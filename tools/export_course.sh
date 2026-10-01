#!/usr/bin/env bash
# Usage: tools/export_course.sh <coast|alpine> <course> <start_min> <minutes>
# Env: CRF (default 26; the Godot output is very noisy, CRF 20 gives ~50 Mbit/s), EXPORT_EXTRA, EXPORT_SUFFIX
# Output: export/<scene>_<course>_<startmin>m/{video.mp4,camera.json,route.json,occluder.glb}
set -euo pipefail
SCENE=${1:?scene coast|alpine}; COURSE=${2:?course}; START=${3:?start minute}; MIN=${4:?minutes}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case $SCENE in coast) TSCN=res://MainScene.tscn;; alpine) TSCN=res://MainScene_alpine.tscn;; *) echo bad scene; exit 1;; esac
OUT="$ROOT/export/${SCENE}_${COURSE}_${START}m${EXPORT_SUFFIX:-}"
mkdir -p "$OUT"
AVI="$OUT/_tmp.avi"
cd "$ROOT"
godot --path . "$TSCN" --write-movie "$AVI" --fixed-fps 60 -- --course="$COURSE" --start-min="$START" \
  --no-hud --export-dir="$OUT" --export-minutes="$MIN" ${EXPORT_EXTRA:-} 2>&1 | tee "$OUT/godot.log" | grep -E "ERROR|TrackExporter" || true
if grep -q "SCRIPT ERROR" "$OUT/godot.log"; then echo "script errors, see $OUT/godot.log"; exit 1; fi
ffmpeg -y -loglevel error -i "$AVI" -an -c:v libx264 -preset medium -crf "${CRF:-26}" \
  -vf "scale=1920:1080:in_range=pc:out_range=tv,format=yuv420p" -color_range tv -r 60 -movflags +faststart "$OUT/video.mp4"
rm -f "$AVI"
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate,nb_frames -of csv=p=0 "$OUT/video.mp4"
