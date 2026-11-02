#!/usr/bin/env python3
"""Validate and launch the cheap R37 route/camera diagnostic probe.

The probe reads the frozen R14 world and R36 geometry cache directly.  It is
deliberately a local diagnostic launcher: it does not copy, rewrite, or freeze
the release scene and it never changes release acceptance metadata.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import math
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCENE = Path("scenes/saisies_r37_probe.tscn")
SCRIPT = Path("scripts/saisies_r37_probe.gd")
CONFIG = Path("data/saisies_r37_probe.json")
WORLD = Path("export/saisies/SaisiesEnvironment_geo_r14.scn")
CACHE = Path("export/saisies/release_candidate/saisies_release_geometry_cache.scn")


class ProbeError(RuntimeError):
    """Raised when a diagnostic input is missing or malformed."""


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
    raise ProbeError("Godot executable was not found; set GODOT_BIN")


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProbeError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ProbeError(f"JSON root must be an object: {path}")
    return value


def project_path(raw: str | Path) -> Path:
    value = str(raw)
    if value.startswith("res://"):
        return ROOT / value[6:]
    path = Path(value)
    return path if path.is_absolute() else ROOT / path


def validate_inputs(config_raw: str) -> tuple[dict[str, Any], Path, Path, Path]:
    config_path = project_path(config_raw)
    config = read_json(config_path)
    world_path = project_path(str(config.get("world_scene", WORLD.as_posix())))
    cache_path = project_path(str(config.get("geometry_cache", CACHE.as_posix())))
    required_paths = [ROOT / Path("project.godot"), ROOT / SCENE, ROOT / SCRIPT, config_path, world_path, cache_path]
    missing = [str(path) for path in required_paths if not path.is_file()]
    if missing:
        raise ProbeError("R37 probe files are missing: " + ", ".join(missing))
    if config.get("schema_version") != 1 or config.get("kind") != "saisies_r37_camera_route_probe":
        raise ProbeError("R37 config has an unexpected schema or kind")
    if config.get("status") != "diagnostic_only" or config.get("visual_acceptance") is not False:
        raise ProbeError("R37 config must remain diagnostic_only and visual_acceptance=false")
    if config.get("formal_integration_allowed") is not False or config.get("not_validated") is not True:
        raise ProbeError("R37 config must remain explicitly unvalidated")
    route = config.get("route_contract")
    if not isinstance(route, dict):
        raise ProbeError("R37 route_contract is missing")
    if abs(float(route.get("station_end_m", -1.0)) - 14615.087922) > 0.25:
        raise ProbeError("R37 route contract station_end_m is not the frozen route length")
    targets = config.get("candidates", config.get("targets"))
    if not isinstance(targets, list) or not targets:
        raise ProbeError("R37 config must contain candidates")
    seen: set[str] = set()
    route_end = float(route.get("station_end_m", 14615.087922))
    for target in targets:
        if not isinstance(target, dict):
            raise ProbeError("R37 candidate entries must be objects")
        scene_id = str(target.get("scene_id", "")).strip()
        tag = str(target.get("tag", "")).strip()
        pose = target.get("pose", target.get("source_pose"))
        try:
            video_seconds = float(target.get("video_seconds"))
            station_m = float(target.get("station_m"))
        except (TypeError, ValueError) as exc:
            raise ProbeError(f"R37 candidate {scene_id}/{tag} needs numeric video_seconds/station_m") from exc
        if not scene_id or not tag or not isinstance(pose, dict):
            raise ProbeError("R37 candidates require scene_id, tag, video_seconds, station_m, and pose")
        if not math.isfinite(video_seconds) or not math.isfinite(station_m) or not 0.0 <= station_m <= route_end:
            raise ProbeError(f"R37 candidate {scene_id}/{tag} is outside the route contract")
        key = f"{scene_id.upper()}::{tag.upper()}"
        if key in seen:
            raise ProbeError(f"R37 candidate scene_id/tag is duplicated: {key}")
        seen.add(key)
    return config, world_path, cache_path, config_path


def command_for(godot: str, args: argparse.Namespace) -> list[str]:
    command = [godot]
    if args.headless_check:
        command.append("--headless")
    if args.resolution:
        command.extend(["--resolution", args.resolution])
    command.extend(["--path", str(ROOT), f"res://{SCENE.as_posix()}"])
    user_args: list[str] = []
    if args.config:
        user_args.append(f"--config={args.config}")
    if args.output:
        user_args.append(f"--output={args.output}")
    if args.targets:
        user_args.append(f"--targets={args.targets}")
    if args.window is not None:
        user_args.append(f"--window={args.window:g}")
    if args.step is not None:
        user_args.append(f"--step={args.step:g}")
    if args.curvature_delta is not None:
        user_args.append(f"--curvature-delta={args.curvature_delta:g}")
    if args.projection_ahead is not None:
        user_args.append(f"--projection-ahead={args.projection_ahead:g}")
    for name, value in (("station", args.station), ("video-seconds", args.video_seconds), ("fov", args.fov), ("pitch", args.pitch), ("yaw", args.yaw), ("lateral", args.lateral), ("height", args.height)):
        if value is not None:
            user_args.append(f"--{name}={value:g}")
    if args.capture_dir:
        user_args.append(f"--capture-dir={args.capture_dir}")
    if args.capture_targets:
        user_args.append(f"--capture-targets={args.capture_targets}")
    if args.capture_offset is not None:
        user_args.append(f"--capture-offset={args.capture_offset:g}")
    if args.capture_wait_frames is not None:
        user_args.append(f"--capture-wait-frames={args.capture_wait_frames}")
    if args.route_only:
        user_args.append("--route-only")
    if args.baseline:
        user_args.append("--baseline")
    if args.headless_check:
        user_args.append("--headless-check")
    if user_args:
        command.append("--")
        command.extend(user_args)
    return command


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the diagnostic-only R37 Saisies route/camera probe.")
    parser.add_argument("--prepare-only", action="store_true", help="validate inputs and print the command without launching Godot")
    parser.add_argument("--print-command", action="store_true", help="print the exact Godot command before launching")
    parser.add_argument("--headless-check", action="store_true", help="add Godot headless mode and probe parse/readiness checks")
    parser.add_argument("--config", default=f"res://{CONFIG.as_posix()}", help="candidate config path; accepts res:// or a project-relative path")
    parser.add_argument("--resolution", default="1920x1080", help="Godot viewport resolution, default 1920x1080")
    parser.add_argument("--output", default="", help="trajectory JSON path (defaults to user://saisies_r37_probe_trajectory.json)")
    parser.add_argument("--targets", default="", help="comma-separated target ids, for example S06,S10")
    parser.add_argument("--window", type=float, default=None, help="station window in metres")
    parser.add_argument("--step", type=float, default=None, help="station matrix step in metres")
    parser.add_argument("--curvature-delta", type=float, default=None, help="curvature tangent sample span in metres")
    parser.add_argument("--projection-ahead", type=float, default=None, help="projection look-ahead in metres")
    parser.add_argument("--station", type=float, default=None, help="replace the configured matrix with one direct station")
    parser.add_argument("--video-seconds", type=float, default=None, help="annotate a direct station with source time")
    parser.add_argument("--fov", type=float, default=None, help="explicit camera FOV override")
    parser.add_argument("--pitch", type=float, default=None, help="explicit camera pitch override")
    parser.add_argument("--yaw", type=float, default=None, help="explicit camera yaw override")
    parser.add_argument("--lateral", type=float, default=None, help="explicit camera lateral offset override")
    parser.add_argument("--height", type=float, default=None, help="explicit camera height override")
    parser.add_argument("--route-only", action="store_true", help="run only with the R36 geometry cache hidden")
    parser.add_argument("--baseline", action="store_true", help="run only with the R36 geometry cache visible")
    parser.add_argument("--capture-dir", default="", help="optional directory for explicitly selected center captures")
    parser.add_argument("--capture-targets", default="", help="comma-separated selected targets for optional captures")
    parser.add_argument("--capture-offset", type=float, default=None, help="offset to capture; defaults to the matrix center (0m)")
    parser.add_argument("--capture-wait-frames", type=int, default=None, help="frames to settle before each selected capture; default 12")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        config, world_path, cache_path, config_path = validate_inputs(args.config)
        godot = find_godot()
        command = command_for(godot, args)
        print(f"R37 probe scene: res://{SCENE.as_posix()}")
        print(f"R37 config: {config_path}")
        print(f"R37 frozen world: {world_path}")
        print(f"R37 frozen cache: {cache_path}")
        if args.print_command or args.prepare_only:
            print("R37 launch command: " + shlex.join(command))
        if args.prepare_only:
            return 0
        os.execv(command[0], command)
    except ProbeError as exc:
        print(f"Saisies R37 probe refused: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"Saisies R37 probe failed to start Godot: {exc}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
