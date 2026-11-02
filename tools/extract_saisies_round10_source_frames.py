#!/usr/bin/env python3
"""Extract full resolution, frame-indexed R10 source evidence.

The extraction intentionally uses the source frame index rather than an fps
filter.  The companion manifest records both the requested index/time and the
decoded showinfo PTS so a one-second thumbnail cannot be mistaken for an exact
source frame.  This is an evidence helper only; it never changes scene or
runtime data.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path
from typing import Any


FPS_NUM = 24_000
FPS_DEN = 1_001
REQUESTED_TIMES = (628, 629, 630, 631, 632, 633)
SOURCE_VIDEO = Path("video/Descending Col des Saisies _ French Alps #3_1080p.mp4")
DEFAULT_OUTPUT = Path("export/saisies/review/round10_analysis/source_sequence/fullres")
REFERENCE_S13 = Path("video/saisies_analysis/acceptance/S13_f015105.png")
SHOWINFO_RE = re.compile(
    r"\bn:\s*(?P<n>\d+)\s+pts:\s*(?P<pts>-?\d+)\s+pts_time:\s*(?P<pts_time>-?[0-9.]+)"
)
INPUT_TIMEBASE_RE = re.compile(r"config in time_base:\s*(?P<timebase>\d+/\d+)")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError(f"not a PNG: {path}")
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def compare_pixels(left: Path, right: Path) -> dict[str, Any]:
    try:
        from PIL import Image, ImageChops, ImageStat
    except ImportError:
        return {"available": False, "equal": None, "reason": "Pillow unavailable"}
    with Image.open(left) as left_image, Image.open(right) as right_image:
        left_rgb = left_image.convert("RGB")
        right_rgb = right_image.convert("RGB")
        if left_rgb.size != right_rgb.size:
            return {
                "available": True,
                "equal": False,
                "size_equal": False,
                "left_size": list(left_rgb.size),
                "right_size": list(right_rgb.size),
            }
        diff = ImageChops.difference(left_rgb, right_rgb)
        extrema = diff.getextrema()
        max_channel_delta = max(channel[1] for channel in extrema)
        mean_channel_delta = sum(ImageStat.Stat(diff).mean) / 3.0
        return {
            "available": True,
            "equal": diff.getbbox() is None,
            "size_equal": True,
            "size": list(left_rgb.size),
            "max_channel_delta": max_channel_delta,
            "mean_channel_delta": mean_channel_delta,
        }


def requested_frames() -> list[dict[str, Any]]:
    result = []
    for requested_time in REQUESTED_TIMES:
        frame_index = round(requested_time * FPS_NUM / FPS_DEN)
        result.append(
            {
                "requested_time_s": float(requested_time),
                "frame_index": int(frame_index),
                "requested_frame_time_s": frame_index * FPS_DEN / FPS_NUM,
            }
        )
    return result


def run_extraction(video: Path, output_dir: Path) -> tuple[list[dict[str, Any]], str, str]:
    output_dir.mkdir(parents=True, exist_ok=True)
    requests = requested_frames()
    indices = [str(item["frame_index"]) for item in requests]
    # showinfo must see the selected frames before any output-rate conversion.
    select_expression = "select=" + "+".join(f"eq(n\\,{index})" for index in indices) + ",showinfo"
    selected_pattern = output_dir / "_selected_%02d.png"
    command = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "info",
        "-i",
        str(video),
        "-vf",
        select_expression,
        "-fps_mode",
        "passthrough",
        "-frames:v",
        str(len(requests)),
        str(selected_pattern),
    ]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    showinfo_log = output_dir / "fullres_source_frames_showinfo.log"
    showinfo_log.write_text(completed.stderr)
    if completed.returncode != 0:
        raise RuntimeError(f"ffmpeg extraction failed ({completed.returncode}); see {showinfo_log}")
    matches = list(SHOWINFO_RE.finditer(completed.stderr))
    if len(matches) != len(requests):
        raise RuntimeError(
            f"expected {len(requests)} showinfo frame records, found {len(matches)}; see {showinfo_log}"
        )
    # showinfo prints both input and output time bases.  Preserve the input
    # timebase (the output image stream reports 0/0), which is what makes the
    # decoded PTS comparable with the source frame index.
    timebases = sorted(set(match.group("timebase") for match in INPUT_TIMEBASE_RE.finditer(completed.stderr)))
    timebase = timebases[0] if timebases else "unknown"
    records: list[dict[str, Any]] = []
    for ordinal, (request, match) in enumerate(zip(requests, matches), start=1):
        selected = output_dir / f"_selected_{ordinal:02d}.png"
        if not selected.is_file():
            raise RuntimeError(f"missing selected output: {selected}")
        frame_path = output_dir / (
            f"source_{int(request['requested_time_s'])}_frame{int(request['frame_index']):05d}.png"
        )
        selected.replace(frame_path)
        width, height = png_size(frame_path)
        actual_pts = int(match.group("pts"))
        actual_pts_time = float(match.group("pts_time"))
        records.append(
            {
                **request,
                "decoded_output_ordinal": ordinal,
                "decoded_showinfo_n": int(match.group("n")),
                "actual_pts": actual_pts,
                "actual_pts_time_s": actual_pts_time,
                "requested_vs_actual_pts_delta_s": actual_pts_time - float(request["requested_frame_time_s"]),
                "timebase": timebase,
                "width": width,
                "height": height,
                "sha256": sha256(frame_path),
                "file": frame_path.as_posix(),
            }
        )
    for stale in output_dir.glob("_selected_*.png"):
        stale.unlink()
    return records, timebase, " ".join(command)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    parser.add_argument("--video", type=Path, default=SOURCE_VIDEO)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    project_root = args.project_root.resolve()
    video = (project_root / args.video).resolve() if not args.video.is_absolute() else args.video.resolve()
    output_dir = (project_root / args.output_dir).resolve() if not args.output_dir.is_absolute() else args.output_dir.resolve()
    reference = (project_root / REFERENCE_S13).resolve()
    if not video.is_file():
        raise SystemExit(f"source video missing: {video}")
    if not reference.is_file():
        raise SystemExit(f"S13 reference missing: {reference}")
    records, timebase, command = run_extraction(video, output_dir)
    extracted_630 = next(item for item in records if item["requested_time_s"] == 630.0)
    extracted_630_path = Path(extracted_630["file"])
    reference_width, reference_height = png_size(reference)
    reference_sha = sha256(reference)
    comparison = {
        "reference_file": reference.as_posix(),
        "reference_frame_index": 15105,
        "reference_width": reference_width,
        "reference_height": reference_height,
        "reference_sha256": reference_sha,
        "extracted_file": extracted_630_path.as_posix(),
        "extracted_sha256": extracted_630["sha256"],
        "sha256_equal": reference_sha == extracted_630["sha256"],
        "pixel_comparison": compare_pixels(reference, extracted_630_path),
        "interpretation": "Frame index 15105 is the existing S13 reference time sample; any PNG encoding/hash difference is reported separately from pixel equality.",
    }
    manifest = {
        "schema_version": 1,
        "id": "saisies_round10_fullres_source_frames",
        "status": "evidence_only",
        "note": "Exact source frame-index extraction for R10 visual evidence. Requested seconds are labels; decoded showinfo PTS is the actual frame timing. This is not camera calibration or GPS.",
        "video": "res://video/Descending Col des Saisies _ French Alps #3_1080p.mp4",
        "nominal_fps": {"numerator": FPS_NUM, "denominator": FPS_DEN, "value": FPS_NUM / FPS_DEN},
        "selection": {
            "method": "ffmpeg select=eq(n,frame_index),showinfo",
            "indices": [item["frame_index"] for item in records],
            "timebase": timebase,
            "command": command,
            "showinfo_log": (output_dir / "fullres_source_frames_showinfo.log").as_posix(),
        },
        "frames": records,
        "s13_frame15105_reference_comparison": comparison,
        "span_annotation_policy": "Use decoded actual PTS and full-resolution visual review to label feature boundaries as estimated frame spans. Do not promote legacy route-proportion landmarks to source-backed evidence.",
    }
    manifest_path = output_dir / "fullres_source_frames_manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"manifest": manifest_path.as_posix(), "frames": records, "reference_comparison": comparison}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
