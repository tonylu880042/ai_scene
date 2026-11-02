#!/usr/bin/env python3
"""Prepare and launch the fixed S03 signs review project from round21."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
S01_LAUNCHER = Path(__file__).with_name("run_saisies_s01_review.py")
SOURCE_BUNDLE_RELATIVE = Path("export/saisies/review/round21_s03_signs/source_bundle")
SNAPSHOT_RELATIVE = SOURCE_BUNDLE_RELATIVE / "source_snapshot.json"
REVIEW_SCENE_RELATIVE = Path("scenes/MainScene_saisies_s03_signs_review.tscn")
WORK_PROJECT_RELATIVE = Path("export/saisies/review/round21_s03_signs/work_project.json")
LINKED_DIRS = ("assets", "video", "export")
R14_BAKE_RELATIVE = Path("export/saisies/SaisiesEnvironment_geo_r14.scn")

REQUIRED_SOURCE_RELATIVES = (
    Path("project.godot"),
    Path("scenes/MainScene_saisies_s01_review.tscn"),
    Path("scenes/MainScene_saisies_s02_review.tscn"),
    Path("scenes/MainScene_saisies_s03_review.tscn"),
    Path("scenes/MainScene_saisies_s03_ground_review.tscn"),
    Path("scenes/MainScene_saisies_s03_lift_review.tscn"),
    REVIEW_SCENE_RELATIVE,
    Path("scripts/saisies_s01_camera_controller.gd"),
    Path("scripts/saisies_s01_architecture.gd"),
    Path("scripts/saisies_s01_landscape.gd"),
    Path("scripts/saisies_s02_lodge_refinement.gd"),
    Path("scripts/saisies_s02_review_controller.gd"),
    Path("scripts/saisies_s03_junction_refinement.gd"),
    Path("scripts/saisies_s03_review_controller.gd"),
    Path("scripts/saisies_s03_ground_refinement.gd"),
    Path("scripts/saisies_s03_lift_refinement.gd"),
    Path("scripts/saisies_s03_signs_refinement.gd"),
    Path("data/saisies_s01_camera_calibration.json"),
)


def _s01_helpers():
    spec = importlib.util.spec_from_file_location("saisies_s01_review_helpers", S01_LAUNCHER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import launcher helpers: {S01_LAUNCHER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


s01 = _s01_helpers()
LauncherError = s01.LauncherError


def load_snapshot(root: Path):
    bundle = root / SOURCE_BUNDLE_RELATIVE
    snapshot_path = root / SNAPSHOT_RELATIVE
    if not bundle.is_dir():
        raise LauncherError(f"S03 signs source bundle is missing: {bundle}")
    if not snapshot_path.is_file():
        raise LauncherError(f"S03 signs source snapshot is missing: {snapshot_path}")
    snapshot = s01.read_json(snapshot_path, "S03 signs source snapshot")
    hashes = s01.parse_hash_map(snapshot, "hashes")
    assets = s01.parse_hash_map(snapshot, "assets")
    required_set = set(REQUIRED_SOURCE_RELATIVES)
    for required in REQUIRED_SOURCE_RELATIVES:
        if required not in hashes:
            raise LauncherError(f"source snapshot hashes must include {required}")
    for relative in hashes:
        if relative.parts[0] in set(LINKED_DIRS) | {".godot"}:
            raise LauncherError(f"source hash {relative} belongs to a linked tree")
    asset_paths, normalized_assets = s01.resolve_asset_paths(root, assets)
    base_bake, base_bake_digest = s01.parse_base_bake(snapshot, normalized_assets, asset_paths)
    if base_bake != R14_BAKE_RELATIVE:
        raise LauncherError(f"base_bake must identify {R14_BAKE_RELATIVE}, got {base_bake}")
    return bundle, hashes, normalized_assets, asset_paths, base_bake_digest


def validate_restored_scene(restore: Path) -> None:
    project = restore / "project.godot"
    signs_scene = restore / REVIEW_SCENE_RELATIVE
    lift_scene = restore / "scenes/MainScene_saisies_s03_lift_review.tscn"
    ground_scene = restore / "scenes/MainScene_saisies_s03_ground_review.tscn"
    s03_scene = restore / "scenes/MainScene_saisies_s03_review.tscn"
    s02_scene = restore / "scenes/MainScene_saisies_s02_review.tscn"
    s01_scene = restore / "scenes/MainScene_saisies_s01_review.tscn"
    required_files = (project, signs_scene, lift_scene, ground_scene, s03_scene, s02_scene, s01_scene)
    if any(not path.is_file() for path in required_files):
        raise LauncherError("restored R21 source bundle is missing project or fixed review scenes")
    try:
        signs_text = signs_scene.read_text(encoding="utf-8")
        lift_text = lift_scene.read_text(encoding="utf-8")
        ground_text = ground_scene.read_text(encoding="utf-8")
        s03_text = s03_scene.read_text(encoding="utf-8")
        s02_text = s02_scene.read_text(encoding="utf-8")
        s01_text = s01_scene.read_text(encoding="utf-8")
    except OSError as exc:
        raise LauncherError(f"cannot read restored review scenes: {exc}") from exc
    for required in (
        "MainScene_saisies_s03_lift_review.tscn",
        "saisies_s03_signs_refinement.gd",
    ):
        if required not in signs_text:
            raise LauncherError(f"fixed S03 signs wrapper does not reference {required}")
    for required in (
        "MainScene_saisies_s03_ground_review.tscn",
        "saisies_s03_lift_refinement.gd",
    ):
        if required not in lift_text:
            raise LauncherError(f"fixed S03 lift dependency does not reference {required}")
    if "MainScene_saisies_s03_cafe_review.tscn" not in ground_text or "saisies_s03_ground_refinement.gd" not in ground_text:
        raise LauncherError("fixed S03 ground wrapper does not reference its accepted cafe module")
    for required in (
        "MainScene_saisies_s02_review.tscn",
        "saisies_s03_junction_refinement.gd",
        "saisies_s03_review_controller.gd",
    ):
        if required not in s03_text:
            raise LauncherError(f"fixed S03 scene does not reference {required}")
    if "MainScene_saisies_s01_review.tscn" not in s02_text:
        raise LauncherError("fixed S02 scene does not reference the frozen S01 review scene")
    if "SaisiesEnvironment_geo_r14.scn" not in s01_text:
        raise LauncherError("frozen S01 scene does not reference the R14 baked world")


def command_for(godot: str, restore: Path, signs_off: bool) -> list[str]:
    command = [godot, "--path", str(restore), f"res://{REVIEW_SCENE_RELATIVE.as_posix()}"]
    if signs_off:
        command.extend(["--", "--s03-signs-off"])
    return command


def write_work_project(
    root: Path,
    path: Path,
    restore: Path,
    command: list[str],
    signs_off: bool,
    hash_count: int,
    asset_count: int,
) -> None:
    payload: dict[str, Any] = {
        "schema_version": 1,
        "kind": "saisies_s03_signs_review_work_project",
        "source_bundle": str(root / SOURCE_BUNDLE_RELATIVE),
        "restored_project": str(restore),
        "scene": f"res://{REVIEW_SCENE_RELATIVE.as_posix()}",
        "hashes_verified": hash_count,
        "assets_verified": asset_count,
        "base_bake": R14_BAKE_RELATIVE.as_posix(),
        "signs_off": signs_off,
        "godot_command": command,
        "godot_command_shell": shlex.join(command),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def prepare(root: Path, signs_off: bool):
    bundle, hashes, assets, asset_paths, base_bake_digest = load_snapshot(root)
    s01.verify_asset_hashes(root, assets, asset_paths, base_bake_digest)
    restore = Path(tempfile.mkdtemp(prefix="saisies_s03_signs_review_"))
    try:
        s01.verify_source_hashes(root, bundle, hashes, restore)
        shutil.copy2(root / SNAPSHOT_RELATIVE, restore / "source_snapshot.json")
        s01.link_workspace_tree(root, restore)
        validate_restored_scene(restore)
    except Exception:
        shutil.rmtree(restore, ignore_errors=True)
        raise
    godot = s01.find_godot()
    return restore, command_for(godot, restore, signs_off), len(hashes), len(assets)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Prepare and launch the fixed Saisies S03 signs review scene from round20.")
    parser.add_argument("--prepare-only", action="store_true", help="verify and prepare the isolated project, write work_project.json, and do not launch Godot")
    parser.add_argument("--s03-signs-off", action="store_true", help="pass --s03-signs-off to Godot for the controlled baseline")
    parser.add_argument("--print-command", action="store_true", help="print the exact Godot command before launching")
    args = parser.parse_args(argv)
    try:
        restore, command, hash_count, asset_count = prepare(ROOT, args.s03_signs_off)
        work_project = ROOT / WORK_PROJECT_RELATIVE
        write_work_project(ROOT, work_project, restore, command, args.s03_signs_off, hash_count, asset_count)
        print(f"S03 source restored: {restore}")
        print(f"S03 signs fixed scene: res://{REVIEW_SCENE_RELATIVE.as_posix()}")
        print(f"S03 signs hash verification: source={hash_count} assets={asset_count} base_bake={R14_BAKE_RELATIVE}")
        print(f"S03 signs work_project JSON: {work_project}")
        if args.print_command or args.prepare_only:
            print("S03 signs launch command: " + shlex.join(command))
        if args.prepare_only:
            return 0
        os.execv(command[0], command)
    except LauncherError as exc:
        print(f"Saisies S03 signs review launch refused: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"Saisies S03 signs review launch failed to start Godot: {exc}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
