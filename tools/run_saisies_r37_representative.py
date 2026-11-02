#!/usr/bin/env python3
"""Validate and launch an isolated R37 representative geometry candidate.

The candidate scene loads the frozen R14 world and R36 geometry cache, then
applies a local frame/terrain fit in memory.  It never rewrites release files.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import shlex
import shutil
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCENE = Path("scenes/saisies_r37_representative.tscn")
SCRIPT = Path("scripts/saisies_r37_representative.gd")
CONFIG = Path("data/saisies_r37_representatives.json")
WORLD = Path("export/saisies/SaisiesEnvironment_geo_r14.scn")
CACHE = Path("export/saisies/release_candidate/saisies_release_geometry_cache.scn")


class RepresentativeError(RuntimeError):
    """Raised when an isolated candidate input is missing or malformed."""


def validate_knots(candidate_id: str, name: str, value: Any, value_key: str, lower: float, upper: float) -> None:
    if not isinstance(value, list) or len(value) < 2:
        raise RepresentativeError(f"representative {candidate_id} {name} needs at least two knots")
    previous = -math.inf
    for index, knot in enumerate(value):
        if not isinstance(knot, dict):
            raise RepresentativeError(f"representative {candidate_id} {name}[{index}] must be an object")
        try:
            station = float(knot["station_m"])
            authored_value = float(knot[value_key])
        except (KeyError, TypeError, ValueError) as exc:
            raise RepresentativeError(f"representative {candidate_id} {name}[{index}] needs station_m/{value_key}") from exc
        if not math.isfinite(station) or not lower - 1e-4 <= station <= upper + 1e-4:
            raise RepresentativeError(f"representative {candidate_id} {name}[{index}] station is outside its outer window")
        if not math.isfinite(authored_value):
            raise RepresentativeError(f"representative {candidate_id} {name}[{index}] value must be finite")
        if station <= previous:
            raise RepresentativeError(f"representative {candidate_id} {name} stations must be strictly increasing")
        previous = station


def find_godot() -> str:
    configured = os.environ.get("GODOT_BIN")
    if configured and Path(configured).is_file():
        return configured
    found = shutil.which("godot") or shutil.which("godot4")
    if found:
        return found
    for candidate in ("/Applications/Godot.app/Contents/MacOS/Godot", "/opt/homebrew/bin/godot"):
        if Path(candidate).is_file():
            return candidate
    raise RepresentativeError("Godot executable was not found; set GODOT_BIN")


def project_path(raw: str | Path) -> Path:
    value = str(raw)
    if value.startswith("res://"):
        return ROOT / value[6:]
    path = Path(value)
    return path if path.is_absolute() else ROOT / path


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RepresentativeError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise RepresentativeError(f"JSON root must be an object: {path}")
    return value


def validate_inputs(config_raw: str, candidate_id: str) -> tuple[dict[str, Any], Path, Path, Path]:
    config_path = project_path(config_raw)
    config = read_json(config_path)
    world_path = project_path(str(config.get("world_scene", WORLD.as_posix())))
    cache_path = project_path(str(config.get("geometry_cache", CACHE.as_posix())))
    required = [ROOT / Path("project.godot"), ROOT / SCENE, ROOT / SCRIPT, config_path, world_path, cache_path]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise RepresentativeError("R37 representative files are missing: " + ", ".join(missing))
    status = config.get("status", "diagnostic_only")
    if status not in {"diagnostic_only", "draft_for_integrate"}:
        raise RepresentativeError(f"representative config has unsupported status: {status}")
    if config.get("formal_integration_allowed", False) is not False or config.get("visual_acceptance", False) is not False:
        raise RepresentativeError("representative config must remain unaccepted and formal_integration_allowed=false")
    candidates = config.get("representatives", config.get("candidates", config.get("segments")))
    if not isinstance(candidates, list) or not candidates:
        raise RepresentativeError("representative config must contain representatives, candidates, or segments")
    selected = [item for item in candidates if isinstance(item, dict) and str(item.get("id", item.get("scene_id", ""))).upper() == candidate_id.upper()]
    if not selected:
        raise RepresentativeError(f"representative candidate is missing: {candidate_id}")
    candidate = selected[0]
    fit = candidate.get("fit_samples", candidate.get("route_samples", candidate.get("samples", candidate.get("frames"))))
    if fit is None:
        fit = []
    if not isinstance(fit, list):
        raise RepresentativeError(f"representative {candidate_id} fit samples must be an array when present")
    has_heading_delta = isinstance(candidate.get("heading_delta_knots_deg"), list) and bool(candidate.get("heading_delta_knots_deg"))
    has_absolute_heading = isinstance(candidate.get("absolute_heading_knots_deg", candidate.get("heading_absolute_knots_deg")), list) and bool(candidate.get("absolute_heading_knots_deg", candidate.get("heading_absolute_knots_deg")))
    has_knots = (has_heading_delta or has_absolute_heading) and isinstance(candidate.get("grade_knots_pct"), list)
    if not fit and not has_knots:
        raise RepresentativeError(f"representative {candidate_id} needs fit_samples or heading/grade knots")
    for index, sample in enumerate(fit):
        if not isinstance(sample, dict):
            raise RepresentativeError(f"representative {candidate_id} fit sample {index} must be an object")
        try:
            station = float(sample.get("station_m", sample.get("source_station_m")))
        except (TypeError, ValueError) as exc:
            raise RepresentativeError(f"representative {candidate_id} fit sample {index} needs station_m") from exc
        if not math.isfinite(station) or station < 0.0 or station > 14615.087922:
            raise RepresentativeError(f"representative {candidate_id} fit sample {index} is outside the route")
    if has_knots:
        window = candidate.get("station_window")
        if not isinstance(window, dict):
            raise RepresentativeError(f"representative {candidate_id} knot fit needs station_window")
        for key in ("outer_start_m", "outer_end_m", "edit_start_m", "edit_end_m"):
            try:
                value = float(window[key])
            except (KeyError, TypeError, ValueError) as exc:
                raise RepresentativeError(f"representative {candidate_id} station_window needs {key}") from exc
            if not math.isfinite(value) or value < 0.0 or value > 14615.087922:
                raise RepresentativeError(f"representative {candidate_id} station_window {key} is outside the route")
        if not float(window["outer_start_m"]) < float(window["edit_start_m"]) < float(window["edit_end_m"]) < float(window["outer_end_m"]):
            raise RepresentativeError(f"representative {candidate_id} station_window must be outer_start < edit_start < edit_end < outer_end")
        outer_start = float(window["outer_start_m"])
        outer_end = float(window["outer_end_m"])
        edit_start = float(window["edit_start_m"])
        edit_end = float(window["edit_end_m"])
        heading_knots = candidate.get("heading_delta_knots_deg", candidate.get("absolute_heading_knots_deg", candidate.get("heading_absolute_knots_deg")))
        grade_knots = candidate["grade_knots_pct"]
        heading_value_key = "delta_deg" if has_heading_delta else "absolute_heading_deg"
        heading_name = "heading_delta_knots_deg" if has_heading_delta else "absolute_heading_knots_deg"
        validate_knots(candidate_id, heading_name, heading_knots, heading_value_key, outer_start, outer_end)
        validate_knots(candidate_id, "grade_knots_pct", grade_knots, "target_pct", edit_start, edit_end)
        if has_heading_delta and (abs(float(heading_knots[0]["delta_deg"])) > 1e-3 or abs(float(heading_knots[-1]["delta_deg"])) > 1e-3):
            raise RepresentativeError(f"representative {candidate_id} heading correction must be zero at outer boundaries")
    return config, world_path, cache_path, config_path


def command_for(godot: str, args: argparse.Namespace) -> list[str]:
    command = [godot]
    if args.headless:
        command.append("--headless")
    if args.resolution:
        command.extend(["--resolution", args.resolution])
    command.extend(["--path", str(ROOT), f"res://{SCENE.as_posix()}"])
    user_args = [f"--candidate={args.candidate}"]
    if args.config:
        user_args.append(f"--config={args.config}")
    if args.capture_dir:
        user_args.append(f"--capture-dir={args.capture_dir}")
    if args.report:
        user_args.append(f"--report={args.report}")
    if args.station is not None:
        user_args.append(f"--station={args.station:g}")
    if args.interactive:
        user_args.append("--interactive")
    if args.tour:
        user_args.append("--tour")
    if args.no_tour:
        user_args.append("--no-tour")
    if args.no_capture:
        user_args.append("--no-capture")
    if args.no_dressing:
        user_args.append("--no-dressing")
    command.append("--")
    command.extend(user_args)
    return command


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run an isolated diagnostic R37 representative geometry candidate.")
    parser.add_argument("--candidate", default="S06", help="representative id, for example S06, S10, or S12")
    parser.add_argument("--config", default=f"res://{CONFIG.as_posix()}", help="representative JSON path")
    parser.add_argument("--resolution", default="1920x1080", help="Godot viewport resolution")
    parser.add_argument("--capture-dir", default="", help="optional one-frame capture directory")
    parser.add_argument("--report", default="", help="optional runtime report path")
    parser.add_argument("--station", type=float, default=None, help="optional camera station override")
    parser.add_argument("--headless", action="store_true", help="launch Godot headless")
    parser.add_argument("--interactive", action="store_true", help="keep the scene alive and start the source-sequence tour; add --no-tour for static harnesses")
    parser.add_argument("--tour", action="store_true", help="run the source-sequence camera loop and keep the scene alive; Space pauses")
    parser.add_argument("--no-tour", action="store_true", help="force the interactive source-sequence loop off")
    parser.add_argument("--no-capture", action="store_true", help="skip the candidate's optional PNG capture")
    parser.add_argument("--no-dressing", action="store_true", help="disable the source-estimated R37 dressing overlay")
    parser.add_argument("--prepare-only", action="store_true", help="validate and print command without launching")
    parser.add_argument("--print-command", action="store_true", help="print the exact Godot command")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        _, world_path, cache_path, config_path = validate_inputs(args.config, args.candidate)
        godot = find_godot()
        command = command_for(godot, args)
        print(f"R37 representative scene: res://{SCENE.as_posix()}")
        print(f"R37 representative candidate: {args.candidate}")
        print(f"R37 representatives config: {config_path}")
        print(f"R37 frozen world: {world_path}")
        print(f"R37 frozen cache: {cache_path}")
        if args.prepare_only or args.print_command:
            print("R37 representative launch command: " + shlex.join(command))
        if args.prepare_only:
            return 0
        os.execv(command[0], command)
    except RepresentativeError as exc:
        print(f"Saisies R37 representative refused: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"Saisies R37 representative failed to start Godot: {exc}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
