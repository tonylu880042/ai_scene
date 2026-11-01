#!/usr/bin/env python3
"""P2 context streets from OpenStreetMap: vehicular roads, parking aisles and car parks near the route,
draped on the shipped P1 terrain and written as tiles/<NN>/roadside.glb. Never touches P0/P1 data.

  python3 tools/osm_context.py fetch <package> <osm.json> [margin_m]   Overpass query around the route
  python3 tools/osm_context.py build <package> <osm.json>              roadside.glb + manifest + licence
  python3 tools/osm_context.py fetch-skyline <package> <skyline.json>  measured-height buildings within 1.5 km
  python3 tools/osm_context.py fetch-water <package> <water.json>       OSM coastline + water areas around the route
  python3 tools/osm_context.py shoreline <package> <water.json> <from_s> <to_s> <out.json>
                                    OSM-measured water edge per 2 m -> coast_profiles replacing that span only
  python3 tools/osm_context.py buildings <package> <osm.json> [skyline.json]
                                    tiles/<NN>/buildings.glb (P4), environment/skyline_buildings.glb (P5) + licence

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


def fetch(pkg, out_path, margin_m=150.0, skyline=False, water=False):
    route = json.load(open(os.path.join(pkg, "route", "route.json")))
    origin = route["coordinate_system"]["origin"]
    xs, zs = route["samples"]["x"], route["samples"]["z"]
    south, west = to_latlon(origin, min(xs) - margin_m, max(zs) + margin_m)
    north, east = to_latlon(origin, max(xs) + margin_m, min(zs) - margin_m)
    bbox = f"{south:.6f},{west:.6f},{north:.6f},{east:.6f}"
    query = (f'[out:json][timeout:180];(way["highway"~"^({"|".join(CLASS_WIDTH_M)})$"]({bbox});'
             f'way["amenity"="parking"]({bbox});way["building"]({bbox}););out geom tags;')
    if water:
        query = (f'[out:json][timeout:180];(way["natural"="coastline"]({bbox});way["natural"="water"]({bbox});'
                 f'relation["natural"="water"]({bbox});way["waterway"="riverbank"]({bbox}););out geom tags;')
    if skyline:  # only buildings that carry a measured height or level count
        query = f'[out:json][timeout:180];(way["building"]["height"]({bbox});way["building"]["building:levels"]({bbox}););out geom tags;'
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

    def foreign_clearance(self, x, z, s, min_ds=60.0):
        """Distance to the road edge of another traversal (route samples more than min_ds away along s)."""
        best = math.inf
        gx, gz = math.floor(x / self.cell), math.floor(z / self.cell)
        for dx in (-1, 0, 1):
            for dz in (-1, 0, 1):
                for px, pz, ps, half in self.grid.get((gx + dx, gz + dz), ()):
                    if abs(ps - s) > min_ds:
                        best = min(best, math.hypot(x - px, z - pz) - half)
        return best


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


# ------------------------------------------------------------------ P4 buildings / P5 skyline
BUILDING_REACH_M = 200.0   # P4: footprint centroid within this distance of the route
SKYLINE_REACH_M = 1500.0   # P5: measured towers beyond the P4 reach, up to this distance
SKYLINE_MIN_HEIGHT_M = 25.0
LEVEL_M = 3.1
NEIGHBOUR_RADIUS_M = 120.0  # unmeasured heights: median of measured OSM neighbours within this radius ...
NEIGHBOUR_MIN = 3           # ... when at least this many exist, else the class estimate below
NEIGHBOUR_MIN_AREA_M2 = 150.0  # gazebos, kiosks and sheds next to towers keep their class estimate
NEIGHBOUR_MAX_M = 6 * 3.1 + 1.0  # an inherited height never makes an unmeasured footprint a tower
CLASS_LEVELS = {"apartments": 6, "hotel": 8, "residential": 3, "commercial": 3, "retail": 2, "office": 4,
                "house": 2, "detached": 2, "semidetached_house": 2, "terrace": 2, "garage": 1, "garages": 1,
                "shed": 1, "roof": 1, "carport": 1, "kiosk": 1, "toilets": 1, "church": 3, "school": 2}
LOW_CLASSES = {"garage", "garages", "shed", "roof", "carport", "kiosk", "toilets"}  # never inherit tower heights
HOUSE_CLASSES = {"yes", "house", "detached", "semidetached_house", "terrace", "residential", "bungalow"}
WALL_TINTS = [(0.82, 0.80, 0.74), (0.88, 0.87, 0.84), (0.75, 0.70, 0.62), (0.70, 0.72, 0.73), (0.85, 0.78, 0.66)]
ROOF_TINTS = [(0.45, 0.22, 0.14), (0.32, 0.32, 0.33), (0.52, 0.29, 0.18), (0.24, 0.26, 0.28)]  # terracotta / grey
FACADE = {"name": "facade_osm", "color": [1.0, 1.0, 1.0], "roughness": 0.8}  # tint per vertex (COLOR_0)
ROOF = {"name": "roof_osm", "color": [0.30, 0.30, 0.31], "roughness": 0.9}
ROOF_TILE = {"name": "roof_tile_osm", "color": [1.0, 1.0, 1.0], "roughness": 0.85}
ESTIMATED_BUILDING_PROTOTYPES = "coastal_apartment_"  # video-estimated P4 boxes that OSM footprints supersede


def measured_height(tags):
    """(height_m, source) from OSM height / levels tags, or None."""
    for key in ("height", "building:height"):
        try:
            return float(tags[key].split()[0]), "osm height tag"
        except (KeyError, ValueError):
            pass
    try:
        return float(tags["building:levels"]) * LEVEL_M + 1.0, "osm building:levels"
    except (KeyError, ValueError):
        return None


def building_height(tags, neighbours=(), area_m2=0.0):
    """(height_m, source): measured tags, else the (capped) median of measured neighbours for a sizeable plain
    building, else a class estimate."""
    measured = measured_height(tags)
    if measured:
        return measured
    if len(neighbours) >= NEIGHBOUR_MIN and tags.get("building") not in LOW_CLASSES and "amenity" not in tags \
            and area_m2 >= NEIGHBOUR_MIN_AREA_M2:
        ordered = sorted(neighbours)
        return min(ordered[len(ordered) // 2], NEIGHBOUR_MAX_M), "estimated: median of measured OSM neighbours"
    return CLASS_LEVELS.get(tags.get("building"), 2) * LEVEL_M + 0.6, "estimated from building class"


def footprints_of(osm_path, origin):
    """(way, tags, ccw ring in xz, centroid) for every closed building way."""
    for way in json.load(open(osm_path))["elements"]:
        tags = way.get("tags", {})
        if "building" not in tags or tags.get("building") in {"no", "construction"} or len(way.get("geometry", [])) < 4:
            continue
        ring = [to_xz(origin, g["lat"], g["lon"]) for g in way["geometry"]]
        if ring[0] == ring[-1]:
            ring = ring[:-1]
        if rt._polygon_area2_xz(ring) < 0:
            ring.reverse()  # counter-clockwise seen from above (+Y), in x/z
        yield way, tags, ring, (sum(p[0] for p in ring) / len(ring), sum(p[1] for p in ring) / len(ring))


def extrude(m, ring, base, top, tint, roof_tint, hipped):
    """Walls (UV metres) + flat or hipped roof into mesh dict m; returns the roof footprint triangles (xz)."""
    run = 0.0
    for (ax, az), (bx, bz) in zip(ring, ring[1:] + ring[:1]):
        length = math.hypot(bx - ax, bz - az)
        k = len(m["positions"])
        m["positions"] += [(ax, base, az), (bx, base, bz), (bx, top, bz), (ax, top, az)]
        m["uv"] += [(run, 0.0), (run + length, 0.0), (run + length, top - base), (run, top - base)]
        m["color"] += [tint] * 4
        m["facade"] += [k, k + 2, k + 1, k, k + 3, k + 2]  # outward for a ccw ring
        run += length
    footprint = rt._triangulate_xz(ring)
    if hipped:  # pyramid hip to the centroid: reads as a tiled house roof from the street
        cx, cz = sum(p[0] for p in ring) / len(ring), sum(p[1] for p in ring) / len(ring)
        rise = min(3.0, 0.25 * math.sqrt(abs(rt._polygon_area2_xz(ring)) / 2))
        for (ax, az), (bx, bz) in zip(ring, ring[1:] + ring[:1]):
            k = len(m["positions"])
            m["positions"] += [(ax, top, az), (bx, top, bz), (cx, top + rise, cz)]
            m["uv"] += [(ax, az), (bx, bz), (cx, cz)]
            m["color"] += [roof_tint] * 3
            m["tile_roof"] += [k, k + 2, k + 1]  # upward for a ccw ring
        return footprint
    k = len(m["positions"])
    m["positions"] += [(x, top, z) for x, z in ring]
    m["uv"] += [(x, z) for x, z in ring]
    m["color"] += [tint] * len(ring)
    lookup = {p: i for i, p in enumerate(ring)}
    for tri in footprint:
        ids = [k + lookup.get(p, min(range(len(ring)), key=lambda i: math.dist(ring[i], p))) for p in tri]
        m["roof"] += [ids[0], ids[2], ids[1]] if rt._polygon_area2_xz(tri) > 0 else ids
    return footprint


def write_buildings_glb(path, name, m):
    prims = [{"material": FACADE, "indices": m["facade"]}]
    if m["roof"]:
        prims.append({"material": ROOF, "indices": m["roof"]})
    if m["tile_roof"]:
        prims.append({"material": ROOF_TILE, "indices": m["tile_roof"]})
    rt.write_glb(path, {"name": name, "translation": [0.0, 0.0, 0.0],
                        "attributes": {"POSITION": m["positions"], "TEXCOORD_0": m["uv"], "COLOR_0": m["color"]},
                        "primitives": prims})


def buildings(pkg, osm_path, skyline_path=None):
    route, man, sem = veg._load(pkg)
    origin = route["coordinate_system"]["origin"]
    space = veg.Space(pkg, route, man, sem)
    index = RouteIndex(route, cell=20.0)
    water_level = min((c.get("water_level_m", 0.0) for c in man["visual_terrain"].get("coast_profiles", [])), default=0.0)
    tiles = man["tiles"]
    tile_of = lambda s: next((t for t in tiles if t["from_s"] <= s <= t["to_s"]), tiles[-1])
    new_mesh = lambda: {"positions": [], "uv": [], "color": [], "facade": [], "roof": [], "tile_roof": []}
    meshes = {t["id"]: new_mesh() for t in tiles}
    stats = {"buildings": 0, "dropped_far": 0, "dropped_route": 0, "dropped_on_p1_water": [], "hipped_roofs": 0,
             "height_sources": {}}
    footprints, covered, kept, measured = [], {}, [], {}
    for way, tags, ring, (cx, cz) in footprints_of(osm_path, origin):
        distance, s, _ = index.nearest(cx, cz, math.ceil(BUILDING_REACH_M / 20.0))
        if s is None or distance > BUILDING_REACH_M:
            stats["dropped_far"] += 1
            continue
        if min(index.clearance(x, z) for x, z in ring) < 1.0:
            stats["dropped_route"] += 1  # P0 wins (e.g. passages over the path)
            continue
        ground = [y for y in (space.ground_world(x, z) for x, z in ring + [(cx, cz)]) if y is not None]
        if ground and max(ground) < water_level + 0.1:  # P1 says water here: P4 may not contradict it
            stats["dropped_on_p1_water"].append({"osm_way": way["id"], "s": round(s, 1), "building": tags.get("building")})
            continue
        kept.append((way, tags, ring, cx, cz, s, ground))
        h = measured_height(tags)
        if h:
            measured.setdefault((math.floor(cx / NEIGHBOUR_RADIUS_M), math.floor(cz / NEIGHBOUR_RADIUS_M)), []).append((cx, cz, h[0]))
    for way, tags, ring, cx, cz, s, ground in kept:
        gx, gz = math.floor(cx / NEIGHBOUR_RADIUS_M), math.floor(cz / NEIGHBOUR_RADIUS_M)
        neighbours = [h for dx in (-1, 0, 1) for dz in (-1, 0, 1) for x, z, h in measured.get((gx + dx, gz + dz), ())
                      if math.hypot(x - cx, z - cz) <= NEIGHBOUR_RADIUS_M]
        area = abs(rt._polygon_area2_xz(ring)) / 2
        height, source = building_height(tags, neighbours, area)
        stats["height_sources"][source] = stats["height_sources"].get(source, 0) + 1
        base = (min(ground) if ground else rm_elevation(route, s)) - 0.3  # sunk: no floating corners on slopes
        hipped = tags.get("building") in HOUSE_CLASSES and height <= 2 * LEVEL_M + 1.0 and area < 400 and len(ring) <= 12 \
            and tags.get("roof:shape", "hipped") != "flat"
        stats["hipped_roofs"] += hipped
        footprint = extrude(meshes[tile_of(s)["id"]], ring, base, base + 0.3 + height,
                            WALL_TINTS[way["id"] % len(WALL_TINTS)], ROOF_TINTS[way["id"] % len(ROOF_TINTS)], hipped)
        covered.setdefault(tile_of(s)["id"], []).extend(tuple(tri) for tri in footprint)
        footprints.append((cx, cz))
        stats["buildings"] += 1
    stats["dropped_on_p1_water_count"] = len(stats["dropped_on_p1_water"])
    for tile in tiles:
        m = meshes[tile["id"]]
        if not m["facade"]:
            tile["files"].pop("buildings", None)
            continue
        write_buildings_glb(os.path.join(pkg, "tiles", tile["id"], "buildings.glb"), f"{tile['id']}_buildings", m)
        tile["files"]["buildings"] = f"tiles/{tile['id']}/buildings.glb"
    stats["estimated_p4_removed"] = remove_superseded_structures(pkg, man, footprints)
    stats["p3_instances_removed"] = remove_covered_vegetation(pkg, man, covered)  # P4 outranks P3
    layer = man["layers"]["P4_structures"]
    if "tiles/*/buildings.glb" not in layer.setdefault("files", []):
        layer["files"].append("tiles/*/buildings.glb")
    layer["osm_buildings"] = {
        "source": {"kind": "osm", "ref": "OpenStreetMap contributors, ODbL 1.0"},
        "plan_geometry": "measured (OSM footprints)",
        "height": "OSM height / levels tags; else median of measured OSM neighbours within %g m; else per-class estimate" % NEIGHBOUR_RADIUS_M,
        "roof": "flat; estimated pyramid hip on small houses (<= 2 levels, < 400 m2) unless roof:shape=flat",
        "base": "lowest P1 terrain under the footprint - 0.3 m (estimated); footprints on P1 water are dropped",
        "uv": "metres (u along the facade, v up; roofs world x/z)", "reach_m": BUILDING_REACH_M, "stats": stats}
    if skyline_path:
        skyline(pkg, man, route, index, skyline_path)
    with open(os.path.join(pkg, "manifest.json"), "w") as f:
        json.dump(man, f, indent=1)
    credits = os.path.join(pkg, "CREDITS.md")
    line = "- Buildings (tiles/*/buildings.glb, environment/skyline_buildings.glb): OpenStreetMap contributors, ODbL 1.0; heights partly estimated.\n"
    text = open(credits).read()
    if line not in text:
        open(credits, "w").write(text.rstrip("\n") + "\n" + line)
    print(json.dumps({k: v for k, v in stats.items() if k != "dropped_on_p1_water"}))


def skyline(pkg, man, route, index, osm_path):
    """P5: measured towers (>= SKYLINE_MIN_HEIGHT_M) beyond the P4 reach, one static mesh for the whole route."""
    origin = route["coordinate_system"]["origin"]
    m = {"positions": [], "uv": [], "color": [], "facade": [], "roof": [], "tile_roof": []}
    count = 0
    for way, tags, ring, (cx, cz) in footprints_of(osm_path, origin):
        h = measured_height(tags)
        if not h or h[0] < SKYLINE_MIN_HEIGHT_M:
            continue
        distance, s, _ = index.nearest(cx, cz, math.ceil(SKYLINE_REACH_M / 20.0))
        if s is None or not BUILDING_REACH_M < distance <= SKYLINE_REACH_M:
            continue
        base = rm_elevation(route, s) - 1.0  # beyond P1: estimated from the nearest route elevation
        extrude(m, ring, base, base + 1.0 + h[0], WALL_TINTS[way["id"] % len(WALL_TINTS)], None, False)
        count += 1
    path = os.path.join(pkg, "environment", "skyline_buildings.glb")
    if not count:
        return
    write_buildings_glb(path, "skyline_buildings", m)
    layer = man["layers"].setdefault("P5_distant", {"status": "generated", "files": []})
    if "environment/skyline_buildings.glb" not in layer.setdefault("files", []):
        layer["files"].append("environment/skyline_buildings.glb")
    layer["skyline_buildings"] = {"source": {"kind": "osm", "ref": "OpenStreetMap contributors, ODbL 1.0"},
                                  "selection": "OSM height / levels >= %g m, %g-%g m from the route" % (SKYLINE_MIN_HEIGHT_M, BUILDING_REACH_M, SKYLINE_REACH_M),
                                  "base": "nearest route elevation - 1 m (estimated)", "count": count}


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


# ------------------------------------------------------------------ P1 shoreline evidence
class Water:
    """Point-in-water from OSM: inside a natural=water polygon, or on the water (right-hand) side of the nearest
    natural=coastline segment within 400 m (OSM coastlines keep land on their left)."""

    def __init__(self, osm_path, origin, cell=50.0):
        self.cell, self.coast, self.polygons = cell, {}, []
        for e in json.load(open(osm_path))["elements"]:
            tags = e.get("tags", {})
            rings = [e["geometry"]] if e["type"] == "way" else [m["geometry"] for m in e.get("members", [])
                                                              if m.get("role") == "outer" and m.get("geometry")]
            for ring in rings:
                pts = [to_xz(origin, g["lat"], g["lon"]) for g in ring]
                if tags.get("natural") == "coastline":
                    for a, b in zip(pts, pts[1:]):
                        for gx in range(math.floor(min(a[0], b[0]) / cell), math.floor(max(a[0], b[0]) / cell) + 1):
                            for gz in range(math.floor(min(a[1], b[1]) / cell), math.floor(max(a[1], b[1]) / cell) + 1):
                                self.coast.setdefault((gx, gz), []).append((a, b))
                elif len(pts) >= 4 and pts[0] == pts[-1]:
                    xs, zs = [p[0] for p in pts], [p[1] for p in pts]
                    self.polygons.append(((min(xs), max(xs), min(zs), max(zs)), pts))

    def __call__(self, x, z):
        for (x0, x1, z0, z1), pts in self.polygons:
            if x0 <= x <= x1 and z0 <= z <= z1 and _point_in_ring(x, z, pts):
                return True
        best = None
        gx, gz = math.floor(x / self.cell), math.floor(z / self.cell)
        for r in range(0, 9):  # rings of cells out to 400 m
            for dx in range(-r, r + 1):
                for dz in range(-r, r + 1):
                    if max(abs(dx), abs(dz)) != r:
                        continue
                    for a, b in self.coast.get((gx + dx, gz + dz), ()):
                        ex, ez = b[0] - a[0], b[1] - a[1]
                        t = max(0.0, min(1.0, ((x - a[0]) * ex + (z - a[1]) * ez) / ((ex * ex + ez * ez) or 1e-9)))
                        d = math.hypot(x - a[0] - t * ex, z - a[1] - t * ez)
                        if best is None or d < best[0]:
                            best = (d, ex * (z - a[1]) - ez * (x - a[0]))
            if best is not None and best[0] < (r - 1) * self.cell:
                break
        # x east, z south: with north up, a point on the right of a segment has a positive cross in this frame
        return best is not None and best[1] > 0


def _point_in_ring(x, z, pts):
    inside = False
    for (ax, az), (bx, bz) in zip(pts, pts[1:]):
        if (az > z) != (bz > z) and x < ax + (z - az) * (bx - ax) / (bz - az):
            inside = not inside
    return inside


def water_edge(route, water, s, side, reach_m=150.0, step_m=0.5):
    """Lateral distance from the centreline to the first OSM water along the left/right normal, or None."""
    import route_model as rm
    p = rm.sample(route, s)
    lx, lz = rm.left_vector(p["heading_deg"])
    sign = 1 if side == "left" else -1
    u = p["width_left_m" if side == "left" else "width_right_m"]
    while u <= reach_m:
        if water(p["x"] + sign * lx * u, p["z"] + sign * lz * u):
            return u
        u += step_m
    return None


def water_band(route, water, s, side, reach_m=150.0, step_m=0.5, index=None, foreign_clearance_m=3.0):
    """(near, far) of the first OSM water interval along the left/right normal; far None if it reaches reach_m;
    None if no water within reach. With a RouteIndex, the interval also ends foreign_clearance_m before another
    traversal of the route (P1 pins terrain to that road's edge, so water may not run into it)."""
    import route_model as rm
    p = rm.sample(route, s)
    lx, lz = rm.left_vector(p["heading_deg"])
    sign = 1 if side == "left" else -1
    u, near = p["width_left_m" if side == "left" else "width_right_m"], None
    while u <= reach_m:
        x, z = p["x"] + sign * lx * u, p["z"] + sign * lz * u
        if index is not None and index.foreign_clearance(x, z, s) < foreign_clearance_m:
            return (near, max(u - foreign_clearance_m, near + step_m)) if near is not None else None
        wet = water(x, z)
        if wet and near is None:
            near = u
        elif not wet and near is not None:
            return near, u
        u += step_m
    return (near, None) if near is not None else None


def _median(values):
    values = sorted(values)
    return values[len(values) // 2] if values else None


def shoreline(pkg, water_path, from_s, to_s, out_path, chunk_m=2.0, bank_width_m=6.0, max_route_y_m=5.0):
    """Replace every coast profile inside [from_s, to_s] (both sides) with OSM-measured 2 m chunks: the first OSM
    water interval along the route normal, near and far edges each a median of 5 chunks (10 m) so the waterline
    does not flip between terrain columns. A band with land beyond it (creek / channel) sets water_far_m. A chunk
    with no OSM water within reach is land: no profile. Where an original two-sided (bridge) profile covers a
    route above max_route_y_m (the deck or its ramps) the original profiles are kept: P1 terrain follows the deck height, so a narrow measured band would
    become a trench. Profiles outside the span keep their values (straddling ones are clipped at the span ends),
    so terrain outside it does not change."""
    route = json.load(open(os.path.join(pkg, "route", "route.json")))
    man = json.load(open(os.path.join(pkg, "manifest.json")))
    water = Water(water_path, route["coordinate_system"]["origin"])
    index = RouteIndex(route)
    stations = [from_s + k * chunk_m for k in range(int(round((to_s - from_s) / chunk_m)))]
    out, replaced, report = [], [], {"span": [from_s, to_s], "measured": {}}
    for prof in man["visual_terrain"]["coast_profiles"]:
        if prof["to_s"] <= from_s or prof["from_s"] >= to_s:
            out.append(prof)
            continue
        replaced.append(prof)
        if prof["from_s"] < from_s:
            out.append(dict(prof, to_s=from_s))
        if prof["to_s"] > to_s:
            out.append(dict(prof, from_s=to_s))
    template = replaced[0] if replaced else {"water_level_m": 0, "sand_width_m": 2}
    import route_model as rm
    elevated = [rm.sample(route, s + chunk_m / 2)["y"] > max_route_y_m and
                any(p["side"] == "both" and p["from_s"] <= s + chunk_m / 2 <= p["to_s"] for p in replaced) for s in stations]
    report["kept_original_on_elevated_chunks"] = sum(elevated)
    for i, a in enumerate(stations):
        if elevated[i]:
            b = min(a + chunk_m, to_s)
            out += [dict(p, from_s=round(max(a, p["from_s"]), 4), to_s=round(min(b, p["to_s"]), 4))
                    for p in replaced if p["from_s"] < b and p["to_s"] > a]
    for side in ("left", "right"):
        bands = [water_band(route, water, s + chunk_m / 2, side, index=index) for s in stations]
        report["measured"][side] = bands
        for i, a in enumerate(stations):
            window = [v for v in bands[max(0, i - 2):i + 3] if v is not None]
            if elevated[i] or bands[i] is None or not window:
                continue  # OSM: land on this side
            near = _median([v[0] for v in window])
            fars = [v[1] for v in window]
            # open water only when most of the window agrees: one far-reaching chunk must not flood the band out to
            # another traversal of the route (its road edge would pin water-bed terrain up to path height)
            far = None if sum(f is None for f in fars) * 2 > len(fars) else _median([f for f in fars if f is not None])
            width = rm_width(route, a, side)
            prof = {"from_s": round(a, 4), "to_s": round(min(a + chunk_m, to_s), 4), "side": side, "water_edge_m": round(near, 2),
                    "water_level_m": template.get("water_level_m", 0), "bank_width_m": round(min(bank_width_m, max(0.5, near - width)), 2),
                    "sand_width_m": template.get("sand_width_m", 2),
                    "source": {"kind": "osm", "estimated": False, "confidence": 0.75,
                               "ref": "OpenStreetMap natural=coastline / natural=water, ODbL 1.0",
                               "note": "plan-view water band measured along the route normal (0.5 m steps, median of 5 x 2 m); bank shape is the estimated profile model"}}
            if far is not None and far > near + 2.0:
                prof["water_far_m"] = round(far, 2)
            out.append(prof)
    out.sort(key=lambda p: (p["from_s"], p["side"]))
    json.dump({"coast_profiles": out, "report": dict(report, replaced_profiles=replaced)}, open(out_path, "w"), indent=1)
    for side in ("left", "right"):
        v = [b for b in report["measured"][side] if b is not None]
        print(side, f"{len(v)}/{len(stations)} chunks with water, {sum(b[1] is not None for b in v)} with land beyond")


def semantics_from_coast(pkg, spans, piece_m=10.0, tree_reach_m=40.0):
    """P2 follows P1 inside spans: on each side, grass / water / vegetation_zone zones are rebuilt per piece_m from
    the shipped coast profiles (grass to the near water edge, water to the far edge of a band, grass beyond it;
    trees on the land side up to tree_reach_m or 1 m short of the water). Zones straddling a span end are clipped;
    every other zone is untouched. Returns the removed semantic zone ids (for vegetation.regenerate)."""
    route = json.load(open(os.path.join(pkg, "route", "route.json")))
    man = json.load(open(os.path.join(pkg, "manifest.json")))
    path = os.path.join(pkg, "semantics", "semantics.json")
    sem = json.load(open(path))
    profiles, ext = man["visual_terrain"]["coast_profiles"], sem.get("extent_m", 100.0)
    types = {"grass", "water", "vegetation_zone"}
    inside = lambda z: any(z["from_s"] < b and z["to_s"] > a for a, b in spans)
    removed = [z for z in sem["zones"] if z["semantic_type"] in types and z["side"] in ("left", "right") and inside(z)]
    keep = [z for z in sem["zones"] if z not in removed]
    next_id = [max(int(z["id"][1:]) for z in sem["zones"] if z["id"][1:].isdigit()) + 1]

    def zone(t, side, a, b, lo, hi, attrs, source, confidence):
        if hi - lo < 0.05 or b - a < 0.05:
            return None
        lat = [round(lo, 3), round(hi, 3)] if side == "left" else [round(-hi, 3), round(-lo, 3)]
        z = {"id": "z%04d" % next_id[0], "semantic_type": t, "side": side, "from_s": round(a, 4), "to_s": round(b, 4),
             "lateral_offset_m": lat, "vertical_offset_m": None, "confidence": confidence, "attributes": attrs, "source": source}
        next_id[0] += 1
        return z

    added = []
    for z in removed:  # parts outside every span keep their original values
        cuts = [(z["from_s"], z["to_s"])]
        for a, b in spans:
            cuts = [piece for lo, hi in cuts for piece in ((lo, min(hi, a)), (max(lo, b), hi)) if piece[1] - piece[0] > 0.05]
        for lo, hi in cuts:
            added.append(dict(z, id="z%04d" % next_id[0], from_s=round(lo, 4), to_s=round(hi, 4)))
            next_id[0] += 1
    derived = {"kind": "procedural", "estimated": True, "ref": "P1 OSM-measured coast profiles (tools/osm_context.py shoreline)",
               "note": "ground cover follows the shipped shoreline; tree species / density carried over from the replaced video zone"}
    osm = {"kind": "map", "estimated": False, "ref": "OpenStreetMap natural=coastline / natural=water, ODbL 1.0"}
    for a, b in spans:
        for side in ("left", "right"):
            old = [z for z in removed if z["side"] == side and z["from_s"] < b and z["to_s"] > a]
            first = lambda t: next((z for z in old if z["semantic_type"] == t), None) or \
                next((z for z in removed if z["semantic_type"] == t), None)
            grass_t, water_t, tree_t = first("grass"), first("water"), next((z for z in old if z["semantic_type"] == "vegetation_zone"), None)
            k = a
            while k < b - 1e-6:
                e = min(k + piece_m, b)
                surfaces = [z for z in keep if z["semantic_type"] in ("road", "trail", "sidewalk", "bridge", "tunnel")
                            and z["from_s"] < e and z["to_s"] > k]
                inner = max([max(rm_width(route, s, side) for s in (k, (k + e) / 2, e)) + 0.025] +
                            [z["lateral_offset_m"][1] if side == "left" else -z["lateral_offset_m"][0] for z in surfaces])
                bands = [rt.coast_profile(profiles, s, side) for s in [k + 0.5 + i for i in range(int(e - k))] or [k]]
                wet = [p for p in bands if p]
                near = max(inner, min(p["water_edge_m"] for p in wet)) if wet else None
                fars = [p.get("water_far_m") for p in wet]
                far = max(fars) if wet and all(f is not None for f in fars) else None
                if far is not None and far >= ext:
                    far = None
                if near is not None and near >= ext:
                    near = None  # water only beyond the semantics extent
                g_attrs, w_attrs = (grass_t or {}).get("attributes", {"kind": "lawn"}), dict((water_t or {}).get("attributes", {"kind": "creek"}))
                if near is None:
                    added.append(zone("grass", side, k, e, inner, ext, g_attrs, derived, 0.6))
                else:
                    w_attrs.update(level_m=0, edge_m=round(near, 2))
                    added += [zone("grass", side, k, e, inner, near, g_attrs, derived, 0.6),
                              zone("water", side, k, e, near, far if far is not None else ext, w_attrs, osm, 0.75)]
                    if far is not None:
                        added.append(zone("grass", side, k, e, far, ext, g_attrs, derived, 0.6))
                if tree_t:
                    lo = abs(tree_t["lateral_offset_m"][0 if side == "left" else 1])
                    hi = min(tree_reach_m, near - 1.0) if near is not None else tree_reach_m
                    added.append(zone("vegetation_zone", side, k, e, lo, hi, tree_t["attributes"], derived, 0.5))
                k = e
    sem["zones"] = keep + [z for z in added if z]
    sem["zones"].sort(key=lambda z: (z["from_s"], z["id"]))
    json.dump(sem, open(path, "w"), indent=1)
    print(f"semantics: replaced {len(removed)} zones with {len([z for z in added if z])} in {len(spans)} spans")
    return {z["id"] for z in removed}


def rm_width(route, s, side):
    import route_model as rm
    return rm.sample(route, s)["width_left_m" if side == "left" else "width_right_m"]


if __name__ == "__main__":
    command, pkg, osm = sys.argv[1:4]
    if command == "fetch":
        fetch(pkg, osm, *(float(a) for a in sys.argv[4:5]))
    elif command == "fetch-water":
        fetch(pkg, osm, 400.0, water=True)
    elif command == "shoreline":
        shoreline(pkg, osm, float(sys.argv[4]), float(sys.argv[5]), sys.argv[6])
    elif command == "fetch-skyline":
        fetch(pkg, osm, SKYLINE_REACH_M, skyline=True)
    elif command == "buildings":
        buildings(pkg, osm, *sys.argv[4:5])
    else:
        build(pkg, osm)
