#!/usr/bin/env python3
"""Fetch official IGN RGE Alti elevations for the geographic Saisies route.

This is a reproducible source-data audit, not a route-profile replacement.
The route's existing DEM/profile stays untouched until the RGE samples have
been reviewed.  Requests are kept in one raw JSON cache file per 64-point
batch so a later run can verify or rebuild the derived report without making
another network request.

    python3 tools/fetch_saisies_road_elevations.py

The public endpoint is documented by IGN/Geoportail and returns one elevation
record per requested latitude/longitude.  The returned ``acc`` and source
measure metadata are retained with every point.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import hashlib
import json
import math
import os
import sys
import time
from pathlib import Path
from typing import Any, Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ROUTE = ROOT / "data" / "saisies_geo_route.json"
DEFAULT_CACHE = ROOT / "assets" / "terrain" / "saisies_geo" / "source" / "road_elevations"
DEFAULT_OUTPUT = ROOT / "data" / "saisies_geo_road_elevations.json"
API_URL = "https://data.geopf.fr/altimetrie/1.0/calcul/alti/rest/elevation.json"
PROVENANCE_URL = "https://geoservices.ign.fr/rgealti"
RESOURCE = "ign_rge_alti_wld"
DEFAULT_BATCH_SIZE = 64
DEFAULT_WORKERS = 4
DEFAULT_TIMEOUT_S = 40
RETRIES = 3
USER_AGENT = "ai-scene Saisies RGE Alti batch validation"
LAT_LON_TOLERANCE = 2.0e-7


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--route", type=Path, default=DEFAULT_ROUTE)
    parser.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S)
    parser.add_argument("--force", action="store_true", help="refetch all raw batch responses")
    return parser.parse_args()


def finite(value: Any) -> bool:
    try:
        return math.isfinite(float(value))
    except (TypeError, ValueError):
        return False


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def project_relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(ROOT.resolve()))
    except ValueError:
        return f"external://{path.name}"


def load_route(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    parsed = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(parsed, dict):
        raise ValueError(f"route is not a JSON object: {path}")
    points = parsed.get("points")
    if not isinstance(points, list) or len(points) < 2:
        raise ValueError(f"route has fewer than two points: {path}")
    checked: list[dict[str, Any]] = []
    previous_s = -1.0
    for index, point in enumerate(points):
        if not isinstance(point, dict):
            raise ValueError(f"route point {index} is not an object")
        for key in ("lat", "lon", "s_m", "elevation_m"):
            if not finite(point.get(key)):
                raise ValueError(f"route point {index} has non-finite {key}")
        current_s = float(point["s_m"])
        if current_s <= previous_s:
            raise ValueError(f"route s_m is not strictly increasing at point {index}")
        previous_s = current_s
        checked.append(point)
    if abs(float(checked[0]["s_m"])) > 0.01:
        raise ValueError("route does not start at s_m=0")
    return parsed, checked


def compact_coordinate(value: float) -> str:
    """Keep request coordinates deterministic without adding binary noise."""
    return format(value, ".10f").rstrip("0").rstrip(".")


def request_url(batch: list[dict[str, Any]]) -> str:
    query = {
        "lon": "|".join(compact_coordinate(float(point["lon"])) for point in batch),
        "lat": "|".join(compact_coordinate(float(point["lat"])) for point in batch),
        "resource": RESOURCE,
        "delimiter": "|",
        "indent": "false",
        "measures": "true",
        "zonly": "false",
    }
    return f"{API_URL}?{urlencode(query)}"


def validate_response(raw: bytes, batch: list[dict[str, Any]], label: str) -> dict[str, Any]:
    try:
        parsed = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"{label}: response is not UTF-8 JSON: {exc}") from exc
    if not isinstance(parsed, dict) or not isinstance(parsed.get("elevations"), list):
        raise ValueError(f"{label}: response has no elevations array")
    elevations = parsed["elevations"]
    if len(elevations) != len(batch):
        raise ValueError(f"{label}: got {len(elevations)} records for {len(batch)} points")
    for offset, (requested, result) in enumerate(zip(batch, elevations)):
        if not isinstance(result, dict):
            raise ValueError(f"{label}: elevation {offset} is not an object")
        if not finite(result.get("lat")) or not finite(result.get("lon")):
            raise ValueError(f"{label}: elevation {offset} has non-finite coordinates")
        if abs(float(result["lat"]) - float(requested["lat"])) > LAT_LON_TOLERANCE:
            raise ValueError(f"{label}: latitude order/mismatch at offset {offset}")
        if abs(float(result["lon"]) - float(requested["lon"])) > LAT_LON_TOLERANCE:
            raise ValueError(f"{label}: longitude order/mismatch at offset {offset}")
        if not finite(result.get("z")):
            raise ValueError(f"{label}: elevation {offset} has non-finite z")
    return parsed


def fetch_raw(url: str, timeout_s: float, label: str) -> bytes:
    last_error: Exception | None = None
    for attempt in range(1, RETRIES + 1):
        try:
            request = Request(url, headers={"User-Agent": USER_AGENT})
            with urlopen(request, timeout=timeout_s) as response:
                raw = response.read()
            if len(raw) < 32:
                raise ValueError(f"response is unexpectedly small ({len(raw)} bytes)")
            return raw
        except (HTTPError, URLError, TimeoutError, OSError, ValueError) as exc:
            last_error = exc
            if attempt < RETRIES:
                time.sleep(float(2 ** (attempt - 1)))
    raise RuntimeError(f"{label}: request failed after {RETRIES} attempts: {last_error}")


def read_or_fetch_batch(
    batch_index: int,
    start: int,
    batch: list[dict[str, Any]],
    cache_dir: Path,
    force: bool,
    timeout_s: float,
) -> dict[str, Any]:
    end = start + len(batch)
    cache_path = cache_dir / f"batch_{batch_index:04d}_{start:04d}_{end:04d}.json"
    url = request_url(batch)
    raw: bytes | None = None
    cached = False
    if cache_path.exists() and not force:
        try:
            candidate = cache_path.read_bytes()
            validate_response(candidate, batch, f"cache {cache_path.name}")
            raw = candidate
            cached = True
        except (OSError, ValueError) as exc:
            print(f"cache invalid, refetching {cache_path.name}: {exc}", flush=True)
    if raw is None:
        raw = fetch_raw(url, timeout_s, f"batch {batch_index}")
        validate_response(raw, batch, f"batch {batch_index}")
        cache_dir.mkdir(parents=True, exist_ok=True)
        temporary = cache_path.with_name(cache_path.name + ".part")
        temporary.write_bytes(raw)
        os.replace(temporary, cache_path)
    parsed = validate_response(raw, batch, f"batch {batch_index}")
    return {
        "batch_index": batch_index,
        "start_index": start,
        "end_index": end,
        "count": len(batch),
        "cache_path": cache_path,
        "url": url,
        "raw": raw,
        "payload": parsed,
        "cached": cached,
    }


def batch_ranges(point_count: int, batch_size: int) -> Iterable[tuple[int, int, int]]:
    for batch_index, start in enumerate(range(0, point_count, batch_size)):
        yield batch_index, start, min(start + batch_size, point_count)


def rge_records(
    route_points: list[dict[str, Any]],
    batch_results: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for result in sorted(batch_results, key=lambda item: int(item["batch_index"])):
        batch_points = route_points[int(result["start_index"]): int(result["end_index"])]
        elevations = result["payload"]["elevations"]
        raw_hash = sha256_bytes(result["raw"])
        cache_path: Path = result["cache_path"]
        for index, (route_point, elevation) in enumerate(zip(batch_points, elevations), start=int(result["start_index"])):
            measures = elevation.get("measures")
            primary = measures[0] if isinstance(measures, list) and measures and isinstance(measures[0], dict) else {}
            source_name = str(primary.get("source_name", ""))
            record = {
                "index": index,
                "s_m": float(route_point["s_m"]),
                "lat": float(route_point["lat"]),
                "lon": float(route_point["lon"]),
                "z": float(elevation["z"]),
                "acc": str(elevation.get("acc", primary.get("acc", ""))),
                "source": source_name or "IGN RGE Alti",
                "source_measure": str(primary.get("source_measure", "")),
                "title": str(primary.get("title", "")),
                "rawhash": raw_hash,
                "cache_file": project_relative(cache_path),
            }
            records.append(record)
    records.sort(key=lambda item: int(item["index"]))
    if [int(item["index"]) for item in records] != list(range(len(route_points))):
        raise ValueError("RGE response records are not a complete ordered route")
    return records


def summarize(route_points: list[dict[str, Any]], records: list[dict[str, Any]]) -> dict[str, Any]:
    if len(route_points) != len(records):
        raise ValueError("cannot summarize mismatched route and RGE records")
    z_values = [float(record["z"]) for record in records]
    coarse = [float(point["elevation_m"]) for point in route_points]
    differences = [coarse[index] - z_values[index] for index in range(len(records))]
    grades: list[float] = []
    ascent = 0.0
    descent = 0.0
    for previous, current in zip(records, records[1:]):
        ds = float(current["s_m"]) - float(previous["s_m"])
        if ds <= 0.0:
            raise ValueError("route s spacing is not positive while computing RGE grade")
        dz = float(current["z"]) - float(previous["z"])
        grades.append(dz / ds * 100.0)
        ascent += max(dz, 0.0)
        descent += max(-dz, 0.0)
    worst_index = max(range(len(differences)), key=lambda index: abs(differences[index]))
    rge_min = min(grades)
    rge_max = max(grades)
    rge_rms = math.sqrt(sum(value * value for value in grades) / len(grades))
    diff_rms = math.sqrt(sum(value * value for value in differences) / len(differences))
    worst_point = records[worst_index]
    return {
        "rge_grade": {
            "min_pct": rge_min,
            "max_pct": rge_max,
            "rms_pct": rge_rms,
            "ascent_m": ascent,
            "descent_m": descent,
            "segments": len(grades),
            "segments_abs_gt_25_pct": sum(1 for value in grades if abs(value) > 25.0),
        },
        "coarse_dem_difference": {
            "definition": "coarse_dem_elevation_m - rge_z_m",
            "min_m": min(differences),
            "max_m": max(differences),
            "mean_m": sum(differences) / len(differences),
            "rms_m": diff_rms,
            "max_abs_m": max(abs(value) for value in differences),
            "worst_index": worst_index,
            "worst_s_m": float(worst_point["s_m"]),
            "worst_lat": float(worst_point["lat"]),
            "worst_lon": float(worst_point["lon"]),
            "worst_coarse_elevation_m": coarse[worst_index],
            "worst_rge_z_m": z_values[worst_index],
            "worst_difference_m": differences[worst_index],
        },
        "endpoints": {
            "start": {
                "s_m": float(records[0]["s_m"]),
                "lat": float(records[0]["lat"]),
                "lon": float(records[0]["lon"]),
                "coarse_elevation_m": coarse[0],
                "rge_z_m": z_values[0],
                "difference_m": differences[0],
            },
            "end": {
                "s_m": float(records[-1]["s_m"]),
                "lat": float(records[-1]["lat"]),
                "lon": float(records[-1]["lon"]),
                "coarse_elevation_m": coarse[-1],
                "rge_z_m": z_values[-1],
                "difference_m": differences[-1],
            },
        },
    }


def write_report(
    output: Path,
    route_path: Path,
    route_data: dict[str, Any],
    route_points: list[dict[str, Any]],
    batch_results: list[dict[str, Any]],
    records: list[dict[str, Any]],
    args: argparse.Namespace,
) -> dict[str, Any]:
    batches: list[dict[str, Any]] = []
    for result in sorted(batch_results, key=lambda item: int(item["batch_index"])):
        cache_path: Path = result["cache_path"]
        raw_hash = sha256_bytes(result["raw"])
        batches.append({
            "batch_index": int(result["batch_index"]),
            "start_index": int(result["start_index"]),
            "end_index": int(result["end_index"]),
            "count": int(result["count"]),
            "cache_file": project_relative(cache_path),
            "cache_bytes": len(result["raw"]),
            "raw_sha256": raw_hash,
            "query_url": result["url"],
            "cached": bool(result["cached"]),
        })
    report: dict[str, Any] = {
        "schema_version": 1,
        "id": "saisies_geo_road_elevations",
        "title": "Official IGN RGE Alti elevations sampled along the Saisies geographic route",
        "estimated": True,
        "note": "Raw source elevation audit only; these samples are not yet substituted into the runtime road profile. This is source-data validation, not GPS or camera calibration.",
        "route_file": project_relative(route_path),
        "route_sha256": sha256_file(route_path),
        "source_urls": [API_URL, PROVENANCE_URL],
        "provenance": {
            "provider": "IGN",
            "dataset": "RGE Alti",
            "resource": RESOURCE,
            "endpoint": API_URL,
            "request_parameters": {
                "delimiter": "|",
                "indent": False,
                "measures": True,
                "zonly": False,
                "batch_size": int(args.batch_size),
                "workers": int(args.workers),
            },
            "retrieved_at_utc": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
            "user_agent": USER_AGENT,
            "route_title": str(route_data.get("title", "")),
        },
        "point_count": len(records),
        "batch_size": int(args.batch_size),
        "batches": batches,
        "points": records,
    }
    report["analysis"] = summarize(route_points, records)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".part")
    temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, output)
    return report


def print_summary(report: dict[str, Any], batch_results: list[dict[str, Any]]) -> None:
    analysis = report["analysis"]
    grade = analysis["rge_grade"]
    difference = analysis["coarse_dem_difference"]
    start = analysis["endpoints"]["start"]
    end = analysis["endpoints"]["end"]
    cached = sum(1 for result in batch_results if result["cached"])
    print(
        "SAISIES RGE FETCH PASS points=%d batches=%d cache_hits=%d "
        "rge_grade=%.3f..%.3f%% rms=%.3f%% ascent=%.3fm descent=%.3fm "
        "segments_abs_gt25=%d coarse_minus_rge=%.3f..%.3fm rms=%.3fm max_abs=%.3fm"
        % (
            report["point_count"],
            len(batch_results),
            cached,
            grade["min_pct"],
            grade["max_pct"],
            grade["rms_pct"],
            grade["ascent_m"],
            grade["descent_m"],
            grade["segments_abs_gt_25_pct"],
            difference["min_m"],
            difference["max_m"],
            difference["rms_m"],
            difference["max_abs_m"],
        ),
        flush=True,
    )
    print(
        "RGE endpoints start=%.3fm coarse=%.3f diff=%.3fm end=%.3fm coarse=%.3f diff=%.3fm"
        % (
            start["rge_z_m"], start["coarse_elevation_m"], start["difference_m"],
            end["rge_z_m"], end["coarse_elevation_m"], end["difference_m"],
        ),
        flush=True,
    )
    print(
        "RGE worst_coarse_difference s=%.3fm lat=%.7f lon=%.7f coarse=%.3fm rge=%.3fm diff=%.3fm"
        % (
            difference["worst_s_m"], difference["worst_lat"], difference["worst_lon"],
            difference["worst_coarse_elevation_m"], difference["worst_rge_z_m"], difference["worst_difference_m"],
        ),
        flush=True,
    )


def main() -> int:
    args = parse_args()
    if args.batch_size < 1 or args.batch_size > 64:
        raise SystemExit("--batch-size must be in 1..64 for the IGN endpoint")
    if args.workers < 1 or args.workers > 4:
        raise SystemExit("--workers must be in 1..4")
    if args.timeout <= 0.0:
        raise SystemExit("--timeout must be positive")
    route_path = args.route.resolve()
    cache_dir = args.cache_dir.resolve()
    output = args.output.resolve()
    route_data, route_points = load_route(route_path)
    ranges = list(batch_ranges(len(route_points), args.batch_size))
    print(
        f"Fetching IGN RGE Alti: route_points={len(route_points)} batches={len(ranges)} "
        f"batch_size={args.batch_size} workers={args.workers} cache={project_relative(cache_dir)}",
        flush=True,
    )
    batch_results: list[dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {
            pool.submit(
                read_or_fetch_batch,
                batch_index,
                start,
                route_points[start:end],
                cache_dir,
                args.force,
                args.timeout,
            ): (batch_index, start, end)
            for batch_index, start, end in ranges
        }
        for completed, future in enumerate(concurrent.futures.as_completed(futures), start=1):
            result = future.result()
            batch_results.append(result)
            state = "cache" if result["cached"] else "fetch"
            print(
                f"  {state} batch={result['batch_index']:04d} "
                f"points={result['start_index']}..{result['end_index'] - 1} ({completed}/{len(ranges)})",
                flush=True,
            )
    records = rge_records(route_points, batch_results)
    report = write_report(output, route_path, route_data, route_points, batch_results, records, args)
    print_summary(report, batch_results)
    print(f"Wrote {project_relative(output)} and {len(batch_results)} raw batch cache files", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"SAISIES RGE FETCH FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
