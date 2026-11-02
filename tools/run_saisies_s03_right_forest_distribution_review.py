#!/usr/bin/env python3
"""Prepare and launch the fixed R28 S03 right-forest distribution review."""

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
SOURCE_BUNDLE_RELATIVE = Path("export/saisies/review/round28_s03_right_forest_distribution/source_bundle")
SNAPSHOT_RELATIVE = SOURCE_BUNDLE_RELATIVE / "source_snapshot.json"
REVIEW_SCENE_RELATIVE = Path("scenes/MainScene_saisies_s03_right_forest_distribution_review.tscn")
WORK_PROJECT_RELATIVE = Path("export/saisies/review/round28_s03_right_forest_distribution/work_project.json")
LINKED_DIRS = {"assets", "video", "export"}
R14_BAKE_RELATIVE = Path("export/saisies/SaisiesEnvironment_geo_r14.scn")


def _s01_helpers():
    spec = importlib.util.spec_from_file_location("saisies_s01_review_helpers_r28", S01_LAUNCHER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import launcher helpers: {S01_LAUNCHER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


s01 = _s01_helpers()
LauncherError = s01.LauncherError

REQUIRED_SOURCE_RELATIVES = (
    Path("project.godot"),
    REVIEW_SCENE_RELATIVE,
    Path("scenes/MainScene_saisies_s03_junction_shape_review.tscn"),
    Path("scenes/MainScene_saisies_s03_cafe_parasol_review.tscn"),
    Path("scenes/MainScene_saisies_s03_right_forest_review.tscn"),
    Path("scripts/saisies_s03_right_forest_distribution.gd"),
    Path("scripts/saisies_s03_right_forest_distribution.gd.uid"),
    Path("scripts/saisies_s03_junction_shape.gd"),
    Path("scripts/saisies_s03_right_forest_refinement.gd"),
    Path("scripts/saisies_s03_right_forest_refinement.gd.uid"),
    Path("tools/run_saisies_s03_right_forest_distribution_review.py"),
    Path("tools/run_saisies_s03_right_forest_distribution_review.command"),
)


def load_snapshot(root: Path):
    bundle = root / SOURCE_BUNDLE_RELATIVE
    snapshot_path = root / SNAPSHOT_RELATIVE
    if not bundle.is_dir() or not snapshot_path.is_file():
        raise LauncherError(f"R28 right-forest distribution source bundle is missing: {bundle}")
    snapshot = s01.read_json(snapshot_path, "R28 right-forest distribution source snapshot")
    hashes = s01.parse_hash_map(snapshot, "hashes")
    assets = s01.parse_hash_map(snapshot, "assets")
    for required in REQUIRED_SOURCE_RELATIVES:
        if required not in hashes:
            raise LauncherError(f"source snapshot hashes must include {required}")
    for relative in hashes:
        if relative.parts[0] in LINKED_DIRS | {".godot"}:
            raise LauncherError(f"source hash {relative} belongs to a linked tree")
    asset_paths, normalized_assets = s01.resolve_asset_paths(root, assets)
    base_bake, base_bake_digest = s01.parse_base_bake(snapshot, normalized_assets, asset_paths)
    if base_bake != R14_BAKE_RELATIVE:
        raise LauncherError(f"base_bake must identify {R14_BAKE_RELATIVE}, got {base_bake}")
    return bundle, hashes, normalized_assets, asset_paths, base_bake_digest


def validate_restored_scene(restore: Path) -> None:
    scene = restore / REVIEW_SCENE_RELATIVE
    junction_scene = restore / "scenes/MainScene_saisies_s03_junction_shape_review.tscn"
    if not scene.is_file() or not junction_scene.is_file() or not (restore / "project.godot").is_file():
        raise LauncherError("restored R28 source bundle is missing project or review scenes")
    scene_text = scene.read_text(encoding="utf-8")
    junction_text = junction_scene.read_text(encoding="utf-8")
    for required_text in ("MainScene_saisies_s03_junction_shape_review.tscn", "saisies_s03_right_forest_distribution.gd", "JunctionShapeReview", "RightForestDistribution"):
        if required_text not in scene_text:
            raise LauncherError(f"R28 wrapper does not reference {required_text}")
    for required_text in ("MainScene_saisies_s03_cafe_parasol_review.tscn", "saisies_s03_junction_shape.gd", "ParasolReview", "JunctionShapeRefinement"):
        if required_text not in junction_text:
            raise LauncherError(f"R27 dependency does not reference {required_text}")


def command_for(godot: str, restore: Path, distribution_off: bool) -> list[str]:
    command = [godot, "--path", str(restore), f"res://{REVIEW_SCENE_RELATIVE.as_posix()}"]
    if distribution_off:
        command.extend(["--", "--s03-right-forest-distribution-off"])
    return command


def write_work_project(root: Path, path: Path, restore: Path, command: list[str], distribution_off: bool, hash_count: int, asset_count: int) -> None:
    payload: dict[str, Any] = {
        "schema_version": 1,
        "kind": "saisies_s03_right_forest_distribution_review_work_project",
        "source_bundle": str(root / SOURCE_BUNDLE_RELATIVE),
        "restored_project": str(restore),
        "scene": f"res://{REVIEW_SCENE_RELATIVE.as_posix()}",
        "hashes_verified": hash_count,
        "assets_verified": asset_count,
        "base_bake": R14_BAKE_RELATIVE.as_posix(),
        "right_forest_distribution_off": distribution_off,
        "godot_command": command,
        "godot_command_shell": shlex.join(command),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def prepare(root: Path, distribution_off: bool):
    bundle, hashes, assets, asset_paths, base_bake_digest = load_snapshot(root)
    s01.verify_asset_hashes(root, assets, asset_paths, base_bake_digest)
    restore = Path(tempfile.mkdtemp(prefix="saisies_s03_right_forest_distribution_review_"))
    try:
        s01.verify_source_hashes(root, bundle, hashes, restore)
        shutil.copy2(root / SNAPSHOT_RELATIVE, restore / "source_snapshot.json")
        s01.link_workspace_tree(root, restore)
        validate_restored_scene(restore)
    except Exception:
        shutil.rmtree(restore, ignore_errors=True)
        raise
    godot = s01.find_godot()
    return restore, command_for(godot, restore, distribution_off), len(hashes), len(assets)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Prepare and launch the fixed R28 S03 right-forest distribution review scene.")
    parser.add_argument("--prepare-only", action="store_true", help="verify and prepare the isolated project without launching Godot")
    parser.add_argument("--s03-right-forest-distribution-off", action="store_true", help="pass --s03-right-forest-distribution-off to Godot for the R27 baseline")
    parser.add_argument("--print-command", action="store_true", help="print the exact Godot command before launching")
    args = parser.parse_args(argv)
    try:
        restore, command, hash_count, asset_count = prepare(ROOT, args.s03_right_forest_distribution_off)
        work_project = ROOT / WORK_PROJECT_RELATIVE
        write_work_project(ROOT, work_project, restore, command, args.s03_right_forest_distribution_off, hash_count, asset_count)
        print(f"S03 right-forest distribution source restored: {restore}")
        print(f"S03 right-forest distribution fixed scene: res://{REVIEW_SCENE_RELATIVE.as_posix()}")
        print(f"S03 right-forest distribution hash verification: source={hash_count} assets={asset_count} base_bake={R14_BAKE_RELATIVE}")
        print(f"S03 right-forest distribution work_project JSON: {work_project}")
        if args.print_command or args.prepare_only:
            print("S03 right-forest distribution launch command: " + shlex.join(command))
        if args.prepare_only:
            return 0
        os.execv(command[0], command)
    except LauncherError as exc:
        print(f"Saisies R28 right-forest distribution launch refused: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"Saisies R28 right-forest distribution launch failed to start Godot: {exc}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
