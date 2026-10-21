#!/usr/bin/env python3
"""Near-route semantics of a sections-file scene -> <package>/semantics/semantics.json, without Godot. Stdlib only.

    python3 tools/build_semantics.py data/weissensee_sections.json export/packages/<id> [--piece-m=100]
        [--sea-right] [--sea-y=-1.3] [--inland-slope=0.35] [--bank-ratio=2.2] [--bank-run=4] [--bank-lip=1.5]
        [--cliff-lip=5] [--sand-bank] [--seed=5] [--max-dist=40] [--trees-per-chunk=14] [--chunk-length=60] [--buildings]
        [--no-water]

Needs the package's route/route.json (tools/build_route.py). Flags are the scene's exports (route.gd Path3D,
FoliageSpawner, a Buildings node with chalet / nordic, a Lake / Ocean node); defaults are the scripts' own.
MainScene_weissensee.tscn: --sea-y=-12 --inland-slope=1 --bank-ratio=0.45 --bank-run=3 --cliff-lip=0.4
--max-dist=38 --trees-per-chunk=70 --buildings.

Port of tools/export_semantics.gd (the Godot adapter, kept as the reference): same zones per section piece, from the
same rules (scripts/route.gd section_at / _build_widths / lake-bank columns / water_edge_u, FoliageSpawner forest_mix,
Boardwalk edges, Buildings chalet). Godot-only state (docs/SEMANTICS.md §6):
- water_edge_u comes from route.gd's lake-bank columns, whose wide-bank "knobs" are FastNoiseLite: noise2() ports it
  (OpenSimplex2S FBm, Godot's defaults, seed = route.gd random_seed), so every lateral offset matches the adapter;
- vertical_offset_m of inland ground zones is approximate: route.gd's inland slope rule (+ mean cliff face) without
  its noise hills, crags and real DEM (real_shore, assets/). Lake side, water, route surfaces, cliffs, bridges: exact.
"""
import bisect
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_route as br  # noqa: E402
import semantics as sm  # noqa: E402

ROW = br.ROW
EXTENT = 150.0
BARRIERS = {"boardfence": "fence", "woodrail": "fence", "lattice": "fence", "efence": "fence", "rail": "fence",
            "blackrail": "fence", "parapet_fence": "fence", "chainlink": "fence", "cable": "guardrail",
            "lograil": "guardrail", "guardrail": "guardrail", "lowwall": "wall", "parapet": "wall",
            "parapet_lamps": "wall", "wall": "wall", "cliffwall": "wall"}
f32 = br.f32


def snapped(v, step):  # Godot snappedf
    return round(math.floor(v / step + 0.5) * step, 6)


def smoothstep(a, b, x):
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


def inv_lerp(a, b, v):
    return 1.0 if a == b else (v - a) / (b - a)


# Godot FastNoiseLite as route.gd uses it (defaults: OpenSimplex2S, FBm 5 octaves, lacunarity 2, gain 0.5,
# frequency 0.01): a port of FastNoiseLite's GetNoise(x, y) (MIT, Jordan Peck), in doubles where Godot uses floats.
_G24 = [(math.sin(math.radians(7.5 + 15 * k)), math.cos(math.radians(7.5 + 15 * k))) for k in range(24)]
_G8 = [(math.sin(math.radians(22.5 + 45 * k)), math.cos(math.radians(22.5 + 45 * k))) for k in range(8)]
GRAD2 = _G24 * 5 + _G8  # FastNoiseLite Gradients2D: 24 directions x 5, then 8
PX, PY = 501125321, 1136930381
SQRT3 = math.sqrt(3.0)
G2 = (3.0 - SQRT3) / 6.0


def _i32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x80000000 else v


def _grad(seed, xp, yp, xd, yd):
    h = _i32((seed ^ xp ^ yp) * 0x27D4EB2D)
    h = ((h ^ (h >> 15)) & (127 << 1)) >> 1
    gx, gy = GRAD2[h]
    return xd * gx + yd * gy


def _os2s(seed, x, y):  # SingleOpenSimplex2S on skewed coordinates
    i, j = math.floor(x), math.floor(y)
    xi, yi = x - i, y - j
    i, j = _i32(i * PX), _i32(j * PY)
    i1, j1 = _i32(i + PX), _i32(j + PY)
    t = (xi + yi) * G2
    x0, y0 = xi - t, yi - t
    a0 = 2.0 / 3.0 - x0 * x0 - y0 * y0
    v = a0 ** 4 * _grad(seed, i, j, x0, y0)
    a1 = 2 * (1 - 2 * G2) * (1 / G2 - 2) * t + (-2 * (1 - 2 * G2) ** 2 + a0)
    v += a1 ** 4 * _grad(seed, i1, j1, x0 - (1 - 2 * G2), y0 - (1 - 2 * G2))
    xmyi = xi - yi
    pts = []
    if t > G2:
        pts.append((3 * G2 - 2, 3 * G2 - 1, _i32(i + (PX << 1)), j1) if xi + xmyi > 1 else (G2, G2 - 1, i, j1))
        pts.append((3 * G2 - 1, 3 * G2 - 2, i1, _i32(j + (PY << 1))) if yi - xmyi > 1 else (G2 - 1, G2, i1, j))
    else:
        pts.append((1 - G2, -G2, _i32(i - PX), j) if xi + xmyi < 0 else (G2 - 1, G2, i1, j))
        pts.append((-G2, 1 - G2, i, _i32(j - PY)) if yi < xmyi else (G2, G2 - 1, i, j1))
    for dx, dy, ci, cj in pts:
        x2, y2 = x0 + dx, y0 + dy
        a2 = 2.0 / 3.0 - x2 * x2 - y2 * y2
        if a2 > 0:
            v += a2 ** 4 * _grad(seed, ci, cj, x2, y2)
    return v * 18.24196194486065


def noise2(seed, x, y, freq=0.01, octaves=5):  # FastNoiseLite.get_noise_2d
    x, y = x * freq, y * freq
    k = (x + y) * 0.5 * (SQRT3 - 1.0)
    x, y = x + k, y + k
    total, amp = 0.0, 1.0 / sum(0.5 ** o for o in range(octaves))
    for o in range(octaves):
        total += _os2s(_i32(seed + o), x, y) * amp
        x, y, amp = x * 2.0, y * 2.0, amp * 0.5
    return total


class Scene:
    """route.gd's per-row cross-section of a sections-file course (no alpine trail, no Godot)."""
    section_at = br.Route.section_at

    def __init__(self, secs, route, sea_y=-1.3, inland_slope=0.35, bank_ratio=2.2, bank_run=4.0, bank_lip=1.5,
                 cliff_lip=5.0, grass_bank=True, seed=5):
        self.video_km, self.types, self.secs = float(secs["video_km"]), secs["types"], secs["sections"]
        self.landmarks = secs.get("landmarks", [])
        self.length = route["total_length_m"]
        self.n = math.ceil(self.length / ROW) + 1
        self.inland_slope = inland_slope
        smp = route["samples"]
        e0 = smp["elevation_m"][0]  # start_height: route.json elevation_m = start_height + physical rise
        ex = route.get("visual", {}).get("vertical_exaggeration", 1.0)
        rows = {k: [] for k in ["y", "hl", "hr", "pr", "slope", "gap", "quay", "cliff", "br", "cf", "ridge"]}
        for i in range(self.n):
            s = i * ROW
            k = min(bisect.bisect_left(smp["s"], s), len(smp["s"]) - 1)
            if k > 0 and smp["s"][k] > s:
                t = (s - smp["s"][k - 1]) / (smp["s"][k] - smp["s"][k - 1])
                e = smp["elevation_m"][k - 1] + (smp["elevation_m"][k] - smp["elevation_m"][k - 1]) * t
            else:
                e = smp["elevation_m"][k]
            y = f32(e0 + ex * (e - e0))  # rendered road height (route.gd _pos.y)
            sec = self.section_at(s)
            for key, v in [("y", y), ("hl", sec["half"][0]), ("pr", sec["half"][1]),
                           ("hr", f32(f32(sec["half"][1]) + float(sec.get("road", 0.0)))),
                           ("slope", sec.get("slope", 1.0)), ("gap", sec.get("water_gap", y - sea_y)),
                           ("quay", 1 if sec.get("quay", False) else 0), ("cliff", sec.get("cliff", 0.0)),
                           ("br", sec.get("bank_ratio", bank_ratio)), ("cf", sec.get("cliff_from", 6.0)),
                           ("ridge", sec.get("ridge", 0.0))]:
                rows[key].append(f32(float(v)))
        for key, r in [("gap", 37), ("hl", 3), ("hr", 3), ("pr", 3), ("slope", 10), ("cliff", 15), ("br", 15),
                       ("cf", 15), ("ridge", 20)]:  # route.gd _build_widths eases the section values
            rows[key] = br.smooth(rows[key], r)
        self.__dict__.update(rows)
        self.wy = [f32(y - g) for y, g in zip(self.y, self.gap)]
        # seaward columns per row (route.gd _build_columns): path edge, lip, bank at 0.2 / 0.5 / 0.8 / 1, skirt
        self.su, self.sy = [], []
        for i in range(self.n):
            h, wy, el = self.y[i], self.wy[i], self.hl[i]
            alt, shoulder = h - wy, f32(h - 0.03)
            w = min(max(alt * self.br[i], bank_run if grass_bank else 20.0), 260.0)
            k = smoothstep(2.0, 8.0, alt)
            lip = (bank_lip if grass_bank else 14.0) + (cliff_lip - (bank_lip if grass_bank else 14.0)) * k
            if self.quay[i] == 1:
                lip, w = el + 0.02, 0.25
            us, ys = [el, lip], [shoulder, shoulder]
            for f in [0.2, 0.5, 0.8, 1.0]:
                us.append(lip + w * f)
                yb = shoulder + (wy - 0.5 - shoulder) * f * f * (3.0 - 2.0 * f)
                if self.br[i] > bank_ratio + 0.1 and f < 1.0:  # wide banks: outcrops and hollows
                    yb += 0.12 * alt * noise2(seed, i * ROW * 0.05, f * 7.0) * 4.0 * f * (1.0 - f)
                if self.ridge[i] > 0.01 and f < 0.6:
                    yb += (shoulder + (0.6 if f < 0.3 else 1.0) * self.ridge[i] - yb) * min(max(self.ridge[i] / 1.5, 0.0), 1.0)
                ys.append(yb)
            us.append(lip + w + 3.0)
            ys.append(wy - 40.0)
            self.su.append([f32(u) for u in us])
            self.sy.append([f32(y) for y in ys])

    def row(self, s):
        f = min(max(s / ROW, 0.0), self.n - 1.001)
        return int(f), f - math.floor(f)

    def _lerp(self, a, s):
        i, t = self.row(s)
        return a[i] + (a[i + 1] - a[i]) * t

    def half_left(self, s):
        return self.hl[self.row(s)[0]]

    def half_right(self, s):
        return self.hr[self.row(s)[0]]

    def path_right(self, s):
        return self.pr[self.row(s)[0]]

    def road_y(self, s):
        return self._lerp(self.y, s)

    def gap_at(self, s):  # road above the water: pos_at(s).y - water_level(s)
        return self.road_y(s) - self._lerp(self.wy, s)

    def water_edge_u(self, s):  # where the bank meets the water (u seaward)
        i = self.row(s)[0]
        us, ys, wl = self.su[i], self.sy[i], self.wy[i] + 0.2
        for j in range(len(us) - 1):
            if ys[j + 1] <= wl:
                return us[j] + (us[j + 1] - us[j]) * min(max(inv_lerp(ys[j], ys[j + 1], wl), 0.0), 1.0)
        return us[-2]

    def ground_y(self, s, u):  # terrain height (u seaward +); inland without noise hills / DEM (see module doc)
        i = self.row(s)[0]
        if -self.hr[i] <= u <= self.hl[i]:
            return self.y[i]
        if u < 0.0:
            a, cl = -u - self.hr[i], self.cliff[i]
            ledge = smoothstep(self.cf[i], self.cf[i] + 8.0, a) if cl > 0.5 else 1.0
            face = cl * 0.7 * min(max((a - self.cf[i]) / 14.0, 0.0), 1.0) ** 0.55 if cl > 0.5 else 0.0
            return f32(self.y[i] - 0.03) + self.inland_slope * self.slope[i] * a * ledge + face
        us, ys = self.su[i], self.sy[i]
        for j in range(len(us) - 1):
            if u <= us[j + 1] or j == len(us) - 2:
                t = min(max(inv_lerp(us[j], us[j + 1], u), 0.0), 1.0)
                return ys[j] + (ys[j + 1] - ys[j]) * t


def extreme(a, b, f, use_max):  # over every route.json sample the range covers, and its ends
    ss = [a, b] + [min(max(float(k), a), b) for k in range(math.floor(a), math.ceil(b) + 1)]
    return (max if use_max else min)(f(s) for s in ss)


def build(secs, route, sections_ref, piece_m=100.0, sea_right=False, max_dist=40.0, trees_per_chunk=14,
          chunk_length=60.0, buildings=False, has_water=True, **scene_opts):
    sc = Scene(secs, route, **scene_opts)
    sgn = -1.0 if sea_right else 1.0  # route.gd u (seaward +) -> travel lateral (left +)
    zones = []

    def vert(a, b, ua, ub):
        d = [sc.ground_y(a + (b - a) * i / 4.0, ua + (ub - ua) * j / 4.0) - sc.road_y(a + (b - a) * i / 4.0)
             for i in range(5) for j in range(5)]
        return [snapped(min(d), 0.1), snapped(max(d), 0.1)]

    def zone(t, a, b, ua, ub, conf, src, attrs=None, v="ground"):
        l0, l1 = (min(max(x, -EXTENT), EXTENT) for x in sorted([ua * sgn, ub * sgn]))
        if l1 - l0 < 0.05 or b - a < 0.5:
            return
        side = "both" if l0 < -0.001 and l1 > 0.001 else ("left" if l0 >= -0.001 else "right")
        zones.append({"semantic_type": t, "side": side, "from_s": snapped(a, 0.01), "to_s": snapped(b, 0.01),
                      "lateral_offset_m": [snapped(l0, 0.01), snapped(l1, 0.01)],
                      "vertical_offset_m": vert(a, b, ua, ub) if v == "ground" else v,
                      "confidence": conf, "attributes": attrs or {}, "source": src})

    def piece(a, b, sec, src):
        hl = extreme(a, b, sc.half_left, True)
        hr = extreme(a, b, sc.half_right, True)
        pr = extreme(a, b, sc.path_right, True)
        we = extreme(a, b, sc.water_edge_u, False) if has_water else EXTENT
        gap = extreme(a, b, sc.gap_at, True)
        name = sec.get("name", "")
        tex = sec.get("surface", "asphalt_02")
        st = "road" if "asphalt" in tex else ("sidewalk" if "concrete" in tex else "trail")
        zone(st, a, b, -pr, hl, 0.9, src, {"section": name, "surface_texture": tex}, [0.0, 0.0])
        if hr - pr > 0.05:
            zone("road", a, b, -hr, -pr, 0.9, src, {"kind": "roadside lane"}, [0.0, 0.0])
        if has_water and we < EXTENT:
            wv = [snapped(-gap, 0.1), snapped(-extreme(a, b, sc.gap_at, False), 0.1)]
            zone("water", a, b, we, EXTENT, 0.9, src,
                 {"kind": "lake", "edge_m": [snapped(we, 0.1), snapped(extreme(a, b, sc.water_edge_u, True), 0.1)]}, wv)
        cover = float(sec.get("grass", 0.5))
        grassy = cover >= 0.25
        if grassy and we > hl + 0.3:
            zone("grass", a, b, hl, we, 0.6, src, {"cover": cover})
        is_open = name in ["plaza", "parking"]
        if is_open:
            zone("open_space", a, b, -(hr + 25.0), -hr, 0.7, src, {"kind": name})
        if grassy:
            zone("grass", a, b, -EXTENT, -(hr + (25.0 if is_open else 0.0)), 0.6, src, {"cover": cover})
        # trees (FoliageSpawner forest_mix: inland band to `depth`, wooded bank on the lake side, lake_band strip)
        trees = float(sec.get("trees", 1.0))
        depth = float(sec.get("depth", max_dist))
        sp = {"beech": float(sec.get("beech", 0.5)), "spruce": float(sec.get("spruce", 0.4)),
              "larch": float(sec.get("larch", 0.1))}
        stems = snapped(0.5 * trees_per_chunk * trees / (chunk_length * max(depth - hr, 1.0)) * 10000.0, 1.0)
        fa = {"density": "dense" if trees >= 1.5 else ("medium" if trees >= 0.6 else "sparse"), "species": sp,
              "autumn_share": float(sec.get("yellow", 0.5)), "stems_per_ha": stems,
              "floor": "leaf_litter" if float(sec.get("litter", 0.0)) > 0.3 else "grass"}
        tree_type = "forest" if trees >= 0.3 else "vegetation_zone"
        if trees < 0.3:
            fa = {"kind": "scattered_trees", "species": sp, "stems_per_ha": stems}
        if trees > 0.0:
            zone(tree_type, a, b, -depth, -(hr + 0.6), 0.7, src, fa)
            if we - 0.8 - hl - 0.6 > 1.0:
                zone(tree_type, a, b, hl + 0.6, min(depth, we - 0.8), 0.7, src, fa)
        if int(sec.get("lake_band", 0)) > 0 and we - 1.0 > hl + 10.0:
            zone("forest", a, b, hl + 10.0, we - 1.0, 0.6, src, {"density": "medium", "kind": "lake_band", "species": sp})
        if int(sec.get("hazel", 0)) > 0:
            ha = {"kind": "shrubs", "per_100m": snapped(float(sec["hazel"]) / chunk_length * 100.0, 0.1)}
            zone("vegetation_zone", a, b, -(hr + 9.0), -(hr + 2.0), 0.6, src, ha)
            zone("vegetation_zone", a, b, hl + 2.0, min(hl + 9.0, we - 0.8), 0.6, src, ha)
        if has_water and int(sec.get("reeds", 0)) > 0 and gap < 4.0:
            zone("vegetation_zone", a, b, max(we - 2.0, hl + 0.1), we + 4.0, 0.6, src,
                 {"kind": "reeds", "per_100m": snapped(float(sec["reeds"]) / chunk_length * 100.0, 0.1)})
        # landform
        rise = float(sec.get("slope", 1.0)) * sc.inland_slope
        if rise >= 0.15:
            zone("slope", a, b, -EXTENT, -hr, 0.8, src, {"direction": "up", "rise_per_m": snapped(rise, 0.01)})
        if has_water and gap >= 1.5 and we - hl > 0.5:
            zone("slope", a, b, hl, we, 0.8, src, {"direction": "down", "drop_m": snapped(gap, 0.1)})
        if float(sec.get("cliff", 0.0)) > 0.5:
            cf = float(sec.get("cliff_from", 6.0))
            zone("cliff", a, b, -(hr + cf + 14.0), -(hr + cf), 0.8, src, {"height_m": float(sec["cliff"])},
                 [0.0, float(sec["cliff"])])
        # edge barriers (Boardwalk: posts 5 cm outside the path edge)
        for style, half, d in [(str(sec.get("lake", "none")), hl, 1.0), (str(sec.get("inland", "none")), hr, -1.0)]:
            if style in BARRIERS:
                t, u0 = BARRIERS[style], half + 0.05
                zone(t, a, b, d * u0, d * (u0 + (0.6 if t == "wall" else 0.3)), 0.8, src, {"kind": style})
        # buildings (Buildings.gd chalet: chalets 10-30 m inland, barns 15-60 m, footprints ~13 m deep)
        if buildings:
            if sec.get("houses", False):
                zone("building_zone", a, b, -(hr + 37.0), -(hr + 3.0), 0.7, src, {"kind": "chalets"})
            elif sec.get("barns", False):
                zone("building_zone", a, b, -(hr + 63.0), -(hr + 12.0), 0.6, src, {"kind": "barns"})

    secs_list = sc.secs
    for k, e in enumerate(secs_list):
        s0 = float(e[0]) / sc.video_km * sc.length
        s1 = float(secs_list[k + 1][0]) / sc.video_km * sc.length if k + 1 < len(secs_list) else sc.length
        sec = sc.section_at(0.5 * (s0 + s1))
        src = {"kind": "scene_generator", "ref": "%s S%02d %s" % (sections_ref, k + 1, e[1]), "estimated": True}
        if len(e) > 3 and isinstance(e[3], str):
            src["note"] = e[3]
        n = max(math.ceil((s1 - s0) / piece_m), 1)
        for p in range(n):
            piece(s0 + (s1 - s0) * p / n, s0 + (s1 - s0) * (p + 1) / n, sec, src)
    for km, kind in sc.landmarks:  # footbridges carry the route: bridge zones over the path
        if kind == "footbridge":
            s = float(km) / sc.video_km * sc.length
            a, b = max(s - 5.0, 0.0), min(s + 5.0, sc.length)
            w = max(extreme(a, b, sc.half_left, True), extreme(a, b, sc.half_right, True)) + 0.15
            zone("bridge", a, b, -w, w, 0.8, {"kind": "scene_generator", "estimated": True,
                 "ref": "%s landmarks footbridge (Boardwalk.gd, 10 m deck)" % sections_ref}, {"kind": "footbridge"}, [-1.0, 0.0])
    zones.sort(key=lambda z: (z["from_s"], z["lateral_offset_m"][0]))
    return {"version": sm.VERSION, "route_id": route["route_id"], "extent_m": EXTENT,
            "source": {"producer": "tools/build_semantics.py (tools/export_semantics.gd rules)", "sections": sections_ref,
                       "course": route.get("source", {}).get("course"),
                       "note": "zones follow the scene generators' rules per section piece (<= %d m); vertical offsets "
                               "are terrain relative to the road from route.gd's cross-section without noise / DEM"
                               % int(piece_m)},
            "zones": [{"id": "z%04d" % (i + 1)} | z for i, z in enumerate(zones)]}


def main(argv):
    opts = dict((a[2:].split("=", 1) + ["1"])[:2] for a in argv if a.startswith("--"))
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 2:
        print(__doc__)
        return 2
    sec_path, pkg = args
    with open(sec_path) as f:
        secs = json.load(f)
    with open(os.path.join(pkg, "route", "route.json")) as f:
        route = json.load(f)
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    ref = os.path.relpath(os.path.abspath(sec_path), os.path.abspath(root))
    num = lambda k, d: float(opts.get(k, d))  # noqa: E731
    sem = build(secs, route, ref if not ref.startswith("..") else sec_path, piece_m=num("piece-m", 100),
                sea_right="sea-right" in opts, max_dist=num("max-dist", 40), trees_per_chunk=num("trees-per-chunk", 14),
                chunk_length=num("chunk-length", 60), buildings="buildings" in opts, has_water="no-water" not in opts,
                sea_y=num("sea-y", -1.3), inland_slope=num("inland-slope", 0.35), bank_ratio=num("bank-ratio", 2.2),
                bank_run=num("bank-run", 4), bank_lip=num("bank-lip", 1.5), cliff_lip=num("cliff-lip", 5),
                seed=int(num("seed", 5)),
                grass_bank="sand-bank" not in opts)
    out = os.path.join(pkg, "semantics", "semantics.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(sem, f, indent=1)
    errs = sm.validate(sem, route)
    print(f"{out}: {len(sem['zones'])} zones -> " + ("VALID" if not errs else "INVALID"))
    for e in errs[:20]:
        print("  " + e)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
