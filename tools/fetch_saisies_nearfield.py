#!/usr/bin/env python3
"""Fetch small official IGN RGE Alti near-field patches for the geo route.

The patches are independent source-data artifacts.  They use the exact local
WebMercator frame shared by ``scripts/saisies_geography.gd`` and retain the
original coarse DEM datum; no runtime route or terrain code is changed here.

Default output is two 512 m axis-aligned XZ squares around the S08 and S13
route stations.  Each square is a 65x65 inclusive vertex grid at 8 m spacing,
stored as ASL little-endian float32 values in rows of increasing z and columns
of increasing x.  Raw API responses are cached in 64-point batches so a
subsequent verification run is offline and hashable.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import hashlib
import json
import math
import os
import struct
import sys
from pathlib import Path
from typing import Any, Iterable

# Reuse the already validated IGN request/response implementation.  The
# import works both when invoked as ``python tools/...`` and when imported from
# a test process because the script directory is on sys.path in the former
# case; the fallback keeps direct module execution explicit.
try:
    from fetch_saisies_road_elevations import (
        API_URL,
        PROVENANCE_URL,
        RESOURCE,
        USER_AGENT,
        fetch_raw,
        project_relative,
        request_url,
        sha256_bytes,
        sha256_file,
        validate_response,
    )
except ImportError:  # pragma: no cover - only used by unusual module loaders
    from tools.fetch_saisies_road_elevations import (  # type: ignore
        API_URL,
        PROVENANCE_URL,
        RESOURCE,
        USER_AGENT,
        fetch_raw,
        project_relative,
        request_url,
        sha256_bytes,
        sha256_file,
        validate_response,
    )


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ROUTE = ROOT / "data" / "saisies_geo_route.json"
DEFAULT_METADATA = ROOT / "assets" / "terrain" / "saisies_geo" / "metadata.json"
DEFAULT_CACHE = ROOT / "assets" / "terrain" / "saisies_geo" / "nearfield" / "cache"
DEFAULT_OUTPUT = ROOT / "data" / "saisies_geo_nearfield.json"
DEFAULT_BATCH_SIZE = 64
DEFAULT_WORKERS = 4
DEFAULT_TIMEOUT_S = 40.0
EARTH_RADIUS_M = 6378137.0
WEB_MERCATOR_MAX_LAT = 85.0511287798066
GRID = 65
SPACING_M = 8.0
PATCH_SIZE_M = (GRID - 1) * SPACING_M
HALF_PATCH_M = PATCH_SIZE_M * 0.5
NO_DATA_ABS_LIMIT_M = 10_000.0
LAT_LON_TOLERANCE = 2.0e-7
PATCHES = (
    {
        "id": "S08",
        "center_s_m": 5275.0,
        "current_acceptance_station_s_m": 5143.26,
        "alternate_diagnostic_station_s_m": 5408.0,
        "station_note": "Center shifted for near-field elevation diagnostics; production acceptance remains at 5143.26m.",
    },
    {"id": "S13", "center_s_m": 10339.0},
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--route", type=Path, default=DEFAULT_ROUTE)
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    parser.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S)
    parser.add_argument("--force", action="store_true", help="refetch all raw API batches")
    parser.add_argument("--verify-only", action="store_true", help="verify existing report/cache/f32 without network")
    return parser.parse_args()


def finite(value: Any) -> bool:
    try:
        return math.isfinite(float(value))
    except (TypeError, ValueError):
        return False


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return sha256_bytes(encoded)


def read_json(path: Path) -> dict[str, Any]:
    parsed = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(parsed, dict):
        raise ValueError(f"expected JSON object: {path}")
    return parsed


def load_route(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    data = read_json(path)
    points = data.get("points")
    if not isinstance(points, list) or len(points) < 2:
        raise ValueError(f"route has fewer than two points: {path}")
    checked: list[dict[str, Any]] = []
    previous_s = -1.0
    for index, point in enumerate(points):
        if not isinstance(point, dict):
            raise ValueError(f"route point {index} is not an object")
        for key in ("lat", "lon", "s_m"):
            if not finite(point.get(key)):
                raise ValueError(f"route point {index} has non-finite {key}")
        s_m = float(point["s_m"])
        if s_m <= previous_s:
            raise ValueError(f"route s_m is not strictly increasing at point {index}")
        previous_s = s_m
        checked.append(point)
    if abs(float(checked[0]["s_m"])) > 0.01:
        raise ValueError("route does not start at s_m=0")
    return data, checked


class GeographyFrame:
    """Exact WebMercator/local transform mirrored from SaisiesGeography."""

    def __init__(self, frame: dict[str, Any], metadata: dict[str, Any]) -> None:
        required = [
            "origin_lat",
            "origin_lon",
            "forward_east",
            "forward_north",
            "right_east",
            "right_north",
            "datum_m",
        ]
        for key in required:
            if not finite(frame.get(key)):
                raise ValueError(f"geography frame field is not finite: {key}")
        self.frame = {key: frame[key] for key in frame}
        self.origin_lat = float(frame["origin_lat"])
        self.origin_lon = float(frame["origin_lon"])
        self.forward_east = float(frame["forward_east"])
        self.forward_north = float(frame["forward_north"])
        self.right_east = float(frame["right_east"])
        self.right_north = float(frame["right_north"])
        self.datum_m = float(frame["datum_m"])
        forward_len = math.hypot(self.forward_east, self.forward_north)
        right_len = math.hypot(self.right_east, self.right_north)
        if abs(forward_len - 1.0) > 0.02 or abs(right_len - 1.0) > 0.02:
            raise ValueError("geography frame basis is not normalized")
        if abs(self.forward_east * self.right_east + self.forward_north * self.right_north) > 0.02:
            raise ValueError("geography frame basis is not orthogonal")
        bounds = metadata.get("bounds_wgs84")
        if not isinstance(bounds, dict):
            raise ValueError("terrain metadata has no bounds_wgs84")
        self.west = float(bounds["west"])
        self.south = float(bounds["south"])
        self.east = float(bounds["east"])
        self.north = float(bounds["north"])
        self.map_size_m = float(metadata.get("size_m", 0.0))
        if self.map_size_m <= 0.0:
            raise ValueError("terrain metadata has invalid size_m")
        self.west_mercator = self.mercator_x(self.west)
        self.east_mercator = self.mercator_x(self.east)
        self.south_mercator = self.mercator_y(self.south)
        self.north_mercator = self.mercator_y(self.north)
        if self.east_mercator <= self.west_mercator or self.north_mercator <= self.south_mercator:
            raise ValueError("terrain metadata projected bounds are invalid")
        self.scale_x = self.map_size_m / (self.east_mercator - self.west_mercator)
        self.scale_y = self.map_size_m / (self.north_mercator - self.south_mercator)
        self.origin_mercator_x = self.mercator_x(self.origin_lon)
        self.origin_mercator_y = self.mercator_y(self.origin_lat)

    @staticmethod
    def mercator_x(lon: float) -> float:
        return EARTH_RADIUS_M * math.radians(lon)

    @staticmethod
    def mercator_y(lat: float) -> float:
        bounded = max(-WEB_MERCATOR_MAX_LAT, min(WEB_MERCATOR_MAX_LAT, lat))
        return EARTH_RADIUS_M * math.log(math.tan(math.pi * 0.25 + math.radians(bounded) * 0.5))

    @staticmethod
    def inverse_mercator_lon(value: float) -> float:
        return math.degrees(value / EARTH_RADIUS_M)

    @staticmethod
    def inverse_mercator_lat(value: float) -> float:
        return math.degrees(math.atan(math.sinh(value / EARTH_RADIUS_M)))

    def world_from_latlon(self, lat: float, lon: float) -> tuple[float, float]:
        en_x = (self.mercator_x(lon) - self.origin_mercator_x) * self.scale_x
        en_y = (self.mercator_y(lat) - self.origin_mercator_y) * self.scale_y
        return (
            en_x * self.right_east + en_y * self.right_north,
            -(en_x * self.forward_east + en_y * self.forward_north),
        )

    def latlon_from_world(self, x: float, z: float) -> tuple[float, float]:
        en_x = x * self.right_east - z * self.forward_east
        en_y = x * self.right_north - z * self.forward_north
        mercator_x = self.origin_mercator_x + en_x / self.scale_x
        mercator_y = self.origin_mercator_y + en_y / self.scale_y
        return self.inverse_mercator_lat(mercator_y), self.inverse_mercator_lon(mercator_x)


def route_anchor(points: list[dict[str, Any]], station: float, geography: GeographyFrame) -> dict[str, Any]:
    if station < float(points[0]["s_m"]) or station > float(points[-1]["s_m"]):
        raise ValueError(f"station {station} is outside route range")
    upper = next((index for index, point in enumerate(points) if float(point["s_m"]) >= station), len(points) - 1)
    lower = max(0, upper - 1)
    a = points[lower]
    b = points[upper]
    ds = float(b["s_m"]) - float(a["s_m"])
    fraction = 0.0 if ds <= 0.0 else (station - float(a["s_m"])) / ds
    fraction = max(0.0, min(1.0, fraction))
    a_world = geography.world_from_latlon(float(a["lat"]), float(a["lon"]))
    b_world = geography.world_from_latlon(float(b["lat"]), float(b["lon"]))
    center_x = a_world[0] + (b_world[0] - a_world[0]) * fraction
    center_z = a_world[1] + (b_world[1] - a_world[1]) * fraction
    center_lat, center_lon = geography.latlon_from_world(center_x, center_z)
    linear_lat = float(a["lat"]) + (float(b["lat"]) - float(a["lat"])) * fraction
    linear_lon = float(a["lon"]) + (float(b["lon"]) - float(a["lon"])) * fraction
    linear_world = geography.world_from_latlon(linear_lat, linear_lon)
    projection_delta = math.hypot(center_x - linear_world[0], center_z - linear_world[1])
    if projection_delta > 0.05:
        raise ValueError(f"route station {station} projection interpolation diverges by {projection_delta:.3f}m")
    return {
        "center_s_m": station,
        "center_x": center_x,
        "center_z": center_z,
        "center_lat": center_lat,
        "center_lon": center_lon,
        "route_bracket": [lower, upper],
        "route_fraction": fraction,
        "route_bracket_s_m": [float(a["s_m"]), float(b["s_m"])],
        "linear_lat": linear_lat,
        "linear_lon": linear_lon,
        "projection_interpolation_delta_m": projection_delta,
    }


def grid_points(patch: dict[str, Any]) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    min_x = float(patch["min_x"])
    min_z = float(patch["min_z"])
    geography: GeographyFrame = patch["_geography"]
    for row in range(GRID):
        z = min_z + row * SPACING_M
        for column in range(GRID):
            x = min_x + column * SPACING_M
            lat, lon = geography.latlon_from_world(x, z)
            values.append({"row": row, "column": column, "x": x, "z": z, "lat": lat, "lon": lon})
    return values


def validate_api_payload(raw: bytes, batch: list[dict[str, Any]], label: str) -> dict[str, Any]:
    parsed = validate_response(raw, batch, label)
    for index, elevation in enumerate(parsed["elevations"]):
        z = elevation.get("z")
        if not finite(z) or abs(float(z)) >= NO_DATA_ABS_LIMIT_M:
            raise ValueError(f"{label}: no-data/non-finite elevation at offset {index}: {z!r}")
    return parsed


def batch_ranges(count: int, batch_size: int) -> Iterable[tuple[int, int, int]]:
    for batch_index, start in enumerate(range(0, count, batch_size)):
        yield batch_index, start, min(start + batch_size, count)


def cache_namespace(patch: dict[str, Any]) -> str:
    """Separate raw caches when an evidence review moves a patch station."""
    return f"{patch['id']}_{float(patch['center_s_m']):.2f}m"


def fetch_batch(
    patch_id: str,
    cache_key: str,
    batch_index: int,
    start: int,
    batch: list[dict[str, Any]],
    cache_dir: Path,
    force: bool,
    timeout_s: float,
) -> dict[str, Any]:
    end = start + len(batch)
    patch_cache_dir = cache_dir / cache_key
    cache_path = patch_cache_dir / f"batch_{batch_index:04d}_{start:04d}_{end:04d}.json"
    url = request_url(batch)
    raw: bytes | None = None
    cached = False
    if cache_path.exists() and not force:
        try:
            candidate = cache_path.read_bytes()
            validate_api_payload(candidate, batch, f"cache {patch_id}/{cache_path.name}")
            raw = candidate
            cached = True
        except (OSError, ValueError) as exc:
            print(f"cache invalid, refetching {patch_id}/{cache_path.name}: {exc}", flush=True)
    if raw is None:
        raw = fetch_raw(url, timeout_s, f"{patch_id} batch {batch_index}")
        validate_api_payload(raw, batch, f"{patch_id} batch {batch_index}")
        patch_cache_dir.mkdir(parents=True, exist_ok=True)
        temporary = cache_path.with_name(cache_path.name + ".part")
        temporary.write_bytes(raw)
        os.replace(temporary, cache_path)
    payload = validate_api_payload(raw, batch, f"{patch_id} batch {batch_index}")
    return {
        "batch_index": batch_index,
        "start_index": start,
        "end_index": end,
        "count": len(batch),
        "cache_path": cache_path,
        "url": url,
        "raw": raw,
        "payload": payload,
        "cached": cached,
    }


def build_patch_spec(
    patch_definition: dict[str, Any],
    route_points: list[dict[str, Any]],
    geography: GeographyFrame,
) -> dict[str, Any]:
    anchor = route_anchor(route_points, float(patch_definition["center_s_m"]), geography)
    patch = {
        "id": str(patch_definition["id"]),
        **anchor,
        "min_x": anchor["center_x"] - HALF_PATCH_M,
        "min_z": anchor["center_z"] - HALF_PATCH_M,
        "max_x": anchor["center_x"] + HALF_PATCH_M,
        "max_z": anchor["center_z"] + HALF_PATCH_M,
        "spacing_m": SPACING_M,
        "grid": GRID,
        "row_order": "z increasing rows; x increasing columns",
        "height_dtype": "<f4",
        "height_unit": "ASL metres",
        "_geography": geography,
    }
    for key in ("current_acceptance_station_s_m", "alternate_diagnostic_station_s_m", "station_note"):
        if key in patch_definition:
            patch[key] = patch_definition[key]
    patch["sample_count"] = GRID * GRID
    return patch


def assemble_patch(
    patch: dict[str, Any],
    cache_dir: Path,
    batch_size: int,
    workers: int,
    force: bool,
    timeout_s: float,
) -> tuple[list[float], list[dict[str, Any]]]:
    samples = grid_points(patch)
    ranges = list(batch_ranges(len(samples), batch_size))
    results: list[dict[str, Any]] = []
    print(
        f"Fetching {patch['id']}: samples={len(samples)} batches={len(ranges)} "
        f"batch_size={batch_size} workers={workers}",
        flush=True,
    )
    cache_key = cache_namespace(patch)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(
                fetch_batch,
                str(patch["id"]),
                cache_key,
                batch_index,
                start,
                samples[start:end],
                cache_dir,
                force,
                timeout_s,
            ): (batch_index, start, end)
            for batch_index, start, end in ranges
        }
        for completed, future in enumerate(concurrent.futures.as_completed(futures), start=1):
            result = future.result()
            results.append(result)
            state = "cache" if result["cached"] else "fetch"
            print(
                f"  {state} {patch['id']} batch={result['batch_index']:04d} "
                f"samples={result['start_index']}..{result['end_index'] - 1} ({completed}/{len(ranges)})",
                flush=True,
            )
    results.sort(key=lambda item: int(item["batch_index"]))
    heights: list[float] = []
    manifests: list[dict[str, Any]] = []
    expected_index = 0
    for result in results:
        if int(result["start_index"]) != expected_index:
            raise ValueError(f"{patch['id']} batch sequence has a gap at {expected_index}")
        expected_index = int(result["end_index"])
        elevations = result["payload"]["elevations"]
        heights.extend(float(item["z"]) for item in elevations)
        raw_hash = sha256_bytes(result["raw"])
        manifests.append({
            "batch_index": int(result["batch_index"]),
            "start_index": int(result["start_index"]),
            "end_index": int(result["end_index"]),
            "count": int(result["count"]),
            "cache_file": project_relative(result["cache_path"]),
            "cache_bytes": len(result["raw"]),
            "raw_sha256": raw_hash,
            "query_url": result["url"],
            "cached": bool(result["cached"]),
        })
    if len(heights) != GRID * GRID or expected_index != GRID * GRID:
        raise ValueError(f"{patch['id']} assembled {len(heights)} heights, expected {GRID * GRID}")
    return heights, manifests


def write_f32(path: Path, heights: list[float]) -> str:
    if not heights or not all(finite(value) and abs(float(value)) < NO_DATA_ABS_LIMIT_M for value in heights):
        raise ValueError(f"non-finite/no-data height in {path}")
    raw = struct.pack(f"<{len(heights)}f", *heights)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".part")
    temporary.write_bytes(raw)
    os.replace(temporary, path)
    return sha256_bytes(raw)


def enrich_patch_metadata(
    patch: dict[str, Any],
    heights: list[float],
    manifests: list[dict[str, Any]],
    output_root: Path,
) -> dict[str, Any]:
    patch_id = str(patch["id"])
    f32_path = output_root / f"{patch_id}.f32"
    height_hash = write_f32(f32_path, heights)
    center_index = (GRID // 2) * GRID + (GRID // 2)
    metadata = {key: value for key, value in patch.items() if key != "_geography"}
    metadata.update({
        "height_file": f"res://assets/terrain/saisies_geo/nearfield/{patch_id}.f32",
        "height_sha256": height_hash,
        "height_min_asl_m": min(heights),
        "height_max_asl_m": max(heights),
        "height_center_asl_m": heights[center_index],
        "cache_directory": f"assets/terrain/saisies_geo/nearfield/cache/{cache_namespace(patch)}",
        "batch_count": len(manifests),
        "batches": manifests,
        "provenance": {
            "provider": "IGN",
            "dataset": "RGE Alti",
            "resource": RESOURCE,
            "endpoint": API_URL,
            "source_url": PROVENANCE_URL,
            "sampling": "exact shared WebMercator/local frame; axis-aligned XZ grid",
            "request": {
                "batch_size": DEFAULT_BATCH_SIZE,
                "workers": DEFAULT_WORKERS,
                "delimiter": "|",
                "indent": False,
                "measures": True,
                "zonly": False,
            },
            "raw_cache": f"assets/terrain/saisies_geo/nearfield/cache/{cache_namespace(patch)}",
            "note": "Near-field source patch for review; not connected to the runtime route/profile and not GPS/camera calibration.",
        },
    })
    return metadata


def write_report(
    output: Path,
    route_path: Path,
    route_data: dict[str, Any],
    geography: GeographyFrame,
    patches: list[dict[str, Any]],
    args: argparse.Namespace,
) -> dict[str, Any]:
    frame = route_data.get("geography_frame")
    if not isinstance(frame, dict):
        raise ValueError("route data has no geography_frame")
    report: dict[str, Any] = {
        "schema_version": 1,
        "id": "saisies_geo_nearfield",
        "title": "Official IGN RGE Alti near-field patches for S08 and S13",
        "estimated": True,
        "note": "Two bounded ASL source patches around visual-review stations; same shared Mercator/local frame and original coarse DEM datum. This artifact is not runtime terrain integration, GPS, or camera calibration.",
        "route_file": project_relative(route_path),
        "route_sha256": sha256_file(route_path),
        "geography_frame": frame,
        "geography_frame_sha256": canonical_sha256(frame),
        "datum_m": geography.datum_m,
        "source_urls": [API_URL, PROVENANCE_URL],
        "api": {
            "resource": RESOURCE,
            "delimiter": "|",
            "indent": False,
            "measures": True,
            "zonly": False,
            "batch_size": int(args.batch_size),
            "workers": int(args.workers),
            "user_agent": USER_AGENT,
        },
        "grid_contract": {
            "grid": GRID,
            "spacing_m": SPACING_M,
            "size_m": PATCH_SIZE_M,
            "height_dtype": "<f4",
            "height_unit": "ASL metres",
            "row_order": "z increasing rows; x increasing columns",
        },
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
        "patches": patches,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".part")
    temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, output)
    return report


def validate_report_files(
    report_path: Path,
    route_path: Path,
    metadata_path: Path,
    cache_dir: Path,
) -> dict[str, Any]:
    report = read_json(report_path)
    route_data, route_points = load_route(route_path)
    terrain_metadata = read_json(metadata_path)
    frame = report.get("geography_frame")
    if not isinstance(frame, dict):
        raise ValueError("report is missing complete geography_frame")
    if report.get("geography_frame_sha256") != canonical_sha256(frame):
        raise ValueError("geography_frame_sha256 does not match report frame")
    route_frame = route_data.get("geography_frame")
    if not isinstance(route_frame, dict) or canonical_sha256(route_frame) != report.get("geography_frame_sha256"):
        raise ValueError("report frame differs from route geography frame")
    geography = GeographyFrame(frame, terrain_metadata)
    if abs(float(report.get("datum_m", float("nan"))) - geography.datum_m) > 1e-6:
        raise ValueError("report datum differs from route frame datum")
    patches = report.get("patches")
    if not isinstance(patches, list) or [item.get("id") for item in patches if isinstance(item, dict)] != ["S08", "S13"]:
        raise ValueError("report does not contain S08/S13 in order")
    route_rge_path = ROOT / "data" / "saisies_geo_road_elevations.json"
    route_rge = read_json(route_rge_path) if route_rge_path.exists() else None
    for patch in patches:
        if not isinstance(patch, dict):
            raise ValueError("patch metadata is not an object")
        patch_id = str(patch.get("id", ""))
        if patch_id not in {"S08", "S13"}:
            raise ValueError(f"unexpected patch id: {patch_id}")
        definition = next((item for item in PATCHES if item["id"] == patch_id), None)
        if definition is None:
            raise ValueError(f"no source definition for patch {patch_id}")
        expected = build_patch_spec(definition, route_points, geography)
        for key in ("center_s_m", "center_x", "center_z", "min_x", "min_z", "max_x", "max_z", "spacing_m", "grid"):
            if abs(float(patch[key]) - float(expected[key])) > 1e-5:
                raise ValueError(f"{patch_id} metadata mismatch for {key}: {patch[key]} vs {expected[key]}")
        if float(patch["spacing_m"]) != SPACING_M or int(patch["grid"]) != GRID:
            raise ValueError(f"{patch_id} grid contract mismatch")
        for key in ("current_acceptance_station_s_m", "alternate_diagnostic_station_s_m", "station_note"):
            if key in expected and patch.get(key) != expected[key]:
                raise ValueError(f"{patch_id} station metadata mismatch for {key}")
        height_file = ROOT / "assets" / "terrain" / "saisies_geo" / "nearfield" / f"{patch_id}.f32"
        raw_height = height_file.read_bytes()
        if len(raw_height) != GRID * GRID * 4:
            raise ValueError(f"{patch_id} f32 byte count {len(raw_height)} is invalid")
        if sha256_bytes(raw_height) != str(patch.get("height_sha256", "")):
            raise ValueError(f"{patch_id} height_sha256 mismatch")
        heights = list(struct.unpack(f"<{GRID * GRID}f", raw_height))
        if not all(finite(value) and abs(value) < NO_DATA_ABS_LIMIT_M for value in heights):
            raise ValueError(f"{patch_id} f32 contains non-finite/no-data values")
        samples = grid_points({**expected, "_geography": geography})
        manifests = patch.get("batches")
        if not isinstance(manifests, list) or sum(int(batch.get("count", 0)) for batch in manifests) != len(samples):
            raise ValueError(f"{patch_id} batch manifest does not cover all grid samples")
        reconstructed: list[float] = []
        next_index = 0
        for batch in manifests:
            if not isinstance(batch, dict):
                raise ValueError(f"{patch_id} has non-object batch metadata")
            start = int(batch["start_index"])
            end = int(batch["end_index"])
            if start != next_index or end <= start:
                raise ValueError(f"{patch_id} batch index gap at {next_index}")
            batch_samples = samples[start:end]
            cache_path = ROOT / str(batch["cache_file"])
            raw = cache_path.read_bytes()
            if sha256_bytes(raw) != str(batch.get("raw_sha256", "")):
                raise ValueError(f"{patch_id} raw cache hash mismatch: {cache_path}")
            payload = validate_api_payload(raw, batch_samples, f"verify {patch_id}/{cache_path.name}")
            reconstructed.extend(float(item["z"]) for item in payload["elevations"])
            next_index = end
        if next_index != len(samples) or len(reconstructed) != len(heights):
            raise ValueError(f"{patch_id} reconstructed sample count mismatch")
        # The report stores the API's decimal z as IEEE-754 little-endian
        # float32.  At ~1--2 km ASL this conversion is below 1e-4 m; allow
        # that representation error while still rejecting a sample reorder or
        # a materially different cached response.
        if any(abs(a - b) > 1e-4 for a, b in zip(reconstructed, heights)):
            raise ValueError(f"{patch_id} f32 values differ from cached API responses")
        center_sample = samples[(GRID // 2) * GRID + GRID // 2]
        center_xz = geography.world_from_latlon(center_sample["lat"], center_sample["lon"])
        if math.hypot(center_xz[0] - float(patch["center_x"]), center_xz[1] - float(patch["center_z"])) > 1e-4:
            raise ValueError(f"{patch_id} center sample does not roundtrip to center world XZ")
        for sample in (samples[0], samples[GRID - 1], samples[-GRID], samples[-1], center_sample):
            roundtrip = geography.world_from_latlon(*geography.latlon_from_world(sample["x"], sample["z"]))
            if math.hypot(roundtrip[0] - sample["x"], roundtrip[1] - sample["z"]) > 1e-4:
                raise ValueError(f"{patch_id} bbox/sample Mercator roundtrip exceeded tolerance")
        if route_rge and isinstance(route_rge.get("points"), list):
            nearest = min(route_rge["points"], key=lambda item: abs(float(item["s_m"]) - float(patch["center_s_m"])))
            center_z = heights[(GRID // 2) * GRID + GRID // 2]
            delta_s = abs(float(nearest["s_m"]) - float(patch["center_s_m"]))
            delta_z = abs(float(nearest["z"]) - center_z)
            if delta_s > 20.0 or delta_z > 20.0:
                raise ValueError(f"{patch_id} center vs known route RGE point too far: ds={delta_s:.3f} dz={delta_z:.3f}")
        print(
            f"NEARFIELD {patch_id} VERIFY PASS samples={len(heights)} "
            f"ASL={min(heights):.3f}..{max(heights):.3f} center={heights[(GRID // 2) * GRID + GRID // 2]:.3f}",
            flush=True,
        )
    return report


def print_summary(report: dict[str, Any]) -> None:
    for patch in report["patches"]:
        print(
            f"NEARFIELD {patch['id']} READY station={float(patch['center_s_m']):.3f}m "
            f"center=({float(patch['center_x']):.6f},{float(patch['center_z']):.6f}) "
            f"bbox=x[{float(patch['min_x']):.6f},{float(patch['max_x']):.6f}] "
            f"z[{float(patch['min_z']):.6f},{float(patch['max_z']):.6f}] "
            f"ASL={float(patch['height_min_asl_m']):.3f}..{float(patch['height_max_asl_m']):.3f} "
            f"center_z={float(patch['height_center_asl_m']):.3f} batches={int(patch['batch_count'])}",
            flush=True,
        )


def main() -> int:
    args = parse_args()
    if args.batch_size < 1 or args.batch_size > 64:
        raise SystemExit("--batch-size must be in 1..64")
    if args.workers < 1 or args.workers > 4:
        raise SystemExit("--workers must be in 1..4")
    if args.timeout <= 0.0:
        raise SystemExit("--timeout must be positive")
    route_path = args.route.resolve()
    metadata_path = args.metadata.resolve()
    cache_dir = args.cache_dir.resolve()
    output = args.output.resolve()
    if args.verify_only:
        report = validate_report_files(output, route_path, metadata_path, cache_dir)
        print(f"SAISIES NEARFIELD VERIFY PASS patches={len(report['patches'])} grid={GRID}x{GRID}", flush=True)
        return 0
    route_data, route_points = load_route(route_path)
    terrain_metadata = read_json(metadata_path)
    frame = route_data.get("geography_frame")
    if not isinstance(frame, dict):
        raise ValueError("route data has no geography_frame")
    geography = GeographyFrame(frame, terrain_metadata)
    patch_specs: list[dict[str, Any]] = []
    for definition in PATCHES:
        patch_specs.append(build_patch_spec(definition, route_points, geography))
    output_root = ROOT / "assets" / "terrain" / "saisies_geo" / "nearfield"
    patch_metadata: list[dict[str, Any]] = []
    for patch in patch_specs:
        heights, manifests = assemble_patch(
            patch,
            cache_dir,
            args.batch_size,
            args.workers,
            args.force,
            args.timeout,
        )
        patch_metadata.append(enrich_patch_metadata(patch, heights, manifests, output_root))
    report = write_report(output, route_path, route_data, geography, patch_metadata, args)
    # Verify the written report and every cache/f32 artifact before reporting
    # completion.  This is intentionally offline and exercises the same
    # returned-coordinate/order checks as a later CI run.
    validate_report_files(output, route_path, metadata_path, cache_dir)
    print_summary(report)
    print(f"Wrote {project_relative(output)} and {len(patch_metadata)} near-field f32 patches", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"SAISIES NEARFIELD FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
