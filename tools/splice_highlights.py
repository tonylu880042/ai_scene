#!/usr/bin/env python3
"""Cut Cycles-rendered highlight frames into a Godot course export.

  python3 tools/splice_highlights.py <export_dir> <frames_dir> [--fade 30] [--crf 20] [--out video_hybrid.mp4]

<frames_dir> holds frame_#####.png numbered by camera.json frame index (tools/blender_scene.py --camera-json), one
contiguous range a..b. They are laid over frames a..b of <export_dir>/video.mp4, fading in and out over --fade frames
so the switch between renderers is a dissolve rather than a hard cut. Same cameras, so camera.json / route.json /
occluder.glb stay valid. Writes <export_dir>/<out> (video.mp4 is kept), bt709-tagged like the exporter's output.
"""
import argparse, glob, json, os, re, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("export_dir")
ap.add_argument("frames_dir")
ap.add_argument("--fade", type=int, default=30)
ap.add_argument("--crf", type=int, default=20)
ap.add_argument("--out", default="video_hybrid.mp4")
a = ap.parse_args()

cam = json.load(open(os.path.join(a.export_dir, "camera.json")))
fps, w, h, n_total = cam["fps"], cam["width"], cam["height"], cam["frame_count"]
idx = sorted(int(re.search(r"frame_(\d+)\.png$", f).group(1)) for f in glob.glob(os.path.join(a.frames_dir, "frame_*.png")))
if not idx:
    sys.exit("no frame_#####.png in " + a.frames_dir)
first, last = idx[0], idx[-1]
if idx != list(range(first, last + 1)):
    sys.exit(f"frames {first}..{last} are not contiguous")
if last >= n_total:
    sys.exit(f"frame {last} is beyond the export's {n_total} frames")
n = last - first + 1
fade = min(a.fade, n // 2)
src = os.path.join(a.export_dir, "video.mp4")
out = os.path.join(a.export_dir, a.out)
hl = (f"[1:v]scale={w}:{h}:flags=lanczos:out_color_matrix=bt709,format=yuva420p,"
      f"fade=t=in:st=0:d={fade / fps}:alpha=1,fade=t=out:st={(n - fade) / fps}:d={fade / fps}:alpha=1,"
      f"setpts=PTS-STARTPTS+{first / fps}/TB[hl];"
      f"[0:v][hl]overlay=eof_action=pass,format=yuv420p[v]")
cmd = ["ffmpeg", "-v", "error", "-y", "-i", src, "-framerate", str(fps), "-start_number", str(first),
       "-i", os.path.join(a.frames_dir, "frame_%05d.png"), "-filter_complex", hl, "-map", "[v]",
       "-c:v", "libx264", "-crf", str(a.crf), "-preset", "slow", "-pix_fmt", "yuv420p",
       "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv",
       "-movflags", "+faststart", out]
subprocess.run(cmd, check=True)
got = int(subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries",
                          "stream=nb_read_frames", "-of", "csv=p=0", out], capture_output=True, text=True).stdout)
print(f"{out}: highlight frames {first}-{last} ({n / fps:.1f} s, {fade}-frame dissolves), {got} frames"
      f" (export has {n_total})")
if got != n_total:
    sys.exit("frame count changed - camera.json would no longer line up")
