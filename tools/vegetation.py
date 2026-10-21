#!/usr/bin/env python3
"""Vegetation distribution stage (P3): semantics zones -> vegetation zones -> prototypes + per-tile instances.
Engine-independent, stdlib only. Needs route/route.json, manifest.json + tiles (tools/road_terrain.py) and
semantics/semantics.json (tools/semantics.py); refuses to run if any of them is missing or invalid.

  python3 tools/vegetation.py build <package_dir> [--seed=11]
  python3 tools/vegetation.py validate <package_dir>

Format: docs/VEGETATION.md. Instances are drawn inside their zone at the zone's density, never on the playable band
(+ clearance per category), in buildings, water, tunnels, on bridges / road zones, on barriers, or (trees, shrubs,
rocks) between the road and a barrier; heights come from the terrain mesh actually written in tiles/*/terrain.glb.
"""
import bisect
import json
import math
import os
import random
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import road_terrain as rt  # noqa: E402
import route_model as rm  # noqa: E402
import semantics as sm  # noqa: E402

VERSION = "0.1"
CATEGORIES = ["grass", "shrub", "deciduous_tree", "conifer", "tropical_tree", "flowers", "rocks", "ground_cover"]
TALL = {"shrub", "deciduous_tree", "conifer", "tropical_tree", "rocks"}  # never between the road and a barrier
CLEARANCE_M = {"grass": 0.3, "flowers": 0.3, "ground_cover": 0.3, "rocks": 0.5, "shrub": 1.0,
               "deciduous_tree": 1.5, "conifer": 1.5, "tropical_tree": 1.5}  # from the playable band edge
MAX_PER_HA = {"grass": 20000, "flowers": 5000, "ground_cover": 10000, "rocks": 2000, "shrub": 3000,
              "deciduous_tree": 1500, "conifer": 1500, "tropical_tree": 1500}
EXCLUDE = {"building_zone", "water", "tunnel", "bridge", "road", "trail", "sidewalk"}
BARRIERS = {"wall", "guardrail", "fence"}
DENSITY_TOL = 0.15  # realised / target density per zone and prototype (zones expecting >= 20 instances)

# Engine-neutral prototype definitions. reference_assets name what the Godot scenes use today (Poly Haven CC0 or
# procedural); a runtime maps prototype ids to its own meshes / LODs.
PROTOTYPES = {
    "grass_clump": {"category": "grass", "height_m": [0.3, 0.8], "scale": [0.6, 1.3], "footprint_radius_m": 0.2,
                    "min_spacing_m": 0.0, "lod": {"cull_distance_m": 90}, "reference_assets": ["FoliageSpawner._make_clump", "grass_medium_01"]},
    "reed_clump": {"category": "grass", "height_m": [1.5, 2.5], "scale": [0.8, 1.3], "footprint_radius_m": 0.3,
                   "min_spacing_m": 0.0, "lod": {"cull_distance_m": 150}, "reference_assets": ["FoliageSpawner._make_reeds"]},
    "meadow_flowers": {"category": "flowers", "height_m": [0.1, 0.4], "scale": [0.7, 1.3], "footprint_radius_m": 0.15,
                       "min_spacing_m": 0.0, "lod": {"cull_distance_m": 60}, "reference_assets": ["celandine_01", "dandelion_01", "periwinkle_plant"]},
    "fern": {"category": "ground_cover", "height_m": [0.4, 1.0], "scale": [0.8, 1.6], "footprint_radius_m": 0.4,
             "min_spacing_m": 0.0, "lod": {"cull_distance_m": 80}, "reference_assets": ["fern_02"]},
    "shrub_broadleaf": {"category": "shrub", "height_m": [1.5, 4.0], "scale": [0.7, 1.3], "footprint_radius_m": 1.0,
                        "min_spacing_m": 1.2, "lod": {"lod_distances_m": [40, 120], "cull_distance_m": 250}, "reference_assets": ["FoliageSpawner._make_hazel", "shrub_02"]},
    "deciduous_broadleaf": {"category": "deciduous_tree", "height_m": [12.0, 28.0], "scale": [0.75, 1.15], "footprint_radius_m": 0.5,
                            "min_spacing_m": 2.5, "lod": {"lod_distances_m": [40, 120, 300], "billboard_from_m": 300, "cull_distance_m": 1200}, "reference_assets": ["FoliageSpawner._make_beech", "island_tree_02"]},
    "conifer_spruce": {"category": "conifer", "height_m": [15.0, 35.0], "scale": [0.75, 1.15], "footprint_radius_m": 0.4,
                       "min_spacing_m": 2.0, "lod": {"lod_distances_m": [40, 120, 300], "billboard_from_m": 300, "cull_distance_m": 1200}, "reference_assets": ["FoliageSpawner._make_conifer", "fir_sapling"]},
    "conifer_larch": {"category": "conifer", "height_m": [15.0, 30.0], "scale": [0.75, 1.15], "footprint_radius_m": 0.4,
                      "min_spacing_m": 2.0, "lod": {"lod_distances_m": [40, 120, 300], "billboard_from_m": 300, "cull_distance_m": 1200}, "reference_assets": ["FoliageSpawner._make_conifer (larch)"]},
    "tropical_palm": {"category": "tropical_tree", "height_m": [6.0, 18.0], "scale": [0.8, 1.2], "footprint_radius_m": 0.4,
                      "min_spacing_m": 3.0, "lod": {"lod_distances_m": [40, 120, 300], "cull_distance_m": 1200}, "reference_assets": []},
    "rock_small": {"category": "rocks", "height_m": [0.1, 0.5], "scale": [0.1, 0.35], "footprint_radius_m": 0.3,
                   "min_spacing_m": 0.0, "lod": {"cull_distance_m": 120}, "reference_assets": ["namaqualand_boulder_03"]},
    "rock_boulder": {"category": "rocks", "height_m": [1.0, 3.0], "scale": [0.6, 1.4], "footprint_radius_m": 1.5,
                     "min_spacing_m": 3.0, "lod": {"lod_distances_m": [60, 200], "cull_distance_m": 600}, "reference_assets": ["boulder_01"]},
}
SPECIES_PROTO = {"beech": "deciduous_broadleaf", "birch": "deciduous_broadleaf", "spruce": "conifer_spruce",
                 "fir": "conifer_spruce", "pine": "conifer_spruce", "larch": "conifer_larch", "palm": "tropical_palm"}
TREE_DENSITY = {"dense": 300.0, "medium": 150.0, "sparse": 60.0}  # stems / ha when the semantics give no number


# ------------------------------------------------------------------ semantics -> vegetation zones
def _trees(attrs, density):
    shares = attrs.get("species") or {"beech": 0.5, "spruce": 0.5}
    total = sum(shares.values()) or 1.0
    mix = {}
    for sp, v in shares.items():
        p = SPECIES_PROTO.get(sp, "deciduous_broadleaf")
        mix[p] = mix.get(p, 0.0) + v / total
    return [{"prototype": p, "density_per_ha": round(density * f, 2)} for p, f in sorted(mix.items()) if f > 0]


def _per_ha(per_100m, width):
    return per_100m / (100.0 * max(width, 0.5)) * 10000.0


def vegetation_zones(sem):
    """Distribution zones from the semantics. Each keeps the semantic zone's box; exclusions apply at sampling."""
    out = []
    for z in sem["zones"]:
        t, a = z["semantic_type"], z.get("attributes", {})
        width = z["lateral_offset_m"][1] - z["lateral_offset_m"][0]
        mix, kind = [], None
        if t == "forest":
            d = a.get("density", "medium")
            kind = f"{d}_forest"
            mix = _trees(a, float(a.get("stems_per_ha") or TREE_DENSITY.get(d, 150.0)))
            mix.append({"prototype": "fern", "density_per_ha": 400.0, "instanced_within_m": 20.0})
        elif t == "vegetation_zone" and a.get("kind") == "scattered_trees":
            kind = "sparse_trees"
            mix = _trees(a, float(a.get("stems_per_ha") or 30.0))
        elif t == "vegetation_zone" and a.get("kind") == "shrubs":
            kind = "roadside_shrubs"
            mix = [{"prototype": "shrub_broadleaf", "density_per_ha": round(_per_ha(float(a.get("per_100m", 10.0)), width), 2)}]
        elif t == "vegetation_zone" and a.get("kind") == "reeds":
            kind = "reed_bed"  # land side only: water is an exclusion (aquatic plants are not in 0.1)
            mix = [{"prototype": "reed_clump", "density_per_ha": round(_per_ha(float(a.get("per_100m", 20.0)), width), 2)}]
        elif t == "grass":
            kind = "grassland"
            cover = float(a.get("cover", 0.6))
            mix = [{"prototype": "grass_clump", "density_per_ha": round(2500.0 * cover, 2), "instanced_within_m": 25.0},
                   {"prototype": "meadow_flowers", "density_per_ha": round(200.0 * cover, 2), "instanced_within_m": 25.0},
                   {"prototype": "rock_small", "density_per_ha": 4.0}]
        elif t == "cliff":
            kind = "rocky_slope"
            mix = [{"prototype": "rock_boulder", "density_per_ha": 40.0}, {"prototype": "rock_small", "density_per_ha": 150.0},
                   {"prototype": "shrub_broadleaf", "density_per_ha": 30.0}]
        if not kind:
            continue
        out.append({"id": "v%04d" % (len(out) + 1), "kind": kind, "semantic_zone": z["id"], "side": z["side"],
                    "from_s": z["from_s"], "to_s": z["to_s"], "lateral_offset_m": list(z["lateral_offset_m"]),
                    "mix": mix, "confidence": z["confidence"], "source": z["source"]})
    return out


# ------------------------------------------------------------------ space: exclusions and ground
class Space:
    """Route-relative queries over one package: exclusions (band, semantics) and terrain height."""

    def __init__(self, pkg, route, man, sem):
        self.route, self.smp = route, route["samples"]
        self.s = self.smp["s"]
        self.buckets = {}
        for z in sem["zones"]:
            if z["semantic_type"] in EXCLUDE | BARRIERS:
                for b in range(int(z["from_s"] // 50), int(z["to_s"] // 50) + 1):
                    self.buckets.setdefault(b, []).append(z)
        self.rows = {}  # (side, sample index) -> [(u, world xyz)] sorted by u, every terrain column of that row
        for tile in man["tiles"]:
            m = rt.read_glb(os.path.join(pkg, tile["files"]["terrain"]))
            pos = rt._world(m)
            for k, (sv, u) in enumerate(zip(m["attributes"]["_ROUTE_S"], m["attributes"]["_ROUTE_U"])):
                i = min(max(bisect.bisect_left(self.s, sv - 0.01), 0), len(self.s) - 1)
                self.rows.setdefault((1 if u > 0 else -1, i), {})[round(u, 3)] = pos[k]
        self.rows = {k: sorted(v.items()) for k, v in self.rows.items()}

    def width(self, s, u):
        p = rm.sample(self.route, s)
        return p["width_left_m"] if u > 0 else p["width_right_m"]

    def world_xz(self, s, u):
        p = rm.sample(self.route, s)
        lx, lz = rm.left_vector(p["heading_deg"])
        return p["x"] + lx * u, p["z"] + lz * u

    def excluded(self, s, u, category, margin=0.0):
        """Reason string if (s, u) may not hold an instance of category, else None. margin widens every exclusion
        (generation uses 1 cm so rounding the written s / lateral offset cannot cross a boundary)."""
        side = 1 if u > 0 else -1
        w = self.width(s, u)
        if abs(u) < w + CLEARANCE_M[category] + margin:
            return "road clearance"
        for z in self.buckets.get(int(s // 50), []):
            if not z["from_s"] - margin <= s <= z["to_s"] + margin:
                continue
            a, b = z["lateral_offset_m"]
            t = z["semantic_type"]
            if t in BARRIERS:
                if (side > 0) != (z["side"] == "left"):
                    continue
                if category in TALL:  # nothing tall between the road and its barrier, nor on it
                    lo, hi = (w, b + 0.5) if side > 0 else (a - 0.5, -w)
                else:
                    lo, hi = a - 0.1, b + 0.1
                if lo - margin <= u <= hi + margin:
                    return t
            elif a - (CLEARANCE_M[category] if t in {"road", "trail", "sidewalk"} else 0.0) - margin <= u <= \
                    b + (CLEARANCE_M[category] if t in {"road", "trail", "sidewalk"} else 0.0) + margin:
                return t
        return None

    def ground(self, s, u, x, z):
        """Height of the terrain triangle under (x, z) (the mesh in terrain.glb), or None outside the terrain."""
        side = 1 if u > 0 else -1
        i = min(max(bisect.bisect_right(self.s, s) - 1, 0), len(self.s) - 2)
        for r in (i, i - 1, i + 1):
            A, B = self.rows.get((side, r)), self.rows.get((side, r + 1))
            if not A or not B:
                continue
            j = bisect.bisect_left([c[0] for c in A], u)
            for c in range(max(j - 2, 0), min(j + 2, len(A) - 1)):
                a, a1, b, b1 = A[c][1], A[c + 1][1], B[c][1], B[c + 1][1]
                for tri in ((a, b, a1), (b, b1, a1)):
                    y = _bary_y(tri, x, z)
                    if y is not None:
                        return y
        return None


def _bary_y(tri, x, z):
    (ax, ay, az), (bx, by, bz), (cx, cy, cz) = tri
    det = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
    if abs(det) < 1e-12:
        return None
    l1 = ((bz - cz) * (x - cx) + (cx - bx) * (z - cz)) / det
    l2 = ((cz - az) * (x - cx) + (ax - cx) * (z - cz)) / det
    l3 = 1.0 - l1 - l2
    return l1 * ay + l2 * by + l3 * cy if min(l1, l2, l3) >= -1e-4 else None


def lateral_range(zone, entry, wmax):
    """Lateral band an entry of the mix is instanced in (grass etc. only near the road: instanced_within_m)."""
    a, b = zone["lateral_offset_m"]
    lim = entry.get("instanced_within_m")
    if lim is not None:
        if zone["side"] == "left":
            b = min(b, wmax + lim)
        else:
            a = max(a, -(wmax + lim))
    return a, b


def free_area_ha(space, zone, entry, category):
    """Area of the zone box (for this entry) where the category may stand, by a regular grid of probes."""
    wmax = max(space.width(zone["from_s"], 1 if zone["side"] == "left" else -1),
               space.width(zone["to_s"], 1 if zone["side"] == "left" else -1))
    a, b = lateral_range(zone, entry, wmax)
    if b - a <= 0:
        return 0.0, (a, b)
    ns, nu = 24, 24
    ok = 0
    for i in range(ns):
        s = zone["from_s"] + (i + 0.5) / ns * (zone["to_s"] - zone["from_s"])
        for j in range(nu):
            u = a + (j + 0.5) / nu * (b - a)
            if space.excluded(s, u, category) is None:
                ok += 1
    # ponytail: area in route coordinates (ds x du); on a bend the true area differs by (1 - curvature * u)
    return ok / (ns * nu) * (zone["to_s"] - zone["from_s"]) * (b - a) / 10000.0, (a, b)


# ------------------------------------------------------------------ build
def _load(pkg):
    with open(os.path.join(pkg, "route", "route.json")) as f:
        route = json.load(f)
    with open(os.path.join(pkg, "manifest.json")) as f:
        man = json.load(f)
    with open(os.path.join(pkg, "semantics", "semantics.json")) as f:
        sem = json.load(f)
    return route, man, sem


def build(pkg, seed=11):
    for need in ("route/route.json", "manifest.json", "semantics/semantics.json"):
        if not os.path.isfile(os.path.join(pkg, need)):
            raise ValueError(f"vegetation needs {need} first (route -> road/terrain -> semantics -> vegetation)")
    route, man, sem = _load(pkg)
    errs = rm.validate(route) + sm.validate(sem, route) + rt.validate(pkg)[0]
    if errs:
        raise ValueError("inputs invalid, not generating vegetation:\n  " + "\n  ".join(errs[:10]))
    space = Space(pkg, route, man, sem)
    zones = vegetation_zones(sem)
    instances = []  # (proto, s, u, x, y, z, yaw, scale, zone id)
    for zone in zones:
        for entry in zone["mix"]:
            proto = PROTOTYPES[entry["prototype"]]
            cat = proto["category"]
            area, (a, b) = free_area_ha(space, zone, entry, cat)
            n = int(round(entry["density_per_ha"] * area))
            entry["free_area_ha"] = round(area, 4)
            entry["target_count"] = n
            rng = random.Random(seed * 1000003 + zlib.crc32(f"{zone['id']}/{entry['prototype']}".encode()))
            placed, grid, tries = 0, {}, 0
            sp = proto["min_spacing_m"]
            while placed < n and tries < 40 * n + 100:
                tries += 1
                s = rng.uniform(zone["from_s"], zone["to_s"])
                u = rng.uniform(a, b)
                if space.excluded(s, u, cat, margin=0.01):
                    continue
                x, z = space.world_xz(s, u)
                if sp > 0:  # dart throwing: keep the zone's trees / shrubs / boulders apart
                    cell = (int(x // sp), int(z // sp))
                    if any(math.hypot(x - q[0], z - q[1]) < sp for dx in (-1, 0, 1) for dz in (-1, 0, 1)
                           for q in grid.get((cell[0] + dx, cell[1] + dz), [])):
                        continue
                y = space.ground(s, u, x, z)
                if y is None:
                    continue
                if sp > 0:
                    grid.setdefault(cell, []).append((x, z))
                instances.append((entry["prototype"], s, u, x, y, z, rng.uniform(0, 2 * math.pi),
                                  rng.uniform(*proto["scale"]), zone["id"]))
                placed += 1
            entry["count"] = placed
    # write: zones, prototypes, per-tile instances
    vdir = os.path.join(pkg, "vegetation")
    os.makedirs(vdir, exist_ok=True)
    with open(os.path.join(vdir, "zones.json"), "w") as f:
        json.dump({"version": VERSION, "route_id": route["route_id"], "zones": zones}, f, indent=1)
    with open(os.path.join(vdir, "prototypes.json"), "w") as f:
        json.dump({"version": VERSION, "categories": CATEGORIES, "clearance_m": CLEARANCE_M,
                   "prototypes": [dict(id=k, **v) for k, v in PROTOTYPES.items()]}, f, indent=1)
    tiles = man["tiles"]
    starts = [t["from_s"] for t in tiles]
    per_tile = {t["id"]: {} for t in tiles}
    for inst in instances:
        t = tiles[min(max(bisect.bisect_right(starts, inst[1]) - 1, 0), len(tiles) - 1)]
        per_tile[t["id"]].setdefault(inst[0], []).append(inst)
    for t in tiles:
        groups, refs = [], []
        for proto, items in sorted(per_tile[t["id"]].items()):
            g = {"proto": proto, "category": PROTOTYPES[proto]["category"], "count": len(items),
                 "data": [], "s": [], "lateral_offset_m": [], "zone": []}
            for (_, s, u, x, y, z, yaw, sc, zid) in items:
                g["data"] += [round(x, 3), round(y, 3), round(z, 3), 0.0, round(math.sin(yaw / 2), 5), 0.0,
                              round(math.cos(yaw / 2), 5), round(sc, 3), round(sc, 3), round(sc, 3)]
                g["s"].append(round(s, 3))
                g["lateral_offset_m"].append(round(u, 3))
                if zid not in refs:
                    refs.append(zid)
                g["zone"].append(refs.index(zid))
            groups.append(g)
        path = f"tiles/{t['id']}/vegetation.json"
        with open(os.path.join(pkg, path), "w") as f:
            json.dump({"version": VERSION, "tile": t["id"], "from_s": t["from_s"], "to_s": t["to_s"],
                       "layout": "data: px py pz qx qy qz qw sx sy sz per instance, package frame (= glTF axes); "
                                 "s / lateral_offset_m route-relative; zone indexes zone_refs",
                       "zone_refs": refs, "groups": groups}, f, separators=(",", ":"))
        t["files"]["vegetation"] = path
        t["vegetation"] = {}
        for g in groups:
            t["vegetation"][g["category"]] = t["vegetation"].get(g["category"], 0) + g["count"]
    man["layers"]["P3_vegetation"] = {"status": "generated", "files": ["vegetation/zones.json", "vegetation/prototypes.json",
                                                                       "tiles/*/vegetation.json"]}
    with open(os.path.join(pkg, "manifest.json"), "w") as f:
        json.dump(man, f, indent=1)
    return zones, len(instances)


# ------------------------------------------------------------------ validation
def validate(pkg):
    """(errors, report). Reads only files; writes vegetation/validation.json."""
    route, man, sem = _load(pkg)
    errs = []
    with open(os.path.join(pkg, "vegetation", "zones.json")) as f:
        vz = json.load(f)
    with open(os.path.join(pkg, "vegetation", "prototypes.json")) as f:
        protos = {p["id"]: p for p in json.load(f)["prototypes"]}
    zones = {z["id"]: z for z in vz["zones"]}
    sem_ids = {z["id"] for z in sem["zones"]}
    for z in vz["zones"]:
        if z["semantic_zone"] not in sem_ids:
            errs.append(f"{z['id']}: semantic zone {z['semantic_zone']} not in semantics.json")
        for e in z["mix"]:
            if e["prototype"] not in protos:
                errs.append(f"{z['id']}: unknown prototype {e['prototype']}")
    space = Space(pkg, route, man, sem)
    counts = {}  # (zone, proto) -> realised
    worst = {"clearance_m": math.inf, "position_m": 0.0, "ground_m": 0.0}
    total = 0
    for t in man["tiles"]:
        path = os.path.join(pkg, t["files"].get("vegetation", ""))
        if not os.path.isfile(path):
            errs.append(f"tile {t['id']}: no vegetation file")
            continue
        with open(path) as f:
            tv = json.load(f)
        bad = {}
        for g in tv["groups"]:
            p = protos.get(g["proto"])
            if p is None or p["category"] != g["category"] or g["category"] not in CATEGORIES:
                errs.append(f"tile {t['id']}: group {g['proto']} has no matching prototype / category")
                continue
            cat = g["category"]
            n = g["count"]
            if not (len(g["data"]) == 10 * n and len(g["s"]) == n == len(g["lateral_offset_m"]) == len(g["zone"])):
                errs.append(f"tile {t['id']}: group {g['proto']} arrays do not match count {n}")
                continue
            for k in range(n):
                x, y, z, qx, qy, qz, qw, sx, sy, sz = g["data"][10 * k: 10 * k + 10]
                s, u = g["s"][k], g["lateral_offset_m"][k]
                zid = tv["zone_refs"][g["zone"][k]]
                zone = zones.get(zid)
                total += 1
                counts[(zid, g["proto"])] = counts.get((zid, g["proto"]), 0) + 1

                def fail(reason):
                    bad[reason] = bad.get(reason, 0) + 1

                if not t["from_s"] - 1e-6 <= s <= t["to_s"] + 1e-6:
                    fail("outside its tile's s range")
                if zone is None or not (zone["from_s"] - 1e-3 <= s <= zone["to_s"] + 1e-3 and
                                        zone["lateral_offset_m"][0] - 1e-3 <= u <= zone["lateral_offset_m"][1] + 1e-3):
                    fail("outside its density region")
                why = space.excluded(s, u, cat)
                if why:
                    fail(f"in an exclusion ({why})")
                worst["clearance_m"] = min(worst["clearance_m"], abs(u) - space.width(s, u))
                ex, ez = space.world_xz(s, u)
                worst["position_m"] = max(worst["position_m"], math.hypot(x - ex, z - ez))
                gy = space.ground(s, u, ex, ez)
                if gy is None:
                    fail("not over terrain")
                else:
                    worst["ground_m"] = max(worst["ground_m"], abs(y - gy))
                if abs(qx * qx + qy * qy + qz * qz + qw * qw - 1.0) > 1e-3 or min(sx, sy, sz) <= 0:
                    fail("bad rotation / scale")
                if not p["scale"][0] - 1e-3 <= sx <= p["scale"][1] + 1e-3:
                    fail("scale outside the prototype range")
        for reason, c in bad.items():
            errs.append(f"tile {t['id']}: {c} instances {reason}")
    if worst["position_m"] > 0.02:
        errs.append(f"instance world position differs from route s / lateral offset by {worst['position_m']:.3f} m")
    if worst["ground_m"] > 0.05:
        errs.append(f"instance height differs from the terrain mesh by {worst['ground_m']:.3f} m")
    # density: realised vs target on the free area, per zone and prototype; absolute caps; spacing
    dens = []
    for z in vz["zones"]:
        for e in z["mix"]:
            got = counts.get((z["id"], e["prototype"]), 0)
            area, _ = free_area_ha(space, z, e, protos[e["prototype"]]["category"])
            want = e["density_per_ha"] * area
            cat = protos[e["prototype"]]["category"]
            if want >= 20 and abs(got / want - 1.0) > DENSITY_TOL:
                errs.append(f"{z['id']} {e['prototype']}: {got} instances, density target gives {want:.0f}")
            if area > 0.05 and got / area > MAX_PER_HA[cat]:
                errs.append(f"{z['id']} {e['prototype']}: {got / area:.0f}/ha above the {cat} cap {MAX_PER_HA[cat]}")
            if want >= 20:
                dens.append(got / want)
    report = {"instances": total, "worst": {k: (round(v, 4) if math.isfinite(v) else None) for k, v in worst.items()},
              "density_ratio": [round(min(dens), 3), round(max(dens), 3)] if dens else None,
              "errors": errs, "valid": not errs}
    with open(os.path.join(pkg, "vegetation", "validation.json"), "w") as f:
        json.dump(report, f, indent=1)
    return errs, report


def main(argv):
    opts = dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)
    args = [a for a in argv if not a.startswith("--")]
    if len(args) == 2 and args[0] == "build":
        zones, n = build(args[1], int(opts.get("seed", 11)))
        kinds = {}
        for z in zones:
            kinds[z["kind"]] = kinds.get(z["kind"], 0) + 1
        print(f"{args[1]}: {len(zones)} vegetation zones {dict(sorted(kinds.items()))}, {n} instances")
        args = ["validate", args[1]]
    if len(args) == 2 and args[0] == "validate":
        errs, rep = validate(args[1])
        for e in errs[:40]:
            print("  FAIL", e)
        print(f"  {rep['instances']} instances; min clearance beyond the road edge {rep['worst']['clearance_m']} m; "
              f"position error {rep['worst']['position_m']} m; ground error {rep['worst']['ground_m']} m; "
              f"density realised/target {rep['density_ratio']}")
        print("VALID" if not errs else f"INVALID ({len(errs)} problems)")
        return 0 if not errs else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
