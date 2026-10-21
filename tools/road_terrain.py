#!/usr/bin/env python3
"""Road + terrain stage of the AI Scene Package: route.json -> distance tiles of road.glb / terrain.glb. Stdlib only.

  python3 tools/road_terrain.py build <package_dir> [--tile-m=500] [--hill-amplitude-m=18] [--seed=7]
  python3 tools/road_terrain.py validate <package_dir>

Order: route centreline -> boundaries (width_left_m / width_right_m) -> road surface -> terrain outward from the edges.
PHYSICAL ROUTE (route.json: s, elevation, grade) is never touched by VISUAL TERRAIN (hills, noise, exaggeration):
road vertices are the route samples plus lateral offsets at the route's height; terrain starts exactly on the road
edge and only its relief beyond the edge is procedural. Format: docs/ROAD_TERRAIN.md.
"""
import array
import bisect
import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import route_model as rm  # noqa: E402

# PBR intent per surface_type (base colour linear RGB, roughness); runtimes substitute their own materials by name
SURFACE_MATERIALS = {
    "asphalt": ((0.18, 0.18, 0.18), 0.9), "concrete": ((0.55, 0.55, 0.52), 0.85),
    "cobblestone": ((0.40, 0.38, 0.35), 0.9), "gravel": ((0.55, 0.50, 0.42), 0.95), "dirt": ((0.42, 0.33, 0.24), 0.95),
    "grass": ((0.30, 0.45, 0.18), 0.95), "boardwalk": ((0.50, 0.38, 0.25), 0.8), "sand": ((0.76, 0.70, 0.50), 0.95),
    "snow": ((0.92, 0.94, 0.96), 0.6), "ice": ((0.80, 0.88, 0.95), 0.1), "unknown": ((1.0, 0.0, 1.0), 1.0),
}
TERRAIN_MATERIAL = {"name": "terrain_ground", "color": [0.30, 0.42, 0.20], "roughness": 0.95}
DEFAULT_TERRAIN = {
    "columns_m": [0.0, 0.6, 2.0, 5.0, 10.0, 20.0, 35.0, 60.0, 100.0, 150.0],  # beyond each road edge
    "shoulder_drop_m": 0.05,       # verge sits this much below the road edge (drainage), from 0 to 0.6 m out
    "flat_band_m": 3.0,            # no relief this close to the road edge ...
    "blend_to_m": 60.0,            # ... full relief from here out
    "hill_amplitude_m": 18.0,
    "hill_wavelength_m": 320.0,
    "vertical_exaggeration": 1.0,  # multiplies the relief only (route.json visual.vertical_exaggeration by default)
    "seed": 7,
    "max_inner_reach_of_radius": 0.7,  # inside of a bend: terrain reaches at most this fraction of the radius (no folds)
}
TOL = {"position": 0.01, "elevation": 0.01, "width": 0.01, "slope_pp": 0.5, "seam": 0.001, "probe": 0.01}


# ------------------------------------------------------------------ GLB (one node, one mesh, primitives share attributes)
def write_glb(path, mesh):
    """mesh = {name, translation [x,y,z], attributes {POSITION, NORMAL: [(x,y,z)], TEXCOORD_0: [(u,v)],
    _ROUTE_S, _ROUTE_U: [float]}, primitives [{material {name, color, roughness}, indices [int]}]}"""
    blob, views, accessors = bytearray(), [], []

    def add(values, comps, ctype, target, minmax=False):
        flat = [c for v in values for c in v] if comps > 1 else list(values)
        arr = array.array("f" if ctype == 5126 else "I", flat)
        if sys.byteorder != "little":
            arr.byteswap()
        while len(blob) % 4:
            blob.append(0)
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(arr) * 4, "target": target})
        blob.extend(arr.tobytes())
        acc = {"bufferView": len(views) - 1, "componentType": ctype, "count": len(values),
               "type": {1: "SCALAR", 2: "VEC2", 3: "VEC3"}[comps]}
        if minmax:
            acc["min"] = [min(arr[i::comps]) for i in range(comps)]
            acc["max"] = [max(arr[i::comps]) for i in range(comps)]
        accessors.append(acc)
        return len(accessors) - 1

    attrs = {}
    for k, v in mesh["attributes"].items():
        comps = len(v[0]) if isinstance(v[0], (tuple, list)) else 1
        attrs[k] = add(v, comps, 5126, 34962, minmax=(k == "POSITION"))
    materials, prims = [], []
    for p in mesh["primitives"]:
        m = p["material"]
        materials.append({"name": m["name"], "pbrMetallicRoughness": {
            "baseColorFactor": list(m["color"]) + [1.0], "metallicFactor": 0.0, "roughnessFactor": m["roughness"]}})
        if mesh.get("texture"):  # one embedded base-colour image (e.g. an orthophoto) for every material
            materials[-1]["pbrMetallicRoughness"]["baseColorTexture"] = {"index": 0}
        prims.append({"attributes": attrs, "indices": add(p["indices"], 1, 5125, 34963), "material": len(materials) - 1})
    gltf = {"asset": {"version": "2.0", "generator": "ai_scene tools/road_terrain.py"}, "scene": 0,
            "scenes": [{"nodes": [0]}], "nodes": [{"name": mesh["name"], "mesh": 0, "translation": mesh["translation"]}],
            "meshes": [{"name": mesh["name"], "primitives": prims}], "materials": materials,
            "accessors": accessors, "bufferViews": views, "buffers": [{"byteLength": len(blob)}]}
    if mesh.get("texture"):
        tex = mesh["texture"]
        while len(blob) % 4:
            blob.append(0)
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(tex["bytes"])})
        blob.extend(tex["bytes"])
        gltf.update(images=[{"bufferView": len(views) - 1, "mimeType": tex["mime"]}], textures=[{"source": 0, "sampler": 0}],
                    samplers=[{"magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071}])
        gltf["buffers"][0]["byteLength"] = len(blob)
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    blob += b"\0" * (-len(blob) % 4)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob)))
        f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        f.write(struct.pack("<II", len(blob), 0x004E4942) + bytes(blob))


def read_glb(path):
    """Inverse of write_glb (for files it wrote)."""
    with open(path, "rb") as f:
        data = f.read()
    magic, _, _ = struct.unpack_from("<III", data, 0)
    assert magic == 0x46546C67, f"{path}: not a GLB"
    jlen, _ = struct.unpack_from("<II", data, 12)
    gltf = json.loads(data[20:20 + jlen])
    bin0 = 20 + jlen + 8

    def get(i):
        acc = gltf["accessors"][i]
        view = gltf["bufferViews"][acc["bufferView"]]
        comps = {"SCALAR": 1, "VEC2": 2, "VEC3": 3}[acc["type"]]
        arr = array.array("f" if acc["componentType"] == 5126 else "I")
        arr.frombytes(data[bin0 + view["byteOffset"]: bin0 + view["byteOffset"] + acc["count"] * comps * 4])
        if sys.byteorder != "little":
            arr.byteswap()
        return list(arr) if comps == 1 else [tuple(arr[k:k + comps]) for k in range(0, len(arr), comps)]

    node = gltf["nodes"][0]
    prims = gltf["meshes"][0]["primitives"]
    out = {"name": node["name"], "translation": node.get("translation", [0, 0, 0]), "images": len(gltf.get("images", [])),
           "attributes": {k: get(i) for k, i in prims[0]["attributes"].items()}, "primitives": []}
    for p in prims:
        m = gltf["materials"][p["material"]]
        pbr = m["pbrMetallicRoughness"]
        out["primitives"].append({"material": {"name": m["name"], "color": pbr["baseColorFactor"][:3],
                                               "roughness": pbr["roughnessFactor"]}, "indices": get(p["indices"])})
    return out


# ------------------------------------------------------------------ geometry
def _hash(ix, iz, seed):
    h = (ix * 374761393 + iz * 668265263 + seed * 1442695041) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFFFF) / 0xFFFFFF * 2.0 - 1.0


def value_noise(x, z, seed):
    ix, iz = math.floor(x), math.floor(z)
    fx, fz = x - ix, z - iz
    fx, fz = fx * fx * (3 - 2 * fx), fz * fz * (3 - 2 * fz)
    a = _hash(ix, iz, seed) + (_hash(ix + 1, iz, seed) - _hash(ix, iz, seed)) * fx
    b = _hash(ix, iz + 1, seed) + (_hash(ix + 1, iz + 1, seed) - _hash(ix, iz + 1, seed)) * fx
    return a + (b - a) * fz


def smoothstep(a, b, v):
    t = min(max((v - a) / (b - a), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def relief(x, z, tp):
    """Visual terrain height above the road-edge level at world (x, z), before the distance blend."""
    w = tp["hill_wavelength_m"]
    n = value_noise(x / w, z / w, tp["seed"]) + 0.35 * value_noise(x / (w * 0.37), z / (w * 0.37), tp["seed"] + 1)
    return tp["hill_amplitude_m"] * tp["vertical_exaggeration"] * n


def _normals(pos, idx):
    acc = [[0.0, 0.0, 0.0] for _ in pos]
    for t in range(0, len(idx), 3):
        a, b, c = (pos[idx[t + k]] for k in range(3))
        u = [b[k] - a[k] for k in range(3)]
        v = [c[k] - a[k] for k in range(3)]
        n = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
        for k in range(3):
            for j in range(3):
                acc[idx[t + k]][j] += n[j]
    out = []
    for n in acc:
        ln = math.sqrt(n[0] ** 2 + n[1] ** 2 + n[2] ** 2) or 1.0
        out.append((n[0] / ln, n[1] / ln, n[2] / ln))
    return out


def _grid_indices(rows, cols, base=0, keep=None):
    """Two triangles per cell of a rows x cols grid whose columns increase to the LEFT of travel: front faces up."""
    out = []
    for r in range(rows - 1):
        if keep is not None and not keep(r):
            continue
        for c in range(cols - 1):
            a, b = base + r * cols + c, base + (r + 1) * cols + c
            out += [a, b, a + 1, b, b + 1, a + 1]
    return out


def _cross_section(smp, i, us, heights):
    """World vertices of row i at lateral offsets us (left +), heights per offset."""
    lx, lz = rm.left_vector(smp["heading_deg"][i])
    return [(smp["x"][i] + lx * u, h, smp["z"][i] + lz * u) for u, h in zip(us, heights)]


def tile_edges(s, tile_m):
    """Tile boundaries snapped to sample distances; a short last tile (< 1/4) joins the previous one."""
    edges = [0]
    k = 1
    while k * tile_m < s[-1] - 0.25 * tile_m:
        i = bisect.bisect_left(s, k * tile_m)
        if i > 0 and k * tile_m - s[i - 1] < s[i] - k * tile_m:
            i -= 1
        if edges[-1] < i < len(s) - 1:
            edges.append(i)
        k += 1
    edges.append(len(s) - 1)
    return edges


def build(pkg, tile_m=500.0, terrain=None):
    route_path = os.path.join(pkg, "route", "route.json")
    with open(route_path) as f:
        route = json.load(f)
    errs = rm.validate(route)
    if errs:
        raise ValueError("route.json is invalid, not building geometry:\n  " + "\n  ".join(errs))
    tp = dict(DEFAULT_TERRAIN, vertical_exaggeration=route.get("visual", {}).get("vertical_exaggeration", 1.0))
    tp.update(terrain or {})
    smp = route["samples"]
    s, n = smp["s"], len(smp["s"])
    D = tp["columns_m"]
    # inside of bends: limit the terrain reach so offset rows never cross (curvature window ~ the terrain extent)
    win = max(1, int(D[-1] / route["sample_interval_m"]))
    kl = [max(0.0, max(smp["curvature"][max(0, i - win): i + win + 1])) for i in range(n)]   # left turns: left is inside
    kr = [max(0.0, -min(smp["curvature"][max(0, i - win): i + win + 1])) for i in range(n)]

    def reach(k, w):
        if k <= 0.0:
            return 1.0
        return min(1.0, max(tp["max_inner_reach_of_radius"] / k - w, D[1]) / D[-1])

    edges = tile_edges(s, tile_m)
    tiles = []
    os.makedirs(os.path.join(pkg, "tiles"), exist_ok=True)
    for t in range(len(edges) - 1):
        i0, i1 = edges[t], edges[t + 1]
        rows = list(range(i0, i1 + 1))
        tid = "%02d" % t
        tdir = os.path.join(pkg, "tiles", tid)
        os.makedirs(tdir, exist_ok=True)
        origin = [round(smp["x"][i0]), round(smp["y"][i0]), round(smp["z"][i0])]
        # --- road: 3 columns (right edge, centre, left edge) at the route's height: flat across, grade along
        rpos, rs, ru, ruv = [], [], [], []
        for i in rows:
            us = [-smp["width_right_m"][i], 0.0, smp["width_left_m"][i]]
            for u, p in zip(us, _cross_section(smp, i, us, [smp["y"][i]] * 3)):
                rpos.append(p)
                rs.append(s[i])
                ru.append(u)
                ruv.append((u, s[i]))
        prims = []
        for st in sorted({smp["surface_type"][i] for i in rows[:-1]}):
            col, rough = SURFACE_MATERIALS[st]
            idx = _grid_indices(len(rows), 3, keep=lambda r, st=st: smp["surface_type"][rows[r]] == st)
            prims.append({"material": {"name": "road_" + st, "color": col, "roughness": rough}, "indices": idx})
        all_idx = [k for p in prims for k in p["indices"]]
        road = {"name": "road_" + tid, "translation": origin, "primitives": prims,
                "attributes": {"POSITION": [(p[0] - origin[0], p[1] - origin[1], p[2] - origin[2]) for p in rpos],
                               "NORMAL": _normals(rpos, all_idx), "TEXCOORD_0": ruv, "_ROUTE_S": rs, "_ROUTE_U": ru}}
        # --- terrain: one grid per side, columns from the road edge outward, edge vertex == road edge vertex
        tpos, ts, tu, tidx = [], [], [], []
        for side in (-1, 1):
            base = len(tpos)
            for i in rows:
                w = smp["width_left_m"][i] if side > 0 else smp["width_right_m"][i]
                sc = reach(kl[i] if side > 0 else kr[i], w)
                ds = D if side > 0 else D[::-1]  # columns ordered by increasing u
                us = [side * (w + d * sc) for d in ds]
                lx, lz = rm.left_vector(smp["heading_deg"][i])
                hs = []
                for u, d in zip(us, ds):
                    x, z = smp["x"][i] + lx * u, smp["z"][i] + lz * u
                    dd = d * sc
                    hs.append(smp["y"][i] - tp["shoulder_drop_m"] * smoothstep(0.0, D[1], dd)
                              + relief(x, z, tp) * smoothstep(tp["flat_band_m"], tp["blend_to_m"], dd))
                for u, p in zip(us, _cross_section(smp, i, us, hs)):
                    tpos.append(p)
                    ts.append(s[i])
                    tu.append(u)
            tidx += _grid_indices(len(rows), len(D), base)
        terr = {"name": "terrain_" + tid, "translation": origin,
                "primitives": [{"material": TERRAIN_MATERIAL, "indices": tidx}],
                "attributes": {"POSITION": [(p[0] - origin[0], p[1] - origin[1], p[2] - origin[2]) for p in tpos],
                               "NORMAL": _normals(tpos, tidx), "TEXCOORD_0": [(p[0], p[2]) for p in tpos],
                               "_ROUTE_S": ts, "_ROUTE_U": tu}}
        write_glb(os.path.join(tdir, "road.glb"), road)
        write_glb(os.path.join(tdir, "terrain.glb"), terr)
        allp = rpos + tpos
        ranges = []
        for i in rows[:-1]:
            st = smp["surface_type"][i]
            if ranges and ranges[-1]["surface_type"] == st:
                ranges[-1]["to_s"] = s[i + 1]
            else:
                ranges.append({"surface_type": st, "from_s": s[i], "to_s": s[i + 1]})
        tiles.append({
            "id": tid, "from_s": s[i0], "to_s": s[i1],
            "bounds": {"min": [round(min(p[k] for p in allp), 3) for k in range(3)],
                       "max": [round(max(p[k] for p in allp), 3) for k in range(3)]},
            "origin": origin,
            "files": {"road": f"tiles/{tid}/road.glb", "terrain": f"tiles/{tid}/terrain.glb"},
            "road": {"surfaces": ranges,
                     "width_left_m": [min(smp["width_left_m"][i] for i in rows), max(smp["width_left_m"][i] for i in rows)],
                     "width_right_m": [min(smp["width_right_m"][i] for i in rows), max(smp["width_right_m"][i] for i in rows)],
                     "grade_percent": [min(smp["grade_percent"][i] for i in rows), max(smp["grade_percent"][i] for i in rows)],
                     "rows": len(rows)},
        })
    manifest = {
        "schema_version": "0.1", "package_id": route["route_id"], "route": "route/route.json",
        "total_length_m": route["total_length_m"], "tile_m": tile_m,
        "layers": {"P0_route": {"status": "complete", "files": ["route/route.json", "tiles/*/road.glb"]},
                   "P1_terrain": {"status": "procedural", "files": ["tiles/*/terrain.glb"]},
                   "P2_corridor": {"status": "absent"}, "P3_vegetation": {"status": "absent"},
                   "P4_structures": {"status": "absent"}, "P5_distant": {"status": "absent"},
                   "P6_atmosphere": {"status": "absent"}},
        "physical_route": {"source": "route/route.json", "note": "road meshes reproduce it exactly; gameplay reads route.json"},
        "visual_terrain": tp,
        "vertex_attributes": {"_ROUTE_S": "route distance s of the vertex row (m)",
                              "_ROUTE_U": "lateral offset from the centreline (m, + left)",
                              "TEXCOORD_0": "road: (u, s) metres; terrain: world (x, z) metres"},
        "tiles": tiles,
    }
    with open(os.path.join(pkg, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    return manifest


# ------------------------------------------------------------------ validation
def _tris(mesh):
    return [k for p in mesh["primitives"] for k in p["indices"]]


def _world(mesh):
    o = mesh["translation"]
    return [(p[0] + o[0], p[1] + o[1], p[2] + o[2]) for p in mesh["attributes"]["POSITION"]]


def _face_up(pos, idx):
    bad = 0
    for t in range(0, len(idx), 3):
        a, b, c = pos[idx[t]], pos[idx[t + 1]], pos[idx[t + 2]]
        ny = (b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2])
        bad += ny <= 0.0
    return bad


def road_height_at(mesh, pos, x, z, s_hint):
    """Height of the road surface under (x, z), from the triangles near s_hint (player positioning / collision probe)."""
    rs = mesh["attributes"]["_ROUTE_S"]
    idx = _tris(mesh)
    for t in range(0, len(idx), 3):
        tri = idx[t:t + 3]
        if min(abs(rs[k] - s_hint) for k in tri) > 3.0:
            continue
        (ax, ay, az), (bx, by, bz), (cx, cy, cz) = (pos[k] for k in tri)
        det = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
        if abs(det) < 1e-12:
            continue
        l1 = ((bz - cz) * (x - cx) + (cx - bx) * (z - cz)) / det
        l2 = ((cz - az) * (x - cx) + (ax - cx) * (z - cz)) / det
        l3 = 1.0 - l1 - l2
        if min(l1, l2, l3) >= -1e-4:  # float32 vertices: points on a shared edge / boundary row
            return l1 * ay + l2 * by + l3 * cy
    return None


def height_on_road(tiles, meshes, x, z, s_hint):
    """road_height_at over every loaded tile that covers s_hint (a boundary row belongs to two tiles)."""
    for t in tiles:
        if t["id"] in meshes and t["from_s"] - 3.0 <= s_hint <= t["to_s"] + 3.0:
            y = road_height_at(meshes[t["id"]][0], meshes[t["id"]][1], x, z, s_hint)
            if y is not None:
                return y
    return None


def validate(pkg):
    """(errors, report). Also writes <pkg>/validation.json."""
    with open(os.path.join(pkg, "route", "route.json")) as f:
        route = json.load(f)
    with open(os.path.join(pkg, "manifest.json")) as f:
        man = json.load(f)
    errs = ["route: " + e for e in rm.validate(route)]
    smp = route["samples"]
    s = smp["s"]
    total = route["total_length_m"]
    tiles = man["tiles"]
    # coverage: tiles tile [0, total] without gaps or overlaps
    if not tiles or abs(tiles[0]["from_s"]) > 1e-6 or abs(tiles[-1]["to_s"] - total) > 1e-6:
        errs.append("tiles do not cover 0 .. total_length_m")
    for a, b in zip(tiles, tiles[1:]):
        if abs(a["to_s"] - b["from_s"]) > 1e-6:
            errs.append(f"road gap/overlap between tiles {a['id']} ({a['to_s']}) and {b['id']} ({b['from_s']})")
    report = {"tiles": [], "seams": [], "probes": []}
    meshes = {}
    for tile in tiles:
        te = []
        paths = {k: os.path.join(pkg, v) for k, v in tile["files"].items()}
        missing = [k for k, p in paths.items() if not os.path.isfile(p)]
        if missing:
            errs.append(f"tile {tile['id']}: missing {missing}")
            continue
        road, terr = read_glb(paths["road"]), read_glb(paths["terrain"])
        rp, tpw = _world(road), _world(terr)
        meshes[tile["id"]] = (road, rp, terr, tpw)
        rs, ru = road["attributes"]["_ROUTE_S"], road["attributes"]["_ROUTE_U"]
        lo, hi = bisect.bisect_left(s, tile["from_s"] - 1e-6), bisect.bisect_right(s, tile["to_s"] + 1e-6)
        rows = {}
        for k, sv in enumerate(rs):
            rows.setdefault(round(sv, 2), []).append(k)
        missing_rows = [s[i] for i in range(lo, hi) if round(s[i], 2) not in rows]
        if missing_rows:
            te.append(f"road rows missing at s={missing_rows[:3]} ({len(missing_rows)})")
        tri_rows = {}
        idx = _tris(road)
        for t in range(0, len(idx), 3):
            key = round(min(rs[k] for k in idx[t:t + 3]), 2)
            tri_rows[key] = tri_rows.get(key, 0) + 1
        holes = [s[i] for i in range(lo, hi - 1) if tri_rows.get(round(s[i], 2), 0) < 4]
        if holes:
            te.append(f"road surface gap between rows at s={holes[:3]} ({len(holes)})")
        worst = {"position": 0.0, "elevation": 0.0, "width": 0.0, "slope_pp": 0.0}
        for i in range(lo, hi):
            ks = rows.get(round(s[i], 2), [])
            if not ks:
                continue
            lx, lz = rm.left_vector(smp["heading_deg"][i])
            for k in ks:
                p = rp[k]
                ex, ez = smp["x"][i] + lx * ru[k], smp["z"][i] + lz * ru[k]
                worst["position"] = max(worst["position"], math.hypot(p[0] - ex, p[2] - ez))
                worst["elevation"] = max(worst["elevation"], abs(p[1] - smp["y"][i]))
            us = [ru[k] for k in ks]
            worst["width"] = max(worst["width"], abs(max(us) - smp["width_left_m"][i]), abs(-min(us) - smp["width_right_m"][i]))
            if i + 1 < hi and rows.get(round(s[i + 1], 2)):
                a = rp[min(ks, key=lambda k: abs(ru[k]))]
                b = rp[min(rows[round(s[i + 1], 2)], key=lambda k: abs(ru[k]))]
                slope = (b[1] - a[1]) / math.hypot(b[0] - a[0], b[2] - a[2]) * 100.0
                worst["slope_pp"] = max(worst["slope_pp"], abs(slope - 0.5 * (smp["grade_percent"][i] + smp["grade_percent"][i + 1])))
        for k, v in worst.items():
            if v > TOL[k]:
                te.append(f"road {k} differs from route.json by {v:.4f} (tolerance {TOL[k]})")
        flipped = _face_up(rp, idx)
        if flipped:
            te.append(f"{flipped} road triangles face down")
        # terrain: starts on the road edge, never inside the road band, no folds
        ts, tu = terr["attributes"]["_ROUTE_S"], terr["attributes"]["_ROUTE_U"]
        edge_err, inside = 0.0, 0
        for k, (sv, u) in enumerate(zip(ts, tu)):
            i = bisect.bisect_left(s, sv - 1e-3)
            w = smp["width_left_m"][i] if u > 0 else smp["width_right_m"][i]
            if abs(abs(u) - w) < 1e-3:
                edge_err = max(edge_err, abs(tpw[k][1] - smp["y"][i]))
            elif abs(u) < w:
                inside += 1
        if edge_err > TOL["elevation"]:
            te.append(f"terrain does not meet the road edge (off by {edge_err:.4f} m)")
        if inside:
            te.append(f"{inside} terrain vertices inside the road band")
        folds = _face_up(tpw, _tris(terr))
        if folds:
            te.append(f"{folds} terrain triangles folded / facing down")
        b0, b1 = tile["bounds"]["min"], tile["bounds"]["max"]
        if any(p[k] < b0[k] - 1e-3 or p[k] > b1[k] + 1e-3 for p in rp + tpw for k in range(3)):
            te.append("geometry outside the recorded bounding box")
        errs += [f"tile {tile['id']}: {e}" for e in te]
        report["tiles"].append({"id": tile["id"], "from_s": tile["from_s"], "to_s": tile["to_s"],
                                "max_error": {k: round(v, 5) for k, v in worst.items()},
                                "terrain_edge_error_m": round(edge_err, 5), "ok": not te})
    # seams: the shared boundary row is identical in both neighbours (road and terrain)
    for a, b in zip(tiles, tiles[1:]):
        if a["id"] not in meshes or b["id"] not in meshes:
            continue
        worst = 0.0
        for m in (0, 2):  # road, terrain
            ma, pa = meshes[a["id"]][m], meshes[a["id"]][m + 1]
            mb, pb = meshes[b["id"]][m], meshes[b["id"]][m + 1]
            ea = sorted(((u, p) for u, sv, p in zip(ma["attributes"]["_ROUTE_U"], ma["attributes"]["_ROUTE_S"], pa)
                         if abs(sv - a["to_s"]) < 1e-3), key=lambda e: e[0])
            eb = sorted(((u, p) for u, sv, p in zip(mb["attributes"]["_ROUTE_U"], mb["attributes"]["_ROUTE_S"], pb)
                         if abs(sv - b["from_s"]) < 1e-3), key=lambda e: e[0])
            if len(ea) != len(eb) or not ea:
                errs.append(f"seam {a['id']}|{b['id']}: boundary rows differ ({len(ea)} vs {len(eb)} vertices)")
                worst = math.inf
                continue
            worst = max([worst] + [max(abs(p[k] - q[k]) for k in range(3)) for (_, p), (_, q) in zip(ea, eb)])
        if worst > TOL["seam"]:
            errs.append(f"seam {a['id']}|{b['id']}: mesh discontinuity {worst:.4f} m")
        report["seams"].append({"tiles": [a["id"], b["id"]], "s": a["to_s"], "max_gap_m": round(worst, 6)})
    # probes: start, middle, end - stand on the road mesh where route.json says, at several lateral offsets
    mid = total / 2.0
    for label, spots in [("start", [0.0, route["start"]["s"]]), ("middle", [mid]),
                         ("end", [route["finish"]["s"], total])]:
        for sv in spots:
            p = rm.sample(route, sv)
            lx, lz = rm.left_vector(p["heading_deg"])
            for frac in (-0.8, 0.0, 0.8):
                u = frac * (p["width_left_m"] if frac > 0 else p["width_right_m"])
                y = height_on_road(tiles, meshes, p["x"] + lx * u, p["z"] + lz * u, sv)
                ok = y is not None and abs(y - p["y"]) <= TOL["probe"]
                report["probes"].append({"section": label, "s": sv, "u": round(u, 3), "route_y": round(p["y"], 4),
                                         "road_y": None if y is None else round(y, 4), "ok": ok})
                if not ok:
                    errs.append(f"probe {label} s={sv} u={u:.2f}: road height {y} vs route {p['y']:.4f}")
            # slope over 5 m on the mesh vs route grade
            s2 = sv + 5.0 if sv + 5.0 <= total else sv - 5.0
            q = rm.sample(route, s2)
            y1 = height_on_road(tiles, meshes, p["x"], p["z"], sv)
            y2 = height_on_road(tiles, meshes, q["x"], q["z"], s2)
            if y1 is not None and y2 is not None:
                mesh_grade = (y2 - y1) / (s2 - sv) * 100.0
                i0, i1 = sorted((bisect.bisect_left(s, min(sv, s2)), bisect.bisect_right(s, max(sv, s2))))
                g = smp["grade_percent"][i0:max(i1, i0 + 1)]
                route_grade = sum(g) / len(g)
                ok = abs(mesh_grade - route_grade) <= TOL["slope_pp"]
                report["probes"].append({"section": label, "s": sv, "slope_over_m": round(s2 - sv, 1),
                                         "mesh_grade_percent": round(mesh_grade, 3),
                                         "route_grade_percent": round(route_grade, 3), "ok": ok})
                if not ok:
                    errs.append(f"probe {label} s={sv}: mesh grade {mesh_grade:.2f}% vs route {route_grade:.2f}%")
    report["errors"] = errs
    report["valid"] = not errs
    with open(os.path.join(pkg, "validation.json"), "w") as f:
        json.dump(report, f, indent=1)
    return errs, report


def main(argv):
    opts = dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)
    args = [a for a in argv if not a.startswith("--")]
    if len(args) == 2 and args[0] == "build":
        terrain = {}
        if "hill-amplitude-m" in opts:
            terrain["hill_amplitude_m"] = float(opts["hill-amplitude-m"])
        if "seed" in opts:
            terrain["seed"] = int(opts["seed"])
        man = build(args[1], float(opts.get("tile-m", 500)), terrain)
        print(f"{args[1]}: {len(man['tiles'])} tiles of ~{man['tile_m']:.0f} m")
        args = ["validate", args[1]]
    if len(args) == 2 and args[0] == "validate":
        errs, rep = validate(args[1])
        for t in rep["tiles"]:
            e = t["max_error"]
            print(f"  tile {t['id']} s {t['from_s']:.0f}-{t['to_s']:.0f}: pos {e['position']:.4f} elev {e['elevation']:.4f} "
                  f"width {e['width']:.4f} slope {e['slope_pp']:.3f}pp terrain-edge {t['terrain_edge_error_m']:.4f} "
                  f"{'OK' if t['ok'] else 'FAIL'}")
        print(f"  seams: max gap {max([x['max_gap_m'] for x in rep['seams']] or [0]):.6f} m over {len(rep['seams'])} seams")
        for p in rep["probes"]:
            if "u" in p:
                print(f"  probe {p['section']:6} s={p['s']:8.1f} u={p['u']:6.2f}: road {p['road_y']} route {p['route_y']} "
                      f"{'OK' if p['ok'] else 'FAIL'}")
            else:
                print(f"  probe {p['section']:6} s={p['s']:8.1f} grade over {p['slope_over_m']} m: mesh "
                      f"{p['mesh_grade_percent']}% route {p['route_grade_percent']}% {'OK' if p['ok'] else 'FAIL'}")
        for e in errs:
            print("  FAIL", e)
        print("VALID" if not errs else f"INVALID ({len(errs)} problems)")
        return 0 if not errs else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
