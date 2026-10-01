#!/usr/bin/env python3
"""Runway video-to-video round trip for an export folder (see tools/EXPORT_README.md).

  cut      Cut a frame-exact clip from an export to upload to Runway.
             runway_clip.py cut export/alpine_summit_10m --start-frame 3000 --frames 600 --name summit_a
           -> runway/summit_a/source_1080p60.mp4, source_1080p30.mp4, clip.json
           Also writes export/<name>_raw/ (the same clip as a playable export) for A/B comparison.

  join     Concatenate consecutive conformed clips into one export (frames must be contiguous).
             runway_clip.py join summit_ab export/summit_a_runway export/summit_b_runway
           -> export/summit_ab/ ; prints the seam frame index(es) so you can inspect the hand-over.

  conform  Turn a Runway output back into a playable export aligned with the camera track.
             runway_clip.py conform runway/summit_a runway/summit_a/runway_output.mp4
           -> export/<name>_runway/ (video.mp4 retimed to the clip's exact duration at the source fps
              and scaled to the source resolution, plus the matching slice of camera.json, route.json,
              occluder.glb).  Then run tools/verify_export.py on it to measure path drift.

Retiming assumes Runway kept the clip's motion and just changed duration/fps/size slightly; the whole
output is stretched to the source duration.  --interp uses motion interpolation for the fps conversion
(smoother when Runway outputs 24 fps; slower)."""
import json, os, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def sh(*args):
    subprocess.run(args, check=True)


def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
                          "-show_entries", "stream=width,height,r_frame_rate,nb_read_frames:format=duration",
                          "-of", "json", path], check=True, capture_output=True, text=True).stdout
    j = json.loads(out)
    st = j["streams"][0]
    num, den = st["r_frame_rate"].split("/")
    return {"w": int(st["width"]), "h": int(st["height"]), "fps": float(num) / float(den),
            "frames": int(st["nb_read_frames"]), "dur": float(j["format"]["duration"])}


def slice_export(src, dst, start, count, video):
    """Write dst/ as a playable export holding frames [start, start+count) of src, with `video`."""
    os.makedirs(dst, exist_ok=True)
    cam = json.load(open(f"{src}/camera.json"))
    cam["frames"] = {k: v[start:start + count] for k, v in cam["frames"].items()}
    cam["frame_count"] = count
    cam["start_time"] = cam["frames"]["t"][0]
    json.dump(cam, open(f"{dst}/camera.json", "w"), separators=(",", ":"))
    for f in ("route.json", "occluder.glb"):
        shutil.copyfile(f"{src}/{f}", f"{dst}/{f}")
    if os.path.abspath(video) != os.path.abspath(f"{dst}/video.mp4"):
        shutil.move(video, f"{dst}/video.mp4")


def cut(export, start, count, name):
    export = os.path.join(ROOT, export) if not os.path.isabs(export) else export
    cam = json.load(open(f"{export}/camera.json"))
    fps, total = cam["fps"], cam["frame_count"]
    if start < 0 or start + count > total:
        sys.exit(f"frames {start}..{start + count} outside 0..{total}")
    out = os.path.join(ROOT, "runway", name)
    os.makedirs(out, exist_ok=True)
    trim = f"trim=start_frame={start}:end_frame={start + count},setpts=PTS-STARTPTS"
    enc = ["-an", "-c:v", "libx264", "-crf", "16", "-preset", "slow", "-pix_fmt", "yuv420p",
           "-color_range", "tv", "-movflags", "+faststart"]
    src = f"{export}/video.mp4"
    sh("ffmpeg", "-v", "error", "-y", "-i", src, "-vf", trim, *enc, f"{out}/source_1080p60.mp4")
    sh("ffmpeg", "-v", "error", "-y", "-i", src, "-vf", trim + ",fps=30", *enc, f"{out}/source_1080p30.mp4")
    json.dump({"export": os.path.relpath(export, ROOT), "start_frame": start, "frame_count": count,
               "fps": fps, "width": cam["width"], "height": cam["height"],
               "duration": count / fps}, open(f"{out}/clip.json", "w"), indent=1)
    raw = os.path.join(ROOT, "export", f"{name}_raw")
    os.makedirs(raw, exist_ok=True)
    shutil.copyfile(f"{out}/source_1080p60.mp4", f"{raw}/video.mp4")
    slice_export(export, raw, start, count, f"{raw}/video.mp4")
    p = probe(f"{out}/source_1080p60.mp4")
    if p["frames"] != count:
        sys.exit(f"cut produced {p['frames']} frames, expected {count}")
    print(f"clip: {out}/source_1080p60.mp4 ({count} frames, {count / fps:.2f}s); 30 fps copy: source_1080p30.mp4")
    print(f"A/B raw export: {raw}")


def conform(clip_dir, runway_mp4, interp):
    clip_dir = os.path.join(ROOT, clip_dir) if not os.path.isabs(clip_dir) else clip_dir
    c = json.load(open(f"{clip_dir}/clip.json"))
    name = os.path.basename(os.path.normpath(clip_dir))
    p = probe(runway_mp4)
    target = c["frame_count"] / c["fps"]
    print(f"runway output: {p['w']}x{p['h']} {p['fps']:.3f} fps, {p['frames']} frames, {p['dur']:.3f}s "
          f"(source {c['width']}x{c['height']} {c['fps']} fps, {target:.3f}s)")
    if abs(p["w"] / p["h"] - c["width"] / c["height"]) > 0.01:
        print("WARNING: aspect ratio differs from the source - Runway cropped or padded; avatars will not line up "
              "unless the framing is corrected.")
    if abs(p["dur"] - target) / target > 0.05:
        print("WARNING: duration differs by more than 5% - check that Runway kept the whole clip.")
    stretch = target / (p["frames"] / p["fps"])  # time scale so the output spans exactly the source duration
    rate = f"minterpolate=fps={c['fps']}:mi_mode=mci" if interp else f"fps={c['fps']}"
    vf = f"setpts=PTS*{stretch:.6f},{rate},scale={c['width']}:{c['height']}:flags=lanczos,trim=end_frame={c['frame_count']}"
    dst = os.path.join(ROOT, "export", f"{name}_runway")
    os.makedirs(dst, exist_ok=True)
    tmp = f"{dst}/video.mp4"
    sh("ffmpeg", "-v", "error", "-y", "-i", runway_mp4, "-vf", vf, "-an", "-c:v", "libx264", "-crf", "18",
       "-pix_fmt", "yuv420p", "-color_range", "tv", "-movflags", "+faststart", tmp)
    q = probe(tmp)
    if q["frames"] < c["frame_count"]:  # pad by holding the last frame so frame i == pose i everywhere
        pad = c["frame_count"] - q["frames"]
        sh("ffmpeg", "-v", "error", "-y", "-i", tmp, "-vf", f"tpad=stop_mode=clone:stop={pad}", "-an",
           "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", "-color_range", "tv",
           "-movflags", "+faststart", tmp + ".pad.mp4")
        os.replace(tmp + ".pad.mp4", tmp)
        q = probe(tmp)
    src = os.path.join(ROOT, c["export"])
    slice_export(src, dst, c["start_frame"], c["frame_count"], tmp)
    print(f"conformed: {dst}/video.mp4  {q['w']}x{q['h']} {q['fps']:.0f} fps {q['frames']} frames")
    print(f"next: python3 tools/verify_export.py {os.path.relpath(dst, ROOT)} --frames 0,{c['frame_count'] // 2},{c['frame_count'] - 1}")


def join(name, parts):
    parts = [os.path.join(ROOT, p) if not os.path.isabs(p) else p for p in parts]
    cams = [json.load(open(f"{p}/camera.json")) for p in parts]
    dst = os.path.join(ROOT, "export", name)
    os.makedirs(dst, exist_ok=True)
    out = cams[0]
    seams = []
    for c in cams[1:]:
        gap = c["frames"]["t"][0] - out["frames"]["t"][-1]
        if abs(gap - 1.0 / out["fps"]) > 0.25 / out["fps"]:
            sys.exit(f"clips are not contiguous (time gap {gap:.4f}s)")
        seams.append(out["frame_count"])
        for k in out["frames"]:
            out["frames"][k] = out["frames"][k] + c["frames"][k]
        out["frame_count"] += c["frame_count"]
    json.dump(out, open(f"{dst}/camera.json", "w"), separators=(",", ":"))
    for f in ("route.json", "occluder.glb"):
        shutil.copyfile(f"{parts[0]}/{f}", f"{dst}/{f}")
    lst = f"{dst}/_concat.txt"
    with open(lst, "w") as fh:
        for p in parts:
            fh.write(f"file '{p}/video.mp4'\n")
    sh("ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", "-movflags", "+faststart", f"{dst}/video.mp4")
    os.remove(lst)
    q = probe(f"{dst}/video.mp4")
    print(f"joined: {dst}/video.mp4 {q['frames']} frames (camera {out['frame_count']}); seam frame(s): {seams}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) >= 2 and a[0] == "cut":
        opt = lambda k, d: a[a.index(k) + 1] if k in a else d
        cut(a[1], int(opt("--start-frame", 0)), int(opt("--frames", 600)), opt("--name", "clip"))
    elif len(a) >= 4 and a[0] == "join":
        join(a[1], a[2:])
    elif len(a) >= 3 and a[0] == "conform":
        conform(a[1], a[2], "--interp" in a)
    else:
        sys.exit(__doc__)
