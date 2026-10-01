#!/usr/bin/env python3
"""Encode Godot's PNG movie frames to MP4 in segments while Godot is still rendering.

  frames_to_mp4.py <frames_dir> <out.mp4> <fps> <crf> <godot_pid> [segment_frames]

Godot's AVI (MJPEG) movie writer stops at 4 GB, which dense foliage reaches in under a minute at 1080p, so we
record PNGs instead. Every `segment_frames` (default 1800 = 30 s) complete frames are encoded as one segment with
ffmpeg's image-sequence demuxer (exact frame count, one output frame per PNG) and deleted; at the end the segments
are joined losslessly. Disk use stays at about one segment of PNGs.
(Piping PNGs through image2pipe was tried first: ffmpeg dropped/duplicated most frames - do not go back to it.)"""
import os, subprocess, sys, time

frames, out, fps, crf, pid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
SEG = int(sys.argv[6]) if len(sys.argv) > 6 else 1800
name = lambda i: os.path.join(frames, f"f{i:08d}.png")
ENC = ["-an", "-c:v", "libx264", "-preset", "medium", "-crf", crf,
       "-vf", "scale=1920:1080:out_range=tv:out_color_matrix=bt709,format=yuv420p", "-color_range", "tv",
       "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]  # PNG sRGB tags upset HW decoders


def alive(p):
    try:
        os.kill(p, 0)
        return True
    except OSError:
        return False


def encode(start, count, path):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-framerate", fps, "-start_number", str(start), "-i",
                    os.path.join(frames, "f%08d.png"), "-frames:v", str(count), *ENC, "-r", fps, path], check=True)
    for k in range(start, start + count):
        os.remove(name(k))


segs, start = [], 0
while True:
    # frames [start, start+SEG) are complete once frame start+SEG exists (Godot writes them in order)
    if os.path.exists(name(start + SEG)):
        segs.append(os.path.join(frames, f"seg{len(segs):04d}.mp4"))
        encode(start, SEG, segs[-1])
        start += SEG
        print(f"  encoded {start} frames", flush=True)
        continue
    if not alive(pid):
        time.sleep(0.5)  # let the last PNG finish writing
        n = 0
        while os.path.exists(name(start + n)):
            n += 1
        if n:
            segs.append(os.path.join(frames, f"seg{len(segs):04d}.mp4"))
            encode(start, n, segs[-1])
            start += n
        break
    time.sleep(0.5)

lst = os.path.join(frames, "segments.txt")
with open(lst, "w") as f:
    f.writelines(f"file '{s}'\n" for s in segs)
subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-c", "copy",
                "-movflags", "+faststart", out], check=True)
for s in segs:
    os.remove(s)
os.remove(lst)
print(f"encoded {start} frames in {len(segs)} segment(s) -> {out}")
