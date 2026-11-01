#!/usr/bin/env python3
"""P2 context streets from OpenStreetMap: vehicular roads, parking aisles and car parks near the route,
draped on the shipped P1 terrain and written as tiles/<NN>/roadside.glb. Never touches P0/P1 data.

  python3 tools/osm_context.py fetch <package> <osm.json> [margin_m]   Overpass query around the route
  python3 tools/osm_context.py build <package> <osm.json>              roadside.glb + manifest + licence
  python3 tools/osm_context.py buildings <package> <osm.json>          tiles/<NN>/buildings.glb (P4) + licence

Geometry is OSM-measured in plan (ODbL); widths are tag-derived or per-class estimates; heights are draped on
P1 terrain (estimated). Quads within the route's own road footprint (+ margin) are dropped, so the P0 road always
wins; P3 instances standing on a context road are removed (P2 outranks P3).
"""
import json
import math
import os
import sys
import urllib.parse
import urllib.request

import road_terrain as rt
import vegetation as veg

METRES_PER_DEGREE = 111195.08  # same equirectangular frame as build_osm_route.py
OVERPASS = "https://overpass-api.de/api/interpreter"
# Carriageway width per highway class when OSM has no width / lanes tag (estimated).
CLASS_WIDTH_M = {"motorway": 14.0, "trunk": 12.0, "primary": 11.0, "secondary": 9.5, "tertiary": 8.5,
                 "unclassified": 6.5, "residential": 7.0, "living_street": 5.5, "service": 4.5}
SKIP_SERVICE = {"driveway", "drive-through", "emergency_access"}
MARKED = {"motorway", "trunk", "primary", "secondary", "tertiary", "residential", "unclassified"}
ROUTE_MARGIN_M = 0.6   # context surface keeps this clear of the P0 road edge
LIFT_M = 0.04          # above the draped terrain (no z-fighting; still well below a kerb)
STEP_M = 4.0
ASPHALT = {"name": "context_asphalt", "color": [0.10, 0.105, 0.11], "roughness": 0.9}
MARKING = {"name": "lane_marking", "color": [0.80, 0.80, 0.78], "roughness": 0.6}


def to_xz(origin, lat, lon):
    return ((lon - origin["lon"]) * METRES_PER_DEGREE * math.cos(math.radians(origin["lat"])),
            (origin["lat"] - lat) * METRES_PER_DEGREE)


def to_latlon(origin, x, z):
    return (origin["lat"] - z / METRES_PER_DEGREE,
            origin["lon"] + x / (METRES_PER_DEGREE * math.cos(math.radians(origin["lat"]))))


def fetch(pkg, out_path, margin_m=150.0):
    route = json.load(open(os.path.join(pkg, "route", "route.json")))
    origin = route["coordinate_system"]["origin"]
    xs, zs = route["samples"]["x"], route["samples"]["z"]
    south, west = to_latlon(origin, min(xs) - margin_m, max(zs) + margin_m)
    north, east = to_latlon(origin, max(xs) + margin_m, min(zs) - margin_m)
    bbox = f"{south:.6f},{west:.6f},{north:.6f},{east:.6f}"
    query = (f'[out:json][timeout:180];(way["highway"~"^({"|".join(CLASS_WIDTH_M)})$"]({bbox});'
             f'way["amenity"="parking"]({bbox});way["building"]({bbox}););out geom tags;')
    request = urllib.request.Request(OVERPASS, data=urllib.parse.urlencode({"data": query}).encode(),
                                     headers={"User-Agent": "ai_scene osm_context (research)"})
    with urllib.request.urlopen(request, timeout=240) as response:
        data = json.load(response)
    data["query"], data["bbox"] = query, bbox
    with open(out_path, "w") as f:
        json.dump(data, f)
    print("fetched", len(data["elements"]), "ways ->", out_path)


def way_width(tags):
    try:
        return float(tags["width"].split()[0])
    except (KeyError, ValueError):
        pass
    try:
        return max(1, int(tags["lanes"])) * 3.2 + 1.0
    except (KeyError, ValueError):
        return CLASS_WIDTH_M.get(tags.get("highway"), 6.0)


class RouteIndex:
    """Nearest route sample within a few metres: (s, clearance) where clearance = distance - road half width."""

    def __init__(self, route, cell=10.0):
        self.cell, self.grid, smp = cell, {}, route["samples"]
        for i, s in enumerate(smp["s"]):
            key = (math.floor(smp["x"][i] / cell), math.floor(smp["z"][i] / cell))
            half = max(smp["width_left_m"][i], smp["width_right_m"][i])
            self.grid.setdefault(key, []).append((smp["x"][i], smp["z"][i], s, half))

    def nearest(self, x, z, reach_cells=2):
        best = (math.inf, None, 0.0)
        gx, gz = math.floor(x / self.cell), math.floor(z / self.cell)
        for dx in range(-reach_cells, reach_cells + 1):
            for dz in range(-reach_cells, reach_cells + 1):
                for px, pz, s, half in self.grid.get((gx + dx, gz + dz), ()):
                    d = math.hypot(x - px, z - pz)
                    if d < best[0]:
                        best = (d, s, half)
        return best

    def clearance(self, x, z):
        d, _, half = self.nearest(x, z, 1)
        return d - half


def resample(points, step):
    out = [points[0]]
    for a, b in zip(points, points[1:]):
        n = max(1, math.ceil(math.dist(a, b) / step))
        out.extend((a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n) for k in range(1, n + 1))
    return out


def ribbon(points, half):
    """Left/right offsets of a polyline (mitre-free: averaged segment normals)."""
    sides = []
    for i, p in enumerate(points):
        a, b = points[max(0, i - 1)], points[min(len(points) - 1, i + 1)]
        tx, tz = b[0] - a[0], b[1] - a[1]
        n = math.hypot(tx, tz) or 1.0
        nx, nz = -tz / n, tx / n
        sides.append(((p[0] + nx * half, p[1] + nz * half), (p[0] - nx * half, p[1] - nz * half)))
    return sides


def build(pkg, osm_path):
    route, man, sem = veg._load(pkg)
    origin = route["coordinate_system"]["origin"]
    space = veg.Space(pkg, route, man, sem)
    index = RouteIndex(route)
    tiles = man["tiles"]
    tile_of = lambda s: next((t for t in tiles if t["from_s"] <= s <= t["to_s"]), tiles[-1])
    meshes = {t["id"]: {"positions": [], "asphalt": [], "marking": []} for t in tiles}
    footprints = {t["id"]: [] for t in tiles}  # context asphalt triangles (xz) for P3 cleanup
    stats = {"ways": 0, "quads": 0, "dropped_route": 0, "dropped_no_terrain": 0, "parking_areas": 0}

    def ground(x, z):
        y = space.ground_world(x, z)
        return None if y is None else y + LIFT_M

    def emit(quad, kind, lift=0.0):
        """quad = 4 xz points (ccw seen from above); drop if off-terrain or inside the route footprint."""
        if min(index.clearance(x, z) for x, z in quad) < ROUTE_MARGIN_M:
            stats["dropped_route"] += 1
            return
        ys = [ground(x, z) for x, z in quad]
        if None in ys:
            stats["dropped_no_terrain"] += 1
            return
        cx, cz = sum(p[0] for p in quad) / 4, sum(p[1] for p in quad) / 4
        _, s, _ = index.nearest(cx, cz, 15)
        tile = tile_of(s if s is not None else 0.0)
        m = meshes[tile["id"]]
        base = len(m["positions"])
        m["positions"].extend((x, y + lift, z) for (x, z), y in zip(quad, ys))
        m[kind].extend([base, base + 2, base + 1, base, base + 3, base + 2])  # upward-facing (glTF ccw, Y up)
        if kind == "asphalt":
            footprints[tile["id"]].extend([(quad[0], quad[1], quad[2]), (quad[0], quad[2], quad[3])])
        stats["quads"] += 1

    elements = json.load(open(osm_path))["elements"]
    for way in elements:
        tags = way.get("tags", {})
        geometry = [to_xz(origin, g["lat"], g["lon"]) for g in way.get("geometry", [])]
        if len(geometry) < 2:
            continue
        highway = tags.get("highway")
        if highway in CLASS_WIDTH_M:
            if tags.get("service") in SKIP_SERVICE or tags.get("bridge") or tags.get("tunnel") or tags.get("area") == "yes":
                continue
            stats["ways"] += 1
            points = resample(geometry, STEP_M)
            half = way_width(tags) / 2
            sides = ribbon(points, half)
            for (l0, r0), (l1, r1) in zip(sides, sides[1:]):
                emit([r0, r1, l1, l0], "asphalt")
            if highway in MARKED and half * 2 >= 6.0 and tags.get("oneway") != "yes":
                line = ribbon(points, 0.06)
                for k, ((l0, r0), (l1, r1)) in enumerate(zip(line, line[1:])):
                    if k % 3 == 0:  # 4 m dash, 8 m gap
                        emit([r0, r1, l1, l0], "marking", lift=0.01)
        elif tags.get("amenity") == "parking" and geometry[0] == geometry[-1]:
            stats["parking_areas"] += 1
            for tri in rt._triangulate_xz(geometry[:-1]):
                a, b, c = tri
                emit([a, b, c, c], "asphalt")  # degenerate fourth corner keeps one code path

    removed = remove_covered_vegetation(pkg, man, footprints)
    for tile in tiles:
        m = meshes[tile["id"]]
        path = os.path.join(pkg, "tiles", tile["id"], "roadside.glb")
        if not m["asphalt"]:
            tile["files"].pop("roadside", None)
            if os.path.exists(path):
                os.remove(path)
            continue
        prims = [{"material": ASPHALT, "indices": m["asphalt"]}]
        if m["marking"]:
            prims.append({"material": MARKING, "indices": m["marking"]})
        rt.write_glb(path, {"name": f"{tile['id']}_roadside", "translation": [0.0, 0.0, 0.0],
                            "attributes": {"POSITION": m["positions"], "NORMAL": [(0.0, 1.0, 0.0)] * len(m["positions"])},
                            "primitives": prims})
        tile["files"]["roadside"] = f"tiles/{tile['id']}/roadside.glb"
    layer = man["layers"].setdefault("P2_corridor", {"status": "estimated", "files": []})
    if "tiles/*/roadside.glb" not in layer["files"]:
        layer["files"].append("tiles/*/roadside.glb")
    layer["context_streets"] = {
        "source": {"kind": "osm", "ref": "OpenStreetMap contributors, ODbL 1.0", "query": json.load(open(osm_path)).get("query")},
        "plan_geometry": "measured (OSM centrelines / car-park outlines)",
        "width": "estimated (OSM width / lanes tags, else per-class defaults)", "height": "estimated (draped on P1 terrain + 0.04 m)",
        "route_clearance_m": ROUTE_MARGIN_M, "stats": stats, "p3_instances_removed": removed}
    with open(os.path.join(pkg, "manifest.json"), "w") as f:
        json.dump(man, f, indent=1)
    credits = os.path.join(pkg, "CREDITS.md")
    text = open(credits).read() if os.path.exists(credits) else "# Sources and licences\n"
    line = "- Context streets and car parks (tiles/*/roadside.glb): OpenStreetMap contributors, ODbL 1.0. https://www.openstreetmap.org/copyright\n"
    if line not in text:
        open(credits, "w").write(text.rstrip("\n") + "\n" + line)
    print(json.dumps({"stats": stats, "p3_instances_removed": removed}))


def remove_covered_vegetation(pkg, man, footprints):
    """Drop P3 instances whose trunk stands on context asphalt (2 m grid broadphase)."""
    removed = 0
    for tile in man["tiles"]:
        path = tile["files"].get("vegetation") and os.path.join(pkg, tile["files"]["vegetation"])
        tris = [t for tid in footprints for t in footprints[tid]]  # neighbours' streets cross tile seams
        if not path or not tris:
            continue
        grid = {}
        for tri in tris:
            xs, zs = [p[0] for p in tri], [p[1] for p in tri]
            for gx in range(math.floor(min(xs) / 2), math.floor(max(xs) / 2) + 1):
                for gz in range(math.floor(min(zs) / 2), math.floor(max(zs) / 2) + 1):
                    grid.setdefault((gx, gz), []).append(tri)
        doc = json.load(open(path))
        changed = False
        for group in doc["groups"]:
            n = group["count"]
            keep = [i for i in range(n) if not any(_inside(group["data"][i * 10], group["data"][i * 10 + 2], t)
                    for t in grid.get((math.floor(group["data"][i * 10] / 2), math.floor(group["data"][i * 10 + 2] / 2)), ()))]
            if len(keep) == n:
                continue
            removed += n - len(keep)
            changed = True
            for key, values in group.items():  # per-instance arrays: s, lateral_offset_m, zone, ...
                if key != "data" and isinstance(values, list) and len(values) == n:
                    group[key] = [values[i] for i in keep]
            group["data"] = [v for i in keep for v in group["data"][i * 10:i * 10 + 10]]
            group["count"] = len(keep)
        if changed:
            doc["groups"] = [g for g in doc["groups"] if g["count"]]
            with open(path, "w") as f:
                json.dump(doc, f)
    return removed


def _inside(x, z, tri):
    (ax, az), (bx, bz), (cx, cz) = tri
    d1 = (x - bx) * (az - bz) - (ax - bx) * (z - bz)
    d2 = (x - cx) * (bz - cz) - (bx - cx) * (z - cz)
    d3 = (x - ax) * (cz - az) - (cx - ax) * (z - az)
    return not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0))


# ------------------------------------------------------------------ P4 buildings
BUILDING_REACH_M = 200.0   # footprint centroid within this distance of the route
LEVEL_M = 3.1
# Levels when OSM has no height / building:levels (estimated). Generic "yes" is mostly detached housing here.
CLASS_LEVELS = {"apartments": 6, "hotel": 8, "residential": 3, "commercial": 3, "retail": 2, "office": 4,
                "house": 2, "detached": 2, "semidetached_house": 2, "terrace": 2, "garage": 1, "garages": 1,
                "shed": 1, "roof": 1, "carport": 1, "kiosk": 1, "toilets": 1, "church": 3, "school": 2}
WALL_TINTS = [(0.82, 0.80, 0.74), (0.88, 0.87, 0.84), (0.75, 0.70, 0.62), (0.70, 0.72, 0.73), (0.85, 0.78, 0.66)]
FACADE = {"name": "facade_osm", "color": [1.0, 1.0, 1.0], "roughness": 0.8}  # tint per vertex (COLOR_0)
ROOF = {"name": "roof_osm", "color": [0.30, 0.30, 0.31], "roughness": 0.9}
ESTIMATED_BUILDING_PROTOTYPES = "coastal_apartment_"  # video-estimated P4 boxes that OSM footprints supersede


def building_height(tags):
    """(height_m, source) — measured tags first, then levels, then a class estimate."""
    for key in ("height", "building:height"):
        try:
            return float(tags[key].split()[0]), "osm height tag"
        except (KeyError, ValueError):
            pass
    try:
        return float(tags["building:levels"]) * LEVEL_M + 1.0, "osm building:levels"
    except (KeyError, ValueError):
        return CLASS_LEVELS.get(tags.get("building"), 2) * LEVEL_M + 0.6, "estimated from building class"


def buildings(pkg, osm_path):
    route, man, sem = veg._load(pkg)
    origin = route["coordinate_system"]["origin"]
    space = veg.Space(pkg, route, man, sem)
    index = RouteIndex(route, cell=20.0)
    tiles = man["tiles"]
    tile_of = lambda s: next((t for t in tiles if t["from_s"] <= s <= t["to_s"]), tiles[-1])
    meshes = {t["id"]: {"positions": [], "uv": [], "color": [], "facade": [], "roof": []} for t in tiles}
    stats = {"buildings": 0, "dropped_far": 0, "dropped_route": 0, "height_sources": {}}
    footprints, covered = [], {}
    for way in json.load(open(osm_path))["elements"]:
        tags = way.get("tags", {})
        if "building" not in tags or tags.get("building") in {"no", "construction"} or len(way.get("geometry", [])) < 4:
            continue
        ring = [to_xz(origin, g["lat"], g["lon"]) for g in way["geometry"]]
        if ring[0] == ring[-1]:
            ring = ring[:-1]
        if rt._polygon_area2_xz(ring) < 0:
            ring.reverse()  # counter-clockwise seen from above (+Y), in x/z
        cx, cz = sum(p[0] for p in ring) / len(ring), sum(p[1] for p in ring) / len(ring)
        distance, s, _ = index.nearest(cx, cz, math.ceil(BUILDING_REACH_M / 20.0))
        if s is None or distance > BUILDING_REACH_M:
            stats["dropped_far"] += 1
            continue
        if min(index.clearance(x, z) for x, z in ring) < 1.0:
            stats["dropped_route"] += 1  # P0 wins (e.g. passages over the path)
            continue
        ground = [space.ground_world(x, z) for x, z in ring + [(cx, cz)]]
        ground = [y for y in ground if y is not None]
        base = (min(ground) if ground else rm_elevation(route, s)) - 0.3  # sunk: no floating corners on slopes
        height, source = building_height(tags)
        stats["height_sources"][source] = stats["height_sources"].get(source, 0) + 1
        tint = WALL_TINTS[way["id"] % len(WALL_TINTS)]
        m = meshes[tile_of(s)["id"]]
        top = base + 0.3 + height
        run = 0.0
        for (ax, az), (bx, bz) in zip(ring, ring[1:] + ring[:1]):
            length = math.hypot(bx - ax, bz - az)
            k = len(m["positions"])
            m["positions"] += [(ax, base, az), (bx, base, bz), (bx, top, bz), (ax, top, az)]
            m["uv"] += [(run, 0.0), (run + length, 0.0), (run + length, top - base), (run, top - base)]  # metres
            m["color"] += [tint] * 4
            m["facade"] += [k, k + 2, k + 1, k, k + 3, k + 2]  # outward for a ccw ring
            run += length
        k = len(m["positions"])
        m["positions"] += [(x, top, z) for x, z in ring]
        m["uv"] += [(x, z) for x, z in ring]
        m["color"] += [tint] * len(ring)
        lookup = {p: i for i, p in enumerate(ring)}
        roof_tris = rt._triangulate_xz(ring)
        covered.setdefault(tile_of(s)["id"], []).extend(tuple(tri) for tri in roof_tris)
        for tri in roof_tris:
            ids = [k + lookup.get(p, min(range(len(ring)), key=lambda i: math.dist(ring[i], p))) for p in tri]
            m["roof"] += [ids[0], ids[2], ids[1]] if rt._polygon_area2_xz(tri) > 0 else ids
        footprints.append((cx, cz))
        stats["buildings"] += 1
    for tile in tiles:
        m = meshes[tile["id"]]
        path = os.path.join(pkg, "tiles", tile["id"], "buildings.glb")
        if not m["facade"]:
            tile["files"].pop("buildings", None)
            continue
        rt.write_glb(path, {"name": f"{tile['id']}_buildings", "translation": [0.0, 0.0, 0.0],
                            "attributes": {"POSITION": m["positions"], "TEXCOORD_0": m["uv"], "COLOR_0": m["color"]},
                            "primitives": [{"material": FACADE, "indices": m["facade"]},
                                           {"material": ROOF, "indices": m["roof"]}]})
        tile["files"]["buildings"] = f"tiles/{tile['id']}/buildings.glb"
    stats["estimated_p4_removed"] = remove_superseded_structures(pkg, man, footprints)
    stats["p3_instances_removed"] = remove_covered_vegetation(pkg, man, covered)  # P4 outranks P3
    layer = man["layers"]["P4_structures"]
    if "tiles/*/buildings.glb" not in layer.setdefault("files", []):
        layer["files"].append("tiles/*/buildings.glb")
    layer["osm_buildings"] = {
        "source": {"kind": "osm", "ref": "OpenStreetMap contributors, ODbL 1.0"},
        "plan_geometry": "measured (OSM footprints)", "height": "OSM height / levels tags, else estimated per class",
        "base": "lowest P1 terrain under the footprint - 0.3 m (estimated)", "uv": "metres (u along the facade, v up)",
        "reach_m": BUILDING_REACH_M, "stats": stats}
    with open(os.path.join(pkg, "manifest.json"), "w") as f:
        json.dump(man, f, indent=1)
    credits = os.path.join(pkg, "CREDITS.md")
    line = "- Buildings (tiles/*/buildings.glb): OpenStreetMap contributors, ODbL 1.0; heights partly estimated.\n"
    text = open(credits).read()
    if line not in text:
        open(credits, "w").write(text.rstrip("\n") + "\n" + line)
    print(json.dumps(stats))


def rm_elevation(route, s):
    smp = route["samples"]
    return smp["y"][min(range(len(smp["s"])), key=lambda i: abs(smp["s"][i] - s))]


def remove_superseded_structures(pkg, man, footprints, radius_m=60.0):
    """Drop video-estimated generic apartment boxes wherever OSM has real footprints nearby."""
    grid = {}
    for x, z in footprints:
        grid.setdefault((math.floor(x / radius_m), math.floor(z / radius_m)), []).append((x, z))
    near = lambda x, z: any(math.hypot(x - px, z - pz) <= radius_m for dx in (-1, 0, 1) for dz in (-1, 0, 1)
                            for px, pz in grid.get((math.floor(x / radius_m) + dx, math.floor(z / radius_m) + dz), ()))
    path = os.path.join(pkg, "structures", "structures.json")
    doc = json.load(open(path))
    gone = {o["object_id"] for o in doc["objects"]
            if str(o.get("prototype", "")).startswith(ESTIMATED_BUILDING_PROTOTYPES) and o["importance"] == "low"
            and o.get("source", {}).get("estimated") and near(o["transform"]["position"][0], o["transform"]["position"][2])}
    if not gone:
        return 0
    doc["objects"] = [o for o in doc["objects"] if o["object_id"] not in gone]
    json.dump(doc, open(path, "w"), indent=1)
    for tile in man["tiles"]:
        tpath = os.path.join(pkg, tile["files"]["structures"])
        td = json.load(open(tpath))
        for g in td["groups"]:
            keep = [i for i, oid in enumerate(g["object_id"]) if oid not in gone]
            dropped = g["count"] - len(keep)
            if dropped and tile.get("structures", {}).get(g["semantic_type"]):
                tile["structures"][g["semantic_type"]] -= dropped
                if tile["structures"][g["semantic_type"]] <= 0:
                    del tile["structures"][g["semantic_type"]]
            g["data"] = [v for i in keep for v in g["data"][i * 10:i * 10 + 10]]
            g["object_id"] = [g["object_id"][i] for i in keep]
            g["count"] = len(keep)
        td["groups"] = [g for g in td["groups"] if g["count"]]
        json.dump(td, open(tpath, "w"))
    return len(gone)


if __name__ == "__main__":
    command, pkg, osm = sys.argv[1:4]
    if command == "fetch":
        fetch(pkg, osm, *(float(a) for a in sys.argv[4:5]))
    elif command == "buildings":
        buildings(pkg, osm)
    else:
        build(pkg, osm)
