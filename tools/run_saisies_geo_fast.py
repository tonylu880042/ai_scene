#!/usr/bin/env python3
"""Launch the fixed R14 geographic bake from its persistent source bundle.

The launcher intentionally has one display target.  It reconstructs a small
temporary project from ``export/saisies/review/round14_final/source_bundle``,
links the large workspace asset/cache trees, verifies the snapshot and baked
scene hashes plus the completed bake equivalence record, then replaces itself
with the local Godot process.  It never falls back to a procedural scene or
starts a bake.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
from typing import Any


BAKED_RELATIVE = Path("export/saisies/SaisiesEnvironment_geo_r14.scn")
FINAL_RELATIVE = Path("export/saisies/review/round14_final")
BUNDLE_NAME = "source_bundle"
LINKED_DIRS = ("assets", "video", "export")
LINKED_CACHE = Path(".godot/imported")
CACHE_FILES = ("global_script_class_cache.cfg", "uid_cache.bin")
COUNT_FIELDS = (
    "node_count",
    "mesh_node_count",
    "multimesh_node_count",
    "multimesh_instance_total",
    "geometry_instance_count",
    "collision_shape_count",
    "road_collision_node_count",
    "forest_multimesh_node_count",
    "multimesh_nonzero_transform_total",
)
REQUIRED_VERIFICATION_FIELDS = (
    "source_packed_counts_equal",
    "source_packed_geometry_equal",
    "native_reload_counts_equal",
    "native_reload_geometry_equal",
    "generator_scripts_stripped",
)


class LauncherError(RuntimeError):
    """A concrete artifact or snapshot error that should stop the launch."""


def project_root() -> Path:
    # The script lives in <project>/tools; this keeps the entry point portable
    # across checkouts and avoids embedding a user's home directory.
    return Path(__file__).resolve().parents[1]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise LauncherError(f"cannot read hash input {path}: {exc}") from exc
    return digest.hexdigest()


def read_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise LauncherError(f"cannot read {label} {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise LauncherError(f"{label} is not valid JSON: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise LauncherError(f"{label} must be a JSON object: {path}")
    return value


def normalize_relative(value: str) -> Path:
    candidate = Path(value)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise LauncherError(f"snapshot path escapes the project: {value}")
    if str(candidate) in ("", "."):
        raise LauncherError("snapshot contains an empty relative path")
    return candidate


def expected_hash(value: Any) -> str:
    if isinstance(value, str):
        raw = value.strip().lower()
        if raw.startswith("sha256:"):
            raw = raw[7:]
        return raw
    if isinstance(value, dict):
        for key in ("sha256", "digest", "hash"):
            if key in value:
                return expected_hash(value[key])
    return ""


def snapshot_hashes(snapshot: dict[str, Any]) -> dict[Path, str]:
    raw = snapshot.get("hashes")
    if not isinstance(raw, dict) or not raw:
        raise LauncherError("source_snapshot.json must contain a non-empty hashes object")
    hashes: dict[Path, str] = {}
    for raw_path, raw_hash in raw.items():
        relative = normalize_relative(str(raw_path))
        digest = expected_hash(raw_hash)
        if len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
            raise LauncherError(f"invalid SHA256 for snapshot path {relative}")
        if relative.parts[0] in {"assets", "video", "export", ".godot"}:
            raise LauncherError(f"snapshot must leave {relative.parts[0]} linked to the workspace: {relative}")
        hashes[relative] = digest
    project_hash = hashes.get(Path("project.godot"))
    if not project_hash:
        raise LauncherError("source_snapshot.json hashes must include project.godot")
    return hashes


def locate_artifacts(root: Path) -> tuple[Path, Path, Path]:
    final_dir = root / FINAL_RELATIVE
    bundle = final_dir / BUNDLE_NAME
    snapshot_path = bundle / "source_snapshot.json"
    baked = root / BAKED_RELATIVE
    manifest_candidates = (
        Path(str(baked) + ".manifest.json"),
        baked.with_suffix(".manifest.json"),
    )
    if not final_dir.is_dir():
        raise LauncherError(f"R14 final directory is missing: {final_dir}")
    if not bundle.is_dir():
        raise LauncherError(f"R14 source bundle is missing: {bundle}")
    if not snapshot_path.is_file():
        raise LauncherError(f"R14 source snapshot is missing: {snapshot_path}")
    if not baked.is_file():
        raise LauncherError(f"R14 baked scene is missing; refusing slow-scene fallback: {baked}")
    manifest = next((candidate for candidate in manifest_candidates if candidate.is_file()), None)
    if manifest is None:
        joined = ", ".join(str(candidate) for candidate in manifest_candidates)
        raise LauncherError(f"R14 baked manifest is missing; expected one of: {joined}")
    return bundle, snapshot_path, manifest


def verify_baked_manifest(root: Path, baked: Path, manifest_path: Path) -> dict[str, Any]:
    manifest = read_json(manifest_path, "baked manifest")
    if int(manifest.get("schema_version", 0)) != 1 or manifest.get("kind") != "saisies_geo_manual_fast_bake":
        raise LauncherError("baked manifest is not a Saisies geo manual fast bake")
    if manifest.get("native_only") is not True:
        raise LauncherError("baked manifest is not marked native_only")
    output_scene = str(manifest.get("output_scene", ""))
    if output_scene and output_scene not in {f"res://{BAKED_RELATIVE.as_posix()}", BAKED_RELATIVE.as_posix()}:
        raise LauncherError(f"baked manifest points at a different scene: {output_scene}")
    declared_sha = expected_hash(manifest.get("baked_sha256", ""))
    if len(declared_sha) != 64:
        raise LauncherError("baked manifest is missing a valid baked_sha256")
    if sha256_file(baked) != declared_sha:
        raise LauncherError(f"baked scene SHA256 does not match its manifest: {baked}")
    verification = manifest.get("verification")
    if not isinstance(verification, dict):
        raise LauncherError("baked manifest is missing its completed verification record")
    for field in REQUIRED_VERIFICATION_FIELDS:
        if verification.get(field) is not True:
            raise LauncherError(f"baked manifest verification is incomplete: {field}")
    source_summary = manifest.get("source_summary")
    baked_summary = manifest.get("baked_summary")
    if not isinstance(source_summary, dict) or not isinstance(baked_summary, dict):
        raise LauncherError("baked manifest must contain source_summary and baked_summary")
    for field in COUNT_FIELDS:
        if field not in source_summary or field not in baked_summary:
            raise LauncherError(f"baked manifest summaries are missing {field}")
        if not isinstance(source_summary[field], int) or isinstance(source_summary[field], bool):
            raise LauncherError(f"baked manifest source summary count is not an integer: {field}")
        if not isinstance(baked_summary[field], int) or isinstance(baked_summary[field], bool):
            raise LauncherError(f"baked manifest baked summary count is not an integer: {field}")
        if source_summary[field] != baked_summary[field]:
            raise LauncherError(
                f"baked manifest source/baked count mismatch for {field}: "
                f"{source_summary[field]} != {baked_summary[field]}"
            )
    source_geometry = str(source_summary.get("geometry_sha256", ""))
    baked_geometry = str(baked_summary.get("geometry_sha256", ""))
    if not source_geometry or source_geometry != baked_geometry:
        raise LauncherError("baked manifest source/baked geometry fingerprints differ")
    return manifest


def copy_snapshot_sources(root: Path, bundle: Path, restore: Path, hashes: dict[Path, str]) -> None:
    for relative, digest in hashes.items():
        source = bundle / relative
        if not source.is_file():
            # A hash-verified workspace copy is allowed for a listed source
            # file, but an unlisted current-workspace file is never imported.
            workspace_candidate = root / relative
            if workspace_candidate.is_file() and sha256_file(workspace_candidate) == digest:
                source = workspace_candidate
            else:
                raise LauncherError(f"snapshot source file is missing from the bundle: {relative}")
        actual = sha256_file(source)
        if actual != digest:
            raise LauncherError(f"snapshot SHA256 mismatch for {relative}: expected {digest}, got {actual}")
        destination = restore / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


def link_workspace_tree(root: Path, restore: Path) -> None:
    for name in LINKED_DIRS:
        source = root / name
        if not source.exists():
            raise LauncherError(f"workspace dependency required for R14 launch is missing: {source}")
        link = restore / name
        link.symlink_to(source, target_is_directory=True)

    imported_source = root / LINKED_CACHE
    if not imported_source.is_dir():
        raise LauncherError(f"workspace Godot import cache is missing: {imported_source}")
    godot_dir = restore / ".godot"
    godot_dir.mkdir(parents=True, exist_ok=True)
    (godot_dir / "imported").symlink_to(imported_source, target_is_directory=True)
    for name in CACHE_FILES:
        source = root / ".godot" / name
        if source.is_file():
            shutil.copy2(source, godot_dir / name)


def find_godot() -> str:
    configured = os.environ.get("GODOT_BIN", "").strip()
    candidates = [configured] if configured else []
    candidates.extend([shutil.which("godot") or "", shutil.which("godot4") or ""])
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return str(Path(candidate).resolve())
    raise LauncherError("local Godot executable was not found; set GODOT_BIN or put godot on PATH")


def prepare(root: Path) -> tuple[Path, str]:
    bundle, snapshot_path, baked_manifest_path = locate_artifacts(root)
    snapshot = read_json(snapshot_path, "source snapshot")
    hashes = snapshot_hashes(snapshot)
    verify_baked_manifest(root, root / BAKED_RELATIVE, baked_manifest_path)
    restore = Path(tempfile.mkdtemp(prefix="saisies_geo_fast_r14_"))
    copy_snapshot_sources(root, bundle, restore, hashes)
    # Keep the audit record with the restored project when the bundle has one;
    # it is copied only into the new temporary directory.
    shutil.copy2(snapshot_path, restore / "source_snapshot.json")
    link_workspace_tree(root, restore)
    if not (restore / "project.godot").is_file():
        raise LauncherError(f"restored source bundle did not produce project.godot: {restore}")
    return restore, str(baked_manifest_path)


def command_for(godot: str, restore: Path) -> list[str]:
    return [godot, "--path", str(restore), f"res://{BAKED_RELATIVE.as_posix()}"]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Launch the fixed native R14 Saisies geographic bake.")
    parser.add_argument("--print-command", action="store_true", help="print the exact Godot command before launch")
    parser.add_argument("--prepare-only", action="store_true", help="prepare and verify the restored project without launching Godot")
    args, unknown = parser.parse_known_args(argv)
    if unknown:
        parser.error("unsupported option(s): " + " ".join(unknown))
    root = project_root()
    try:
        restore, _manifest = prepare(root)
        godot = find_godot()
        command = command_for(godot, restore)
        print(f"R14 source restored: {restore}")
        print(f"R14 baked scene: {root / BAKED_RELATIVE}")
        if args.print_command or args.prepare_only:
            print("R14 launch command: " + shlex.join(command))
        if args.prepare_only:
            return 0
        os.execv(godot, command)
    except LauncherError as exc:
        print(f"Saisies R14 fast launch refused: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"Saisies R14 fast launch failed to start Godot: {exc}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
