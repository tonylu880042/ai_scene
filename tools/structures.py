#!/usr/bin/env python3
"""Near-route buildings and landmarks stage (P4): route + semantics + vegetation + hints -> structures. Stdlib only.

  python3 tools/structures.py build <package_dir> [--sections=data/weissensee_sections.json] [--hints=hints.json] [--seed=5]
  python3 tools/structures.py validate <package_dir>

Sources of objects (docs/STRUCTURES.md): route.json start / finish / checkpoints (race gates, checkpoint signs);
semantics.json building zones (generic houses / barns), barrier zones (fences, guardrails, retaining walls), bridge and
tunnel zones (bridges, tunnel portals); landmark hints (structures/hints.json from video / AI analysis, or derived from a
sections file) for named, high-importance landmarks and point furniture. High-importance objects keep their anchor;
medium ones may slide <= 15 m along the route to find room; low ones are generic fill and are skipped if they don't fit.
"""
import json
import math
import os
import random
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import road_terrain as rt  # noqa: E402
import route_model as rm  # noqa: E402
import semantics as sm  # noqa: E402
import vegetation as vg  # noqa: E402

VERSION = "0.1"
TYPES = ["house", "commercial_building", "station", "hut", "church", "bridge", "tunnel_portal", "retaining_wall",
         "guardrail", "fence", "sign", "lamp", "bench", "monument", "race_landmark"]
IMPORTANCE = ["high", "medium", "low"]
BUILDING = {"house", "commercial_building", "station", "hut", "church", "monument"}
CLEARANCE_M = {t: 2.0 for t in BUILDING} | {"sign": 0.3, "lamp": 0.3, "bench": 0.3}  # beyond the playable band
MAX_DROP_M = {t: 4.0 for t in BUILDING} | {"sign": 1.0, "lamp": 1.0, "bench": 1.0, "race_landmark": 1.0}
SLIDE_M = {"high": 0.0, "medium": 15.0, "low": 0.0}
ANCHOR_TOL_M = 1.0
VEG_BLOCKING = {"deciduous_tree", "conifer", "tropical_tree", "shrub", "rocks"}

# Engine-neutral prototypes. dimensions_m: width along local X, height along Y, depth along Z; local +Z is the front.
# Linear prototypes give a cross-section and repeat along a polyline. reference_assets: today's Godot generators.
PROTOTYPES = {
    "house_chalet": {"semantic_type": "house", "placement": "point", "dimensions_m": [12.0, 9.0, 9.0], "reference_assets": ["Buildings._chalet"]},
    "barn_timber": {"semantic_type": "hut", "placement": "point", "dimensions_m": [5.5, 5.5, 4.5], "reference_assets": ["Buildings._barn"]},
    "lodge": {"semantic_type": "commercial_building", "placement": "point", "dimensions_m": [14.0, 8.0, 10.0], "reference_assets": ["Buildings._chalet (hotel)"]},
    "bench_wood": {"semantic_type": "bench", "placement": "point", "dimensions_m": [1.8, 0.9, 0.6], "reference_assets": ["painted_wooden_bench"]},
    "picnic_table": {"semantic_type": "bench", "placement": "point", "dimensions_m": [2.0, 0.8, 1.8], "reference_assets": ["Boardwalk picnic table"]},
    "lamp_lantern": {"semantic_type": "lamp", "placement": "point", "dimensions_m": [0.3, 3.5, 0.3], "reference_assets": ["Boardwalk lantern post"]},
    "sign_checkpoint": {"semantic_type": "sign", "placement": "point", "dimensions_m": [0.6, 2.2, 0.1], "reference_assets": []},
    "gate_start": {"semantic_type": "race_landmark", "placement": "spanning", "dimensions_m": [0.0, 5.0, 1.0], "reference_assets": ["Gates._make_gate START"]},
    "gate_finish": {"semantic_type": "race_landmark", "placement": "spanning", "dimensions_m": [0.0, 5.0, 1.0], "reference_assets": ["Gates._make_gate FINISH"]},
    "footbridge_wood": {"semantic_type": "bridge", "placement": "spanning", "dimensions_m": [0.0, 1.1, 10.0], "reference_assets": ["Boardwalk._footbridge"]},
    "tunnel_portal_stone": {"semantic_type": "tunnel_portal", "placement": "spanning", "dimensions_m": [0.0, 6.0, 2.0], "reference_assets": ["Boardwalk tunnel portal (garda)"]},
    "retaining_wall_stone": {"semantic_type": "retaining_wall", "placement": "linear", "profile_m": {"height": 1.5, "thickness": 0.6}, "reference_assets": ["Boardwalk wall / lowwall"]},
    "guardrail_cable": {"semantic_type": "guardrail", "placement": "linear", "profile_m": {"height": 1.0, "thickness": 0.1, "post_spacing": 2.5}, "reference_assets": ["Boardwalk cable"]},
    "guardrail_lograil": {"semantic_type": "guardrail", "placement": "linear", "profile_m": {"height": 0.9, "thickness": 0.2, "post_spacing": 2.0}, "reference_assets": ["Boardwalk lograil"]},
    "guardrail_steel": {"semantic_type": "guardrail", "placement": "linear", "profile_m": {"height": 0.75, "thickness": 0.3, "post_spacing": 2.0}, "reference_assets": ["Boardwalk guardrail"]},
    "fence_rail": {"semantic_type": "fence", "placement": "linear", "profile_m": {"height": 1.1, "thickness": 0.1, "post_spacing": 2.0}, "reference_assets": ["Boardwalk woodrail / rail"]},
    "fence_boards": {"semantic_type": "fence", "placement": "linear", "profile_m": {"height": 1.35, "thickness": 0.06, "post_spacing": 2.0}, "reference_assets": ["Boardwalk boardfence"]},
    "fence_pasture": {"semantic_type": "fence", "placement": "linear", "profile_m": {"height": 1.0, "thickness": 0.05, "post_spacing": 4.0}, "reference_assets": ["Boardwalk efence"]},
    "fence_lattice": {"semantic_type": "fence", "placement": "linear", "profile_m": {"height": 1.0, "thickness": 0.05, "post_spacing": 2.0}, "reference_assets": ["Boardwalk lattice"]},
}
LINEAR_PROTO = {"cable": "guardrail_cable", "lograil": "guardrail_lograil", "guardrail": "guardrail_steel",
                "boardfence": "fence_boards", "efence": "fence_pasture", "lattice": "fence_lattice"}


# ------------------------------------------------------------------ geometry helpers
def _vec(heading):
    b = math.radians(heading)
    return (math.sin(b), -math.cos(b)), (-math.cos(b), -math.sin(b))  # forward, left (x, z)


def _quat_facing(fx, fz):
    yaw = math.atan2(fx, fz)  # local +Z -> (fx, fz)
    return [0.0, round(math.sin(yaw / 2), 6), 0.0, round(math.cos(yaw / 2), 6)]


def _box_overlap(a, b, tol=0.01):
    return (min(a[1], b[1]) - max(a[0], b[0]) > tol and min(a[3], b[3]) - max(a[2], b[2]) > tol)


def _zbox(z):
    return (z["from_s"], z["to_s"], z["lateral_offset_m"][0], z["lateral_offset_m"][1])


class Site:
    """Placement checks in route coordinates: route widths, semantics, vegetation instances, terrain."""

    def __init__(self, pkg, route, man, sem):
        self.route, self.sem = route, sem
        self.space = vg.Space(pkg, route, man, sem)
        self.veg = []  # blocking vegetation: (s, u, radius)
        protos = {}
        p = os.path.join(pkg, "vegetation", "prototypes.json")
        if os.path.isfile(p):
            with open(p) as f:
                protos = {q["id"]: q for q in json.load(f)["prototypes"]}
        for t in man["tiles"]:
            vp = os.path.join(pkg, t["files"].get("vegetation", "-"))
            if not os.path.isfile(vp):
                continue
            with open(vp) as f:
                for g in json.load(f)["groups"]:
                    if g["category"] in VEG_BLOCKING:
                        r = protos.get(g["proto"], {}).get("footprint_radius_m", 0.5)
                        for k, (s, u) in enumerate(zip(g["s"], g["lateral_offset_m"])):
                            self.veg.append((s, u, r * g["data"][10 * k + 7]))
        self.veg.sort()
        self.veg_s = [v[0] for v in self.veg]

    def band(self, s0, s1):
        """Max playable half-widths (left, right) over [s0, s1]."""
        smp = self.route["samples"]
        i0 = max(rm.bisect.bisect_left(smp["s"], s0) - 1, 0)
        i1 = min(rm.bisect.bisect_right(smp["s"], s1) + 1, len(smp["s"]))
        return max(smp["width_left_m"][i0:i1]), max(smp["width_right_m"][i0:i1])

    def zones(self, box, types):
        return [z for z in self.sem["zones"] if z["semantic_type"] in types and _box_overlap(box, _zbox(z))]

    def veg_in(self, box, pad=0.0):
        i = rm.bisect.bisect_left(self.veg_s, box[0] - 5.0)
        out = []
        while i < len(self.veg) and self.veg[i][0] <= box[1] + 5.0:
            s, u, r = self.veg[i]
            if box[0] - r - pad < s < box[1] + r + pad and box[2] - r - pad < u < box[3] + r + pad:
                out.append(self.veg[i])
            i += 1
        return out

    def ground(self, s, u):
        x, z = self.space.world_xz(s, u)
        return self.space.ground(s, u, x, z)

    def problems(self, obj):
        """Why a placed point / spanning object is not allowed here (list of strings)."""
        out = []
        t = obj["semantic_type"]
        for box in obj["footprints_route"]:
            wl, wr = self.band(box[0], box[1])
            if obj.get("on_road"):
                if box[2] < wl + 0.3 and box[3] > -(wr + 0.3) and t == "race_landmark":
                    out.append("gate leg on the road")
            else:
                clear = CLEARANCE_M.get(t, 0.3)
                if box[2] < wl + clear and box[3] > -(wr + clear):
                    out.append("inside the road boundary + clearance")
                if self.zones(box, {"road", "trail", "sidewalk"}):
                    out.append("on a road / trail / sidewalk zone")
            if self.zones(box, {"water"}) and t != "bridge":
                out.append("in water")
            if t not in ("bridge", "tunnel_portal") and self.zones(box, {"tunnel", "bridge"}):
                out.append("in a tunnel / on a bridge")
            if t in BUILDING and self.zones(box, {"forest"}):
                out.append("inside a forest zone")
            if t != "bridge" and self.veg_in(box, 0.2):
                out.append(f"collides with {len(self.veg_in(box, 0.2))} trees / shrubs / rocks")
            for lin in self.linear:
                if lin is not obj and any(_box_overlap(box, lb) for lb in lin["footprints_route"]):
                    out.append(f"overlaps {lin['object_id']} ({lin['semantic_type']})")
                    break
            hs = [self.ground(s, u) for s in (box[0], box[1]) for u in (box[2], box[3])]
            if t != "bridge":
                if any(h is None for h in hs):
                    out.append("not over terrain")
                elif max(hs) - min(hs) > MAX_DROP_M.get(t, 4.0):
                    out.append(f"terrain drops {max(hs) - min(hs):.1f} m under it")
        return out


# ------------------------------------------------------------------ object construction
def _point(site, oid, t, proto, importance, s, u, dims, conf, src, name=None, anchor=None, attrs=None):
    """Point object facing the road, footprint [s -+ w/2] x [u -+ d/2] (width along the road, depth across)."""
    w, h, d = dims
    obj = {"object_id": oid, "semantic_type": t, "importance": importance, "placement": "point",
           "s": round(s, 3), "lateral_offset_m": round(u, 3), "side": "left" if u > 0 else "right",
           "dimensions_m": {"width": w, "height": h, "depth": d}, "prototype": proto, "confidence": conf,
           "source": src, "on_road": False, "footprints_route": [(s - w / 2, s + w / 2, u - d / 2, u + d / 2)]}
    if name:
        obj["name"] = name
    if anchor:
        obj["anchor"] = anchor
    if attrs:
        obj["attributes"] = attrs
    return obj


def _finish(site, obj):
    """World transform from the route: position over the footprint centre, base on the lowest ground corner."""
    p = rm.sample(site.route, obj["s"])
    f, left = _vec(p["heading_deg"])
    u = obj["lateral_offset_m"]
    x, z = p["x"] + left[0] * u, p["z"] + left[1] * u
    if obj.get("on_road"):
        y = p["y"]
        facing = (-f[0], -f[1])  # gates / portals face the oncoming runner
        legs = [site.ground(b[0] * 0.5 + b[1] * 0.5, b[2] * 0.5 + b[3] * 0.5) for b in obj["footprints_route"]]
        obj["foundation_drop_m"] = round(max([abs(y - g) for g in legs if g is not None] or [0.0]), 3)
    else:
        b = obj["footprints_route"][0]
        hs = [site.ground(s, uu) for s in (b[0], b[1]) for uu in (b[2], b[3])]
        hs = [h for h in hs if h is not None] or [p["y"]]
        y = min(hs)
        obj["foundation_drop_m"] = round(max(hs) - min(hs), 3)
        sg = -1.0 if u > 0 else 1.0
        facing = (left[0] * sg, left[1] * sg)  # front towards the road
    obj["transform"] = {"position": [round(x, 3), round(y, 3), round(z, 3)], "rotation": _quat_facing(*facing),
                        "scale": [1.0, 1.0, 1.0]}
    obj["footprints_route"] = [[round(v, 3) for v in b] for b in obj["footprints_route"]]
    return obj


def _linear(site, oid, zones, proto):
    """Barrier along its semantic zones (merged), polyline every <= 5 m at the zone's mid offset, on the terrain."""
    t = PROTOTYPES[proto]["semantic_type"]
    s0, s1 = zones[0]["from_s"], zones[-1]["to_s"]
    n = max(int(math.ceil((s1 - s0) / 5.0)), 1)
    ss, us, pts = [], [], []
    for k in range(n + 1):
        s = min(s0 + k * (s1 - s0) / n, s1)
        z = next(z for z in zones if z["from_s"] - 1e-6 <= s <= z["to_s"] + 1e-6)
        u = 0.5 * (z["lateral_offset_m"][0] + z["lateral_offset_m"][1])
        x, zz = site.space.world_xz(s, u)
        y = site.ground(s, u)
        if y is None:
            y = rm.sample(site.route, s)["y"]
        ss.append(round(s, 3))
        us.append(round(u, 3))
        pts.append([round(x, 3), round(y, 3), round(zz, 3)])
    p = rm.sample(site.route, s0)
    f, _ = _vec(p["heading_deg"])
    imp = "medium"
    return {"object_id": oid, "semantic_type": t, "importance": imp, "placement": "linear",
            "s": round(s0, 3), "lateral_offset_m": us[0], "side": zones[0]["side"], "from_s": round(s0, 3), "to_s": round(s1, 3),
            "dimensions_m": {"length": round(s1 - s0, 2), **PROTOTYPES[proto]["profile_m"]}, "prototype": proto,
            "confidence": min(z["confidence"] for z in zones), "on_road": False,
            "source": dict(zones[0]["source"], semantic_zones=[z["id"] for z in zones]),
            "attributes": {"kind": zones[0].get("attributes", {}).get("kind")},
            "polyline": {"s": ss, "lateral_offset_m": us, "points": pts},
            "transform": {"position": pts[0], "rotation": _quat_facing(*f), "scale": [1.0, 1.0, 1.0]},
            "footprints_route": [[round(z["from_s"], 3), round(z["to_s"], 3)] + list(z["lateral_offset_m"]) for z in zones]}


def hints_from_sections(path, route, sem):
    """Landmark hints from a scene sections file (landmarks, named / special sections, lamp spacing)."""
    with open(path) as f:
        d = json.load(f)
    L = route["total_length_m"]
    secs = route.get("sections", [])
    water_left = sum(1 for z in sem["zones"] if z["semantic_type"] == "water" and z["side"] == "left")
    water_right = sum(1 for z in sem["zones"] if z["semantic_type"] == "water" and z["side"] == "right")
    lake, inland = ("left", "right") if water_left >= water_right else ("right", "left")
    src = lambda ref, note=None: {"kind": "scene_generator", "ref": f"{path} {ref}", "estimated": True, **({"note": note} if note else {})}
    hints = []
    for km, kind in d.get("landmarks", []):
        s = float(km) / d["video_km"] * L
        if kind in ("bench", "picnic"):
            hints.append({"semantic_type": "bench", "prototype": "bench_wood" if kind == "bench" else "picnic_table",
                          "importance": "medium", "s": s, "side": lake, "edge_offset_m": 1.2 if kind == "bench" else 3.0,
                          "confidence": 0.6, "source": src(f"landmarks {kind}")})
    for k, e in enumerate(d["sections"]):
        if k >= len(secs):
            break
        t = dict(d["types"][e[1]])
        if len(e) > 2 and isinstance(e[2], dict):
            t.update(e[2])
        note = e[3] if len(e) > 3 and isinstance(e[3], str) else None
        a, b = secs[k]["from_s"], secs[k]["to_s"]
        if e[1] == "inn":  # the named inn of the reference video: a landmark, not a generic chalet
            name = re.sub(r"^\d+:\d+\s*", "", note or "inn").split(",")[0].strip()
            hints.append({"semantic_type": "commercial_building", "prototype": "landmark_" + re.sub(r"\W+", "_", name.lower()).strip("_"),
                          "importance": "high", "name": name, "s": 0.5 * (a + b), "side": inland, "edge_offset_m": 6.0,
                          "dimensions_m": [22.0, 12.0, 12.0], "confidence": 0.7, "source": src(f"S{k + 1:02d} inn", note)})
        elif e[1] == "parking":
            hints.append({"semantic_type": "commercial_building", "prototype": "lodge", "importance": "medium", "name": "lodge",
                          "s": 0.5 * (a + b), "side": inland, "edge_offset_m": 6.0, "confidence": 0.6, "source": src(f"S{k + 1:02d} parking", note)})
        spacing = float(t.get("lamps", 0) or 0)
        if spacing > 0:
            s = a + spacing * 0.5
            while s < b:
                hints.append({"semantic_type": "lamp", "prototype": "lamp_lantern", "importance": "low", "s": s, "side": inland,
                              "edge_offset_m": 0.6, "confidence": 0.6, "source": src(f"S{k + 1:02d} lamps every {spacing:g} m")})
                s += spacing
    return hints


# ------------------------------------------------------------------ build
def _load(pkg):
    route, man, sem = vg._load(pkg)
    return route, man, sem


def build(pkg, sections=None, hints=None, seed=5):
    for need in ("route/route.json", "manifest.json", "semantics/semantics.json", "vegetation/zones.json"):
        if not os.path.isfile(os.path.join(pkg, need)):
            raise ValueError(f"structures need {need} first (route -> road/terrain -> semantics -> vegetation -> structures)")
    route, man, sem = _load(pkg)
    errs = rm.validate(route) + sm.validate(sem, route) + rt.validate(pkg)[0] + vg.validate(pkg)[0]
    if errs:
        raise ValueError("inputs invalid, not placing structures:\n  " + "\n  ".join(errs[:10]))
    site = Site(pkg, route, man, sem)
    site.linear = []
    objs, skipped, protos = [], [], dict(PROTOTYPES)
    nid = lambda: "st%04d" % (len(objs) + len(site.linear) + 1)
    # 1. linear barriers from semantic zones (merged across consecutive pieces)
    bars = sorted((z for z in sem["zones"] if z["semantic_type"] in sm_barriers()), key=lambda z: (z["semantic_type"], z["side"], z["from_s"]))
    run = []
    for z in bars + [None]:
        if run and (z is None or z["semantic_type"] != run[-1]["semantic_type"] or z["side"] != run[-1]["side"]
                    or z.get("attributes", {}).get("kind") != run[-1].get("attributes", {}).get("kind")
                    or abs(z["from_s"] - run[-1]["to_s"]) > 0.05):
            kind = run[0].get("attributes", {}).get("kind")
            t = run[0]["semantic_type"]
            proto = "retaining_wall_stone" if t == "wall" else LINEAR_PROTO.get(kind, "fence_rail" if t == "fence" else "guardrail_steel")
            site.linear.append(_linear(site, nid(), run, proto))
            run = []
        if z is not None:
            run.append(z)
    # 2. route markers, bridges, tunnel portals (spanning, high importance)
    for m, proto, name in [(route["start"], "gate_start", "START"), (route["finish"], "gate_finish", "FINISH")]:
        wl, wr = site.band(m["s"] - 0.5, m["s"] + 0.5)
        for z in site.zones((m["s"] - 0.5, m["s"] + 0.5, -1e9, 1e9), sm_barriers()):  # legs stand outside any barrier
            if z["side"] == "left":
                wl = max(wl, z["lateral_offset_m"][1] - 0.3)
            else:
                wr = max(wr, -z["lateral_offset_m"][0] - 0.3)
        o = {"object_id": nid(), "semantic_type": "race_landmark", "importance": "high", "placement": "spanning", "name": name,
             "s": m["s"], "lateral_offset_m": 0.0, "side": "both", "on_road": True, "prototype": proto,
             "dimensions_m": {"width": round(wl + wr + 1.6, 2), "height": 5.0, "depth": 1.0}, "confidence": 1.0,
             "source": {"kind": "manual", "ref": f"route.json {m['id']}"}, "anchor": {"s": m["s"], "lateral_offset_m": 0.0},
             "attributes": {"checkpoint": m["id"]},
             "footprints_route": [(m["s"] - 0.2, m["s"] + 0.2, wl + 0.6, wl + 1.0), (m["s"] - 0.2, m["s"] + 0.2, -(wr + 1.0), -(wr + 0.6))]}
        objs.append(o)
    for z in sem["zones"]:
        if z["semantic_type"] == "bridge":
            wl, wr = site.band(z["from_s"], z["to_s"])  # the deck spans the whole road over its length
            a, b = min(z["lateral_offset_m"][0], -(wr + 0.15)), max(z["lateral_offset_m"][1], wl + 0.15)
            objs.append({"object_id": nid(), "semantic_type": "bridge", "importance": "high", "placement": "spanning",
                         "s": round(0.5 * (z["from_s"] + z["to_s"]), 3), "lateral_offset_m": 0.0, "side": "both", "on_road": True,
                         "from_s": z["from_s"], "to_s": z["to_s"], "prototype": "footbridge_wood",
                         "dimensions_m": {"width": round(b - a, 2), "height": 1.1, "depth": round(z["to_s"] - z["from_s"], 2)},
                         "confidence": z["confidence"], "source": dict(z["source"], semantic_zones=[z["id"]]),
                         "anchor": {"s": round(0.5 * (z["from_s"] + z["to_s"]), 3), "lateral_offset_m": 0.0},
                         "footprints_route": [(z["from_s"], z["to_s"], a, b)]})
        elif z["semantic_type"] == "tunnel":
            a, b = z["lateral_offset_m"]
            for s, end in ((z["from_s"], "entry"), (z["to_s"], "exit")):
                objs.append({"object_id": nid(), "semantic_type": "tunnel_portal", "importance": "high", "placement": "spanning",
                             "s": s, "lateral_offset_m": 0.0, "side": "both", "on_road": True, "prototype": "tunnel_portal_stone",
                             "dimensions_m": {"width": round(b - a, 2), "height": 6.0, "depth": 2.0}, "confidence": z["confidence"],
                             "source": dict(z["source"], semantic_zones=[z["id"]]), "attributes": {"end": end},
                             "anchor": {"s": s, "lateral_offset_m": 0.0},
                             "footprints_route": [(s - 1.0, s + 1.0, a, b)]})
    # 3. hints: named landmarks first (high), then furniture (medium / low); checkpoint signs on the dry side
    hint_list = list(hints or [])
    wet = {z["side"] for z in sem["zones"] if z["semantic_type"] == "water"}
    for cp in route["checkpoints"]:
        hint_list.append({"semantic_type": "sign", "prototype": "sign_checkpoint", "importance": "medium", "name": cp.get("name", cp["id"]),
                          "s": cp["s"], "side": "right" if "right" not in wet else "left", "edge_offset_m": 0.8, "confidence": 1.0,
                          "source": {"kind": "manual", "ref": f"route.json checkpoint {cp['id']}"}})
    if sections:
        hint_list += hints_from_sections(sections, route, sem)
    order = {"high": 0, "medium": 1, "low": 2}
    for h in sorted(hint_list, key=lambda h: order[h["importance"]]):
        proto = h.get("prototype")
        if not proto and h["importance"] == "high":  # identity: its own prototype, named after the landmark
            proto = "landmark_" + re.sub(r"\W+", "_", h.get("name", h["semantic_type"]).lower()).strip("_")
        if not proto:
            proto = next((k for k, v in PROTOTYPES.items() if v["semantic_type"] == h["semantic_type"]), h["semantic_type"] + "_generic")
        dims = h.get("dimensions_m") or PROTOTYPES.get(proto, {}).get("dimensions_m", [10.0, 8.0, 8.0])
        if proto not in protos:  # high: a unique landmark prototype, never a reusable one
            protos[proto] = {"semantic_type": h["semantic_type"], "placement": "point", "dimensions_m": dims,
                             "unique": h["importance"] == "high",
                             "description": h.get("name", proto), "reference_assets": []}
        sign = 1.0 if h["side"] == "left" else -1.0
        placed = None
        tries = [0.0] + [d * k for k in range(1, int(SLIDE_M[h["importance"]] / 2.5) + 1) for d in (2.5, -2.5)]
        for ds in tries:
            s = h["s"] + ds
            wl, wr = site.band(s - dims[0] / 2, s + dims[0] / 2)
            u = h.get("lateral_offset_m", sign * ((wl if sign > 0 else wr) + h.get("edge_offset_m", 1.0) + dims[2] / 2))
            o = _point(site, nid(), h["semantic_type"], proto, h["importance"], s, u, dims, h.get("confidence", 0.6),
                       h["source"], h.get("name"), anchor={"s": round(h["s"], 3), "lateral_offset_m": round(u, 3)} if h["importance"] == "high" else None)
            if not site.problems(o) and not any(_box_overlap(o["footprints_route"][0], b) for p in objs for b in p["footprints_route"]):
                placed = o
                break
        if placed:
            objs.append(placed)
        elif h["importance"] == "high":  # never silently dropped or moved: keep it and let validation report why
            objs.append(o)
        else:
            skipped.append({"hint": h, "reason": "; ".join(site.problems(o)) or "overlaps another structure"})
    # 4. generic houses / barns in building zones (low importance, reusable prototypes)
    rng = random.Random(seed)
    for z in sem["zones"]:
        if z["semantic_type"] != "building_zone":
            continue
        kind = z.get("attributes", {}).get("kind", "houses")
        proto = "barn_timber" if kind == "barns" else "house_chalet"
        typ = PROTOTYPES[proto]["semantic_type"]
        s = z["from_s"] + rng.uniform(0, 10)
        while s < z["to_s"]:
            base = PROTOTYPES[proto]["dimensions_m"]
            dims = [round(v * rng.uniform(0.85, 1.2), 2) for v in base]
            a, b = z["lateral_offset_m"]
            if s - dims[0] / 2 >= z["from_s"] and s + dims[0] / 2 <= z["to_s"] and b - a > dims[2]:
                u = rng.uniform(a + dims[2] / 2, b - dims[2] / 2)
                o = _point(site, nid(), typ, proto, "low", s, u, dims, z["confidence"], dict(z["source"], semantic_zones=[z["id"]]),
                           attrs={"kind": kind, "clear_ground_cover": True})
                if not site.problems(o) and not any(_box_overlap(o["footprints_route"][0], bb) for p in objs for bb in p["footprints_route"]):
                    objs.append(o)
            s += dims[0] + rng.uniform(8.0, 25.0)
    for o in objs:
        _finish(site, o)
    allobjs = sorted(objs + site.linear, key=lambda o: o["s"])
    _write(pkg, route, man, allobjs, protos, skipped)
    return allobjs, skipped


def sm_barriers():
    return {"wall", "guardrail", "fence"}


def _write(pkg, route, man, objs, protos, skipped):
    d = os.path.join(pkg, "structures")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "structures.json"), "w") as f:
        json.dump({"version": VERSION, "route_id": route["route_id"], "objects": objs, "skipped_hints": skipped}, f, indent=1)
    with open(os.path.join(d, "prototypes.json"), "w") as f:
        json.dump({"version": VERSION, "types": TYPES, "importance": IMPORTANCE,
                   "frame": "local +Y up, +Z front, +X right; dimensions_m = [width X, height Y, depth Z]",
                   "prototypes": [dict(id=k, **v) for k, v in protos.items()]}, f, indent=1)
    tiles = man["tiles"]
    starts = [t["from_s"] for t in tiles]
    for t in tiles:
        groups, linear, ids = {}, [], []
        for o in objs:
            if tiles[min(max(rm.bisect.bisect_right(starts, o["s"]) - 1, 0), len(tiles) - 1)] is not t:
                continue
            ids.append(o["object_id"])
            if o["placement"] == "linear":
                linear.append({"object_id": o["object_id"], "proto": o["prototype"], "points": o["polyline"]["points"]})
            else:
                tr = o["transform"]
                dm = o["dimensions_m"]
                sc = [1.0, 1.0, 1.0]
                base = protos[o["prototype"]].get("dimensions_m")
                if base and base[0] > 0:  # per-instance size variation as scale of the prototype
                    sc = [round(dm["width"] / base[0], 3), round(dm["height"] / base[1], 3), round(dm["depth"] / base[2], 3)]
                g = groups.setdefault(o["prototype"], {"proto": o["prototype"], "semantic_type": o["semantic_type"], "count": 0,
                                                       "data": [], "object_id": []})
                g["count"] += 1
                g["data"] += tr["position"] + tr["rotation"] + sc
                g["object_id"].append(o["object_id"])
        path = f"tiles/{t['id']}/structures.json"
        with open(os.path.join(pkg, path), "w") as f:
            json.dump({"version": VERSION, "tile": t["id"], "from_s": t["from_s"], "to_s": t["to_s"],
                       "layout": "data: px py pz qx qy qz qw sx sy sz per instance (package frame = glTF axes); details by "
                                 "object_id in structures/structures.json",
                       "groups": sorted(groups.values(), key=lambda g: g["proto"]), "linear": linear}, f, separators=(",", ":"))
        t["files"]["structures"] = path
        t["structures"] = {}
        for o in objs:
            if o["object_id"] in ids:
                t["structures"][o["semantic_type"]] = t["structures"].get(o["semantic_type"], 0) + 1
    man["layers"]["P4_structures"] = {"status": "generated", "files": ["structures/structures.json", "structures/prototypes.json",
                                                                       "tiles/*/structures.json"]}
    with open(os.path.join(pkg, "manifest.json"), "w") as f:
        json.dump(man, f, indent=1)


# ------------------------------------------------------------------ validation
def validate(pkg):
    """(errors, report). Rechecks every object from the files; writes structures/validation.json."""
    route, man, sem = _load(pkg)
    with open(os.path.join(pkg, "structures", "structures.json")) as f:
        data = json.load(f)
    with open(os.path.join(pkg, "structures", "prototypes.json")) as f:
        protos = {p["id"]: p for p in json.load(f)["prototypes"]}
    objs = data["objects"]
    site = Site(pkg, route, man, sem)
    site.linear = [o for o in objs if o["placement"] == "linear"]
    errs = []
    total = route["total_length_m"]
    sem_by_id = {z["id"]: z for z in sem["zones"]}
    ids = [o["object_id"] for o in objs]
    if len(set(ids)) != len(ids):
        errs.append("object ids not unique")
    worst = {"anchor_m": 0.0, "ground_m": 0.0, "position_m": 0.0}
    for o in objs:
        oid, t = o["object_id"], o["semantic_type"]
        e = []
        for k in ("object_id", "semantic_type", "s", "lateral_offset_m", "transform", "dimensions_m", "prototype",
                  "confidence", "source", "importance"):
            if k not in o:
                e.append(f"missing {k}")
        if e:
            errs += [f"{oid}: {m}" for m in e]
            continue
        if t not in TYPES or o["importance"] not in IMPORTANCE or not 0 <= o["confidence"] <= 1:
            e.append("bad semantic_type / importance / confidence")
        p = protos.get(o["prototype"])
        if p is None or p["semantic_type"] != t:
            e.append(f"prototype {o['prototype']} missing or of another type")
        if not 0 <= o["s"] <= total + 1e-6:
            e.append("s outside the route")
        q = o["transform"]["rotation"]
        if abs(sum(v * v for v in q) - 1.0) > 1e-3:
            e.append("rotation not a unit quaternion")
        if o["importance"] == "high":  # identity: named or unique, anchored, not moved
            if not (o.get("name") or (p or {}).get("unique") or t in ("bridge", "tunnel_portal")):
                e.append("high importance without a name or unique prototype")
            a = o.get("anchor")
            if not a:
                e.append("high importance without an anchor")
            else:
                d = math.hypot(o["s"] - a["s"], o["lateral_offset_m"] - a["lateral_offset_m"])
                worst["anchor_m"] = max(worst["anchor_m"], d)
                if d > ANCHOR_TOL_M:
                    e.append(f"moved {d:.1f} m from its anchor")
        if o["placement"] == "linear":
            zs = [sem_by_id.get(z) for z in o["source"].get("semantic_zones", [])]
            if not zs or None in zs:
                e.append("linear object without its semantic barrier zones")
            else:
                pl = o["polyline"]
                for s, u, pt in zip(pl["s"], pl["lateral_offset_m"], pl["points"]):
                    if not any(z["from_s"] - 1e-3 <= s <= z["to_s"] + 1e-3 and z["lateral_offset_m"][0] - 1e-3 <= u <= z["lateral_offset_m"][1] + 1e-3 for z in zs):
                        e.append(f"polyline leaves its barrier zone at s={s}")
                        break
                    w = site.space.width(s, u)
                    if abs(u) < w - 0.01:
                        e.append(f"polyline on the road at s={s}")
                        break
                    x, z = site.space.world_xz(s, u)
                    worst["position_m"] = max(worst["position_m"], math.hypot(pt[0] - x, pt[2] - z))
                    g = site.ground(s, u)
                    if g is None:
                        e.append(f"polyline off the terrain at s={s}")
                        break
                    worst["ground_m"] = max(worst["ground_m"], abs(pt[1] - g))
                    if abs(pt[1] - g) > 0.05:
                        e.append(f"polyline {abs(pt[1] - g):.2f} m off the terrain at s={s}")
                        break
        else:
            boxes = [tuple(b) for b in o["footprints_route"]]
            check = dict(o, footprints_route=boxes)
            e += site.problems(check)
            pr = rm.sample(route, o["s"])
            _, left = _vec(pr["heading_deg"])
            x, z = pr["x"] + left[0] * o["lateral_offset_m"], pr["z"] + left[1] * o["lateral_offset_m"]
            pos = o["transform"]["position"]
            worst["position_m"] = max(worst["position_m"], math.hypot(pos[0] - x, pos[2] - z))
            if o.get("on_road"):
                if abs(pos[1] - pr["y"]) > 0.05:
                    e.append("on-road object not at road height")
                if t == "bridge":
                    zs = [sem_by_id.get(z) for z in o["source"].get("semantic_zones", [])]
                    if not zs or None in zs or not all(z["semantic_type"] == "bridge" and abs(z["from_s"] - o["from_s"]) < 0.5
                                                       and abs(z["to_s"] - o["to_s"]) < 0.5 for z in zs):
                        e.append("bridge does not match a semantic bridge zone")
                    wl, wr = site.band(o["from_s"], o["to_s"])
                    if boxes[0][2] > -wr or boxes[0][3] < wl:
                        e.append("bridge deck narrower than the road")
                if t == "tunnel_portal":
                    zs = [sem_by_id.get(z) for z in o["source"].get("semantic_zones", [])]
                    if not zs or None in zs or not any(z["semantic_type"] == "tunnel" and min(abs(z["from_s"] - o["s"]), abs(z["to_s"] - o["s"])) < 0.5 for z in zs):
                        e.append("tunnel portal not at the end of a semantic tunnel zone")
            else:
                b = boxes[0]
                hs = [site.ground(s, u) for s in (b[0], b[1]) for u in (b[2], b[3])]
                if None not in hs:
                    worst["ground_m"] = max(worst["ground_m"], abs(pos[1] - min(hs)))
                    if abs(pos[1] - min(hs)) > 0.05:
                        e.append(f"base {pos[1] - min(hs):.2f} m off the terrain")
            for other in objs:
                if other is not o and other["placement"] != "linear" and other["object_id"] > oid:
                    if any(_box_overlap(b, tuple(ob)) for b in boxes for ob in other["footprints_route"]):
                        e.append(f"overlaps {other['object_id']} ({other['semantic_type']})")
        errs += [f"{oid} ({t}, {o['importance']}): {m}" for m in e]
    if worst["position_m"] > 0.02:
        errs.append(f"world positions differ from s / lateral offset by {worst['position_m']:.3f} m")
    # per-tile files list every object once
    seen = []
    for tile in man["tiles"]:
        path = os.path.join(pkg, tile["files"].get("structures", "-"))
        if not os.path.isfile(path):
            errs.append(f"tile {tile['id']}: no structures file")
            continue
        with open(path) as f:
            td = json.load(f)
        for g in td["groups"]:
            if len(g["data"]) != 10 * g["count"] or len(g["object_id"]) != g["count"]:
                errs.append(f"tile {tile['id']}: group {g['proto']} arrays do not match count")
            seen += g["object_id"]
        seen += [lo["object_id"] for lo in td["linear"]]
    if sorted(seen) != sorted(ids):
        errs.append("per-tile structure files do not list every object exactly once")
    counts = {}
    for o in objs:
        counts.setdefault(o["semantic_type"], {}).setdefault(o["importance"], 0)
        counts[o["semantic_type"]][o["importance"]] += 1
    report = {"objects": len(objs), "by_type": counts, "skipped_hints": len(data.get("skipped_hints", [])),
              "worst": {k: round(v, 4) for k, v in worst.items()}, "errors": errs, "valid": not errs}
    with open(os.path.join(pkg, "structures", "validation.json"), "w") as f:
        json.dump(report, f, indent=1)
    return errs, report


def main(argv):
    opts = dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)
    args = [a for a in argv if not a.startswith("--")]
    if len(args) == 2 and args[0] == "build":
        hints = None
        if "hints" in opts:
            with open(opts["hints"]) as f:
                hints = json.load(f)
        objs, skipped = build(args[1], opts.get("sections"), hints, int(opts.get("seed", 5)))
        print(f"{args[1]}: {len(objs)} objects, {len(skipped)} hints skipped")
        for s in skipped:
            print(f"  skipped {s['hint']['semantic_type']} at s={s['hint']['s']:.0f}: {s['reason']}")
        args = ["validate", args[1]]
    if len(args) == 2 and args[0] == "validate":
        errs, rep = validate(args[1])
        for e in errs[:40]:
            print("  FAIL", e)
        print(f"  {rep['objects']} objects {json.dumps(rep['by_type'])}; worst {rep['worst']}")
        print("VALID" if not errs else f"INVALID ({len(errs)} problems)")
        return 0 if not errs else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
