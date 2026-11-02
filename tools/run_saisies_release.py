#!/usr/bin/env python3
"""Validate and launch the whole-route Saisies release candidate.

The release scene is intentionally a thin integration wrapper around the
frozen R35 review scene.  Forest and roadside geometry remain in their own
worker modules; this launcher only verifies that both modules, the camera
controller, and the candidate data are present before starting Godot.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCENE = Path("scenes/MainScene_saisies_release.tscn")
CACHED_SCENE = Path("scenes/MainScene_saisies_release_cached.tscn")
R35_SCENE = Path("scenes/MainScene_saisies_s04_batch_review.tscn")
RELEASE_DATA = Path("data/saisies_release.json")
MODULE_DATA = Path("data/saisies_release_modules.json")
LIVE_LAUNCH_PROJECT = Path("export/saisies/review/round36_release/live_launch_project.json")
CACHE_SCENE = Path("export/saisies/release_candidate/saisies_release_geometry_cache.scn")
CACHE_MANIFEST = Path("export/saisies/release_candidate/saisies_release_geometry_cache.manifest.json")
R14_BAKE = Path("export/saisies/SaisiesEnvironment_geo_r14.scn")

REQUIRED = (
    Path("project.godot"),
    SCENE,
    R35_SCENE,
    Path("scripts/saisies_release_controller.gd"),
    Path("scripts/saisies_release_controller.gd.uid"),
    Path("scripts/saisies_release_forest.gd"),
    Path("scripts/saisies_release_forest.gd.uid"),
    Path("scripts/saisies_release_roadside.gd"),
    Path("scripts/saisies_release_roadside.gd.uid"),
    Path("scripts/saisies_release_terminals.gd"),
    Path("scripts/saisies_release_terminals.gd.uid"),
    Path("data/saisies_release.json"),
    Path("data/saisies_release_modules.json"),
    Path("data/saisies_release_terminals.json"),
    Path("data/saisies_release_forest.json"),
    Path("data/saisies_release_roadside.json"),
    R14_BAKE,
)


class LauncherError(RuntimeError):
    """Raised when the release candidate is incomplete or unsafe to launch."""


def find_godot() -> str:
    configured = os.environ.get("GODOT_BIN")
    if configured and Path(configured).is_file():
        return configured
    found = shutil.which("godot")
    if found:
        return found
    for candidate in (
        "/Applications/Godot.app/Contents/MacOS/Godot",
        "/opt/homebrew/bin/godot",
    ):
        if Path(candidate).is_file():
            return candidate
    raise LauncherError("Godot executable was not found; set GODOT_BIN")


def load_json(relative: Path) -> dict[str, Any]:
    path = ROOT / relative
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LauncherError(f"cannot read JSON {relative}: {exc}") from exc
    if not isinstance(value, dict):
        raise LauncherError(f"JSON root must be an object: {relative}")
    return value


def validate_release_data() -> tuple[dict[str, Any], dict[str, Any]]:
    release = load_json(RELEASE_DATA)
    modules = load_json(MODULE_DATA)
    if release.get("kind") != "saisies_full_route_release_candidate":
        raise LauncherError("release data has an unexpected kind")
    if release.get("status") != "root_selected_for_integrated_review":
        raise LauncherError("release data must remain root-selected for review")
    if release.get("visual_acceptance") != "pending":
        raise LauncherError("release data must remain visual-acceptance pending")
    if release.get("gps_calibrated") is not False or release.get("formal_route_edit") is not False:
        raise LauncherError("release data must remain visual-estimate-only")
    route = release.get("route")
    if not isinstance(route, dict):
        raise LauncherError("release route section is missing")
    first = float(route.get("first_video_seconds", -1.0))
    last = float(route.get("last_video_seconds", -1.0))
    station_end = float(route.get("station_end_m", -1.0))
    if abs(first) > 1e-6 or abs(last - 920.067) > 0.01 or station_end <= 0.0:
        raise LauncherError("release route endpoints are invalid")
    views = release.get("source_views")
    if not isinstance(views, list) or len(views) != 18:
        raise LauncherError("release data must contain exactly 18 source views")
    ids = []
    previous = -1.0
    for view in views:
        if not isinstance(view, dict):
            raise LauncherError("source view entries must be objects")
        scene_id = str(view.get("scene_id", ""))
        seconds = float(view.get("video_seconds", -1.0))
        image = str(view.get("source_image", ""))
        if not scene_id or seconds <= previous or not image:
            raise LauncherError("source views must have ids, images, and strict time order")
        if not (ROOT / image).is_file():
            raise LauncherError(f"source image is missing: {image}")
        ids.append(scene_id)
        previous = seconds
    if ids != [f"S{index:02d}" for index in range(1, 19)]:
        raise LauncherError("source views must be ordered S01 through S18")

    if modules.get("kind") != "saisies_full_route_release_modules":
        raise LauncherError("release module manifest has an unexpected kind")
    raw_modules = modules.get("modules")
    if not isinstance(raw_modules, list) or [m.get("node_name") for m in raw_modules if isinstance(m, dict)] != ["ReleaseForest", "ReleaseRoadside", "ReleaseTerminals"]:
        raise LauncherError("release module manifest must list ReleaseForest, ReleaseRoadside and ReleaseTerminals")
    for module in raw_modules:
        if not isinstance(module, dict):
            raise LauncherError("release module entries must be objects")
        for key in ("script", "candidate", "ready_meta", "enable_property"):
            if not module.get(key):
                raise LauncherError(f"release module entry is missing {key}")
    return release, modules


def validate_scene(use_cache: bool = False) -> None:
    scene_path = CACHED_SCENE if use_cache else SCENE
    scene_text = (ROOT / scene_path).read_text(encoding="utf-8")
    if use_cache:
        required_tokens = (
            "MainScene_saisies_s04_batch_review.tscn",
            "saisies_release_geometry_cache.scn",
            "saisies_release_cache_gate.gd",
            "saisies_release_controller.gd",
            'node name="ReleaseCacheGate"',
            'node name="ReleaseController"',
            'release_terminals_path = NodePath("../ReleaseCacheGate")',
            "saisies_release.json",
        )
    else:
        required_tokens = (
            "MainScene_saisies_s04_batch_review.tscn",
            "saisies_release_forest.gd",
            "saisies_release_roadside.gd",
            "saisies_release_terminals.gd",
            "saisies_release_controller.gd",
            'node name="ReleaseForest"',
            'node name="ReleaseRoadside"',
            'node name="ReleaseTerminals"',
            'node name="ReleaseController"',
            "BatchBase/ForestBase/GuardrailBase",
            "saisies_release.json",
        )
    for token in required_tokens:
        if token not in scene_text:
            raise LauncherError(f"release scene {scene_path} does not reference {token}")


def validate_files(use_cache: bool = False) -> tuple[dict[str, Any], dict[str, Any]]:
    missing = [str(path) for path in REQUIRED if not (ROOT / path).is_file()]
    if missing:
        raise LauncherError("whole-route release files are missing: " + ", ".join(missing))
    scene_path = CACHED_SCENE if use_cache else SCENE
    if not (ROOT / scene_path).is_file():
        raise LauncherError(f"release scene is missing: {scene_path}")
    if use_cache:
        missing_cache = [str(path) for path in (CACHE_SCENE, CACHE_MANIFEST) if not (ROOT / path).is_file()]
        if missing_cache:
            raise LauncherError("cached release geometry is missing; run native bake first: " + ", ".join(missing_cache))
    validate_scene(use_cache)
    return validate_release_data()


def wants_tour(args: argparse.Namespace) -> bool:
    """Choose a continuous tour unless the caller selected static inspection."""
    if args.tour:
        return True
    if args.static:
        return False
    return not args.source and args.seconds is None


def command_for(godot: str, args: argparse.Namespace) -> list[str]:
    command = [godot]
    if args.headless:
        command.append("--headless")
    scene = CACHED_SCENE if args.use_cache else SCENE
    command.extend(["--path", str(ROOT), f"res://{scene.as_posix()}", "--"])
    tour = wants_tour(args)
    if args.release_off:
        command.append("--saisies-release-off")
    if tour:
        command.append("--saisies-release-tour")
    if args.speed_kmh is not None:
        command.append(f"--saisies-release-speed-kmh={args.speed_kmh}")
    if args.seconds is not None:
        command.append(f"--saisies-release-seconds={args.seconds}")
    if args.source:
        command.append(f"--saisies-release-scene={args.source.upper()}")
    if args.quit_after_ready or (args.headless and not tour):
        command.append("--saisies-release-quit-after-ready")
    return command


def write_work_project(path: Path, command: list[str], release: dict[str, Any], modules: dict[str, Any], use_cache: bool) -> None:
    scene = CACHED_SCENE if use_cache else SCENE
    payload = {
        "schema_version": 1,
        "kind": "saisies_full_route_release_live_launch_project",
        "scene": f"res://{scene.as_posix()}",
        "release_candidate": f"res://{RELEASE_DATA.as_posix()}",
        "module_manifest": f"res://{MODULE_DATA.as_posix()}",
        "source_video_duration_s": release.get("source_video_duration_s"),
        "source_view_count": len(release.get("source_views", [])),
        "route_station_end_m": release.get("route", {}).get("station_end_m"),
        "module_nodes": [module.get("node_name") for module in modules.get("modules", []) if isinstance(module, dict)],
        "preserves_r35_base": True,
        "formal_route_edit": False,
        "visual_acceptance": "pending",
        "use_cache": use_cache,
        "cache_scene": f"res://{CACHED_SCENE.as_posix()}",
        "cache_geometry": f"res://{CACHE_SCENE.as_posix()}",
        "cache_manifest": f"res://{CACHE_MANIFEST.as_posix()}",
        "godot_command": command,
        "godot_command_shell": shlex.join(command),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Prepare and launch the whole-route Saisies release scene.")
    parser.add_argument("--prepare-only", action="store_true", help="validate files and write the work-project JSON")
    parser.add_argument("--print-command", action="store_true", help="print the exact Godot command")
    parser.add_argument("--headless", action="store_true", help="run Godot headlessly")
    parser.add_argument("--release-off", action="store_true", help="disable only the two whole-route release modules")
    parser.add_argument("--use-cache", "--cached", dest="use_cache", action="store_true", help="launch the native-baked static geometry cache")
    parser.add_argument("--tour", action="store_true", help="start the 30 km/h full-route tour (the default without --source/--seconds)")
    parser.add_argument("--static", action="store_true", help="hold the requested/default source pose instead of starting a tour")
    parser.add_argument("--release-speed-kmh", dest="speed_kmh", type=float, default=None, help="preview-tour speed; does not change source-video timing")
    parser.add_argument("--release-seconds", "--seconds", dest="seconds", type=float, default=None, help="start at a release video timestamp")
    parser.add_argument("--release-scene", "--source", dest="source", default="", help="start at a source view such as S05")
    parser.add_argument("--quit-after-ready", action="store_true", help="quit after the release controller publishes ready")
    parser.add_argument("--work-project", default=str(ROOT / LIVE_LAUNCH_PROJECT), help="live launch JSON; the frozen round36 work_project is never modified")
    args = parser.parse_args(argv)
    try:
        release, modules = validate_files(args.use_cache)
        godot = find_godot()
        command = command_for(godot, args)
        write_work_project(Path(args.work_project), command, release, modules, args.use_cache)
        scene = CACHED_SCENE if args.use_cache else SCENE
        print(f"Saisies whole-route release scene: res://{scene.as_posix()}")
        print(f"Saisies release source views: {len(release['source_views'])} / route {release['route']['last_video_seconds']} s")
        print(f"Saisies release work-project JSON: {args.work_project}")
        if args.print_command or args.prepare_only:
            print("Saisies release launch command: " + shlex.join(command))
        if args.prepare_only:
            return 0
        os.execv(command[0], command)
    except LauncherError as exc:
        print(f"Saisies whole-route release launch refused: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"Saisies whole-route release launch failed to start Godot: {exc}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
