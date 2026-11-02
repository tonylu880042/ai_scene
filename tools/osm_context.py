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
    building_query = ''.join(f'{kind}["{tag}"]({bbox});' for kind in ('way', 'relation')
                             for tag in ('building', 'building:part'))
    query = (f'[out:json][timeout:180];(way["highway"~"^({"|".join(CLASS_WIDTH_M)})$"]({bbox});'
             f'way["amenity"="parking"]({bbox});{building_query});out body geom;')
    if water:
        query = (f'[out:json][timeout:180];(way["natural"="coastline"]({bbox});way["natural"="water"]({bbox});'
                 f'relation["natural"="water"]({bbox});way["waterway"="riverbank"]({bbox}););out body geom;')
    if skyline:
        # Fetch whole complexes: a tower can carry height while the podium/part carries min_height.
        query = f'[out:json][timeout:180];({building_query});out body geom;'
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
                "shed": 1, "roof": 1, "carport": 1, "shelter": 1, "canopy": 1, "gazebo": 1, "pergola": 1, "kiosk": 1, "toilets": 1, "church": 3, "school": 2}
LOW_CLASSES = {"garage", "garages", "shed", "roof", "carport", "shelter", "canopy", "gazebo", "pergola", "kiosk", "toilets"}  # never inherit tower heights
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


def number(tags, key, default=None):
    try:
        value = float(str(tags[key]).split()[0])
        return value if math.isfinite(value) and value >= 0 else default
    except (KeyError, ValueError, IndexError):
        return default


def minimum_height(tags):
    h = number(tags, 'min_height')
    if h is not None:
        return h, 'osm min_height'
    n = number(tags, 'building:min_level')
    if n is not None:
        return round(n * LEVEL_M, 6), 'osm building:min_level × 3.1 m (conversion estimated)'
    return 0., 'estimated ground level'


def _ring(points, origin):
    ring = [to_xz(origin, p['lat'], p['lon']) for p in points]
    if len(ring) > 1 and ring[0] == ring[-1]:
        ring.pop()
    ring = [p for i, p in enumerate(ring) if p != ring[i-1]]
    if len(ring) < 3 or abs(rt._polygon_area2_xz(ring)) < .01:
        return []
    return ring if rt._polygon_area2_xz(ring) > 0 else ring[::-1]


def _stitch(members):
    """Join reversible OSM member ways; reject an incomplete ring instead of closing it by guess."""
    pending = [list(m['geometry']) for m in members if m.get('geometry')]
    rings = []
    while pending:
        chain = pending.pop(0)
        while chain[0] != chain[-1]:
            for i, seg in enumerate(pending):
                if chain[-1] == seg[0] or chain[-1] == seg[-1]:
                    if chain[-1] == seg[-1]: seg.reverse()
                    chain.extend(seg[1:]); pending.pop(i)
                    break
                if chain[0] == seg[-1] or chain[0] == seg[0]:
                    if chain[0] == seg[0]: seg.reverse()
                    chain = seg[:-1] + chain; pending.pop(i)
                    break
            else:
                raise ValueError('Incomplete OSM multipolygon ring; fetch out geom with complete members')
        rings.append(chain)
    return rings


def footprints_of(osm_path, origin):
    """OSM ways/multipolygons + inner rings; preserve part IDs and suppress duplicate relation outlines."""
    from pathlib import Path
    elements = json.loads(Path(osm_path).read_text())['elements']
    relations = [e for e in elements if e['type'] == 'relation' and
                 ('building' in e.get('tags', {}) or 'building:part' in e.get('tags', {})) and
                 e.get('tags', {}).get('type') == 'multipolygon']
    member_ids = {m['ref'] for e in relations for m in e.get('members', []) if m.get('role') in ('outer', 'inner')}
    for e in elements:
        tags = dict(e.get('tags', {}))
        if not ('building' in tags or 'building:part' in tags) or tags.get('building') in {'no', 'construction'}:
            continue
        if 'building' not in tags:
            tags['building'] = tags['building:part']
        if e['type'] == 'way':
            if e['id'] in member_ids or len(e.get('geometry', [])) < 4:
                continue
            if e['geometry'][0] != e['geometry'][-1]:
                raise ValueError('Open OSM building way %s' % e['id'])
            outers, inners = [e['geometry']], []
        elif e in relations:
            outers = _stitch([m for m in e['members'] if m.get('role', '') in ('', 'outer')])
            inners = [_ring(p, origin) for p in _stitch([m for m in e['members'] if m.get('role') == 'inner'])]
        else:
            continue
        for part, points in enumerate(outers):
            ring = _ring(points, origin)
            if not ring: continue
            holes = [h for h in inners if h and _point_in_ring(*h[0], ring + [ring[0]])]
            feature = dict(e, _inners=holes, _outer_index=part)
            yield feature, tags, ring, (sum(p[0] for p in ring)/len(ring), sum(p[1] for p in ring)/len(ring))


def _clip_half(poly, a, b, inside=True):
    cross = lambda p: (b[0]-a[0])*(p[1]-a[1]) - (b[1]-a[1])*(p[0]-a[0])
    out = []
    for p, q in zip(poly, poly[1:]+poly[:1]):
        cp, cq = cross(p), cross(q)
        ip, iq = (cp >= -1e-8, cq >= -1e-8) if inside else (cp <= 1e-8, cq <= 1e-8)
        if ip: out.append(p)
        if ip != iq:
            t = cp/(cp-cq)
            out.append((p[0]+t*(q[0]-p[0]), p[1]+t*(q[1]-p[1])))
    return out


def surface_triangles(ring, holes=()):
    """Subtract triangulated holes using convex half planes. No triangle may bridge a courtyard."""
    polys = [list(t) if rt._polygon_area2_xz(t)>0 else list(t)[::-1] for t in rt._triangulate_xz(ring)]
    for hole in holes:
        for cut in rt._triangulate_xz(hole):
            cut = list(cut) if rt._polygon_area2_xz(cut)>0 else list(cut)[::-1]
            remaining = []
            for poly in polys:
                current = poly
                for a, b in zip(cut, cut[1:]+cut[:1]):
                    outside = _clip_half(current, a, b, False)
                    if len(outside)>=3 and abs(rt._polygon_area2_xz(outside))>1e-7:
                        remaining.append(outside)
                    current = _clip_half(current, a, b)
                    if len(current)<3: break
            polys = remaining
    return [(p[0], p[i], p[i+1]) for p in polys for i in range(1,len(p)-1)
            if abs(rt._polygon_area2_xz((p[0],p[i],p[i+1])))>1e-7]


def oriented_rectangle(ring):
    """Minimum-area bounding rectangle; long unit axis, perpendicular axis and bounds."""
    best = None
    for a, b in zip(ring, ring[1:]+ring[:1]):
        dx, dz = b[0]-a[0], b[1]-a[1]; length = math.hypot(dx,dz)
        if length < 1e-6: continue
        u, v = (dx/length,dz/length), (-dz/length,dx/length)
        xs = [x*u[0]+z*u[1] for x,z in ring]; zs = [x*v[0]+z*v[1] for x,z in ring]
        lo, hi, low, high = min(xs),max(xs),min(zs),max(zs)
        area = (hi-lo)*(high-low)
        if best is None or area < best[0]: best = (area,u,v,lo,hi,low,high)
    area,u,v,a,b,c,d = best
    if d-c > b-a:
        u,v,a,b,c,d = v,(-u[0],-u[1]),c,d,-b,-a
    return {'area':area,'u':u,'v':v,'bounds':[a,b,c,d]}


def roof_plan(tags, ring, height, holes=()):
    rect = oriented_rectangle(ring)
    a,b,c,d = rect['bounds'];u,v=rect['u'],rect['v']
    ratio = abs(rt._polygon_area2_xz(ring))/2/rect['area']
    convex = all((q[0]-p[0])*(r[1]-q[1])-(q[1]-p[1])*(r[0]-q[0]) >= -1e-5
                 for p,q,r in zip(ring,ring[1:]+ring[:1],ring[2:]+ring[:2]))
    requested = tags.get('roof:shape')
    small = tags.get('building') in HOUSE_CLASSES and height<=2*LEVEL_M+1 and abs(rt._polygon_area2_xz(ring))/2<400
    shape = requested if requested in {'flat','gabled','hipped','skillion','pyramidal'} else ('hipped' if small else 'flat')
    method = 'OSM roof:shape' if requested else 'estimated from building class'
    if shape != 'flat' and requested not in {'gabled','hipped','skillion','pyramidal'} and (holes or not convex or ratio <= .85):
        shape,method='flat','concave/irregular: flat with parapet'
    ridge = []
    if shape in ('hipped','gabled'):
        inset = min((d-c)/2,(b-a)*.35) if shape=='hipped' else 0
        ridge = [[x*u[0]+(c+d)/2*v[0],x*u[1]+(c+d)/2*v[1]] for x in (a+inset,b-inset)]
    return {'shape':shape,'requested_shape':requested,'method':method,'rectangle_ratio':round(ratio,5),
            'rectangle':rect,'ridge':ridge,'eaves_m':.5 if shape!='flat' else 0.,
            'rise_m':number(tags,'roof:height',min(3.,(d-c)*.25)) if shape!='flat' else 0.,
            'rise_source':'osm roof:height' if number(tags,'roof:height') is not None else 'estimated: 25% of short span, capped at 3 m',
            'orientation_source':'estimated: minimum bounding rectangle long axis'}


def _colour(value, fallback):
    # OSM named/hex colour is sRGB; the package contract stores linear RGB.
    if value:
        try:
            from PIL import ImageColor
            rgb = ImageColor.getrgb(value.strip())[:3]
            return [round((c/255/12.92 if c/255<=.04045 else ((c/255+.055)/1.055)**2.4),6) for c in rgb], 'osm colour tag (sRGB → linear)'
        except (ValueError, TypeError): pass
    return list(fallback), 'estimated: fixed class palette'


def building_appearance(tags, ring, height, source, osm_id, holes=()):
    cls=tags.get('building','yes')
    style = ('garage' if cls in {'garage','garages','shed'} else 'roof' if cls in {'roof','carport','shelter','canopy','gazebo','pergola'} or tags.get('amenity')=='shelter'
             else 'apartment' if cls in {'apartments','hotel'} else 'commercial' if cls in {'retail','commercial','office','supermarket','kiosk'} else 'residential')
    palette={'residential':((.72,.68,.59),(.23,.12,.08)), 'apartment':((.78,.77,.73),(.25,.26,.27)),
             'commercial':((.61,.64,.65),(.27,.28,.29)), 'garage':((.57,.55,.50),(.24,.26,.28)), 'roof':((.65,.66,.65),(.28,.30,.31))}
    wall,ws=_colour(tags.get('building:colour'),palette[style][0]);roof,rs=_colour(tags.get('roof:colour'),palette[style][1])
    levels=number(tags,'building:levels',max(1,round((height-1)/LEVEL_M)))
    return {'osm_id':osm_id,'class':cls,'levels':levels,'levels_source':'osm building:levels' if 'building:levels' in tags else 'estimated from height / 3.1 m',
            'height_m':height,'height_source':source,'height_estimated':source!='osm height tag',
            'roof_shape':roof_plan(tags,ring,height,holes)['shape'],'roof':roof_plan(tags,ring,height,holes),
            'facade_style':style,'wall_color_linear':wall,'wall_color_source':ws,'roof_color_linear':roof,'roof_color_source':rs,
            'min_height_m':minimum_height(tags)[0],'min_height_source':minimum_height(tags)[1],
            'facade_material':'osm_facade','roof_material':'osm_roof','walls':[],
            'appearance_source':{'kind':'procedural','estimated':True,'ref':'class palette / shared geometry rules; no reference image pixels'},
            'geometry':{'mode':'open_shelter' if style=='roof' else 'solid','eaves_m':.5,'parapet_height_m':.9,
                        'balcony_projection_m':.6,'balcony_slab_m':.16,'slab_thickness_m':.18,'column_width_m':.18,
                        'source':'estimated construction dimensions; roof:shape/height tags override defaults'}}


def building_mesh():
    return {'positions':[],'uv':[],'color':[],'groups':{}}


def face(m, pts, tint, material, uv=None):
    k=len(m['positions']);m['positions'].extend(pts);m['color'].extend([tint]*len(pts))
    m['uv'].extend(uv or [(p[0],p[2]) for p in pts])
    ids=m['groups'].setdefault(material,[])
    for i in range(1,len(pts)-1): ids.extend((k,k+i,k+i+1))
    return k,k+len(pts)


def slab(m, ring, bottom, top, tint, material, holes=()):
    for tri in surface_triangles(ring,holes):
        face(m,[(x,top,z) for x,z in reversed(tri)],tint,material)
        face(m,[(x,bottom,z) for x,z in tri],tint,material)
    for border in [ring]+[list(reversed(h)) for h in holes]:
        for a,b,_ in wall_segments(border,holes):
            length=math.dist(a,b)
            face(m,[(a[0],bottom,a[1]),(a[0],top,a[1]),(b[0],top,b[1]),(b[0],bottom,b[1])],tint,material,
                 [(0,0),(0,top-bottom),(length,top-bottom),(length,0)])


def offset_ring(ring, offset):
    """Parallel-edge mitre offset, capped at 2× width on acute corners."""
    out=[]
    for a,p,b in zip(ring[-1:]+ring[:-1],ring,ring[1:]+ring[:1]):
        normals=[]
        for start,end in ((a,p),(p,b)):
            dx,dz=end[0]-start[0],end[1]-start[1];n=math.hypot(dx,dz) or 1
            normals.append((dz/n,-dx/n))
        x,z=normals[0][0]+normals[1][0],normals[0][1]+normals[1][1]
        scale=offset/max(.5,x*normals[1][0]+z*normals[1][1])
        out.append((p[0]+x*scale,p[1]+z*scale))
    return out


def _roof_mesh(m, ring, top, rec, holes):
    plan=rec['roof'];shape=plan['shape'];tint=rec['roof_color_linear'];mat='roof'
    if shape=='flat':
        slab(m,ring,top-.18,top,tint,mat,holes)
        # Individual thin wall boxes avoid invalid inward offsets at reentrant corners.
        for border in [ring]+[list(reversed(h)) for h in holes]:
            for a,b,_ in wall_segments(border,holes):
                dx,dz=b[0]-a[0],b[1]-a[1];length=math.hypot(dx,dz) or 1
                nx,nz=-dz/length*.18,dx/length*.18
                slab(m,[a,b,(b[0]+nx,b[1]+nz),(a[0]+nx,a[1]+nz)],top,top+.9,rec['wall_color_linear'],'trim')
        return
    rect=plan['rectangle'];a,b,c,d=rect['bounds'];u,v=rect['u'],rect['v'];rise=plan['rise_m']
    # Roof edges follow the measured polygon, with an estimated 0.5 m perpendicular eave.
    edge=offset_ring(ring,.5)
    # Clip each roof plane to the actual (expanded) footprint: no bounding-box wedges outside irregular corners.
    loc=[(x*u[0]+z*u[1],x*v[0]+z*v[1]) for x,z in edge]
    a,b,c,d=min(p[0] for p in loc),max(p[0] for p in loc),min(p[1] for p in loc),max(p[1] for p in loc)
    mid=(c+d)/2;inset=min((d-c)/2,(b-a)*.35)
    if shape=='gabled': surfaces=[([(a,c),(b,c),(b,mid),(a,mid)],lambda x,z:(z-c)/(mid-c)*rise),
                                 ([(a,mid),(b,mid),(b,d),(a,d)],lambda x,z:(d-z)/(d-mid)*rise)]
    elif shape in ('hipped','pyramidal'):
        left,right=(a+b)/2,(a+b)/2
        if shape=='hipped': left,right=a+inset,b-inset
        surfaces=[([(a,c),(b,c),(right,mid),(left,mid)],lambda x,z:(z-c)/(mid-c)*rise),
                  ([(left,mid),(right,mid),(b,d),(a,d)],lambda x,z:(d-z)/(d-mid)*rise),
                  ([(a,c),(left,mid),(a,d)],lambda x,z:(x-a)/(left-a)*rise),
                  ([(b,c),(b,d),(right,mid)],lambda x,z:(b-x)/(b-right)*rise)]
    else: surfaces=[(loc,lambda x,z:(z-c)/(d-c)*rise)]
    if shape in ('hipped','gabled'):
        inset=0 if shape=='gabled' else inset
        plan['ridge']=[[x*u[0]+mid*v[0],x*u[1]+mid*v[1]] for x in (a+inset,b-inset)]
    for plane, y_at in surfaces:
        if abs(rt._polygon_area2_xz(plane))<1e-7: continue
        for tri in surface_triangles(loc,[[(x*u[0]+z*u[1],x*v[0]+z*v[1]) for x,z in h] for h in holes]):
            poly=list(tri) if rt._polygon_area2_xz(tri)>0 else list(tri)[::-1]
            for p,q in zip(plane,plane[1:]+plane[:1]): poly=_clip_half(poly,p,q)
            if len(poly)<3: continue
            pts=[(x*u[0]+z*v[0],top+y_at(x,z),x*u[1]+z*v[1]) for x,z in reversed(poly)]
            face(m,pts,tint,mat,[(x,z) for x,z in reversed(poly)])
    # Fascia and closed gable/skillion ends (shelters keep the open support zone).
    def edge_height(p):
        x,z=p[0]*u[0]+p[1]*u[1],p[0]*v[0]+p[1]*v[1]
        if shape=='gabled': return max(0,1-abs(z-mid)/((d-c)/2))*rise
        if shape=='skillion': return (z-c)/(d-c)*rise
        hip_inset=min((d-c)/2,(b-a)*.35) if shape=='hipped' else (b-a)/2
        return max(0,min((x-a)/hip_inset,(b-x)/hip_inset,(z-c)/((d-c)/2),(d-z)/((d-c)/2),1))*rise
    for p,q in [(p,q) for border in [edge]+[list(reversed(h)) for h in holes] for p,q in zip(border,border[1:]+border[:1])]:
        # Split at ridge crossing so gable triangles close fully.
        points=[p,q];zp,zq=p[0]*v[0]+p[1]*v[1],q[0]*v[0]+q[1]*v[1]
        if shape=='gabled' and (zp-mid)*(zq-mid)<0:
            t=(mid-zp)/(zq-zp);points.insert(1,(p[0]+t*(q[0]-p[0]),p[1]+t*(q[1]-p[1])))
        for aa,bb in zip(points,points[1:]):
            face(m,[(aa[0],top-.12,aa[1]),(aa[0],top+edge_height(aa),aa[1]),
                    (bb[0],top+edge_height(bb),bb[1]),(bb[0],top-.12,bb[1])],tint,mat)
    # Eave soffit closes the underside.
    for tri in surface_triangles(edge,holes): face(m,[(x,top-.12,z) for x,z in tri],tint,mat)


def extrude(m, ring, base, top, tint, roof_tint, hipped, *, record=None, floor_y=None, segment_ground=None, holes=(), roof_holes=()):
    """Shared P4/P5 building geometry. Windows/doors are package geometry, never renderer inventions."""
    rec=record or building_appearance({'building':'house' if hipped else 'yes','roof:shape':'hipped' if hipped else 'flat'},ring,top-base,'estimated',0,holes)
    floor_y=base if floor_y is None else floor_y
    rec['floor_origin_y_m']=floor_y;rec['foundation_base_y_m']=base
    start=len(m['positions'])
    candidates=[(a,b) for a,b,_ in wall_segments(ring,holes) if math.dist(a,b)>=2.5]
    anchor=rec.get('entrance_reference_xz')
    entrance=min(candidates,key=lambda ab: math.dist(((ab[0][0]+ab[1][0])/2,(ab[0][1]+ab[1][1])/2),anchor)) if anchor and candidates else (max(candidates,key=lambda ab:math.dist(*ab)) if candidates else None)
    rec['entrance_source']='estimated: nearest eligible outer wall to route' if anchor else 'estimated: longest eligible outer wall'
    if rec['geometry']['mode']=='open_shelter':
        slab(m,offset_ring(ring,.5),top-.18,top,rec['roof_color_linear'],'roof',holes)
        for x,z in ring:
            r=.09;slab(m,[(x-r,z-r),(x+r,z-r),(x+r,z+r),(x-r,z+r)],base,top-.18,tint,'trim')
        rec['geometry']['roof_note']='thin flat support slab; tagged pitched roof added above slab' if rec['roof_shape']!='flat' else 'thin roof slab + columns'
        if rec['roof_shape']!='flat': _roof_mesh(m,ring,top,rec,holes)
    else:
        for border_i,border in enumerate([ring]+[list(reversed(h)) for h in holes]):
            for a,b,i in wall_segments(border,holes):
                length=math.dist(a,b)
                if length<.001: continue
                ground_y=max(segment_ground[i],segment_ground[(i+1)%len(ring)]) if border_i==0 and segment_ground else floor_y
                if border_i>0:
                    samples=rec.get('inner_wall_ground',{});ground_y=max(samples.get(str(a),floor_y),samples.get(str(b),floor_y))
                # Base course rises from lowest ground/foundation to the shared high-ground floor origin.
                if floor_y > base + .001:
                    face(m,[(a[0],base,a[1]),(a[0],floor_y,a[1]),(b[0],floor_y,b[1]),(b[0],base,b[1])],
                         [c*.68 for c in tint],'trim',[(0,base-ground_y),(0,floor_y-ground_y),(length,floor_y-ground_y),(length,base-ground_y)])
                vr=face(m,[(a[0],floor_y,a[1]),(a[0],top,a[1]),(b[0],top,b[1]),(b[0],floor_y,b[1])],tint,'facade',
                        [(0,floor_y-ground_y),(0,top-ground_y),(length,top-ground_y),(length,floor_y-ground_y)])
                wall={'length_m':length,'uv_u_range_m':[0,length],'uv_ground_y_m':ground_y,'vertex_range':list(vr),'window_count':0,'door_count':0,'inner':border_i>0}
                rec['walls'].append(wall)
                ux,uz=(b[0]-a[0])/length,(b[1]-a[1])/length;nx,nz=uz*.025,-ux*.025
                def opening(u0,u1,y0,y1,material):
                    pts=[(a[0]+ux*u+nx,y,a[1]+uz*u+nz) for u,y in [(u0,y0),(u0,y1),(u1,y1),(u1,y0)]]
                    face(m,pts,(1,1,1),material,[(0,0),(0,y1-y0),(u1-u0,y1-y0),(u1-u0,0)])
                if length>=2.5 and rec['facade_style'] not in {'garage','roof'}:
                    bays=max(1,int(length/3.2));bay=length/bays
                    for level in range(max(1,int(rec['levels']))):
                        low=floor_y+level*LEVEL_M
                        if low+2.6>top: break
                        for col in range(bays):
                            center=(col+.5)*bay
                            if level==0 and col==bays//2 and border_i==0 and (a,b)==entrance and rec['facade_style'] in {'residential','commercial'}:
                                opening(center-.48,center+.48,low+.02,low+2.15,'door' if rec['facade_style']=='residential' else 'glass');wall['door_count']+=1
                            else:
                                width=min(1.7,bay*.6)
                                opening(center-width/2,center+width/2,low+(.25 if level==0 and rec['facade_style']=='commercial' else 1),low+2.55,'glass')
                                wall['window_count']+=1
                    if rec['facade_style']=='apartment' and rec['levels']>=4:
                        for level in range(1,int(rec['levels'])):
                            y=floor_y+level*LEVEL_M
                            if y>=top: break
                            out=(uz*.6,-ux*.6)
                            slab(m,[a,(a[0]+out[0],a[1]+out[1]),(b[0]+out[0],b[1]+out[1]),b],y-.16,y,tint,'trim')
                            # Simple opaque balcony front rail.
                            aa=(a[0]+out[0],a[1]+out[1]);bb=(b[0]+out[0],b[1]+out[1])
                            slab(m,[aa,bb,(bb[0]-out[0]*.12,bb[1]-out[1]*.12),(aa[0]-out[0]*.12,aa[1]-out[1]*.12)],y,min(top,y+.85),tint,'trim')
        _roof_mesh(m,ring,top,rec,list(holes)+list(roof_holes))
    rec['mesh_vertex_range']=[start,len(m['positions'])]
    return surface_triangles(ring,holes)


def write_buildings_glb(path, name, m, pkg=None, records=()):
    """Plain glTF PBR + building records in extras; metre UV uses KHR_texture_transform."""
    from pathlib import Path
    import struct
    styles={'facade':('osm_v2_facade',.85), 'roof':('osm_v2_roof',.9), 'trim':('osm_v2_trim',.85),
            'glass':('osm_v2_glass',.2), 'door':('osm_v2_door',.7)}
    ids=[i for group in m['groups'].values() for i in group]
    prims=[{'material':{'name':styles[k][0],'color':([.12,.18,.22] if k=='glass' else [.15,.10,.07] if k=='door' else [1,1,1]),
                         'roughness':styles[k][1]},'indices':v} for k,v in m['groups'].items() if v]
    rt.write_glb(path,{'name':name,'translation':[0.,0.,0.],
                      'attributes':{'POSITION':m['positions'],'TEXCOORD_0':m['uv'],'COLOR_0':m['color'],
                                    'NORMAL':rt._normals(m['positions'],ids)},'primitives':prims})
    raw=Path(path).read_bytes();n=struct.unpack_from('<I',raw,12)[0];doc=json.loads(raw[20:20+n]);blob=raw[28+n:]
    doc['meshes'][0]['extras']={'osm_buildings':list(records),'uv_units':'metres; u resets at each wall; v zero at wall ground'}
    catalog=Path(pkg)/'assets/materials/osm_buildings.json' if pkg else None
    if catalog and catalog.exists():
        specs=json.loads(catalog.read_text())['materials']
        doc.update(images=[],textures=[],samplers=[{'magFilter':9729,'minFilter':9987,'wrapS':10497,'wrapT':10497}])
        def texture(spec,key):
            uri=os.path.relpath(os.path.join(pkg,spec[key]),os.path.dirname(path))
            i=next((i for i,img in enumerate(doc['images']) if img['uri']==uri),len(doc['images']))
            if i==len(doc['images']):
                doc['images'].append({'uri':uri,'mimeType':'image/jpeg' if uri.lower().endswith(('.jpg','.jpeg')) else 'image/png'})
                doc['textures'].append({'source':i,'sampler':0})
            return {'index':i,'extensions':{'KHR_texture_transform':{'scale':[1/spec['repeat_m']]*2}}}
        for mat in doc['materials']:
            key='osm_roof' if mat['name']=='osm_v2_roof' else 'osm_facade'
            if mat['name'] in {'osm_v2_glass','osm_v2_door'}: continue
            spec=specs[key];pbr=mat['pbrMetallicRoughness']
            pbr['baseColorTexture']=texture(spec,'diffuse');pbr['metallicRoughnessTexture']=texture(spec,'roughness')
            mat['normalTexture']=texture(spec,'normal');mat['extras']={'library_material':key,'source':spec['source']}
        doc['extensionsUsed']=['KHR_texture_transform']
    js=json.dumps(doc,separators=(',',':')).encode();js+=b' '*(-len(js)%4)
    Path(path).write_bytes(struct.pack('<III',0x46546C67,2,28+len(js)+len(blob))+struct.pack('<II',len(js),0x4E4F534A)+js+struct.pack('<II',len(blob),0x004E4942)+blob)


def _on_segment(p, a, b, tolerance=1e-5):
    dx,dz=b[0]-a[0],b[1]-a[1];den=dx*dx+dz*dz
    t=((p[0]-a[0])*dx+(p[1]-a[1])*dz)/(den or 1)
    return -.00001<=t<=1.00001 and math.hypot(p[0]-a[0]-t*dx,p[1]-a[1]-t*dz)<=tolerance


def contains_point(ring, p):
    return _point_in_ring(*p,ring+[ring[0]]) or any(_on_segment(p,a,b) for a,b in zip(ring,ring[1:]+ring[:1]))


def wall_segments(border, holes):
    """Clip enclosing walls at ground-level part cutouts, retaining each source edge's ground datum."""
    cuts=[h for h in holes if set(h)!=set(border)]
    for i,(a,b) in enumerate(zip(border,border[1:]+border[:1])):
        ts=[0.,1.];dx,dz=b[0]-a[0],b[1]-a[1]
        for h in cuts:
            for p,q in zip(h,h[1:]+h[:1]):
                ex,ez=q[0]-p[0],q[1]-p[1];den=dx*ez-dz*ex
                if abs(den)<1e-9: continue
                t=((p[0]-a[0])*ez-(p[1]-a[1])*ex)/den
                u=((p[0]-a[0])*dz-(p[1]-a[1])*dx)/den
                if 0<t<1 and 0<=u<=1: ts.append(t)
        ts=sorted(set(ts))
        for t0,t1 in zip(ts,ts[1:]):
            mid=(a[0]+dx*(t0+t1)/2,a[1]+dz*(t0+t1)/2)
            if any(contains_point(h,mid) for h in cuts):continue
            yield (a[0]+dx*t0,a[1]+dz*t0),(a[0]+dx*t1,a[1]+dz*t1),i


def footprint_ground_extrema(space, ring, holes=()):
    """Probe extrema of piecewise-linear P1 inside the actual footprint, including interior terrain vertices."""
    xs,zs=[p[0] for p in ring],[p[1] for p in ring];cell=space.ground_xz_cell_m
    candidates={}
    for gx in range(math.floor(min(xs)/cell),math.floor(max(xs)/cell)+1):
        for gz in range(math.floor(min(zs)/cell),math.floor(max(zs)/cell)+1):
            for box,tri in space.ground_triangles_xz.get((gx,gz),()):
                if box[1]>=min(xs) and box[0]<=max(xs) and box[3]>=min(zs) and box[2]<=max(zs):
                    candidates[tuple(tuple(p) for p in tri)]=tri
    probes={}
    local=[((min(p[0] for p in t),max(p[0] for p in t),min(p[2] for p in t),max(p[2] for p in t)),t) for t in candidates.values()]
    for tri in surface_triangles(ring,holes):
        clip=list(tri) if rt._polygon_area2_xz(tri)>0 else list(reversed(tri))
        for terrain in candidates.values():
            poly=[(p[0],p[2]) for p in terrain]
            for a,b in zip(clip,clip[1:]+clip[:1]):poly=_clip_half(poly,a,b)
            for x,z in poly:
                probes[(round(x,5),round(z,5))]=(x,z)
    heights=[y for x,z in probes.values() if (y:=space.ground_world(x,z,local)) is not None]
    return (min(heights),max(heights)) if heights else None


def _prepare_features(osm_path, origin):
    features=list(footprints_of(osm_path,origin))
    parents=[f for f in features if 'building:part' not in f[1]]
    for part in features:
        e,t,ring,_=part
        if 'building:part' not in t: continue
        candidates=[p for p in parents if all(contains_point(p[2],(x,z)) for x,z in ring)
                    and not any(_point_in_ring(*ring[0],h+[h[0]]) for h in p[0]['_inners'])]
        if candidates:
            parent=min(candidates,key=lambda p:abs(rt._polygon_area2_xz(p[2])))
            e['_parent']=f"{parent[0]['type']}/{parent[0]['id']}"
            parent[0].setdefault('_parts',[]).append(part)
            if t.get('building')=='yes': t['building']=parent[1].get('building','yes')
    return features


def _record(e,t,ring,height,source,s,layer):
    rec=building_appearance(t,ring,height,source,f"{e['type']}/{e['id']}",e['_inners'])
    rec.update(outer_index=e['_outer_index'],s=round(s,3),layer=layer,osm_tags=t,
               footprint_xz=ring,inner_rings_xz=e['_inners'],parent_osm_id=e.get('_parent'),
               footprint_source={'kind':'osm','estimated':False,'ref':'OpenStreetMap footprint, ODbL 1.0'},
               height_value_is_osm_measurement=source=='osm height tag')
    return rec


def osm_landmark_index(objects):
    """Match only explicit OSM way IDs of high-importance structures; never guess by proximity."""
    result = {}
    for obj in objects:
        way_id = obj.get('attributes', {}).get('osm_way_id')
        if obj.get('importance') != 'high' or not way_id:
            continue
        key = f'way/{way_id}'
        if key in result:
            raise ValueError(f'Multiple high-importance structures claim {key}')
        result[key] = obj['object_id']
    return result


def _emit_feature(m, feature, height, source, ground, s, layer, landmark_id=None):
    e,t,ring,_=feature
    rec=_record(e,t,ring,height,source,s,layer)
    if '_route_anchor_xz' in e: rec['entrance_reference_xz']=e['_route_anchor_xz']
    low,high=min(ground),max(ground)
    min_h,min_source=minimum_height(t)
    holes=list(e['_inners']);roof_holes=[]
    parts=e.get('_parts',[])
    elevated=[minimum_height(p[1])[0] for p in parts if minimum_height(p[1])[0]>0]
    if elevated:
        # The parent is an OSM outline of the whole complex, not a second solid tower.
        podium=min(height,min(elevated))
        rec['outline_height_m']=height;rec['segment_height_m']=podium
        rec['podium_source']='derived from lowest elevated building:part min_height; OSM part segmentation'
        height=podium
        roof_holes=[p[2] for p in parts if abs(minimum_height(p[1])[0]-podium)<.05]
    ground_parts=[p[2] for p in parts if minimum_height(p[1])[0]==0]
    holes+=ground_parts
    if parts:
        rec['part_ids']=[f"{p[0]['type']}/{p[0]['id']}" for p in parts]
        # Podium/outline caps are flat; an inferred residential hip cannot intersect its tower parts.
        rec['roof'].update(shape='flat',rise_m=0,eaves_m=0,method='OSM building:part segmentation: flat podium')
        rec['roof_shape']='flat'
    # OSM height is total above local high ground; roof rise / parapet fit inside that envelope.
    roof_allowance=rec['roof']['rise_m'] if rec['roof_shape']!='flat' else (.0 if rec['facade_style']=='roof' or parts else .9)
    top=high+height-roof_allowance
    floor=high+min_h
    if top<=floor+.2:
        raise ValueError(f"Invalid OSM vertical interval for {rec['osm_id']}: min_height >= roof eave")
    rec['ground_source']='footprint/P1 triangle intersections including interior terrain vertices; highest shipped surface; route elevation fallback outside P1 (estimated)'
    rec['ground_min_y_m']=low;rec['ground_max_y_m']=high
    rec['height_reference']='highest sampled ground; OSM total height includes roof/parapet'
    rec['ground_samples_y_m']=ground
    rec['inner_wall_ground']=e.get('_inner_ground',{})
    rec['parapet_height_m']=0 if rec['facade_style']=='roof' else .9
    rec['is_podium']=bool(parts)
    rec['ground_datum_note']='shared parent maximum ground for building:part' if e.get('_parent') else 'own footprint maximum ground'
    # Adjacent measured parts share a common parent ground datum where available.
    base=low-.3 if min_h==0 else floor
    rec['eave_y_m']=top
    if landmark_id:
        rec['geometry']['mode']='represented_by_high_importance_structure'
        rec['represented_by_structure']=landmark_id
        rec['representation_source']='Explicit matching OSM way ID in high-importance structure attributes; OSM record retained'
        rec['mesh_vertex_range']=[len(m['positions'])]*2
        return rec,surface_triangles(ring,holes)
    if ground_parts and not surface_triangles(ring,holes):
        rec['geometry']['mode']='outline_replaced_by_parts'
        rec['mesh_vertex_range']=[len(m['positions'])]*2
        return rec,[]
    footprint=extrude(m,ring,base,top,rec['wall_color_linear'],rec['roof_color_linear'],False,
                      record=rec,floor_y=floor,segment_ground=ground[:len(ring)],holes=holes,roof_holes=roof_holes)
    return rec,footprint


def buildings(pkg, osm_path, skyline_path=None):
    from pathlib import Path
    import hashlib
    route,man,sem=veg._load(pkg);origin=route['coordinate_system']['origin']
    space=veg.Space(pkg,route,man,sem);index=RouteIndex(route,cell=20.)
    water_level=min((c.get('water_level_m',0) for c in man.get('visual_terrain',{}).get('coast_profiles',[])),default=0)
    tiles=man['tiles'];tile_of=lambda s:next((t for t in tiles if t['from_s']<=s<=t['to_s']),tiles[-1])
    meshes={t['id']:building_mesh() for t in tiles};records={t['id']:[] for t in tiles}
    stats={'buildings':0,'dropped_far':0,'dropped_route':0,'dropped_on_p1_water':[],'roof_types':{},'height_sources':{},'discarded':[]}
    landmark_ids=osm_landmark_index(json.loads(Path(pkg,'structures/structures.json').read_text())['objects'])
    stats['represented_by_landmark']=0
    kept=[];measured={}
    for feature in _prepare_features(osm_path,origin):
        e,t,ring,(cx,cz)=feature
        distance,s,_=index.nearest(cx,cz,math.ceil(BUILDING_REACH_M/20))
        reason=None
        if s is None or distance>BUILDING_REACH_M: reason='dropped_far'
        elif min(index.clearance(x,z) for x,z in ring)<1.: reason='dropped_route'
        # Same footprint/centroid water gate as r50; no stricter discard criteria.
        ys=[space.ground_world(x,z) for x,z in ring+[(cx,cz)]]
        available=[y for y in ys if y is not None]
        if reason is None and available and max(available)<water_level+.1: reason='dropped_on_p1_water'
        if reason:
            drop={'osm_id':f"{e['type']}/{e['id']}",'osm_way':e['id'],'s':round(s,1) if s is not None else None,
                  'building':t.get('building'),'height_measured':measured_height(t) is not None,'reason':reason}
            stats['discarded'].append(drop)
            if reason=='dropped_on_p1_water':stats[reason].append(drop)
            else:stats[reason]+=1
            continue
        # Preserve vertex order for the wall v origin. Sample vertices, edge midpoints and center for support.
        fallback=rm_elevation(route,s)
        extra=[space.ground_world((a[0]+b[0])/2,(a[1]+b[1])/2) for a,b in zip(ring,ring[1:]+ring[:1])]
        ground=[y if y is not None else fallback for y in ys]+[y for y in extra if y is not None]
        inner_ground={str(p):space.ground_world(*p) for h in e['_inners'] for p in h}
        e['_inner_ground']={p:(y if y is not None else fallback) for p,y in inner_ground.items()}
        ground+=list(e['_inner_ground'].values())
        extrema=footprint_ground_extrema(space,ring,e['_inners'])
        if extrema:ground+=list(extrema)
        kept.append((feature,s,ground))
        h=measured_height(t)
        if h: measured.setdefault((math.floor(cx/NEIGHBOUR_RADIUS_M),math.floor(cz/NEIGHBOUR_RADIUS_M)),[]).append((cx,cz,h[0]))
    parent_ground={f"{f[0]['type']}/{f[0]['id']}":g for f,s,g in kept if f[0].get('_parts')}
    for feature,s,ground in kept:
        e,t,ring,(cx,cz)=feature;gx,gz=math.floor(cx/NEIGHBOUR_RADIUS_M),math.floor(cz/NEIGHBOUR_RADIUS_M)
        neighbours=[h for dx in (-1,0,1) for dz in (-1,0,1) for x,z,h in measured.get((gx+dx,gz+dz),()) if math.hypot(x-cx,z-cz)<=NEIGHBOUR_RADIUS_M]
        height,source=building_height(t,neighbours,abs(rt._polygon_area2_xz(ring))/2)
        if e.get('_parent') in parent_ground:
            # Keep actual per-wall ground samples but use the same high-ground level for the complex.
            ground=ground+parent_ground[e['_parent']]
        import route_model as rm
        rp=rm.sample(route,s);e['_route_anchor_xz']=[rp['x'],rp['z']]
        tile=tile_of(s);landmark_id=landmark_ids.get(f"{e['type']}/{e['id']}")
        rec,_=_emit_feature(meshes[tile['id']],feature,height,source,ground,s,'P4',landmark_id=landmark_id)
        rec['mesh_file']=None if landmark_id else f"tiles/{tile['id']}/buildings.glb"
        stats['represented_by_landmark']+=bool(landmark_id)
        records[tile['id']].append(rec)
        stats['buildings']+=1;shape=rec['roof_shape'];stats['roof_types'][shape]=stats['roof_types'].get(shape,0)+1
        stats['height_sources'][source]=stats['height_sources'].get(source,0)+1
    stats['dropped_on_p1_water_count']=len(stats['dropped_on_p1_water']);stats['hipped_roofs']=stats['roof_types'].get('hipped',0)
    stats['p3_instances_removed']=0  # This command owns P4/P5; preserve the higher-priority P3 bytes.
    stats['estimated_p4_removed']=remove_superseded_structures(pkg,man,[feature[3] for feature,s,g in kept])
    all_records=[]
    for tile in tiles:
        m=meshes[tile['id']];path=Path(pkg)/'tiles'/tile['id']/'buildings.glb'
        if not m['positions']:
            tile['files'].pop('buildings',None);path.unlink(missing_ok=True);all_records+=records[tile['id']];continue
        write_buildings_glb(str(path),f"{tile['id']}_buildings",m,pkg,records[tile['id']])
        tile['files']['buildings']=f"tiles/{tile['id']}/buildings.glb";all_records+=records[tile['id']]
    inputs=[]
    for p in [osm_path]+([skyline_path] if skyline_path else []):
        doc=json.loads(Path(p).read_text());inputs.append({'file':str(p),'sha256':hashlib.sha256(Path(p).read_bytes()).hexdigest(),
                                                        'queries':doc.get('queries',[doc.get('query')])})
    layer=man['layers']['P4_structures']
    for f in ('tiles/*/buildings.glb','structures/osm_buildings.json'):
        if f not in layer.setdefault('files',[]):layer['files'].append(f)
    info={'source':{'kind':'osm','ref':'OpenStreetMap contributors, ODbL 1.0','inputs':inputs},
          'plan_geometry':'OSM footprint/inner rings measured; 0.5 m eaves and construction profiles estimated',
          'height':'height tag; levels × 3.1 m + 1 m (conversion estimated); bounded neighbour median; class estimate',
          'roof':'OSM roof:shape; small convex rectangle ratio > .85 → long-axis ridge hip; concave/irregular → flat parapet',
          'foundation':'lowest sampled P1 - 0.3 m; base course to highest sampled P1; floors from highest P1',
          'uv':'metres; u starts at 0 per segment; v=0 at maximum of segment endpoint ground heights; foundation excluded',
          'appearance':'class palette with OSM building:colour/roof:colour override; CC0 PBR material catalog; openings baked into GLB',
          'geometry_estimates':{'parapet_m':.9,'eaves_m':.5,'balcony_projection_m':.6,'column_width_m':.18,'shelter_slab_m':.18,
                                'floor_height_m':LEVEL_M,'window_bay_target_m':3.2,'minimum_window_wall_m':2.5},
          'reach_m':BUILDING_REACH_M,'records_file':'structures/osm_buildings.json','buildings':list(all_records),'stats':stats}
    layer['osm_buildings']=info
    if skyline_path:
        all_records+=skyline(pkg,man,route,index,skyline_path)
    Path(pkg,'structures/osm_buildings.json').write_text(json.dumps({'version':'0.1','buildings':all_records},indent=1)+'\n')
    # Include P5 facts in osm_buildings provenance as requested, without duplicating full P5 arrays in manifest.
    info['skyline_records']=[r for r in all_records if r['layer']=='P5']
    Path(pkg,'manifest.json').write_text(json.dumps(man,indent=1)+'\n')
    credits=Path(pkg,'CREDITS.md');text=credits.read_text() if credits.exists() else '# Sources and licences\n'
    line='- Buildings and skyline: OpenStreetMap contributors, ODbL 1.0 (https://www.openstreetmap.org/copyright). Footprints/tags from OSM; untagged roof, floor, foundation, opening and balcony details estimated.\n'
    if line not in text:credits.write_text(text.rstrip()+'\n'+line)
    print(json.dumps({k:v for k,v in stats.items() if k not in ('dropped_on_p1_water','discarded')}))


def skyline(pkg, man, route, index, osm_path):
    from pathlib import Path
    m=building_mesh();records=[]
    features=_prepare_features(osm_path,route['coordinate_system']['origin'])
    complex_height={f"{f[0]['type']}/{f[0]['id']}":max([measured_height(f[1])[0] if measured_height(f[1]) else 0]+[measured_height(p[1])[0] for p in f[0].get('_parts',[]) if measured_height(p[1])]) for f in features}
    for feature in features:
        e,t,ring,(cx,cz)=feature;h=measured_height(t)
        key=f"{e['type']}/{e['id']}"
        if max(h[0] if h else 0,complex_height.get(key,0),complex_height.get(e.get('_parent'),0))<SKYLINE_MIN_HEIGHT_M:continue
        if not h: h=building_height(t,area_m2=abs(rt._polygon_area2_xz(ring))/2)
        distance,s,_=index.nearest(cx,cz,math.ceil(SKYLINE_REACH_M/20))
        if s is None or not BUILDING_REACH_M<distance<=SKYLINE_REACH_M:continue
        ground=rm_elevation(route,s)
        rec,_=_emit_feature(m,feature,*h,[ground]*len(ring),s,'P5')
        rec['ground_source']='estimated from nearest route elevation (outside shipped P1)'
        rec['mesh_file']='environment/skyline_buildings.glb';records.append(rec)
    path=Path(pkg,'environment/skyline_buildings.glb')
    if not records:
        path.unlink(missing_ok=True);return []
    write_buildings_glb(str(path),'skyline_buildings',m,pkg,records)
    layer=man['layers'].setdefault('P5_distant',{'status':'generated','files':[]})
    if 'environment/skyline_buildings.glb' not in layer.setdefault('files',[]):layer['files'].append('environment/skyline_buildings.glb')
    layer['skyline_buildings']={'source':{'kind':'osm','ref':'OpenStreetMap contributors, ODbL 1.0'},'count':len(records),
                              'selection':'OSM height or levels >=25 m, 200–1500 m from route','base':'nearest route elevation (estimated)',
                              'records_file':'structures/osm_buildings.json'}
    return records


def validate_buildings(pkg):
    """Engine-free checks for v2 OSM records, GLB metre UV and shipped CC0 PBR dependencies."""
    from pathlib import Path
    import struct
    root=Path(pkg);path=root/'structures/osm_buildings.json'
    if not path.exists(): return []  # legacy packages retain their existing contract
    errors=[];doc=json.loads(path.read_text());by_mesh={}
    objects={o['object_id']:o for o in json.loads((root/'structures/structures.json').read_text())['objects']} if (root/'structures/structures.json').exists() else {}
    for r in doc['buildings']:
        key=r.get('osm_id','?')
        required=('class','levels','height_m','height_source','roof_shape','facade_style','wall_color_linear',
                  'roof_color_linear','appearance_source','geometry','footprint_source','ground_source')
        for field in required:
            if field not in r:errors.append(f'{key}: missing {field}')
        if r.get('roof_shape') not in {'flat','gabled','hipped','skillion','pyramidal'}:errors.append(f'{key}: unsupported roof')
        for w in r.get('walls',[]):
            if w['uv_u_range_m'][0]!=0:errors.append(f'{key}: wall u does not restart at zero')
            if (w['length_m']<2.5 or r['facade_style'] in {'garage','roof'}) and w['window_count']:
                errors.append(f'{key}: windows on excluded wall')
        if r.get('represented_by_structure'):
            obj=objects.get(r['represented_by_structure'])
            if not obj or obj.get('importance')!='high' or r['osm_id'] != f"way/{obj.get('attributes',{}).get('osm_way_id')}":
                errors.append(f'{key}: invalid explicit landmark representation')
            continue
        by_mesh.setdefault(r['mesh_file'],[]).append(r)
    for mesh,records in by_mesh.items():
        target=root/mesh
        if not target.is_file():errors.append(f'missing {mesh}');continue
        raw=target.read_bytes();n=struct.unpack_from('<I',raw,12)[0];gltf=json.loads(raw[20:20+n]);geom=rt.read_glb(str(target))
        positions=geom['attributes']['POSITION'];uv=geom['attributes']['TEXCOORD_0']
        if not all(math.isfinite(v) for p in positions+uv for v in p):errors.append(f'{mesh}: non-finite geometry')
        for r in records:
            for w in r.get('walls',[]):
                start,end=w['vertex_range']
                if start<0 or end>len(positions):errors.append(f"{r['osm_id']}: wall range outside mesh");continue
                if abs(uv[start][0])>1e-5 or abs(uv[start][1]-(positions[start][1]-w['uv_ground_y_m']))>.002:
                    errors.append(f"{r['osm_id']}: wall UV ground origin mismatch")
        for image in gltf.get('images',[]):
            uri=image.get('uri')
            if uri:
                p=(target.parent/uri).resolve()
                if not p.is_relative_to(root.resolve()) or not p.is_file():errors.append(f'{mesh}: image missing or outside package: {uri}')
                elif p.suffix.lower() in {'.jpg','.jpeg'} and image.get('mimeType')!='image/jpeg':errors.append(f'{mesh}: JPEG MIME mismatch')
        for mat in gltf['materials']:
            if mat['name'] in {'osm_v2_facade','osm_v2_roof','osm_v2_trim'}:
                if not mat['pbrMetallicRoughness'].get('baseColorTexture') or not mat.get('normalTexture'):
                    errors.append(f'{mesh}: material missing package PBR maps')
    catalog=root/'assets/materials/osm_buildings.json'
    if not catalog.is_file():errors.append('missing building material catalog')
    else:
        import hashlib
        for name,spec in json.loads(catalog.read_text())['materials'].items():
            if spec['source'].get('license')!='CC0':errors.append(name+': non-CC0 material')
            for key in ('diffuse','normal','roughness'):
                p=root/spec[key]
                if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=spec['sha256'][key]:errors.append(name+': missing/changed '+key)
    return errors


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
    if sys.argv[1] == "validate-buildings":
        errors=validate_buildings(sys.argv[2])
        print(json.dumps({"valid":not errors,"errors":errors}))
        sys.exit(1 if errors else 0)
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
