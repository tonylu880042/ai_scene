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
from terrain_clearance import RoadCorridors, road_occlusions, clip_terrain, bank_envelopes, conform_banks, coastal_owner_envelopes  # noqa: E402

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


def _grid_indices(rows, cols, base=0, keep=None, positions=None):
    """Two triangles per cell of a rows x cols grid whose columns increase to the LEFT of travel: front faces up."""
    out = []
    for r in range(rows - 1):
        if keep is not None and not keep(r):
            continue
        for c in range(cols - 1):
            a, b = base + r * cols + c, base + (r + 1) * cols + c
            cell = [a, b, a + 1, b, b + 1, a + 1]
            if positions is not None and _face_up(positions, cell):
                alternative = [a, b, b + 1, a, b + 1, a + 1]
                if _face_up(positions, alternative):
                    raise ValueError(f"offset corridor crosses itself near row {r}; review route curvature / widths")
                cell = alternative
            out += cell
    return out


def _terrain_reach_limits(smp, side, candidates, margin):
    """Bound outward rays before adjacent road-edge rays meet; never change the road edge itself."""
    limits = list(candidates)
    normals, edges = [], []
    for i, h in enumerate(smp["heading_deg"]):
        lx, lz = rm.left_vector(h)
        normal = (side*lx, side*lz)
        width = smp["width_left_m" if side > 0 else "width_right_m"][i]
        normals.append(normal)
        edges.append((smp["x"][i]+normal[0]*width, smp["z"][i]+normal[1]*width))
    def cross(a,b):
        return a[0]*b[1]-a[1]*b[0]
    for i in range(len(edges)-1):
        a,b = normals[i:i+2]
        det = cross(a,b)
        if abs(det) < 1e-10:
            continue
        delta = (edges[i+1][0]-edges[i][0], edges[i+1][1]-edges[i][1])
        ta,tb = cross(delta,b)/det, cross(delta,a)/det
        if ta > 0 and tb > 0:
            limits[i] = min(limits[i],ta*margin)
            limits[i+1] = min(limits[i+1],tb*margin)
    return limits


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


def coast_profile(profiles, s, side):
    """Explicit shore cross-sections, independent of gameplay geometry."""
    return next((p for p in profiles if p["side"] in (side, "both")
                 and p["from_s"] <= s <= p["to_s"]), None)


def _find_level_crossing(height_at, level, start, end, steps=48):
    """Find the first bounded crossing of a scalar height function, using bisection locally."""
    if end <= start:
        return None
    x0 = start
    f0 = height_at(x0) - level
    for step in range(1, steps + 1):
        x1 = start + (end - start) * step / steps
        f1 = height_at(x1) - level
        if f0 == 0.0:
            return x0
        if f1 == 0.0:
            return x1
        if (f0 < 0.0) != (f1 < 0.0):
            lo, hi, flo = x0, x1, f0
            for _ in range(48):
                mid = (lo + hi) * 0.5
                fm = height_at(mid) - level
                if (fm < 0.0) == (flo < 0.0):
                    lo, flo = mid, fm
                else:
                    hi = mid
            return (lo + hi) * 0.5
        x0, f0 = x1, f1
    return None


def _upward_triangle(indices, positions):
    """Validate the construction-order winding; never repair a folded terrain face by reversal."""
    tri = list(indices)
    if _face_up(positions, tri) != 0:
        raise ValueError("coastal shoreline strip contains a degenerate or folded triangle")
    return tri


def _waterline_copy_vertex(index, level, positions, stations, lateral, cache):
    """Return a level vertex at existing XZ while leaving any authored point untouched."""
    if positions[index][1] == level:
        return index
    if index not in cache:
        point=positions[index]
        cache[index]=len(positions)
        positions.append((point[0],float(level),point[2]))
        stations.append(stations[index]);lateral.append(lateral[index])
    return cache[index]


def _zipper_chain_indices(row_a, row_b, lateral, positions):
    """Triangulate the strip between two ordered cross-section chains without dropping vertices."""
    if not row_a or not row_b:
        return []
    if len(row_a) == 1:
        out=[]
        for j in range(len(row_b)-1):
            out.extend(_upward_triangle((row_a[0],row_b[j],row_b[j+1]),positions))
        return out
    if len(row_b) == 1:
        out=[]
        for i in range(len(row_a)-1):
            out.extend(_upward_triangle((row_a[i],row_b[0],row_a[i+1]),positions))
        return out
    a0, a1 = lateral[row_a[0]], lateral[row_a[-1]]
    b0, b1 = lateral[row_b[0]], lateral[row_b[-1]]
    if abs(a1-a0) < 1e-9 or abs(b1-b0) < 1e-9:
        raise ValueError("coastal shoreline strip has zero lateral span")
    ai = bi = 0
    out = []
    while ai < len(row_a)-1 or bi < len(row_b)-1:
        if ai == len(row_a)-1:
            tri = (row_a[ai], row_b[bi], row_b[bi+1])
            bi += 1
        elif bi == len(row_b)-1:
            tri = (row_a[ai], row_b[bi], row_a[ai+1])
            ai += 1
        else:
            pa = (lateral[row_a[ai+1]]-a0)/(a1-a0)
            pb = (lateral[row_b[bi+1]]-b0)/(b1-b0)
            if pa <= pb:
                tri = (row_a[ai], row_b[bi], row_a[ai+1])
                ai += 1
            else:
                tri = (row_a[ai], row_b[bi], row_b[bi+1])
                bi += 1
        out.extend(_upward_triangle(tri, positions))
    return out


def _shoreline_strip_indices(row_a, row_b, anchor_a, anchor_b, lateral, positions):
    """Connect corresponding waterline anchors and triangulate both sides of the coast strip."""
    if not (0 <= anchor_a < len(row_a) and 0 <= anchor_b < len(row_b)):
        raise ValueError("coastal shoreline anchor index is outside its terrain row")
    outer = _zipper_chain_indices(row_a[:anchor_a+1], row_b[:anchor_b+1], lateral, positions)
    inner = _zipper_chain_indices(row_a[anchor_a:], row_b[anchor_b:], lateral, positions)
    return outer + inner


def _anchored_row_pair_indices(base_a, base_b, row_a, row_b, anchor_a, anchor_b, lateral, positions):
    """Retessellate only base-column bands crossed by adjacent shoreline anchors."""
    def bracket(base, anchor):
        u = lateral[anchor]
        values = [lateral[index] for index in base]
        for k in range(len(values)-1):
            if values[k] - 1e-8 <= u <= values[k+1] + 1e-8:
                return k
        raise ValueError("coastal shoreline anchor falls outside its row")

    ka, kb = bracket(base_a, anchor_a), bracket(base_b, anchor_b)
    start = max(0, min(ka, kb)-1)
    end = min(len(base_a)-1, max(ka, kb)+2)
    if end <= start:
        raise ValueError("coastal shoreline anchor has no terrain band around it")

    def segment(row, base, anchor, lo, hi):
        ia, ir, ib = row.index(base[lo]), row.index(anchor), row.index(base[hi])
        if not ia <= ir <= ib:
            raise ValueError("coastal anchor order disagrees with lateral terrain columns")
        return row[ia:ir+1], row[ir:ib+1]

    a_outer, a_inner = segment(row_a, base_a, anchor_a, start, end)
    b_outer, b_inner = segment(row_b, base_b, anchor_b, start, end)
    out = _zipper_chain_indices(a_outer, b_outer, lateral, positions)
    out += _zipper_chain_indices(a_inner, b_inner, lateral, positions)
    for c in range(len(base_a)-1):
        if start <= c < end:
            continue
        out += _grid_cell_indices(base_a[c], base_b[c], base_a[c+1], base_b[c+1], positions)
    return out


def _grid_cell_indices(a, b, a1, b1, positions):
    """The legacy two-triangle cell, with its existing folded-face check."""
    cell = [a, b, a1, b, b1, a1]
    if _face_up(positions, cell):
        alternative = [a, b, b1, a, b1, a1]
        if _face_up(positions, alternative):
            raise ValueError("offset corridor crosses itself; review route curvature / widths")
        cell = alternative
    return cell


def _capped_exit_strip_indices(row_a, row_b, cap_a, cap_b, root, exit_vertex,
                              level, positions, stations, lateral):
    """Constrain a two-row zipper to the analytic root-to-original-cap exit segment."""
    zipper = _zipper_chain_indices(row_a, row_b, lateral, positions)
    source = [tuple(zipper[i:i+3]) for i in range(0, len(zipper), 3)]
    edge_found = False
    split_source = []
    for tri in source:
        hit = next((i for i in range(3)
                    if {tri[i], tri[(i+1) % 3]} == {cap_a, cap_b}), None)
        if hit is None:
            split_source.append(tri)
            continue
        if edge_found:
            raise ValueError("capped shoreline exit found a duplicated outer cap edge")
        edge_found = True
        x, y, z = tri[hit], tri[(hit+1) % 3], tri[(hit+2) % 3]
        split_source.extend(((x, exit_vertex, z), (exit_vertex, y, z)))
    if not edge_found:
        raise ValueError("capped shoreline exit is not on the original terrain cap edge")

    a = positions[root]
    b = positions[exit_vertex]
    dx, dz = b[0]-a[0], b[2]-a[2]
    length2 = dx*dx + dz*dz
    if not math.isfinite(length2) or length2 <= 0.0:
        raise ValueError("capped shoreline transition has a zero-length root segment")
    intersections = {}
    endpoint_splits = {}

    def signed(point):
        return dx*(point[2]-a[2]) - dz*(point[0]-a[0])

    def waterline_vertex(idx, distance):
        along = ((positions[idx][0]-a[0])*dx + (positions[idx][2]-a[2])*dz) / length2
        if along < -1e-7 or along > 1.0+1e-7:
            raise ValueError("shoreline transition line crosses a source vertex outside its cap segment")
        return _waterline_copy_vertex(idx,level,positions,stations,lateral,endpoint_splits)

    def intersection(i, j, fi, fj):
        for idx, value in ((i,fi),(j,fj)):
            if value == 0.0:
                return waterline_vertex(idx,value)
        edge = tuple(sorted((i, j)))
        if edge in intersections:
            return intersections[edge]
        t = fi / (fi-fj)
        p, q = positions[i], positions[j]
        point = tuple(p[k] + t*(q[k]-p[k]) for k in range(3))
        point = (point[0], float(level), point[2])
        along = ((point[0]-a[0])*dx + (point[2]-a[2])*dz) / length2
        if along < -1e-7 or along > 1.0+1e-7:
            raise ValueError("shoreline transition line leaves the capped terrain strip")
        idx = len(positions)
        positions.append(point)
        stations.append(stations[i] + t*(stations[j]-stations[i]))
        lateral.append(lateral[i] + t*(lateral[j]-lateral[i]))
        intersections[edge] = idx
        return idx

    output = []
    for tri in split_source:
        if _face_up(positions, tri) != 0:
            raise ValueError("capped shoreline source zipper contains a folded face")
        for keep_positive in (True, False):
            poly = []
            previous = tri[-1]
            f_previous = signed(positions[previous])
            in_previous = f_previous >= 0.0 if keep_positive else f_previous <= 0.0
            for current in tri:
                f_current = signed(positions[current])
                in_current = f_current >= 0.0 if keep_positive else f_current <= 0.0
                if in_current != in_previous:
                    poly.append(intersection(previous, current, f_previous, f_current))
                if in_current:
                    if f_current == 0.0:
                        poly.append(waterline_vertex(current,f_current))
                    else:
                        poly.append(current)
                previous, f_previous, in_previous = current, f_current, in_current
            cleaned = []
            for idx in poly:
                if not cleaned or cleaned[-1] != idx:
                    cleaned.append(idx)
            if len(cleaned) > 1 and cleaned[0] == cleaned[-1]:
                cleaned.pop()
            for k in range(1, len(cleaned)-1):
                piece = (cleaned[0], cleaned[k], cleaned[k+1])
                pa, pb, pc = (positions[i] for i in piece)
                signed_area = (pb[2]-pa[2])*(pc[0]-pa[0]) - (pb[0]-pa[0])*(pc[2]-pa[2])
                if signed_area > 0.0:
                    output.extend(piece)
                elif signed_area < 0.0:
                    raise ValueError("capped shoreline clipping changed source face winding")
                # Only a mathematically zero-area remnant on the cut is discarded.
    return output, {"source_triangles": len(source), "clipped_triangles": len(output)//3,
                    "line_intersections": len(intersections)+len(endpoint_splits)}


def _coastal_waterline_distance(smp, i, side, reach_m, D, tp, profile):
    """Return the existing analytic coast function's first waterline crossing within this row reach."""
    width = smp["width_left_m" if side > 0 else "width_right_m"][i]
    if reach_m <= 0:
        return None
    lx, lz = rm.left_vector(smp["heading_deg"][i])

    def height_at(distance):
        u = side * (width + distance)
        x = smp["x"][i] + lx*u
        z = smp["z"][i] + lz*u
        height = (smp["y"][i] - tp["shoulder_drop_m"] * smoothstep(0.0, D[1], distance)
                  + relief(x, z, tp) * smoothstep(tp["flat_band_m"], tp["blend_to_m"], distance))
        return coastal_height(height, smp["y"][i], width, u, profile)

    return _find_level_crossing(height_at, float(profile.get("water_level_m", 0.0)), 0.0, reach_m)


def _coastal_anchor_config(tp):
    """Validate optional root scope and endpoint policy without affecting coast heights."""
    mode=tp.get("coastal_waterline_anchor_seam_mode","preserve_cross_section")
    if mode not in ("preserve_cross_section","analytic_level"):
        raise ValueError("coastal_waterline_anchor_seam_mode must be preserve_cross_section or analytic_level")
    capped_exit=bool(tp.get("coastal_waterline_capped_exit",False))
    if capped_exit and not tp.get("coastal_waterline_anchors",False):
        raise ValueError("coastal_waterline_capped_exit requires coastal_waterline_anchors")
    scope=tp.get("coastal_waterline_anchor_range_m")
    if scope is None:
        if capped_exit:
            raise ValueError("coastal_waterline_capped_exit requires coastal_waterline_anchor_range_m")
        return None,mode
    if (not isinstance(scope,(list,tuple)) or len(scope)!=2 or
            not all(isinstance(v,(int,float)) and math.isfinite(float(v)) for v in scope) or
            float(scope[0])>=float(scope[1])):
        raise ValueError("coastal_waterline_anchor_range_m must be an increasing finite [start_s,end_s] pair")
    if capped_exit and mode != "analytic_level":
        raise ValueError("coastal_waterline_capped_exit requires analytic_level seam mode")
    return (float(scope[0]),float(scope[1])),mode


def coastal_height(height, road_y, width, u, profile):
    if not profile or abs(u) <= width:
        return height
    edge = max(profile["water_edge_m"], width + 0.1)
    # An authored narrow seawall may meet water within the procedural noise's 3 m flat band.
    start = max(width, edge - profile.get("bank_width_m", 4.0))
    blend = smoothstep(start, edge + 0.8, abs(u))
    far = profile.get("water_far_m")
    if far is not None:  # optional water band (creek / channel): land rises again beyond its far edge
        blend *= 1.0 - smoothstep(max(far - 0.8, edge + 0.8), far + profile.get("bank_width_m", 4.0), abs(u))
    return height * (1 - blend) + (profile.get("water_level_m", 0.0) - 0.8) * blend


def coastal_sand(profile, u):
    """Sand band at the water edge(s) of a coast profile (both banks of an optional water band)."""
    if not profile:
        return False
    sand = profile.get("sand_width_m", 2.0)
    far = profile.get("water_far_m")
    return abs(u) > profile["water_edge_m"] - sand and (far is None or abs(u) < far + sand)


def _terrain_grid_with_coastal_anchors(smp, rows, D, reaches, tp):
    """Build bounded waterline roots plus seam/transition splits that preserve sampled cross-sections."""
    anchor_range,seam_mode=_coastal_anchor_config(tp)
    capped_exit=bool(tp.get("coastal_waterline_capped_exit",False))
    positions, stations, lateral, indices = [], [], [], []
    report = {"anchors_added": 0, "seam_splits": 0, "transition_splits": 0,
              "analytic_seam_anchors": 0,"range_transition_roots": 0,"unpaired_roots": 0,
              "rows_without_reachable_crossing": 0}
    if capped_exit:
        report["capped_exit_roots"]=0
        report["capped_exit_pairs"]=[]
    for side in (-1, 1):
        key = "width_left_m" if side > 0 else "width_right_m"
        ds = list(D if side > 0 else D[::-1])
        base_rows, full_rows, special_ids = [], [], []
        for i in rows:
            width = smp[key][i]
            scale = reaches[side][i] / D[-1]
            us = [side*(width+d*scale) for d in ds]
            heights = []
            for u, d in zip(us, ds):
                lx, lz = rm.left_vector(smp["heading_deg"][i])
                x, z = smp["x"][i]+lx*u, smp["z"][i]+lz*u
                dd = d*scale
                height = (smp["y"][i] - tp["shoulder_drop_m"] * smoothstep(0.0,D[1],dd)
                          + relief(x,z,tp) * smoothstep(tp["flat_band_m"],tp["blend_to_m"],dd))
                profile = coast_profile(tp.get("coast_profiles",[]),smp["s"][i],"left" if side>0 else "right")
                heights.append(coastal_height(height,smp["y"][i],width,u,profile))
            base = []
            for u, h in zip(us, heights):
                base.append(len(positions));positions.append(_cross_section(smp,i,[u],[h])[0])
                stations.append(smp["s"][i]);lateral.append(u)

            anchor_id = None
            bracket = None
            profile = coast_profile(tp.get("coast_profiles",[]),smp["s"][i],"left" if side>0 else "right")
            s_value=float(smp["s"][i])
            in_anchor_range=(anchor_range is None or
                             anchor_range[0]-1e-7<=s_value<=anchor_range[1]+1e-7)
            distance = (_coastal_waterline_distance(smp,i,side,reaches[side][i],D,tp,profile)
                        if tp.get("coastal_waterline_anchors",False) and profile and in_anchor_range else None)
            if distance is not None:
                anchor_u = side*(width+distance)
                for k in range(len(base)-1):
                    u0,u1=lateral[base[k]],lateral[base[k+1]]
                    if u0-1e-7 <= anchor_u <= u1+1e-7:
                        bracket=k
                        break
                if bracket is not None:
                    if abs(anchor_u-lateral[base[bracket]]) <= 1e-7:
                        anchor_id=base[bracket]
                    elif abs(anchor_u-lateral[base[bracket+1]]) <= 1e-7:
                        anchor_id=base[bracket+1]
                    else:
                        xz=_cross_section(smp,i,[anchor_u],[float(profile.get("water_level_m",0.0))])[0]
                        anchor_id=len(positions);positions.append(xz);stations.append(smp["s"][i]);lateral.append(anchor_u)
                        report["anchors_added"] += 1
                    level=float(profile.get("water_level_m",0.0))
                    if (seam_mode=="analytic_level" and in_anchor_range and
                            abs(lateral[anchor_id]-anchor_u)<=1e-7 and abs(positions[anchor_id][1]-level)>1e-7):
                        # A root can coincide with a coarse sample column. Replace only its row
                        # reference; keep the authored vertex and its serialized position intact.
                        root_position=_cross_section(smp,i,[anchor_u],[level])[0]
                        root_id=len(positions);positions.append(root_position)
                        stations.append(smp["s"][i]);lateral.append(anchor_u)
                        base[base.index(anchor_id)]=root_id
                        anchor_id=root_id;report["anchors_added"]+=1
            if profile and anchor_id is None:
                report["rows_without_reachable_crossing"] += 1
            base_rows.append(base)
            special_ids.append(anchor_id)

        def split_row(row, u, water_level=None, reuse_id=None):
            vals=[lateral[j] for j in row]
            for j in row:
                if abs(lateral[j]-u) <= 1e-7:
                    return j
            for k in range(len(row)-1):
                if vals[k] < u < vals[k+1]:
                    a,b=row[k],row[k+1]
                    t=(u-lateral[a])/(lateral[b]-lateral[a])
                    pa,pb=positions[a],positions[b]
                    point=tuple(pa[q]+t*(pb[q]-pa[q]) for q in range(3))
                    if water_level is not None:
                        point=(point[0],float(water_level),point[2])
                    if reuse_id is None:
                        idx=len(positions);positions.append(point)
                        stations.append(stations[a]+t*(stations[b]-stations[a]));lateral.append(u)
                    else:
                        idx=reuse_id;positions[idx]=point
                    return idx
            return None

        def capped_exit_pair(r, side, root_a, root_b):
            """Constrain a one-sided root transition to the original outer cap edge."""
            if not capped_exit or (root_a is None)==(root_b is None):
                return None
            if seam_mode != "analytic_level":
                return None
            ia,ib=rows[r],rows[r+1]
            sa,sb=float(smp["s"][ia]),float(smp["s"][ib])
            if not (anchor_range[0]-1e-7<=sa<=anchor_range[1]+1e-7 and
                    anchor_range[0]-1e-7<=sb<=anchor_range[1]+1e-7):
                return None
            profile_a=coast_profile(tp.get("coast_profiles",[]),sa,"left" if side>0 else "right")
            profile_b=coast_profile(tp.get("coast_profiles",[]),sb,"left" if side>0 else "right")
            if not profile_a or not profile_b or profile_a != profile_b:
                return None
            level=float(profile_a.get("water_level_m",0.0))
            if (float(profile_b.get("water_level_m",0.0))!=level or
                    profile_a.get("side") not in ("both","left" if side>0 else "right") or
                    profile_b.get("side") not in ("both","left" if side>0 else "right")):
                return None
            base_a,base_b=base_rows[r],base_rows[r+1]
            cap_col=0 if side<0 else len(base_a)-1
            root=root_a if root_a is not None else root_b
            root_row=base_a if root_a is not None else base_b
            if root not in root_row and not any(
                    lateral[root_row[k]] <= lateral[root] <= lateral[root_row[k+1]]
                    for k in range(len(root_row)-1)):
                return None
            cap_a,cap_b=base_a[cap_col],base_b[cap_col]
            pa,pb=positions[cap_a],positions[cap_b]
            width_key="width_left_m" if side>0 else "width_right_m"
            route_s=smp["s"]
            def coast_height_at(t):
                station=sa+(sb-sa)*t
                u=lateral[cap_a]+(lateral[cap_b]-lateral[cap_a])*t
                x=pa[0]+(pb[0]-pa[0])*t;z=pa[2]+(pb[2]-pa[2])*t
                sample=min(max(bisect.bisect_right(route_s,station)-1,0),len(route_s)-2)
                f=min(1.0,max(0.0,(station-route_s[sample])/(route_s[sample+1]-route_s[sample])))
                road_y=smp["y"][sample]+(smp["y"][sample+1]-smp["y"][sample])*f
                width=smp[width_key][sample]+(smp[width_key][sample+1]-smp[width_key][sample])*f
                distance=max(0.0,abs(u)-width)
                height=(road_y-tp["shoulder_drop_m"]*smoothstep(0.0,D[1],distance)
                        +relief(x,z,tp)*smoothstep(tp["flat_band_m"],tp["blend_to_m"],distance))
                return coastal_height(height,road_y,width,u,profile_a)-level
            t=_find_level_crossing(coast_height_at,0.0,0.0,1.0)
            if t is None or t<=1e-7 or t>=1.0-1e-7:
                return None
            station=sa+(sb-sa)*t
            u=lateral[cap_a]+(lateral[cap_b]-lateral[cap_a])*t
            point=(pa[0]+(pb[0]-pa[0])*t,level,pa[2]+(pb[2]-pa[2])*t)
            exit_id=len(positions);positions.append(point);stations.append(station);lateral.append(u)
            full_a=list(base_a);full_b=list(base_b)
            for idx,row in ((root_a,full_a),(root_b,full_b)):
                if idx is not None and idx not in row:
                    row.append(idx);row.sort(key=lambda j:lateral[j])
            cell_indices,clip_stats=_capped_exit_strip_indices(
                full_a,full_b,cap_a,cap_b,root,exit_id,level,positions,stations,lateral)
            root_cell=next((k for k in range(len(root_row)-1)
                            if min(lateral[root_row[k]],lateral[root_row[k+1]])-1e-7 <= lateral[root] <=
                               max(lateral[root_row[k]],lateral[root_row[k+1]])+1e-7),None)
            report["capped_exit_roots"]+=1
            report["capped_exit_pairs"].append({"rows":[r,r+1],"stations_m":[sa,sb],
                "exit_station_m":station,"exit_u_m":u,"analytic_height_residual_m":coast_height_at(t),
                "root_station_m":stations[root],"root_u_m":lateral[root],
                "root_vertex":root,"cap_vertices":[cap_a,cap_b],"exit_vertex":exit_id,
                "root_cell_index":root_cell,"cap_cell_index":0 if side<0 else len(base_a)-2,
                **clip_stats})
            return cell_indices

        # Tile boundary splits keep the original cross-section polyline exactly.
        for r in (0,len(rows)-1):
            root=special_ids[r]
            if root is None:
                continue
            row_s=float(smp["s"][rows[r]])
            active=(anchor_range is None or anchor_range[0]-1e-7<=row_s<=anchor_range[1]+1e-7)
            if seam_mode=="analytic_level" and active:
                report["analytic_seam_anchors"]+=1
                continue
            if root not in base_rows[r]:
                split=split_row(base_rows[r],lateral[root],reuse_id=root)
                if split is not None:
                    special_ids[r]=split;report["seam_splits"]+=1
                    report["anchors_added"]-=1
                else:
                    special_ids[r]=None

        # Pair roots across neighboring rows when the same U is within both existing reaches.
        analytic_or_seam_ids=list(special_ids)
        for r in range(len(rows)-1):
            a,b=analytic_or_seam_ids[r],analytic_or_seam_ids[r+1]
            if (a is None) == (b is None):
                continue
            if anchor_range is not None:
                sa=float(smp["s"][rows[r]]);sb=float(smp["s"][rows[r+1]])
                in_a=anchor_range[0]-1e-7<=sa<=anchor_range[1]+1e-7
                in_b=anchor_range[0]-1e-7<=sb<=anchor_range[1]+1e-7
                if in_a!=in_b:
                    report["range_transition_roots"]+=1
                    continue
            source=a if a is not None else b
            target_row=base_rows[r+1] if a is not None else base_rows[r]
            target=split_row(target_row,lateral[source])
            if target is None:
                report["unpaired_roots"]+=1
                continue
            if a is not None:
                special_ids[r+1]=target
            else:
                special_ids[r]=target
            report["transition_splits"]+=1

        # Stitch every pair using the special split when both rows have one. If a root is
        # outside its neighbor's capped reach, zipper the full rows without widening either row.
        for r in range(len(rows)-1):
            ra,rb=special_ids[r],special_ids[r+1]
            full_a=list(base_rows[r]);full_b=list(base_rows[r+1])
            for idx,row in ((ra,full_a),(rb,full_b)):
                if idx is not None and idx not in row:
                    row.append(idx);row.sort(key=lambda j:lateral[j])
            if ra is not None and rb is not None:
                ia,ib=full_a.index(ra),full_b.index(rb)
                if 0 < ia < len(full_a)-1 and 0 < ib < len(full_b)-1:
                    indices.extend(_anchored_row_pair_indices(base_rows[r],base_rows[r+1],
                        full_a,full_b,ra,rb,lateral,positions))
                else:
                    indices.extend(_shoreline_strip_indices(full_a,full_b,ia,ib,lateral,positions))
            elif ra is not None or rb is not None:
                exit_indices=capped_exit_pair(r,side,ra,rb)
                if exit_indices is not None:
                    indices.extend(exit_indices)
                else:
                    indices.extend(_zipper_chain_indices(full_a,full_b,lateral,positions))
            else:
                for c in range(len(D)-1):
                    indices.extend(_grid_cell_indices(base_rows[r][c],base_rows[r+1][c],
                                                      base_rows[r][c+1],base_rows[r+1][c+1],positions))
    return positions,stations,lateral,indices,report


def refresh_tile_bounds(pkg,tile):
    """Recompute the package world AABB from the final serialized road and terrain meshes."""
    positions=[]
    for layer in ("road","terrain"):
        mesh=read_glb(os.path.join(pkg,tile["files"][layer]))
        positions.extend(_world(mesh))
    tile["bounds"]={"min":[round(min(p[k] for p in positions),3) for k in range(3)],
                     "max":[round(max(p[k] for p in positions),3) for k in range(3)]}


def _point_in_polygon_xz(point, polygon):
    x,z=point; inside=False
    for i,(ax,az) in enumerate(polygon):
        bx,bz=polygon[(i+1)%len(polygon)]
        if (az>z)!=(bz>z) and x < (bx-ax)*(z-az)/(bz-az)+ax:
            inside=not inside
    return inside


def _segments_intersect_xz(a,b,c,d):
    def orient(p,q,r): return (q[0]-p[0])*(r[1]-p[1])-(q[1]-p[1])*(r[0]-p[0])
    def on(p,q,r): return min(p[0],q[0])-1e-8<=r[0]<=max(p[0],q[0])+1e-8 and min(p[1],q[1])-1e-8<=r[1]<=max(p[1],q[1])+1e-8
    o1,o2,o3,o4=orient(a,b,c),orient(a,b,d),orient(c,d,a),orient(c,d,b)
    if ((o1>1e-8 and o2< -1e-8) or (o1< -1e-8 and o2>1e-8)) and ((o3>1e-8 and o4< -1e-8) or (o3< -1e-8 and o4>1e-8)): return True
    return (abs(o1)<=1e-8 and on(a,b,c)) or (abs(o2)<=1e-8 and on(a,b,d)) or (abs(o3)<=1e-8 and on(c,d,a)) or (abs(o4)<=1e-8 and on(c,d,b))


def _polygon_intersects_triangle_xz(polygon, triangle):
    tri=[(p[0],p[2]) for p in triangle]
    if max(p[0] for p in polygon)<min(p[0] for p in tri)-1e-6 or min(p[0] for p in polygon)>max(p[0] for p in tri)+1e-6 or max(p[1] for p in polygon)<min(p[1] for p in tri)-1e-6 or min(p[1] for p in polygon)>max(p[1] for p in tri)+1e-6:
        return False
    if any(_point_in_polygon_xz(p,polygon) for p in tri) or any(_point_in_polygon_xz(p,tri) for p in polygon): return True
    return any(_segments_intersect_xz(polygon[i],polygon[(i+1)%len(polygon)],tri[j],tri[(j+1)%3]) for i in range(len(polygon)) for j in range(3))


def _assert_pad_avoids_all_roads(pkg, manifest, polygon):
    for tile in manifest["tiles"]:
        path=tile.get("files",{}).get("road")
        if not path or not os.path.isfile(os.path.join(pkg,path)): continue
        road=read_glb(os.path.join(pkg,path)); positions=_world(road)
        for primitive in road["primitives"]:
            idx=primitive["indices"]
            for k in range(0,len(idx),3):
                tri=[positions[idx[k+j]] for j in range(3)]
                if _polygon_intersects_triangle_xz(polygon,tri):
                    raise ValueError(f"support pad overlaps canonical road triangle in tile {tile['id']}")


def _expand_quad_xz(corners, margin_m):
    if margin_m <= 0: return list(corners)
    area=sum(corners[i][0]*corners[(i+1)%4][1]-corners[(i+1)%4][0]*corners[i][1] for i in range(4))
    sign=1.0 if area>0 else -1.0; out=[]
    for i,p in enumerate(corners):
        prev=corners[(i-1)%4]; nxt=corners[(i+1)%4]
        e1=(p[0]-prev[0],p[1]-prev[1]); e2=(nxt[0]-p[0],nxt[1]-p[1])
        n1=(sign*e1[1]/math.hypot(*e1),-sign*e1[0]/math.hypot(*e1))
        n2=(sign*e2[1]/math.hypot(*e2),-sign*e2[0]/math.hypot(*e2))
        det=n1[0]*n2[1]-n1[1]*n2[0]
        if abs(det)<1e-8: raise ValueError("support pad polygon has a degenerate corner")
        dx=margin_m*(n2[1]-n1[1])/det; dz=margin_m*(n1[0]-n2[0])/det
        out.append((p[0]+dx,p[1]+dz))
    return out


def add_local_ground_support_pad(pkg, tile_id, *, polygon_xz, top_y_m, s_center_m, grid_m, source, margin_m=0.02):
    """Add a source-labeled, local P1 support surface to one terrain tile without touching its road mesh.

    ``polygon_xz`` must be four ordered world-space corners of a rectangle/parallelogram. Heights are
    deliberately explicit: the caller must sample the existing terrain and record that derivation.
    This models an estimated level construction pad, not a surveyed ground surface.
    """
    if len(polygon_xz) != 4 or grid_m <= 0 or not isinstance(source, dict) or not source.get("estimated"):
        raise ValueError("support pad requires four corners, positive grid_m, and estimated provenance")
    corners = [(float(p[0]), float(p[1])) for p in polygon_xz]
    if any(math.hypot(corners[(i + 1) % 4][0] - p[0], corners[(i + 1) % 4][1] - p[1]) < 0.1
           for i, p in enumerate(corners)):
        raise ValueError("support pad has a degenerate edge")
    pkg = os.fspath(pkg)
    with open(os.path.join(pkg, "manifest.json")) as f:
        manifest = json.load(f)
    tile = next((t for t in manifest["tiles"] if str(t["id"]).zfill(2) == str(tile_id).zfill(2)), None)
    if tile is None:
        raise ValueError(f"unknown tile {tile_id}")
    corners = _expand_quad_xz(corners, float(margin_m))
    _assert_pad_avoids_all_roads(pkg,manifest,corners)
    path = os.path.join(pkg, tile["files"]["terrain"])
    mesh = read_glb(path)
    with open(os.path.join(pkg, "route", "route.json")) as f:
        route = json.load(f)
    p00, p10, p11, p01 = corners
    nx = max(1, math.ceil(math.hypot(p10[0] - p00[0], p10[1] - p00[1]) / grid_m))
    nz = max(1, math.ceil(math.hypot(p01[0] - p00[0], p01[1] - p00[1]) / grid_m))
    origin = mesh["translation"]
    positions, uvs, ss, us = [], [], [], []
    smp = route["samples"]
    near = min(range(len(smp["s"])), key=lambda i: abs(smp["s"][i] - s_center_m))
    lo, hi = max(0, near - 100), min(len(smp["s"]) - 1, near + 101)
    for iz in range(nz + 1):
        v = iz / nz
        for ix in range(nx + 1):
            u = ix / nx
            x = p00[0] * (1-u)*(1-v) + p10[0] * u*(1-v) + p11[0] * u*v + p01[0] * (1-u)*v
            z = p00[1] * (1-u)*(1-v) + p10[1] * u*(1-v) + p11[1] * u*v + p01[1] * (1-u)*v
            best = None
            for i in range(lo, hi):
                ax, az = smp["x"][i], smp["z"][i]
                dx, dz = smp["x"][i+1] - ax, smp["z"][i+1] - az
                f = max(0.0, min(1.0, ((x-ax)*dx + (z-az)*dz) / max(dx*dx + dz*dz, 1e-12)))
                xx, zz = ax + f*dx, az + f*dz
                dist2 = (x-xx)**2 + (z-zz)**2
                if best is None or dist2 < best[0]:
                    s = smp["s"][i] + f * (smp["s"][i+1] - smp["s"][i])
                    heading = math.radians(smp["heading_deg"][i])
                    lx, lz = -math.cos(heading), -math.sin(heading)
                    best = (dist2, s, (x-xx)*lx + (z-zz)*lz)
            positions.append((x-origin[0], float(top_y_m)-origin[1], z-origin[2]))
            uvs.append((x, z)); ss.append(best[1]); us.append(best[2])
    indices = []
    for iz in range(nz):
        for ix in range(nx):
            a = iz*(nx+1)+ix; b=a+1; d=(iz+1)*(nx+1)+ix; c=d+1
            indices.extend((a,d,c,a,c,b))
    world = [(p[0]+origin[0],p[1]+origin[1],p[2]+origin[2]) for p in positions]
    # Ensure top-facing triangle winding in X/Y/Z world coordinates.
    if indices and _normals(world, indices)[indices[0]][1] < 0:
        for k in range(0, len(indices), 3):
            indices[k+1], indices[k+2] = indices[k+2], indices[k+1]
    attrs = mesh["attributes"]
    old_normals=list(attrs["NORMAL"])
    offset = len(attrs["POSITION"])
    attrs["POSITION"].extend(positions)
    attrs["NORMAL"].extend([(0.0, 1.0, 0.0)] * len(positions))
    attrs["TEXCOORD_0"].extend(uvs)
    attrs["_ROUTE_S"].extend(ss)
    attrs["_ROUTE_U"].extend(us)
    mesh["primitives"].append({"material": dict(TERRAIN_MATERIAL), "indices": [offset+i for i in indices]})
    # Keep every preexisting terrain normal exactly; the new local level faces are individually top-facing.
    attrs["NORMAL"] = old_normals + [(0.0, 1.0, 0.0)] * len(positions)
    write_glb(path, mesh)
    refresh_tile_bounds(pkg, tile)
    record = {"tile_id": str(tile_id).zfill(2), "polygon_xz_m": corners, "top_y_m": float(top_y_m),
              "grid_m": grid_m, "s_center_m": float(s_center_m), "margin_m": float(margin_m), "source": source,
              "estimated": True, "method": "level construction support pad over existing P1 top surface"}
    manifest.setdefault("p1_local_support_patches", []).append(record)
    with open(os.path.join(pkg, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    return {**record, "added_vertices": len(positions), "added_triangles": len(indices)//3}


def _barycentric_height_xz(x, z, tri, eps=1e-4):
    (ax, ay, az), (bx, by, bz), (cx, cy, cz) = tri
    den = (bz-cz)*(ax-cx) + (cx-bx)*(az-cz)
    if abs(den) < 1e-12:
        return None
    a = ((bz-cz)*(x-cx) + (cx-bx)*(z-cz)) / den
    b = ((cz-az)*(x-cx) + (ax-cx)*(z-cz)) / den
    c = 1-a-b
    if min(a, b, c) < -eps:
        return None
    return a*ay + b*by + c*cy


def _segment_edge_parameter(a, b, c, d):
    """Return the segment parameter at a non-parallel 2-D segment intersection."""
    rx, rz = b[0]-a[0], b[1]-a[1]
    sx, sz = d[0]-c[0], d[1]-c[1]
    den = rx*sz-rz*sx
    if abs(den) < 1e-10:
        return None
    qx, qz = c[0]-a[0], c[1]-a[1]
    t, u = (qx*sz-qz*sx)/den, (qx*rz-qz*rx)/den
    return min(1.0, max(0.0, t)) if -1e-8 <= t <= 1+1e-8 and -1e-8 <= u <= 1+1e-8 else None


def add_local_ground_support_skirt(pkg, tile_id, *, reference_pkg, polygon_xz, top_y_m, grid_m, source,
                                   s_center_m, max_drop_m=2.0, margin_m=0.02):
    """Close only the vertical perimeter between an existing support pad and frozen reference P1 ground.

    The upper edge is looked up from the serialized pad's float32 vertices. The lower edge is split at
    reference-terrain triangle crossings so each skirt face follows one planar source triangle exactly.
    This appends side faces only; it never rebuilds the support top or changes route/road geometry.
    """
    if len(polygon_xz) != 4 or grid_m <= 0 or max_drop_m <= 0 or not isinstance(source, dict) or not source.get("estimated"):
        raise ValueError("support skirt requires four corners, positive spacing/drop, and estimated provenance")
    corners = _expand_quad_xz([(float(p[0]), float(p[1])) for p in polygon_xz], float(margin_m))
    pkg, reference_pkg = os.fspath(pkg), os.fspath(reference_pkg)
    with open(os.path.join(pkg, "manifest.json")) as f:
        manifest = json.load(f)
    tile = next((t for t in manifest["tiles"] if str(t["id"]).zfill(2) == str(tile_id).zfill(2)), None)
    if tile is None:
        raise ValueError(f"unknown tile {tile_id}")
    _assert_pad_avoids_all_roads(pkg, manifest, corners)
    target_path = os.path.join(pkg, tile["files"]["terrain"])
    with open(os.path.join(reference_pkg, "manifest.json")) as f:
        reference_manifest = json.load(f)
    target = read_glb(target_path)
    origin = target["translation"]
    target_world = _world(target)
    p00, p10, p11, p01 = corners
    nx = max(1, math.ceil(math.hypot(p10[0]-p00[0], p10[1]-p00[1]) / grid_m))
    nz = max(1, math.ceil(math.hypot(p01[0]-p00[0], p01[1]-p00[1]) / grid_m))
    upper_candidates = [(i, p) for i, p in enumerate(target_world) if abs(p[1]-float(top_y_m)) <= 0.0002]

    def expected(u, v):
        return (p00[0]*(1-u)*(1-v)+p10[0]*u*(1-v)+p11[0]*u*v+p01[0]*(1-u)*v,
                p00[1]*(1-u)*(1-v)+p10[1]*u*(1-v)+p11[1]*u*v+p01[1]*(1-u)*v)

    def upper_vertex(u, v):
        x, z = expected(u, v)
        i, p = min(upper_candidates, key=lambda item: math.hypot(item[1][0]-x, item[1][2]-z), default=(None, None))
        if i is None or math.hypot(p[0]-x, p[2]-z) > 0.003:
            raise ValueError("support skirt cannot find the serialized pad boundary vertex")
        return p

    # Only source terrain triangles whose XZ bounds meet the support footprint can own the lower edge.
    minx, maxx = min(p[0] for p in corners)-0.01, max(p[0] for p in corners)+0.01
    minz, maxz = min(p[1] for p in corners)-0.01, max(p[1] for p in corners)+0.01
    source_tris = []
    for source_tile in reference_manifest["tiles"]:
        bounds = source_tile.get("bounds", {})
        bmin, bmax = bounds.get("min", []), bounds.get("max", [])
        if len(bmin) == 3 and (bmax[0] < minx or bmin[0] > maxx or bmax[2] < minz or bmin[2] > maxz):
            continue
        source_rel = source_tile.get("files", {}).get("terrain")
        if not source_rel:
            continue
        source_path = os.path.join(reference_pkg, source_rel)
        if not os.path.isfile(source_path):
            continue
        reference = read_glb(source_path)
        if not reference["primitives"]:
            continue
        ref_world = _world(reference)
        for primitive in reference["primitives"]:
            if primitive["material"]["name"] not in ("terrain_ground", "shore_sand"):
                continue
            ids = primitive["indices"]
            for k in range(0, len(ids), 3):
                tri = tuple(ref_world[ids[k+j]] for j in range(3))
                if (max(p[0] for p in tri) >= minx and min(p[0] for p in tri) <= maxx and
                        max(p[2] for p in tri) >= minz and min(p[2] for p in tri) <= maxz):
                    source_tris.append(tri)
    if not source_tris:
        raise ValueError("no reference ground triangles beneath support skirt")

    with open(os.path.join(pkg, "route", "route.json")) as f:
        smp = json.load(f)["samples"]
    near = min(range(len(smp["s"])), key=lambda i: abs(smp["s"][i]-float(s_center_m)))
    lo, hi = max(0, near-100), min(len(smp["s"])-1, near+101)

    def route_coordinates(x, z):
        best = None
        for ri in range(lo, hi):
            ax, az = smp["x"][ri], smp["z"][ri]
            dx, dz = smp["x"][ri+1]-ax, smp["z"][ri+1]-az
            f = max(0.0, min(1.0, ((x-ax)*dx+(z-az)*dz)/max(dx*dx+dz*dz,1e-12)))
            xx, zz = ax+f*dx, az+f*dz
            dist2 = (x-xx)**2+(z-zz)**2
            if best is None or dist2 < best[0]:
                heading = math.radians(smp["heading_deg"][ri])
                best = (dist2, smp["s"][ri]+f*(smp["s"][ri+1]-smp["s"][ri]),
                        (x-xx)*(-math.cos(heading))+(z-zz)*(-math.sin(heading)))
        return best[1], best[2]

    # Four ordered top-edge chains, all taken from the actual serialized grid vertices.
    edges = [([upper_vertex(i/nx, 0) for i in range(nx+1)]),
             ([upper_vertex(1, i/nz) for i in range(nz+1)]),
             ([upper_vertex(1-i/nx, 1) for i in range(nx+1)]),
             ([upper_vertex(0, 1-i/nz) for i in range(nz+1)])]
    skirt_positions, skirt_s, skirt_u, skirt_indices = [], [], [], []
    bottom_vertex_groups, bottom_spans = {}, []

    def ground_owner(x, z):
        hits = [(height, tri) for tri in source_tris
                if (height := _barycentric_height_xz(x, z, tri)) is not None]
        return max(hits, key=lambda item: item[0]) if hits else (None, None)

    for chain in edges:
        for top_a, top_b in zip(chain, chain[1:]):
            a, b = (top_a[0], top_a[2]), (top_b[0], top_b[2])
            ts = [0.0, 1.0]
            for tri in source_tris:
                for j in range(3):
                    c, d = (tri[j][0], tri[j][2]), (tri[(j+1)%3][0], tri[(j+1)%3][2])
                    t = _segment_edge_parameter(a, b, c, d)
                    if t is not None:
                        ts.append(t)
            ts = sorted(ts)
            unique = []
            for t in ts:
                if not unique or t-unique[-1] > 1e-6:
                    unique.append(t)
            interval_lows = []
            for ta, tb in zip(unique, unique[1:]):
                mid = (ta+tb)*0.5
                x, z = a[0]+(b[0]-a[0])*mid, a[1]+(b[1]-a[1])*mid
                mid_y, owner = ground_owner(x, z)
                if owner is None:
                    raise ValueError(f"no reference ground inside support skirt interval at ({x:.3f}, {z:.3f})")
                endpoints = []
                for t in (ta, tb):
                    ex, ez = a[0]+(b[0]-a[0])*t, a[1]+(b[1]-a[1])*t
                    ey = _barycentric_height_xz(ex, ez, owner, eps=2e-4)
                    if ey is None:
                        raise ValueError("reference ground owner does not span its support skirt interval")
                    endpoints.append((ex, ey, ez))
                for _, y, _ in endpoints + [(x, mid_y, z)]:
                    drop = float(top_y_m)-y
                    if drop <= 0 or drop > max_drop_m:
                        raise ValueError(f"reference ground height incompatible inside support skirt interval ({drop:.3f} m)")
                interval_lows.append(endpoints)
            for i in range(len(unique)-1):
                ta, tb = unique[i], unique[i+1]
                upper_a = tuple(top_a[k]+(top_b[k]-top_a[k])*ta for k in range(3))
                upper_b = tuple(top_a[k]+(top_b[k]-top_a[k])*tb for k in range(3))
                base = len(skirt_positions)
                low_a, low_b = interval_lows[i]
                face = [upper_a, upper_b, low_b, low_a]
                skirt_positions.extend(face)
                for point in face:
                    station, lateral = route_coordinates(point[0], point[2])
                    skirt_s.append(station)
                    skirt_u.append(lateral)
                skirt_indices.extend((base, base+1, base+2, base, base+2, base+3))
                for bottom_idx in (base+2, base+3):
                    point = skirt_positions[bottom_idx]
                    bottom_vertex_groups.setdefault((round(point[0], 5), round(point[2], 5)), []).append(bottom_idx)
                bottom_spans.append((base+3, base+2))

    # At overlapping source-tile seams, adjacent owner triangles can touch the skirt at different
    # heights. Share the lower endpoint so the wall stays continuous and remains buried, never floating.
    for indices in bottom_vertex_groups.values():
        lowest = min(skirt_positions[i][1] for i in indices)
        for i in indices:
            x, _, z = skirt_positions[i]
            skirt_positions[i] = (x, lowest, z)

    max_ground_gap_m, max_ground_burial_m = 0.0, 0.0
    for ia, ib in bottom_spans:
        a, b = skirt_positions[ia], skirt_positions[ib]
        for fraction in (0.1, 0.25, 0.5, 0.75, 0.9):
            x, z = a[0]+(b[0]-a[0])*fraction, a[2]+(b[2]-a[2])*fraction
            ground, _ = ground_owner(x, z)
            if ground is None:
                raise ValueError(f"no reference ground beneath support skirt at ({x:.3f}, {z:.3f})")
            bottom_y = a[1]+(b[1]-a[1])*fraction
            gap = bottom_y-ground
            max_ground_gap_m = max(max_ground_gap_m, gap)
            max_ground_burial_m = max(max_ground_burial_m, -gap)
            if gap > 0.001:
                raise ValueError(f"support skirt bottom floats above reference ground by {gap:.3f} m")
            if float(top_y_m)-bottom_y > max_drop_m:
                raise ValueError("conservative support skirt joint exceeds max_drop_m")

    signed_area = sum(corners[i][0]*corners[(i+1)%4][1]-corners[(i+1)%4][0]*corners[i][1]
                      for i in range(4))
    if signed_area < 0:
        for k in range(0, len(skirt_indices), 3):
            skirt_indices[k+1], skirt_indices[k+2] = skirt_indices[k+2], skirt_indices[k+1]

    # Convert world vertices to the target GLB node's local frame and append a side-only grass primitive.
    offset = len(target["attributes"]["POSITION"])
    target["attributes"]["POSITION"].extend([(p[0]-origin[0], p[1]-origin[1], p[2]-origin[2]) for p in skirt_positions])
    target["attributes"]["NORMAL"].extend(_normals(skirt_positions, skirt_indices))
    target["attributes"]["TEXCOORD_0"].extend([(p[0], p[2]) for p in skirt_positions])
    target["attributes"]["_ROUTE_S"].extend(skirt_s)
    target["attributes"]["_ROUTE_U"].extend(skirt_u)
    target["primitives"].append({"material": {"name":"support_skirt", "color":TERRAIN_MATERIAL["color"],
                                                "roughness":TERRAIN_MATERIAL["roughness"]},
                                 "indices": [offset+i for i in skirt_indices]})
    # Recalculate normals for faces with a stable outward direction; retain the exact top geometry and attributes.
    target["attributes"]["NORMAL"][-len(skirt_positions):] = _normals(skirt_positions, skirt_indices)
    write_glb(target_path, target)
    refresh_tile_bounds(pkg, tile)
    record = {"tile_id":str(tile_id).zfill(2), "polygon_xz_m":corners, "top_y_m":float(top_y_m),
              "max_drop_m":float(max_drop_m), "grid_m":float(grid_m), "source":source, "estimated":True,
              "method":"side-only skirt; upper edge from serialized support pad, lower edge traced on frozen reference terrain triangles; lower shared owner-seam endpoints conservatively buried",
              "bottom_ground_probes_per_span":5, "max_ground_gap_m":max_ground_gap_m,
              "max_ground_burial_m":max_ground_burial_m}
    manifest.setdefault("p1_local_support_skirts", []).append(record)
    with open(os.path.join(pkg, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    return {**record, "added_vertices":len(skirt_positions), "added_triangles":len(skirt_indices)//3}


def apply_coastal_ownership(pkg,tiles,smp,tp,corridors):
    """Conform foreign P1 triangles only to explicit, bounded, source-owned coast surfaces."""
    profiles=[p for p in tp.get("coast_profiles",[]) if p.get("overlap_priority",False)]
    if not profiles:return {}
    meshes={};owners=[]
    for tile in tiles:
        path=os.path.join(pkg,tile["files"]["terrain"]);mesh=read_glb(path);pos=_world(mesh)
        meshes[tile["id"]]=(path,mesh,pos,tile)
        owners.append((tile["id"],mesh,pos))
    envelopes,mask_report=coastal_owner_envelopes(owners,profiles,smp,corridors,
        road_clearance_m=float(tp.get("coastal_road_clearance_m",2.0)),
        surface_clearance_m=float(tp.get("coastal_overlap_clearance_m",0.02)))
    if not envelopes.tris:
        return {"mask":mask_report,"tiles":{},"status":"no_authorized_own_terrain"}
    reports={}
    for tid,(path,mesh,world,tile) in meshes.items():
        attrs=mesh["attributes"];ss=list(attrs["_ROUTE_S"]);uu=list(attrs["_ROUTE_U"])
        indices=[i for primitive in mesh["primitives"] for i in primitive["indices"]]
        origin=mesh["translation"]
        updated,stats=conform_banks(world,ss,uu,indices,envelopes,smp,origin,canonical_float32=True)
        reports[tid]=stats
        if not stats["modified_triangles"]:continue
        ground=[];sand=[];profiles_all=tp.get("coast_profiles",[])
        for k in range(0,len(updated),3):
            tri=updated[k:k+3];sv=sum(ss[j] for j in tri)/3;u=sum(uu[j] for j in tri)/3
            profile=coast_profile(profiles_all,sv,"left" if u>0 else "right")
            (sand if coastal_sand(profile,u) else ground).extend(tri)
        prims=[]
        if ground:prims.append({"material":TERRAIN_MATERIAL,"indices":ground})
        if sand:prims.append({"material":{"name":"shore_sand","color":[0.68,0.59,0.39],"roughness":0.95},"indices":sand})
        mesh["primitives"]=prims
        mesh["attributes"]["POSITION"]=[(p[0]-origin[0],p[1]-origin[1],p[2]-origin[2]) for p in world]
        mesh["attributes"]["_ROUTE_S"]=ss;mesh["attributes"]["_ROUTE_U"]=uu
        mesh["attributes"]["TEXCOORD_0"]=[(p[0],p[2]) for p in world]
        mesh["attributes"]["NORMAL"]=_normals(world,updated)
        write_glb(path,mesh)
        refresh_tile_bounds(pkg,tile)
    return {"mask":mask_report,"tiles":reports,"status":"applied"}


def build(pkg, tile_m=500.0, terrain=None):
    route_path = os.path.join(pkg, "route", "route.json")
    with open(route_path) as f:
        route = json.load(f)
    errs = rm.validate(route)
    if errs:
        raise ValueError("route.json is invalid, not building geometry:\n  " + "\n  ".join(errs))
    tp = dict(DEFAULT_TERRAIN, vertical_exaggeration=route.get("visual", {}).get("vertical_exaggeration", 1.0))
    tp.update(terrain or {})
    anchor_range,seam_mode=_coastal_anchor_config(tp)
    route_stations=route["samples"]["s"]
    if anchor_range is not None and (anchor_range[0]<float(route_stations[0]) or
                                     anchor_range[1]>float(route_stations[-1])):
        raise ValueError("coastal_waterline_anchor_range_m must fit within route station bounds")
    if anchor_range is not None and not tp.get("coastal_waterline_anchors",False):
        raise ValueError("coastal_waterline_anchor_range_m requires coastal_waterline_anchors")
    if seam_mode=="analytic_level" and not tp.get("coastal_waterline_anchors",False):
        raise ValueError("analytic_level seam mode requires coastal_waterline_anchors")
    smp = route["samples"]
    s, n = smp["s"], len(smp["s"])
    D = tp["columns_m"]
    # inside of bends: limit the terrain reach so offset rows never cross (curvature window ~ the terrain extent)
    win = max(1, int(tp.get("curvature_window_m", D[-1]) / route["sample_interval_m"]))
    kl = [max(0.0, max(smp["curvature"][max(0, i - win): i + win + 1])) for i in range(n)]   # left turns: left is inside
    kr = [max(0.0, -min(smp["curvature"][max(0, i - win): i + win + 1])) for i in range(n)]

    def reach(k, w):
        if k <= 0.0:
            return 1.0
        return min(1.0, max(tp["max_inner_reach_of_radius"] / k - w, D[1]) / D[-1])

    # Reject an impossible centreline/width contract before writing a partial package. A diagonal
    # change may triangulate a concave cell; reversing faces cannot repair a crossing corridor.
    road_rows = []
    for i in range(n):
        us = [-smp["width_right_m"][i],0.0,smp["width_left_m"][i]]
        road_rows.extend(_cross_section(smp,i,us,[smp["y"][i]]*3))
    road_indices = _grid_indices(n,3,positions=road_rows)
    corridors = RoadCorridors(road_rows, road_indices, [sv for sv in s for _ in range(3)])
    reaches = {}
    for side,ks,key in [(1,kl,"width_left_m"),(-1,kr,"width_right_m")]:
        proposed = [D[-1]*reach(k,w) for k,w in zip(ks,smp[key])]
        limits = _terrain_reach_limits(smp,side,proposed,tp["max_inner_reach_of_radius"])
        reaches[side] = limits

    envelopes = bank_envelopes(smp,reaches,tp["road_transition_m"],tp.get("road_max_bank_grade",.25)) if tp.get("road_transition_m",0)>0 else None
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
            idx = _grid_indices(len(rows), 3, keep=lambda r, st=st: smp["surface_type"][rows[r]] == st, positions=rpos)
            prims.append({"material": {"name": "road_" + st, "color": col, "roughness": rough}, "indices": idx})
        all_idx = [k for p in prims for k in p["indices"]]
        road = {"name": "road_" + tid, "translation": origin, "primitives": prims,
                "attributes": {"POSITION": [(p[0] - origin[0], p[1] - origin[1], p[2] - origin[2]) for p in rpos],
                               "NORMAL": _normals(rpos, all_idx), "TEXCOORD_0": ruv, "_ROUTE_S": rs, "_ROUTE_U": ru}}
        # --- terrain: one grid per side, columns from the road edge outward, edge vertex == road edge vertex
        tpos, ts, tu, tidx = [], [], [], []
        if tp.get("coastal_waterline_anchors", False):
            tpos, ts, tu, tidx, anchor_report = _terrain_grid_with_coastal_anchors(
                smp, rows, D, reaches, tp)
        else:
            # Keep the legacy grid construction unchanged unless the explicit opt-in is set.
            for side in (-1, 1):
                base = len(tpos)
                for i in rows:
                    w = smp["width_left_m"][i] if side > 0 else smp["width_right_m"][i]
                    sc = reaches[side][i] / D[-1]
                    ds = D if side > 0 else D[::-1]  # columns ordered by increasing u
                    us = [side * (w + d * sc) for d in ds]
                    lx, lz = rm.left_vector(smp["heading_deg"][i])
                    hs = []
                    for u, d in zip(us, ds):
                        x, z = smp["x"][i] + lx * u, smp["z"][i] + lz * u
                        dd = d * sc
                        height = (smp["y"][i] - tp["shoulder_drop_m"] * smoothstep(0.0, D[1], dd)
                                  + relief(x, z, tp) * smoothstep(tp["flat_band_m"], tp["blend_to_m"], dd))
                        profile = coast_profile(tp.get("coast_profiles", []), s[i], "left" if side > 0 else "right")
                        hs.append(coastal_height(height, smp["y"][i], w, u, profile))
                    for u, p in zip(us, _cross_section(smp, i, us, hs)):
                        tpos.append(p)
                        ts.append(s[i])
                        tu.append(u)
                tidx += _grid_indices(len(rows), len(D), base, positions=tpos)
        bank_report = {}
        if envelopes is not None:
            tidx,bank_report = conform_banks(tpos,ts,tu,tidx,envelopes,smp,origin)
        tidx, clip_report = clip_terrain(tpos,ts,tu,tidx,corridors,origin)
        ground, sand = [], []
        exact_sand = bool(tp.get("coastal_exact_sand_boundary",False))
        for k in range(0, len(tidx), 3):
            tri = tidx[k:k+3]
            sv, u = sum(ts[j] for j in tri)/3, sum(tu[j] for j in tri)/3
            profile = coast_profile(tp.get("coast_profiles", []), sv, "left" if u > 0 else "right")
            target = sand if (not exact_sand and coastal_sand(profile, u)) else ground
            target.extend(tri)
        terrain_prims = [{"material": TERRAIN_MATERIAL, "indices": ground}] if ground else []
        if sand:
            terrain_prims.append({"material": {"name": "shore_sand", "color": [0.68, 0.59, 0.39], "roughness": 0.95}, "indices": sand})
        terr = {"name": "terrain_" + tid, "translation": origin,
                "primitives": terrain_prims,
                "attributes": {"POSITION": [(p[0] - origin[0], p[1] - origin[1], p[2] - origin[2]) for p in tpos],
                               "NORMAL": _normals(tpos, tidx), "TEXCOORD_0": [(p[0], p[2]) for p in tpos],
                               "_ROUTE_S": ts, "_ROUTE_U": tu}}
        exact_sand_report = None
        if exact_sand:
            terr, exact_sand_report = _classify_coastal_sand_exact(
                terr, tp.get("coast_profiles",[]), s[i0], s[i1])
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
        tile_record = {
            "id": tid, "from_s": s[i0], "to_s": s[i1],
            "bounds": {"min": [round(min(p[k] for p in allp), 3) for k in range(3)],
                       "max": [round(max(p[k] for p in allp), 3) for k in range(3)]},
            "origin": origin, "terrain_clipping": clip_report, "bank_transition": bank_report,
            "files": {"road": f"tiles/{tid}/road.glb", "terrain": f"tiles/{tid}/terrain.glb"},
            "road": {"surfaces": ranges,
                     "width_left_m": [min(smp["width_left_m"][i] for i in rows), max(smp["width_left_m"][i] for i in rows)],
                     "width_right_m": [min(smp["width_right_m"][i] for i in rows), max(smp["width_right_m"][i] for i in rows)],
                     "grade_percent": [min(smp["grade_percent"][i] for i in rows), max(smp["grade_percent"][i] for i in rows)],
                     "rows": len(rows)},
        }
        if tp.get("coastal_waterline_anchors", False):
            tile_record["coastal_waterline_anchors"] = anchor_report
        if exact_sand_report is not None:
            tile_record["coastal_exact_sand_boundary"] = exact_sand_report
        tiles.append(tile_record)
    coastal_report=apply_coastal_ownership(pkg,tiles,smp,tp,corridors)
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
        **({"coastal_ownership": coastal_report} if coastal_report else {}),
        "vertex_attributes": {"_ROUTE_S": "route distance s of the vertex row (m)",
                              "_ROUTE_U": "lateral offset from the centreline (m, + left)",
                              "TEXCOORD_0": "road: (u, s) metres; terrain: world (x, z) metres"},
        "tiles": tiles,
    }
    if os.path.isfile(os.path.join(pkg, "acceptance.json")):
        manifest["acceptance"] = "acceptance.json"
    with open(os.path.join(pkg, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    return manifest


# ------------------------------------------------------------------ validation
def _tris(mesh):
    return [k for p in mesh["primitives"] for k in p["indices"]]


def _world(mesh):
    o = mesh["translation"]
    return [(p[0] + o[0], p[1] + o[1], p[2] + o[2]) for p in mesh["attributes"]["POSITION"]]


def _point_in_xz_triangle(x, z, tri, eps=1e-7):
    (ax, _, az), (bx, _, bz), (cx, _, cz) = tri
    den = (bz-cz)*(ax-cx) + (cx-bx)*(az-cz)
    if abs(den) < 1e-12:
        return False
    a = ((bz-cz)*(x-cx) + (cx-bx)*(z-cz)) / den
    b = ((cz-az)*(x-cx) + (ax-cx)*(z-cz)) / den
    c = 1-a-b
    return min(a, b, c) >= -eps


def reclassify_surface_materials(positions, primitives, regions, sand_material=None):
    """Reassign terrain triangles by centroid inside world-XZ owner triangles; positions/indices never change."""
    if not regions:
        return primitives, {"triangles_reclassified": 0}
    sand_material = sand_material or {"name":"shore_sand", "color":[0.68,0.59,0.39], "roughness":0.95}
    cell = 16.0
    region_grid = {}
    for region in regions:
        xs = [p[0] for p in region]; zs = [p[2] for p in region]
        for gx in range(math.floor(min(xs)/cell), math.floor(max(xs)/cell)+1):
            for gz in range(math.floor(min(zs)/cell), math.floor(max(zs)/cell)+1):
                region_grid.setdefault((gx,gz), []).append(region)
    source = []
    for primitive in primitives:
        material = primitive["material"]
        for k in range(0, len(primitive["indices"]), 3):
            tri = primitive["indices"][k:k+3]
            if len(tri) != 3:
                raise ValueError("terrain surface indices must be triangles")
            source.append((material, tri))
    groups = {}
    reassigned = 0
    for material, tri in source:
        target = material
        if material.get("name") in ("terrain_ground", "shore_sand"):
            x = sum(positions[i][0] for i in tri) / 3
            z = sum(positions[i][2] for i in tri) / 3
            candidates = region_grid.get((math.floor(x/cell), math.floor(z/cell)), ())
            if any(_point_in_xz_triangle(x, z, region) for region in candidates):
                target = sand_material
                reassigned += material != sand_material
        key = json.dumps(target, sort_keys=True, separators=(",", ":"))
        groups.setdefault(key, [target, []])[1].extend(tri)
    ordered = sorted(groups.values(), key=lambda group: (group[0].get("name") != "terrain_ground", group[0].get("name", "")))
    updated = [{"material": mat, "indices": idx} for mat, idx in ordered if idx]
    return updated, {"triangles_reclassified": int(reassigned)}


def _polygon_area2_xz(poly):
    if len(poly)<3:return 0.0
    origin=poly[0]
    return sum((poly[i][0]-origin[0])*(poly[i+1][1]-origin[1])-
               (poly[i][1]-origin[1])*(poly[i+1][0]-origin[0])
               for i in range(1,len(poly)-1))


def _clean_xz_polygon(poly, eps=0.0, collinear_eps=None):
    if not poly:
        return []
    if collinear_eps is None:collinear_eps=eps
    out=[]
    for point in poly:
        if not out or math.hypot(point[0]-out[-1][0],point[1]-out[-1][1]) > eps:
            out.append((float(point[0]),float(point[1])))
    if len(out)>1 and math.hypot(out[0][0]-out[-1][0],out[0][1]-out[-1][1]) <= eps:
        out.pop()
    changed=True
    while changed and len(out)>=3:
        changed=False
        for i in range(len(out)):
            a,b,c=out[i-1],out[i],out[(i+1)%len(out)]
            cross=(b[0]-a[0])*(c[1]-b[1])-(b[1]-a[1])*(c[0]-b[0])
            scale=max(1.0,math.hypot(b[0]-a[0],b[1]-a[1])+math.hypot(c[0]-b[0],c[1]-b[1]))
            if abs(cross) <= collinear_eps*scale:
                out.pop(i); changed=True; break
    return out if len(out)>=3 and _polygon_area2_xz(out)!=0.0 else []


def _clip_xz_halfplane(poly, a, b, orientation, keep_inside=True):
    """Clip a convex XZ polygon against one oriented line, retaining one closed half-plane."""
    if not poly:
        return []
    def distance(p):
        return orientation*((b[0]-a[0])*(p[1]-a[1])-(b[1]-a[1])*(p[0]-a[0]))
    result=[]
    prev=poly[-1]; dp=distance(prev)
    prev_in=dp>=0.0 if keep_inside else dp<=0.0
    for curr in poly:
        dc=distance(curr)
        curr_in=dc>=0.0 if keep_inside else dc<=0.0
        if curr_in != prev_in:
            den=dp-dc
            if abs(den)>1e-15:
                t=max(0.0,min(1.0,dp/den))
                result.append((prev[0]+t*(curr[0]-prev[0]),prev[1]+t*(curr[1]-prev[1])))
        if curr_in:
            result.append(curr)
        prev,dp,prev_in=curr,dc,curr_in
    return _clean_xz_polygon(result)


def _subtract_convex_xz(poly, clip_triangle):
    """Return disjoint convex polygons for P\triangle and P∩triangle."""
    orientation=1.0 if _polygon_area2_xz(clip_triangle)>0 else -1.0
    inside=poly
    outside=[]
    for i in range(3):
        a,b=clip_triangle[i],clip_triangle[(i+1)%3]
        rejected=_clip_xz_halfplane(inside,a,b,orientation,False)
        if rejected:
            outside.append(rejected)
        inside=_clip_xz_halfplane(inside,a,b,orientation,True)
        if not inside:
            break
    return outside,inside


def _triangulate_xz(poly):
    cleaned=_clean_xz_polygon(poly,eps=1e-12,collinear_eps=0.0)
    if len(cleaned)<3:return []
    def cross(a,b,c):
        return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
    orientation=1.0 if _polygon_area2_xz(cleaned)>0 else -1.0
    remaining=list(range(len(cleaned))); triangles=[]
    while len(remaining)>3:
        ear=None
        for q,index in enumerate(remaining):
            prev=remaining[q-1];nxt=remaining[(q+1)%len(remaining)]
            a,b,c=cleaned[prev],cleaned[index],cleaned[nxt]
            if orientation*cross(a,b,c)<=0.0:continue
            contains=False
            for other in remaining:
                if other in (prev,index,nxt):continue
                p=cleaned[other]
                ca=orientation*cross(a,b,p);cb=orientation*cross(b,c,p);cc=orientation*cross(c,a,p)
                if ca>0.0 and cb>0.0 and cc>0.0:
                    contains=True;break
            if not contains:
                ear=(q,(a,b,c));break
        if ear is None:
            raise ValueError(f"cannot triangulate clipped terrain polygon without changing coverage: area2={_polygon_area2_xz([cleaned[i] for i in remaining])}, remaining={[cleaned[i] for i in remaining]}")
        q,triangle=ear;triangles.append(triangle);remaining.pop(q)
    final=tuple(cleaned[i] for i in remaining)
    if orientation*cross(*final)>0.0:triangles.append(final)
    return [tri for tri in triangles if cross(*tri)!=0.0]


def _clip_route_scalar(poly, axis, bound, keep_greater):
    if not poly:
        return []
    result=[]
    prev=poly[-1]; dp=prev[axis]-bound
    prev_in=dp>=-1e-10 if keep_greater else dp<=1e-10
    for curr in poly:
        dc=curr[axis]-bound
        curr_in=dc>=-1e-10 if keep_greater else dc<=1e-10
        if curr_in != prev_in:
            den=dp-dc
            if abs(den)>1e-15:
                t=max(0.0,min(1.0,dp/den))
                result.append(tuple(prev[j]+t*(curr[j]-prev[j]) for j in range(len(prev))))
        if curr_in:
            result.append(curr)
        prev,dp,prev_in=curr,dc,curr_in
    # De-duplicate in route coordinates; world coords are interpolated by the same barycentric parameter.
    out=[]
    for point in result:
        if not out or abs(point[0]-out[-1][0])>1e-8 or abs(point[1]-out[-1][1])>1e-8:
            out.append(point)
    if len(out)>1 and abs(out[0][0]-out[-1][0])<=1e-8 and abs(out[0][1]-out[-1][1])<=1e-8:
        out.pop()
    return out if len(out)>=3 else []


def _owner_region_triangles_exact(owners, from_s, to_s, lateral_min, lateral_max):
    """Clip owner faces in (s,u), then triangulate their exact projected XZ mask."""
    regions=[]; owner_count=0
    for _,mesh,world in owners:
        attrs=mesh["attributes"]
        ss,uu=attrs["_ROUTE_S"],attrs["_ROUTE_U"]
        for primitive in mesh["primitives"]:
            ids=primitive["indices"]
            for k in range(0,len(ids),3):
                tri=ids[k:k+3]
                poly=[(ss[i],uu[i],world[i][0],world[i][2]) for i in tri]
                for axis,bound,greater in ((0,from_s,True),(0,to_s,False),
                                           (1,lateral_min,True),(1,lateral_max,False)):
                    poly=_clip_route_scalar(poly,axis,bound,greater)
                    if not poly: break
                if not poly: continue
                mask_poly=[(v[2],v[3]) for v in poly]
                clipped=_triangulate_xz(mask_poly)
                if clipped:
                    owner_count+=1
                    regions.extend([(a[0],0.0,a[1]),(b[0],0.0,b[1]),(c[0],0.0,c[1])] for a,b,c in clipped)
    return regions,owner_count


def _barycentric_xz(x,z,tri):
    (ax,_,az),(bx,_,bz),(cx,_,cz)=tri
    den=(bz-cz)*(ax-cx)+(cx-bx)*(az-cz)
    if abs(den)<1e-14:
        raise ValueError("cannot interpolate a terrain face with degenerate XZ projection")
    a=((bz-cz)*(x-cx)+(cx-bx)*(z-cz))/den
    b=((cz-az)*(x-cx)+(ax-cx)*(z-cz))/den
    return (a,b,1-a-b)


def _interpolate_attribute(values, tri_indices, bary):
    samples=[values[i] for i in tri_indices]
    if isinstance(samples[0],(list,tuple)):
        return tuple(sum(bary[j]*samples[j][c] for j in range(3)) for c in range(len(samples[0])))
    return sum(bary[j]*samples[j] for j in range(3))


def _triangle_bbox_overlaps(poly, tri, eps=1e-8):
    return (max(p[0] for p in poly)>=min(p[0] for p in tri)-eps and
            min(p[0] for p in poly)<=max(p[0] for p in tri)+eps and
            max(p[1] for p in poly)>=min(p[1] for p in tri)-eps and
            min(p[1] for p in poly)<=max(p[1] for p in tri)+eps)


def _validate_land_infill_authoring(authoring):
    """Validate a deliberately explicit, estimated-land postprocess contract."""
    if not isinstance(authoring,dict) or authoring.get("schema_version")!=1:
        raise ValueError("land infill authoring must use schema_version 1")
    if authoring.get("estimated") is not True:
        raise ValueError("land infill requires an explicit estimated=true provenance")
    provenance=authoring.get("provenance")
    if not isinstance(provenance,dict) or provenance.get("status")!="estimated" or not provenance.get("source") or not provenance.get("rationale"):
        raise ValueError("land infill provenance requires estimated status, source, and rationale")
    target=str(authoring.get("target_tile_id",""))
    if not target: raise ValueError("land infill target_tile_id is required")
    rule=authoring.get("height_rule")
    if not isinstance(rule,dict) or rule.get("kind")!="boundary_supported_idw":
        raise ValueError("land infill height_rule must be boundary_supported_idw")
    neighbors=rule.get("neighbors")
    if not isinstance(neighbors,int) or neighbors<1 or neighbors>8:
        raise ValueError("land infill height_rule neighbors must be an integer from 1 to 8")
    max_distance=float(rule.get("max_estimated_support_distance_m",0.0))
    edge_spacing=float(rule.get("support_edge_sample_spacing_m",0.0))
    max_mismatch=float(rule.get("max_boundary_mismatch_m",0.0))
    support_chart=rule.get("terrain_support_chart")
    if support_chart is not None:
        if not isinstance(support_chart,dict) or support_chart.get("kind")!="canonical_route_local":
            raise ValueError("terrain_support_chart kind must be canonical_route_local")
        station_window=float(support_chart.get("station_window_m",float("nan")))
        lateral_window=float(support_chart.get("lateral_window_m",float("nan")))
        branch_separation=float(support_chart.get("distinct_branch_station_separation_m",float("nan")))
        branch_ambiguity=float(support_chart.get("branch_ambiguity_distance_m",float("nan")))
        if not math.isfinite(station_window) or not 0<station_window<=1.0:
            raise ValueError("terrain support chart station window must be in (0, 1.0] m")
        if not math.isfinite(lateral_window) or not 0<lateral_window<=0.05:
            raise ValueError("terrain support chart lateral window must be in (0, 0.05] m")
        if not math.isfinite(branch_separation) or branch_separation<5.0:
            raise ValueError("terrain support chart distinct branch separation must be at least 5 m")
        if not math.isfinite(branch_ambiguity) or not 0<branch_ambiguity<=0.02:
            raise ValueError("terrain support chart branch ambiguity distance must be in (0, 0.02] m")
        if max_mismatch>0.002:
            raise ValueError("route-coherent terrain support cannot relax the existing 2 mm selected-owner mismatch limit")
    foreign_fallback=rule.get("foreign_fallback_owner_ids",[])
    if not isinstance(foreign_fallback,list) or any(not str(owner) for owner in foreign_fallback):
        raise ValueError("land infill foreign_fallback_owner_ids must be a list of non-empty tile ids")
    if len(set(map(str,foreign_fallback)))!=len(foreign_fallback) or target in set(map(str,foreign_fallback)):
        raise ValueError("land infill foreign fallback tile ids must be unique and exclude target_tile_id")
    chart=authoring.get("route_attribute_chart")
    if chart is not None:
        if not isinstance(chart,dict) or chart.get("kind")!="target_road_affine":
            raise ValueError("route_attribute_chart kind must be target_road_affine")
        chart_distance=float(chart.get("max_distance_m",0.0))
        if not math.isfinite(chart_distance) or not 0.0<chart_distance<=0.02:
            raise ValueError("target_road_affine max_distance_m must be finite and in (0, 0.02]")
    if not math.isfinite(max_distance) or max_distance<=0 or not math.isfinite(max_mismatch) or max_mismatch<=0:
        raise ValueError("land infill height tolerances must be finite positive metres")
    if not math.isfinite(edge_spacing) or edge_spacing<0.0 or edge_spacing>max_distance:
        raise ValueError("land infill support_edge_sample_spacing_m must be finite and between 0 and max_estimated_support_distance_m")
    material=authoring.get("material")
    if not isinstance(material,dict) or not material.get("name") or len(material.get("color",[]))!=3:
        raise ValueError("land infill material requires name and RGB color")
    if not math.isfinite(float(material.get("roughness",float("nan")))):
        raise ValueError("land infill roughness must be finite")
    regions=authoring.get("regions")
    if not isinstance(regions,list) or not regions:
        raise ValueError("land infill requires at least one bounded region")
    seen=set()
    for region in regions:
        if not isinstance(region,dict) or not region.get("id") or region["id"] in seen:
            raise ValueError("land infill regions require unique ids")
        seen.add(region["id"])
        coverage_owners=region.get("terrain_coverage_owner_ids")
        if coverage_owners is not None and (not isinstance(coverage_owners,list) or not coverage_owners or
                any(not str(owner) for owner in coverage_owners) or
                len(set(map(str,coverage_owners)))!=len(coverage_owners)):
            raise ValueError(f"land infill region {region['id']} terrain_coverage_owner_ids must be a non-empty unique owner list")
        support_policy=rule.get("support_owner_policy")
        if coverage_owners is not None and support_policy!={"terrain":"terrain_coverage_owner_ids","road":"all_package_p0","foreign_terrain":"excluded"}:
            raise ValueError("selected terrain coverage requires explicit selected-P1/all-P0 support_owner_policy")
        poly=region.get("polygon_xz")
        if not isinstance(poly,list) or len(poly)<3:
            raise ValueError(f"land infill region {region['id']} needs a polygon_xz")
        points=[]
        for point in poly:
            if not isinstance(point,list) or len(point)!=2 or not all(math.isfinite(float(v)) for v in point):
                raise ValueError(f"land infill region {region['id']} has non-finite XZ coordinates")
            points.append((float(point[0]),float(point[1])))
        area2=_polygon_area2_xz(points)
        if area2==0.0: raise ValueError(f"land infill region {region['id']} has zero area")
        sign=1.0 if area2>0 else -1.0
        turns=[sign*((points[(i+1)%len(points)][0]-points[i][0])*(points[(i+2)%len(points)][1]-points[(i+1)%len(points)][1])-
                     (points[(i+1)%len(points)][1]-points[i][1])*(points[(i+2)%len(points)][0]-points[(i+1)%len(points)][0]))
               for i in range(len(points))]
        if any(turn< -1e-10 for turn in turns):
            raise ValueError(f"land infill region {region['id']} must be convex")
    return target,rule,material,regions


def _land_infill_triangles(pkg,manifest,layer,bounds,center):
    """Read serialized P1/P0 faces intersecting an ROI; keep triangle-level, not tile-level, bounds."""
    x0,x1,z0,z1=bounds;cx,cz=center;triangles=[];files=[]
    for tile in manifest.get("tiles",[]):
        rel=tile.get("files",{}).get(layer)
        if not rel: continue
        path=os.path.join(pkg,rel)
        if not os.path.isfile(path): continue
        mesh=read_glb(path);world=_world(mesh);attrs=mesh["attributes"]
        for pi,primitive in enumerate(mesh["primitives"]):
            ids=primitive["indices"]
            for k in range(0,len(ids),3):
                indices=ids[k:k+3];points=[world[i] for i in indices]
                if (max(p[0] for p in points)<x0 or min(p[0] for p in points)>x1 or
                    max(p[2] for p in points)<z0 or min(p[2] for p in points)>z1): continue
                xz=[(float(p[0]-cx),float(p[2]-cz)) for p in points]
                if _polygon_area2_xz(xz)==0.0: continue
                triangles.append({"xz":xz,"y":[float(p[1]) for p in points],
                    "attributes":{name:[attrs[name][i] for i in indices] for name in attrs},
                    "owner":str(tile["id"]),"layer":layer,"primitive":pi,"triangle":k//3,
                    "material":primitive["material"]})
        files.append({"tile":str(tile["id"]),"path":rel,"sha256":_sha256_file(path)})
    return triangles,files


def _land_infill_subtract(polygons,triangles):
    remaining=list(polygons);removed=0.0;intersections=0
    for triangle in triangles:
        clip=triangle["xz"];cx0=min(p[0] for p in clip);cx1=max(p[0] for p in clip)
        cz0=min(p[1] for p in clip);cz1=max(p[1] for p in clip);updated=[]
        for poly in remaining:
            if (max(p[0] for p in poly)<cx0 or min(p[0] for p in poly)>cx1 or
                max(p[1] for p in poly)<cz0 or min(p[1] for p in poly)>cz1):
                updated.append(poly);continue
            outside,inside=_subtract_convex_xz(poly,clip);intersections+=1
            removed+=abs(_polygon_area2_xz(inside))*0.5
            updated.extend(outside)
        remaining=updated
    return remaining,{"triangle_polygon_intersections":intersections,"covered_area_m2":removed,
                      "remaining_piece_count":len(remaining),"discarded_area_m2":0.0}


def _land_infill_hits(point,triangles,tolerance=2e-6):
    x,z=point;hits=[]
    for triangle in triangles:
        a,b,c=triangle["xz"]
        if x<min(a[0],b[0],c[0])-tolerance or x>max(a[0],b[0],c[0])+tolerance or z<min(a[1],b[1],c[1])-tolerance or z>max(a[1],b[1],c[1])+tolerance:
            continue
        try:bary=_barycentric_xz(x,z,[(a[0],0,a[1]),(b[0],0,b[1]),(c[0],0,c[1])])
        except ValueError:continue
        if min(bary)>=-tolerance:
            y=sum(bary[i]*triangle["y"][i] for i in range(3))
            hits.append({"height":y,"bary":bary,"triangle":triangle})
    return hits


def _land_infill_route_projection(x,z,route,target_tile):
    samples=route["samples"];stations=samples["s"];lo=float(target_tile["from_s"]);hi=float(target_tile["to_s"])
    best=None
    for i in range(len(stations)-1):
        s0,s1=float(stations[i]),float(stations[i+1])
        if s1<lo-1e-8 or s0>hi+1e-8:continue
        ax,az=float(samples["x"][i]),float(samples["z"][i]);bx,bz=float(samples["x"][i+1]),float(samples["z"][i+1])
        dx,dz=bx-ax,bz-az;den=dx*dx+dz*dz
        if den<=0:continue
        t=max(0.0,min(1.0,((x-ax)*dx+(z-az)*dz)/den));px,pz=ax+t*dx,az+t*dz
        dist2=(x-px)**2+(z-pz)**2;s=s0+t*(s1-s0)
        rank=(dist2,abs(s-(lo+hi)*0.5))
        if best is None or rank<best[0]:
            length=math.sqrt(den);u=((x-px)*dz-(z-pz)*dx)/length
            best=(rank,s,u)
    if best is None:raise ValueError("cannot project land infill vertices onto target tile route")
    return best[1],best[2],math.sqrt(best[0][0])


def _land_infill_select_route_coherent_hits(point,hits,route,target_tile,config):
    """Select P1 support faces on the target visit's canonical route chart.

    The chart is evaluated at the unchanged world XZ using each serialized face's
    barycentric route attributes. A separated route pass may not win by triangle
    order: near-equal centerline distances are an explicit ambiguity error.
    """
    x,z=map(float,point);origin=target_tile.get("origin",[0.0,0.0,0.0])
    world_x=x+float(origin[0]);world_z=z+float(origin[2])
    ref_s,ref_u,ref_distance=_land_infill_route_projection(world_x,world_z,route,target_tile)
    samples=route["samples"];stations=list(map(float,samples["s"]))
    branch_separation=float(config["distinct_branch_station_separation_m"])
    branch_ambiguity=float(config["branch_ambiguity_distance_m"])
    distinct=[]
    for i in range(len(stations)-1):
        s0,s1=stations[i],stations[i+1]
        if s1<float(target_tile["from_s"])-1e-8 or s0>float(target_tile["to_s"])+1e-8:continue
        ax,az=float(samples["x"][i]),float(samples["z"][i])
        bx,bz=float(samples["x"][i+1]),float(samples["z"][i+1])
        dx,dz=bx-ax,bz-az;den=dx*dx+dz*dz
        if den<=0.0:continue
        t=max(0.0,min(1.0,((world_x-ax)*dx+(world_z-az)*dz)/den))
        px,pz=ax+t*dx,az+t*dz
        station=s0+t*(s1-s0)
        if abs(station-ref_s)<branch_separation:continue
        distinct.append((math.hypot(world_x-px,world_z-pz),station))
    nearest_distinct=min(distinct,key=lambda row:row[0]) if distinct else None
    branch_delta=None if nearest_distinct is None else nearest_distinct[0]-ref_distance
    if branch_delta is not None and branch_delta<=branch_ambiguity:
        raise ValueError(f"ambiguous distinct route branches at {point}: nearest branch distance delta {branch_delta:.9g}m")
    selected=[];candidate_rows=[]
    for hit in hits:
        triangle=hit["triangle"];bary=hit["bary"];attrs=triangle.get("attributes",{})
        if "_ROUTE_S" not in attrs or "_ROUTE_U" not in attrs:
            raise ValueError("route-coherent terrain support requires serialized _ROUTE_S/_ROUTE_U face attributes")
        s=sum(float(bary[i])*float(attrs["_ROUTE_S"][i]) for i in range(3))
        u=sum(float(bary[i])*float(attrs["_ROUTE_U"][i]) for i in range(3))
        ds=s-ref_s;du=u-ref_u
        row={"owner":triangle.get("owner"),"triangle":triangle.get("triangle"),
             "s_m":s,"u_m":u,"height_m":float(hit["height"]),"delta_s_m":ds,"delta_u_m":du}
        candidate_rows.append(row)
        if abs(ds)<=float(config["station_window_m"]) and abs(du)<=float(config["lateral_window_m"]):
            selected.append(hit)
    if not selected:
        diagnostics={"reference_s_m":ref_s,"reference_u_m":ref_u,"reference_centerline_distance_m":ref_distance,
            "nearest_distinct_branch_station_m":None if nearest_distinct is None else nearest_distinct[1],
            "nearest_distinct_branch_distance_m":None if nearest_distinct is None else nearest_distinct[0],
            "nearest_distinct_branch_distance_delta_m":branch_delta,"selected_height_spread_m":None,
            "candidate_faces":candidate_rows}
        if config.get("_allow_no_match"):
            return [],diagnostics
        raise ValueError(f"no terrain support face matches canonical route chart at {point}: reference S/U=({ref_s:.6f},{ref_u:.6f})")
    spread=max(float(hit["height"]) for hit in selected)-min(float(hit["height"]) for hit in selected)
    max_spread=float(config["max_selected_owner_spread_m"])
    if spread>max_spread:
        raise ValueError(f"selected-owner support spread {spread:.9g}m exceeds {max_spread}m on canonical route chart at {point}")
    return selected,{"reference_s_m":ref_s,"reference_u_m":ref_u,"reference_centerline_distance_m":ref_distance,
        "nearest_distinct_branch_station_m":None if nearest_distinct is None else nearest_distinct[1],
        "nearest_distinct_branch_distance_m":None if nearest_distinct is None else nearest_distinct[0],
        "nearest_distinct_branch_distance_delta_m":branch_delta,"selected_height_spread_m":spread,
        "candidate_faces":candidate_rows}


def _closest_xz_triangle_point(x,z,triangle):
    """Return the closest point and distance on a triangle's projected XZ footprint."""
    a=(triangle[0][0],triangle[0][2]);b=(triangle[1][0],triangle[1][2]);c=(triangle[2][0],triangle[2][2])
    candidates=[]
    bary=_barycentric_xz(x,z,triangle)
    if min(bary)>=0.0:
        return (x,z),0.0
    for p,q,weights in ((a,b,(0,1)),(b,c,(1,2)),(c,a,(2,0))):
        dx=q[0]-p[0];dz=q[1]-p[1];den=dx*dx+dz*dz
        t=0.0 if den==0.0 else max(0.0,min(1.0,((x-p[0])*dx+(z-p[1])*dz)/den))
        px=p[0]+t*dx;pz=p[1]+t*dz
        candidates.append(((x-px)**2+(z-pz)**2,px,pz))
    d2,px,pz=min(candidates)
    return (px,pz),math.sqrt(d2)


def _apply_near_road_affine_chart(terrain,road,start_vertex,max_distance_m=0.02):
    """Replace only appended terrain S/U using the target road's affine face chart.

    Positions and all attributes other than appended _ROUTE_S/_ROUTE_U stay intact.
    The distance test uses the actual world-XZ point against target-road faces;
    barycentrics are then evaluated at that original point, without snapping/clamping.
    """
    if not isinstance(max_distance_m,(int,float)) or not math.isfinite(max_distance_m) or not 0.0<max_distance_m<=0.02:
        raise ValueError("target-road affine chart max_distance_m must be in (0, 0.02]")
    ta=terrain.get("attributes",{});ra=road.get("attributes",{})
    needed=("POSITION","_ROUTE_S","_ROUTE_U")
    if any(key not in ta for key in needed) or any(key not in ra for key in needed):
        raise ValueError("target-road affine chart requires POSITION and _ROUTE_S/_ROUTE_U")
    t_origin=terrain.get("translation",[0.0,0.0,0.0]);r_origin=road.get("translation",[0.0,0.0,0.0])
    r_world=[(p[0]+r_origin[0],p[1]+r_origin[1],p[2]+r_origin[2]) for p in ra["POSITION"]]
    faces=[]
    for prim_index,primitive in enumerate(road.get("primitives",[])):
        ids=primitive.get("indices",[])
        for offset in range(0,len(ids),3):
            face=tuple(ids[offset:offset+3])
            if len(face)!=3:continue
            tri=[r_world[i] for i in face]
            try:_barycentric_xz(*((tri[0][0]+tri[1][0]+tri[2][0])/3.0,(tri[0][2]+tri[1][2]+tri[2][2])/3.0),tri)
            except ValueError:continue
            faces.append((tri,face,prim_index,offset//3))
    if not faces:raise ValueError("target-road affine chart has no nondegenerate projected faces")
    changed=0;max_distance=0.0;face_ids=[]
    for index in range(max(0,int(start_vertex)),len(ta["POSITION"])):
        p=ta["POSITION"][index];x=p[0]+t_origin[0];z=p[2]+t_origin[2]
        choices=[]
        for tri,ids,prim_index,face_index in faces:
            _,distance=_closest_xz_triangle_point(x,z,tri)
            if distance>max_distance_m:continue
            try:bary=_barycentric_xz(x,z,tri)
            except ValueError:continue
            s=sum(bary[j]*ra["_ROUTE_S"][ids[j]] for j in range(3))
            u=sum(bary[j]*ra["_ROUTE_U"][ids[j]] for j in range(3))
            old_s=float(ta["_ROUTE_S"][index])
            choices.append((distance,abs(s-old_s),prim_index,face_index,s,u))
        if not choices:continue
        chosen=min(choices)
        ta["_ROUTE_S"][index]=chosen[4];ta["_ROUTE_U"][index]=chosen[5]
        max_distance=max(max_distance,chosen[0]);face_ids.append([chosen[2],chosen[3]]);changed+=1
    return {"changed_vertex_count":changed,"max_face_distance_m":max_distance,
            "max_distance_m":max_distance_m,"selected_road_faces":face_ids,
            "policy":"unrestricted affine barycentrics at original world XZ; closest target-owner face within explicit bound"}


def _land_infill_edge_support_samples(support_triangles,spacing_m,max_height_mismatch_m):
    """Interpolate support samples along serialized face edges, without changing meshes."""
    if spacing_m<=0.0:return [],{"derived_sample_count":0,"source_triangle_count":len(support_triangles),"max_sample_segment_m":0.0,"sample_count_by_owner_layer":{}}
    original_rows={};edge_rows={};max_segment=0.0;counts={}
    for triangle in support_triangles:
        attrs=triangle.get("attributes",{});ss=attrs.get("_ROUTE_S",[0.0,0.0,0.0]);uu=attrs.get("_ROUTE_U",[0.0,0.0,0.0])
        for i,point in enumerate(triangle["xz"]):
            key=(triangle["owner"],triangle["layer"],tuple(point),float(ss[i]),float(uu[i]))
            original_rows.setdefault(key,[]).append(float(triangle["y"][i]))
    for triangle in support_triangles:
        attrs=triangle.get("attributes",{});ss=attrs.get("_ROUTE_S",[0.0,0.0,0.0]);uu=attrs.get("_ROUTE_U",[0.0,0.0,0.0])
        for a,b in ((0,1),(1,2),(2,0)):
            endpoints=[]
            for index in (a,b):
                endpoints.append((tuple(triangle["xz"][index]),float(triangle["y"][index]),float(ss[index]),float(uu[index])))
            first,second=sorted(endpoints,key=lambda endpoint:(endpoint[0],endpoint[2],endpoint[3],endpoint[1]))
            p0,y0,s0,u0=first;p1,y1,s1,u1=second
            length=math.hypot(p1[0]-p0[0],p1[1]-p0[1])
            if length<=0.0:continue
            segments=max(1,int(math.ceil(length/spacing_m)))
            max_segment=max(max_segment,length/segments)
            for step in range(1,segments):
                fraction=step/segments
                point=(p0[0]+fraction*(p1[0]-p0[0]),p0[1]+fraction*(p1[1]-p0[1]))
                y=y0+fraction*(y1-y0);s=s0+fraction*(s1-s0);u=u0+fraction*(u1-u0)
                key=(triangle["owner"],triangle["layer"],point,s,u)
                original_key=(triangle["owner"],triangle["layer"],point,s,u)
                if original_key in original_rows:
                    source_heights=original_rows[original_key]
                    if max(max(source_heights),y)-min(min(source_heights),y)>max_height_mismatch_m:
                        raise ValueError(f"land infill same-chart edge support height mismatch exceeds {max_height_mismatch_m}m at {point}")
                    continue
                values=edge_rows.setdefault(key,[])
                if values and max(max(row[1] for row in values),y)-min(min(row[1] for row in values),y)>max_height_mismatch_m:
                    raise ValueError(f"land infill same-chart edge support height mismatch exceeds {max_height_mismatch_m}m at {point}")
                values.append((point,y,triangle["owner"],triangle["layer"],s,u))
    samples=[]
    for key,rows in edge_rows.items():
        # A shared edge is visited from both adjacent faces. Keep one support
        # record per chart sample after checking the duplicate heights above.
        samples.append(min(rows,key=lambda row:(row[1],row[2],row[3],row[4],row[5])))
        owner,layer=key[:2];count_key=f"{owner}:{layer}";counts[count_key]=counts.get(count_key,0)+1
    return samples,{"derived_sample_count":len(edge_rows),"source_triangle_count":len(support_triangles),
        "max_sample_segment_m":max_segment,"sample_count_by_owner_layer":counts}


def _append_land_infill(mesh,polygons_xz,center,support_triangles,route,target_tile,rule,material):
    """Append estimated terrain over precomputed centered XZ complements; originals remain an exact prefix."""
    required={"POSITION","NORMAL","TEXCOORD_0","_ROUTE_S","_ROUTE_U"}
    if set(mesh["attributes"])!=required:
        raise ValueError("land infill currently supports terrain POSITION/NORMAL/TEXCOORD_0/_ROUTE_S/_ROUTE_U attributes")
    target_origin=mesh.get("translation",[0.0,0.0,0.0]);cx,cz=center
    vertex_map={};positions=[];indices=[];projected=[];supported_heights=[];estimated_heights=[]
    point_cache={};support_samples=[];support_owner_counts={};support_owner_layer_counts={};fallback_foreign_owner_counts={}
    route_chart=rule.get("_terrain_support_chart");route_chart_diagnostics=[];route_chart_filtered_hits=0
    edge_spacing=float(rule.get("support_edge_sample_spacing_m",0.0))
    route_chart_unambiguous_count=0;route_chart_unambiguous_max_delta_s=0.0;route_chart_unambiguous_max_delta_u=0.0
    for triangle in support_triangles:
        for i,point in enumerate(triangle["xz"]):
            attrs=triangle.get("attributes",{})
            s=float(attrs.get("_ROUTE_S",[0.0,0.0,0.0])[i]);u=float(attrs.get("_ROUTE_U",[0.0,0.0,0.0])[i])
            key=(point[0],point[1]);support_samples.append((key,float(triangle["y"][i]),triangle["owner"],triangle["layer"],s,u))
    edge_samples,edge_sample_report=_land_infill_edge_support_samples(
        support_triangles,edge_spacing,float(rule["max_boundary_mismatch_m"]))
    for point,y,owner,layer,s,u in edge_samples:
        support_samples.append((point,y,owner,layer,s,u))
    unique_samples={}
    for point,y,owner,layer,s,u in support_samples:
        key=(owner,layer,point,s,u) if route_chart or edge_spacing>0.0 else (owner,layer,point)
        unique_samples.setdefault(key,[]).append((y,s,u))
    support_samples=[]
    for key,rows in unique_samples.items():
        owner,layer,point=key[:3];ys=[row[0] for row in rows]
        support_samples.append((owner,layer,point,sum(ys)/len(ys),max(ys)-min(ys),
            sum(row[1] for row in rows)/len(rows),sum(row[2] for row in rows)/len(rows)))
    neighbors=int(rule["neighbors"]);max_distance=float(rule["max_estimated_support_distance_m"])
    max_mismatch=float(rule["max_boundary_mismatch_m"]);max_spread=0.0;max_owner_spread=0.0
    max_cross_owner_spread=0.0;max_estimated_distance=0.0;min_estimated_neighbor_count=None;target_owner=str(target_tile["id"])
    def attributes_for(point):
        nonlocal max_spread,max_owner_spread,max_cross_owner_spread,max_estimated_distance,min_estimated_neighbor_count,route_chart_filtered_hits
        nonlocal route_chart_unambiguous_count,route_chart_unambiguous_max_delta_s,route_chart_unambiguous_max_delta_u
        cached=point_cache.get(point)
        if cached is not None:return cached
        hits=_land_infill_hits(point,support_triangles)
        if hits:
            diagnostic_hits=hits
            if "_terrain_support_owner_ids" in rule:
                terrain_hits=[hit for hit in hits if hit["triangle"]["layer"]=="terrain" and
                              hit["triangle"]["owner"] in set(rule["_terrain_support_owner_ids"])]
                road_hits=[hit for hit in hits if hit["triangle"]["layer"]=="road"]
                if route_chart and terrain_hits:
                    terrain_groups={}
                    for hit in terrain_hits:
                        tr=hit["triangle"];terrain_groups.setdefault((tr["owner"],tr["layer"]),[]).append(hit)
                    conflicting=any(max(h["height"] for h in group)-min(h["height"] for h in group)>max_mismatch
                                    for group in terrain_groups.values())
                    if conflicting:
                        chart_config={**route_chart,"max_selected_owner_spread_m":max_mismatch,
                                      "_allow_no_match":bool(road_hits)}
                        coherent_hits,chart_diag=_land_infill_select_route_coherent_hits(
                            point,terrain_hits,route,target_tile,chart_config)
                        route_chart_diagnostics.append(chart_diag)
                        route_chart_filtered_hits+=len(terrain_hits)-len(coherent_hits)
                        eligible_hits=coherent_hits+road_hits
                        if not eligible_hits:
                            raise ValueError(f"no selected terrain support face matches canonical route chart and no P0 support exists at {point}")
                    else:
                        # A unique or already-consistent surface is the actual local
                        # boundary support. Keep its authored height; chart offsets
                        # are diagnostics and do not trigger an IDW replacement.
                        for hit in terrain_hits:
                            tr=hit["triangle"];bary=hit["bary"];attrs=tr.get("attributes",{})
                            hs=sum(float(bary[i])*float(attrs["_ROUTE_S"][i]) for i in range(3))
                            hu=sum(float(bary[i])*float(attrs["_ROUTE_U"][i]) for i in range(3))
                            rs,ru,_=_land_infill_route_projection(point[0]+cx,point[1]+cz,route,target_tile)
                            route_chart_unambiguous_count+=1
                            route_chart_unambiguous_max_delta_s=max(route_chart_unambiguous_max_delta_s,abs(hs-rs))
                            route_chart_unambiguous_max_delta_u=max(route_chart_unambiguous_max_delta_u,abs(hu-ru))
                        eligible_hits=terrain_hits+road_hits
                else:
                    eligible_hits=terrain_hits+road_hits
            else:
                allowed_owners={target_owner}|set(map(str,rule.get("foreign_fallback_owner_ids",[])))
                eligible_hits=[hit for hit in hits if hit["triangle"]["owner"] in allowed_owners]
        else:
            diagnostic_hits=[];eligible_hits=[]
        if eligible_hits:
            # Prefer current tile P0 at a road boundary, then current tile P1, then other P1/P0.
            def priority(hit):
                tr=hit["triangle"];target=str(target_tile["id"])
                category=(0 if tr["layer"]=="road" and tr["owner"]==target else
                          1 if tr["layer"]=="terrain" and tr["owner"]==target else
                          2 if tr["layer"]=="terrain" else 3)
                # In an overlapping same-owner surface, select the visible/topmost
                # surface deterministically; primitive/triangle order is only a tie-break.
                return (category,tr["owner"],tr["layer"],-hit["height"],tr["primitive"],tr["triangle"])
            eligible_hits.sort(key=priority);best=eligible_hits[0]
            group=[h for h in eligible_hits if h["triangle"]["owner"]==best["triangle"]["owner"]
                   and h["triangle"]["layer"]==best["triangle"]["layer"]]
            owner_spread=max(h["height"] for h in group)-min(h["height"] for h in group)
            owner_means={owner:sum(h["height"] for h in diagnostic_hits if h["triangle"]["owner"]==owner)/
                         sum(h["triangle"]["owner"]==owner for h in diagnostic_hits)
                         for owner in {h["triangle"]["owner"] for h in diagnostic_hits}}
            cross_spread=max(owner_means.values())-min(owner_means.values())
            max_spread=max(max_spread,max(h["height"] for h in diagnostic_hits)-min(h["height"] for h in diagnostic_hits))
            max_owner_spread=max(max_owner_spread,owner_spread);max_cross_owner_spread=max(max_cross_owner_spread,cross_spread)
            if owner_spread>max_mismatch:
                sources=[{"owner":h["triangle"]["owner"],"layer":h["triangle"]["layer"],
                          "triangle":h["triangle"]["triangle"],"height_y_m":h["height"]} for h in group]
                raise ValueError(f"land infill selected-owner support spread {owner_spread:.9g}m exceeds {max_mismatch}m at {point}: {sources}")
            if best["triangle"]["owner"]!=target_owner and cross_spread>max_mismatch:
                sources=[{"owner":h["triangle"]["owner"],"layer":h["triangle"]["layer"],
                          "triangle":h["triangle"]["triangle"],"height_y_m":h["height"]} for h in diagnostic_hits]
                raise ValueError(f"land infill must not borrow foreign support across {cross_spread:.9g}m overlap at {point}: {sources}")
            y=best["height"]
            support_owner_counts[best["triangle"]["owner"]]=support_owner_counts.get(best["triangle"]["owner"],0)+1
            selected_key=f'{best["triangle"]["owner"]}:{best["triangle"]["layer"]}'
            support_owner_layer_counts[selected_key]=support_owner_layer_counts.get(selected_key,0)+1
            normal=(0.0,1.0,0.0)
            source=best["triangle"]
            bary=best["bary"]
            for name in ("NORMAL",):
                vals=source["attributes"].get(name)
                if vals:
                    normal=tuple(sum(bary[i]*vals[i][j] for i in range(3)) for j in range(3))
            result=(y,normal,"supported")
            supported_heights.append(y)
        else:
            if "_terrain_support_owner_ids" in rule:
                terrain_owners=sorted(set(map(str,rule["_terrain_support_owner_ids"])))
                road_owners=sorted(set(map(str,rule.get("_road_support_owner_ids",[]))))
                sample_pools=[]
                for owner in terrain_owners:
                    sample_pools.append(([sample for sample in support_samples if sample[0]==owner and sample[1]=="terrain"],owner))
                for owner in road_owners:
                    sample_pools.append(([sample for sample in support_samples if sample[0]==owner and sample[1]=="road"],owner))
            else:
                sample_pools=[([sample for sample in support_samples if sample[0]==target_owner and sample[1]=="terrain"],target_owner),
                              ([sample for sample in support_samples if sample[0]==target_owner and sample[1]=="road"],target_owner)]
                foreign_owners=sorted(map(str,rule.get("foreign_fallback_owner_ids",[])))
                for owner in foreign_owners:
                    sample_pools.extend(([sample for sample in support_samples if sample[0]==owner and sample[1]==layer],owner)
                                        for layer in ("terrain","road"))
            nearby=[];chosen_pool=None
            for pool,pool_owner in sample_pools:
                candidate=sorted(((math.hypot(point[0]-sample[2][0],point[1]-sample[2][1]),sample)
                                   for sample in pool),key=lambda row:row[0])[:neighbors]
                enough=(len(candidate)==neighbors) if edge_spacing>0.0 else bool(candidate)
                if enough and candidate[-1][0]<=max_distance:
                    nearby=candidate;chosen_pool=pool_owner;break
            if not nearby or nearby[-1][0]>max_distance:
                raise ValueError(f"land infill vertex has no supported height within {max_distance}m")
            if edge_spacing>0.0 and len(nearby)!=neighbors:
                raise ValueError(f"land infill edge-sample mode requires {neighbors} distinct support samples")
            if nearby:min_estimated_neighbor_count=len(nearby) if min_estimated_neighbor_count is None else min(min_estimated_neighbor_count,len(nearby))
            weighted=0.0;weight_sum=0.0
            for distance,sample in nearby:
                weight=1.0/max(distance*distance,1e-12);weighted+=weight*sample[3];weight_sum+=weight
                if chosen_pool!=target_owner:fallback_foreign_owner_counts[sample[0]]=fallback_foreign_owner_counts.get(sample[0],0)+1
            y=weighted/weight_sum;dist=nearby[-1][0];max_estimated_distance=max(max_estimated_distance,dist)
            result=(y,(0.0,1.0,0.0),"estimated");estimated_heights.append(y)
        point_cache[point]=result
        return result
    f32=lambda value:struct.unpack("<f",struct.pack("<f",float(value)))[0]
    packed_collapsed_area=0.0;packed_area_before=0.0
    for poly in polygons_xz:
        if len(poly)<3:continue
        original_points=[(float(p[0]),float(p[1])) for p in poly]
        packed_points=[]
        for x,z in original_points:
            point=(f32(x),f32(z))
            if not packed_points or point!=packed_points[-1]:packed_points.append(point)
        if len(packed_points)>1 and packed_points[0]==packed_points[-1]:packed_points.pop()
        # Drop only vertices made exactly collinear by the actual POSITION float32 pack.
        changed=True
        while changed and len(packed_points)>=3:
            changed=False
            for i in range(len(packed_points)):
                a=packed_points[i-1];b=packed_points[i];c=packed_points[(i+1)%len(packed_points)]
                cross=(b[0]-a[0])*(c[1]-b[1])-(b[1]-a[1])*(c[0]-b[0])
                if cross==0.0:
                    packed_points.pop(i);changed=True;break
        original_area=abs(_polygon_area2_xz(original_points))*.5
        packed_area=abs(_polygon_area2_xz(packed_points))*.5 if len(packed_points)>=3 else 0.0
        packed_area_before+=packed_area
        if packed_area==0.0:
            packed_collapsed_area+=original_area
            continue
        points=packed_points
        # Every piece is convex from sequential triangle subtraction. Fan triangulation keeps every nonzero face.
        local_indices=[]
        for point in points:
            key=point
            vertex=vertex_map.get(key)
            if vertex is None:
                y,_,_=attributes_for(point);world_x,world_z=point[0]+cx,point[1]+cz
                s,u,dist=_land_infill_route_projection(world_x,world_z,route,target_tile)
                vertex=len(positions);vertex_map[key]=vertex
                positions.append((world_x-target_origin[0],y-target_origin[1],world_z-target_origin[2]))
                projected.append((s,u))
            local_indices.append(vertex)
        for i in range(1,len(local_indices)-1):
            tri=[local_indices[0],local_indices[i],local_indices[i+1]]
            a,b,c=[positions[j] for j in tri]
            area2=(b[0]-a[0])*(c[2]-a[2])-(b[2]-a[2])*(c[0]-a[0])
            if area2==0.0:continue
            if area2>0.0:tri[1],tri[2]=tri[2],tri[1]
            indices.extend(tri)
    if not indices:
        raise ValueError("land infill produced no nonzero triangles")
    normals=_normals(positions,indices)
    patch={"name":"estimated_land_infill","translation":list(target_origin),"attributes":{
        "POSITION":positions,"NORMAL":normals,"TEXCOORD_0":[(p[0]+target_origin[0],p[2]+target_origin[2]) for p in positions],
        "_ROUTE_S":[p[0] for p in projected],"_ROUTE_U":[p[1] for p in projected]},
        "primitives":[{"material":{"name":"terrain_ground","color":list(material["color"]),"roughness":float(material["roughness"])},"indices":indices}]}
    regions=[]
    world=_world(patch)
    for k in range(0,len(indices),3):regions.append([world[indices[k+i]] for i in range(3)])
    clipped,emission=reclassify_surface_mesh_exact(patch,regions,material,preserve_source_winding=True)
    if set(clipped["attributes"])!=set(mesh["attributes"]):
        raise ValueError("land infill attribute contract differs from target terrain")
    original_vertex_count=len(mesh["attributes"]["POSITION"])
    updated={**mesh,"attributes":{k:list(v) for k,v in mesh["attributes"].items()},
             "primitives":[{"material":dict(p["material"]),"indices":list(p["indices"])} for p in mesh["primitives"]]}
    for name in updated["attributes"]:updated["attributes"][name].extend(clipped["attributes"][name])
    for primitive in clipped["primitives"]:
        offset_indices=[i+original_vertex_count for i in primitive["indices"]]
        existing=next((p for p in updated["primitives"] if p["material"]==primitive["material"]),None)
        if existing is None:updated["primitives"].append({"material":primitive["material"],"indices":offset_indices})
        else:existing["indices"].extend(offset_indices)
    added_area=0.0;serialized_area=0.0
    for k in range(0,len(indices),3):
        tri=[positions[indices[k+i]] for i in range(3)]
        added_area+=abs((tri[1][0]-tri[0][0])*(tri[2][2]-tri[0][2])-(tri[1][2]-tri[0][2])*(tri[2][0]-tri[0][0]))*.5
    f32=lambda value:struct.unpack("<f",struct.pack("<f",float(value)))[0]
    emitted_indices=[i-original_vertex_count for p in updated["primitives"] if p["material"]==material for i in p["indices"] if i>=original_vertex_count]
    for k in range(0,len(emitted_indices),3):
        tri=[updated["attributes"]["POSITION"][emitted_indices[k+i]+original_vertex_count] for i in range(3)]
        a,b,c=[(f32(p[0]),f32(p[2])) for p in tri]
        serialized_area+=abs((b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]))*.5
    patch_faces=[]
    for primitive in clipped["primitives"]:
        if primitive["material"]!=material:continue
        ix=primitive["indices"]
        for k in range(0,len(ix),3):
            patch_faces.append([(f32(clipped["attributes"]["POSITION"][ix[k+i]][0]),
                                 f32(clipped["attributes"]["POSITION"][ix[k+i]][2])) for i in range(3)])
    def intersection_area(a,b):
        inside=list(a);orientation=1.0 if _polygon_area2_xz(b)>0 else -1.0
        for i in range(3):
            inside=_clip_xz_halfplane(inside,b[i],b[(i+1)%3],orientation,True)
            if not inside:return 0.0
        return abs(_polygon_area2_xz(inside))*.5
    overlap_total=0.0;overlap_max=0.0;overlap_pairs=0
    overlap_by_layer={"terrain":{"area_sum_m2":0.0,"max_pair_area_m2":0.0,"nonzero_pairs":0},
                      "road":{"area_sum_m2":0.0,"max_pair_area_m2":0.0,"nonzero_pairs":0}}
    for face in patch_faces:
        for triangle in support_triangles:
            mask=triangle["xz"]
            if not _triangle_bbox_overlaps(face,mask,eps=1e-8):continue
            area=intersection_area(face,mask)
            overlap_total+=area;overlap_max=max(overlap_max,area);overlap_pairs+=int(area>0.0)
            layer=triangle["layer"];entry=overlap_by_layer[layer]
            entry["area_sum_m2"]+=area;entry["max_pair_area_m2"]=max(entry["max_pair_area_m2"],area)
            entry["nonzero_pairs"]+=int(area>0.0)
    report={"added_area_prepack_m2":added_area,"added_area_serialized_m2":serialized_area,
        "added_vertices":len(positions),"added_triangles_source":len(indices)//3,
        "support_hit_vertices":len(supported_heights),"estimated_vertices":len(estimated_heights),
        "supported_height_range_y_m":[min(supported_heights),max(supported_heights)] if supported_heights else None,
        "estimated_height_range_y_m":[min(estimated_heights),max(estimated_heights)] if estimated_heights else None,
        "max_all_owner_input_height_spread_m":max_spread,
        "max_selected_owner_support_height_mismatch_m":max_owner_spread,
        "max_cross_owner_input_height_difference_m":max_cross_owner_spread,
        "selected_support_owner_vertex_counts":support_owner_counts,
        "selected_support_owner_layer_vertex_counts":support_owner_layer_counts,
        "normal_policy":"recomputed from appended patch triangles; source support normals are not copied",
        "estimated_foreign_fallback_owner_vertex_counts":fallback_foreign_owner_counts,
        "max_estimated_support_distance_m":max_estimated_distance,
        "route_coherent_support":{"kind":"canonical_route_local" if route_chart else None,
            "policy":"chart selection is applied only when a selected same-owner/layer terrain support group exceeds the existing 2mm height spread; sole/already-consistent support retains its actual face height and records chart deltas",
            "terrain_hit_candidates_filtered":route_chart_filtered_hits,"evaluated_chart_points":len(route_chart_diagnostics),
            "max_selected_chart_height_spread_m":max((d["selected_height_spread_m"] or 0.0 for d in route_chart_diagnostics),default=0.0),
            "nearest_distinct_branch_distance_delta_min_m":min((d["nearest_distinct_branch_distance_delta_m"] for d in route_chart_diagnostics if d["nearest_distinct_branch_distance_delta_m"] is not None),default=None),
            "unambiguous_support_vertices_kept":route_chart_unambiguous_count,
            "unambiguous_support_max_abs_station_delta_m":route_chart_unambiguous_max_delta_s,
            "unambiguous_support_max_abs_lateral_delta_m":route_chart_unambiguous_max_delta_u},
        "float32_packed_source_complement_area_m2":packed_area_before,
        "float32_collapsed_complement_polygon_area_m2":packed_collapsed_area,
        "route_projection_station_bounds_m":[min(p[0] for p in projected),max(p[0] for p in projected)],
        "serialized_overlap_with_existing_p1_p0_pair_area_sum_m2":overlap_total,
        "serialized_overlap_max_single_face_pair_m2":overlap_max,
        "serialized_overlap_face_pairs_nonzero":overlap_pairs,
        "serialized_overlap_by_layer":overlap_by_layer,
        "serialized_positive_face_count":len(emitted_indices)//3,"emission":emission}
    if edge_spacing>0.0:
        report["support_edge_sampling"]={"spacing_m":edge_spacing,**edge_sample_report,
            "minimum_estimated_neighbor_count_used":min_estimated_neighbor_count,
            "sampled_edges":"all three edges of each selected-P1/all-P0 support triangle intersecting the authored ROI bounds",
            "interpolation":"linear XZ/Y/_ROUTE_S/_ROUTE_U along original serialized triangle edges; original source vertices retained; support-only samples do not alter source faces, coverage, or direct-hit tests",
            "deduplication":"same owner/layer/point/S/U chart only; distinct chart samples at a shared XZ remain separate"}
    return updated,report


def _sha256_file(path):
    import hashlib
    digest=hashlib.sha256()
    with open(path,"rb") as stream:
        for block in iter(lambda:stream.read(1024*1024),b""):digest.update(block)
    return digest.hexdigest()


def apply_land_infill(pkg,authoring):
    """Explicit postprocess: fill authored ROI complements of all serialized P1/P0 triangles."""
    target_id,rule,material,regions=_validate_land_infill_authoring(authoring)
    manifest_path=os.path.join(pkg,"manifest.json")
    with open(manifest_path) as stream:manifest=json.load(stream)
    route_path=os.path.join(pkg,manifest.get("route","route/route.json"))
    with open(route_path) as stream:route=json.load(stream)
    target_tile=next((tile for tile in manifest.get("tiles",[]) if str(tile.get("id"))==target_id),None)
    if target_tile is None:raise ValueError(f"land infill target tile {target_id} is absent")
    terrain_path=os.path.join(pkg,target_tile["files"]["terrain"])
    original_target=read_glb(terrain_path)
    region_outputs=[];all_polygons=[];all_support=[];all_unselected_p1=[];all_input_hashes={"terrain":{},"road":{}}
    selected_support_owners=set();has_explicit_coverage_policy=False
    logical_ids_global=set()
    for region in regions:
        polygon=[(float(p[0]),float(p[1])) for p in region["polygon_xz"]]
        x0=min(x for x,z in polygon);x1=max(x for x,z in polygon);z0=min(z for x,z in polygon);z1=max(z for x,z in polygon)
        center=((x0+x1)*.5,(z0+z1)*.5)
        # Use the target tile origin as a common local frame for every ROI and owner.
        # This keeps subtraction/intersection coordinates small without a second
        # center->world->tile-local translation that can reopen float32 seams.
        target_origin=target_tile.get("origin",[0,0,0])
        local=[(x-float(target_origin[0]),z-float(target_origin[2])) for x,z in polygon]
        work_center=(float(target_origin[0]),float(target_origin[2]))
        p1,files1=_land_infill_triangles(pkg,manifest,"terrain",[x0,x1,z0,z1],work_center)
        p0,files0=_land_infill_triangles(pkg,manifest,"road",[x0,x1,z0,z1],work_center)
        for row in files1:all_input_hashes["terrain"][row["tile"]]=row["sha256"]
        for row in files0:all_input_hashes["road"][row["tile"]]=row["sha256"]
        all_ids={str(tile["id"]) for tile in manifest["tiles"]};logical_ids=set(map(str,region.get("logical_owner_ids",[])))
        logical_ids_global|=logical_ids
        coverage_owner_ids=region.get("terrain_coverage_owner_ids")
        if coverage_owner_ids is not None:
            has_explicit_coverage_policy=True
            unknown=sorted(set(map(str,coverage_owner_ids))-all_ids)
            if unknown:raise ValueError(f"land infill region {region['id']} references unknown terrain coverage owners: {unknown}")
            selected_p1=[triangle for triangle in p1 if triangle["owner"] in set(map(str,coverage_owner_ids))]
            all_unselected_p1.extend(triangle for triangle in p1 if triangle["owner"] not in set(map(str,coverage_owner_ids)))
            selected_support_owners.update(map(str,coverage_owner_ids))
        else:
            selected_p1=p1
        logical_p1=[triangle for triangle in p1 if triangle["owner"] in logical_ids]
        logical_p0=[triangle for triangle in p0 if triangle["owner"] in logical_ids]
        rem1,p1_stats=_land_infill_subtract([local],selected_p1)
        rem_all,p0_stats=_land_infill_subtract(rem1,p0)
        all_owner_rem1,_=_land_infill_subtract([local],p1)
        all_owner_rem,_=_land_infill_subtract(all_owner_rem1,p0)
        rem_logical,_=_land_infill_subtract([local],logical_p1)
        rem_logical,_=_land_infill_subtract(rem_logical,logical_p0)
        all_support.extend(selected_p1+p0)
        area=lambda poly:abs(_polygon_area2_xz(poly))*.5
        region_outputs.append({"id":region["id"],"roi_xz":polygon,"center_xz":center,
            "roi_area_m2":area(local),"all_p1_triangle_count":len(p1),"selected_p1_triangle_count":len(selected_p1),"all_p0_triangle_count":len(p0),
            "terrain_coverage_owner_ids":sorted(set(t["owner"] for t in selected_p1)),
            "all_package_complement_area_m2":sum(area(p) for p in all_owner_rem),
            "selected_p1_all_p0_complement_area_m2":sum(area(p) for p in rem_all),
            "duplicated_unselected_p1_coverage_area_m2":sum(area(p) for p in rem_all)-sum(area(p) for p in all_owner_rem),
            "added_area_m2":sum(area(p) for p in rem_all),
            "logical_owner_ids":sorted(logical_ids),"logical_only_complement_area_m2":sum(area(p) for p in rem_logical),
            "foreign_only_coverage_difference_m2":sum(area(p) for p in rem_logical)-sum(area(p) for p in rem_all),
            "p1_subtraction":p1_stats,"p0_subtraction":p0_stats,"polygon_count":len(rem_all),
            "discarded_zero_area_polygons":0})
        all_polygons.extend((poly,work_center) for poly in rem_all)
    if not all_polygons:raise ValueError("land infill authoring regions have no P1/P0 complement")
    origin=original_target.get("translation",[0.0,0.0,0.0])
    # All complement and support XZ values are already in the target tile-local frame.
    converted=[polygon for polygon,_ in all_polygons]
    combined_center=(origin[0],origin[2])
    effective_rule=dict(rule)
    if has_explicit_coverage_policy:
        effective_rule["_terrain_support_owner_ids"]=sorted(selected_support_owners)
        effective_rule["_road_support_owner_ids"]=sorted(str(tile["id"]) for tile in manifest["tiles"] if tile.get("files",{}).get("road"))
    if rule.get("terrain_support_chart") is not None:
        effective_rule["_terrain_support_chart"]=dict(rule["terrain_support_chart"])
    updated,mesh_report=_append_land_infill(original_target,converted,combined_center,all_support,route,target_tile,effective_rule,material)
    chart_report=None
    chart=authoring.get("route_attribute_chart")
    if chart is not None:
        road_path=os.path.join(pkg,target_tile["files"]["road"])
        target_road=read_glb(road_path)
        chart_report=_apply_near_road_affine_chart(updated,target_road,
            start_vertex=len(original_target["attributes"]["POSITION"]),
            max_distance_m=float(chart["max_distance_m"]))
    unselected_overlap={"sampled_new_vertices_with_unselected_p1":0,"max_abs_y_difference_m":0.0,"by_owner":{}}
    if all_unselected_p1:
        start=len(original_target["attributes"]["POSITION"]);translation=updated.get("translation",[0.0,0.0,0.0])
        for i in range(start,len(updated["attributes"]["POSITION"])):
            p=updated["attributes"]["POSITION"][i]
            hits=_land_infill_hits((p[0],p[2]),all_unselected_p1)
            for hit in hits:
                owner=hit["triangle"]["owner"];difference=abs(p[1]+translation[1]-hit["height"])
                row=unselected_overlap["by_owner"].setdefault(owner,{"sampled_vertex_hits":0,"max_abs_y_difference_m":0.0})
                row["sampled_vertex_hits"]+=1;row["max_abs_y_difference_m"]=max(row["max_abs_y_difference_m"],difference)
                unselected_overlap["sampled_new_vertices_with_unselected_p1"]+=1
                unselected_overlap["max_abs_y_difference_m"]=max(unselected_overlap["max_abs_y_difference_m"],difference)
    method=("selected serialized P1 plus all serialized P0 XZ complement inside bounded authored convex ROIs; selected P1 and all P0 supply support heights; deterministic inverse-square IDW at unsupported decomposition/interior vertices; route-coherent selected-P1 support uses canonical target-tile route S/U windows; appended route S/U uses the separate target-road affine chart"
        if has_explicit_coverage_policy and rule.get("terrain_support_chart") is not None else
        "selected serialized P1 plus all serialized P0 XZ complement inside bounded authored convex ROIs; existing support heights at hits, deterministic inverse-square IDW at unsupported decomposition/interior vertices; appended route S/U uses the target-tile canonical route chart" if has_explicit_coverage_policy else
        "all serialized P1/P0 XZ complement inside bounded authored convex ROIs; existing support heights at hits, deterministic inverse-square IDW at unsupported decomposition/interior vertices; route S/U projected only to target-tile canonical route segments")
    manifest.setdefault("estimated_land_infill",[]).append({
        "authoring":authoring,"method":method,
        "support_owner_policy":({"terrain":"selected terrain_coverage_owner_ids","road":"all package P0 owners","foreign_terrain":"excluded"} if has_explicit_coverage_policy else "legacy target-owner plus configured foreign_fallback_owner_ids"),
        "regions":region_outputs,"mesh_report":mesh_report,
        "route_attribute_chart_report":chart_report,
        "route_coherent_support_report":mesh_report["route_coherent_support"],
        "unselected_p1_overlap_height_diagnostic":unselected_overlap,
        "input_support_hashes":all_input_hashes,"target_original_sha256":_sha256_file(terrain_path)})
    # Stage all outputs before replacing either file; validation errors never leave partial geometry.
    terrain_tmp=terrain_path+".land_infill.tmp";manifest_tmp=manifest_path+".land_infill.tmp"
    try:
        write_glb(terrain_tmp,updated)
        with open(manifest_tmp,"w") as stream:json.dump(manifest,stream,indent=1)
        os.replace(terrain_tmp,terrain_path);os.replace(manifest_tmp,manifest_path)
    finally:
        for path in (terrain_tmp,manifest_tmp):
            if os.path.exists(path):os.remove(path)
    return {"target_tile_id":target_id,"regions":region_outputs,"mesh_report":mesh_report,
            "route_attribute_chart_report":chart_report,
            "unselected_p1_overlap_height_diagnostic":unselected_overlap,
            "manifest_sha256":_sha256_file(manifest_path),"terrain_sha256":_sha256_file(terrain_path)}


def _classify_coastal_sand_exact(mesh, profiles, tile_from_s, tile_to_s):
    """Classify authored coast sand in local route coordinates, restoring actual positions afterward."""
    attrs={key:list(values) for key,values in mesh["attributes"].items()}
    if "_ROUTE_S" not in attrs or "_ROUTE_U" not in attrs:
        raise ValueError("exact coastal sand classification requires route S/U attributes")
    regions=[]
    if any(p.get("water_far_m") is not None for p in profiles):
        raise ValueError("coastal_exact_sand_boundary does not support water_far_m bands yet")
    for profile in profiles:
        start=max(float(tile_from_s),float(profile["from_s"]))
        end=min(float(tile_to_s),float(profile["to_s"]))
        if end <= start:
            continue
        width=float(profile.get("sand_width_m",2.0)); edge=float(profile["water_edge_m"])
        sides=("left","right") if profile.get("side")=="both" else (profile["side"],)
        for side in sides:
            a,b=start-tile_from_s,end-tile_from_s
            sign=-1.0 if side=="right" else 1.0
            signed_outward=[sign*float(u) for sv,u in zip(attrs["_ROUTE_S"],attrs["_ROUTE_U"])
                            if start-1e-6 <= float(sv) <= end+1e-6]
            outer=max(signed_outward,default=edge)
            if side=="right": z0,z1=edge-width,outer
            else: z0,z1=-outer,-(edge-width)
            if z1 <= z0:
                continue
            regions.extend([[(a,0,z0),(b,0,z0),(b,0,z1)],
                            [(a,0,z0),(b,0,z1),(a,0,z1)]])
    if not regions:
        return mesh,{"status":"no_profile_intersection","regions":0,"triangles_reclassified":0}
    attrs["_ACTUAL_POSITION"]=[tuple(p) for p in attrs["POSITION"]]
    attrs["POSITION"]=[(float(s)-tile_from_s,0.0,-float(u))
                       for s,u in zip(attrs["_ROUTE_S"],attrs["_ROUTE_U"])]
    eligible=[index for primitive in mesh["primitives"]
              if primitive["material"].get("name") in ("terrain_ground","shore_sand")
              for index in primitive["indices"]]
    if not eligible:
        return mesh,{"status":"no_eligible_terrain","regions":len(regions),"triangles_reclassified":0}
    working_primitives=[{"material":TERRAIN_MATERIAL,"indices":eligible}]
    working_primitives.extend({"material":primitive["material"],"indices":list(primitive["indices"])}
        for primitive in mesh["primitives"]
        if primitive["material"].get("name") not in ("terrain_ground","shore_sand"))
    working={**mesh,"translation":[0.0,0.0,0.0],"attributes":attrs,
             "primitives":working_primitives}
    updated,stats=reclassify_surface_mesh_exact(working,regions,
        {"name":"shore_sand","color":[0.68,0.59,0.39],"roughness":0.95},
        preserve_source_winding=True)
    updated["attributes"]["POSITION"]=updated["attributes"].pop("_ACTUAL_POSITION")
    updated["translation"]=mesh["translation"]
    stats.update({"status":"applied","regions":len(regions),"parameter_frame":"(local_s, -u)",
                  "source_winding_preserved":True})
    return updated,stats


def reclassify_surface_mesh_exact(mesh, regions, target_material=None, cell_m=16.0,
                                  preserve_source_winding=False):
    """Split terrain triangles on a projected owner mask without changing the piecewise-planar surface."""
    if not regions:
        return mesh,{"triangles_reclassified":0,"triangles_split":0,"new_vertices":0,"mask_triangles":0}
    material=target_material or {"name":"shore_sand","color":[0.68,0.59,0.39],"roughness":0.95}
    result={**mesh,"attributes":{k:list(v) for k,v in mesh["attributes"].items()},"primitives":[]}
    world=_world(mesh)
    masks=[]
    for region in regions:
        tri=[(p[0],p[2]) for p in region]
        if len(tri)==3 and abs(_polygon_area2_xz(tri))>0.0:
            masks.append(tri)
    if not masks:
        return mesh,{"triangles_reclassified":0,"triangles_split":0,"new_vertices":0,"mask_triangles":0}
    grid={}
    for index,tri in enumerate(masks):
        for gx in range(math.floor(min(p[0] for p in tri)/cell_m),math.floor(max(p[0] for p in tri)/cell_m)+1):
            for gz in range(math.floor(min(p[1] for p in tri)/cell_m),math.floor(max(p[1] for p in tri)/cell_m)+1):
                grid.setdefault((gx,gz),[]).append(index)
    groups={}; split_count=0; changed_count=0; collapsed_removed=0; prepack_collapsed_removed=0; quantization_flips_removed=0
    actual_collapsed_removed=0;actual_quantization_flips_removed=0;actual_removed_area_m2=0.0
    actual_full_precision_winding_mismatch_retained=0
    original_vertex_count=len(result["attributes"]["POSITION"])
    translation=mesh.get("translation",(0.0,0.0,0.0))

    def f32(value):
        return struct.unpack("<f",struct.pack("<f",float(value)))[0]

    def emit(material_key,source_tri,poly,vertex_cache):
        nonlocal collapsed_removed,prepack_collapsed_removed,quantization_flips_removed
        nonlocal actual_collapsed_removed,actual_quantization_flips_removed,actual_removed_area_m2
        nonlocal actual_full_precision_winding_mismatch_retained
        source_points=[world[j] for j in source_tri]
        source_area2=(source_points[1][0]-source_points[0][0])*(source_points[2][2]-source_points[0][2])-(source_points[1][2]-source_points[0][2])*(source_points[2][0]-source_points[0][0])
        if source_area2==0.0 or (source_area2>0.0 and not preserve_source_winding):
            raise ValueError("exact terrain clipping received a wrongly wound source face")
        source_sign=1.0 if source_area2>0.0 else -1.0
        poly_area2=sum((poly[i][0]-poly[0][0])*(poly[i+1][1]-poly[0][1])-
                       (poly[i][1]-poly[0][1])*(poly[i+1][0]-poly[0][0])
                       for i in range(1,len(poly)-1)) if len(poly)>=3 else 0.0
        if poly_area2 and source_area2*poly_area2<0:
            poly=list(reversed(poly))
        for raw_face in _triangulate_xz(poly):
            face=list(raw_face)
            prepack=[(p[0]-translation[0],p[1]-translation[2]) for p in face]
            prepack_area2=(prepack[1][0]-prepack[0][0])*(prepack[2][1]-prepack[0][1])-(prepack[1][1]-prepack[0][1])*(prepack[2][0]-prepack[0][0])
            if prepack_area2==0:
                prepack_collapsed_removed+=1
                continue
            if prepack_area2*source_sign<0:
                face[1],face[2]=face[2],face[1]
                prepack[1],prepack[2]=prepack[2],prepack[1]
                prepack_area2=-prepack_area2
            indices=[]
            for x,z in face:
                found=None
                for j in source_tri:
                    if (f32(result["attributes"]["POSITION"][j][0])==f32(x-translation[0]) and
                        f32(result["attributes"]["POSITION"][j][2])==f32(z-translation[2])):
                        found=j;break
                if found is None:
                    cache_key=(f32(x-translation[0]),f32(z-translation[2]))
                    found=vertex_cache.get(cache_key)
                    if found is None:
                        bary=_barycentric_xz(x,z,[world[j] for j in source_tri])
                        found=len(result["attributes"]["POSITION"])
                        for name,values in result["attributes"].items():
                            values.append(_interpolate_attribute(values,source_tri,bary))
                        vertex_cache[cache_key]=found
                indices.append(found)
            actual_values=result["attributes"].get("_ACTUAL_POSITION") if preserve_source_winding else None
            if actual_values is not None:
                actual_source=[actual_values[j] for j in source_tri]
                actual_source_area2=((actual_source[1][0]-actual_source[0][0])*(actual_source[2][2]-actual_source[0][2])-
                    (actual_source[1][2]-actual_source[0][2])*(actual_source[2][0]-actual_source[0][0]))
                if actual_source_area2==0.0:
                    raise ValueError("exact terrain clipping received a degenerate actual source face")
                actual=[actual_values[j] for j in indices]
                actual_area2=((actual[1][0]-actual[0][0])*(actual[2][2]-actual[0][2])-
                    (actual[1][2]-actual[0][2])*(actual[2][0]-actual[0][0]))
                packed_actual=[(f32(p[0]),f32(p[2])) for p in actual]
                packed_actual_area2=((packed_actual[1][0]-packed_actual[0][0])*(packed_actual[2][1]-packed_actual[0][1])-
                    (packed_actual[1][1]-packed_actual[0][1])*(packed_actual[2][0]-packed_actual[0][0]))
                if packed_actual_area2==0.0 or packed_actual_area2*actual_source_area2<0.0:
                    point_error=[(abs(packed_actual[i][0]-actual[i][0]),abs(packed_actual[i][1]-actual[i][2]))
                                 for i in range(3)]
                    dx1=actual[1][0]-actual[0][0];dz1=actual[1][2]-actual[0][2]
                    dx2=actual[2][0]-actual[0][0];dz2=actual[2][2]-actual[0][2]
                    ex1=point_error[1][0]+point_error[0][0];ez1=point_error[1][1]+point_error[0][1]
                    ex2=point_error[2][0]+point_error[0][0];ez2=point_error[2][1]+point_error[0][1]
                    actual_bound=(abs(dx1)*ez2+abs(dz2)*ex1+ex1*ez2+
                        abs(dz1)*ex2+abs(dx2)*ez1+ez1*ex2+
                        16.0*sys.float_info.epsilon*max(1.0,abs(dx1*dz2)+abs(dz1*dx2)))
                    if (packed_actual_area2==0.0 and abs(actual_area2)<=actual_bound) or (
                            packed_actual_area2*actual_source_area2<0.0 and
                            abs(actual_area2)<=actual_bound and
                            abs(packed_actual_area2-actual_area2)<=actual_bound):
                        actual_collapsed_removed+=int(packed_actual_area2==0.0)
                        actual_quantization_flips_removed+=int(packed_actual_area2!=0.0)
                        actual_removed_area_m2+=abs(actual_area2)*0.5
                        continue
                    raise ValueError("exact terrain clipping has an actual-XZ float32 reversal beyond quantization bound")
                if actual_area2==0.0 or actual_area2*actual_source_area2<0.0:
                    actual_full_precision_winding_mismatch_retained+=1
                key=json.dumps(material_key,sort_keys=True,separators=(",",":"))
                groups.setdefault(key,[material_key,[]])[1].extend(indices)
                continue
            # GLB positions are float32. Reject sub-quantization facets that collapse or
            # reverse after serialization instead of emitting degenerate/folded faces.
            p0,p1,p2=[result["attributes"]["POSITION"][i] for i in indices]
            x0,z0=f32(p0[0]),f32(p0[2]);x1,z1=f32(p1[0]),f32(p1[2]);x2,z2=f32(p2[0]),f32(p2[2])
            packed_area2=(x1-x0)*(z2-z0)-(z1-z0)*(x2-x0)
            if prepack_area2==0.0:
                prepack_collapsed_removed+=1
                continue
            if packed_area2==0:
                collapsed_removed+=1
                continue
            if packed_area2*source_sign<0:
                packed_local=[(f32(result["attributes"]["POSITION"][i][0]),
                               f32(result["attributes"]["POSITION"][i][2])) for i in indices]
                point_error=[(abs(packed_local[i][0]-prepack[i][0]),
                              abs(packed_local[i][1]-prepack[i][1])) for i in range(3)]
                dx1=prepack[1][0]-prepack[0][0];dz1=prepack[1][1]-prepack[0][1]
                dx2=prepack[2][0]-prepack[0][0];dz2=prepack[2][1]-prepack[0][1]
                ex1=point_error[1][0]+point_error[0][0];ez1=point_error[1][1]+point_error[0][1]
                ex2=point_error[2][0]+point_error[0][0];ez2=point_error[2][1]+point_error[0][1]
                quantization_bound=(abs(dx1)*ez2+abs(dz2)*ex1+ex1*ez2+
                                    abs(dz1)*ex2+abs(dx2)*ez1+ez1*ex2+
                                    16.0*sys.float_info.epsilon*max(1.0,abs(dx1*dz2)+abs(dz1*dx2)))
                if abs(prepack_area2)<=quantization_bound and abs(packed_area2-prepack_area2)<=quantization_bound:
                    quantization_flips_removed+=1
                    continue
                raise ValueError("exact terrain clipping reversed a face beyond its float32 quantization bound")
            key=json.dumps(material_key,sort_keys=True,separators=(",",":"))
            groups.setdefault(key,[material_key,[]])[1].extend(indices)

    for primitive in mesh["primitives"]:
        source_material=primitive["material"]
        for k in range(0,len(primitive["indices"]),3):
            tri=primitive["indices"][k:k+3]
            if len(tri)!=3: raise ValueError("terrain surface indices must be triangles")
            original_poly=[(world[i][0],world[i][2]) for i in tri]
            if source_material.get("name") not in ("terrain_ground","shore_sand"):
                key=json.dumps(source_material,sort_keys=True,separators=(",",":"))
                groups.setdefault(key,[source_material,[]])[1].extend(tri)
                continue
            xs=[p[0] for p in original_poly]; zs=[p[1] for p in original_poly]
            candidates=set()
            for gx in range(math.floor(min(xs)/cell_m),math.floor(max(xs)/cell_m)+1):
                for gz in range(math.floor(min(zs)/cell_m),math.floor(max(zs)/cell_m)+1):
                    candidates.update(grid.get((gx,gz),()))
            candidates=[masks[i] for i in sorted(candidates) if _triangle_bbox_overlaps(original_poly,masks[i])]
            if not candidates:
                key=json.dumps(source_material,sort_keys=True,separators=(",",":"))
                groups.setdefault(key,[source_material,[]])[1].extend(tri)
                continue
            remaining=[original_poly]; inside=[]
            for mask in candidates:
                pending=[]
                for poly in remaining:
                    if not _triangle_bbox_overlaps(poly,mask):
                        pending.append(poly);continue
                    outside,hit=_subtract_convex_xz(poly,mask)
                    pending.extend(outside)
                    if hit: inside.append(hit)
                remaining=pending
                if not remaining: break
            vertex_cache={}
            before_inside=sum(abs(_polygon_area2_xz(p)) for p in inside)*.5
            if before_inside>0.0 and before_inside < abs(_polygon_area2_xz(original_poly))*.5:
                split_count+=1
            if before_inside>0.0:
                for poly in inside: emit(material,tri,poly,vertex_cache)
                changed_count+=sum(len(_triangulate_xz(p)) for p in inside)
            for poly in remaining:
                emit(source_material,tri,poly,vertex_cache)
    ordered=sorted(groups.values(),key=lambda g:(g[0].get("name")!="terrain_ground",g[0].get("name","")))
    result["primitives"]=[{"material":m,"indices":idx} for m,idx in ordered if idx]
    return result,{"triangles_reclassified":changed_count,"triangles_split":split_count,
                   "new_vertices":len(result["attributes"]["POSITION"])-original_vertex_count,
                   "mask_triangles":len(masks),"float32_collapsed_facets_removed":collapsed_removed,
                   "prepack_zero_area_facets_removed":prepack_collapsed_removed,
                   "float32_quantization_flips_removed":quantization_flips_removed,
                   "actual_float32_collapsed_facets_removed":actual_collapsed_removed,
                   "actual_float32_quantization_flips_removed":actual_quantization_flips_removed,
                   "actual_float32_removed_projected_area_m2":actual_removed_area_m2,
                   "actual_full_precision_winding_mismatch_retained":actual_full_precision_winding_mismatch_retained,
                   "float32_degenerate_facets_removed":collapsed_removed+prepack_collapsed_removed+quantization_flips_removed}


def apply_surface_material_overrides(pkg, authoring):
    """Material-only local surface override using already-shipped owner terrain triangles."""
    with open(os.path.join(pkg, "manifest.json")) as f:
        manifest = json.load(f)
    overrides = authoring.get("overrides", [])
    if not overrides:
        return {"status":"unchanged", "triangles_reclassified":0}
    tiles = manifest["tiles"]
    owners = []
    for tile in tiles:
        mesh = read_glb(os.path.join(pkg, tile["files"]["terrain"]))
        attrs = mesh["attributes"]
        if "_ROUTE_S" not in attrs or "_ROUTE_U" not in attrs:
            continue
        owners.append((tile, mesh, _world(mesh)))
    totals = {}
    for override in overrides:
        regions = []
        a, b = float(override["from_s"]), float(override["to_s"])
        edge = float(override["edge_m"])
        width_value = override.get("width_m", override.get("sand_width_m"))
        if width_value is None:
            raise ValueError(f"surface override {override.get('id')} requires width_m")
        width = float(width_value)
        material = override.get("material", override.get("sand_material"))
        boundary_mode = override.get("boundary_mode", "centroid")
        if boundary_mode == "exact_triangle_clip":
            boundary_mode = "exact"
        if boundary_mode not in ("centroid", "exact"):
            raise ValueError(f"unsupported surface boundary_mode {boundary_mode!r}")
        side_sign = -1 if override["side"] == "right" else 1
        inner = edge - width
        if boundary_mode == "exact":
            signed_bounds = sorted((side_sign * inner, side_sign * edge))
            regions, owner_count = _owner_region_triangles_exact(
                owners, a, b, signed_bounds[0], signed_bounds[1])
        else:
            owner_count = 0
            for _, mesh, world in owners:
                attrs = mesh["attributes"]
                ss, uu = attrs["_ROUTE_S"], attrs["_ROUTE_U"]
                for primitive in mesh["primitives"]:
                    ids = primitive["indices"]
                    for k in range(0, len(ids), 3):
                        tri = ids[k:k+3]
                        sv = sum(ss[i] for i in tri)/3
                        lateral = side_sign * sum(uu[i] for i in tri)/3
                        if a <= sv <= b and inner <= lateral <= edge:
                            regions.append([world[i] for i in tri])
            owner_count = len(regions)
        if not regions:
            raise ValueError(f"surface override {override.get('id')} has no source-owner triangles")
        updated_count = 0
        for tile in tiles:
            path = os.path.join(pkg, tile["files"]["terrain"])
            mesh = read_glb(path)
            world = _world(mesh)
            if boundary_mode == "exact":
                updated, stats = reclassify_surface_mesh_exact(mesh, regions, material)
            else:
                updated, stats = reclassify_surface_materials(world, mesh["primitives"], regions,
                                                               material)
            if stats["triangles_reclassified"]:
                if boundary_mode == "exact":
                    mesh = updated
                else:
                    mesh["primitives"] = updated
                write_glb(path, mesh)
                updated_count += stats["triangles_reclassified"]
        totals[override.get("id", "override")] = {"boundary_mode":boundary_mode,
            "owner_triangles":owner_count,
            "triangles_reclassified":updated_count, "from_s":a, "to_s":b,
            "side":override["side"], "lateral_m":[inner,edge],
            "material":material or {"name":"shore_sand", "color":[0.68,0.59,0.39], "roughness":0.95}}
    manifest["surface_material_overrides"] = {"provenance":authoring.get("source",{}),
        "method":"per-override centroid classification or exact triangle clipping against owner terrain; physical terrain surface unchanged",
        "rebuild":"python3 tools/road_terrain.py materials <package> <authoring.json>", "results":totals}
    with open(os.path.join(pkg, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    return {"status":"applied", "overrides":totals}


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


def _boundary_segments(mesh, positions, sv):
    ss,us = mesh["attributes"]["_ROUTE_S"],mesh["attributes"]["_ROUTE_U"]
    result = []
    for primitive in mesh["primitives"]:
        idx = primitive["indices"]
        for k in range(0,len(idx),3):
            tri = idx[k:k+3]
            for a,b in zip(tri,tri[1:]+tri[:1]):
                if abs(ss[a]-sv)<1e-3 and abs(ss[b]-sv)<1e-3 and abs(us[a]-us[b])>1e-7:
                    if us[a]>us[b]:a,b=b,a
                    result.append((us[a],us[b],positions[a],positions[b]))
    return result


def _boundary_gap(a,b):
    """Compare actual boundary polylines; a clipped mesh may subdivide the same line differently."""
    def position(segments,u):
        nearest = None
        distance = math.inf
        for lo,hi,p,q in segments:
            delta = max(lo-u,u-hi,0.)
            if delta < distance:
                distance = delta
                t=min(1.,max(0.,(u-lo)/(hi-lo)))
                nearest = [x+(y-x)*t for x,y in zip(p,q)]
        return nearest if distance <= TOL["seam"] else None
    ends=sorted({v for seg in a+b for v in seg[:2]})
    queries=ends+[(x+y)/2 for x,y in zip(ends,ends[1:]) if y-x>1e-5]
    worst=0.
    for u in queries:
        p,q=position(a,u),position(b,u)
        if (p is None)!=(q is None):return math.inf
        if p is not None:worst=max(worst,max(abs(x-y) for x,y in zip(p,q)))
    return worst


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
            i = min(max(bisect.bisect_right(s, sv)-1,0),len(s)-2)
            fraction = min(1.,max(0.,(sv-s[i])/(s[i+1]-s[i])))
            widths = smp["width_left_m" if u > 0 else "width_right_m"]
            w = widths[i]+(widths[i+1]-widths[i])*fraction
            road_y = smp["y"][i]+(smp["y"][i+1]-smp["y"][i])*fraction
            if abs(abs(u) - w) < 1e-3:
                edge_err = max(edge_err, abs(tpw[k][1] - road_y))
            elif abs(u) < w:
                inside += 1
        if edge_err > TOL["elevation"]:
            te.append(f"terrain does not meet the road edge (off by {edge_err:.4f} m)")
        if inside:
            te.append(f"{inside} terrain vertices inside the road band")
        # A legitimate side-only closure has zero XZ projection but nonzero 3-D area. Keep testing
        # any support_skirt face that projects to an area (including horizontal or inverted faces).
        ground_indices = []
        for primitive in terr["primitives"]:
            ids = primitive["indices"]
            for j in range(0, len(ids), 3):
                tri_ids = ids[j:j+3]
                skip_vertical_side = False
                if primitive["material"]["name"] == "support_skirt":
                    a, b, c = (tpw[k] for k in tri_ids)
                    u = (b[0]-a[0], b[1]-a[1], b[2]-a[2])
                    v = (c[0]-a[0], c[1]-a[1], c[2]-a[2])
                    cross = (u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0])
                    area3 = math.sqrt(sum(component*component for component in cross))
                    xz_projected = (b[2]-a[2])*(c[0]-a[0])-(b[0]-a[0])*(c[2]-a[2])
                    skip_vertical_side = abs(xz_projected) <= 1e-6 and area3 > 1e-8
                if not skip_vertical_side:
                    ground_indices.extend(tri_ids)
        folds = _face_up(tpw, ground_indices)
        if folds:
            te.append(f"{folds} terrain triangles folded / facing down")
        b0, b1 = tile["bounds"]["min"], tile["bounds"]["max"]
        if any(p[k] < b0[k] - 1e-3 or p[k] > b1[k] + 1e-3 for p in rp + tpw for k in range(3)):
            te.append("geometry outside the recorded bounding box")
        errs += [f"tile {tile['id']}: {e}" for e in te]
        report["tiles"].append({"id": tile["id"], "from_s": tile["from_s"], "to_s": tile["to_s"],
                                "max_error": {k: round(v, 5) for k, v in worst.items()},
                                "terrain_edge_error_m": round(edge_err, 5), "ok": not te})
    clearance = road_occlusions(smp, ((tid,m[2],m[3]) for tid,m in meshes.items()))
    report["global_road_clearance"] = clearance
    if clearance["blocked_probes"]:
        errs.append(f"terrain covers road at {clearance['blocked_probes']} probes; max {clearance['max_above_road_m']:.3f} m")
    # seams: the shared boundary row is identical in both neighbours (road and terrain)
    for a, b in zip(tiles, tiles[1:]):
        if a["id"] not in meshes or b["id"] not in meshes:
            continue
        worst = 0.0
        for m in (0, 2):  # road, terrain
            ma, pa = meshes[a["id"]][m], meshes[a["id"]][m + 1]
            mb, pb = meshes[b["id"]][m], meshes[b["id"]][m + 1]
            ea = _boundary_segments(ma,pa,a["to_s"])
            eb = _boundary_segments(mb,pb,b["from_s"])
            if m==0 and (not ea or not eb):
                errs.append(f"seam {a['id']}|{b['id']}: road boundary missing")
                worst=math.inf
            worst=max(worst,_boundary_gap(ea,eb))
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
    if len(args) == 3 and args[0] == "materials":
        with open(args[2]) as f:
            authoring = json.load(f)
        result = apply_surface_material_overrides(args[1], authoring)
        print(json.dumps(result, indent=1))
        return 0
    if len(args) == 2 and args[0] == "build":
        terrain = {}
        if "terrain" in opts:
            with open(opts["terrain"]) as f:
                terrain = json.load(f)
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
