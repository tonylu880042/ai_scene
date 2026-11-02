class_name SaisiesGeoBuildings
extends Node3D

## OSM footprint staging for the independent round-eight geography scene.
##
## The module intentionally depends on route.geography rather than the old
## route-space ground_y approximation.  It can therefore be enabled after the
## terrain/route Luna exposes the shared geographic helper without changing the
## existing v2 village module.

@export_file("*.json") var buildings_file := "res://data/saisies_geo_buildings.json"
@export var route_path: NodePath
@export var landscape_path: NodePath
@export var authored_village_path: NodePath
@export var max_buildings := 240
@export var foundation_sink_m := 0.08

var route: SaisiesRoute
var geography: Object
var landscape: Node
var authored_village: Node
var buildings_ready := false
var geometry_errors := 0
var skipped_features := 0
var inner_rings_preserved := 0
var authored_village_suppressed_count := 0
var authored_village_suppressed_ids: Array[String] = []
var authored_village_suppression_records: Array = []
var authored_village_footprints: Array = []
var winding_normalized_count := 0
var winding_normalized_ids: Array[String] = []
var _materials: Dictionary = {}
var _last_roof_gable_caps := 0
var _last_roof_cap_face_offsets: Array[int] = []
var _last_roof_cap_outward: Array[Vector3] = []
var _authored_village_warning_emitted := false

func _ready() -> void:
	route = get_node_or_null(route_path) as SaisiesRoute
	if route == null and get_parent() != null:
		route = get_parent().get_node_or_null("Route") as SaisiesRoute
	_resolve_landscape()
	_resolve_authored_village()
	if route == null or not route.route_ready() or not _landscape_ready_if_requested() or not _authored_village_ready_if_requested():
		call_deferred("_try_build")
		return
	_build()

func _try_build() -> void:
	if buildings_ready:
		return
	if route == null:
		route = get_node_or_null(route_path) as SaisiesRoute
	_resolve_landscape()
	_resolve_authored_village()
	if route != null and route.route_ready() and _landscape_ready_if_requested() and _authored_village_ready_if_requested():
		_build()
	else:
		call_deferred("_try_build")

func _build() -> void:
	if buildings_ready or route == null:
		return
	if not _landscape_ready_if_requested():
		return
	if not _authored_village_ready_if_requested():
		return
	if not _route_has_property("geography"):
		push_warning("SaisiesGeoBuildings HOLD: route.geography is not exposed yet")
		return
	geography = route.get("geography") as Object
	if geography == null or not geography.has_method("world_from_latlon") or not geography.has_method("height_world"):
		push_warning("SaisiesGeoBuildings HOLD: route.geography lacks geographic helpers")
		return
	_collect_authored_village_footprints()
	_make_materials()
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(buildings_file)) if FileAccess.file_exists(buildings_file) else null
	if not (parsed is Dictionary):
		push_error("SaisiesGeoBuildings: building data is missing or invalid")
		return
	var payload: Dictionary = parsed
	var features: Array = payload.get("buildings", [])
	var group := Node3D.new()
	group.name = "SaisiesGeoBuildingFootprints"
	add_child(group)
	var built_count := 0
	for item in features:
		if built_count >= max_buildings:
			break
		if not (item is Dictionary):
			skipped_features += 1
			continue
		var feature: Dictionary = item
		if not _build_feature(group, feature):
			skipped_features += 1
			continue
		built_count += 1
	set_meta("saisies_geo_buildings_ready", true)
	set_meta("saisies_geo_buildings_file", buildings_file)
	set_meta("saisies_geo_buildings_count", built_count)
	set_meta("saisies_geo_buildings_geometry_errors", geometry_errors)
	set_meta("saisies_geo_buildings_skipped_features", skipped_features)
	set_meta("saisies_geo_buildings_inner_rings_preserved", inner_rings_preserved)
	set_meta("saisies_geo_buildings_authored_village_footprint_count", authored_village_footprints.size())
	set_meta("saisies_geo_buildings_authored_village_suppressed_count", authored_village_suppressed_count)
	set_meta("saisies_geo_buildings_authored_village_suppressed_ids", authored_village_suppressed_ids)
	set_meta("saisies_geo_buildings_authored_village_suppressions", authored_village_suppression_records)
	set_meta("saisies_geo_buildings_authored_village_footprints", authored_village_footprints)
	set_meta("saisies_geo_buildings_authored_village_contract", "world XZ polygons; OSM is skipped only on positive-area polygon intersection")
	set_meta("saisies_geo_buildings_winding_normalized_count", winding_normalized_count)
	set_meta("saisies_geo_buildings_winding_normalized_ids", winding_normalized_ids)
	set_meta("saisies_geo_buildings_signage_deferred", true)
	set_meta("saisies_geo_buildings_ground_source", "landscape.sample_mesh_triangle" if _landscape_requested() else "route.geography.height_world")
	set_meta("saisies_geo_buildings_landscape_grounding", _landscape_requested())
	buildings_ready = true
	print("saisies geo buildings: built=%d skipped=%d geometry_errors=%d inner_rings=%d" % [built_count, skipped_features, geometry_errors, inner_rings_preserved])

func _route_has_property(property_name: String) -> bool:
	if route == null:
		return false
	for property in route.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false

func _resolve_landscape() -> void:
	if landscape != null:
		return
	if landscape_path != NodePath():
		landscape = get_node_or_null(landscape_path)
	if landscape == null and landscape_path == NodePath() and get_parent() != null:
		landscape = get_parent().get_node_or_null("Landscape")

func _resolve_authored_village() -> void:
	if is_instance_valid(authored_village):
		return
	if authored_village_path != NodePath():
		authored_village = get_node_or_null(authored_village_path)
	if authored_village == null and get_parent() != null:
		authored_village = get_parent().find_child("VillageS01S02", true, false) as Node
	if authored_village == null and get_parent() != null:
		authored_village = get_parent().find_child("NewVillageS01S02", true, false) as Node

func _authored_village_ready_if_requested() -> bool:
	_resolve_authored_village()
	if authored_village == null:
		return authored_village_path == NodePath()
	if not authored_village.has_method("get_authored_building_footprints"):
		if not _authored_village_warning_emitted:
			push_warning("SaisiesGeoBuildings HOLD: authored village lacks get_authored_building_footprints()")
			_authored_village_warning_emitted = true
		return false
	for property_name in ["village_ready", "authored_village_ready", "geo_village_ready"]:
		if _node_has_property(authored_village, property_name):
			return bool(authored_village.get(property_name))
	for method_name in ["is_ready", "village_ready", "authored_village_ready"]:
		if authored_village.has_method(method_name):
			var ready_value = authored_village.call(method_name)
			if ready_value is bool:
				return ready_value
	for meta_name in ["saisies_village_ready", "saisies_geo_village_ready"]:
		if authored_village.has_meta(meta_name):
			return bool(authored_village.get_meta(meta_name))
	return true

func _node_has_property(node: Node, property_name: String) -> bool:
	for property in node.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false

func _landscape_requested() -> bool:
	return landscape_path != NodePath()

func _landscape_ready_if_requested() -> bool:
	if not _landscape_requested():
		return true
	_resolve_landscape()
	return landscape != null and landscape.has_method("sample_mesh_triangle") and _has_landscape_ready_property() and bool(landscape.get("landscape_ready"))

func _has_landscape_ready_property() -> bool:
	if landscape == null:
		return false
	for property in landscape.get_property_list():
		if String(property.get("name", "")) == "landscape_ready":
			return true
	return false

func _collect_authored_village_footprints() -> void:
	authored_village_footprints.clear()
	if authored_village == null or not authored_village.has_method("get_authored_building_footprints"):
		return
	var raw = authored_village.call("get_authored_building_footprints")
	var records: Array = []
	if authored_village.has_method("get_authored_footprint_records"):
		var raw_records = authored_village.call("get_authored_footprint_records")
		if raw_records is Array:
			records = raw_records
	if raw is Dictionary and raw.has("footprints"):
		raw = raw.get("footprints")
	if _is_point_like(raw):
		raw = [raw]
	if raw is PackedVector2Array or raw is PackedVector3Array:
		raw = [raw]
	if not (raw is Array):
		return
	if _array_is_polygon(raw):
		var polygon := _normalise_polygon(raw)
		if polygon.size() >= 3:
			var polygon_id := "authored/0"
			if not records.is_empty() and records[0] is Dictionary:
				var record: Dictionary = records[0]
				polygon_id = String(record.get("id", record.get("building_name", record.get("name", polygon_id))))
			authored_village_footprints.append({"id": polygon_id, "polygon": polygon, "area_m2": absf(_polygon_area(polygon))})
		return
	for item_index in raw.size():
		var item = raw[item_index]
		var item_id := "authored/%d" % item_index
		if item_index < records.size() and records[item_index] is Dictionary:
			var record: Dictionary = records[item_index]
			item_id = String(record.get("id", record.get("building_name", record.get("name", item_id))))
		var candidate = item
		if item is Dictionary:
			item_id = String(item.get("id", item.get("name", item_id)))
			for key in ["polygon", "footprint_xz", "footprint", "points", "vertices", "world_xz"]:
				if item.has(key):
					candidate = item.get(key)
					break
		var polygon := _normalise_polygon(candidate)
		var area := absf(_polygon_area(polygon))
		if polygon.size() >= 3 and area > 0.001:
			authored_village_footprints.append({"id": item_id, "polygon": polygon, "area_m2": area})

func _array_is_polygon(value: Array) -> bool:
	if value.is_empty():
		return false
	return _is_point_like(value[0])

func _is_point_like(value: Variant) -> bool:
	if value is Vector2 or value is Vector3:
		return true
	if value is Array:
		return value.size() >= 2 and (value[0] is float or value[0] is int) and (value[1] is float or value[1] is int)
	if value is Dictionary:
		return (value.has("x") and value.has("z")) or (value.has("east") and value.has("north"))
	return false

func _normalise_polygon(value: Variant) -> PackedVector2Array:
	var polygon := PackedVector2Array()
	if value is PackedVector2Array:
		return value
	if value is PackedVector3Array:
		for point in value:
			polygon.append(Vector2(point.x, point.z))
		return polygon
	if not (value is Array):
		return polygon
	for point in value:
		var xz = _to_xz(point)
		if xz != null:
			polygon.append(xz)
	if polygon.size() > 1 and polygon[0].distance_to(polygon[polygon.size() - 1]) < 0.01:
		polygon.remove_at(polygon.size() - 1)
	return polygon

func _to_xz(value: Variant):
	if value is Vector2:
		return value
	if value is Vector3:
		return Vector2(value.x, value.z)
	if value is Array and value.size() >= 2 and (value[0] is float or value[0] is int) and (value[1] is float or value[1] is int):
		return Vector2(float(value[0]), float(value[1]))
	if value is Dictionary:
		if value.has("x") and value.has("z"):
			return Vector2(float(value["x"]), float(value["z"]))
		if value.has("east") and value.has("north"):
			return Vector2(float(value["east"]), float(value["north"]))
	return null

func _polygon_area(polygon: PackedVector2Array) -> float:
	if polygon.size() < 3:
		return 0.0
	var area := 0.0
	for index in polygon.size():
		var current := polygon[index]
		var next := polygon[(index + 1) % polygon.size()]
		area += current.x * next.y - next.x * current.y
	return area * 0.5

func _polygon_area_from_world_points(points: Array[Vector3]) -> float:
	var polygon := PackedVector2Array()
	for point in points:
		polygon.append(Vector2(point.x, point.z))
	return _polygon_area(polygon)

func _positive_polygon_intersection_area(left: PackedVector2Array, right: PackedVector2Array) -> float:
	if left.size() < 3 or right.size() < 3:
		return 0.0
	var intersections := Geometry2D.intersect_polygons(left, right)
	var total := 0.0
	for polygon in intersections:
		if polygon is PackedVector2Array:
			total += absf(_polygon_area(polygon))
	return total

func _wall_bad_normal_count(mesh: ArrayMesh, wall_points: Array[Vector3]) -> int:
	if mesh == null:
		return 0
	var faces := mesh.get_faces()
	var bad := 0
	var expected_edge_count := mini(wall_points.size(), faces.size() / 6)
	for edge_index in expected_edge_count:
		var edge := wall_points[(edge_index + 1) % wall_points.size()] - wall_points[edge_index]
		edge.y = 0.0
		if edge.length_squared() < 0.000001:
			continue
		var expected_outward := edge.normalized().cross(Vector3.UP)
		for triangle_index in 2:
			var face_offset := (edge_index * 2 + triangle_index) * 3
			var a := faces[face_offset]
			var b := faces[face_offset + 1]
			var c := faces[face_offset + 2]
			var normal := (c - a).cross(b - a)
			if normal.length_squared() < 0.000001 or normal.normalized().dot(expected_outward) < 0.99:
				bad += 1
	return bad

func _roof_bad_normal_count(mesh: ArrayMesh, cap_face_offsets: Array[int], cap_outward: Array[Vector3]) -> int:
	if mesh == null:
		return 0
	var faces := mesh.get_faces()
	var bad := 0
	for face_offset in range(0, faces.size(), 3):
		var a := faces[face_offset]
		var b := faces[face_offset + 1]
		var c := faces[face_offset + 2]
		var normal := (c - a).cross(b - a)
		var cap_index := cap_face_offsets.find(face_offset)
		if cap_index >= 0:
			if normal.length_squared() < 0.000001 or cap_index >= cap_outward.size() or normal.normalized().dot(cap_outward[cap_index]) <= 0.0:
				bad += 1
			continue
		if normal.length_squared() < 0.000001 or normal.normalized().y < -0.001:
			bad += 1
	return bad

func _authored_village_overlap(footprint: Array[Vector3]) -> Dictionary:
	if authored_village_footprints.is_empty():
		return {}
	var osm_polygon := PackedVector2Array()
	for point in footprint:
		osm_polygon.append(Vector2(point.x, point.z))
	var matched_ids: Array[String] = []
	var matched_areas: Array[float] = []
	for record in authored_village_footprints:
		var authored_polygon: PackedVector2Array = record["polygon"]
		var overlap_area := _positive_polygon_intersection_area(osm_polygon, authored_polygon)
		if overlap_area > 0.001:
			matched_ids.append(String(record["id"]))
			matched_areas.append(overlap_area)
	if matched_ids.is_empty():
		return {}
	return {"ids": matched_ids, "areas_m2": matched_areas}

func _build_feature(parent: Node3D, feature: Dictionary) -> bool:
	var rings: Array = feature.get("rings", [])
	var outer: Dictionary = {}
	for ring_item in rings:
		if not (ring_item is Dictionary):
			continue
		var ring: Dictionary = ring_item
		if String(ring.get("role", "outer")) == "outer":
			outer = ring
		else:
			inner_rings_preserved += 1
	if outer.is_empty():
		geometry_errors += 1
		return false
	var coordinates: Array = outer.get("coordinates", [])
	if coordinates.size() < 4:
		geometry_errors += 1
		return false
	var footprint: Array[Vector3] = []
	for coordinate_item in coordinates:
		if not (coordinate_item is Array) or coordinate_item.size() < 2:
			geometry_errors += 1
			return false
		var coordinate: Array = coordinate_item
		var point := _world_from_latlon(float(coordinate[1]), float(coordinate[0]))
		point.y = _height_world(point)
		if not _finite_vector(point):
			geometry_errors += 1
			return false
		footprint.append(point)
	if footprint.size() > 1 and footprint[0].distance_to(footprint[footprint.size() - 1]) < 0.02:
		footprint.pop_back()
	if footprint.size() < 3:
		geometry_errors += 1
		return false
	var source_footprint := footprint.duplicate()
	var winding_area := _polygon_area_from_world_points(footprint)
	if absf(winding_area) < 0.0001:
		geometry_errors += 1
		return false
	var winding_flipped := false
	if winding_area > 0.0:
		footprint.reverse()
		winding_normalized_count += 1
		winding_flipped = true
		winding_normalized_ids.append(String(feature.get("id", feature.get("osm_id", "unknown"))))
	var overlap := _authored_village_overlap(footprint)
	if not overlap.is_empty():
		var feature_id := String(feature.get("id", feature.get("osm_id", "unknown")))
		authored_village_suppressed_count += 1
		authored_village_suppressed_ids.append(feature_id)
		authored_village_suppression_records.append({
			"id": feature_id,
			"osm_id": feature_id,
			"authored_footprint_ids": overlap["ids"],
			"positive_intersection_areas_m2": overlap["areas_m2"]
		})
		return false
	var wall_points := _with_edge_samples(footprint)
	var height_m := maxf(float(feature.get("height_m", 6.2)), 2.0)
	var roof_rise_m := clampf(float(feature.get("roof_rise_m", height_m * 0.22)), 0.8, 3.5)
	var eave_y := _eave_y(wall_points, height_m)
	var building := Node3D.new()
	var feature_id := String(feature.get("id", feature.get("osm_id", "unknown")))
	building.name = "GeoBuilding_%s" % feature_id.replace("/", "_")
	building.set_meta("osm_id", int(feature.get("osm_id", -1)))
	building.set_meta("osm_feature_id", feature_id)
	building.set_meta("osm_type", String(feature.get("osm_type", "way")))
	building.set_meta("osm_tags", feature.get("tags", {}))
	building.set_meta("osm_node_ids", feature.get("node_ids", []))
	building.set_meta("height_m", height_m)
	building.set_meta("height_source", String(feature.get("height_source", "default_estimate")))
	building.set_meta("foundation_sink_m", foundation_sink_m)
	building.set_meta("footprint_latlon", coordinates)
	var footprint_world_xz := PackedVector2Array()
	for point in source_footprint:
		footprint_world_xz.append(Vector2(point.x, point.z))
	building.set_meta("footprint_world_xz", footprint_world_xz)
	var normalized_footprint_world_xz := PackedVector2Array()
	for point in footprint:
		normalized_footprint_world_xz.append(Vector2(point.x, point.z))
	building.set_meta("footprint_world_xz_normalized", normalized_footprint_world_xz)
	building.set_meta("footprint_winding", "clockwise_xz")
	building.set_meta("footprint_winding_area_xz", _polygon_area_from_world_points(footprint))
	building.set_meta("footprint_winding_flipped", winding_flipped)
	building.set_meta("roof_source", String(feature.get("roof_source", "simple_generated_pitched_roof")))
	building.set_meta("building_source_contract", "OSM_BACKGROUND_STAGING")
	parent.add_child(building)
	var walls := MeshInstance3D.new()
	walls.name = "FoundationWall"
	walls.mesh = _wall_mesh(wall_points, eave_y)
	walls.material_override = _wall_material(feature.get("tags", {}))
	building.add_child(walls)
	var roof := MeshInstance3D.new()
	roof.name = "SimplePitchedRoof"
	roof.mesh = _roof_mesh(footprint, eave_y, roof_rise_m)
	roof.material_override = _materials["roof"]
	building.add_child(roof)
	_build_alpine_facade(building, footprint, height_m, eave_y, feature.get("tags", {}))
	var wall_bad_normals := _wall_bad_normal_count(walls.mesh, wall_points)
	var roof_bad_normals := _roof_bad_normal_count(roof.mesh, _last_roof_cap_face_offsets, _last_roof_cap_outward)
	building.set_meta("wall_bad_normal_count", wall_bad_normals)
	building.set_meta("roof_bad_normal_count", roof_bad_normals)
	building.set_meta("foundation_sample_count", wall_points.size())
	building.set_meta("foundation_bottom_vertices", _bottom_sample_vectors(wall_points))
	building.set_meta("foundation_ground_vertices", _ground_sample_vectors(wall_points))
	building.set_meta("foundation_eave_y", eave_y)
	building.set_meta("roof_rise_m", roof_rise_m)
	building.set_meta("roof_ridge_y", eave_y + roof_rise_m)
	building.set_meta("roof_gable_caps", _last_roof_gable_caps)
	building.set_meta("roof_gable_cap_face_offsets", _last_roof_cap_face_offsets.duplicate())
	building.set_meta("roof_gable_cap_outward", _last_roof_cap_outward.duplicate())
	building.set_meta("roof_closed", _last_roof_gable_caps == 2)
	return walls.mesh != null and roof.mesh != null

func _world_from_latlon(lat: float, lon: float) -> Vector3:
	var value = geography.call("world_from_latlon", lat, lon)
	if value is Vector3:
		return value
	if value is Vector2:
		return Vector3(value.x, 0.0, value.y)
	return Vector3(INF, INF, INF)

func _height_world(point: Vector3) -> float:
	if _landscape_requested():
		if landscape == null or not landscape.has_method("sample_mesh_triangle"):
			return INF
		var sampled = landscape.call("sample_mesh_triangle", Vector2(point.x, point.z))
		if sampled is Dictionary and sampled.has("height"):
			var mesh_height := float(sampled["height"])
			if is_finite(mesh_height):
				return mesh_height
		return INF
	var value = geography.call("height_world", Vector2(point.x, point.z))
	if value is float or value is int:
		return float(value)
	return INF

func _finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _with_edge_samples(points: Array[Vector3]) -> Array[Vector3]:
	var sampled: Array[Vector3] = []
	for index in points.size():
		var current := points[index]
		var next := points[(index + 1) % points.size()]
		sampled.append(current)
		var midpoint := (current + next) * 0.5
		midpoint.y = _height_world(midpoint)
		if _finite_vector(midpoint):
			sampled.append(midpoint)
		else:
			geometry_errors += 1
	return sampled

func _eave_y(points: Array[Vector3], height_m: float) -> float:
	var highest_ground := -INF
	for point in points:
		highest_ground = maxf(highest_ground, point.y)
	return highest_ground + height_m

func _wall_mesh(points: Array[Vector3], eave_y: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_smooth_group(-1)
	for index in points.size():
		var p0 := points[index]
		var p1 := points[(index + 1) % points.size()]
		var b0 := p0 + Vector3.DOWN * foundation_sink_m
		var b1 := p1 + Vector3.DOWN * foundation_sink_m
		var t0 := Vector3(p0.x, eave_y, p0.z)
		var t1 := Vector3(p1.x, eave_y, p1.z)
		_add_quad(surface, b0, t0, t1, b1)
	surface.generate_normals()
	return surface.commit()

func _roof_mesh(points: Array[Vector3], eave_y: float, roof_rise_m: float) -> ArrayMesh:
	_last_roof_gable_caps = 0
	_last_roof_cap_face_offsets.clear()
	_last_roof_cap_outward.clear()
	var axis := Vector3.RIGHT
	var longest := 0.0
	for index in points.size():
		var edge := points[(index + 1) % points.size()] - points[index]
		edge.y = 0.0
		if edge.length() > longest:
			longest = edge.length()
			axis = edge.normalized()
	if longest < 0.01:
		axis = Vector3.RIGHT
	var centre := Vector3.ZERO
	for point in points:
		centre += Vector3(point.x, eave_y, point.z)
	centre /= float(points.size())
	var min_axis := INF
	var max_axis := -INF
	for point in points:
		var along := (point - centre).dot(axis)
		min_axis = minf(min_axis, along)
		max_axis = maxf(max_axis, along)
	var ridge_start := centre + axis * min_axis + Vector3.UP * roof_rise_m
	var ridge_end := centre + axis * max_axis + Vector3.UP * roof_rise_m
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_smooth_group(-1)
	var triangle_count := 0
	for index in points.size():
		var p0 := Vector3(points[index].x, eave_y, points[index].z)
		var p1 := Vector3(points[(index + 1) % points.size()].x, eave_y, points[(index + 1) % points.size()].z)
		var a0 := clampf((p0 - centre).dot(axis), min_axis, max_axis)
		var a1 := clampf((p1 - centre).dot(axis), min_axis, max_axis)
		var r0 := ridge_start.lerp(ridge_end, inverse_lerp(min_axis, max_axis, a0))
		var r1 := ridge_start.lerp(ridge_end, inverse_lerp(min_axis, max_axis, a1))
		if _add_roof_triangle(surface, p0, p1, r1):
			triangle_count += 1
		if _add_roof_triangle(surface, p0, r1, r0):
			triangle_count += 1
	# The perimeter triangles leave the two gable end planes open.  Close each
	# end with the two eave vertices nearest the axis endpoint and its ridge tip.
	var min_pair := _gable_end_pair(points, centre, axis, min_axis, eave_y)
	if min_pair.size() == 2:
		_last_roof_cap_face_offsets.append(triangle_count * 3)
		_last_roof_cap_outward.append(-axis)
		_add_roof_cap_triangle(surface, min_pair[0], min_pair[1], ridge_start, -axis)
		triangle_count += 1
		_last_roof_gable_caps += 1
	var max_pair := _gable_end_pair(points, centre, axis, max_axis, eave_y)
	if max_pair.size() == 2:
		_last_roof_cap_face_offsets.append(triangle_count * 3)
		_last_roof_cap_outward.append(axis)
		_add_roof_cap_triangle(surface, max_pair[1], max_pair[0], ridge_end, axis)
		triangle_count += 1
		_last_roof_gable_caps += 1
	surface.generate_normals()
	return surface.commit()

func _gable_end_pair(points: Array[Vector3], centre: Vector3, axis: Vector3, target_axis: float, eave_y: float) -> Array[Vector3]:
	var first := Vector3.ZERO
	var second := Vector3.ZERO
	var first_distance := INF
	var second_distance := INF
	var has_first := false
	for point in points:
		var candidate := Vector3(point.x, eave_y, point.z)
		var distance := absf((candidate - centre).dot(axis) - target_axis)
		if not has_first or distance < first_distance:
			second = first
			second_distance = first_distance
			first = candidate
			first_distance = distance
			has_first = true
		elif distance < second_distance:
			second = candidate
			second_distance = distance
	if not has_first or second_distance == INF or first.distance_to(second) < 0.02:
		return []
	return [first, second]

func _add_quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_add_triangle(surface, a, b, c)
	_add_triangle(surface, a, c, d)

func _add_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	surface.add_vertex(a)
	surface.add_vertex(b)
	surface.add_vertex(c)

func _add_roof_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> bool:
	# Roof surfaces must face upward for Godot's clockwise front-face convention.
	# Keep the generated footprint/ridge vertices untouched; only correct winding.
	var normal := (c - a).cross(b - a)
	if normal.length_squared() < 0.000001:
		return false
	if normal.y < 0.0:
		_add_triangle(surface, a, c, b)
	else:
		_add_triangle(surface, a, b, c)
	return true

func _add_roof_cap_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, expected_outward: Vector3) -> void:
	# Gable caps are vertical, so their y component cannot establish winding.
	# Orient each cap against the ridge axis while preserving its source vertices.
	var normal := (c - a).cross(b - a)
	if normal.length_squared() > 0.000001 and normal.normalized().dot(expected_outward) < 0.0:
		_add_triangle(surface, a, c, b)
	else:
		_add_triangle(surface, a, b, c)

func _facade_window_plan(edge_infos: Array[Dictionary]) -> Dictionary:
	var row_counts: Array[int] = []
	var column_counts: Array[int] = []
	var desired_rows: Array[int] = []
	var desired_columns: Array[int] = []
	var eligible_slots: Array[int] = []
	for edge_slot in edge_infos.size():
		var info: Dictionary = edge_infos[edge_slot]
		var edge_length := float(info["length"])
		var face_span := maxf(float(info["eave_y"]) - float(info["ground_y"]), 0.0)
		var eligible := edge_length >= 2.5 and face_span >= 1.8
		var wanted_rows := clampi(int(floor(face_span / 2.6)), 1, 4) if eligible else 0
		var wanted_columns := clampi(int(floor(edge_length / 3.0)), 1, 5) if eligible else 0
		row_counts.append(1 if eligible else 0)
		column_counts.append(1 if eligible else 0)
		desired_rows.append(wanted_rows)
		desired_columns.append(wanted_columns)
		if eligible:
			eligible_slots.append(edge_slot)
	var eligible_count := eligible_slots.size()
	if eligible_count == 0:
		return {"rows": row_counts, "columns": column_counts, "eligible": eligible_slots}
	# Keep node counts bounded while reserving one window row for every
	# eligible edge.  Give each edge a second window where its dimensions allow
	# it, then spend the remaining budget by face height/length.  This avoids a
	# first-come cap leaving later visible faces blank.
	var window_budget := maxi(eligible_count, mini(96, maxi(24, eligible_count * 3)))
	var total_windows := eligible_count
	var two_window_target := mini(window_budget, eligible_count * 2)
	for edge_slot in eligible_slots:
		if total_windows >= two_window_target:
			break
		var info: Dictionary = edge_infos[edge_slot]
		var face_span := maxf(float(info["eave_y"]) - float(info["ground_y"]), 0.0)
		var add_row := false
		if desired_rows[edge_slot] > row_counts[edge_slot] and desired_columns[edge_slot] > column_counts[edge_slot]:
			var vertical_need := face_span / 2.6
			var horizontal_need := float(info["length"]) / 3.0
			add_row = vertical_need >= horizontal_need
		elif desired_rows[edge_slot] > row_counts[edge_slot]:
			add_row = true
		elif desired_columns[edge_slot] <= column_counts[edge_slot]:
			continue
		if add_row:
			row_counts[edge_slot] += 1
		else:
			column_counts[edge_slot] += 1
		total_windows += 1
	while total_windows < window_budget:
		var picked_slot := -1
		var picked_add_row := false
		var picked_score := -INF
		for edge_slot in eligible_slots:
			var info: Dictionary = edge_infos[edge_slot]
			var remaining_budget := window_budget - total_windows
			if row_counts[edge_slot] < desired_rows[edge_slot]:
				var row_cost := column_counts[edge_slot]
				if row_cost <= remaining_budget:
					var face_span := maxf(float(info["eave_y"]) - float(info["ground_y"]), 0.0)
					var row_need := float(desired_rows[edge_slot] - row_counts[edge_slot]) / float(desired_rows[edge_slot])
					var row_score := face_span / 2.6 * row_need
					if row_score > picked_score:
						picked_score = row_score
						picked_slot = edge_slot
						picked_add_row = true
			if column_counts[edge_slot] < desired_columns[edge_slot]:
				var column_cost := row_counts[edge_slot]
				if column_cost <= remaining_budget:
					var column_need := float(desired_columns[edge_slot] - column_counts[edge_slot]) / float(desired_columns[edge_slot])
					var column_score := float(info["length"]) / 3.0 * column_need
					if column_score > picked_score:
						picked_score = column_score
						picked_slot = edge_slot
						picked_add_row = false
		if picked_slot < 0:
			break
		if picked_add_row:
			total_windows += column_counts[picked_slot]
			row_counts[picked_slot] += 1
		else:
			total_windows += row_counts[picked_slot]
			column_counts[picked_slot] += 1
	return {"rows": row_counts, "columns": column_counts, "eligible": eligible_slots}

func _build_alpine_facade(building: Node3D, footprint: Array[Vector3], height_m: float, eave_y: float, raw_tags: Variant) -> void:
	var facade := Node3D.new()
	facade.name = "AlpineFacade"
	facade.set_meta("source_contract", "OSM_BACKGROUND_STAGING")
	facade.set_meta("height_m", height_m)
	facade.set_meta("height_source", String(building.get_meta("height_source", "default_estimate")))
	building.add_child(facade)
	if footprint.size() < 2:
		building.set_meta("facade_edge_count", 0)
		building.set_meta("facade_window_count", 0)
		building.set_meta("facade_door_count", 0)
		return
	var edge_infos: Array[Dictionary] = []
	for index in footprint.size():
		var candidate_start := footprint[index]
		var candidate_end := footprint[(index + 1) % footprint.size()]
		var candidate_delta := Vector3(candidate_end.x - candidate_start.x, 0.0, candidate_end.z - candidate_start.z)
		var candidate_length := Vector2(candidate_delta.x, candidate_delta.z).length()
		if candidate_length < 2.0:
			continue
		var candidate_tangent := candidate_delta.normalized()
		# _build_feature normalizes outer rings clockwise in world XZ.  The
		# right-hand edge cross-up direction is therefore outward even for
		# concave footprints; centroid tests can point into a re-entrant corner.
		var candidate_outward := candidate_tangent.cross(Vector3.UP)
		var candidate_midpoint := (candidate_start + candidate_end) * 0.5
		var face_ground_y := maxf(candidate_start.y, candidate_end.y)
		# Use several points along the real ground edge so sloped terrain cannot
		# leave a lower window row buried in the hillside.
		for sample_fraction in [0.25, 0.5, 0.75]:
			var ground_sample := candidate_start.lerp(candidate_end, sample_fraction)
			ground_sample.y = _height_world(ground_sample)
			if _finite_vector(ground_sample):
				face_ground_y = maxf(face_ground_y, ground_sample.y)
		var edge_score := candidate_length
		var route_facing := false
		if route != null and route.has_method("distance_for_position"):
			var route_s := route.distance_for_position(candidate_midpoint)
			var road_point := route.pos_at(route_s)
			var toward_road := Vector3(road_point.x - candidate_midpoint.x, 0.0, road_point.z - candidate_midpoint.z)
			if toward_road.length_squared() > 0.01:
				var road_alignment := candidate_outward.dot(toward_road.normalized())
				edge_score = maxf(road_alignment, 0.0) * candidate_length * candidate_length
				route_facing = road_alignment > 0.05
		edge_infos.append({
			"index": index,
			"start": candidate_start,
			"end": candidate_end,
			"midpoint": candidate_midpoint,
			"tangent": candidate_tangent,
			"outward": candidate_outward,
			"length": candidate_length,
			"ground_y": face_ground_y,
			"eave_y": eave_y,
			"edge_score": edge_score,
			"route_facing": route_facing
		})
	if edge_infos.is_empty():
		building.set_meta("facade_edge_count", 0)
		building.set_meta("facade_window_count", 0)
		building.set_meta("facade_door_count", 0)
		return
	var primary_slot := 0
	for edge_slot in range(1, edge_infos.size()):
		var candidate: Dictionary = edge_infos[edge_slot]
		var primary: Dictionary = edge_infos[primary_slot]
		if float(candidate["edge_score"]) > float(primary["edge_score"]) or (is_equal_approx(float(candidate["edge_score"]), float(primary["edge_score"])) and float(candidate["length"]) > float(primary["length"])):
			primary_slot = edge_slot
	var primary_info: Dictionary = edge_infos[primary_slot]
	if bool(primary_info["route_facing"]):
		facade.set_meta("street_facing_edge", "nearest_route_edge")
	else:
		facade.set_meta("street_facing_edge", "longest_footprint_edge")
	var window_plan := _facade_window_plan(edge_infos)
	var planned_rows: Array[int] = window_plan["rows"]
	var planned_columns: Array[int] = window_plan["columns"]
	var edge_ground_levels := PackedFloat32Array()
	var edge_spans := PackedFloat32Array()
	var edge_indices := PackedInt32Array()
	var edge_lengths := PackedFloat32Array()
	var edge_window_counts := PackedInt32Array()
	var edge_row_counts := PackedInt32Array()
	var window_total := 0
	var window_rows_total := 0
	var door_total := 0
	for edge_slot in edge_infos.size():
		var info: Dictionary = edge_infos[edge_slot]
		var midpoint: Vector3 = info["midpoint"]
		var tangent: Vector3 = info["tangent"]
		var outward: Vector3 = info["outward"]
		var edge_length := float(info["length"])
		var face_ground_y := float(info["ground_y"])
		var face_span := maxf(eave_y - face_ground_y, 0.0)
		edge_ground_levels.append(face_ground_y)
		edge_spans.append(face_span)
		edge_indices.append(int(info["index"]))
		edge_lengths.append(edge_length)
		var facade_basis := Basis.looking_at(-outward, Vector3.UP)
		var is_primary := edge_slot == primary_slot
		var row_count := planned_rows[edge_slot]
		var window_count := planned_columns[edge_slot]
		edge_row_counts.append(row_count)
		edge_window_counts.append(window_count)
		var add_windows := row_count > 0 and window_count > 0
		if add_windows:
			var window_span := clampf(edge_length / float(window_count + 1) * 0.48, 0.62, 1.45)
			var window_height := clampf(face_span * 0.18, 0.82, 1.35)
			window_rows_total += row_count
			for row in row_count:
				var row_fraction := 0.5 if row_count == 1 else lerpf(0.30, 0.80, float(row) / float(row_count - 1))
				var row_y := face_ground_y + face_span * row_fraction
				for window_index in window_count:
					var window_t := float(window_index + 1) / float(window_count + 1)
					var along := (window_t - 0.5) * edge_length
					var door_width := clampf(edge_length * 0.14, 0.78, 1.10)
					if is_primary and absf(along) < door_width * 0.70:
						along += door_width * 0.75 if along >= 0.0 else -door_width * 0.75
					var window_position := midpoint + tangent * along + outward * 0.075
					window_position.y = row_y
					var window := _facade_box(facade, "Window_E%02d_R%02d_%02d" % [int(info["index"]), row, window_index], Vector3(window_span, window_height, 0.10), window_position, facade_basis, _materials["facade_glass"])
					window.set_meta("street_facing", is_primary)
					window.set_meta("facade_face_ground_y", face_ground_y)
					window.set_meta("facade_face_eave_y", eave_y)
					_facade_box(facade, "WindowTrimTop_E%02d_R%02d_%02d" % [int(info["index"]), row, window_index], Vector3(window_span + 0.16, 0.10, 0.14), window_position + Vector3.UP * (window_height * 0.5 + 0.07), facade_basis, _materials["facade_wood"])
					_facade_box(facade, "WindowTrimBottom_E%02d_R%02d_%02d" % [int(info["index"]), row, window_index], Vector3(window_span + 0.16, 0.10, 0.14), window_position - Vector3.UP * (window_height * 0.5 + 0.07), facade_basis, _materials["facade_wood"])
					window_total += 1
		# A restrained wood band and eave trim keep long plaster faces from reading
		# as blank slabs while retaining the OSM footprint and generated roof.
		if face_span >= 2.5:
			var band_position := midpoint + outward * 0.06
			band_position.y = face_ground_y + face_span * 0.48
			_facade_box(facade, "WoodBand_E%02d" % int(info["index"]), Vector3(maxf(edge_length - 0.20, 0.50), 0.14, 0.14), band_position, facade_basis, _materials["facade_wood"])
		var eave_position := midpoint + outward * 0.07
		eave_position.y = eave_y - 0.10
		_facade_box(facade, "EaveTrim_E%02d" % int(info["index"]), Vector3(edge_length, 0.12, 0.16), eave_position, facade_basis, _materials["facade_wood"])
		var plinth_position := midpoint + outward * 0.08
		plinth_position.y = face_ground_y + 0.22
		_facade_box(facade, "StonePlinth_E%02d" % int(info["index"]), Vector3(edge_length, 0.42, 0.18), plinth_position, facade_basis, _materials["facade_stone"])
		if is_primary:
			var door_width := clampf(edge_length * 0.14, 0.78, 1.10)
			var door_height := clampf(minf(1.92, maxf(face_span * 0.72, 1.40)), 1.40, 1.92)
			var door_position := midpoint + outward * 0.09
			door_position.y = face_ground_y + door_height * 0.5
			var door := _facade_box(facade, "Door_Street", Vector3(door_width, door_height, 0.12), door_position, facade_basis, _materials["facade_wood"])
			door.set_meta("street_facing", true)
			door.set_meta("facade_face_ground_y", face_ground_y)
			door.set_meta("facade_face_eave_y", eave_y)
			_facade_box(facade, "DoorFrameLeft", Vector3(0.12, door_height + 0.20, 0.17), door_position - tangent * (door_width * 0.5 + 0.06) + Vector3.UP * 0.08, facade_basis, _materials["facade_stone"])
			_facade_box(facade, "DoorFrameRight", Vector3(0.12, door_height + 0.20, 0.17), door_position + tangent * (door_width * 0.5 + 0.06) + Vector3.UP * 0.08, facade_basis, _materials["facade_stone"])
			_facade_box(facade, "DoorLintel", Vector3(door_width + 0.22, 0.14, 0.18), door_position + Vector3.UP * (door_height * 0.5 + 0.10), facade_basis, _materials["facade_stone"])
			door_total = 1
	var tags: Dictionary = raw_tags if raw_tags is Dictionary else {}
	facade.set_meta("building_type", String(tags.get("building", "yes")))
	facade.set_meta("edge_count", edge_infos.size())
	facade.set_meta("window_count", window_total)
	facade.set_meta("window_rows", window_rows_total)
	facade.set_meta("door_count", door_total)
	facade.set_meta("edge_ground_y", edge_ground_levels)
	facade.set_meta("edge_face_span_y", edge_spans)
	facade.set_meta("edge_indices", edge_indices)
	facade.set_meta("edge_lengths", edge_lengths)
	facade.set_meta("edge_window_counts", edge_window_counts)
	facade.set_meta("edge_row_counts", edge_row_counts)
	building.set_meta("facade_edge_count", edge_infos.size())
	building.set_meta("facade_window_count", window_total)
	building.set_meta("facade_window_rows", window_rows_total)
	building.set_meta("facade_door_count", door_total)
	building.set_meta("facade_edge_ground_y", edge_ground_levels)
	building.set_meta("facade_edge_face_span_y", edge_spans)
	building.set_meta("facade_edge_indices", edge_indices)
	building.set_meta("facade_edge_lengths", edge_lengths)
	building.set_meta("facade_edge_window_counts", edge_window_counts)
	building.set_meta("facade_edge_row_counts", edge_row_counts)
	building.set_meta("facade_assets", ["painted_plaster_wall", "brown_planks_09", "stacked_stone_wall", "clay_roof_tiles_02"])

func _facade_box(parent: Node3D, node_name: String, size: Vector3, position: Vector3, basis: Basis, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	instance.basis = basis
	parent.add_child(instance)
	return instance

func _bottom_sample_vectors(points: Array[Vector3]) -> PackedVector3Array:
	var out := PackedVector3Array()
	for point in points:
		out.append(point + Vector3.DOWN * foundation_sink_m)
	return out

func _ground_sample_vectors(points: Array[Vector3]) -> PackedVector3Array:
	var out := PackedVector3Array()
	for point in points:
		out.append(point)
	return out

func _make_materials() -> void:
	_materials["wall"] = _texture_mat("painted_plaster_wall", Color(0.90, 0.84, 0.70), 0.88)
	_materials["wall_retail"] = _texture_mat("clay_plaster", Color(0.72, 0.74, 0.68), 0.82)
	_materials["wall_apartment"] = _texture_mat("painted_plaster_wall", Color(0.62, 0.65, 0.62), 0.90)
	_materials["wall_chapel"] = _texture_mat("old_stone_wall", Color(0.76, 0.72, 0.63), 0.86)
	_materials["roof"] = _texture_mat("clay_roof_tiles_02", Color(0.24, 0.25, 0.24), 0.92)
	_materials["facade_glass"] = _mat(Color(0.035, 0.11, 0.14, 0.92), 0.24, 0.08)
	_materials["facade_wood"] = _texture_mat("brown_planks_09", Color(0.34, 0.20, 0.12), 0.90)
	_materials["facade_stone"] = _texture_mat("stacked_stone_wall", Color(0.66, 0.63, 0.55), 0.96)

func _mat(color: Color, roughness: float, metallic := 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	return material

func _texture_mat(stem: String, tint: Color, roughness: float) -> StandardMaterial3D:
	var material := _mat(tint, roughness)
	var albedo_path := "res://assets/textures/%s_diff.jpg" % stem
	var normal_path := "res://assets/textures/%s_nor.jpg" % stem
	var roughness_path := "res://assets/textures/%s_rough.jpg" % stem
	if ResourceLoader.exists(albedo_path):
		material.albedo_texture = load(albedo_path)
	if ResourceLoader.exists(normal_path):
		material.normal_enabled = true
		material.normal_texture = load(normal_path)
	if ResourceLoader.exists(roughness_path):
		material.roughness_texture = load(roughness_path)
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * 0.42
	return material

func _wall_material(raw_tags: Variant) -> Material:
	var tags: Dictionary = raw_tags if raw_tags is Dictionary else {}
	var building_type := String(tags.get("building", "yes"))
	if building_type in ["retail", "commercial"]:
		return _materials["wall_retail"]
	if building_type == "apartments":
		return _materials["wall_apartment"]
	if building_type == "chapel":
		return _materials["wall_chapel"]
	return _materials["wall"]
