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
import gltf_mesh  # noqa: E402

VERSION = "0.1"
TYPES = ["house", "commercial_building", "station", "hut", "church", "bridge", "pier", "tunnel_portal", "retaining_wall",
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
    "coastal_house_gable": {"semantic_type": "house", "placement": "point", "dimensions_m": [18.0, 6.0, 8.0],
                            "reference_assets": ["Shared pale low-rise gable house; video-estimated generic shape"]},
    "coastal_apartment_corner_36": {"semantic_type": "commercial_building", "placement": "point", "dimensions_m": [18.0, 36.0, 15.0],
                                     "reference_assets": ["Shared coastal apartment with wrap-around corner balconies; video-estimated generic shape"]},
    "rotary_chapel_gable": {"semantic_type": "church", "placement": "point", "dimensions_m": [5.9, 8.0, 14.9],
                            "reference_assets": ["Rotary Broadwater Chapel OSM footprint + owner exterior; estimated detail"]},
    "sky_broadwater_podium": {"semantic_type": "commercial_building", "placement": "point", "dimensions_m": [46.1, 40.16, 62.3],
                              "reference_assets": ["Sky Broadwater OSM part 1115393562; BDA architect exterior; estimated podium detail"]},
    "park_art_cylinder": {"semantic_type": "monument", "placement": "point", "dimensions_m": [6.5, 4.8, 6.5],
                          "reference_assets": ["Video-estimated openwork cylindrical park sculpture; source pixels not included"]},
    "broadwater_jetty": {"semantic_type": "pier", "placement": "point", "dimensions_m": [24.0, 2.1, 12.0],
                         "asset_parameters": {"deck_local_y_m": 1.2, "pile_size_m": 0.28,
                                               "pile_layout_xz_m": [[x,z] for x in (-10.0,-3.3,3.3,10.0) for z in (-4.4,-1.5,1.5,4.4)],
                                               "pile_bottom_corner_offsets_m": [[0.0]*4 for _ in range(16)]},
                         "reference_assets": ["S08 private-video morphology review; dimensions and location estimated; no frame pixels included"]},
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
    "fence_timber_rail": {"semantic_type": "fence", "placement": "linear", "profile_m": {"height": 1.05, "thickness": 0.09, "post_spacing": 2.2}, "reference_assets": ["Timber posts and twin rails; video-estimated local profile"]},
    "fence_boards": {"semantic_type": "fence", "placement": "linear", "profile_m": {"height": 1.35, "thickness": 0.06, "post_spacing": 2.0}, "reference_assets": ["Boardwalk boardfence"]},
    "fence_pasture": {"semantic_type": "fence", "placement": "linear", "profile_m": {"height": 1.0, "thickness": 0.05, "post_spacing": 4.0}, "reference_assets": ["Boardwalk efence"]},
    "fence_lattice": {"semantic_type": "fence", "placement": "linear", "profile_m": {"height": 1.0, "thickness": 0.05, "post_spacing": 2.0}, "reference_assets": ["Boardwalk lattice"]},
}
LINEAR_PROTO = {"cable": "guardrail_cable", "lograil": "guardrail_lograil", "guardrail": "guardrail_steel",
                "boardfence": "fence_boards", "efence": "fence_pasture", "lattice": "fence_lattice",
                "timber_rail": "fence_timber_rail"}


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


def valid_foundation_support_policy(obj, manifest):
    """Accept only the r16-style estimated local P1 pad backed by matching manifest provenance."""
    attrs = obj.get("attributes", {})
    source = obj.get("source", {})
    transform = obj.get("transform", {})
    if not isinstance(source, dict) or not isinstance(attrs, dict) or not isinstance(transform, dict):
        return False
    support = attrs.get("foundation_support")
    if not isinstance(support, dict):
        return False
    position = transform.get("position", [])
    tile_id = str(support.get("p1_tile", ""))
    pad_y = support.get("pad_top_y_m")
    def finite_number(value):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return False
        try:
            return math.isfinite(float(value))
        except (OverflowError, ValueError):
            return False
    if (support.get("kind") != "estimated_local_level_pad"
            or not isinstance(source.get("kind"), str) or not source.get("kind")
            or source.get("estimated") is not True or not isinstance(source.get("ref"), str) or not source.get("ref")
            or attrs.get("candidate_only") is not True
            or not isinstance(position, (list, tuple)) or len(position) != 3 or not finite_number(pad_y)
            or not all(finite_number(v) for v in position)
            or abs(float(pad_y) - position[1]) > 0.01
            or not all(finite_number(support.get(key)) and 0 <= support[key] <= limit
                       for key, limit in (("max_gap_m", 0.05), ("max_penetration_m", 0.02)))):
        return False
    tiles = manifest.get("tiles", [])
    if not isinstance(tiles, list) or tile_id not in {str(tile.get("id")) for tile in tiles
                                                     if isinstance(tile, dict)
                                                     and isinstance(tile.get("files"), dict)
                                                     and tile["files"].get("terrain")}:
        return False
    x, z = position[0], position[2]
    patches = manifest.get("p1_local_support_patches", [])
    if not isinstance(patches, list):
        return False
    for patch in patches:
        if not isinstance(patch, dict):
            continue
        polygon = patch.get("polygon_xz_m", [])
        patch_source = patch.get("source", {})
        if not isinstance(patch_source, dict):
            continue
        if (str(patch.get("tile_id")) != tile_id or patch.get("estimated") is not True
                or not isinstance(patch_source.get("kind"), str) or not patch_source.get("kind")
                or patch_source.get("estimated") is not True
                or not isinstance(patch_source.get("ref"), str) or not patch_source.get("ref")
                or not isinstance(patch.get("method"), str) or not patch.get("method")
                or not finite_number(patch.get("top_y_m"))
                or abs(float(patch["top_y_m"]) - float(pad_y)) > 0.001
                or not isinstance(polygon, list) or len(polygon) < 3
                or len({(point[0], point[1]) for point in polygon
                        if isinstance(point, (list, tuple)) and len(point) == 2
                        and all(finite_number(v) for v in point)}) < 3
                or any(not isinstance(point, (list, tuple)) or len(point) != 2
                       or not all(finite_number(v) for v in point) for point in polygon)):
            continue
        area = sum(polygon[i][0] * polygon[(i + 1) % len(polygon)][1]
                   - polygon[(i + 1) % len(polygon)][0] * polygon[i][1]
                   for i in range(len(polygon)))
        if abs(area) <= 1e-8:
            continue
        inside = False
        previous = polygon[-1]
        for current in polygon:
            x1, z1 = current; x2, z2 = previous
            cross = (x - x1) * (z2 - z1) - (z - z1) * (x2 - x1)
            if abs(cross) <= 1e-8 and min(x1, x2) - 1e-8 <= x <= max(x1, x2) + 1e-8 and min(z1, z2) - 1e-8 <= z <= max(z1, z2) + 1e-8:
                return True
            if (z1 > z) != (z2 > z):
                try:
                    if x < (x2 - x1) * (z - z1) / (z2 - z1) + x1:
                        inside = not inside
                except (ZeroDivisionError, TypeError, ValueError):
                    inside = False
                    break
            previous = current
        if inside:
            return True
    return False


def point_world_base_samples(obj):
    """Nine world-XZ support samples from a point object's rigidly transformed local footprint."""
    dims = obj["dimensions_m"]
    w, d = dims["width"], dims["depth"]
    transform = obj["transform"]
    px, py, pz = transform["position"]
    qx, qy, qz, qw = transform["rotation"]
    sx, sy, sz = transform["scale"]
    samples = []
    for lx in (-w / 2, 0.0, w / 2):
        for lz in (-d / 2, 0.0, d / 2):
            vx, vy, vz = lx * sx, 0.0 * sy, lz * sz
            # q * v * conjugate(q), valid for the package's general unit quaternion.
            tx = 2.0 * (qy * vz - qz * vy)
            ty = 2.0 * (qz * vx - qx * vz)
            tz = 2.0 * (qx * vy - qy * vx)
            rx = vx + qw * tx + (qy * tz - qz * ty)
            ry = vy + qw * ty + (qz * tx - qx * tz)
            rz = vz + qw * tz + (qx * ty - qy * tx)
            samples.append({"x": px + rx, "y": py + ry, "z": pz + rz})
    return samples


def point_world_mesh_support_samples(obj, local_vertices):
    """Transform unique lowest mesh vertices (plus footprint grid) into world support samples."""
    if not local_vertices:
        return point_world_base_samples(obj)
    base_y = min(v[1] for v in local_vertices)
    support = [tuple(v) for v in local_vertices if v[1] <= base_y + 1e-3]
    dims = obj["dimensions_m"]
    proto_dims = obj.get("prototype_dimensions_m")
    if proto_dims and all(v > 0 for v in proto_dims):
        # Match _write's tile scale exactly; dimensions_m and the footprint grid are already physical.
        mesh_scale = [round(dims["width"] / proto_dims[0], 3), round(dims["height"] / proto_dims[1], 3),
                      round(dims["depth"] / proto_dims[2], 3)]
        mesh_points = [(v[0] * mesh_scale[0], v[1] * mesh_scale[1], v[2] * mesh_scale[2]) for v in support]
        grid_scale = [1.0, 1.0, 1.0]
    else:
        # Legacy direct callers have no prototype metadata; honor the supplied object transform scale.
        sx, sy, sz = obj["transform"]["scale"]
        mesh_points = [(v[0] * sx, v[1] * sy, v[2] * sz) for v in support]
        grid_scale = [sx, sy, sz]
    unique = {(round(v[0], 4), round(v[1], 4), round(v[2], 4)) for v in mesh_points}
    unique.update((round(x * grid_scale[0], 4), 0.0, round(z * grid_scale[2], 4))
                  for x in (-dims["width"] / 2, 0.0, dims["width"] / 2)
                  for z in (-dims["depth"] / 2, 0.0, dims["depth"] / 2))
    transform = obj["transform"]
    px, py, pz = transform["position"]
    qx, qy, qz, qw = transform["rotation"]
    out = []
    for lx, ly, lz in sorted(unique):
        vx, vy, vz = lx, ly, lz
        tx = 2.0 * (qy * vz - qz * vy)
        ty = 2.0 * (qz * vx - qx * vz)
        tz = 2.0 * (qx * vy - qy * vx)
        out.append({"x": px + vx + qw * tx + qy * tz - qz * ty,
                    "y": py + vy + qw * ty + qz * tx - qx * tz,
                    "z": pz + vz + qw * tz + qx * ty - qy * tx})
    return out


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

    def foreign_road_in(self, box, clearance):
        """Probe a footprint at <=1m spacing against every other traversal's physical road corridor."""
        a,b,lo,hi=box
        ns=max(1,math.ceil(b-a));nu=max(1,math.ceil(hi-lo))
        for i in range(ns+1):
            s=a+(b-a)*i/ns
            for j in range(nu+1):
                u=lo+(hi-lo)*j/nu
                x,z=self.space.world_xz(s,u)
                if self.space.road_corridors.contains_foreign(x,z,s,clearance):return True
        return False

    def problems(self, obj, check_ground=True):
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
                if self.foreign_road_in(box, clear):
                    out.append("footprint on another route traversal")
            if self.zones(box, {"water"}) and t not in ("bridge", "pier"):
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
            hs = [self.ground(s, u) for s in (box[0], box[1]) for u in (box[2], box[3])] if check_ground else []
            if check_ground and t not in ("bridge", "pier"):
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


def append_hints(pkg, hints):
    """Append point hints to a validated P4 package without regenerating existing objects."""
    for need in ("route/route.json", "manifest.json", "semantics/semantics.json", "vegetation/zones.json",
                 "structures/structures.json", "structures/prototypes.json"):
        if not os.path.isfile(os.path.join(pkg, need)):
            raise ValueError(f"append-hints needs {need}")
    route, man, sem = _load(pkg)
    errs = rm.validate(route) + sm.validate(sem, route) + rt.validate(pkg)[0] + vg.validate(pkg)[0]
    if errs:
        raise ValueError("P4 inputs invalid, not appending:")
    p4_path = os.path.join(pkg, "structures", "structures.json")
    proto_path = os.path.join(pkg, "structures", "prototypes.json")
    with open(p4_path) as f:
        p4 = json.load(f)
    with open(proto_path) as f:
        proto_data = json.load(f)
    objs = p4["objects"]
    protos = {p["id"]: {k: v for k, v in p.items() if k != "id"} for p in proto_data["prototypes"]}
    site = Site(pkg, route, man, sem)
    site.linear = [o for o in objs if o["placement"] == "linear"]
    numeric_ids = [int(o["object_id"][2:]) for o in objs if re.fullmatch(r"st\d+", o["object_id"])]
    next_id = max(numeric_ids, default=0) + 1
    skipped = list(p4.get("skipped_hints", []))
    new_skipped = []
    for hint in hints:
        proto = hint.get("prototype")
        if not proto:
            raise ValueError("append-hints requires an explicit reusable prototype for every hint")
        if proto not in protos:
            if proto not in PROTOTYPES:
                raise ValueError(f"unknown prototype {proto}")
            protos[proto] = dict(PROTOTYPES[proto])
        semantic_type = hint["semantic_type"]
        if protos[proto].get("semantic_type") != semantic_type:
            raise ValueError(f"{proto} semantic type does not match {semantic_type}")
        if protos[proto].get("placement") != "point":
            raise ValueError("append-hints only supports point prototypes")
        dims = hint.get("dimensions_m") or protos[proto].get("dimensions_m")
        if not dims or len(dims) != 3:
            raise ValueError(f"{proto} requires three dimensions_m values")
        importance = hint.get("importance", "medium")
        if importance not in IMPORTANCE:
            raise ValueError(f"invalid importance {importance}")
        side = hint.get("side")
        if side not in ("left", "right"):
            raise ValueError("append-hints requires side left or right")
        s0 = float(hint["s"])
        sign = 1.0 if side == "left" else -1.0
        candidates = [0.0] + [d * k for k in range(1, int(SLIDE_M[importance] / 2.5) + 1) for d in (2.5, -2.5)]
        placed = None
        for ds in candidates:
            s = s0 + ds
            lateral = float(hint["lateral_offset_m"]) if "lateral_offset_m" in hint else sign * (
                (site.band(s - dims[0] / 2, s + dims[0] / 2)[0 if sign > 0 else 1]) +
                float(hint.get("edge_offset_m", 1.0)) + dims[2] / 2)
            anchor = {"s": round(s0, 3), "lateral_offset_m": round(lateral, 3)} if importance == "high" else None
            obj = _point(site, f"st{next_id:04d}", semantic_type, proto, importance, s, lateral, dims,
                         float(hint.get("confidence", 0.6)), hint["source"], hint.get("name"), anchor=anchor,
                         attrs=hint.get("attributes"))
            _finish(site, obj)
            overlaps = any(_box_overlap(obj["footprints_route"][0], tuple(b))
                           for old in objs for b in old["footprints_route"])
            if not site.problems(obj) and not overlaps:
                placed = obj
                break
            if importance == "high":
                placed = obj  # Named landmarks keep their exact anchor and let validation report a conflict.
                break
        next_id += 1
        if placed:
            objs.append(placed)
        else:
            record = {"hint": hint, "reason": "; ".join(site.problems(obj)) or "overlaps another structure"}
            skipped.append(record)
            new_skipped.append(record)
    _write(pkg, route, man, objs, protos, skipped)
    return objs, new_skipped


def replace_point_objects(pkg, hints):
    """Replace named point objects at authored route anchors, rebuilding tiles and preserving IDs.

    This is for evidence-backed P4 revisions where an existing landmark identity/location is corrected.
    Placement conflicts remain visible to validate(); this helper never slides or suppresses them.
    Each hint requires object_id, semantic_type, prototype, s, lateral_offset_m, dimensions_m and source.
    """
    with open(os.path.join(pkg, "route", "route.json")) as f: route = json.load(f)
    with open(os.path.join(pkg, "manifest.json")) as f: man = json.load(f)
    with open(os.path.join(pkg, "semantics", "semantics.json")) as f: sem = json.load(f)
    with open(os.path.join(pkg, "structures", "structures.json")) as f: p4 = json.load(f)
    with open(os.path.join(pkg, "structures", "prototypes.json")) as f: proto_data = json.load(f)
    objs = p4["objects"]
    proto_data_by_id = {p["id"]: {k: v for k, v in p.items() if k != "id"} for p in proto_data["prototypes"]}
    site = Site(pkg, route, man, sem)
    site.linear = [o for o in objs if o["placement"] == "linear"]
    seen = set()
    for hint in hints:
        oid = hint["object_id"]
        if oid in seen: raise ValueError(f"duplicate object_id {oid}")
        seen.add(oid)
        index = next((i for i, o in enumerate(objs) if o["object_id"] == oid), None)
        if index is None: raise ValueError(f"unknown structure object_id {oid}")
        if objs[index].get("placement") != "point":
            raise ValueError(f"{oid} is not a point object and cannot be replaced by replace_point_objects")
        proto = hint["prototype"]
        if proto not in PROTOTYPES: raise ValueError(f"unknown prototype {proto}")
        spec = PROTOTYPES[proto]
        if spec["semantic_type"] != hint["semantic_type"] or spec["placement"] != "point":
            raise ValueError(f"incompatible replacement prototype {proto}")
        dims = hint["dimensions_m"]
        if len(dims) != 3: raise ValueError(f"{oid} requires three dimensions_m values")
        s, u = float(hint["s"]), float(hint["lateral_offset_m"])
        obj = _point(site, oid, hint["semantic_type"], proto, hint.get("importance", "high"),
                     s, u, dims, float(hint.get("confidence", 0.6)), hint["source"],
                     hint.get("name"), anchor={"s": round(s, 3), "lateral_offset_m": round(u, 3)},
                     attrs=hint.get("attributes"))
        _finish(site, obj)
        objs[index] = obj
        proto_data_by_id[proto] = dict(spec)
    _write(pkg, route, man, objs, proto_data_by_id, p4.get("skipped_hints", []))
    return objs


def sm_barriers():
    return {"wall", "guardrail", "fence"}


def preserve_package_prototype_assets(generated, previous):
    """Keep existing package asset lineage across a P4 rebuild while adding/updating prototype facts."""
    merged = {key: dict(value) for key, value in generated.items()}
    for old in previous:
        pid = old["id"]
        if pid not in merged:
            merged[pid] = {k: v for k, v in old.items() if k != "id"}
            continue
        for field in ("mesh_file", "source", "asset_parameters"):
            if field in old and field not in merged[pid]:
                merged[pid][field] = old[field]
    return merged


def _write(pkg, route, man, objs, protos, skipped):
    d = os.path.join(pkg, "structures")
    os.makedirs(d, exist_ok=True)
    prototype_path = os.path.join(d, "prototypes.json")
    if os.path.isfile(prototype_path):
        with open(prototype_path) as f:
            previous = json.load(f).get("prototypes", [])
        protos = preserve_package_prototype_assets(protos, previous)
    with open(os.path.join(d, "structures.json"), "w") as f:
        json.dump({"version": VERSION, "route_id": route["route_id"], "objects": objs, "skipped_hints": skipped}, f, indent=1)
    with open(prototype_path, "w") as f:
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
    ground_support = {}
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
            support = o.get("attributes", {}).get("foundation_support")
            strict_support = valid_foundation_support_policy(o, man)
            e += site.problems(check, check_ground=not strict_support)
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
            elif t == "pier":
                attrs = o.get("attributes", {})
                policy = attrs.get("pier_support", {})
                mesh_file = (p or {}).get("mesh_file")
                mesh_path = os.path.join(pkg, mesh_file) if mesh_file else None
                if not policy.get("estimated") or policy.get("deck_y_m") is None or policy.get("water_level_m") is None:
                    e.append("pier lacks estimated deck/water datum metadata")
                elif abs((pos[1] + float(policy["deck_y_m"])) - float(policy["water_level_m"]) - 0.4) > 0.03:
                    e.append("pier deck is not 0.4 m above declared water level")
                if mesh_path and os.path.isfile(mesh_path):
                    try:
                        mesh_local, mesh_indices = gltf_mesh.read(mesh_path)
                        used = [mesh_local[i] for i in sorted(set(mesh_indices))]
                        layout=(p or {}).get("asset_parameters",{}).get("pile_layout_xz_m",[])
                        if len(layout)!=16:
                            e.append("pier prototype must declare 16 actual pile locations")
                        sx=o["dimensions_m"]["width"]/(p or {}).get("dimensions_m",[o["dimensions_m"]["width"]])[0]
                        sz=o["dimensions_m"]["depth"]/(p or {}).get("dimensions_m",[0,0,o["dimensions_m"]["depth"]])[2]
                        bottom=set()
                        half=float((p or {}).get("asset_parameters",{}).get("pile_size_m",0.28))/2
                        for lx0,lz0 in layout:
                            lx0=float(lx0)*sx; lz0=float(lz0)*sz
                            for dx,dz in ((-half,-half),(half,-half),(half,half),(-half,half)):
                                cx=lx0+dx*sx; cz=lz0+dz*sz
                                vertices=[v for v in used if abs(v[0]-cx)<=.002 and abs(v[2]-cz)<=.002]
                                if not vertices:
                                    e.append(f"pier mesh lacks pile base corner at ({cx:.2f},{cz:.2f})")
                                    continue
                                low_y=min(v[1] for v in vertices)
                                bottom.add((round(cx,4),round(low_y,4),round(cz,4)))
                        qx, qy, qz, qw = o["transform"]["rotation"]
                        px, py, pz = pos
                        results=[]
                        for lx,ly,lz in sorted(bottom):
                            tx=2*(qy*lz-qz*ly); ty=2*(qz*lx-qx*lz); tz=2*(qx*ly-qy*lx)
                            x=px+lx+qw*tx+qy*tz-qz*ty
                            y=py+ly+qw*ty+qz*tx-qx*tz
                            z=pz+lz+qw*tz+qx*ty-qy*tx
                            # Resolve the physical owner by nearest route station, then test every
                            # terrain triangle in the runtime's actual s-window (back 350 / ahead 800 m).
                            lo=max(0.0,o["s"]-o["dimensions_m"]["width"]/2-5.0)
                            hi=min(total,o["s"]+o["dimensions_m"]["width"]/2+5.0)
                            best=(float("inf"),o["s"])
                            station_step=0.2
                            for step in range(max(1,math.ceil((hi-lo)/station_step))+1):
                                station=min(hi,lo+step*station_step)
                                rp=rm.sample(route,station)
                                dist=math.hypot(rp["x"]-x,rp["z"]-z)
                                if dist<best[0]:best=(dist,station)
                            station=best[1]; rp=rm.sample(route,station); _,left=_vec(rp["heading_deg"])
                            lateral=(x-rp["x"])*left[0]+(z-rp["z"])*left[1]
                            ground=site.ground(station,lateral)
                            # Same station window as PackagePreview: [progress-350, progress+800].
                            window=[]
                            for bucket in range(math.floor(max(0.0,o["s"]-350.0)/2),math.floor(min(total,o["s"]+800.0)/2)+1):
                                for box,tri in site.space.ground_triangles.get(bucket,()):
                                    if box[0]-1e-5<=x<=box[1]+1e-5 and box[2]-1e-5<=z<=box[3]+1e-5:
                                        hit=vg._bary_y(tri,x,z)
                                        if hit is not None:window.append(hit)
                            active_high=max(window) if window else None
                            results.append({"x_m":round(x,3),"y_m":round(y,3),"z_m":round(z,3),
                                            "owner_s_m":round(station,3),"owner_u_m":round(lateral,3),
                                            "owner_ground_y_m":round(ground,4) if ground is not None else None,
                                            "owner_base_minus_ground_m":round(y-ground,4) if ground is not None else None,
                                            "loaded_window_hit_count":len(window),"loaded_window_max_y_m":round(active_high,4) if active_high is not None else None,
                                            "loaded_window_base_minus_max_m":round(y-active_high,4) if active_high is not None else None})
                        support_ok=bool(results) and all(r["owner_ground_y_m"] is not None and abs(r["owner_base_minus_ground_m"]) <= 0.05
                            and r["loaded_window_max_y_m"] is not None and abs(r["loaded_window_base_minus_max_m"])<=0.05 for r in results)
                        ground_support[oid]={"policy":"actual_mesh_lowest_vertices_are_piles",
                                             "sample_count":len(results),"hit_count":sum(r["owner_ground_y_m"] is not None for r in results),
                                             "owner_policy":"nearest route station + runtime streaming s window [-350,+800] m",
                                             "max_abs_ground_error_m":round(max((abs(r["owner_base_minus_ground_m"]) for r in results if r["owner_base_minus_ground_m"] is not None),default=0),4),
                                             "samples":results}
                        if not support_ok:e.append("actual pile bottom vertices are not supported by P1 within 0.05 m")
                    except gltf_mesh.GltfMeshError as exc:
                        e.append(f"pier support mesh cannot be used: {exc}")
                else:
                    e.append(f"pier prototype mesh {mesh_file} is missing")
            elif t in BUILDING:
                samples = point_world_base_samples(o)
                mesh_file = (p or {}).get("mesh_file")
                mesh_path = os.path.join(pkg, mesh_file) if mesh_file else None
                if mesh_path and not os.path.isfile(mesh_path):
                    e.append(f"prototype mesh {mesh_file} is missing")
                if mesh_path and os.path.isfile(mesh_path):
                    try:
                        mesh_local, mesh_indices = gltf_mesh.read(mesh_path)
                        used_vertices = [mesh_local[i] for i in sorted(set(mesh_indices))]
                        samples = point_world_mesh_support_samples(
                            dict(o, prototype_dimensions_m=(p or {}).get("dimensions_m")), used_vertices)
                    except gltf_mesh.GltfMeshError as exc:
                        e.append(f"prototype mesh {mesh_file} cannot be used for support validation: {exc}")
                hits = []
                missing = []
                sample_results = []
                for index, sample in enumerate(samples):
                    ground = site.space.ground_world(sample["x"], sample["z"])
                    if ground is None:
                        missing.append(index)
                        sample_results.append({"index": index, "x_m": round(sample["x"], 3),
                                               "base_y_m": round(sample["y"], 3), "z_m": round(sample["z"], 3),
                                               "ground_y_m": None, "signed_base_minus_ground_m": None})
                    else:
                        signed = sample["y"] - ground  # positive is a gap; negative is penetration
                        hits.append((index, ground, signed))
                        sample_results.append({"index": index, "x_m": round(sample["x"], 3),
                                               "base_y_m": round(sample["y"], 3), "z_m": round(sample["z"], 3),
                                               "ground_y_m": round(ground, 4),
                                               "signed_base_minus_ground_m": round(signed, 4)})
                errors = [abs(signed) for _, _, signed in hits]
                penetration = max([max(0.0, -signed) for _, _, signed in hits] or [0.0])
                gap = max([max(0.0, signed) for _, _, signed in hits] or [0.0])
                max_error = max(errors) if errors else None
                attrs = o.get("attributes", {})
                support = attrs.get("foundation_support")
                support_claimed = support is not None
                support = support if isinstance(support, dict) else {}
                if support_claimed and not strict_support:
                    e.append("foundation support policy is invalid; using the 0.05 m base-to-minimum-ground limit")
                gap_limit = min(0.05, support.get("max_gap_m", 0.05)) if strict_support else 0.05
                penetration_limit = min(0.02, support.get("max_penetration_m", 0.02)) if strict_support else 0.02
                ground_support[oid] = {
                    "sample_count": len(samples), "hit_count": len(hits), "missing_count": len(missing),
                    "missing_points": missing,
                    "sample_kind": "prototype_lowest_vertices_and_footprint_grid" if mesh_path and os.path.isfile(mesh_path) else "footprint_grid",
                    "max_ground_y_m": round(max((g for _, g, _ in hits), default=float("nan")), 4) if hits else None,
                    "min_ground_y_m": round(min((g for _, g, _ in hits), default=float("nan")), 4) if hits else None,
                    "max_abs_ground_error_m": round(max_error, 4) if max_error is not None else None,
                    "max_penetration_m": round(penetration, 4), "max_gap_m": round(gap, 4),
                    "gap_limit_m": gap_limit, "penetration_limit_m": penetration_limit,
                    "policy": support.get("kind", "legacy_foundation_drop") if strict_support else "diagnostic_only_legacy_foundation_drop",
                    "samples": sample_results if strict_support or o["importance"] == "high" else [],
                }
                if max_error is not None:
                    worst["ground_m"] = max(worst["ground_m"], max_error)
                if not strict_support:
                    # Preserve the established package contract for ordinary buildings:
                    # their rigid base anchor remains within 5 cm of the lowest route-relative corner.
                    legacy_hs=[site.ground(s,u) for s in (boxes[0][0],boxes[0][1]) for u in (boxes[0][2],boxes[0][3])]
                    available=[h for h in legacy_hs if h is not None]
                    if available:
                        base_delta=pos[1]-min(available)
                        worst["ground_m"]=max(worst["ground_m"],abs(base_delta))
                        if abs(base_delta)>0.05:
                            e.append(f"base {base_delta:.2f} m off the terrain")
                if missing and (strict_support or o["importance"] == "high"):
                    e.append(f"actual rigid base has {len(missing)}/{len(samples)} missing terrain samples {missing}")
                if strict_support and hits and penetration > penetration_limit:
                    e.append(f"actual rigid base penetrates highest terrain by {penetration:.3f} m (limit {penetration_limit:.3f})")
                if strict_support and hits and gap > gap_limit:
                    e.append(f"actual rigid base has {gap:.3f} m unsupported gap (limit {gap_limit:.3f})")
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
              "ground_support": ground_support,
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
    if len(args) == 2 and args[0] == "append-hints":
        if "hints" not in opts:
            raise ValueError("append-hints requires --hints=file.json")
        with open(opts["hints"]) as f:
            hints = json.load(f)
        objs, skipped = append_hints(args[1], hints)
        print(f"{args[1]}: {len(objs)} objects, {len(skipped)} skipped hints")
        for item in skipped:
            print(f"  skipped {item['hint'].get('name', item['hint']['prototype'])}: {item['reason']}")
        args = ["validate", args[1]]
    if len(args) == 2 and args[0] == "replace-point-objects":
        if "hints" not in opts:
            raise ValueError("replace-point-objects requires --hints=file.json")
        with open(opts["hints"]) as f: hints = json.load(f)
        objs = replace_point_objects(args[1], hints)
        print(f"{args[1]}: replaced {len(hints)} existing point objects; IDs preserved")
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
