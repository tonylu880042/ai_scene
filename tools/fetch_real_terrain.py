#!/usr/bin/env python3
"""Fetch a real alpine backdrop: elevation + orthophoto for a square around a lat/lon.

  python3 tools/fetch_real_terrain.py [name] [lat] [lon] [size_km]
  default: jungfrau 46.5853 7.9614 24   (Kleine Scheidegg: Eiger / Moench / Jungfrau, Lauterbrunnen, Grindelwald)

Sources (both free, attribution required - see player/scene credits):
  elevation  AWS Terrain Tiles (terrarium PNG, z12 ~26 m/px here)  https://registry.opendata.aws/terrain-tiles/
  imagery    swisstopo SWISSIMAGE WMTS (z14 ~6.6 m/px here)        (c) swisstopo, Federal Office of Topography

Writes assets/terrain/<name>_h.f32 (GRID x GRID float32 metres, row 0 = north), <name>_albedo.jpg, <name>.json."""
import io, json, math, os, sys, urllib.request
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
name, lat, lon, size_km = (sys.argv[1:] + ["jungfrau", "46.5853", "7.9614", "24"][len(sys.argv) - 1:])[:4]
lat, lon, size_m = float(lat), float(lon), float(size_km) * 1000.0
GRID = 512        # height samples per side
ALBEDO = 4096     # orthophoto pixels per side
UA = {"User-Agent": "Mozilla/5.0 (ai_scene terrain fetch)"}


def get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60).read()


def world_px(z):  # global web-mercator pixel coords of the centre at zoom z (256 px tiles)
    n = 256 * 2 ** z
    return (lon + 180) / 360 * n, (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n


def mosaic(z, url, out_px, decode):
    """Crop a size_m square around the centre from tiles at zoom z, resampled to out_px."""
    m_per_px = 40075016.686 * math.cos(math.radians(lat)) / (256 * 2 ** z)
    half = size_m / 2 / m_per_px
    cx, cy = world_px(z)
    x0, y0, x1, y1 = cx - half, cy - half, cx + half, cy + half
    tx0, ty0, tx1, ty1 = int(x0 // 256), int(y0 // 256), int(x1 // 256), int(y1 // 256)
    canvas = None
    for ty in range(ty0, ty1 + 1):
        for tx in range(tx0, tx1 + 1):
            tile = decode(Image.open(io.BytesIO(get(url.format(z=z, x=tx, y=ty)))))
            if canvas is None:
                canvas = np.zeros(((ty1 - ty0 + 1) * 256, (tx1 - tx0 + 1) * 256) + tile.shape[2:], tile.dtype)
            canvas[(ty - ty0) * 256:(ty - ty0 + 1) * 256, (tx - tx0) * 256:(tx - tx0 + 1) * 256] = tile
        print(f"  z{z} row {ty - ty0 + 1}/{ty1 - ty0 + 1}", flush=True)
    ox, oy = x0 - tx0 * 256, y0 - ty0 * 256
    crop = canvas[int(oy):int(oy + 2 * half), int(ox):int(ox + 2 * half)]
    if crop.ndim == 2:
        return np.asarray(Image.fromarray(crop.astype(np.float32), "F").resize((out_px, out_px), Image.BILINEAR))
    return Image.fromarray(crop).resize((out_px, out_px), Image.LANCZOS)


terrarium = lambda im: (lambda a: a[..., 0] * 256.0 + a[..., 1] + a[..., 2] / 256.0 - 32768.0)(
    np.asarray(im.convert("RGB"), dtype=np.float64)).astype(np.float32)
rgb = lambda im: np.asarray(im.convert("RGB"))

out = os.path.join(ROOT, "assets", "terrain")
os.makedirs(out, exist_ok=True)
print("elevation…")
h = mosaic(12, "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png", GRID, terrarium)
h.astype("<f4").tofile(f"{out}/{name}_h.f32")
print("orthophoto…")
img = mosaic(14, "https://wmts.geo.admin.ch/1.0.0/ch.swisstopo.swissimage/default/current/3857/{z}/{x}/{y}.jpeg", ALBEDO, rgb)
img.save(f"{out}/{name}_albedo.jpg", quality=90)
meta = {"name": name, "lat": lat, "lon": lon, "size_m": size_m, "grid": GRID,
        "min_m": float(h.min()), "max_m": float(h.max()), "centre_m": float(h[GRID // 2, GRID // 2])}
json.dump(meta, open(f"{out}/{name}.json", "w"), indent=1)
print(meta)
