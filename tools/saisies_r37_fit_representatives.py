#!/usr/bin/env python3
"""Validate and compile the R37 representative route geometry draft.

The tool uses native R37 trajectory samples as the base for interpolation and
never launches Godot or rewrites release data.  It writes only a provisional
runtime-schema JSON under the round37 analysis directory; that file is an
input for the isolated representative scene, not an acceptance or bake step.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "data/saisies_r37_representatives.json"
DEFAULT_NATIVE = ROOT / "export/saisies/review/round37_route_diagnosis/geometry_audit/capture.json"
DEFAULT_ROUTE = ROOT / "data/saisies_geo_route.json"
DEFAULT_COMPILED_OUTPUT = ROOT / "export/saisies/review/round37_route_diagnosis/analysis/saisies_r37_representatives_compiled.json"
ROUTE_END_M = 14615.087922
ANGLE_EPS_DEG = 1e-3


class FitError(RuntimeError):
    """Raised when the draft cannot be checked against its native base."""


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise FitError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise FitError(f"JSON root must be an object: {path}")
    return value


def finite(value: Any) -> bool:
    return isinstance(value, (int, float)) and math.isfinite(float(value))


def require_finite(value: Any, label: str) -> float:
    if not finite(value):
        raise FitError(f"{label} must be a finite number")
    return float(value)


def angle_delta_deg(target: float, base: float) -> float:
    """Shortest signed target-base delta in degrees."""

    return (target - base + 180.0) % 360.0 - 180.0


def wrap_heading(value: float) -> float:
    return (value + 180.0) % 360.0 - 180.0


def smoothstep(value: float) -> float:
    x = max(0.0, min(1.0, value))
    return x * x * (3.0 - 2.0 * x)


def lerp(a: float, b: float, weight: float) -> float:
    return a + (b - a) * weight


def lerp_angle_deg(a: float, b: float, weight: float) -> float:
    return a + angle_delta_deg(b, a) * weight


def vector_lerp(a: list[float], b: list[float], weight: float) -> list[float]:
    return [lerp(float(x), float(y), weight) for x, y in zip(a, b)]


def native_rows(native: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    records = native.get("records")
    if not isinstance(records, list) or not records:
        raise FitError("native trajectory has no records")
    groups: dict[str, list[dict[str, Any]]] = {}
    for record in records:
        if not isinstance(record, dict) or record.get("mode") != "baseline":
            continue
        scene_id = str(record.get("target_scene_id", "")).strip()
        if not scene_id:
            continue
        station = require_finite(record.get("station_m"), f"native {scene_id} station_m")
        heading = require_finite(record.get("heading_deg"), f"native {scene_id} heading_deg")
        grade = require_finite(record.get("grade_pct"), f"native {scene_id} grade_pct")
        position = record.get("route_position")
        if not isinstance(position, list) or len(position) != 3 or not all(finite(x) for x in position):
            raise FitError(f"native {scene_id} station {station} has no finite route_position")
        groups.setdefault(scene_id, []).append(
            {
                "station_m": station,
                "heading_deg": heading,
                "grade_pct": grade,
                "route_position": [float(x) for x in position],
            }
        )
    for scene_id, rows in groups.items():
        rows.sort(key=lambda row: row["station_m"])
        deduped: list[dict[str, Any]] = []
        for row in rows:
            if deduped and abs(row["station_m"] - deduped[-1]["station_m"]) < 1e-4:
                continue
            deduped.append(row)
        groups[scene_id] = deduped
    return groups


def _extrapolate_pair(left: dict[str, Any], right: dict[str, Any], station: float) -> dict[str, Any]:
    a = float(left["station_m"])
    b = float(right["station_m"])
    # The current native probe is intentionally local.  Carry the nearest
    # measured heading/grade beyond its edge instead of linearly extending a
    # noisy 25m grade sample into an artificial 50% slope.  Position still
    # follows the measured endpoint tangent so the compiled sample remains a
    # station-indexed native-base estimate and is explicitly marked below.
    edge = left if station < a else right
    if station < a:
        derivative = [
            (float(right["route_position"][index]) - float(left["route_position"][index])) / max(b - a, 1e-6)
            for index in range(3)
        ]
        distance = station - a
    else:
        derivative = [
            (float(right["route_position"][index]) - float(left["route_position"][index])) / max(b - a, 1e-6)
            for index in range(3)
        ]
        distance = station - b
    return {
        "station_m": station,
        "heading_deg": float(edge["heading_deg"]),
        "grade_pct": float(edge["grade_pct"]),
        "route_position": [float(edge["route_position"][index]) + derivative[index] * distance for index in range(3)],
        "native_extrapolated": True,
    }


def interpolate(rows: list[dict[str, Any]], station: float, *, allow_extrapolation: bool = False) -> dict[str, Any]:
    if not rows:
        raise FitError("cannot interpolate an empty native row group")
    outside = station < rows[0]["station_m"] - 1e-4 or station > rows[-1]["station_m"] + 1e-4
    if outside and not allow_extrapolation:
        raise FitError(
            f"station {station:.4f} is outside native probe range "
            f"{rows[0]['station_m']:.4f}..{rows[-1]['station_m']:.4f}"
        )
    if outside:
        if len(rows) < 2:
            raise FitError("at least two native rows are required for extrapolation")
        return _extrapolate_pair(rows[0], rows[1], station) if station < rows[0]["station_m"] else _extrapolate_pair(rows[-2], rows[-1], station)
    if station <= rows[0]["station_m"]:
        result = dict(rows[0])
        result["native_extrapolated"] = False
        return result
    if station >= rows[-1]["station_m"]:
        result = dict(rows[-1])
        result["native_extrapolated"] = False
        return result
    for left, right in zip(rows, rows[1:]):
        a = float(left["station_m"])
        b = float(right["station_m"])
        if a <= station <= b:
            weight = 0.0 if b <= a else (station - a) / (b - a)
            return {
                "station_m": station,
                "heading_deg": lerp_angle_deg(float(left["heading_deg"]), float(right["heading_deg"]), weight),
                "grade_pct": lerp(float(left["grade_pct"]), float(right["grade_pct"]), weight),
                "route_position": vector_lerp(left["route_position"], right["route_position"], weight),
                "native_extrapolated": False,
            }
    raise FitError(f"could not interpolate native station {station}")


def piecewise_smooth(knots: list[dict[str, Any]], station: float, value_key: str) -> float:
    if not knots:
        raise FitError(f"empty knot list for {value_key}")
    if station <= float(knots[0]["station_m"]):
        return float(knots[0][value_key])
    if station >= float(knots[-1]["station_m"]):
        return float(knots[-1][value_key])
    for left, right in zip(knots, knots[1:]):
        a = float(left["station_m"])
        b = float(right["station_m"])
        if a <= station <= b:
            weight = 0.0 if b <= a else (station - a) / (b - a)
            return lerp(float(left[value_key]), float(right[value_key]), smoothstep(weight))
    raise FitError(f"station {station} is not covered by {value_key} knots")


def piecewise_grade_with_blend(
    rows: list[dict[str, Any]], segment: dict[str, Any], station: float
) -> float:
    window = segment["station_window"]
    edit_start = float(window["edit_start_m"])
    edit_end = float(window["edit_end_m"])
    outer_start = float(window["outer_start_m"])
    outer_end = float(window["outer_end_m"])
    base_grade = float(interpolate(rows, station, allow_extrapolation=True)["grade_pct"])
    grades = segment["grade_knots_pct"]
    if station < edit_start:
        if station <= outer_start:
            return base_grade
        first = float(grades[0]["target_pct"])
        weight = smoothstep((station - outer_start) / (edit_start - outer_start))
        return lerp(base_grade, first, weight)
    if station > edit_end:
        if station >= outer_end:
            return base_grade
        last = float(grades[-1]["target_pct"])
        weight = smoothstep((outer_end - station) / (outer_end - edit_end))
        return lerp(base_grade, last, weight)
    return piecewise_smooth(grades, station, "target_pct")


def source_grade_contract(segment: dict[str, Any]) -> dict[str, Any]:
    source_sequence = segment.get("source_sequence")
    if not isinstance(source_sequence, dict):
        raise FitError(f"{segment.get('id', '<segment>')} source_sequence is missing")
    contract = source_sequence.get("grade_contract")
    if not isinstance(contract, dict):
        raise FitError(f"{segment.get('id', '<segment>')} source_sequence.grade_contract is missing")
    sign = str(contract.get("sign", "")).strip().lower()
    if sign not in {"positive", "negative"}:
        raise FitError(f"{segment.get('id', '<segment>')} grade contract sign must be positive or negative")
    minimum = require_finite(contract.get("min_pct"), f"{segment.get('id', '<segment>')} grade_contract.min_pct")
    maximum = require_finite(contract.get("max_pct"), f"{segment.get('id', '<segment>')} grade_contract.max_pct")
    if minimum > maximum:
        raise FitError(f"{segment.get('id', '<segment>')} grade contract min_pct exceeds max_pct")
    if sign == "positive" and minimum <= 0.0:
        raise FitError(f"{segment.get('id', '<segment>')} positive grade contract must stay above zero")
    if sign == "negative" and maximum >= 0.0:
        raise FitError(f"{segment.get('id', '<segment>')} negative grade contract must stay below zero")
    if not str(contract.get("source_basis", "")).strip():
        raise FitError(f"{segment.get('id', '<segment>')} grade contract needs source_basis")
    return {"sign": sign, "min_pct": minimum, "max_pct": maximum, "source_basis": contract["source_basis"]}


def absolute_heading_knots(rows: list[dict[str, Any]], segment: dict[str, Any]) -> list[dict[str, float]]:
    """Build target absolute headings once, then spline those values.

    Adding a delta to every noisy native sample would reintroduce probe noise.
    Each authored knot is therefore based on its native heading once, and the
    resulting absolute values are interpolated directly for runtime samples.
    """

    result: list[dict[str, float]] = []
    previous: float | None = None
    for knot in segment["heading_delta_knots_deg"]:
        station = require_finite(knot.get("station_m"), f"{segment['id']} heading knot station")
        native = interpolate(rows, station, allow_extrapolation=True)
        raw = wrap_heading(float(native["heading_deg"]) + float(knot["delta_deg"]))
        absolute = raw if previous is None else previous + angle_delta_deg(raw, previous)
        result.append({"station_m": station, "absolute_heading_deg": absolute})
        previous = absolute
    return result


def piecewise_absolute_heading(knots: list[dict[str, float]], station: float) -> float:
    return wrap_heading(piecewise_smooth(knots, station, "absolute_heading_deg"))


def overall_orientation_weight(segment: dict[str, Any], station: float) -> float:
    """Return a C1 source-yaw weight: zero at outer bounds, one in the core."""

    window = segment["station_window"]
    outer_start = float(window["outer_start_m"])
    edit_start = float(window["edit_start_m"])
    edit_end = float(window["edit_end_m"])
    outer_end = float(window["outer_end_m"])
    if station <= outer_start or station >= outer_end:
        return 0.0
    if station < edit_start:
        return smoothstep((station - outer_start) / max(edit_start - outer_start, 1e-6))
    if station <= edit_end:
        return 1.0
    return smoothstep((outer_end - station) / max(outer_end - edit_end, 1e-6))


def orientation_settings(segment: dict[str, Any]) -> dict[str, Any]:
    raw = segment.get("overall_orientation", {})
    if not isinstance(raw, dict):
        raise FitError(f"{segment.get('id', '<segment>')} overall_orientation must be an object")
    enabled = bool(raw.get("enabled", True))
    if not enabled:
        return {
            "enabled": False,
            "mode": "disabled",
            "initial_deg": 0.0,
            "search_min_deg": 0.0,
            "search_max_deg": 0.0,
            "source_compass": False,
        }
    initial = require_finite(raw.get("initial_deg"), f"{segment.get('id', '<segment>')} overall_orientation.initial_deg")
    half_range = require_finite(raw.get("search_half_range_deg", 20.0), f"{segment.get('id', '<segment>')} overall_orientation.search_half_range_deg")
    max_abs = require_finite(raw.get("max_abs_deg", 45.0), f"{segment.get('id', '<segment>')} overall_orientation.max_abs_deg")
    if half_range <= 0.0 or max_abs <= 0.0 or abs(initial) > max_abs + 1e-6:
        raise FitError(f"{segment.get('id', '<segment>')} overall_orientation bounds are invalid")
    if bool(raw.get("source_compass", True)):
        raise FitError(f"{segment.get('id', '<segment>')} overall_orientation must remain compass-free")
    search_min = max(-max_abs, initial - half_range)
    search_max = min(max_abs, initial + half_range)
    return {
        "enabled": True,
        "mode": str(raw.get("mode", "free_source_yaw")),
        "initial_deg": initial,
        "search_min_deg": search_min,
        "search_max_deg": search_max,
        "source_compass": False,
    }


def oriented_heading_deg(
    absolute_knots: list[dict[str, float]], segment: dict[str, Any], station: float, overall_yaw_deg: float
) -> float:
    return wrap_heading(piecewise_absolute_heading(absolute_knots, station) + overall_yaw_deg * overall_orientation_weight(segment, station))


def _xz_endpoint_residual(
    rows: list[dict[str, Any]], segment: dict[str, Any], overall_yaw_deg: float
) -> tuple[list[float], float]:
    """Return the unanchored horizontal endpoint residual for one source yaw.

    The outer endpoints are still anchored to the native route when compiling
    samples.  This pre-anchor residual is the objective for the free yaw so the
    yaw minimizes the amount of position correction that the boundary blend has
    to absorb.  It deliberately uses only native route positions and the
    authored heading/grade fit; no offline world coordinates are introduced.
    """

    window = segment["station_window"]
    start = float(window["outer_start_m"])
    end = float(window["outer_end_m"])
    closure = closure_report(rows, segment)
    absolute_knots = absolute_heading_knots(rows, segment)
    stations = station_grid(start, end, 10.0)
    headings = [oriented_heading_deg(absolute_knots, segment, station, overall_yaw_deg) for station in stations]
    grades = [closed_grade_with_blend(rows, segment, station, closure) for station in stations]
    position = list(interpolate(rows, start, allow_extrapolation=True)["route_position"])
    for index in range(1, len(stations)):
        span = stations[index] - stations[index - 1]
        mean_heading = lerp_angle_deg(headings[index - 1], headings[index], 0.5)
        mean_grade = 0.5 * (grades[index - 1] + grades[index])
        forward = [math.sin(math.radians(mean_heading)), 0.0, -math.cos(math.radians(mean_heading))]
        position = vec3_add(
            position,
            vec3_add(vec3_scale(forward, span), [0.0, mean_grade * span / 100.0, 0.0]),
        )
    native_end = list(interpolate(rows, end, allow_extrapolation=True)["route_position"])
    residual = [native_end[index] - position[index] for index in range(3)]
    xz = [residual[0], residual[2]]
    return xz, math.hypot(xz[0], xz[1])


def optimize_overall_orientation(rows: list[dict[str, Any]], segment: dict[str, Any]) -> dict[str, Any]:
    """Choose a compass-free source yaw with an exact outer=0/core=1 C1 blend."""

    settings = orientation_settings(segment)
    if not settings["enabled"]:
        vector, residual = _xz_endpoint_residual(rows, segment, 0.0)
        return {
            **settings,
            "optimized_deg": 0.0,
            "pre_xz_residual_vector_m": vector,
            "pre_xz_residual_m": residual,
            "post_xz_residual_vector_m": vector,
            "post_xz_residual_m": residual,
            "initial_xz_residual_vector_m": vector,
            "initial_xz_residual_m": residual,
            "reduction_m": 0.0,
            "blend_contract": "overall yaw weight is zero because orientation is disabled",
        }

    search_min = float(settings["search_min_deg"])
    search_max = float(settings["search_max_deg"])
    initial = float(settings["initial_deg"])
    evaluations: dict[float, tuple[list[float], float]] = {}

    def evaluate(yaw: float) -> tuple[list[float], float]:
        bounded = max(search_min, min(search_max, float(yaw)))
        key = round(bounded, 12)
        if key not in evaluations:
            evaluations[key] = _xz_endpoint_residual(rows, segment, bounded)
        return evaluations[key]

    # A coarse pass protects the one-dimensional refinement from assuming that
    # the authored bend sequence is convex over the full search interval.
    coarse_count = 80
    coarse_step = (search_max - search_min) / float(coarse_count)
    candidates = [search_min + coarse_step * index for index in range(coarse_count + 1)]
    candidates.extend([initial, 0.0])
    best_yaw = min(candidates, key=lambda yaw: evaluate(yaw)[1])
    best_value = evaluate(best_yaw)[1]
    # Refine around the best coarse cell.  The final report retains the exact
    # sampled vector, rather than an opaque optimizer score.
    half_cell = max(coarse_step, 1e-3)
    left = max(search_min, best_yaw - half_cell)
    right = min(search_max, best_yaw + half_cell)
    golden_ratio = (math.sqrt(5.0) - 1.0) * 0.5
    for _ in range(48):
        first = right - golden_ratio * (right - left)
        second = left + golden_ratio * (right - left)
        if evaluate(first)[1] <= evaluate(second)[1]:
            right = second
        else:
            left = first
    refined = (left + right) * 0.5
    if evaluate(refined)[1] < best_value:
        best_yaw = refined
        best_value = evaluate(refined)[1]
    zero_vector, zero_residual = evaluate(0.0)
    initial_vector, initial_residual = evaluate(initial)
    final_vector, final_residual = evaluate(best_yaw)
    return {
        **settings,
        "optimized_deg": best_yaw,
        "pre_xz_residual_vector_m": zero_vector,
        "pre_xz_residual_m": zero_residual,
        "initial_xz_residual_vector_m": initial_vector,
        "initial_xz_residual_m": initial_residual,
        "post_xz_residual_vector_m": final_vector,
        "post_xz_residual_m": final_residual,
        "reduction_m": zero_residual - final_residual,
        "blend_contract": "C1 smoothstep: outer boundaries weight 0, edit core weight 1",
    }


def blend_bump(station: float, start: float, end: float) -> float:
    """A zero-at-bounds C1 bump used only inside one outer blend window."""

    if station <= start or station >= end or end <= start:
        return 0.0
    x = (station - start) / (end - start)
    return 4.0 * x * (1.0 - x)


def integrate_function(start: float, end: float, step: float, function: Any) -> float:
    if end <= start:
        return 0.0
    station = start
    total = 0.0
    while station < end - 1e-6:
        next_station = min(end, station + step)
        total += 0.5 * (float(function(station)) + float(function(next_station))) * (next_station - station)
        station = next_station
    return total


def raw_integrated_height_residual(rows: list[dict[str, Any]], segment: dict[str, Any]) -> float:
    window = segment["station_window"]
    start = float(window["outer_start_m"])
    end = float(window["outer_end_m"])
    native_start_y = float(interpolate(rows, start, allow_extrapolation=True)["route_position"][1])
    native_end_y = float(interpolate(rows, end, allow_extrapolation=True)["route_position"][1])
    integrated = native_start_y + integrate_function(
        start,
        end,
        2.5,
        lambda station: piecewise_grade_with_blend(rows, segment, station) / 100.0,
    )
    return integrated - native_end_y


def closure_report(rows: list[dict[str, Any]], segment: dict[str, Any]) -> dict[str, Any]:
    """Solve the endpoint residual through both long outer blend windows."""

    window = segment["station_window"]
    outer_start = float(window["outer_start_m"])
    edit_start = float(window["edit_start_m"])
    edit_end = float(window["edit_end_m"])
    outer_end = float(window["outer_end_m"])
    raw_residual = raw_integrated_height_residual(rows, segment)
    bump_integral_pct_m = integrate_function(
        outer_start,
        outer_end,
        2.5,
        lambda station: blend_bump(station, outer_start, edit_start) + blend_bump(station, edit_end, outer_end),
    )
    bump_integral_m_per_pct = bump_integral_pct_m / 100.0
    amplitude = 0.0 if abs(bump_integral_m_per_pct) < 1e-9 else -raw_residual / bump_integral_m_per_pct

    def closed_grade(station: float) -> float:
        raw = piecewise_grade_with_blend(rows, segment, station)
        bump = blend_bump(station, outer_start, edit_start) + blend_bump(station, edit_end, outer_end)
        return raw + amplitude * bump

    max_blend_grade = 0.0
    max_blend_station = outer_start
    station = outer_start
    while station <= outer_end + 1e-6:
        if station <= edit_start + 1e-6 or station >= edit_end - 1e-6:
            value = abs(closed_grade(station))
            if value > max_blend_grade:
                max_blend_grade = value
                max_blend_station = station
        station += 2.5
    native_min = float(rows[0]["station_m"])
    native_max = float(rows[-1]["station_m"])
    coverage = "full" if outer_start >= native_min - 1e-4 and outer_end <= native_max + 1e-4 else "partial_extrapolated"
    return {
        "raw_integrated_height_residual_m": raw_residual,
        "height_closure_peak_correction_pct": amplitude,
        "max_blend_grade_pct": max_blend_grade,
        "max_blend_grade_station_m": max_blend_station,
        "native_probe_range_m": [native_min, native_max],
        "native_coverage": coverage,
        "closure_policy": "symmetric C1 bump in the two expanded outer blend windows; no short height return",
    }


def closed_grade_with_blend(
    rows: list[dict[str, Any]], segment: dict[str, Any], station: float, closure: dict[str, Any]
) -> float:
    window = segment["station_window"]
    bump = blend_bump(station, float(window["outer_start_m"]), float(window["edit_start_m"]))
    bump += blend_bump(station, float(window["edit_end_m"]), float(window["outer_end_m"]))
    return piecewise_grade_with_blend(rows, segment, station) + float(closure["height_closure_peak_correction_pct"]) * bump


def source_station_for_time(route: dict[str, Any], seconds: float) -> float:
    checkpoints = route.get("checkpoints")
    if not isinstance(checkpoints, list) or len(checkpoints) < 2:
        raise FitError("route data has no checkpoints for source time mapping")
    for left, right in zip(checkpoints, checkpoints[1:]):
        t0 = float(left["video_seconds"])
        t1 = float(right["video_seconds"])
        if t0 <= seconds <= t1:
            weight = 0.0 if t1 <= t0 else (seconds - t0) / (t1 - t0)
            return lerp(float(left["distance_m"]), float(right["distance_m"]), weight)
    raise FitError(f"source time {seconds} is outside route checkpoint mapping")


def require_sorted_knots(knots: Any, name: str, *, within: tuple[float, float] | None = None) -> None:
    if not isinstance(knots, list) or len(knots) < 2:
        raise FitError(f"{name} must contain at least two knots")
    previous: float | None = None
    for index, knot in enumerate(knots):
        if not isinstance(knot, dict):
            raise FitError(f"{name}[{index}] must be an object")
        station = require_finite(knot.get("station_m"), f"{name}[{index}].station_m")
        if previous is not None and station <= previous:
            raise FitError(f"{name} station values must be strictly increasing")
        if within is not None and not within[0] - 1e-4 <= station <= within[1] + 1e-4:
            raise FitError(f"{name}[{index}] station {station} is outside {within}")
        previous = station


def validate(config: dict[str, Any], route: dict[str, Any], groups: dict[str, list[dict[str, Any]]]) -> list[str]:
    if config.get("schema_version") != 1 or config.get("kind") != "saisies_r37_route_geometry_representatives":
        raise FitError("unexpected representative config schema or kind")
    if config.get("status") != "draft_for_integrate":
        raise FitError("representative config must remain draft_for_integrate")
    for key in ("visual_acceptance", "formal_integration_allowed", "not_validated"):
        if config.get(key) is not (False if key != "not_validated" else True):
            raise FitError(f"representative config has invalid {key}")
    provenance = config.get("provenance")
    if not isinstance(provenance, dict) or provenance.get("source_estimated") is not True or provenance.get("gps") is not False:
        raise FitError("provenance must say source_estimated=true and gps=false")
    contract = config.get("route_contract")
    if not isinstance(contract, dict):
        raise FitError("route_contract is missing")
    station_end = require_finite(contract.get("station_end_m"), "route_contract.station_end_m")
    if abs(station_end - ROUTE_END_M) > 0.25:
        raise FitError("route endpoint does not match the frozen route")
    route_length = require_finite(route.get("length_m"), "route.length_m")
    if abs(route_length - station_end) > 0.25:
        raise FitError("native route data and candidate station endpoint disagree")
    segments = config.get("segments")
    if not isinstance(segments, list) or [s.get("id") for s in segments if isinstance(s, dict)] != ["S06", "S10", "S12"]:
        raise FitError("segments must be exactly S06, S10, S12 in order")
    scope = config.get("scope")
    if not isinstance(scope, dict):
        raise FitError("scope is missing")
    preserved_ids = scope.get("preserved_neighbor_scene_ids")
    if preserved_ids != ["S05", "S07", "S09", "S11", "S13"]:
        raise FitError("scope must preserve S05/S07/S09/S11/S13")
    terminal_station = require_finite(scope.get("untouched_terminal_station_m"), "scope.untouched_terminal_station_m")
    if abs(terminal_station - station_end) > 0.25:
        raise FitError("untouched terminal station differs from route endpoint")
    neighbor_anchors = scope.get("preserved_neighbor_scene_anchors")
    if not isinstance(neighbor_anchors, list) or len(neighbor_anchors) != len(preserved_ids):
        raise FitError("scope must list all preserved neighbor anchors")
    for neighbor in neighbor_anchors:
        if not isinstance(neighbor, dict) or str(neighbor.get("scene_id", "")) not in preserved_ids:
            raise FitError("scope contains an unknown preserved neighbor anchor")
        source_time = require_finite(neighbor.get("source_time_s"), "preserved neighbor source_time_s")
        station = require_finite(neighbor.get("station_m"), "preserved neighbor station_m")
        mapped = source_station_for_time(route, source_time)
        if abs(mapped - station) > 1.5:
            raise FitError(f"preserved neighbor {neighbor.get('scene_id')} does not match estimated mapping")
    previous_outer_end = -math.inf
    warnings: list[str] = []
    for segment in segments:
        if not isinstance(segment, dict):
            raise FitError("each segment must be an object")
        scene_id = str(segment.get("scene_id", "")).strip()
        if scene_id not in groups:
            raise FitError(f"native trajectory has no baseline records for {scene_id}")
        window = segment.get("station_window")
        if not isinstance(window, dict):
            raise FitError(f"{scene_id} station_window is missing")
        edit_start = require_finite(window.get("edit_start_m"), f"{scene_id}.edit_start_m")
        edit_end = require_finite(window.get("edit_end_m"), f"{scene_id}.edit_end_m")
        outer_start = require_finite(window.get("outer_start_m"), f"{scene_id}.outer_start_m")
        outer_end = require_finite(window.get("outer_end_m"), f"{scene_id}.outer_end_m")
        blend_width = require_finite(window.get("boundary_blend_range_m"), f"{scene_id}.boundary_blend_range_m")
        if not outer_start < edit_start < edit_end < outer_end:
            raise FitError(f"{scene_id} station windows are not strictly nested")
        if abs((edit_start - outer_start) - blend_width) > 0.01 or abs((outer_end - edit_end) - blend_width) > 0.01:
            raise FitError(f"{scene_id} blend width does not match outer window")
        if outer_start <= previous_outer_end:
            raise FitError(f"{scene_id} outer window overlaps the previous segment")
        previous_outer_end = outer_end
        if edit_start < 0.0 or outer_end > station_end:
            raise FitError(f"{scene_id} window is outside the route")
        orientation = orientation_settings(segment)
        orientation_weight_checks = {
            "outer_start": overall_orientation_weight(segment, outer_start),
            "edit_start": overall_orientation_weight(segment, edit_start),
            "edit_end": overall_orientation_weight(segment, edit_end),
            "outer_end": overall_orientation_weight(segment, outer_end),
        }
        if abs(orientation_weight_checks["outer_start"]) > 1e-8 or abs(orientation_weight_checks["outer_end"]) > 1e-8:
            raise FitError(f"{scene_id} overall orientation must be zero at both outer boundaries")
        if orientation["enabled"] and (
            abs(orientation_weight_checks["edit_start"] - 1.0) > 1e-8
            or abs(orientation_weight_checks["edit_end"] - 1.0) > 1e-8
        ):
            raise FitError(f"{scene_id} overall orientation must be one across the edit core")
        anchor = segment.get("baseline_anchor")
        if not isinstance(anchor, dict):
            raise FitError(f"{scene_id}.baseline_anchor is missing")
        anchor_station = require_finite(anchor.get("station_m"), f"{scene_id}.baseline_anchor.station_m")
        if not edit_start < anchor_station < edit_end:
            raise FitError(f"{scene_id} anchor is outside its edit window")
        native_anchor = interpolate(groups[scene_id], anchor_station)
        for key in ("native_heading_deg", "native_grade_pct"):
            expected = require_finite(anchor.get(key), f"{scene_id}.baseline_anchor.{key}")
            actual = native_anchor["heading_deg"] if key == "native_heading_deg" else native_anchor["grade_pct"]
            tolerance = 0.2 if key == "native_heading_deg" else 0.05
            if abs(angle_delta_deg(actual, expected) if key == "native_heading_deg" else actual - expected) > tolerance:
                raise FitError(f"{scene_id} native anchor {key} disagrees with trajectory")
        source_sequence = segment.get("source_sequence")
        if not isinstance(source_sequence, dict):
            raise FitError(f"{scene_id}.source_sequence is missing")
        grade_contract = source_grade_contract(segment)
        trace_rows = source_sequence.get("time_to_station_estimates")
        if not isinstance(trace_rows, list) or len(trace_rows) < 2:
            raise FitError(f"{scene_id} needs source time-to-station trace rows")
        previous_time = -math.inf
        previous_station = -math.inf
        for index, trace in enumerate(trace_rows):
            if not isinstance(trace, dict):
                raise FitError(f"{scene_id}.source_sequence[{index}] must be an object")
            seconds = require_finite(trace.get("source_time_s"), f"{scene_id} source time")
            station = require_finite(trace.get("station_m"), f"{scene_id} source station")
            if seconds <= previous_time or station <= previous_station:
                raise FitError(f"{scene_id} source trace must be strictly increasing")
            mapped = source_station_for_time(route, seconds)
            if abs(mapped - station) > 1.5:
                raise FitError(f"{scene_id} source trace {seconds}s does not match the existing estimated mapping")
            previous_time = seconds
            previous_station = station
        heading_knots = segment.get("heading_delta_knots_deg")
        require_sorted_knots(heading_knots, f"{scene_id}.heading_delta_knots_deg", within=(outer_start, outer_end))
        if abs(float(heading_knots[0]["delta_deg"])) > ANGLE_EPS_DEG or abs(float(heading_knots[-1]["delta_deg"])) > ANGLE_EPS_DEG:
            raise FitError(f"{scene_id} heading correction must be zero at both outer boundaries")
        for index, knot in enumerate(heading_knots):
            require_finite(knot.get("delta_deg"), f"{scene_id}.heading_delta_knots_deg[{index}].delta_deg")
        grade_knots = segment.get("grade_knots_pct")
        require_sorted_knots(grade_knots, f"{scene_id}.grade_knots_pct", within=(edit_start, edit_end))
        for index, knot in enumerate(grade_knots):
            grade = require_finite(knot.get("target_pct"), f"{scene_id}.grade_knots_pct[{index}].target_pct")
            if grade < grade_contract["min_pct"] - 1e-4 or grade > grade_contract["max_pct"] + 1e-4:
                raise FitError(
                    f"{scene_id} grade knot {grade} is outside the {grade_contract['min_pct']:+.1f}..{grade_contract['max_pct']:+.1f}% source band"
                )
            if grade_contract["sign"] == "positive" and grade <= 0.0:
                raise FitError(f"{scene_id} source grade sign assertion rejected non-positive target {grade}")
            if grade_contract["sign"] == "negative" and grade >= 0.0:
                raise FitError(f"{scene_id} source grade sign assertion rejected non-negative target {grade}")
        height_knots = segment.get("road_height_delta_knots_m")
        require_sorted_knots(height_knots, f"{scene_id}.road_height_delta_knots_m", within=(outer_start, outer_end))
        for index, knot in enumerate(height_knots):
            require_finite(knot.get("delta_m"), f"{scene_id}.road_height_delta_knots_m[{index}].delta_m")
        if abs(float(height_knots[0]["delta_m"])) > 0.01 or abs(float(height_knots[-1]["delta_m"])) > 0.01:
            raise FitError(f"{scene_id} road height correction must return to zero at both outer boundaries")
        composition = segment.get("composition_contract")
        if not isinstance(composition, dict) or not composition.get("route_frame"):
            raise FitError(f"{scene_id} composition contract needs an explicit route frame")
        # A fitted target grade can have a non-zero integral relative to the
        # native route.  This is a review warning, never a reason to hide a
        # vertical mismatch by changing the camera.
        closure = closure_report(groups[scene_id], segment)
        if closure["native_coverage"] != "full":
            warnings.append(
                f"{scene_id}: expanded {window['outer_start_m']:.1f}..{window['outer_end_m']:.1f}m blend exceeds native probe range; compiled geometry holds edge grade/heading and linearly extrapolates endpoint position for review only"
            )
        if abs(float(closure["height_closure_peak_correction_pct"])) > 12.0:
            warnings.append(
                f"{scene_id}: height closure peak correction is {closure['height_closure_peak_correction_pct']:+.2f}% (max closed blend grade {closure['max_blend_grade_pct']:.2f}%); native-ground audit required"
            )
        elif float(closure["max_blend_grade_pct"]) > 12.0:
            warnings.append(
                f"{scene_id}: maximum closed grade in the expanded blend is {closure['max_blend_grade_pct']:.2f}%; review native ground before acceptance"
            )
        for neighbor in neighbor_anchors:
            neighbor_station = float(neighbor["station_m"])
            if outer_start <= neighbor_station <= outer_end:
                raise FitError(f"{scene_id} outer window captures preserved neighbor {neighbor['scene_id']}")
    return warnings


def integrated_height_residual(rows: list[dict[str, Any]], segment: dict[str, Any]) -> float:
    return raw_integrated_height_residual(rows, segment)


def station_grid(start: float, end: float, step: float) -> list[float]:
    values: list[float] = []
    station = start
    while station < end - 1e-6:
        values.append(station)
        station += step
    if not values or abs(values[-1] - end) > 1e-5:
        values.append(end)
    return values


def preview_segment(rows: list[dict[str, Any]], segment: dict[str, Any]) -> dict[str, Any]:
    window = segment["station_window"]
    start = float(window["outer_start_m"])
    end = float(window["outer_end_m"])
    absolute_knots = absolute_heading_knots(rows, segment)
    orientation = optimize_overall_orientation(rows, segment)
    optimized_yaw = float(orientation["optimized_deg"])
    height_knots = segment["road_height_delta_knots_m"]
    closure = closure_report(rows, segment)
    samples: list[dict[str, Any]] = []
    for station in station_grid(start, end, 25.0):
        base = interpolate(rows, station, allow_extrapolation=True)
        target_heading = oriented_heading_deg(absolute_knots, segment, station, optimized_yaw)
        delta = angle_delta_deg(target_heading, float(base["heading_deg"]))
        height_delta = piecewise_smooth(height_knots, station, "delta_m")
        raw_grade = piecewise_grade_with_blend(rows, segment, station)
        closed_grade = closed_grade_with_blend(rows, segment, station, closure)
        samples.append(
            {
                "station_m": station,
                "native_heading_deg": float(base["heading_deg"]),
                "target_heading_deg": target_heading,
                "heading_delta_deg": delta,
                "overall_orientation_weight": overall_orientation_weight(segment, station),
                "native_grade_pct": float(base["grade_pct"]),
                "raw_target_grade_pct": raw_grade,
                "target_grade_pct": closed_grade,
                "closure_grade_correction_pct": closed_grade - raw_grade,
                "native_height_m": float(base["route_position"][1]),
                "height_delta_hint_m": height_delta,
                "native_extrapolated": bool(base.get("native_extrapolated", False)),
            }
        )
    return {
        "id": segment["id"],
        "outer_window_m": [start, end],
        "sample_count": len(samples),
        "preview_samples": samples,
        "absolute_heading_knots": absolute_knots,
        "overall_orientation": orientation,
        "integrated_height_residual_m": closure["raw_integrated_height_residual_m"],
        "height_closure_peak_correction_pct": closure["height_closure_peak_correction_pct"],
        "max_blend_grade_pct": closure["max_blend_grade_pct"],
        "max_blend_grade_station_m": closure["max_blend_grade_station_m"],
        "native_probe_range_m": closure["native_probe_range_m"],
        "native_coverage": closure["native_coverage"],
    }


def vec3_add(a: list[float], b: list[float]) -> list[float]:
    return [float(a[index]) + float(b[index]) for index in range(3)]


def vec3_scale(a: list[float], scale: float) -> list[float]:
    return [float(value) * scale for value in a]


def derive_actual_geometry(stations: list[float], positions: list[list[float]]) -> dict[str, list[Any]]:
    """Derive runtime heading, grade and tangent from the final positions."""

    if len(stations) != len(positions) or len(stations) < 2:
        raise FitError("final route geometry needs at least two position samples")
    headings: list[float] = []
    grades: list[float] = []
    tangents: list[list[float]] = []
    for index in range(len(stations)):
        left_index = max(index - 1, 0)
        right_index = min(index + 1, len(stations) - 1)
        delta = [
            float(positions[right_index][axis]) - float(positions[left_index][axis])
            for axis in range(3)
        ]
        horizontal = math.hypot(delta[0], delta[2])
        length = math.sqrt(sum(value * value for value in delta))
        if horizontal <= 1e-6 or length <= 1e-6:
            raise FitError(f"final route geometry has a degenerate tangent at station {stations[index]:.4f}")
        headings.append(wrap_heading(math.degrees(math.atan2(delta[0], -delta[2]))))
        grades.append(delta[1] / horizontal * 100.0)
        tangents.append([value / length for value in delta])
    return {"headings": headings, "grades": grades, "tangents": tangents}


def actual_core_validation(
    stations: list[float], actual: dict[str, list[Any]], segment: dict[str, Any]
) -> dict[str, Any]:
    """Report phase and assert the source grade sign on final positions."""

    window = segment["station_window"]
    edit_start = float(window["edit_start_m"])
    edit_end = float(window["edit_end_m"])
    indices = [index for index, station in enumerate(stations) if edit_start - 1e-6 <= station <= edit_end + 1e-6]
    if not indices:
        raise FitError(f"{segment['id']} final geometry has no core samples")
    grades = [float(actual["grades"][index]) for index in indices]
    headings = [float(actual["headings"][index]) for index in indices]
    unwrapped: list[float] = []
    for heading in headings:
        unwrapped.append(heading if not unwrapped else unwrapped[-1] + angle_delta_deg(heading, unwrapped[-1]))
    contract = source_grade_contract(segment)
    if contract["sign"] == "positive":
        sign_pass = all(grade > 0.0 for grade in grades)
    else:
        sign_pass = all(grade < 0.0 for grade in grades)
    if not sign_pass:
        raise FitError(
            f"{segment['id']} final position-derived core grade violates {contract['sign']} source sign "
            f"({min(grades):+.3f}..{max(grades):+.3f}%)"
        )
    mid_index = len(unwrapped) // 2
    phase_trace: list[dict[str, Any]] = []
    source_sequence = segment.get("source_sequence", {})
    trace_rows = source_sequence.get("time_to_station_estimates", []) if isinstance(source_sequence, dict) else []
    for raw_trace in trace_rows if isinstance(trace_rows, list) else []:
        if not isinstance(raw_trace, dict) or not finite(raw_trace.get("station_m")):
            continue
        authored_station = float(raw_trace["station_m"])
        nearest_index = min(range(len(stations)), key=lambda index: abs(stations[index] - authored_station))
        phase_trace.append(
            {
                "source_time_s": float(raw_trace.get("source_time_s", 0.0)),
                "phase": str(raw_trace.get("phase", "")),
                "authored_station_m": authored_station,
                "sample_station_m": float(stations[nearest_index]),
                "actual_heading_deg": float(actual["headings"][nearest_index]),
            }
        )
    turn_deltas: list[dict[str, Any]] = []
    for left_trace, right_trace in zip(phase_trace, phase_trace[1:]):
        turn_deltas.append(
            {
                "from_phase": left_trace["phase"],
                "to_phase": right_trace["phase"],
                "from_source_time_s": left_trace["source_time_s"],
                "to_source_time_s": right_trace["source_time_s"],
                "heading_delta_deg": angle_delta_deg(
                    float(right_trace["actual_heading_deg"]), float(left_trace["actual_heading_deg"])
                ),
                "left_is_negative_heading_delta": True,
            }
        )
    return {
        "derived_from_final_positions": True,
        "core_station_range_m": [edit_start, edit_end],
        "core_sample_count": len(indices),
        "core_actual_grade_min_pct": min(grades),
        "core_actual_grade_max_pct": max(grades),
        "core_grade_sign": contract["sign"],
        "core_grade_sign_pass": sign_pass,
        "core_heading_start_deg": unwrapped[0],
        "core_heading_mid_deg": unwrapped[mid_index],
        "core_heading_end_deg": unwrapped[-1],
        "core_heading_span_deg": unwrapped[-1] - unwrapped[0],
        "core_heading_min_deg": min(unwrapped),
        "core_heading_max_deg": max(unwrapped),
        "source_phase_trace_actual": phase_trace,
        "source_phase_turn_deltas_actual": turn_deltas,
        "phase_status": "reported_from_final_position_tangents",
    }


def compiled_fit_samples(
    rows: list[dict[str, Any]], segment: dict[str, Any]
) -> tuple[list[dict[str, Any]], float, dict[str, Any], dict[str, Any]]:
    """Compile final position-derived geometry into representative.gd schema."""

    window = segment["station_window"]
    start = float(window["outer_start_m"])
    end = float(window["outer_end_m"])
    closure = closure_report(rows, segment)
    absolute_knots = absolute_heading_knots(rows, segment)
    orientation = optimize_overall_orientation(rows, segment)
    optimized_yaw = float(orientation["optimized_deg"])
    stations = station_grid(start, end, 10.0)
    requested_headings = [
        oriented_heading_deg(absolute_knots, segment, station, optimized_yaw) for station in stations
    ]
    requested_grades = [closed_grade_with_blend(rows, segment, station, closure) for station in stations]
    positions: list[list[float]] = [list(interpolate(rows, start, allow_extrapolation=True)["route_position"])]
    for index in range(1, len(stations)):
        span = stations[index] - stations[index - 1]
        mean_heading = lerp_angle_deg(requested_headings[index - 1], requested_headings[index], 0.5)
        mean_grade = 0.5 * (requested_grades[index - 1] + requested_grades[index])
        forward = [math.sin(math.radians(mean_heading)), 0.0, -math.cos(math.radians(mean_heading))]
        step = vec3_add(vec3_scale(forward, span), [0.0, mean_grade * span / 100.0, 0.0])
        positions.append(vec3_add(positions[-1], step))
    native_end = list(interpolate(rows, end, allow_extrapolation=True)["route_position"])
    endpoint_residual = [native_end[index] - positions[-1][index] for index in range(3)]
    for index, station in enumerate(stations):
        normalized = (station - start) / max(end - start, 1e-6)
        positions[index] = vec3_add(positions[index], vec3_scale(endpoint_residual, smoothstep(normalized)))
    actual = derive_actual_geometry(stations, positions)
    core_validation = actual_core_validation(stations, actual, segment)
    samples: list[dict[str, Any]] = []
    for index, station in enumerate(stations):
        base = interpolate(rows, station, allow_extrapolation=True)
        actual_heading = float(actual["headings"][index])
        actual_grade = float(actual["grades"][index])
        samples.append(
            {
                "station_m": station,
                "position": [float(value) for value in positions[index]],
                "tangent": [float(value) for value in actual["tangents"][index]],
                "heading_deg": actual_heading,
                "grade_pct": actual_grade,
                "actual_heading_deg": actual_heading,
                "actual_grade_pct": actual_grade,
                "requested_heading_deg": float(requested_headings[index]),
                "requested_grade_pct": float(requested_grades[index]),
                "overall_orientation_weight": overall_orientation_weight(segment, station),
                "native_heading_deg": float(base["heading_deg"]),
                "native_grade_pct": float(base["grade_pct"]),
                "native_extrapolated": bool(base.get("native_extrapolated", False)),
            }
        )
    endpoint_residual_m = math.sqrt(sum(value * value for value in endpoint_residual))
    return samples, endpoint_residual_m, orientation, core_validation


def compile_candidate(rows: list[dict[str, Any]], segment: dict[str, Any]) -> dict[str, Any]:
    samples, endpoint_residual, orientation, core_validation = compiled_fit_samples(rows, segment)
    closure = closure_report(rows, segment)
    window = segment["station_window"]
    baseline_anchor = segment.get("baseline_anchor", {})
    source_sequence = segment.get("source_sequence", {})
    source_trace = source_sequence.get("time_to_station_estimates", []) if isinstance(source_sequence, dict) else []
    source_times = [float(row["source_time_s"]) for row in source_trace if isinstance(row, dict) and finite(row.get("source_time_s"))]
    source_time_range = [min(source_times), max(source_times)] if source_times else []
    camera = segment.get("camera")
    if not isinstance(camera, dict):
        camera = {
            "station_m": float(baseline_anchor.get("station_m", window["edit_start_m"])),
            "source_time_s": float(baseline_anchor.get("source_time_s", 0.0)),
            "source_estimated": True,
        }
    return {
        "id": segment["id"],
        "scene_id": segment["scene_id"],
        "route_section": str(segment.get("route_section", "")),
        "window_start_m": float(window["outer_start_m"]),
        "window_end_m": float(window["outer_end_m"]),
        "baseline_anchor": baseline_anchor,
        "source_sequence": source_sequence,
        "source_time_range_s": source_time_range,
        "camera": camera,
        "corridor_half_width_m": float(segment.get("corridor_half_width_m", 40.0)),
        "corridor_falloff_m": float(window["boundary_blend_range_m"]),
        "cross_section_overrides": segment.get("cross_section_overrides", []),
        "fit_samples": samples,
        "fit_report": {
            "sample_spacing_m": 10.0,
            "absolute_heading_spline": True,
            "overall_orientation": orientation,
            "final_geometry_fields": "heading_deg/grade_pct/tangent are derived from final anchored positions; requested_* fields retain authored targets",
            "actual_core_validation": core_validation,
            "source_grade_contract": source_grade_contract(segment),
            "endpoint_residual_before_position_anchor_m": endpoint_residual,
            "endpoint_residual_after_position_anchor_m": 0.0,
            **closure,
        },
    }


def compile_config(
    config: dict[str, Any], groups: dict[str, list[dict[str, Any]]], config_path: Path, native_path: Path
) -> dict[str, Any]:
    representatives = [compile_candidate(groups[segment["scene_id"]], segment) for segment in config["segments"]]
    return {
        "schema_version": 1,
        "kind": "saisies_r37_route_geometry_representatives_compiled",
        "status": "diagnostic_only",
        "visual_acceptance": False,
        "formal_integration_allowed": False,
        "not_validated": True,
        "source_config": str(config_path),
        "source_native": str(native_path),
        "native_authority": config["provenance"]["native_authority"],
        "compile_contract": {
            "runtime_schema": "representatives[].fit_samples[{station_m,position,tangent,heading_deg,grade_pct,requested_heading_deg,requested_grade_pct}]",
            "window_schema": "representatives[].window_start_m/window_end_m",
            "source_anchor_schema": "representatives[].baseline_anchor/source_sequence/source_time_range_s/camera are retained so interactive launch defaults to the authored representative anchor rather than fit_samples[0]",
            "cross_section_schema": "representatives[].cross_section_overrides",
            "absolute_heading_spline": "Native heading is sampled at authored knots once; absolute targets are then splined. Native probe noise is not added per runtime sample.",
            "overall_orientation": "Source has no world compass. A numerically selected free yaw preserves authored relative phase, applies a C1 smoothstep weight of 0 at outer boundaries and 1 throughout each edit core, and reports pre-anchor XZ residual reduction.",
            "actual_geometry": "Runtime heading, grade and tangent are derived from the final anchored position samples. requested_heading_deg/requested_grade_pct remain diagnostic authored targets only.",
            "native_coverage": "Expanded 250m blend windows exceed the current +/-250m-per-anchor probe at their outer edges; edge grade/heading are held and endpoint positions are linearly extrapolated, marked, and require a new native route audit before acceptance.",
        },
        "route_contract": config["route_contract"],
        "scope": config["scope"],
        "representatives": representatives,
    }


def write_json(path: Path, value: dict[str, Any]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except OSError as exc:
        raise FitError(f"cannot write compiled representative data {path}: {exc}") from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check/preview R37 representative route geometry data")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--native", type=Path, default=DEFAULT_NATIVE)
    parser.add_argument("--route-data", type=Path, default=DEFAULT_ROUTE)
    parser.add_argument("--compile-output", type=Path, default=DEFAULT_COMPILED_OUTPUT, help="write runtime-schema draft JSON")
    parser.add_argument("--preview", action="store_true", help="emit the native-based preview JSON after checks")
    parser.add_argument("--pretty", action="store_true", help="indent preview JSON")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        config = read_json(args.config)
        native = read_json(args.native)
        route = read_json(args.route_data)
        groups = native_rows(native)
        warnings = validate(config, route, groups)
        previews = [preview_segment(groups[segment["scene_id"]], segment) for segment in config["segments"]]
        compiled = compile_config(config, groups, args.config, args.native)
        write_json(args.compile_output, compiled)
    except FitError as exc:
        print(f"Saisies R37 representative fit refused: {exc}")
        return 2
    print("Saisies R37 representative config: OK")
    for preview in previews:
        print(
            "%s outer=%.1f..%.1f samples=%d raw_residual=%+.2fm closure_peak=%+.2f%% max_blend_grade=%.2f%% coverage=%s"
            % (
                preview["id"],
                preview["outer_window_m"][0],
                preview["outer_window_m"][1],
                preview["sample_count"],
                preview["integrated_height_residual_m"],
                preview["height_closure_peak_correction_pct"],
                preview["max_blend_grade_pct"],
                preview["native_coverage"],
            )
        )
    print(f"Compiled runtime representatives: {args.compile_output}")
    for warning in warnings:
        print(f"WARNING: {warning}")
    if args.preview:
        payload = {
            "schema_version": 1,
            "kind": "saisies_r37_native_based_representative_preview",
            "not_validated": True,
            "source_config": str(args.config),
            "source_native": str(args.native),
            "segments": previews,
        }
        print(json.dumps(payload, indent=2 if args.pretty else None, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
