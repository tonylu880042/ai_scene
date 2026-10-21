"""Synthetic (no-GPS) route -> canonical route.json, without Godot.

    python3 tools/build_route.py data/weissensee_sections.json --course=rolling_hills \
        --out=export/packages/<id>/route/route.json [--route-id=<id>] [--bend=0.6] [--start-height=0]
        [--sea-right] [--road-left=2.25] [--road-right=10] [--pace=6] [--grade-scale=1.5] [--step=1]
        [--checkpoint-every-m=1000] [--start-gap=10] [--finish-gap=12]

Reproduces scripts/route.gd (_turn_rates, _build_centreline, _build_widths, section_at, info_at) the way
tools/export_route.gd samples it, then tools/route_model.py finalize(). The sections file may be "-" (no sections:
sine bends, road_left / road_right widths, asphalt). Pass the scene's Path3D exports (bend, start_height, ...),
after its course template (courses_*.json "Path3D") is applied. Godot keeps Vector3 / Packed*32 arrays in float32;
f32() mirrors that so x / z agree with the Godot export to well under a millimetre.
"""
import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import route_model as rm  # noqa: E402

ROW = 2.0
PROGRAMS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "programs.json")
# section texture -> surface_type (tools/export_route.gd _surface)
SURFACES = [("asphalt", "asphalt"), ("concrete", "concrete"), ("cobble", "cobblestone"), ("gravel", "gravel"),
            ("plank", "boardwalk"), ("wood", "boardwalk"), ("snow", "snow"), ("ice", "ice"), ("mud", "dirt"),
            ("trail", "dirt"), ("dirt", "dirt"), ("sand", "sand"), ("grass", "grass")]


def f32(v):
    return struct.unpack("f", struct.pack("f", v))[0]


def surface_type(tex):
    return next((t for k, t in SURFACES if k in tex), "unknown")


def smooth(a, r):  # route.gd _smooth: box filter over 2r+1 rows, clamped at the ends
    n = len(a)
    return [f32(sum(a[min(max(i + k, 0), n - 1)] for k in range(-r, r + 1)) / (2 * r + 1)) for i in range(n)]


class Route:
    def __init__(self, segs, secs=None, bend=1.0, start_height=-0.2, sea_right=False, road_left=2.25,
                 road_right=10.0, pace=6.0):
        self.segs, self.bend, self.start_height, self.sea_right = segs, bend, start_height, sea_right
        self.video_km = float(secs["video_km"]) if secs else 1.0
        self.types = secs["types"] if secs else {}
        self.secs = secs["sections"] if secs else []
        self.speed = 1000.0 / (pace * 60.0)
        self.length = sum(s[0] for s in segs) * 60.0 * self.speed
        self.n = math.ceil(self.length / ROW) + 1
        self._centreline()
        self._widths(road_left, road_right)

    def info_at(self, t):  # incline (%) at t seconds into the course
        m, acc = t / 60.0, 0.0
        for s in self.segs:
            acc += s[0]
            if m < acc:
                return float(s[1])
        return float(self.segs[-1][1])

    def section_at(self, s):
        if not self.secs:
            return {}
        km = min(max(s / self.length, 0.0), 1.0) * self.video_km
        e0 = self.secs[0]
        for e in self.secs:
            if km >= float(e[0]):
                e0 = e
        t = dict(self.types[e0[1]])
        if len(e0) > 2 and isinstance(e0[2], dict):
            t.update(e0[2])
        t["name"] = e0[1]
        return t

    def section_spans(self):  # [(from_s, to_s, type)]
        out = []
        for k, e in enumerate(self.secs):
            s1 = float(self.secs[k + 1][0]) / self.video_km * self.length if k + 1 < len(self.secs) else self.length
            out.append((float(e[0]) / self.video_km * self.length, s1, e[1]))
        return out

    def _turn_rates(self):  # heading change per row (rad, + left) from sections' "turn"; [] -> sine bends
        rate = [0.0] * self.n
        any_turn = False
        for s0, s1, _ in self.section_spans():
            turn = self.section_at(0.5 * (s0 + s1)).get("turn")
            if turn is None or s1 <= s0:
                continue
            any_turn = True
            bends = turn if isinstance(turn, list) else [turn]
            span = (s1 - s0) / len(bends)
            for b, deg in enumerate(bends):
                a = s0 + b * span
                for i in range(math.ceil(a / ROW), min(math.ceil((a + span) / ROW), self.n)):
                    rate[i] = f32(rate[i] + math.radians(float(deg)) * math.pi / 2.0
                                  * math.sin(math.pi * (i * ROW - a) / span) * ROW / span)
        return rate if any_turn else []

    def _centreline(self):
        turns = self._turn_rates()
        px, pz = 0.0, 0.0  # f32, like Godot's Vector3
        gp = e = heading = 0.0
        self.x, self.z, self.elev = [], [], []
        ease = min(1.0, ROW / 20.0)
        for i in range(self.n):
            s = i * ROW
            h = self.bend * (0.7 * math.sin(s / 500.0) + 0.35 * math.sin(s / 220.0 + 1.0))
            if turns:
                h = heading
                heading -= turns[i]
            self.x.append(px)
            self.z.append(pz)
            self.elev.append(f32(e))
            gp += (self.info_at(s / self.speed) / 100.0 - gp) * ease  # ~20 m to ease between grades
            e += gp * ROW
            fx, fz = f32(math.cos(h)), f32(math.sin(h))
            px = f32(px + f32(fx * ROW))
            pz = f32(pz + f32(fz * ROW))

    def _widths(self, road_left, road_right):
        hl, hr, self.tex = [], [], []
        for i in range(self.n):
            sec = self.section_at(i * ROW)
            if sec:
                hl.append(f32(sec["half"][0]))
                hr.append(f32(f32(sec["half"][1]) + float(sec.get("road", 0.0))))
            else:
                hl.append(f32(road_left))
                hr.append(f32(road_right))
        if self.secs:  # ease the cross-section over ~14 m at section changes
            hl, hr = smooth(hl, 3), smooth(hr, 3)
        self.hl, self.hr = hl, hr

    def _row(self, s):
        f = min(max(s / ROW, 0.0), self.n - 1.001)
        return int(f), f - math.floor(f)

    def at(self, s):  # x, z, elevation above the start, travel-left / travel-right half widths
        i, t = self._row(s)
        lerp = lambda a: f32(a[i] + (a[i + 1] - a[i]) * t)  # noqa: E731
        wl, wr = (self.hr[i], self.hl[i]) if self.sea_right else (self.hl[i], self.hr[i])
        return lerp(self.x), lerp(self.z), lerp(self.elev), wl, wr


def build(segs, secs=None, route_id="route", step=1.0, checkpoint_every=1000.0, start_gap=10.0, finish_gap=12.0,
          grade_scale=1.5, source=None, **route_opts):
    """Primary facts of the route (as tools/export_route.gd writes them), finalized by route_model."""
    r = Route(segs, secs, **route_opts)
    ss = []
    k = 0
    while k * step < r.length - 1e-6:
        ss.append(k * step)
        k += 1
    ss.append(r.length)
    smp = {k: [] for k in ["s", "x", "z", "elevation_m", "width_left_m", "width_right_m", "surface_type"]}
    for s in ss:
        x, z, e, wl, wr = r.at(s)
        for key, v in zip(smp, [s, x, z, r.start_height + e, wl, wr,
                                surface_type(r.section_at(s).get("surface", "asphalt_02") if secs else "asphalt_02")]):
            smp[key].append(v)
    start_s, finish_s = start_gap, r.length - finish_gap
    cps, c = [], checkpoint_every
    while checkpoint_every > 0 and c < finish_s - 1.0:
        if c > start_s + 1.0:
            cps.append({"id": "cp%02d" % (len(cps) + 1), "s": c, "name": "%.1f km" % (c / 1000.0)})
        c += checkpoint_every
    raw = {
        "route_id": route_id, "sample_interval_m": step, "closed": False,
        "start": {"id": "start", "s": start_s, "name": "START gate"},
        "finish": {"id": "finish", "s": finish_s, "name": "FINISH gate"},
        "checkpoints": cps,
        "visual": {"vertical_exaggeration": grade_scale, "relief_amplitude_m": 0.0,
                   "note": "the Godot scene draws the road at start_height + vertical_exaggeration * "
                           "(elevation_m - start_height); not physical"},
        "source": {"producer": "tools/build_route.py (scripts/route.gd)", "pace_min_per_km": route_opts.get("pace", 6.0),
                   "grade": "treadmill program incline, eased over ~20 m (data/programs.json)",
                   "widths": "section half widths (+ roadside lane), smoothed as route.gd"} | (source or {}),
        "samples": smp,
    }
    if secs:
        raw["sections"] = [{"id": "S%02d" % (i + 1), "from_s": a, "to_s": b, "type": t}
                           for i, (a, b, t) in enumerate(r.section_spans())]
    return rm.finalize(raw)


def main(argv):
    opts = dict((a[2:].split("=", 1) + ["1"])[:2] for a in argv if a.startswith("--"))
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 1 or "course" not in opts:
        print(__doc__)
        return 2
    secs = None
    if args[0] != "-":
        with open(args[0]) as f:
            secs = json.load(f)
    with open(opts.get("programs", PROGRAMS)) as f:
        segs = json.load(f)[opts["course"]]
    stem = "route" if secs is None else os.path.basename(args[0]).rsplit(".", 1)[0].removesuffix("_sections")
    rid = opts.get("route-id", f"{stem}_{opts['course']}")
    num = lambda k, d: float(opts.get(k, d))  # noqa: E731
    r = build(segs, secs, route_id=rid, step=num("step", 1), checkpoint_every=num("checkpoint-every-m", 1000),
              start_gap=num("start-gap", 10), finish_gap=num("finish-gap", 12), grade_scale=num("grade-scale", 1.5),
              source={"sections": args[0], "course": opts["course"]},
              bend=num("bend", 1.0), start_height=num("start-height", -0.2), sea_right="sea-right" in opts,
              road_left=num("road-left", 2.25), road_right=num("road-right", 10.0), pace=num("pace", 6.0))
    out = opts.get("out", f"export/packages/{rid}/route/route.json")
    rm._save(r, out)
    return rm._report(r, out)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
