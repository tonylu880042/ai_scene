#!/usr/bin/env python3
"""Extract a bounded, provenance-preserving OSM building set for geo staging.

The input is the read-only OSM snapshot downloaded for the Saisies village.  A
feature keeps its OSM id, node ids, complete tags, and geographic rings.  No
floor count is invented: a tagged height is used first, tagged levels are
converted only as an explicitly estimated height, and all other roofs carry a
default-estimate marker.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INPUT = ROOT / "assets" / "terrain" / "saisies_geo" / "source" / "route" / "saisies_village_osm.xml"
DEFAULT_OUTPUT = ROOT / "data" / "saisies_geo_buildings.json"
ORIGIN_LAT = 45.7577436
ORIGIN_LON = 6.5378919
EARTH_RADIUS_M = 6_378_137.0
RING_EPSILON_M = 0.20
MIN_AREA_M2 = 12.0
MAX_BUILDINGS = 240
NUMBER_RE = re.compile(r"[-+]?\d+(?:[.,]\d+)?")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--max-buildings", type=int, default=MAX_BUILDINGS)
    parser.add_argument("--min-area-m2", type=float, default=MIN_AREA_M2)
    return parser.parse_args()


def tags_of(element: ET.Element) -> dict[str, str]:
    return {tag.attrib["k"]: tag.attrib["v"] for tag in element.findall("tag")}


def local_xy(lat: float, lon: float) -> tuple[float, float]:
    east = math.radians(lon - ORIGIN_LON) * EARTH_RADIUS_M * math.cos(math.radians(ORIGIN_LAT))
    north = math.radians(lat - ORIGIN_LAT) * EARTH_RADIUS_M
    return east, north


def polygon_area_centroid(points: list[tuple[float, float]]) -> tuple[float, tuple[float, float]]:
    if len(points) < 4:
        return 0.0, (0.0, 0.0)
    area_twice = 0.0
    centroid_x = 0.0
    centroid_y = 0.0
    for p0, p1 in zip(points, points[1:]):
        cross = p0[0] * p1[1] - p1[0] * p0[1]
        area_twice += cross
        centroid_x += (p0[0] + p1[0]) * cross
        centroid_y += (p0[1] + p1[1]) * cross
    if abs(area_twice) < 1e-6:
        return 0.0, (0.0, 0.0)
    return abs(area_twice) * 0.5, (centroid_x / (3.0 * area_twice), centroid_y / (3.0 * area_twice))


def close_ring(refs: list[str]) -> list[str] | None:
    if len(refs) < 3:
        return None
    ring = refs[:]
    if ring[0] != ring[-1]:
        ring.append(ring[0])
    if len(set(ring[:-1])) < 3:
        return None
    return ring


def join_member_rings(member_refs: list[list[str]]) -> list[list[str]]:
    """Join relation member way refs into closed rings, preserving orientation."""
    pending = [refs[:] for refs in member_refs if len(refs) >= 2]
    rings: list[list[str]] = []
    while pending:
        current = pending.pop(0)
        if current[0] == current[-1]:
            ring = close_ring(current)
            if ring is not None:
                rings.append(ring)
            continue
        joined = True
        while joined and current[0] != current[-1]:
            joined = False
            tail = current[-1]
            for index, candidate in enumerate(pending):
                if candidate[0] == tail:
                    current.extend(candidate[1:])
                elif candidate[-1] == tail:
                    current.extend(reversed(candidate[:-1]))
                else:
                    continue
                pending.pop(index)
                joined = True
                break
        ring = close_ring(current)
        if ring is not None:
            rings.append(ring)
    return rings


def parse_numeric(value: str | None) -> float | None:
    if not value:
        return None
    match = NUMBER_RE.search(value.replace(",", "."))
    if match is None:
        return None
    number = float(match.group(0))
    if "ft" in value.lower():
        number *= 0.3048
    return number if math.isfinite(number) and number > 0.0 else None


def estimate_height(tags: dict[str, str]) -> tuple[float, str, float | None]:
    tagged_height = parse_numeric(tags.get("height"))
    if tagged_height is not None:
        return tagged_height, "osm_height", None
    levels = parse_numeric(tags.get("building:levels"))
    if levels is not None:
        return max(2.8, levels * 2.9 + 0.35), "estimated_from_osm_levels", levels
    building = tags.get("building", "yes")
    defaults = {
        "apartments": 8.8,
        "residential": 7.0,
        "retail": 5.2,
        "commercial": 5.2,
        "industrial": 6.0,
        "chapel": 7.5,
        "garage": 3.2,
        "garages": 3.2,
        "service": 3.5,
        "roof": 2.5,
    }
    return defaults.get(building, 6.2), "default_estimate", None


def geometry_for_ring(refs: list[str], nodes: dict[str, tuple[float, float]]) -> tuple[list[dict[str, float]], list[tuple[float, float]]] | None:
    coords: list[dict[str, float]] = []
    local: list[tuple[float, float]] = []
    for ref in refs:
        point = nodes.get(ref)
        if point is None:
            return None
        lat, lon = point
        coords.append({"lat": lat, "lon": lon})
        local.append(local_xy(lat, lon))
    return coords, local


def feature_from_rings(
    osm_type: str,
    osm_id: str,
    tags: dict[str, str],
    rings: list[dict[str, Any]],
    node_ids: list[str],
    source_members: list[str] | None,
    min_area_m2: float,
) -> tuple[dict[str, Any] | None, str | None]:
    outer = next((ring for ring in rings if ring["role"] == "outer"), None)
    if outer is None:
        return None, "degenerate"
    outer_local = outer["local_xy"]
    area_m2, centroid = polygon_area_centroid(outer_local)
    if not math.isfinite(area_m2) or area_m2 < min_area_m2:
        return None, "tiny_or_degenerate"
    centre_lat = sum(float(point["lat"]) for point in outer["coordinates"][:-1]) / max(len(outer["coordinates"]) - 1, 1)
    centre_lon = sum(float(point["lon"]) for point in outer["coordinates"][:-1]) / max(len(outer["coordinates"]) - 1, 1)
    distance_m = math.hypot(*centroid)
    height_m, height_source, osm_levels = estimate_height(tags)
    public_rings: list[dict[str, Any]] = []
    for ring in rings:
        public_rings.append(
            {
                "role": ring["role"],
                "node_ids": [int(ref) for ref in ring["node_ids"]],
                "coordinates": [[float(point["lon"]), float(point["lat"])] for point in ring["coordinates"]],
            }
        )
    feature: dict[str, Any] = {
        "id": f"{osm_type}/{osm_id}",
        "osm_type": osm_type,
        "osm_id": int(osm_id),
        "node_ids": [int(ref) for ref in node_ids],
        "tags": tags,
        "rings": public_rings,
        "centre_lat": centre_lat,
        "centre_lon": centre_lon,
        "local_centre_m": {"east": centroid[0], "north": centroid[1]},
        "distance_from_origin_m": distance_m,
        "area_m2": area_m2,
        "height_m": height_m,
        "height_source": height_source,
        "roof_rise_m": max(1.0, min(3.0, height_m * 0.22)),
        "roof_source": "simple_generated_pitched_roof",
    }
    if osm_levels is not None:
        feature["osm_levels"] = osm_levels
    if source_members is not None:
        feature["member_way_ids"] = [int(member) for member in source_members]
    return feature, None


def feature_priority(feature: dict[str, Any]) -> tuple[int, float, float]:
    tags = feature["tags"]
    named = int(bool(tags.get("name") or tags.get("addr:housename")))
    important = int(bool(tags.get("amenity") or tags.get("shop") or tags.get("tourism") or tags.get("building") in {"apartments", "retail", "commercial"}))
    return (named + important, float(feature["area_m2"]), -float(feature["distance_from_origin_m"]))


def select_spatially(features: list[dict[str, Any]], limit: int) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if len(features) <= limit:
        return sorted(features, key=lambda item: int(item["osm_id"])), []
    buckets: dict[tuple[int, int], list[dict[str, Any]]] = defaultdict(list)
    for feature in features:
        c = feature["local_centre_m"]
        bx = max(0, min(7, int((float(c["east"]) + 1000.0) / 250.0)))
        by = max(0, min(7, int((float(c["north"]) + 1000.0) / 250.0)))
        buckets[(bx, by)].append(feature)
    for items in buckets.values():
        items.sort(key=feature_priority, reverse=True)
    selected: list[dict[str, Any]] = []
    while len(selected) < limit and buckets:
        for bucket in sorted(list(buckets)):
            items = buckets.get(bucket, [])
            if not items:
                buckets.pop(bucket, None)
                continue
            selected.append(items.pop(0))
            if len(selected) >= limit:
                break
        buckets = {key: items for key, items in buckets.items() if items}
    selected_ids = {feature["id"] for feature in selected}
    omitted = [feature for feature in features if feature["id"] not in selected_ids]
    return sorted(selected, key=lambda item: int(item["osm_id"])), sorted(omitted, key=lambda item: int(item["osm_id"]))


def main() -> int:
    args = parse_args()
    input_path = args.input.resolve()
    output_path = args.output.resolve()
    if not input_path.is_file():
        raise FileNotFoundError(f"OSM snapshot not found: {input_path}")
    root = ET.parse(input_path).getroot()
    nodes = {
        node.attrib["id"]: (float(node.attrib["lat"]), float(node.attrib["lon"]))
        for node in root.findall("node")
        if node.attrib.get("lat") is not None and node.attrib.get("lon") is not None
    }
    ways: dict[str, dict[str, Any]] = {}
    for way in root.findall("way"):
        way_id = way.attrib["id"]
        ways[way_id] = {
            "node_ids": [member.attrib["ref"] for member in way.findall("nd")],
            "tags": tags_of(way),
        }
    relations = root.findall("relation")
    building_relation_count = 0
    relation_way_ids: set[str] = set()
    relation_features: list[dict[str, Any]] = []
    excluded_counts = defaultdict(int)
    for relation in relations:
        tags = tags_of(relation)
        if tags.get("type") != "multipolygon" or not tags.get("building"):
            continue
        building_relation_count += 1
        member_refs: dict[str, list[list[str]]] = defaultdict(list)
        member_way_ids: list[str] = []
        for member in relation.findall("member"):
            if member.attrib.get("type") != "way":
                continue
            member_id = member.attrib.get("ref", "")
            way = ways.get(member_id)
            if way is None:
                continue
            role = member.attrib.get("role", "outer") or "outer"
            member_refs[role].append(way["node_ids"])
            member_way_ids.append(member_id)
            relation_way_ids.add(member_id)
        rings: list[dict[str, Any]] = []
        for role in ("outer", "inner"):
            for ring_refs in join_member_rings(member_refs[role]):
                geometry = geometry_for_ring(ring_refs, nodes)
                if geometry is None:
                    excluded_counts["missing_nodes"] += 1
                    continue
                coordinates, local = geometry
                rings.append({"role": role, "node_ids": ring_refs, "coordinates": coordinates, "local_xy": local})
        feature, reason = feature_from_rings("relation", relation.attrib["id"], tags, rings, [ref for ring in rings for ref in ring["node_ids"]], member_way_ids, args.min_area_m2)
        if feature is None:
            excluded_counts[reason or "degenerate"] += 1
            continue
        if feature["distance_from_origin_m"] > 1000.0:
            excluded_counts["outside_1km"] += 1
            continue
        relation_features.append(feature)

    way_features: list[dict[str, Any]] = []
    for way_id, way in ways.items():
        tags = way["tags"]
        if "building" not in tags or way_id in relation_way_ids:
            continue
        ring_refs = close_ring(way["node_ids"])
        if ring_refs is None:
            excluded_counts["degenerate"] += 1
            continue
        geometry = geometry_for_ring(ring_refs, nodes)
        if geometry is None:
            excluded_counts["missing_nodes"] += 1
            continue
        coordinates, local = geometry
        rings = [{"role": "outer", "node_ids": ring_refs, "coordinates": coordinates, "local_xy": local}]
        feature, reason = feature_from_rings("way", way_id, tags, rings, ring_refs, None, args.min_area_m2)
        if feature is None:
            excluded_counts[reason or "degenerate"] += 1
            continue
        if feature["distance_from_origin_m"] > 1000.0:
            excluded_counts["outside_1km"] += 1
            continue
        way_features.append(feature)

    all_features = relation_features + way_features
    selected, capped = select_spatially(all_features, max(1, args.max_buildings))
    excluded_counts["max_buildings_cap"] += len(capped)
    root_bounds = root.find("bounds")
    snapshot = {
        "source": {
            "dataset": "OpenStreetMap",
            "license": "ODbL 1.0",
            "attribution": "© OpenStreetMap contributors",
            "copyright": root.attrib.get("copyright", ""),
            "source_snapshot": input_path.name,
            "snapshot_generator": root.attrib.get("generator", ""),
            "snapshot_version": root.attrib.get("version", ""),
            "bounds": dict(root_bounds.attrib) if root_bounds is not None else {},
            "source_url": "https://www.openstreetmap.org/copyright",
        },
        "coordinate_contract": {
            "origin_lat": ORIGIN_LAT,
            "origin_lon": ORIGIN_LON,
            "filter": "feature centroid within 1000m of origin; local metrics are diagnostic only",
            "geometry_coordinates": "[lon, lat] WGS84 degrees, closed rings",
        },
        "selection": {
            "min_area_m2": args.min_area_m2,
            "max_buildings": args.max_buildings,
            "ways_with_building_tag": sum(1 for way in ways.values() if "building" in way["tags"]),
            "building_multipolygon_relations": building_relation_count,
            "selected_buildings": len(selected),
            "excluded": dict(sorted(excluded_counts.items())),
        },
        "multipolygon_support": {
            "parser_support": "building multipolygon outer/inner member rings are joined and preserved",
            "runtime_support": "outer shell is staged; inner rings are preserved in data for a later hole-capable mesh",
            "building_relations_in_snapshot": building_relation_count,
            "nonbuilding_multipolygon_relations_skipped": sum(1 for relation in relations if tags_of(relation).get("type") == "multipolygon" and not tags_of(relation).get("building")),
        },
        "signage": {
            "deferred": True,
            "note": "No generated sign is attached to a footprint; the real La Table de l’Olympe / RESTAURANT SAVOYARD evidence remains for later visual placement.",
        },
        "buildings": selected,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(snapshot, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(
        f"OSM buildings: ways={snapshot['selection']['ways_with_building_tag']} "
        f"relations={building_relation_count} selected={len(selected)} "
        f"excluded={dict(sorted(excluded_counts.items()))}",
        flush=True,
    )
    print(f"wrote {output_path} ({output_path.stat().st_size} bytes)", flush=True)
    print("SAISIES GEO BUILDING DATA PASS", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
