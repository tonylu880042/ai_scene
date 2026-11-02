#!/usr/bin/env python3
"""Build the independent Saisies geographic route dataset.

The route candidate is a read-only analysis artifact.  This builder adds only
road geometry that is present in a supplemental OSM extract (currently the
two summit roundabout connectors in ``assets/terrain/saisies_geo/source/route/saisies_village_osm.xml``), then
densifies the resulting centerline without scaling its geodesic arc length.
Heights are sampled bilinearly from the cached Web-Mercator DEM using the
same north-up convention as ``fetch_saisies_geography.py``.

Example::

    python3 tools/build_saisies_geo_route.py
"""

from __future__ import annotations

import argparse
import hashlib
import heapq
import json
import math
import struct
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROUTE_DIR = ROOT / "assets" / "terrain" / "saisies_geo" / "source" / "route"
DEFAULT_CANDIDATE = SOURCE_ROUTE_DIR / "saisies_geo_route_candidate.json"
DEFAULT_CANDIDATE_OSM = SOURCE_ROUTE_DIR / "saisies_d218b_osm.json"
DEFAULT_SUPPLEMENTAL_OSM = SOURCE_ROUTE_DIR / "saisies_village_osm.xml"
DEFAULT_DEM_METADATA = ROOT / "assets" / "terrain" / "saisies_geo" / "metadata.json"
DEFAULT_DEM = ROOT / "assets" / "terrain" / "saisies_geo" / "height.f32"
DEFAULT_BASE_ROUTE = ROOT / "data" / "saisies_route.json"
DEFAULT_OUTPUT = ROOT / "data" / "saisies_geo_route.json"
METRES_PER_DEGREE_LAT = 111_320.0
ROAD_CLASSES = {
    "motorway",
    "motorway_link",
    "trunk",
    "trunk_link",
    "primary",
    "primary_link",
    "secondary",
    "secondary_link",
    "tertiary",
    "tertiary_link",
    "unclassified",
    "residential",
    "living_street",
    "service",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, default=DEFAULT_CANDIDATE)
    parser.add_argument("--candidate-osm", type=Path, default=DEFAULT_CANDIDATE_OSM)
    parser.add_argument("--supplemental-osm", type=Path, default=DEFAULT_SUPPLEMENTAL_OSM)
    parser.add_argument("--dem-metadata", type=Path, default=DEFAULT_DEM_METADATA)
    parser.add_argument("--dem", type=Path, default=DEFAULT_DEM)
    parser.add_argument("--base-route", type=Path, default=DEFAULT_BASE_ROUTE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--sample-spacing", type=float, default=10.0)
    return parser.parse_args()


def read_json(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f"expected JSON object: {path}")
    return data


def provenance_path(path: Path) -> str:
    """Keep provenance portable instead of embedding a machine-local path."""
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(ROOT.resolve()))
    except ValueError:
        return f"analysis-cache://{path.name}"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def metres_between(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat = math.radians((a[0] + b[0]) * 0.5)
    north = (b[0] - a[0]) * METRES_PER_DEGREE_LAT
    east = (b[1] - a[1]) * METRES_PER_DEGREE_LAT * math.cos(lat)
    return math.hypot(east, north)


def local_enu(a: tuple[float, float], b: tuple[float, float]) -> tuple[float, float]:
    lat = math.radians((a[0] + b[0]) * 0.5)
    return (
        (b[1] - a[1]) * METRES_PER_DEGREE_LAT * math.cos(lat),
        (b[0] - a[0]) * METRES_PER_DEGREE_LAT,
    )


def interpolate_latlon(
    a: tuple[float, float], b: tuple[float, float], t: float
) -> tuple[float, float]:
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def path_length(points: Iterable[tuple[float, float]]) -> float:
    values = list(points)
    return sum(metres_between(a, b) for a, b in zip(values, values[1:]))


class DemSampler:
    """Bilinear sampler for the cached north-up Web-Mercator DEM."""

    def __init__(self, metadata_path: Path, data_path: Path) -> None:
        self.metadata_path = metadata_path
        self.data_path = data_path
        self.metadata = read_json(metadata_path)
        height = self.metadata.get("height", {})
        self.grid = int(height.get("grid", 0))
        self.size_m = float(self.metadata.get("size_m", 0.0))
        centre = self.metadata.get("centre", {})
        self.centre_lat = float(centre.get("lat", 0.0))
        self.centre_lon = float(centre.get("lon", 0.0))
        self.zoom = int(height.get("zoom", 12))
        if self.grid < 2 or self.size_m <= 0.0:
            raise ValueError(f"invalid DEM metadata: {metadata_path}")
        expected = self.grid * self.grid
        raw = data_path.read_bytes()
        if len(raw) != expected * 4:
            raise ValueError(f"DEM byte count {len(raw)} != {expected * 4}: {data_path}")
        self.values = struct.unpack(f"<{expected}f", raw)
        if not all(math.isfinite(value) for value in self.values):
            raise ValueError(f"DEM contains non-finite heights: {data_path}")
        self.m_per_px = 40_075_016.686 * math.cos(math.radians(self.centre_lat)) / (
            256.0 * (2**self.zoom)
        )
        centre_x, centre_y = self.world_px(self.centre_lat, self.centre_lon)
        half_px = self.size_m / (2.0 * self.m_per_px)
        self.x0 = centre_x - half_px
        self.y0 = centre_y - half_px
        self.x1 = centre_x + half_px
        self.y1 = centre_y + half_px

    def world_px(self, lat: float, lon: float) -> tuple[float, float]:
        n = 256.0 * (2**self.zoom)
        x = (lon + 180.0) / 360.0 * n
        y = (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) * 0.5 * n
        return x, y

    def sample(self, lat: float, lon: float) -> float:
        px, py = self.world_px(lat, lon)
        u = (px - self.x0) / max(self.x1 - self.x0, 1e-9) * (self.grid - 1)
        v = (py - self.y0) / max(self.y1 - self.y0, 1e-9) * (self.grid - 1)
        u = max(0.0, min(float(self.grid - 1), u))
        v = max(0.0, min(float(self.grid - 1), v))
        x0 = min(self.grid - 1, int(math.floor(u)))
        y0 = min(self.grid - 1, int(math.floor(v)))
        x1 = min(self.grid - 1, x0 + 1)
        y1 = min(self.grid - 1, y0 + 1)
        tx = u - x0
        ty = v - y0

        def value(x: int, y: int) -> float:
            return float(self.values[y * self.grid + x])

        top = value(x0, y0) * (1.0 - tx) + value(x1, y0) * tx
        bottom = value(x0, y1) * (1.0 - tx) + value(x1, y1) * tx
        return top * (1.0 - ty) + bottom * ty


class SupplementalRoads:
    """Road graph used only for evidence-backed connector geometry."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.nodes: dict[int, tuple[float, float]] = {}
        self.graph: dict[int, list[tuple[int, float, str, dict[str, str]]]] = defaultdict(list)
        self.roundabout_ways: list[tuple[list[int], dict[str, str], str]] = []
        root = ET.parse(path).getroot()
        for node in root.findall("node"):
            self.nodes[int(node.attrib["id"])] = (
                float(node.attrib["lat"]),
                float(node.attrib["lon"]),
            )
        for way in root.findall("way"):
            tags = {tag.attrib["k"]: tag.attrib.get("v", "") for tag in way.findall("tag")}
            if tags.get("highway") not in ROAD_CLASSES:
                continue
            refs = [int(nd.attrib["ref"]) for nd in way.findall("nd")]
            refs = [ref for ref in refs if ref in self.nodes]
            if len(refs) < 2:
                continue
            if tags.get("junction") == "roundabout":
                self.roundabout_ways.append((refs, tags, way.attrib["id"]))
            for a, b in zip(refs, refs[1:]):
                distance = metres_between(self.nodes[a], self.nodes[b])
                self.graph[a].append((b, distance, way.attrib["id"], tags))
                self.graph[b].append((a, distance, way.attrib["id"], tags))

    def roundabout_paths(self, start: int, end: int) -> list[list[int]]:
        options: list[list[int]] = []
        for refs, tags, _way_id in self.roundabout_ways:
            if start not in refs or end not in refs:
                continue
            i = refs.index(start)
            j = refs.index(end)
            if i <= j:
                options.append(refs[i : j + 1])
            else:
                options.append(list(reversed(refs[j : i + 1])))
        return options

    def shortest_path(self, start: int, end: int) -> list[int] | None:
        if start not in self.nodes or end not in self.nodes:
            return None
        queue: list[tuple[float, int]] = [(0.0, start)]
        distances = {start: 0.0}
        previous: dict[int, int | None] = {start: None}
        while queue:
            distance, current = heapq.heappop(queue)
            if distance != distances.get(current):
                continue
            if current == end:
                break
            for neighbour, edge_length, _way_id, _tags in self.graph.get(current, []):
                candidate = distance + edge_length
                if candidate < distances.get(neighbour, float("inf")):
                    distances[neighbour] = candidate
                    previous[neighbour] = current
                    heapq.heappush(queue, (candidate, neighbour))
        if end not in previous:
            return None
        path: list[int] = []
        current: int | None = end
        while current is not None:
            path.append(current)
            current = previous[current]
        return list(reversed(path))


def turn_angle(a: tuple[float, float], b: tuple[float, float]) -> float:
    denominator = math.hypot(*a) * math.hypot(*b)
    if denominator <= 1e-9:
        return math.pi
    cosine = max(-1.0, min(1.0, (a[0] * b[0] + a[1] * b[1]) / denominator))
    return math.acos(cosine)


def connector_score(
    path: list[int],
    previous: tuple[float, float] | None,
    following: tuple[float, float] | None,
    roads: SupplementalRoads,
) -> tuple[float, float]:
    if len(path) < 2:
        return (float("inf"), float("inf"))
    length = path_length(roads.nodes[node] for node in path)
    turn = 0.0
    if previous is not None and len(path) >= 2:
        turn += turn_angle(
            local_enu(previous, roads.nodes[path[0]]),
            local_enu(roads.nodes[path[0]], roads.nodes[path[1]]),
        )
    if following is not None and len(path) >= 2:
        turn += turn_angle(
            local_enu(roads.nodes[path[-2]], roads.nodes[path[-1]]),
            local_enu(roads.nodes[path[-1]], following),
        )
    # Preserve route continuity first, then prefer the shorter actual mapped
    # arc when two roundabout alternatives have similar tangents.
    return (turn, length)


def connector_for_gap(
    start: int,
    end: int,
    previous: tuple[float, float] | None,
    following: tuple[float, float] | None,
    roads: SupplementalRoads,
) -> tuple[list[int] | None, str]:
    options = roads.roundabout_paths(start, end)
    if options:
        selected = min(options, key=lambda item: connector_score(item, previous, following, roads))
        return selected, "osm_roundabout"
    selected = roads.shortest_path(start, end)
    if selected:
        return selected, "osm_shortest_road_path"
    return None, "unresolved"


def attach_supplemental_connectors(
    points: list[dict[str, Any]],
    gaps: list[list[Any]],
    roads: SupplementalRoads,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    by_node: dict[int, list[int]] = defaultdict(list)
    for index, point in enumerate(points):
        if point.get("node") is not None:
            by_node[int(point["node"])].append(index)
    connectors: list[dict[str, Any]] = []
    between: dict[int, tuple[int, int, list[int], str]] = {}
    for raw_gap in gaps:
        if len(raw_gap) < 2:
            continue
        start_id, end_id = int(raw_gap[0]), int(raw_gap[1])
        if start_id not in by_node or end_id not in by_node:
            connectors.append({"start_node": start_id, "end_node": end_id, "status": "not_on_candidate_path"})
            continue
        pairs = [(a, b) for a in by_node[start_id] for b in by_node[end_id] if abs(a - b) == 1]
        if not pairs:
            connectors.append({"start_node": start_id, "end_node": end_id, "status": "not_adjacent_in_candidate"})
            continue
        left, right = pairs[0]
        if left > right:
            left, right = right, left
        start = int(points[left]["node"])
        end = int(points[right]["node"])
        previous = (points[left - 1]["lat"], points[left - 1]["lon"]) if left else None
        following = (
            (points[right + 1]["lat"], points[right + 1]["lon"])
            if right + 1 < len(points)
            else None
        )
        path, source = connector_for_gap(start, end, previous, following, roads)
        if not path or len(path) < 2:
            connectors.append({"start_node": start, "end_node": end, "status": source})
            continue
        between[left] = (start, end, path, source)
        connectors.append(
            {
                "start_node": start,
                "end_node": end,
                "status": "inserted",
                "source": source,
                "path_nodes": path,
                "path_length_m": path_length(roads.nodes[node] for node in path),
            }
        )

    expanded: list[dict[str, Any]] = []
    for index, point in enumerate(points):
        expanded.append(dict(point))
        if index not in between:
            continue
        _start, _end, path, source = between[index]
        for node in path[1:-1]:
            lat, lon = roads.nodes[node]
            expanded.append({"node": node, "lat": lat, "lon": lon, "source": source})
    return expanded, connectors


def densify(points: list[dict[str, Any]], spacing_m: float) -> list[dict[str, Any]]:
    if len(points) < 2:
        raise ValueError("centerline needs at least two points")
    if spacing_m <= 0.0:
        raise ValueError("sample spacing must be positive")
    dense: list[dict[str, Any]] = [dict(points[0])]
    for current in points[1:]:
        previous = dense[-1]
        a = (float(previous["lat"]), float(previous["lon"]))
        b = (float(current["lat"]), float(current["lon"]))
        distance = metres_between(a, b)
        steps = max(1, int(math.ceil(distance / spacing_m)))
        for step in range(1, steps + 1):
            t = step / steps
            lat, lon = interpolate_latlon(a, b, t)
            item: dict[str, Any] = {"lat": lat, "lon": lon}
            if step == steps:
                item.update(current)
            else:
                item["source"] = "densified_geodesic_segment"
            dense.append(item)
    return dense


def frame_for_points(points: list[dict[str, Any]]) -> dict[str, float]:
    origin = (float(points[0]["lat"]), float(points[0]["lon"]))
    forward_east = 0.0
    forward_north = 0.0
    for point in points[1:]:
        east, north = local_enu(origin, (float(point["lat"]), float(point["lon"])))
        length = math.hypot(east, north)
        if length > 0.1:
            forward_east = east / length
            forward_north = north / length
            break
    if math.hypot(forward_east, forward_north) < 0.9:
        raise ValueError("could not derive geographic forward frame")
    return {
        "origin_lat": origin[0],
        "origin_lon": origin[1],
        "forward_east": forward_east,
        "forward_north": forward_north,
        "right_east": forward_north,
        "right_north": -forward_east,
    }


def world_xz(
    lat: float, lon: float, frame: dict[str, float]
) -> tuple[float, float]:
    east, north = local_enu((frame["origin_lat"], frame["origin_lon"]), (lat, lon))
    x = east * frame["right_east"] + north * frame["right_north"]
    z = -(east * frame["forward_east"] + north * frame["forward_north"])
    return x, z


def heading_deg(points: list[dict[str, Any]], index: int) -> float:
    index0 = max(0, index - 1)
    index1 = min(len(points) - 1, index + 1)
    a = world_xz(float(points[index0]["lat"]), float(points[index0]["lon"]), points[0]["_frame"])
    b = world_xz(float(points[index1]["lat"]), float(points[index1]["lon"]), points[0]["_frame"])
    return math.degrees(math.atan2(b[0] - a[0], -(b[1] - a[1])))


def nearest_by_s(points: list[dict[str, Any]], s: float) -> dict[str, Any]:
    return min(points, key=lambda point: abs(float(point["s_m"]) - s))


def scaled_base_geometry(
    base: dict[str, Any], old_length: float, new_length: float, dense: list[dict[str, Any]], frame: dict[str, float]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    scale = new_length / max(old_length, 1e-9)
    checkpoints: list[dict[str, Any]] = []
    for raw in base.get("checkpoints", []):
        if not isinstance(raw, dict):
            continue
        old_s = float(raw.get("distance_m", 0.0))
        mapped_s = max(0.0, min(new_length, old_s * scale))
        point = nearest_by_s(dense, mapped_s)
        checkpoints.append(
            {
                "distance_m": mapped_s,
                "video_seconds": float(raw.get("video_seconds", raw.get("time_s", 0.0))),
                "elevation_m": point["elevation_m"],
                "heading_deg": point["heading_deg"],
                "estimated": True,
                "mapping": "old route distance ratio to geographic arc length",
            }
        )
    sections: list[dict[str, Any]] = []
    for raw in base.get("sections", []):
        if not isinstance(raw, dict):
            continue
        section = dict(raw)
        if "from_m" in section:
            section["from_m"] = max(0.0, min(new_length, float(section["from_m"]) * scale))
        if "to_m" in section:
            section["to_m"] = max(0.0, min(new_length, float(section["to_m"]) * scale))
        section["mapping"] = "estimated from legacy route proportions"
        sections.append(section)
    landmarks: list[dict[str, Any]] = []
    for raw in base.get("landmarks", []):
        if not isinstance(raw, dict):
            continue
        landmark = dict(raw)
        if "distance_m" in landmark:
            landmark["distance_m"] = max(0.0, min(new_length, float(landmark["distance_m"]) * scale))
        landmark["mapping"] = "estimated from legacy route proportions"
        landmarks.append(landmark)
    return checkpoints, sections, landmarks


def build(args: argparse.Namespace) -> dict[str, Any]:
    candidate = read_json(args.candidate)
    raw_points = candidate.get("points")
    if not isinstance(raw_points, list) or len(raw_points) < 2:
        raise ValueError("candidate must contain at least two points")
    points = [dict(point) for point in raw_points if isinstance(point, dict)]
    roads = SupplementalRoads(args.supplemental_osm)
    points, connectors = attach_supplemental_connectors(
        points, candidate.get("snapped_endpoint_gaps", []), roads
    )
    dense = densify(points, args.sample_spacing)
    frame = frame_for_points(dense)
    dem = DemSampler(args.dem_metadata, args.dem)
    datum_m = dem.sample(frame["origin_lat"], frame["origin_lon"])
    input_sha256 = {
        "candidate": sha256_file(args.candidate),
        "candidate_osm": sha256_file(args.candidate_osm),
        "supplemental_osm": sha256_file(args.supplemental_osm),
        "dem_metadata": sha256_file(args.dem_metadata),
        "dem_file": sha256_file(args.dem),
        "base_route": sha256_file(args.base_route),
    }

    cumulative = 0.0
    previous_latlon: tuple[float, float] | None = None
    for index, point in enumerate(dense):
        lat = float(point["lat"])
        lon = float(point["lon"])
        if previous_latlon is not None:
            cumulative += metres_between(previous_latlon, (lat, lon))
        previous_latlon = (lat, lon)
        point["s_m"] = cumulative
        x, z = world_xz(lat, lon, frame)
        elevation = dem.sample(lat, lon)
        point["x_m"] = x
        point["z_m"] = z
        point["elevation_m"] = elevation
        point["height_m"] = elevation - datum_m
    for index, point in enumerate(dense):
        point["_frame"] = frame
        point["heading_deg"] = heading_deg(dense, index)
    for point in dense:
        point.pop("_frame", None)
    length_m = cumulative
    base = read_json(args.base_route)
    old_length = float(base.get("estimated_length_m", 14800.0))
    checkpoints, sections, landmarks = scaled_base_geometry(base, old_length, length_m, dense, frame)
    # Keep only serializable source fields and make the geometry provenance
    # explicit.  Node ids for generated samples are optional diagnostics.
    output_points: list[dict[str, Any]] = []
    for point in dense:
        output_points.append(
            {
                "node": point.get("node"),
                "source": point.get("source", "candidate_centerline"),
                "lat": point["lat"],
                "lon": point["lon"],
                "s_m": point["s_m"],
                "x_m": point["x_m"],
                "z_m": point["z_m"],
                "elevation_m": point["elevation_m"],
                "height_m": point["height_m"],
                "heading_deg": point["heading_deg"],
            }
        )
    output = {
        "schema_version": 1,
        "id": "saisies_geo_d218b",
        "title": "Saisies D218B geographic route (estimated source geography)",
        "note": "Map-derived geographic centerline and DEM heights; start/end and legacy video-time mapping are estimates, not GPS calibration.",
        "source": {
            "candidate": provenance_path(args.candidate),
            "candidate_osm": provenance_path(args.candidate_osm),
            "candidate_note": candidate.get("note", ""),
            "inputs_note": "analysis-cache inputs are provenance only; runtime route points and DEM assets are embedded/project-relative.",
            "supplemental_osm": provenance_path(args.supplemental_osm),
            "dem_metadata": provenance_path(args.dem_metadata),
            "dem_file": provenance_path(args.dem),
            "base_route": provenance_path(args.base_route),
            "source_urls": [
                "https://www.openstreetmap.org/",
                "https://registry.opendata.aws/terrain-tiles/",
            ],
            "input_sha256": input_sha256,
            "start_node": candidate.get("start_node"),
            "end_node": candidate.get("end_node"),
        },
        "geography_frame": {
            **frame,
            "datum_m": datum_m,
            "world_convention": "x=dot(ENU,right), z=-dot(ENU,forward), y=DEM-datum",
            "right_convention": "right=(forward_north,-forward_east)",
        },
        "dem": {
            "metadata_file": provenance_path(args.dem_metadata),
            "height_file": provenance_path(args.dem),
            "centre": dem.metadata.get("centre"),
            "size_m": dem.size_m,
            "grid": dem.grid,
            "row0": dem.metadata.get("height", {}).get("row0", "north"),
            "zoom": dem.zoom,
            "sampling": "bilinear Web-Mercator pixel mapping; no latitude/longitude degree-as-metre shortcut",
        },
        "estimated_length_m": length_m,
        "length_m": length_m,
        "sample_spacing_m": args.sample_spacing,
        "road_width_m": float(base.get("road_width_m", 6.4)),
        "start_elevation_m": dense[0]["elevation_m"],
        "end_elevation_m": dense[-1]["elevation_m"],
        "height_source": "AWS Terrain Tiles / cached Terrarium DEM",
        "source_urls": [
            "https://www.openstreetmap.org/",
            "https://registry.opendata.aws/terrain-tiles/",
        ],
        "input_sha256": input_sha256,
        "old_time_mapping": "legacy checkpoints and sections scaled by geographic_length / legacy_length; estimated until landmarks are matched",
        "supplemental_connectors": connectors,
        "snapped_endpoint_gaps": candidate.get("snapped_endpoint_gaps", []),
        "checkpoints": checkpoints,
        "sections": sections,
        "landmarks": landmarks,
        "points": output_points,
    }
    return output


def main() -> int:
    args = parse_args()
    try:
        output = build(args)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(output, indent=2) + "\n")
        points = output["points"]
        inserted = [item for item in output["supplemental_connectors"] if item.get("status") == "inserted"]
        print(
            "built %s: %.3f m, %d samples, %d supplemental connectors, DEM %.2f..%.2f m"
            % (
                args.output,
                output["length_m"],
                len(points),
                len(inserted),
                min(point["elevation_m"] for point in points),
                max(point["elevation_m"] for point in points),
            )
        )
        for connector in output["supplemental_connectors"]:
            print(
                "connector %s->%s: %s%s"
                % (
                    connector.get("start_node"),
                    connector.get("end_node"),
                    connector.get("status"),
                    " (%s)" % connector.get("source") if connector.get("source") else "",
                )
            )
        return 0
    except (OSError, ValueError, ET.ParseError, struct.error) as exc:
        print(f"build failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
