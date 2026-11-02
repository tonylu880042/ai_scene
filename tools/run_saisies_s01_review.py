#!/usr/bin/env python3
"""Prepare and launch the fixed S01 review project from its source bundle.

The review scene is restored into a temporary project from the persistent
bundle at ``export/saisies/review/round15_s01/source_bundle``.  Source files
listed by ``hashes`` are copied only from that bundle.  Large runtime trees
are linked from the workspace after every listed ``assets`` hash has been
verified, so a live scripts/data tree cannot silently replace the frozen
review source.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile
from typing import Any


SOURCE_BUNDLE_RELATIVE = Path("export/saisies/review/round15_s01/source_bundle")
SNAPSHOT_RELATIVE = SOURCE_BUNDLE_RELATIVE / "source_snapshot.json"
REVIEW_SCENE_RELATIVE = Path("scenes/MainScene_saisies_s01_review.tscn")
WORK_PROJECT_RELATIVE = Path("export/saisies/review/round15_s01/work_project.json")
LINKED_DIRS = ("assets", "video", "export")
LINKED_CACHE = Path(".godot/imported")
CACHE_FILES = ("global_script_class_cache.cfg", "uid_cache.bin")
FACADE_ASSET_RELATIVE = Path("assets/textures/saisies_s01_restaurant_facade_v1.png")
R14_BAKE_RELATIVE = Path("export/saisies/SaisiesEnvironment_geo_r14.scn")
REQUIRED_SOURCE_RELATIVES = (
	Path("project.godot"),
	REVIEW_SCENE_RELATIVE,
	Path("scripts/saisies_s01_camera_controller.gd"),
	Path("scripts/saisies_s01_architecture.gd"),
	Path("scripts/saisies_s01_landscape.gd"),
	Path("data/saisies_s01_camera_calibration.json"),
)


class LauncherError(RuntimeError):
	"""A concrete missing, malformed, or hash-mismatched review artifact."""


def project_root() -> Path:
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


def normalize_relative(value: Any, label: str) -> Path:
	raw = str(value).strip()
	if not raw or raw in {".", ".."}:
		raise LauncherError(f"{label} contains an empty relative path")
	if "\x00" in raw or "\\" in raw or raw.startswith("res://"):
		raise LauncherError(f"{label} is not a portable relative path: {raw}")
	candidate = Path(raw)
	if candidate.is_absolute() or ".." in candidate.parts or "." in candidate.parts:
		raise LauncherError(f"{label} path escapes the project: {raw}")
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


def parse_hash_map(snapshot: dict[str, Any], key: str) -> dict[Path, str]:
	raw_map = snapshot.get(key)
	if not isinstance(raw_map, dict) or not raw_map:
		raise LauncherError(f"source_snapshot.json must contain a non-empty {key} object")
	result: dict[Path, str] = {}
	for raw_path, raw_digest in raw_map.items():
		relative = normalize_relative(raw_path, f"{key} entry")
		digest = expected_hash(raw_digest)
		if len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
			raise LauncherError(f"invalid SHA256 for {key} path {relative}")
		if relative in result:
			raise LauncherError(f"duplicate normalized {key} path {relative}")
		result[relative] = digest
	return result


def load_snapshot(
	root: Path,
) -> tuple[Path, dict[str, Any], dict[Path, str], dict[Path, str], dict[Path, Path], str]:
	bundle = root / SOURCE_BUNDLE_RELATIVE
	snapshot_path = root / SNAPSHOT_RELATIVE
	if not bundle.is_dir():
		raise LauncherError(f"S01 source bundle is missing: {bundle}")
	if not snapshot_path.is_file():
		raise LauncherError(f"S01 source snapshot is missing: {snapshot_path}")
	snapshot = read_json(snapshot_path, "source snapshot")
	hashes = parse_hash_map(snapshot, "hashes")
	assets = parse_hash_map(snapshot, "assets")
	for required in REQUIRED_SOURCE_RELATIVES:
		if required not in hashes:
			raise LauncherError(f"source snapshot hashes must include {required}")
	for relative in hashes:
		if relative.parts[0] in set(LINKED_DIRS) | {".godot"}:
			raise LauncherError(
				f"source hash {relative} belongs to a linked tree; put runtime assets in assets instead of hashes"
			)
	asset_paths, normalized_assets = resolve_asset_paths(root, assets)
	if FACADE_ASSET_RELATIVE not in normalized_assets:
		raise LauncherError(f"source snapshot assets must include {FACADE_ASSET_RELATIVE}")
	base_bake, base_bake_digest = parse_base_bake(snapshot, normalized_assets, asset_paths)
	if base_bake != R14_BAKE_RELATIVE:
		raise LauncherError(f"base_bake must identify {R14_BAKE_RELATIVE}, got {base_bake}")
	return bundle, snapshot, hashes, normalized_assets, asset_paths, base_bake_digest


def resolve_asset_paths(root: Path, assets: dict[Path, str]) -> tuple[dict[Path, Path], dict[Path, str]]:
	"""Map manifest keys to linked-tree paths without guessing across roots."""
	resolved: dict[Path, Path] = {}
	normalized_hashes: dict[Path, str] = {}
	for manifest_relative in assets:
		if manifest_relative.parts[0] in LINKED_DIRS:
			candidates = [manifest_relative]
		else:
			candidates = [Path(name) / manifest_relative for name in LINKED_DIRS]
		existing = [candidate for candidate in candidates if (root / candidate).is_file()]
		if len(existing) == 0:
			raise LauncherError(
				f"listed asset is missing from the workspace linked trees: {manifest_relative}"
			)
		if len(existing) > 1:
			raise LauncherError(
				f"listed asset path is ambiguous across linked trees: {manifest_relative}: {existing}"
			)
		relative = existing[0]
		if relative in resolved:
			raise LauncherError(f"duplicate normalized asset path {relative}")
		resolved[relative] = root / relative
		normalized_hashes[relative] = assets[manifest_relative]
	return resolved, normalized_hashes


def parse_base_bake(
	snapshot: dict[str, Any], assets: dict[Path, str], asset_paths: dict[Path, Path]
) -> tuple[Path, str]:
	"""Accept either an asset-map bake entry or an explicit base_bake record."""
	if R14_BAKE_RELATIVE in asset_paths:
		return R14_BAKE_RELATIVE, assets[R14_BAKE_RELATIVE]
	raw = snapshot.get("base_bake")
	if raw is None:
		raise LauncherError(
			f"source snapshot assets must include {R14_BAKE_RELATIVE} or define base_bake explicitly"
		)
	if isinstance(raw, str):
		relative = normalize_relative(raw, "base_bake")
	else:
		if not isinstance(raw, dict):
			raise LauncherError("base_bake must be a relative path or an object")
		relative = normalize_relative(
			raw.get("relative", raw.get("path", raw.get("file", ""))), "base_bake"
		)
	if relative.parts[0] not in LINKED_DIRS:
		# An unqualified base_bake path is allowed only when it resolves into a
		# unique linked tree, using the same rules as the assets map.
		matches = [candidate for candidate in asset_paths if candidate.name == relative.name and candidate.as_posix().endswith(relative.as_posix())]
		if len(matches) == 1:
			relative = matches[0]
	if relative != R14_BAKE_RELATIVE:
		raise LauncherError(f"base_bake must identify {R14_BAKE_RELATIVE}, got {relative}")
	if relative not in asset_paths:
		# A separate base_bake record may carry the digest while the asset map
		# contains other linked files; still require its explicit hash.
		digest = expected_hash(raw) if isinstance(raw, dict) else ""
		if len(digest) != 64:
			raise LauncherError("base_bake is not present in assets and has no valid SHA256")
		return relative, digest
	return relative, assets[relative]


def safe_bundle_file(bundle: Path, relative: Path) -> Path:
	bundle_root = bundle.resolve()
	source = bundle / relative
	try:
		resolved = source.resolve(strict=True)
	except OSError as exc:
		raise LauncherError(f"source bundle file is missing: {relative}") from exc
	try:
		resolved.relative_to(bundle_root)
	except ValueError as exc:
		raise LauncherError(f"source bundle path escapes bundle through a symlink: {relative}") from exc
	if not resolved.is_file():
		raise LauncherError(f"source bundle path is not a file: {relative}")
	return resolved


def verify_source_hashes(root: Path, bundle: Path, hashes: dict[Path, str], restore: Path) -> None:
	for relative, expected in hashes.items():
		source = safe_bundle_file(bundle, relative)
		actual = sha256_file(source)
		if actual != expected:
			raise LauncherError(
				f"source snapshot SHA256 mismatch for {relative}: expected {expected}, got {actual}"
			)
		destination = restore / relative
		destination.parent.mkdir(parents=True, exist_ok=True)
		shutil.copy2(source, destination)


def verify_asset_hashes(
	root: Path,
	assets: dict[Path, str],
	asset_paths: dict[Path, Path],
	base_bake_digest: str,
) -> None:
	for relative, expected in assets.items():
		resolved = asset_paths.get(relative)
		if resolved is None:
			# This can only be the explicit base_bake form, handled below.
			continue
		if not resolved.is_file():
			raise LauncherError(f"linked asset is missing: {relative}")
		actual = sha256_file(resolved)
		if actual != expected:
			raise LauncherError(
				f"linked asset SHA256 mismatch for {relative}: expected {expected}, got {actual}"
			)
	base_path = root / R14_BAKE_RELATIVE
	if not base_path.is_file():
		raise LauncherError(f"base R14 bake is missing from linked export: {R14_BAKE_RELATIVE}")
	if sha256_file(base_path) != base_bake_digest:
		raise LauncherError(f"base R14 bake SHA256 mismatch: {R14_BAKE_RELATIVE}")


def link_workspace_tree(root: Path, restore: Path) -> None:
	for name in LINKED_DIRS:
		source = root / name
		if not source.is_dir():
			raise LauncherError(f"workspace dependency required for S01 review is missing: {source}")
		(restore / name).symlink_to(source.resolve(), target_is_directory=True)

	imported_source = root / LINKED_CACHE
	if not imported_source.is_dir():
		raise LauncherError(f"workspace Godot import cache is missing: {imported_source}")
	godot_dir = restore / ".godot"
	godot_dir.mkdir(parents=True, exist_ok=True)
	(godot_dir / "imported").symlink_to(imported_source.resolve(), target_is_directory=True)
	for name in CACHE_FILES:
		source = root / ".godot" / name
		if source.is_file():
			shutil.copy2(source, godot_dir / name)


def validate_restored_scene(restore: Path) -> None:
	project = restore / "project.godot"
	scene = restore / REVIEW_SCENE_RELATIVE
	if not project.is_file():
		raise LauncherError(f"restored source bundle did not produce project.godot: {project}")
	if not scene.is_file():
		raise LauncherError(f"restored source bundle is missing fixed S01 scene: {scene}")
	try:
		text = scene.read_text(encoding="utf-8")
	except OSError as exc:
		raise LauncherError(f"cannot read fixed S01 scene: {scene}: {exc}") from exc
	if "SaisiesEnvironment_geo_r14.scn" not in text:
		raise LauncherError(
			"fixed S01 scene does not reference the R14 baked world; refusing procedural or fallback launch"
		)


def find_godot() -> str:
	configured = os.environ.get("GODOT_BIN", "").strip()
	candidates = [configured] if configured else []
	candidates.extend([shutil.which("godot") or "", shutil.which("godot4") or ""])
	for candidate in candidates:
		if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
			return str(Path(candidate).resolve())
	raise LauncherError("local Godot executable was not found; set GODOT_BIN or put godot on PATH")


def command_for(godot: str, restore: Path, tour: bool) -> list[str]:
	command = [godot, "--path", str(restore), f"res://{REVIEW_SCENE_RELATIVE.as_posix()}"]
	if tour:
		command.extend(["--", "--tour"])
	return command


def write_work_project(
	root: Path,
	path: Path,
	restore: Path,
	command: list[str],
	tour: bool,
	hash_count: int,
	asset_count: int,
) -> None:
	payload = {
		"schema_version": 1,
		"kind": "saisies_s01_review_work_project",
		"source_bundle": str(root / SOURCE_BUNDLE_RELATIVE),
		"restored_project": str(restore),
		"scene": f"res://{REVIEW_SCENE_RELATIVE.as_posix()}",
		"hashes_verified": hash_count,
		"assets_verified": asset_count,
		"base_bake": R14_BAKE_RELATIVE.as_posix(),
		"facade_texture": FACADE_ASSET_RELATIVE.as_posix(),
		"tour": {
			"enabled": tour,
			"station_start_m": 0.0 if tour else 50.0,
			"station_end_m": 220.0,
			"speed_kmh": 30.0,
		},
		"godot_command": command,
		"godot_command_shell": shlex.join(command),
	}
	path.parent.mkdir(parents=True, exist_ok=True)
	temporary = path.with_name(path.name + ".tmp")
	temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
	temporary.replace(path)


def prepare(root: Path, tour: bool) -> tuple[Path, list[str], int, int]:
	bundle, snapshot, hashes, assets, asset_paths, base_bake_digest = load_snapshot(root)
	verify_asset_hashes(root, assets, asset_paths, base_bake_digest)
	restore = Path(tempfile.mkdtemp(prefix="saisies_s01_review_"))
	try:
		verify_source_hashes(root, bundle, hashes, restore)
		shutil.copy2(root / SNAPSHOT_RELATIVE, restore / "source_snapshot.json")
		link_workspace_tree(root, restore)
		validate_restored_scene(restore)
	except Exception:
		shutil.rmtree(restore, ignore_errors=True)
		raise
	godot = find_godot()
	return restore, command_for(godot, restore, tour), len(hashes), len(assets)


def main(argv: list[str]) -> int:
	parser = argparse.ArgumentParser(
		description="Prepare and launch the fixed Saisies S01 review scene from its persistent source bundle."
	)
	parser.add_argument(
		"--prepare-only",
		action="store_true",
		help="verify and prepare the isolated project, write work_project.json, and do not launch Godot",
	)
	parser.add_argument(
		"--tour",
		action="store_true",
		help="pass the bounded S01 tour argument: 0..220 m at 30 km/h",
	)
	parser.add_argument(
		"--print-command",
		action="store_true",
		help="print the exact Godot command before launching",
	)
	args = parser.parse_args(argv)
	root = project_root()
	try:
		restore, command, hash_count, asset_count = prepare(root, args.tour)
		work_project = root / WORK_PROJECT_RELATIVE
		write_work_project(root, work_project, restore, command, args.tour, hash_count, asset_count)
		print(f"S01 source restored: {restore}")
		print(f"S01 fixed scene: res://{REVIEW_SCENE_RELATIVE.as_posix()}")
		print(f"S01 hash verification: source={hash_count} assets={asset_count} base_bake={R14_BAKE_RELATIVE}")
		print(f"S01 work_project JSON: {work_project}")
		if args.print_command or args.prepare_only:
			print("S01 launch command: " + shlex.join(command))
		if args.prepare_only:
			return 0
		os.execv(command[0], command)
	except LauncherError as exc:
		print(f"Saisies S01 review launch refused: {exc}", file=sys.stderr)
		return 2
	except OSError as exc:
		print(f"Saisies S01 review launch failed to start Godot: {exc}", file=sys.stderr)
		return 3
	return 0


if __name__ == "__main__":
	raise SystemExit(main(sys.argv[1:]))
