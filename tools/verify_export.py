#!/usr/bin/env python3
"""Verify an export folder: overlay projected route centre-line on video frames.
Usage: verify_export.py <export_dir> [--frames 0,120,300] [--markers]
--markers: folder was exported with --export-markers (magenta debug spheres every 5 m);
           measures pixel error between projected sphere positions and detected magenta blobs.
Outputs overlay_<frame>.png into <export_dir>/verify/."""
import json, math, subprocess, sys, os
import numpy as np
from PIL import Image, ImageDraw

d = sys.argv[1]
frames = [0, 120, 300]
markers = "--markers" in sys.argv
if "--frames" in sys.argv:
    frames = [int(x) for x in sys.argv[sys.argv.index("--frames") + 1].split(",")]
cam = json.load(open(f"{d}/camera.json")); route = json.load(open(f"{d}/route.json"))
F = cam["frames"]; W, H = cam["width"], cam["height"]
R = {k: np.array(route[k]) for k in ("x", "y", "z", "lx", "lz")}
os.makedirs(f"{d}/verify", exist_ok=True)

def quat_mat(x, y, z, w):
    return np.array([[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
                     [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
                     [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]])

def project(i, P):
    """P: (n,3) world points -> (n,2) pixels, valid mask. Camera looks down -Z, vertical fov."""
    c = np.array([F["px"][i], F["py"][i], F["pz"][i]])
    Rm = quat_mat(F["qx"][i], F["qy"][i], F["qz"][i], F["qw"][i])
    v = (P - c) @ Rm  # = R^T (P - c)
    f = 1.0 / math.tan(math.radians(cam["fov_y_deg"]) / 2)
    ok = v[:, 2] < -cam["near"]
    zz = np.where(ok, -v[:, 2], 1.0)
    u = (v[:, 0] * f / (W / H) / zz + 1) / 2 * W
    w = (1 - v[:, 1] * f / zz) / 2 * H
    return np.stack([u - 0.5, w - 0.5], 1), ok  # pixel-index coords (pixel centre = integer)

def route_pts(s0, s1, step=1):
    idx = np.arange(int(math.ceil(s0)), int(s1) + 1, step)
    idx = idx[idx < len(R["x"])]
    return np.stack([R["x"][idx], R["y"][idx], R["z"][idx]], 1), idx

def blobs(mask):
    """Connected components (8-neighbour) of a boolean mask -> centroids (x,y), sizes."""
    pts = set(map(tuple, np.argwhere(mask)))
    cents, sizes = [], []
    while pts:
        st = [pts.pop()]; comp = []
        while st:
            y, x = st.pop(); comp.append((y, x))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    n = (y + dy, x + dx)
                    if n in pts:
                        pts.remove(n); st.append(n)
        c = np.array(comp)
        cents.append((c[:, 1].mean(), c[:, 0].mean())); sizes.append(len(comp))
    return cents, sizes

def get_frame(i):
    p = f"{d}/verify/frame_{i}.png"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", f"{d}/video.mp4", "-vf",
                    f"select=eq(n\\,{i})", "-vframes", "1", p], check=True)
    return Image.open(p).convert("RGB")

print(f"frames={cam['frame_count']} fps={cam['fps']} {W}x{H} fov={cam['fov_y_deg']}")
for i in frames:
    img = get_frame(i)
    s = F["s"][i]
    P, idx = route_pts(s + 2, s + 80)
    uv, ok = project(i, P)
    dr = ImageDraw.Draw(img)
    for (u, w), o in zip(uv, ok):
        if o and 0 <= u < W and 0 <= w < H:
            dr.ellipse([u-3, w-3, u+3, w+3], fill=(255, 0, 0))
    # trail edges (road_left/right) at 10 m, to show the dot sits inside the trail
    j = int(round(s + 10))
    for sign, col in ((1, (0, 255, 255)), (-1, (0, 255, 255))):
        off = route["road_left"] if sign > 0 else -route["road_right"]
        e = np.array([[R["x"][j] + R["lx"][j]*off, R["y"][j], R["z"][j] + R["lz"][j]*off]])
        (u, w), = project(i, e)[0]
        dr.ellipse([u-4, w-4, u+4, w+4], outline=col, width=2)
    c10, _ = project(i, np.array([[R["x"][j], R["y"][j], R["z"][j]]]))
    print(f"frame {i}: s={s:.2f} centre@+10m -> px ({c10[0][0]:.1f},{c10[0][1]:.1f})")
    img.save(f"{d}/verify/overlay_{i}.png")
    if markers:
        a = np.asarray(img if False else Image.open(f"{d}/verify/frame_{i}.png").convert("RGB")).astype(int)
        mask = (a[..., 0] > 200) & (a[..., 2] > 200) & (a[..., 1] < 90)
        cents, sizes = blobs(mask)
        cents = np.array(cents).reshape(-1, 2)
        errs = []
        t0 = math.floor(cam["start_time"] / 60.0) * 60.0  # markers: start_offset + 5 m * n (whole-minute start)
        if "--start-min" in sys.argv:
            t0 = float(sys.argv[sys.argv.index("--start-min") + 1]) * 60.0
        st = t0 * cam["speed_mps"]
        good = [(c, n) for c, n in zip(cents, sizes) if n >= 10]
        gc = np.array([g[0] for g in good]).reshape(-1, 2)
        for n in range(200):
            sm = st + 5.0 * n
            if not (s + 4 < sm < s + 30): continue  # near markers only (far ones are a few px wide)
            k = int(sm); f = sm - k
            P = np.array([[R["x"][k]*(1-f) + R["x"][k+1]*f, R["y"][k]*(1-f) + R["y"][k+1]*f + 0.12,
                           R["z"][k]*(1-f) + R["z"][k+1]*f]])
            q, ok = project(i, P)
            if not ok[0] or len(gc) == 0: continue
            dd = np.hypot(*(gc - q[0]).T)
            m = dd.argmin()
            if dd[m] < 12: errs.append((dd[m], q[0] - gc[m]))
        if errs:
            e = np.array([x[0] for x in errs]); dv = np.array([x[1] for x in errs])
            print(f"   markers matched={len(errs)} mean err={e.mean():.2f}px median={np.median(e):.2f}px max={e.max():.2f}px mean(dx,dy)=({dv[:,0].mean():+.2f},{dv[:,1].mean():+.2f})")
        else:
            print("   no markers matched")
