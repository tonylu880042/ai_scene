#!/usr/bin/env bash
# Usage: tools/export_course.sh <coast|alpine> <course> <start_min> <minutes>
# Env: CRF (default 26; the Godot output is very noisy, CRF 20 gives ~50 Mbit/s), EXPORT_EXTRA (e.g. --hq), EXPORT_SUFFIX
# Output: export/<scene>_<course>_<startmin>m/{video.mp4,camera.json,route.json,occluder.glb}
set -euo pipefail
SCENE=${1:?scene coast|alpine}; COURSE=${2:?course}; START=${3:?start minute}; MIN=${4:?minutes}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case $SCENE in coast) TSCN=res://MainScene.tscn;; alpine) TSCN=res://MainScene_alpine.tscn;; *) echo bad scene; exit 1;; esac
OUT="$ROOT/export/${SCENE}_${COURSE}_${START}m${EXPORT_SUFFIX:-}"
mkdir -p "$OUT"
FR="$OUT/_frames"
rm -rf "$FR"; mkdir -p "$FR"
cd "$ROOT"
# PNG frames encoded in segments while rendering (Godot's AVI writer stops at 4 GB, which dense grass hits within a minute)
godot --path . "$TSCN" --write-movie "$FR/f.png" --fixed-fps 60 -- --course="$COURSE" --start-min="$START" \
  --no-hud --export-dir="$OUT" --export-minutes="$MIN" ${EXPORT_EXTRA:-} > "$OUT/godot.log" 2>&1 &
GPID=$!
python3 "$ROOT/tools/frames_to_mp4.py" "$FR" "$OUT/video.mp4" 60 "${CRF:-26}" "$GPID" "${SEGMENT_FRAMES:-1800}"
wait "$GPID" || true
rm -rf "$FR"
grep -E "ERROR|TrackExporter" "$OUT/godot.log" | grep -v leaked || true
if grep -q "SCRIPT ERROR" "$OUT/godot.log"; then echo "script errors, see $OUT/godot.log"; exit 1; fi
python3 "$ROOT/tools/check_frozen.py" "$OUT/video.mp4"
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate,nb_frames -of csv=p=0 "$OUT/video.mp4"
