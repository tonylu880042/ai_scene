#!/usr/bin/env python3
"""Independent numeric check of the overlay projection (does not use Three.js).
Input: JSON from the page (window.__player: avatar foot world positions and the pixel Three.js projected them to).
Re-projects the foot positions with plain numpy using camera.json (same maths as tools/verify_export.py), compares to the
page's pixel, then checks that the foot lies on the trail: lateral lane within the trail half-width, and (using the real video
frame extracted with ffmpeg) that the video pixel under the foot is trail-coloured (same dark-gravel colour as the centre line).
usage: verify_foot.py <export_dir> foot.json"""
import json, sys, subprocess, numpy as np

exp, fj = sys.argv[1], sys.argv[2]
cam = json.load(open(f"{exp}/camera.json")); F = cam["frames"]; R = json.load(open(f"{exp}/route.json"))
W, H, fov = cam["width"], cam["height"], np.radians(cam["fov_y_deg"]); fy = (H / 2) / np.tan(fov / 2); fx = fy

def project(P, i):
    q = np.array([F["qx"][i], F["qy"][i], F["qz"][i], F["qw"][i]]); x, y, z, w = q
    Rm = np.array([[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)], [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)], [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]])
    d = Rm.T @ (np.array(P) - np.array([F["px"][i], F["py"][i], F["pz"][i]]))  # camera space, looks down -Z
    return np.array([W/2 + fx * d[0] / -d[2], H/2 - fy * d[1] / -d[2]]), -d[2]

def route(s):
    i = int(np.floor(s)); f = s - i
    g = lambda k: R[k][i] + (R[k][i+1] - R[k][i]) * f
    return np.array([g("x"), g("y"), g("z")]), np.array([g("lx"), 0, g("lz")])

def frame_img(i):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", f"{exp}/video.mp4", "-vf", f"select=eq(n\\,{i})", "-vframes", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(H, W, 3).astype(float)

def patch(img, p, r=3):
    x, y = int(round(p[0])), int(round(p[1]))
    return img[max(0, y-r):y+r+1, max(0, x-r):x+r+1].reshape(-1, 3).mean(0)

errs = []; allok = True
for rec in json.load(open(fj)):
    i = rec["frame"]; img = frame_img(i)
    print(f"--- frame {i}  (cam s={F['s'][i]:.1f} m)")
    for a in rec["av"]:
        if not a["shown"]: continue
        c, l = route(a["s"])
        foot = c + l * a["lane"]                           # expected foot = centre + left*lane (route y = trail surface)
        pj, depth = project(foot, i); pc, _ = project(c, i)
        pl, _ = project(c + l * 0.8, i); pr, _ = project(c - l * 0.8, i)   # trail edges at this s
        err_pos = np.linalg.norm(np.array(a["pos"]) - foot)
        err_px = np.linalg.norm(pj - np.array(a["px"])); errs.append(err_px)
        inside = min(pl[0], pr[0]) <= pj[0] <= max(pl[0], pr[0])
        trail_c = patch(img, pj + np.array([0, 4]))          # video pixels just below the foot point
        centre_c = patch(img, pc)                            # reference: centre line pixel (trail colour)
        outside_c = patch(img, project(c + l * 1.8, i)[0])    # off-trail reference
        d_in = np.linalg.norm(trail_c - centre_c); d_out = np.linalg.norm(trail_c - outside_c)
        ok = err_px < 0.5 and inside and abs(a["lane"]) <= 0.8
        allok &= ok
        print(f"{a['name']:5s} s={a['s']:7.1f} depth={depth:5.1f}m lane={a['lane']:+.2f}  foot px python=({pj[0]:.1f},{pj[1]:.1f}) three=({a['px'][0]:.1f},{a['px'][1]:.1f}) err={err_px:.3f}px  world err={err_pos:.4f}m  "
              f"inside trail edges px[{min(pl[0],pr[0]):.0f},{max(pl[0],pr[0]):.0f}]: {inside}   video colour under foot |d to trail|={d_in:.0f} |d to offtrail|={d_out:.0f}")
print(f"max projection error between Three.js and independent numpy: {max(errs):.3f} px;  ALL OK: {allok}")
