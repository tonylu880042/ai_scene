#!/usr/bin/env python3
"""Fetch a real Saisies elevation/orthophoto square with explicit provenance.

The output is a small, reproducible staging package for a later Godot terrain
consumer.  It deliberately writes raw web tiles beside the derived products;
the terrain material must never be mistaken for a photograph pasted into the
scene.

    python3 tools/fetch_saisies_geography.py

Defaults target a 24 km square centred at 45.72 N, 6.57 E.  The elevation
source is AWS Terrain Tiles in Mapzen Terrarium encoding at z12.  The primary
imagery source is the French IGN orthophoto WMTS at z13.  If the IGN probe is
unavailable, the script records the failure and uses the explicit EOX
Sentinel-2 cloudless fallback; it never fills a missing image with generated
or constant pixels.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import io
import json
import math
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "assets" / "terrain" / "saisies_geo"
LATITUDE = 45.72
LONGITUDE = 6.57
SIZE_M = 24_000.0
ELEVATION_ZOOM = 12
IMAGERY_ZOOM = 13
HEIGHT_GRID = 769
ALBEDO_SIZE = 4096
TILE_SIZE = 256
TILE_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
IGN_WMTS = "https://data.geopf.fr/wmts"
IGN_TILE_URL = (
    IGN_WMTS
    + "?REQUEST=GetTile&SERVICE=WMTS&VERSION=1.0.0&STYLE=normal"
    + "&TILEMATRIXSET=PM&FORMAT=image/jpeg&LAYER=ORTHOIMAGERY.ORTHOPHOTOS"
    + "&TILEMATRIX={z}&TILECOL={x}&TILEROW={y}"
)
EOX_TILE_URL = "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg"
USER_AGENT = "ai-scene/saisies-geography-fetch (public terrain cache)"
RETRIES = 3


@dataclass(frozen=True)
class Tile:
    source_key: str
    z: int
    x: int
    y: int
    url: str
    path: Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=None, help="output directory (default: assets/terrain/saisies_geo)")
    parser.add_argument("--workers", type=int, default=None, help="parallel tile requests, clamped to 4..6")
    parser.add_argument("--force", action="store_true", help="redownload cached raw tiles")
    return parser.parse_args()


def output_dir_from(args: argparse.Namespace) -> Path:
    configured = args.output or os.environ.get("SAISIES_GEO_OUTPUT")
    return (Path(configured) if configured else DEFAULT_OUTPUT).resolve()


def worker_count(args: argparse.Namespace) -> int:
    configured = args.workers
    if configured is None:
        configured = int(os.environ.get("SAISIES_GEO_WORKERS", "4"))
    return max(4, min(6, configured))


def world_px(lat: float, lon: float, zoom: int) -> tuple[float, float]:
    n = TILE_SIZE * 2**zoom
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n
    return x, y


def metres_per_pixel(lat: float, zoom: int) -> float:
    return 40_075_016.686 * math.cos(math.radians(lat)) / (TILE_SIZE * 2**zoom)


def pixel_bounds(lat: float, lon: float, size_m: float, zoom: int) -> tuple[float, float, float, float]:
    cx, cy = world_px(lat, lon, zoom)
    half_px = size_m / (2.0 * metres_per_pixel(lat, zoom))
    return cx - half_px, cy - half_px, cx + half_px, cy + half_px


def tile_span(bounds: tuple[float, float, float, float]) -> tuple[int, int, int, int]:
    x0, y0, x1, y1 = bounds
    return (
        int(math.floor(x0 / TILE_SIZE)),
        int(math.floor(y0 / TILE_SIZE)),
        int(math.floor(x1 / TILE_SIZE)),
        int(math.floor(y1 / TILE_SIZE)),
    )


def tile_url(template: str, z: int, x: int, y: int) -> str:
    return template.format(z=z, x=x, y=y)


def tiles_for(
    source_key: str,
    z: int,
    bounds: tuple[float, float, float, float],
    template: str,
    raw_root: Path,
    suffix: str,
) -> list[Tile]:
    tx0, ty0, tx1, ty1 = tile_span(bounds)
    base = raw_root / source_key / f"z{z}"
    return [
        Tile(source_key, z, tx, ty, tile_url(template, z, tx, ty), base / f"{tx}_{ty}{suffix}")
        for ty in range(ty0, ty1 + 1)
        for tx in range(tx0, tx1 + 1)
    ]


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def image_info(data: bytes) -> tuple[tuple[int, int], str, np.ndarray]:
    if len(data) < 1024:
        raise ValueError(f"tile response is unexpectedly small ({len(data)} bytes)")
    try:
        with Image.open(io.BytesIO(data)) as image:
            if image.size != (TILE_SIZE, TILE_SIZE):
                raise ValueError(f"tile dimensions are {image.size}, expected 256x256")
            rgb = np.asarray(image.convert("RGB"))
            image_format = image.format or "unknown"
    except Exception as exc:
        raise ValueError(f"tile is not a decodable 256px image: {exc}") from exc
    if rgb.size == 0 or not np.isfinite(rgb).all() or int(np.ptp(rgb)) == 0:
        raise ValueError("tile is empty or constant")
    return (TILE_SIZE, TILE_SIZE), image_format, rgb


def fetch_bytes(tile: Tile, timeout_s: int = 60) -> bytes:
    last_error: Exception | None = None
    for attempt in range(1, RETRIES + 1):
        try:
            request = Request(tile.url, headers={"User-Agent": USER_AGENT})
            with urlopen(request, timeout=timeout_s) as response:
                data = response.read()
            image_info(data)
            return data
        except (HTTPError, URLError, TimeoutError, ValueError, OSError) as exc:
            last_error = exc
            if attempt < RETRIES:
                time.sleep(float(2 ** (attempt - 1)))
    raise RuntimeError(f"failed {tile.source_key} z{tile.z}/{tile.x}/{tile.y}: {last_error}")


def cached_tile(tile: Tile, force: bool) -> dict[str, Any]:
    if tile.path.exists() and not force:
        try:
            data = tile.path.read_bytes()
            dimensions, image_format, _ = image_info(data)
            return {
                "source_key": tile.source_key,
                "z": tile.z,
                "x": tile.x,
                "y": tile.y,
                "path": str(tile.path),
                "relative_path": str(tile.path.relative_to(tile.path.parents[2])),
                "url": tile.url,
                "size_bytes": len(data),
                "sha256": sha256_bytes(data),
                "dimensions": list(dimensions),
                "format": image_format,
                "cached": True,
            }
        except (OSError, ValueError) as exc:
            print(f"cache invalid, refetching {tile.path}: {exc}", flush=True)

    tile.path.parent.mkdir(parents=True, exist_ok=True)
    data = fetch_bytes(tile)
    temporary = tile.path.with_suffix(tile.path.suffix + ".part")
    temporary.write_bytes(data)
    os.replace(temporary, tile.path)
    dimensions, image_format, _ = image_info(data)
    return {
        "source_key": tile.source_key,
        "z": tile.z,
        "x": tile.x,
        "y": tile.y,
        "path": str(tile.path),
        "relative_path": str(tile.path.relative_to(tile.path.parents[2])),
        "url": tile.url,
        "size_bytes": len(data),
        "sha256": sha256_bytes(data),
        "dimensions": list(dimensions),
        "format": image_format,
        "cached": False,
    }


def fetch_many(tiles: Iterable[Tile], workers: int, force: bool) -> list[dict[str, Any]]:
    tile_list = list(tiles)
    results: list[dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(cached_tile, tile, force): tile for tile in tile_list}
        for index, future in enumerate(concurrent.futures.as_completed(futures), start=1):
            tile = futures[future]
            result = future.result()
            results.append(result)
            state = "cache" if result["cached"] else "fetch"
            print(f"  {state} {tile.source_key} z{tile.z}/{tile.x}/{tile.y} ({index}/{len(tile_list)})", flush=True)
    return sorted(results, key=lambda item: (item["y"], item["x"]))


def probe_one(tile: Tile, force: bool) -> dict[str, Any]:
    print(f"probing {tile.source_key} with z{tile.z}/{tile.x}/{tile.y}", flush=True)
    result = cached_tile(tile, force)
    print(
        f"probe ok: {result['format']} {result['dimensions'][0]}x{result['dimensions'][1]} "
        f"{result['size_bytes']} bytes sha256={result['sha256'][:16]}…",
        flush=True,
    )
    return result


def open_tile(path: Path) -> np.ndarray:
    with Image.open(path) as image:
        return np.asarray(image.convert("RGB"))


def assemble_canvas(
    tile_records: list[dict[str, Any]],
    bounds: tuple[float, float, float, float],
    decoder: Callable[[Path], np.ndarray],
) -> tuple[np.ndarray, int, int]:
    if not tile_records:
        raise ValueError("cannot assemble an empty tile set")
    tx0, ty0, tx1, ty1 = tile_span(bounds)
    first = decoder(Path(tile_records[0]["path"]))
    channels = 1 if first.ndim == 2 else first.shape[2]
    canvas_shape = ((ty1 - ty0 + 1) * TILE_SIZE, (tx1 - tx0 + 1) * TILE_SIZE)
    if channels > 1:
        canvas_shape += (channels,)
    canvas = np.zeros(canvas_shape, dtype=first.dtype)
    for record in tile_records:
        tile = decoder(Path(record["path"]))
        if tile.shape[:2] != (TILE_SIZE, TILE_SIZE):
            raise ValueError(f"decoded tile has invalid shape {tile.shape}: {record['path']}")
        offset_x = (int(record["x"]) - tx0) * TILE_SIZE
        offset_y = (int(record["y"]) - ty0) * TILE_SIZE
        canvas[offset_y : offset_y + TILE_SIZE, offset_x : offset_x + TILE_SIZE] = tile
    return canvas, tx0 * TILE_SIZE, ty0 * TILE_SIZE


def sample_mosaic(
    canvas: np.ndarray,
    origin_x: int,
    origin_y: int,
    bounds: tuple[float, float, float, float],
    out_width: int,
    out_height: int,
    inclusive_vertices: bool,
) -> np.ndarray:
    """Sample a tile canvas at floating WebMercator pixel coordinates.

    Tile arrays represent pixel centres at global coordinates n + 0.5.  DEM
    output is an inclusive vertex grid, while imagery output uses pixel-centre
    coordinates inside the exact requested bounds.  Chunking keeps the 4096px
    RGB interpolation below a large temporary allocation.
    """
    x0, y0, x1, y1 = bounds
    if inclusive_vertices:
        xs = np.linspace(x0, x1, out_width, dtype=np.float64)
        ys = np.linspace(y0, y1, out_height, dtype=np.float64)
    else:
        xs = x0 + (np.arange(out_width, dtype=np.float64) + 0.5) * (x1 - x0) / out_width
        ys = y0 + (np.arange(out_height, dtype=np.float64) + 0.5) * (y1 - y0) / out_height
    src_x = xs - float(origin_x) - 0.5
    src_y = ys - float(origin_y) - 0.5
    x_lo = np.floor(src_x).astype(np.int64)
    y_lo_all = np.floor(src_y).astype(np.int64)
    x_lo = np.clip(x_lo, 0, canvas.shape[1] - 1)
    x_hi = np.clip(x_lo + 1, 0, canvas.shape[1] - 1)
    tx = (src_x - x_lo).astype(np.float32)
    output_shape = (out_height, out_width) if canvas.ndim == 2 else (out_height, out_width, canvas.shape[2])
    result = np.empty(output_shape, dtype=np.float32)
    chunk_rows = 128
    for row_start in range(0, out_height, chunk_rows):
        row_end = min(row_start + chunk_rows, out_height)
        y_lo = np.clip(y_lo_all[row_start:row_end], 0, canvas.shape[0] - 1)
        y_hi = np.clip(y_lo + 1, 0, canvas.shape[0] - 1)
        ty = (src_y[row_start:row_end] - y_lo).astype(np.float32)
        top_left = canvas[y_lo[:, None], x_lo[None, :]].astype(np.float32)
        top_right = canvas[y_lo[:, None], x_hi[None, :]].astype(np.float32)
        bottom_left = canvas[y_hi[:, None], x_lo[None, :]].astype(np.float32)
        bottom_right = canvas[y_hi[:, None], x_hi[None, :]].astype(np.float32)
        if canvas.ndim == 3:
            weight_x = tx[None, :, None]
            weight_y = ty[:, None, None]
        else:
            weight_x = tx[None, :]
            weight_y = ty[:, None]
        top = top_left * (1.0 - weight_x)
        top += top_right * weight_x
        bottom = bottom_left * (1.0 - weight_x)
        bottom += bottom_right * weight_x
        result[row_start:row_end] = top * (1.0 - weight_y) + bottom * weight_y
    if not np.isfinite(result).all():
        raise ValueError("floating mosaic sample contains non-finite values")
    return result


def decode_terrarium(path: Path) -> np.ndarray:
    rgb = open_tile(path).astype(np.float64)
    return (rgb[..., 0] * 256.0 + rgb[..., 1] + rgb[..., 2] / 256.0 - 32768.0).astype(np.float32)


def write_height(tile_records: list[dict[str, Any]], bounds: tuple[float, float, float, float], path: Path) -> np.ndarray:
    canvas, origin_x, origin_y = assemble_canvas(tile_records, bounds, decode_terrarium)
    height = sample_mosaic(canvas, origin_x, origin_y, bounds, HEIGHT_GRID, HEIGHT_GRID, True)
    if height.shape != (HEIGHT_GRID, HEIGHT_GRID) or not np.isfinite(height).all():
        raise ValueError("height output is not a finite 769x769 array")
    if float(height.max()) - float(height.min()) < 1.0:
        raise ValueError("height output is effectively constant")
    if float(height.min()) < -1000.0 or float(height.max()) > 9000.0:
        raise ValueError(f"height output is outside plausible Earth bounds: {height.min()}..{height.max()}")
    path.parent.mkdir(parents=True, exist_ok=True)
    height.astype("<f4").tofile(path)
    return height


def write_albedo(tile_records: list[dict[str, Any]], bounds: tuple[float, float, float, float], path: Path) -> np.ndarray:
    canvas, origin_x, origin_y = assemble_canvas(tile_records, bounds, open_tile)
    sampled = sample_mosaic(canvas, origin_x, origin_y, bounds, ALBEDO_SIZE, ALBEDO_SIZE, False)
    image = Image.fromarray(np.clip(np.rint(sampled), 0.0, 255.0).astype(np.uint8), mode="RGB")
    albedo = np.asarray(image, dtype=np.uint8)
    if albedo.shape != (ALBEDO_SIZE, ALBEDO_SIZE, 3) or int(np.ptp(albedo)) == 0:
        raise ValueError("albedo output is empty, constant, or not 4096x4096 RGB")
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="JPEG", quality=92, optimize=True)
    return albedo


def lonlat_from_pixel(x: float, y: float, zoom: int) -> tuple[float, float]:
    n = TILE_SIZE * 2**zoom
    lon = x / n * 360.0 - 180.0
    mercator = math.pi * (1.0 - 2.0 * y / n)
    lat = math.degrees(math.atan(math.sinh(mercator)))
    return lon, lat


def bounds_wgs84(bounds: tuple[float, float, float, float], zoom: int) -> dict[str, float]:
    x0, y0, x1, y1 = bounds
    west, north = lonlat_from_pixel(x0, y0, zoom)
    east, south = lonlat_from_pixel(x1, y1, zoom)
    return {"west": west, "south": south, "east": east, "north": north}


def source_records(imagery_key: str, imagery_template: str, fallback_reason: str | None) -> dict[str, Any]:
    sources: dict[str, Any] = {
        "elevation": {
            "name": "AWS Terrain Tiles / Tilezen Terrarium",
            "template": TILE_URL,
            "registry": "https://registry.opendata.aws/terrain-tiles/",
            "attribution_url": "https://github.com/tilezen/joerd/blob/master/docs/attribution.md",
            "license": "Multiple source datasets; see Tilezen attribution",
            "attribution": "Europe terrain: Copernicus / European Union EU-DEM; global datasets: USGS SRTM/GMTED2010; served as Mapzen Terrarium tiles",
        },
        "imagery": {
            "name": "French IGN orthophoto WMTS",
            "template": imagery_template,
            "service": IGN_WMTS,
            "layer": "ORTHOIMAGERY.ORTHOPHOTOS",
            "license": "Etalab 2.0 Open Licence",
            "license_url": "https://www.etalab.gouv.fr/licence-ouverte-open-licence/",
            "attribution": "© IGN — open orthophotography under Licence Ouverte / Etalab 2.0",
            "status": "primary_ign" if imagery_key == "ign_ortho" else "explicit_fallback",
        },
    }
    licenses = [
        {
            "dataset": "AWS Terrain Tiles / Tilezen Terrarium",
            "license": "Multiple source datasets; see Tilezen attribution",
            "source": "https://registry.opendata.aws/terrain-tiles/",
            "attribution": "Europe terrain: Copernicus / European Union EU-DEM; global datasets: USGS SRTM/GMTED2010; Tilezen attribution: https://github.com/tilezen/joerd/blob/master/docs/attribution.md",
        },
        {
            "dataset": "IGN ORTHOIMAGERY.ORTHOPHOTOS",
            "license": "Etalab 2.0 Open Licence",
            "source": "https://www.etalab.gouv.fr/licence-ouverte-open-licence/",
        },
    ]
    if imagery_key != "ign_ortho":
        sources["imagery_fallback"] = {
            "name": "EOX Sentinel-2 cloudless",
            "template": imagery_template,
            "license": "CC BY 4.0",
            "attribution": "Sentinel-2 cloudless by EOX IT Services GmbH; contains modified Copernicus Sentinel data 2016",
            "reason": fallback_reason or "IGN probe failed",
            "source": "https://s2maps.eu/",
        }
        licenses.append(
            {
                "dataset": "EOX Sentinel-2 cloudless fallback",
                "license": "CC BY 4.0",
                "source": "https://s2maps.eu/",
            }
        )
    return {"sources": sources, "licenses": licenses}


def public_tile_records(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Remove machine-specific absolute paths before records enter metadata."""
    public: list[dict[str, Any]] = []
    for record in records:
        item = {key: value for key, value in record.items() if key != "path"}
        item["path"] = f"raw/{record['relative_path']}"
        public.append(item)
    return public


def main() -> int:
    args = parse_args()
    out = output_dir_from(args)
    raw = out / "raw"
    out.mkdir(parents=True, exist_ok=True)
    raw.mkdir(parents=True, exist_ok=True)
    workers = worker_count(args)

    elevation_bounds = pixel_bounds(LATITUDE, LONGITUDE, SIZE_M, ELEVATION_ZOOM)
    imagery_bounds = pixel_bounds(LATITUDE, LONGITUDE, SIZE_M, IMAGERY_ZOOM)
    elevation_tiles = tiles_for("aws_terrarium", ELEVATION_ZOOM, elevation_bounds, TILE_URL, raw, ".png")
    ign_tiles = tiles_for("ign_ortho", IMAGERY_ZOOM, imagery_bounds, IGN_TILE_URL, raw, ".jpg")
    print(
        f"Saisies geography centre=({LATITUDE:.5f},{LONGITUDE:.5f}) size={SIZE_M:.0f}m "
        f"height_tiles={len(elevation_tiles)} imagery_tiles={len(ign_tiles)} workers={workers}",
        flush=True,
    )

    imagery_key = "ign_ortho"
    imagery_template = IGN_TILE_URL
    fallback_reason: str | None = None
    try:
        probe_one(ign_tiles[0], args.force)
    except Exception as exc:
        fallback_reason = str(exc)
        print(f"WARNING: IGN WMTS probe failed; using explicit EOX fallback: {fallback_reason}", flush=True)
        imagery_key = "eox_s2cloudless"
        imagery_template = EOX_TILE_URL
        fallback_tiles = tiles_for(imagery_key, IMAGERY_ZOOM, imagery_bounds, imagery_template, raw, ".jpg")
        probe_one(fallback_tiles[0], args.force)
        ign_tiles = fallback_tiles

    print("fetching AWS Terrarium elevation tiles…", flush=True)
    elevation_records = fetch_many(elevation_tiles, workers, args.force)
    height_path = out / "height.f32"
    height = write_height(elevation_records, elevation_bounds, height_path)
    print(
        f"height.f32: shape={height.shape} range={float(height.min()):.2f}..{float(height.max()):.2f}m "
        f"sha256={sha256_file(height_path)[:16]}…",
        flush=True,
    )

    print(f"fetching {imagery_key} orthophoto tiles…", flush=True)
    imagery_records = fetch_many(ign_tiles, workers, args.force)
    albedo_path = out / "albedo.jpg"
    albedo = write_albedo(imagery_records, imagery_bounds, albedo_path)
    print(
        f"albedo.jpg: shape={albedo.shape} range={int(albedo.min())}..{int(albedo.max())} "
        f"sha256={sha256_file(albedo_path)[:16]}…",
        flush=True,
    )

    raw_hashes = {
        record["relative_path"]: record["sha256"]
        for record in [*elevation_records, *imagery_records]
    }
    geographic_bounds = bounds_wgs84(imagery_bounds, IMAGERY_ZOOM)
    if not all(math.isfinite(value) for value in geographic_bounds.values()):
        raise ValueError(f"geographic bounds contain non-finite coordinates: {geographic_bounds}")
    if not (-90.0 <= geographic_bounds["south"] < geographic_bounds["north"] <= 90.0):
        raise ValueError(f"geographic latitude bounds are invalid: {geographic_bounds}")
    if not (-180.0 <= geographic_bounds["west"] < geographic_bounds["east"] <= 180.0):
        raise ValueError(f"geographic longitude bounds are invalid: {geographic_bounds}")
    metadata: dict[str, Any] = {
        "name": "saisies_geo",
        "centre": {"lat": LATITUDE, "lon": LONGITUDE},
        "size_m": SIZE_M,
        "bounds_wgs84": geographic_bounds,
        "height": {
            "file": "height.f32",
            "grid": HEIGHT_GRID,
            "shape": list(height.shape),
            "dtype": "<f4",
            "row0": "north",
            "zoom": ELEVATION_ZOOM,
            "pixel_bounds": [float(value) for value in elevation_bounds],
            "metres_per_source_pixel": metres_per_pixel(LATITUDE, ELEVATION_ZOOM),
            "tile_span": list(tile_span(elevation_bounds)),
            "min_m": float(height.min()),
            "max_m": float(height.max()),
            "centre_m": float(height[HEIGHT_GRID // 2, HEIGHT_GRID // 2]),
        },
        "albedo": {
            "file": "albedo.jpg",
            "shape": list(albedo.shape),
            "dtype": "uint8 RGB",
            "zoom": IMAGERY_ZOOM,
            "pixel_bounds": [float(value) for value in imagery_bounds],
            "metres_per_source_pixel": metres_per_pixel(LATITUDE, IMAGERY_ZOOM),
            "tile_span": list(tile_span(imagery_bounds)),
        },
        "sampling": {
            "projection": "EPSG:3857 global WebMercator tile pixels",
            "tile_pixel_center": "global pixel coordinate n + 0.5 represents the centre of source array index n",
            "bounds_definition": "24km square edges at centre +/- size_m/2 using local WebMercator metres per pixel",
            "resampling": "floating-coordinate bilinear interpolation over the full raw tile canvas",
            "height": {
                "convention": "inclusive vertex grid",
                "coordinate": "x=x_min + i*(x_max-x_min)/(grid-1), y=y_min + j*(y_max-y_min)/(grid-1)",
                "row0": "north",
            },
            "albedo": {
                "convention": "pixel centres inside exact bounds",
                "coordinate": "x=x_min + (i+0.5)*(x_max-x_min)/width, y=y_min + (j+0.5)*(y_max-y_min)/height",
                "row0": "north",
            },
        },
        "raw_cache": {"directory": "raw", "tile_count": len(elevation_records) + len(imagery_records)},
        "hashes": {
            "height.f32": sha256_file(height_path),
            "albedo.jpg": sha256_file(albedo_path),
            "raw_tiles": raw_hashes,
        },
        "tile_records": {
            "elevation": public_tile_records(elevation_records),
            "imagery": public_tile_records(imagery_records),
        },
        "validation": {
            "all_tiles_decoded_256px": True,
            "height_finite_and_nonconstant": True,
            "albedo_finite_and_nonconstant": True,
        },
    }
    metadata.update(source_records(imagery_key, imagery_template, fallback_reason))
    metadata_path = out / "metadata.json"
    metadata_path.write_text(json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"metadata.json: {metadata_path} ({metadata_path.stat().st_size} bytes)", flush=True)
    print("SAISIES GEOGRAPHY FETCH PASS", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"SAISIES GEOGRAPHY FETCH FAIL: {exc}", file=sys.stderr, flush=True)
        raise
