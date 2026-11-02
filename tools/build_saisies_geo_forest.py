#!/usr/bin/env python3
"""Build a traceable forest-polygon staging dataset from the cached OSM query.

The query is intentionally treated as land-cover evidence only.  It describes
forest polygons and leaf-type tags; it does not provide individual tree
locations.  The Godot module later scatters estimated trees inside these
polygons with a deterministic grid and records that distinction in metadata.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INPUT = ROOT / "assets" / "terrain" / "saisies_geo" / "source" / "forest" / "saisies_forest_osm.json"
DEFAULT_URL_FILE = ROOT / "assets" / "terrain" / "saisies_geo" / "source" / "forest" / "saisies_forest_osm_url.txt"
DEFAULT_OUTPUT = ROOT / "data" / "saisies_geo_forest.json"
EARTH_RADIUS_M = 6378137.0
MAX_LAT = 85.0511287798066
EXPANSION_M = 1800.0
MIN_RING_AREA_M2 = 24.0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--url-file", type=Path, default=DEFAULT_URL_FILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--route", type=Path, default=ROOT / "data" / "saisies_geo_route.json")
    parser.add_argument("--terrain-metadata", type=Path, default=ROOT / "assets" / "terrain" / "saisies_geo" / "metadata.json")
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def key(point: tuple[float, float]) -> tuple[int, int]:
    return (round(point[0] * 1_000_000), round(point[1] * 1_000_000))


def close(a: tuple[float, float], b: tuple[float, float]) -> bool:
    return key(a) == key(b)


def mercator_x(lon: float) -> float:
    return EARTH_RADIUS_M * math.radians(lon)


def mercator_y(lat: float) -> float:
    lat = max(-MAX_LAT, min(MAX_LAT, lat))
    return EARTH_RADIUS_M * math.log(math.tan(math.pi * 0.25 + math.radians(lat) * 0.5))


def inverse_lon(value: float) -> float:
    return math.degrees(value / EARTH_RADIUS_M)


def inverse_lat(value: float) -> float:
    return math.degrees(math.atan(math.sinh(value / EARTH_RADIUS_M)))


class GeographyFrame:
    def __init__(self, route: dict[str, Any], metadata: dict[str, Any]) -> None:
        frame = route["geography_frame"]
        bounds = metadata["bounds_wgs84"]
        self.origin_lat = float(frame["origin_lat"])
        self.origin_lon = float(frame["origin_lon"])
        self.forward_east = float(frame["forward_east"])
        self.forward_north = float(frame["forward_north"])
        self.right_east = float(frame["right_east"])
        self.right_north = float(frame["right_north"])
        self.map_size_m = float(metadata["size_m"])
        west_x = mercator_x(float(bounds["west"]))
        east_x = mercator_x(float(bounds["east"]))
        south_y = mercator_y(float(bounds["south"]))
        north_y = mercator_y(float(bounds["north"]))
        self.scale_x = self.map_size_m / (east_x - west_x)
        self.scale_y = self.map_size_m / (north_y - south_y)
        self.origin_x = mercator_x(self.origin_lon)
        self.origin_y = mercator_y(self.origin_lat)

    def world(self, lat: float, lon: float) -> tuple[float, float]:
        east = (mercator_x(lon) - self.origin_x) * self.scale_x
        north = (mercator_y(lat) - self.origin_y) * self.scale_y
        return (
            east * self.right_east + north * self.right_north,
            -(east * self.forward_east + north * self.forward_north),
        )

    def latlon(self, x: float, z: float) -> tuple[float, float]:
        east = x * self.right_east - z * self.forward_east
        north = x * self.right_north - z * self.forward_north
        return (
            inverse_lat(self.origin_y + north / self.scale_y),
            inverse_lon(self.origin_x + east / self.scale_x),
        )


def ring_area(ring: list[tuple[float, float]]) -> float:
    if len(ring) < 4:
        return 0.0
    return 0.5 * abs(sum(ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1] for i in range(len(ring) - 1)))


def ring_bbox(ring: list[tuple[float, float]]) -> tuple[float, float, float, float]:
    xs = [point[0] for point in ring]
    zs = [point[1] for point in ring]
    return min(xs), min(zs), max(xs), max(zs)


def bbox_intersects(a: tuple[float, float, float, float], b: tuple[float, float, float, float]) -> bool:
    return a[2] >= b[0] and a[0] <= b[2] and a[3] >= b[1] and a[1] <= b[3]


def clip_edge(
    points: list[tuple[float, float]], axis: int, boundary: float, keep_greater: bool
) -> list[tuple[float, float]]:
    if not points:
        return []
    output: list[tuple[float, float]] = []

    def inside(point: tuple[float, float]) -> bool:
        return point[axis] >= boundary - 1e-7 if keep_greater else point[axis] <= boundary + 1e-7

    previous = points[-1]
    previous_inside = inside(previous)
    for current in points:
        current_inside = inside(current)
        if current_inside != previous_inside:
            delta = current[axis] - previous[axis]
            if abs(delta) > 1e-12:
                t = (boundary - previous[axis]) / delta
                output.append((previous[0] + (current[0] - previous[0]) * t, previous[1] + (current[1] - previous[1]) * t))
        if current_inside:
            output.append(current)
        previous = current
        previous_inside = current_inside
    return output


def clip_ring(ring: list[tuple[float, float]], bounds: tuple[float, float, float, float]) -> list[tuple[float, float]]:
    if len(ring) < 4:
        return []
    points = ring[:-1] if close(ring[0], ring[-1]) else ring[:]
    xmin, zmin, xmax, zmax = bounds
    for axis, boundary, keep_greater in [
        (0, xmin, True),
        (0, xmax, False),
        (1, zmin, True),
        (1, zmax, False),
    ]:
        points = clip_edge(points, axis, boundary, keep_greater)
        if len(points) < 3:
            return []
    if not close(points[0], points[-1]):
        points.append(points[0])
    else:
        points[-1] = points[0]
    if ring_area(points) < MIN_RING_AREA_M2:
        return []
    return points


def coordinates_from_geometry(geometry: Iterable[dict[str, Any]]) -> list[tuple[float, float]]:
    return [(float(point["lat"]), float(point["lon"])) for point in geometry]


def join_segments(segments: list[dict[str, Any]]) -> tuple[list[list[tuple[float, float]]], list[list[int]]]:
    """Join Overpass relation member geometries into closed rings."""
    pending = []
    for segment in segments:
        coordinates = coordinates_from_geometry(segment.get("geometry", []))
        if len(coordinates) >= 2:
            pending.append({"coordinates": coordinates, "way_id": int(segment.get("ref", -1))})
    rings: list[list[tuple[float, float]]] = []
    provenance: list[list[int]] = []
    while pending:
        item = pending.pop(0)
        chain = item["coordinates"][:]
        refs = [item["way_id"]]
        while not close(chain[0], chain[-1]):
            found = -1
            reversed_segment = False
            for index, candidate in enumerate(pending):
                candidate_coordinates = candidate["coordinates"]
                if close(chain[-1], candidate_coordinates[0]):
                    found = index
                    break
                if close(chain[-1], candidate_coordinates[-1]):
                    found = index
                    reversed_segment = True
                    break
            if found < 0:
                break
            candidate = pending.pop(found)
            candidate_coordinates = candidate["coordinates"]
            if reversed_segment:
                candidate_coordinates = list(reversed(candidate_coordinates))
            chain.extend(candidate_coordinates[1:])
            refs.append(candidate["way_id"])
        if close(chain[0], chain[-1]) and len(chain) >= 4:
            chain[-1] = chain[0]
            rings.append(chain)
            provenance.append(refs)
    return rings, provenance


def feature_tags(element: dict[str, Any]) -> dict[str, str]:
    return {str(key): str(value) for key, value in (element.get("tags") or {}).items()}


def accepted_forest(tags: dict[str, str]) -> bool:
    return tags.get("landuse") == "forest" or tags.get("natural") == "wood"


def main() -> int:
    args = parse_args()
    source_bytes = args.input.read_bytes()
    source = json.loads(source_bytes)
    route = json.loads(args.route.read_text())
    metadata = json.loads(args.terrain_metadata.read_text())
    url = args.url_file.read_text(encoding="utf-8").strip()
    frame = GeographyFrame(route, metadata)
    route_points = route.get("points", [])
    route_world = [(float(point["x_m"]), float(point["z_m"])) for point in route_points]
    route_bbox = (
        min(point[0] for point in route_world),
        min(point[1] for point in route_world),
        max(point[0] for point in route_world),
        max(point[1] for point in route_world),
    )
    expanded_bbox = (route_bbox[0] - EXPANSION_M, route_bbox[1] - EXPANSION_M, route_bbox[2] + EXPANSION_M, route_bbox[3] + EXPANSION_M)

    elements = source.get("elements", [])
    relations = [element for element in elements if element.get("type") == "relation"]
    relation_member_way_ids = {
        int(member["ref"])
        for relation in relations
        for member in relation.get("members", [])
        if member.get("type") == "way" and member.get("ref") is not None
    }
    features: list[dict[str, Any]] = []
    stats = {
        "input_elements": len(elements),
        "input_ways": sum(element.get("type") == "way" for element in elements),
        "input_relations": len(relations),
        "accepted_ways": 0,
        "accepted_multipolygons": 0,
        "skipped_member_ways": 0,
        "skipped_outside_bbox": 0,
        "skipped_unclosed": 0,
        "skipped_degenerate": 0,
        "selected_features": 0,
    }

    def add_feature(
        element: dict[str, Any],
        ring_specs: list[tuple[str, list[tuple[float, float]], list[int]]],
        member_way_ids: list[int],
    ) -> None:
        tags = feature_tags(element)
        all_world: list[tuple[float, float]] = []
        clipped_specs: list[dict[str, Any]] = []
        for role, latlon_ring, source_way_ids in ring_specs:
            world_ring = [frame.world(lat, lon) for lat, lon in latlon_ring]
            all_world.extend(world_ring)
            clipped = clip_ring(world_ring, expanded_bbox)
            if not clipped:
                continue
            coordinates = []
            for x, z in clipped:
                lat, lon = frame.latlon(x, z)
                coordinates.append([lon, lat])
            clipped_specs.append({
                "role": role,
                "coordinates": coordinates,
                "source_way_ids": sorted(set(source_way_ids)),
            })
        if not clipped_specs:
            stats["skipped_outside_bbox"] += 1
            return
        outer_world = [frame.world(float(point[1]), float(point[0])) for point in clipped_specs[0]["coordinates"] if clipped_specs[0]["role"] == "outer"]
        if not outer_world or ring_area(outer_world) < MIN_RING_AREA_M2:
            stats["skipped_degenerate"] += 1
            return
        bbox = ring_bbox([point for spec in clipped_specs for point in (frame.world(float(coordinate[1]), float(coordinate[0])) for coordinate in spec["coordinates"])])
        feature_id = f"{element.get('type', 'unknown')}:{int(element.get('id', -1))}"
        features.append({
            "id": feature_id,
            "osm_type": str(element.get("type", "unknown")),
            "osm_id": int(element.get("id", -1)),
            "tags": tags,
            "leaf_type": tags.get("leaf_type", "unknown"),
            "source": tags.get("source", "OSM land-cover tag; no individual inventory"),
            "source_hash": sha256_file(args.input),
            "member_way_ids": sorted(set(member_way_ids)),
            "rings": clipped_specs,
            "world_bbox_xz": [float(value) for value in bbox],
            "clipped_to_route_bbox_m": True,
        })
        stats["selected_features"] += 1

    # Relations own their member ways.  Assemble each role independently so
    # inner holes remain explicit in the output rather than silently filled.
    for relation in relations:
        tags = feature_tags(relation)
        if not accepted_forest(tags) or tags.get("type") != "multipolygon":
            continue
        outer_members = [member for member in relation.get("members", []) if member.get("role") == "outer" and member.get("type") == "way"]
        inner_members = [member for member in relation.get("members", []) if member.get("role") == "inner" and member.get("type") == "way"]
        outer_rings, outer_refs = join_segments(outer_members)
        inner_rings, inner_refs = join_segments(inner_members)
        if not outer_rings:
            stats["skipped_unclosed"] += 1
            continue
        ring_specs: list[tuple[str, list[tuple[float, float]], list[int]]] = []
        for ring, refs in zip(outer_rings, outer_refs):
            ring_specs.append(("outer", ring, refs))
        for ring, refs in zip(inner_rings, inner_refs):
            ring_specs.append(("inner", ring, refs))
        member_ids = [int(member["ref"]) for member in relation.get("members", []) if member.get("type") == "way" and member.get("ref") is not None]
        stats["accepted_multipolygons"] += 1
        add_feature(relation, ring_specs, member_ids)

    # Standalone ways are accepted only when they are not already relation
    # members; this avoids drawing the same land cover twice.
    for way in (element for element in elements if element.get("type") == "way"):
        way_id = int(way.get("id", -1))
        if way_id in relation_member_way_ids:
            stats["skipped_member_ways"] += 1
            continue
        tags = feature_tags(way)
        if not accepted_forest(tags):
            continue
        stats["accepted_ways"] += 1
        geometry = coordinates_from_geometry(way.get("geometry", []))
        if len(geometry) < 4 or not close(geometry[0], geometry[-1]):
            stats["skipped_unclosed"] += 1
            continue
        add_feature(way, [("outer", geometry, [way_id])], [way_id])

    stats["selected_features"] = len(features)
    features.sort(key=lambda feature: (feature["osm_type"], int(feature["osm_id"])))
    output = {
        "schema_version": 1,
        "name": "saisies_geo_forest",
        "source": {
            "url": url,
            "url_file": str(args.url_file.resolve().relative_to(ROOT)) if args.url_file.resolve().is_relative_to(ROOT) else str(args.url_file),
            "url_file_sha256": sha256_file(args.url_file),
            "snapshot_file": str(args.input.resolve().relative_to(ROOT)) if args.input.resolve().is_relative_to(ROOT) else str(args.input),
            "snapshot_file_sha256": sha256_file(args.input),
            "license": "OpenStreetMap ODbL 1.0",
            "copyright": "© OpenStreetMap contributors",
            "query_bbox_wgs84": [45.70, 6.51, 45.78, 6.61],
            "query_output": "Overpass JSON with geometry",
        },
        "selection": {
            "route_id": route.get("id", "saisies_geo_route"),
            "route_bbox_world_xz": [float(value) for value in route_bbox],
            "expanded_bbox_world_xz": [float(value) for value in expanded_bbox],
            "expansion_m": EXPANSION_M,
            # The runtime forest is selected by lateral distance from every
            # point on the route.  Keep the route end explicit so a verifier
            # can reject an accidental first-segment-only build.
            "runtime_route_end_m": float(route.get("length_m", route.get("estimated_length_m", 0.0))),
            "runtime_road_distance_m": 600.0,
            "tree_grid_spacing_m": [18.0, 25.0],
            "road_clearance_m": 12.0,
            "building_clearance_m": 4.0,
            "max_tree_instances": 12000,
        },
        "forest_support": {
            "accepted_tags": ["landuse=forest", "natural=wood"],
            "multipolygon_support": "outer/inner member ways are assembled into closed rings; inner rings remain holes",
            "unsupported_features": "excluded; no untagged/default forest is invented",
            "species_note": "leaf_type is polygon-level estimated distribution, not an individual-tree survey",
        },
        "stats": stats,
        "features": features,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(
        "Saisies forest: input=%d ways=%d relations=%d selected=%d multipolygons=%d skipped_member_ways=%d" % (
            stats["input_elements"], stats["input_ways"], stats["input_relations"], len(features), stats["accepted_multipolygons"], stats["skipped_member_ways"]
        )
    )
    print("wrote %s (%d bytes) sha256=%s" % (args.output, args.output.stat().st_size, sha256_file(args.output)[:16]))
    print("SAISIES GEO FOREST DATA PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
