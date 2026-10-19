#!/usr/bin/env python3
"""Top-down route map for the L0 check: centre line coloured per section, section IDs (S01.. = order in
<name>_sections.json) with their "turn", landmarks, start / end. Builds no terrain (tools/dump_route.gd).

  python3 tools/plot_route.py res://scenes/MainScene_<name>.tscn <out.png> [course]
"""
import json, math, os, subprocess, sys, tempfile

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from section_sheet import font  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COLOURS = [(33, 102, 172), (214, 96, 77), (27, 120, 55), (118, 42, 131)]
W, PAD, LEGEND_COLS = 1800, 120, 4


def heading_change(pts, a, b):  # degrees between the travel directions at rows a and b, + left of travel (Godot: -Z ahead = left of +X)
    a, b = max(min(a, len(pts) - 2), 0), max(min(b, len(pts) - 1), 1)
    f0 = (pts[a + 1][0] - pts[a][0], pts[a + 1][1] - pts[a][1])
    f1 = (pts[b][0] - pts[b - 1][0], pts[b][1] - pts[b - 1][1])
    left0 = (f0[1], -f0[0])
    return math.degrees(math.atan2(f1[0] * left0[0] + f1[1] * left0[1], f1[0] * f0[0] + f1[1] * f0[1]))


def main():
    scene, out = sys.argv[1], sys.argv[2]
    course = sys.argv[3] if len(sys.argv) > 3 else ""
    with tempfile.TemporaryDirectory() as tmp:
        dump = os.path.join(tmp, "route.json")
        subprocess.run(["godot", "--headless", "--path", ROOT, "--script", "tools/dump_route.gd", "--",
                        scene, course, dump], check=True, capture_output=True)
        d = json.load(open(dump))
    pts = d["points"]
    xs, zs = [p[0] for p in pts], [p[1] for p in pts]
    k = (W - 2 * PAD) / max(max(xs) - min(xs), 1.0)
    map_h = int(max((max(zs) - min(zs)) * k, 400)) + 2 * PAD
    k = min(k, (map_h - 2 * PAD) / max(max(zs) - min(zs), 1.0))
    ox = PAD + ((W - 2 * PAD) - (max(xs) - min(xs)) * k) / 2
    oy = PAD + ((map_h - 2 * PAD) - (max(zs) - min(zs)) * k) / 2
    # Godot top view: +X right, +Z down on the image (north = -Z up)
    xy = lambda p: (ox + (p[0] - min(xs)) * k, oy + (p[1] - min(zs)) * k)
    row = lambda s: min(int(s / d["step_m"]), len(pts) - 1)
    at = lambda s: xy(pts[row(s)])

    secs = d["sections"] or [{"id": "S01", "s0": 0.0, "s1": d["length"], "name": "", "turn": None}]
    f, small = font(26), font(20)
    legend_rows = math.ceil(len(secs) / LEGEND_COLS)
    img = Image.new("RGB", (W, map_h + 70 + legend_rows * 26), (250, 250, 247))
    g = ImageDraw.Draw(img)
    for i, s in enumerate(secs):
        g.line([xy(p) for p in pts[row(s["s0"]):row(s["s1"]) + 1]], fill=COLOURS[i % len(COLOURS)], width=7)
    for i, s in enumerate(secs):
        x, y = at(s["s0"])
        g.ellipse((x - 5, y - 5, x + 5, y + 5), fill=(0, 0, 0))
        g.text((x + 6, y + (8 if i % 2 else -30)), s["id"], fill=COLOURS[i % len(COLOURS)], font=small)
    for s, kind in d["landmarks"]:
        x, y = at(s)
        g.polygon([(x, y - 9), (x + 9, y), (x, y + 9), (x - 9, y)], fill=(230, 160, 0))
    for s, c, label in ((0.0, (0, 160, 0), "START"), (d["length"], (200, 0, 0), "END")):
        x, y = at(s)
        g.ellipse((x - 14, y - 14, x + 14, y + 14), outline=c, width=5)
        g.text((x + 18, y - 34), label, fill=c, font=f)
    turned = any(s["turn"] is not None for s in secs)
    g.text((PAD, 30), f"{d['scene']}  course {d['course']}  {d['length'] / 1000:.2f} km  {len(secs)} sections  "
           f"bends: {'sections turn' if turned else 'sine (no turn keys)'}  ◆ landmark", fill=(0, 0, 0), font=f)
    bar = next(m for m in (10, 20, 50, 100, 200, 500, 1000, 2000, 5000) if m >= 200 / k)  # scale bar of round metres
    g.line([(PAD, map_h - 40), (PAD + bar * k, map_h - 40)], fill=(0, 0, 0), width=4)
    g.text((PAD, map_h - 34), f"{bar} m", fill=(0, 0, 0), font=small)
    # legend: measured heading change per section (+ left / - right), so the bend order reads like the video's
    g.text((PAD, map_h + 10), "measured heading change per section: + left / - right", fill=(0, 0, 0), font=small)
    cw = (W - 2 * PAD) // LEGEND_COLS
    for i, s in enumerate(secs):
        x, y = PAD + (i // legend_rows) * cw, map_h + 44 + (i % legend_rows) * 26
        dh = heading_change(pts, row(s["s0"]), row(s["s1"]))
        arrow = "←" if dh > 10 else "→" if dh < -10 else "↑"
        g.text((x, y), f"{s['id']} {arrow}{dh:+4.0f}°  {s['name']}"[:34], fill=COLOURS[i % len(COLOURS)], font=small)
    img.save(out)
    print(out)


if __name__ == "__main__":
    main()
