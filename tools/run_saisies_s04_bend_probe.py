#!/usr/bin/env python3
"""Launch the route-only S04 bend probe without loading the production scene."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import sys


ROOT = Path(__file__).resolve().parents[1]
SCENE = Path("scenes/SaisiesS04BendProbe.tscn")
WORK_PROJECT = Path("/private/tmp/saisies_s04_bend_probe_work_project.json")
REQUIRED = (
    SCENE,
    Path("scripts/saisies_s04_bend_probe.gd"),
    Path("scripts/saisies_s04_bend_probe.gd.uid"),
    Path("scripts/saisies_geo_route.gd"),
    Path("scripts/saisies_route.gd"),
    Path("scripts/saisies_geography.gd"),
    Path("data/saisies_geo_route.json"),
    Path("data/saisies_s04_bend_candidate.json"),
)


def find_godot() -> str:
    configured = os.environ.get("GODOT_BIN")
    if configured and Path(configured).is_file():
        return configured
    found = shutil.which("godot")
    if found:
        return found
    for candidate in ("/Applications/Godot.app/Contents/MacOS/Godot", "/opt/homebrew/bin/godot"):
        if Path(candidate).is_file():
            return candidate
    raise RuntimeError("Godot executable was not found; set GODOT_BIN")


def validate() -> None:
    missing = [str(path) for path in REQUIRED if not (ROOT / path).is_file()]
    if missing:
        raise RuntimeError("S04 bend probe files are missing: " + ", ".join(missing))
    scene_text = (ROOT / SCENE).read_text(encoding="utf-8")
    for token in ("saisies_s04_bend_probe.gd", "saisies_geo_route.gd", "Route", "CameraRig"):
        if token not in scene_text:
            raise RuntimeError(f"route-only probe scene does not reference {token}")


def command_for(args: argparse.Namespace) -> list[str]:
    command = [find_godot()]
    if args.headless_check:
        command.append("--headless")
    command.extend(["--path", str(ROOT), f"res://{SCENE.as_posix()}", "--"])
    command.extend(
        [
            f"--station={args.station}",
            f"--fov={args.fov}",
            f"--yaw={args.yaw}",
            f"--pitch={args.pitch}",
            f"--lateral={args.lateral}",
            f"--distance={args.distance}",
            f"--height={args.height}",
            f"--look-ahead={args.look_ahead}",
            f"--step={args.step}",
            f"--diagnostic-out={args.diagnostic_out}",
            f"--candidate-file={args.candidate_file}",
        ]
    )
    if args.video_seconds is not None:
        command.append(f"--video-seconds={args.video_seconds}")
    if args.headless_check:
        command.append("--headless-check")
    if args.capture:
        command.append(f"--capture={args.capture}")
    if args.quit_after_capture:
        command.append("--quit-after-capture")
    return command


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Run the S04 route-only bend diagnostic/native grey probe.")
    parser.add_argument("--prepare-only", action="store_true", help="validate files and print the command without starting Godot")
    parser.add_argument("--print-command", action="store_true", help="print the exact native command")
    parser.add_argument("--station", type=float, default=1826.88599)
    parser.add_argument("--fov", type=float, default=77.0)
    parser.add_argument("--yaw", type=float, default=0.0)
    parser.add_argument("--pitch", type=float, default=-8.0)
    parser.add_argument("--lateral", type=float, default=0.0)
    parser.add_argument("--distance", type=float, default=0.0)
    parser.add_argument("--height", type=float, default=1.67)
    parser.add_argument("--look-ahead", type=float, default=30.0)
    parser.add_argument("--step", type=float, default=10.0)
    parser.add_argument("--diagnostic-out", default="/private/tmp/saisies_s04_route_diagnostic.json")
    parser.add_argument("--capture", default="", help="optional native PNG output path")
    parser.add_argument("--video-seconds", type=float, default=None, help="resolve station from the diagnostic piecewise-linear candidate")
    parser.add_argument("--candidate-file", default="res://data/saisies_s04_bend_candidate.json")
    parser.add_argument("--quit-after-capture", action="store_true", help="quit after saving a requested capture")
    parser.add_argument("--headless-check", action="store_true", help="run route/data probe headlessly and quit after diagnostics")
    parser.add_argument("--work-project", default=str(WORK_PROJECT))
    args = parser.parse_args(argv)
    try:
        validate()
        command = command_for(args)
        payload = {
            "schema_version": 1,
            "kind": "saisies_s04_bend_probe_work_project",
            "scene": f"res://{SCENE.as_posix()}",
            "route_only": True,
            "production_route_unchanged": True,
            "godot_command": command,
            "godot_command_shell": shlex.join(command),
            "diagnostic_out": args.diagnostic_out,
            "capture": args.capture,
            "pose_defaults": {"pitch_deg": args.pitch, "distance_m": args.distance, "height_m": args.height},
            "video_seconds": args.video_seconds,
            "candidate_file": args.candidate_file,
            "candidate_probe_only": True,
            "formal_route_integration": False,
        }
        work_path = Path(args.work_project)
        work_path.parent.mkdir(parents=True, exist_ok=True)
        work_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        print("S04 route-only bend probe scene: " + f"res://{SCENE.as_posix()}")
        print("S04 route diagnostic output: " + args.diagnostic_out)
        if args.print_command or args.prepare_only:
            print("S04 native probe command: " + shlex.join(command))
        if args.prepare_only:
            return 0
        os.execv(command[0], command)
    except (OSError, RuntimeError) as exc:
        print(f"S04 bend probe launch refused: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
