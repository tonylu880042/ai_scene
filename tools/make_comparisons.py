#!/usr/bin/env python3
"""Pair untouched video references with same-size renders; never score fidelity."""
import argparse
import hashlib
import json
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def sha256(path):
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
        return digest.hexdigest()


def prepare(manifest, project_root, renders, ids, output):
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    scenes = payload["scenes"]
    by_id = {}
    for scene in scenes:
        sid = scene["scene_id"]
        if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", sid):
            raise ValueError(f"Invalid scene ID: {sid!r}")
        if sid in by_id:
            raise ValueError(f"Duplicate scene ID: {sid}")
        by_id[sid] = scene
    selected = ids if ids is not None else list(by_id)
    if not selected or len(set(selected)) != len(selected):
        raise ValueError("Select at least one unique scene ID")
    pairs = []
    for sid in selected:
        if sid not in by_id:
            raise ValueError(f"Unknown scene ID: {sid}")
        scene = by_id[sid]
        ref = (project_root / scene["reference_image"]).resolve()
        render = (renders / f"{sid}.png").resolve()
        ref_hash, render_hash = sha256(ref), sha256(render)
        expected = scene.get("reference_sha256")
        if expected and expected != ref_hash:
            raise ValueError(f"{sid}: original reference SHA256 mismatch")
        with Image.open(ref) as left, Image.open(render) as right:
            if left.size != right.size:
                raise ValueError(f"{sid}: size mismatch {left.size} vs {right.size}")
            size = left.size
            declared = (scene.get("width", size[0]), scene.get("height", size[1]))
            if size != declared:
                raise ValueError(f"{sid}: source size differs from manifest")
            left.verify()
            right.verify()
        pairs.append({"scene_id": sid, "requested_seconds": scene.get("requested_seconds"),
                      "reference_image": str(ref), "reference_sha256": ref_hash,
                      "render_image": str(render), "render_sha256": render_hash,
                      "size": list(size), "visual_status": "not_reviewed"})
    inputs = {Path(pair[key]) for pair in pairs for key in ("reference_image", "render_image")}
    outputs = {(output / f"{pair['scene_id']}_comparison.png").resolve() for pair in pairs}
    outputs.add((output / "comparison_manifest.json").resolve())
    if inputs & outputs or manifest.resolve() in outputs:
        raise ValueError("Output would overwrite source evidence")
    return pairs


def write_pairs(pairs, output, version):
    try:
        font = ImageFont.truetype("DejaVuSans.ttf", 24)
    except OSError:
        font = ImageFont.load_default()
    output.mkdir(parents=True, exist_ok=True)
    for pair in pairs:
        width, height = pair["size"]
        canvas = Image.new("RGB", (width * 2, height + 40), (20, 24, 28))
        draw = ImageDraw.Draw(canvas)
        draw.text((10, 8), f"{pair['scene_id']} | VIDEO {pair['requested_seconds']}s | original",
                  fill="white", font=font)
        draw.text((width + 10, 8), f"{version} | RENDER | NOT REVIEWED", fill="white", font=font)
        for x, key in ((0, "reference_image"), (width, "render_image")):
            with Image.open(pair[key]) as image:
                canvas.paste(image.convert("RGB"), (x, 40))
        name = f"{pair['scene_id']}_comparison.png"
        canvas.save(output / name)
        pair["comparison_image"] = name
    report = {"schema_version": 1, "version": version,
              "scope": "Image pairing and integrity only; visual fidelity requires review",
              "pairs": pairs}
    (output / "comparison_manifest.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--renders", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ids", nargs="+")
    parser.add_argument("--version", default="candidate")
    args = parser.parse_args()
    try:
        pairs = prepare(args.manifest, args.project_root, args.renders, args.ids, args.output)
        write_pairs(pairs, args.output, args.version)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))
    print(f"Created {len(pairs)} comparisons; visual status: not_reviewed")


if __name__ == "__main__":
    main()
