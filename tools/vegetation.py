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
import re
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
PROTOTYPES["norfolk_pine"] = {"category": "conifer", "height_m": [14, 25], "scale": [.75, 1.15],
    "footprint_radius_m": .4, "min_spacing_m": 3,
    "lod": {"lod_distances_m": [50, 150, 400], "cull_distance_m": 1200},
    "reference_assets": ["procedural tiered Araucaria silhouette"]}
SPECIES_PROTO = {"norfolk_pine": "norfolk_pine", "beech": "deciduous_broadleaf", "birch": "deciduous_broadleaf", "spruce": "conifer_spruce",
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


def split_zones_by_semantics(zones, semantic_mapping):
    """Replace P3 zone records whose semantics were split, scaling area-derived targets."""
    result = []
    digits = [int(m.group(1)) for z in zones if (m := re.search(r"(\d+)", z["id"]))]
    next_id = max(digits, default=0) + 1
    for zone in zones:
        pieces = semantic_mapping.get(zone.get("semantic_zone"))
        if pieces is None:
            result.append(zone)
            continue
        old_area = max(1e-9, (zone["to_s"] - zone["from_s"]) *
                       (zone["lateral_offset_m"][1] - zone["lateral_offset_m"][0]))
        for semantic in pieces:
            if semantic["semantic_type"] == "open_space":
                continue
            clone = dict(zone)
            clone["id"] = f"v{next_id:04d}"; next_id += 1
            clone["semantic_zone"] = semantic["id"]
            clone["from_s"], clone["to_s"] = semantic["from_s"], semantic["to_s"]
            clone["lateral_offset_m"] = list(semantic["lateral_offset_m"])
            ratio = ((clone["to_s"] - clone["from_s"]) *
                     (clone["lateral_offset_m"][1] - clone["lateral_offset_m"][0])) / old_area
            clone["mix"] = [dict(m) for m in zone["mix"]]
            for mix in clone["mix"]:
                for key in ("free_area_ha", "target_count", "count"):
                    if key in mix:
                        mix[key] = round(mix[key] * ratio, 5 if key == "free_area_ha" else 0)
            result.append(clone)
    return result


def remap_existing_zone_refs(tile, variants):
    """Point unchanged tile instances at the split P3 zone that contains each stored s/u."""
    refs = list(tile["zone_refs"])
    changed = 0
    for group in tile["groups"]:
        for i, ref_index in enumerate(list(group["zone"])):
            if ref_index >= len(refs):
                raise ValueError(f"bad zone index for {group['proto']}[{i}]")
            options = variants.get(refs[ref_index])
            if not options:
                continue
            s, u = group["s"][i], group["lateral_offset_m"][i]
            matches = [z for z in options
                       if z["from_s"] - 1e-3 <= s <= z["to_s"] + 1e-3
                       and z["lateral_offset_m"][0] - 1e-3 <= u <= z["lateral_offset_m"][1] + 1e-3
                       and any(m["prototype"] == group["proto"] for m in z["mix"])]
            if len(matches) != 1:
                raise ValueError(f"expected one split density zone for {group['proto']}[{i}] at {(s,u)}; got {len(matches)}")
            zone_id = matches[0]["id"]
            if zone_id not in refs:
                refs.append(zone_id)
            group["zone"][i] = refs.index(zone_id)
            changed += 1
    used = {index for group in tile["groups"] for index in group["zone"]}
    drop = {index for index, zone_id in enumerate(refs) if zone_id in variants and index not in used}
    if drop:
        kept = [zone_id for index, zone_id in enumerate(refs) if index not in drop]
        remap = {}
        new_index = 0
        for old_index in range(len(refs)):
            if old_index not in drop:
                remap[old_index] = new_index
                new_index += 1
        for group in tile["groups"]:
            group["zone"] = [remap[index] for index in group["zone"]]
        refs = kept
    tile["zone_refs"] = refs
    return changed


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
        positions=[]
        for i in range(len(self.s)):
            us=[-self.smp["width_right_m"][i],0.,self.smp["width_left_m"][i]]
            positions.extend(rt._cross_section(self.smp,i,us,[self.smp["y"][i]]*3))
        self.road_corridors=rt.RoadCorridors(positions,rt._grid_indices(len(self.s),3,positions=positions),
                                            [s for s in self.s for _ in range(3)])
        self.ground_triangles = {}
        self.ground_triangles_xz = {}
        self.ground_xz_cell_m = 64.0
        for tile in man["tiles"]:
            m = rt.read_glb(os.path.join(pkg, tile["files"]["terrain"]))
            pos = rt._world(m)
            ss = m["attributes"]["_ROUTE_S"]
            for primitive in m["primitives"]:
                idx = primitive["indices"]
                for k in range(0,len(idx),3):
                    ids = idx[k:k+3]
                    a,b = min(ss[i] for i in ids),max(ss[i] for i in ids)
                    tri = [pos[i] for i in ids]
                    box = (min(p[0] for p in tri),max(p[0] for p in tri),min(p[2] for p in tri),max(p[2] for p in tri))
                    for bucket in range(math.floor((a-.01)/2),math.floor((b+.01)/2)+1):
                        self.ground_triangles.setdefault(bucket,[]).append((box,tri))
                    cell = self.ground_xz_cell_m
                    for gx in range(math.floor(box[0] / cell), math.floor(box[1] / cell) + 1):
                        for gz in range(math.floor(box[2] / cell), math.floor(box[3] / cell) + 1):
                            self.ground_triangles_xz.setdefault((gx, gz), []).append((box, tri))

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
        x,z = self.world_xz(s,u)
        if self.road_corridors.contains_foreign(x,z,s,CLEARANCE_M[category]+margin):
            return "another route traversal"
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
        return self.ground_world(x, z, self.ground_triangles.get(math.floor(s / 2), ()))

    def ground_world(self, x, z, candidates=None):
        """Highest shipped P1 surface under world-XZ, or None if no triangle covers the point."""
        if candidates is None:
            cell = self.ground_xz_cell_m
            candidates = self.ground_triangles_xz.get((math.floor(x / cell), math.floor(z / cell)), ())
        hits = []
        for box, tri in candidates:
            if box[0] - 1e-5 <= x <= box[1] + 1e-5 and box[2] - 1e-5 <= z <= box[3] + 1e-5:
                y = _bary_y(tri, x, z)
                if y is not None:
                    hits.append(y)
        return max(hits) if hits else None


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


def apply_local_overrides(pkg, config_path):
    """Apply a small, data-authored prototype/scale override without resampling instances.

    This preserves every instance's route-relative and world position fields. Only the configured
    zone/prototype matches are retagged and uniformly scaled; the package's other vegetation is untouched.
    """
    with open(config_path) as f:
        config = json.load(f)
    vdir = os.path.join(pkg, "vegetation")
    with open(os.path.join(vdir, "zones.json")) as f:
        zones_doc = json.load(f)
    with open(os.path.join(vdir, "prototypes.json")) as f:
        protos_doc = json.load(f)
    zones = {z["id"]: z for z in zones_doc["zones"]}
    protos = {p["id"]: p for p in protos_doc["prototypes"]}

    for definition in config.get("prototype_aliases", []):
        alias = definition["id"]
        if alias in protos:
            raise ValueError(f"prototype alias already exists: {alias}")
        base = protos.get(definition["base"])
        if base is None:
            raise ValueError(f"unknown base prototype: {definition['base']}")
        clone = json.loads(json.dumps(base))
        clone["id"] = alias
        for key in ("scale", "height_m", "source", "reference_assets", "category",
                    "footprint_radius_m", "min_spacing_m", "lod"):
            if key in definition:
                clone[key] = definition[key]
        clone["derived_from"] = definition["base"]
        protos_doc["prototypes"].append(clone)
        protos[alias] = clone

    rules = {}
    target_zone_ids = set()
    for rule in config.get("zone_rules", []):
        for zid in rule["zones"]:
            if zid not in zones:
                raise ValueError(f"unknown vegetation zone: {zid}")
            if zid in rules:
                raise ValueError(f"duplicate zone override: {zid}")
            rules[zid] = rule
            target_zone_ids.add(zid)
            if "mix" in rule:
                zone_mix = json.loads(json.dumps(rule["mix"]))
                old_area = next((entry.get("free_area_ha") for entry in zones[zid]["mix"]
                                 if entry.get("free_area_ha") is not None), None)
                for entry in zone_mix:
                    if "free_area_ha" not in entry and old_area is not None:
                        entry["free_area_ha"] = old_area
                zones[zid]["mix"] = zone_mix

    if not rules and not config.get("prototype_aliases"):
        return 0

    changed = 0
    manifest_path = os.path.join(pkg, "manifest.json")
    with open(manifest_path) as f:
        manifest = json.load(f)
    for tile in manifest["tiles"]:
        path = os.path.join(pkg, tile["files"].get("vegetation", ""))
        if not os.path.isfile(path):
            continue
        with open(path) as f:
            doc = json.load(f)
        if not any(zid in target_zone_ids for zid in doc.get("zone_refs", [])):
            continue
        output = {}
        for group in doc["groups"]:
            n = group["count"]
            for i in range(n):
                zid = doc["zone_refs"][group["zone"][i]]
                rule = rules.get(zid)
                spec = next((x for x in rule.get("replace", []) if x["from"] == group["proto"]), None) if rule else None
                proto = spec["to"] if spec else group["proto"]
                if proto not in protos:
                    raise ValueError(f"unknown override target prototype: {proto}")
                row = output.setdefault(proto, {"proto": proto, "category": protos[proto]["category"],
                                                "count": 0, "data": [], "s": [],
                                                "lateral_offset_m": [], "zone_refs": []})
                data = group["data"][10 * i:10 * i + 10]
                if spec:
                    factors = spec.get("scale_multiplier_xyz")
                    if factors is None:
                        factors = [float(spec.get("scale_multiplier", 1.0))] * 3
                    if len(factors) != 3 or any(float(factor) <= 0 for factor in factors):
                        raise ValueError(f"scale multiplier must be a positive scalar or XYZ triple: {spec}")
                    data[7:10] = [round(v * float(factor), 3) for v, factor in zip(data[7:10], factors)]
                    changed += 1
                row["count"] += 1
                row["data"].extend(data)
                row["s"].append(group["s"][i])
                row["lateral_offset_m"].append(group["lateral_offset_m"][i])
                row["zone_refs"].append(zid)
        refs = []
        groups = []
        for proto in sorted(output):
            row = output[proto]
            zone_ids = row.pop("zone_refs")
            for zid in zone_ids:
                if zid not in refs:
                    refs.append(zid)
            row["zone_ids"] = zone_ids
            groups.append(row)
        doc["zone_refs"] = refs
        for group in groups:
            group["zone"] = [refs.index(zid) for zid in group.pop("zone_ids")]
        doc["groups"] = groups
        tile["vegetation"] = {}
        for group in groups:
            tile["vegetation"][group["category"]] = tile["vegetation"].get(group["category"], 0) + group["count"]
        with open(path, "w") as f:
            json.dump(doc, f, separators=(",", ":"))

    with open(os.path.join(vdir, "zones.json"), "w") as f:
        json.dump(zones_doc, f, indent=1)
    with open(os.path.join(vdir, "prototypes.json"), "w") as f:
        json.dump(protos_doc, f, indent=1)
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=1)
    return changed


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
    if len(args) == 3 and args[0] == "apply-local-overrides":
        changed = apply_local_overrides(args[1], args[2])
        print(f"{args[1]}: applied local vegetation overrides to {changed} instances")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
