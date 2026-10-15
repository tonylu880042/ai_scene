#!/usr/bin/env python3
"""Trace a real lake shoreline in a fetch_real_terrain.py DEM, for route.gd's real_shore (real mountains unrolled
along the generated route).

  python3 tools/real_shore.py <dem_name> <start_lat> <start_lon> <length_m> [west|east|north|south] [north|south|east|west]
  e.g. python3 tools/real_shore.py garda_west 45.8135 10.7917 8000 west north   (Limone harbour, northward)
       LAKE_M=929.5 python3 tools/real_shore.py weissensee 46.712 13.285 9100 south east   (east-west lake: per column)

The lake is the flat minimum-level area of the DEM (LAKE_M=<metres> when a deeper valley is in the square). Per DEM row
(north / south shores: per column) the lake's westmost (or eastmost) pixel is the shore;
the line is smoothed, started at the point nearest <start>, resampled every 10 m for <length_m> and given unit normals
pointing inland. Coordinates are DEM-local metres (x east, z south, origin at the DEM centre), like real_terrain.gd.
Writes assets/terrain/<dem_name>_shore.json."""
import json, math, os, sys
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
name, lat, lon, length = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
side = sys.argv[5] if len(sys.argv) > 5 else "west"
heading = sys.argv[6] if len(sys.argv) > 6 else "north"
d = os.path.join(ROOT, "assets", "terrain")
meta = json.load(open(f"{d}/{name}.json"))
g, size = meta["grid"], meta["size_m"]
h = np.fromfile(f"{d}/{name}_h.f32", "<f4").reshape(g, g)
step = size / (g - 1)
lake = float(os.environ.get("LAKE_M", np.percentile(h, 2)))  # the lake surface is the lowest large flat area
water = np.abs(h - lake) < 1.0 if "LAKE_M" in os.environ else h < lake + 1.0
# keep the largest connected water body (flood fill from its lowest-row-sum seed)
from collections import deque
seen = np.zeros_like(water)
best = None
for seed in zip(*np.nonzero(water)):
    if seen[seed]:
        continue
    comp, q = [], deque([seed])
    seen[seed] = True
    while q:
        r, c = q.popleft()
        comp.append((r, c))
        for rr, cc in ((r + 1, c), (r - 1, c), (r, c + 1), (r, c - 1)):
            if 0 <= rr < g and 0 <= cc < g and water[rr, cc] and not seen[rr, cc]:
                seen[rr, cc] = True
                q.append((rr, cc))
    if best is None or len(comp) > len(best):
        best = comp
lake_mask = np.zeros_like(water)
for r, c in best:
    lake_mask[r, c] = True
ns = side in ("north", "south")  # east-west lake: scan columns, the shore is the lake's north- / southmost pixel
m = lake_mask.T if ns else lake_mask
rows, xs = [], []
for r in range(g):
    cols = np.nonzero(m[r])[0]
    if len(cols):
        rows.append(r)
        xs.append(cols.min() if side in ("west", "north") else cols.max())
rows, xs = np.array(rows, float), np.array(xs, float)
k = 9  # ~120 m moving average against pixel stairs
xs = np.convolve(np.pad(xs, k // 2, mode="edge"), np.ones(k) / k, mode="valid")
pts = np.stack([(xs - (g - 1) / 2) * step, (rows - (g - 1) / 2) * step], 1)  # DEM-local metres (x east, z south)
if ns:
    pts = pts[:, ::-1]
# start nearest the given lat/lon (local metric approximation around the DEM centre)
sx = (lon - meta["lon"]) * math.cos(math.radians(meta["lat"])) * 111320.0
sz = -(lat - meta["lat"]) * 110540.0
i0 = int(np.argmin(np.hypot(pts[:, 0] - sx, pts[:, 1] - sz)))
line = pts[i0::-1] if heading in ("north", "west") else pts[i0:]  # rows run north -> south, columns west -> east
seg = np.hypot(*np.diff(line, axis=0).T)
arc = np.concatenate([[0.0], np.cumsum(seg)])
s = np.arange(0.0, min(length, arc[-1]), 10.0)
P = np.stack([np.interp(s, arc, line[:, 0]), np.interp(s, arc, line[:, 1])], 1)
T = np.gradient(P, axis=0)
T /= np.linalg.norm(T, axis=1, keepdims=True)
N = np.stack([T[:, 1], -T[:, 0]], 1)
if (N[:, 1 if ns else 0].mean() > 0) == (side in ("west", "north")):  # inland = away from the lake
    N = -N
out = {"dem": name, "lake_m": lake, "step": 10.0, "points": np.round(P, 2).tolist(), "normals": np.round(N, 4).tolist()}
json.dump(out, open(f"{d}/{name}_shore.json", "w"))
print(f"{name}: lake {lake:.1f} m, shore {s[-1]:.0f} m from ({P[0][0]:.0f}, {P[0][1]:.0f}) to ({P[-1][0]:.0f}, {P[-1][1]:.0f}), "
      f"start {np.hypot(P[0][0] - sx, P[0][1] - sz):.0f} m from the requested point")
