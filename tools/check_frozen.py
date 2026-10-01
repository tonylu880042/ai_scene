#!/usr/bin/env python3
"""Fail if a rendered video has frozen stretches (the movie writer repeated a stale frame).
  check_frozen.py <video.mp4> [max_run_frames=10]
A run of identical consecutive frames longer than max_run_frames means rendering stalled (e.g. the Godot window
was covered/hidden on macOS) while the camera track kept advancing - such a clip would not match camera.json."""
import subprocess, sys
import numpy as np

path = sys.argv[1]
limit = int(sys.argv[2]) if len(sys.argv) > 2 else 10
w, h = 96, 54
p = subprocess.Popen(["ffmpeg", "-v", "error", "-i", path, "-vf", f"scale={w}:{h},format=gray", "-f", "rawvideo", "-"],
                     stdout=subprocess.PIPE)
prev, run, worst, n, frozen = None, 0, (0, 0), 0, 0
while True:
    b = p.stdout.read(w * h)
    if len(b) < w * h:
        break
    f = np.frombuffer(b, np.uint8).astype(np.int16)
    if prev is not None and np.abs(f - prev).mean() < 0.05:
        run += 1
        frozen += 1
        if run > worst[0]:
            worst = (run, n - run)
    else:
        run = 0
    prev, n = f, n + 1
print(f"{n} frames, {frozen} repeated, longest frozen run {worst[0]} frames at frame {worst[1]}")
if worst[0] > limit:
    print("FROZEN VIDEO: rendering stalled (keep the Godot window visible while exporting)")
    sys.exit(1)
