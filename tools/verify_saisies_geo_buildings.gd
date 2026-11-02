extends SceneTree

## Contract check for the independent OSM building staging module.
## Pass --with-landscape to build the actual 769 grid and ground every
## footprint sample against SaisiesGeoLandscape.sample_mesh_triangle.

const ROUTE_SCRIPT_PATH := "res://scripts/saisies_geo_route.gd"
const ROUTE_FILE := "res://data/saisies_geo_route.json"

var _errors: Array[String] = []
var _with_landscape := false
var _with_authored_fixture := false
var _with_authored_village := false
var _landscape: Node3D

class AuthoredVillageFixture:
	extends Node3D
	var village_ready := true
	var footprints: Array[PackedVector2Array] = []

	func get_authored_building_footprints() -> Array[PackedVector2Array]:
		return footprints

func _initialize() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	_with_landscape = "--with-landscape" in args
	_with_authored_fixture = "--with-authored-village-fixture" in args
	_with_authored_village = "--with-authored-village" in args
	call_deferred("_run")

func _run() -> void:
	var data_path := "res://data/saisies_geo_buildings.json"
	if not FileAccess.file_exists(data_path):
		_fail("geo building data is missing")
		_finish()
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(data_path))
	if not (parsed is Dictionary):
		_fail("geo building data is not a JSON object")
		_finish()
		return
	var payload: Dictionary = parsed
	_verify_data(payload)
	var route_script := load(ROUTE_SCRIPT_PATH) as Script
	var buildings_script := load("res://scripts/saisies_geo_buildings.gd") as Script
	if route_script == null or buildings_script == null:
		_fail("route or geo building script could not be loaded")
		_finish()
		return
	var holder := Node3D.new()
	holder.name = "SaisiesGeoBuildingVerification"
	get_root().add_child(holder)
	var route := route_script.new() as Node3D
	route.name = "Route"
	route.set("geo_route_file", ROUTE_FILE)
	holder.add_child(route)
	await process_frame
	await process_frame
	if not bool(route.call("route_ready")):
		_fail("route did not become ready")
	else:
		if not _route_has_property(route, "geography"):
			_fail("geographic route does not expose route.geography")
		else:
			if _with_landscape:
				await _add_landscape(holder)
				if _landscape == null or not bool(_landscape.get("landscape_ready")) or int(_landscape.get_meta("saisies_geo_landscape_grid_size", 0)) != 769:
					_fail("--with-landscape did not produce a ready 769 grid")
			if _with_authored_village:
				if not _with_landscape:
					_fail("--with-authored-village requires --with-landscape")
				else:
					await _add_authored_village(holder)
			elif _with_authored_fixture:
				var authored := _make_authored_fixture(payload, route)
				authored.name = "VillageS01S02"
				holder.add_child(authored)
				for _attempt in range(60):
					if bool(authored.get("village_ready")):
						break
					await process_frame
				if not bool(authored.get("village_ready")):
					_fail("authored village fixture did not become ready")
			var buildings := buildings_script.new() as Node3D
			buildings.name = "SaisiesGeoBuildings"
			buildings.set("route_path", NodePath("../Route"))
			if _with_authored_village or _with_authored_fixture:
				buildings.set("authored_village_path", NodePath("../VillageS01S02"))
			if _with_landscape:
				buildings.set("landscape_path", NodePath("../Landscape"))
			holder.add_child(buildings)
			for _attempt in range(240):
				if bool(buildings.get("buildings_ready")):
					break
				await process_frame
			if not bool(buildings.get("buildings_ready")):
				_fail("geo building module did not build against route.geography")
			else:
				_verify_runtime(buildings, payload, route)
		holder.queue_free()
	_finish()

func _add_landscape(holder: Node3D) -> void:
	var landscape_script := load("res://scripts/saisies_geo_landscape.gd") as Script
	if landscape_script == null:
		_fail("could not load geographic landscape script")
		return
	_landscape = landscape_script.new() as Node3D
	_landscape.name = "Landscape"
	_landscape.set("route_path", NodePath("../Route"))
	_landscape.set("build_grid_size", 769)
	holder.add_child(_landscape)
	for _attempt in range(240):
		if bool(_landscape.get("landscape_ready")):
			return
		await process_frame

func _add_authored_village(holder: Node3D) -> void:
	var village_script := load("res://scripts/saisies_geo_village.gd") as Script
	if village_script == null:
		_fail("could not load geographic authored village script")
		return
	var village := village_script.new() as Node3D
	village.name = "VillageS01S02"
	village.set("route_path", NodePath("../Route"))
	village.set("landscape_path", NodePath("../Landscape"))
	holder.add_child(village)
	for _attempt in range(240):
		if bool(village.get("village_ready")):
			return
		await process_frame
	_fail("authored geographic village did not become ready before buildings")

func _make_authored_fixture(payload: Dictionary, route: Node3D) -> Node3D:
	var fixture := AuthoredVillageFixture.new() as Node3D
	var buildings: Array = payload.get("buildings", [])
	if buildings.is_empty():
		return fixture
	var feature: Dictionary = buildings[0]
	var rings: Array = feature.get("rings", [])
	for ring_item in rings:
		if not (ring_item is Dictionary) or String(ring_item.get("role", "outer")) != "outer":
			continue
		var polygon := PackedVector2Array()
		for coordinate_item in ring_item.get("coordinates", []):
			if coordinate_item is Array and coordinate_item.size() >= 2:
				var world = route.get("geography").call("world_from_latlon", float(coordinate_item[1]), float(coordinate_item[0]))
				if world is Vector3:
					polygon.append(Vector2(world.x, world.z))
				elif world is Vector2:
					polygon.append(world)
		if polygon.size() >= 3:
			fixture.footprints.append(polygon)
			break
	return fixture

func _verify_data(payload: Dictionary) -> void:
	var source: Dictionary = payload.get("source", {})
	if String(source.get("license", "")) != "ODbL 1.0":
		_fail("OSM source license metadata is missing")
	var selection: Dictionary = payload.get("selection", {})
	var selected_count := int(selection.get("selected_buildings", -1))
	var buildings: Array = payload.get("buildings", [])
	if selected_count != buildings.size():
		_fail("selected_buildings metadata does not match feature count")
	if buildings.is_empty():
		_fail("geo building data contains no selected footprints")
	var multipolygon: Dictionary = payload.get("multipolygon_support", {})
	if not String(multipolygon.get("parser_support", "")).contains("outer/inner"):
		_fail("multipolygon parser support is not documented")
	var seen_ids := {}
	for item in buildings:
		if not (item is Dictionary):
			_fail("building feature is not an object")
			continue
		var feature: Dictionary = item
		var feature_id := String(feature.get("id", ""))
		if feature_id.is_empty() or seen_ids.has(feature_id):
			_fail("building feature id is missing or duplicated: %s" % feature_id)
		seen_ids[feature_id] = true
		var distance := float(feature.get("distance_from_origin_m", INF))
		if not is_finite(distance) or distance > 1000.0:
			_fail("building lies outside 1km geographic filter: %s (%.1f m)" % [feature_id, distance])
		var area := float(feature.get("area_m2", 0.0))
		if not is_finite(area) or area < 12.0:
			_fail("building footprint is degenerate/tiny: %s" % feature_id)
		if String(feature.get("height_source", "")).is_empty() or float(feature.get("height_m", 0.0)) <= 0.0:
			_fail("building height provenance is missing: %s" % feature_id)
		var tags: Dictionary = feature.get("tags", {})
		if not tags.has("building"):
			_fail("building OSM tags are missing building key: %s" % feature_id)
		var rings: Array = feature.get("rings", [])
		var outer_count := 0
		for ring_item in rings:
			if not (ring_item is Dictionary):
				_fail("building ring is not an object: %s" % feature_id)
				continue
			var ring: Dictionary = ring_item
			var coords: Array = ring.get("coordinates", [])
			var node_ids: Array = ring.get("node_ids", [])
			if coords.size() < 4 or node_ids.size() != coords.size() or coords[0] != coords[coords.size() - 1]:
				_fail("building ring is not closed or lacks node ids: %s" % feature_id)
			for coordinate_item in coords:
				if not (coordinate_item is Array) or coordinate_item.size() < 2 or not is_finite(float(coordinate_item[0])) or not is_finite(float(coordinate_item[1])):
					_fail("building ring has non-finite coordinate: %s" % feature_id)
			if String(ring.get("role", "outer")) == "outer":
				outer_count += 1
		if outer_count != 1:
			_fail("building does not have exactly one outer ring: %s" % feature_id)
	print("saisies geo building data: selected=%d source=OSM outer/inner parser documented" % buildings.size())

func _verify_runtime(buildings: Node3D, payload: Dictionary, route: Node3D) -> void:
	var ground_source := String(buildings.get_meta("saisies_geo_buildings_ground_source", ""))
	if _with_landscape and ground_source != "landscape.sample_mesh_triangle":
		_fail("building runtime did not use landscape mesh grounding: %s" % ground_source)
	if not _with_landscape and ground_source != "route.geography.height_world":
		_fail("building runtime ground source is not explicit: %s" % ground_source)
	var expected_suppressed_ids: Array[String] = []
	var expected_retained_ids: Array[String] = []
	var authored_records: Array = buildings.get_meta("saisies_geo_buildings_authored_village_suppressions", [])
	for record_item in authored_records:
		if record_item is Dictionary:
			expected_suppressed_ids.append(str(record_item.get("id", record_item.get("osm_id", ""))))
	var all_features: Array = payload.get("buildings", [])
	for feature_item in all_features:
		if feature_item is Dictionary and not expected_suppressed_ids.has(str(feature_item.get("id", ""))):
			expected_retained_ids.append(str(feature_item.get("id", "")))
	var expected := mini(expected_retained_ids.size(), int(buildings.get("max_buildings")))
	var group := buildings.get_node_or_null("SaisiesGeoBuildingFootprints") as Node3D
	if group == null:
		_fail("runtime geo building group is missing")
		return
	var geography = route.get("geography")
	if geography == null or not geography.has_method("height_world"):
		_fail("runtime route geography does not provide height_world")
		return
	if group.get_child_count() != expected:
		_fail("runtime building count %d differs from expected %d" % [group.get_child_count(), expected])
	if int(buildings.get_meta("saisies_geo_buildings_authored_village_suppressed_count", 0)) != expected_suppressed_ids.size():
		_fail("authored village suppression count is not reported from positive intersections")
	if _with_authored_fixture and expected_suppressed_ids.is_empty():
		_fail("fixture did not produce a positive-area authored village suppression")
	if _with_authored_village:
		if int(buildings.get_meta("saisies_geo_buildings_authored_village_footprint_count", 0)) == 0:
			_fail("actual authored village did not publish WORLD XZ footprint polygons")
		if expected_suppressed_ids.is_empty():
			_fail("actual authored village produced no positive-area OSM footprint intersection")
	for record_item in authored_records:
		if record_item is Dictionary:
			var overlap_areas: Array = record_item.get("positive_intersection_areas_m2", [])
			if overlap_areas.is_empty():
				_fail("authored suppression record lacks its positive intersection area")
			for overlap_area in overlap_areas:
				if float(overlap_area) <= 0.001:
					_fail("authored suppression was recorded without a positive-area intersection")
	if not authored_records.is_empty():
		print("saisies geo authored suppression: count=%d records=%s" % [authored_records.size(), authored_records])
	var checked := 0
	var wall_bad_normal_total := 0
	var roof_bad_normal_total := 0
	var retained_ids := {}
	for child in group.get_children():
		var building := child as Node3D
		var feature_id := str(building.get_meta("osm_feature_id", ""))
		retained_ids[feature_id] = true
		if expected_suppressed_ids.has(feature_id):
			_fail("suppressed OSM feature was retained: %s" % feature_id)
		var wall := building.get_node_or_null("FoundationWall") as MeshInstance3D
		var roof := building.get_node_or_null("SimplePitchedRoof") as MeshInstance3D
		if wall == null or roof == null or wall.mesh == null or roof.mesh == null:
			_fail("runtime building lacks wall/roof mesh: %s" % building.name)
			continue
		var facade := building.get_node_or_null("AlpineFacade") as Node3D
		if facade == null or facade.get_child_count() < 2 or int(building.get_meta("facade_window_count", 0)) < 1 or int(building.get_meta("facade_door_count", 0)) != 1:
			_fail("runtime building lacks a readable alpine facade feature row: %s" % building.name)
		var facade_edge_count := int(building.get_meta("facade_edge_count", 0))
		var facade_edge_ground_y: PackedFloat32Array = building.get_meta("facade_edge_ground_y", PackedFloat32Array())
		var facade_edge_spans: PackedFloat32Array = building.get_meta("facade_edge_face_span_y", PackedFloat32Array())
		var facade_edge_indices: PackedInt32Array = building.get_meta("facade_edge_indices", PackedInt32Array())
		var facade_edge_lengths: PackedFloat32Array = building.get_meta("facade_edge_lengths", PackedFloat32Array())
		var facade_edge_window_counts: PackedInt32Array = building.get_meta("facade_edge_window_counts", PackedInt32Array())
		var facade_edge_row_counts: PackedInt32Array = building.get_meta("facade_edge_row_counts", PackedInt32Array())
		if facade_edge_count < 1 or facade_edge_ground_y.size() != facade_edge_count or facade_edge_spans.size() != facade_edge_count or facade_edge_indices.size() != facade_edge_count or facade_edge_lengths.size() != facade_edge_count or facade_edge_window_counts.size() != facade_edge_count or facade_edge_row_counts.size() != facade_edge_count:
			_fail("runtime building lacks per-edge alpine facade ground spans: %s" % building.name)
		else:
			var windows_by_edge := {}
			for facade_child in facade.get_children():
				var child_name := String(facade_child.name)
				if not child_name.begins_with("Window_E"):
					continue
				var row_marker := child_name.find("_R")
				if row_marker < 0:
					continue
				var edge_key := child_name.substr(0, row_marker)
				windows_by_edge[edge_key] = int(windows_by_edge.get(edge_key, 0)) + 1
			for edge_index in facade_edge_count:
				var edge_span := facade_edge_spans[edge_index]
				var edge_length := facade_edge_lengths[edge_index]
				var row_count := int(facade_edge_row_counts[edge_index])
				var windows_per_row := int(facade_edge_window_counts[edge_index])
				var expected_edge_key := "Window_E%02d" % int(facade_edge_indices[edge_index])
				var actual_window_count := int(windows_by_edge.get(expected_edge_key, 0))
				var eligible := edge_length >= 2.5 and edge_span >= 1.8
				if not is_finite(facade_edge_ground_y[edge_index]) or not is_finite(edge_span) or edge_span < -0.01 or not is_finite(edge_length) or edge_length < 0.0:
					_fail("runtime facade edge span is invalid: %s edge=%d" % [building.name, edge_index])
				elif eligible:
					if row_count < 1 or row_count > 4 or windows_per_row < 1 or windows_per_row > 5:
						_fail("runtime eligible facade edge plan is outside bounded rows/windows: %s edge=%d rows=%d windows=%d" % [building.name, int(facade_edge_indices[edge_index]), row_count, windows_per_row])
					if actual_window_count < 1:
						_fail("runtime eligible facade edge has no window: %s edge=%d" % [building.name, int(facade_edge_indices[edge_index])])
					elif actual_window_count != row_count * windows_per_row:
						_fail("runtime facade edge window grouping disagrees with plan: %s edge=%d actual=%d expected=%d" % [building.name, int(facade_edge_indices[edge_index]), actual_window_count, row_count * windows_per_row])
				elif row_count != 0 or windows_per_row != 0 or actual_window_count != 0:
					_fail("runtime ineligible facade edge received windows: %s edge=%d actual=%d" % [building.name, int(facade_edge_indices[edge_index]), actual_window_count])
		var wall_material := wall.material_override as StandardMaterial3D
		var roof_material := roof.material_override as StandardMaterial3D
		if wall_material == null or wall_material.albedo_texture == null or roof_material == null or roof_material.albedo_texture == null:
			_fail("runtime building facade/roof did not reuse textured alpine materials: %s" % building.name)
		var wall_bad_normals := int(building.get_meta("wall_bad_normal_count", -1))
		var roof_bad_normals := int(building.get_meta("roof_bad_normal_count", -1))
		if wall_bad_normals < 0 or roof_bad_normals < 0:
			_fail("runtime building does not report wall/roof normal checks: %s" % building.name)
		elif wall_bad_normals > 0 or roof_bad_normals > 0:
			_fail("runtime building has backfacing wall/roof triangles: %s wall=%d roof=%d" % [building.name, wall_bad_normals, roof_bad_normals])
		wall_bad_normal_total += maxi(wall_bad_normals, 0)
		roof_bad_normal_total += maxi(roof_bad_normals, 0)
		_verify_source_footprint_coordinates(building, payload, route)
		var bottom_samples: PackedVector3Array = building.get_meta("foundation_bottom_vertices", PackedVector3Array())
		var ground_samples: PackedVector3Array = building.get_meta("foundation_ground_vertices", PackedVector3Array())
		if bottom_samples.size() == 0 or bottom_samples.size() != ground_samples.size():
			_fail("runtime foundation samples are missing: %s" % building.name)
			continue
		var height_m := float(building.get_meta("height_m", NAN))
		var eave_y := float(building.get_meta("foundation_eave_y", NAN))
		var ridge_y := float(building.get_meta("roof_ridge_y", NAN))
		var gable_caps := int(building.get_meta("roof_gable_caps", 0))
		if not is_finite(height_m) or not is_finite(eave_y) or not is_finite(ridge_y):
			_fail("runtime roof/eave metadata is non-finite: %s" % building.name)
		var highest_ground := -INF
		for index in bottom_samples.size():
			var bottom := building.global_transform * bottom_samples[index]
			var ground := building.global_transform * ground_samples[index]
			var sampled_ground := _ground_height(Vector2(ground.x, ground.z), geography)
			highest_ground = maxf(highest_ground, ground.y)
			if not is_finite(bottom.y) or not is_finite(ground.y) or not is_finite(sampled_ground):
				_fail("runtime foundation sample is non-finite: %s" % building.name)
			elif absf(ground.y - sampled_ground) > 0.05:
				_fail("runtime foundation ground sample disagrees with geography: %s sample=%.3f geo=%.3f" % [building.name, ground.y, sampled_ground])
			elif bottom.y > sampled_ground + 0.03 or sampled_ground - bottom.y > 0.25:
				_fail("runtime foundation contact is invalid: %s bottom=%.3f ground=%.3f" % [building.name, bottom.y, ground.y])
		var expected_eave := highest_ground + height_m
		if absf(eave_y - expected_eave) > 0.03:
			_fail("runtime eave is not levelled from highest footprint ground: %s eave=%.3f expected=%.3f" % [building.name, eave_y, expected_eave])
		if absf(ridge_y - eave_y - float(building.get_meta("roof_rise_m", ridge_y - eave_y))) > 0.03:
			_fail("runtime roof ridge is not above the common eave: %s" % building.name)
		if gable_caps != 2 or not bool(building.get_meta("roof_closed", false)):
			_fail("runtime roof gable caps are incomplete: %s caps=%d" % [building.name, gable_caps])
		if facade != null:
			_verify_facade_height_spans(building, facade, eave_y)
		_verify_array_normals(building, wall, roof, building.get_meta("roof_gable_cap_face_offsets", []), building.get_meta("roof_gable_cap_outward", []))
		_verify_mesh_levels(building, wall, roof, eave_y, ridge_y)
		checked += 1
	var retained_outside_count := 0
	for id_value in expected_retained_ids:
		if retained_ids.has(id_value):
			retained_outside_count += 1
		else:
			_fail("outside authored footprint feature was removed: %s" % id_value)
	if retained_outside_count != group.get_child_count():
		_fail("outside authored footprints were not retained: %d/%d" % [retained_outside_count, group.get_child_count()])
	if checked > 0:
		print("saisies geo building runtime: checked=%d foundation footprints, inner_rings=%d ground=%s landscape=%s wall_bad_normals=%d roof_bad_normals=%d" % [checked, int(buildings.get_meta("saisies_geo_buildings_inner_rings_preserved", 0)), ground_source, _with_landscape, wall_bad_normal_total, roof_bad_normal_total])

func _verify_source_footprint_coordinates(building: Node3D, payload: Dictionary, route: Node3D) -> void:
	var feature_id := str(building.get_meta("osm_feature_id", ""))
	var source_feature: Dictionary = {}
	for item in payload.get("buildings", []):
		if item is Dictionary and str(item.get("id", "")) == feature_id:
			source_feature = item
			break
	if source_feature.is_empty():
		_fail("runtime building has no matching source feature: %s" % feature_id)
		return
	var source_points := PackedVector2Array()
	for ring_item in source_feature.get("rings", []):
		if not (ring_item is Dictionary) or str(ring_item.get("role", "outer")) != "outer":
			continue
		for coordinate_item in ring_item.get("coordinates", []):
			if coordinate_item is Array and coordinate_item.size() >= 2:
				var world = route.get("geography").call("world_from_latlon", float(coordinate_item[1]), float(coordinate_item[0]))
				if world is Vector3:
					source_points.append(Vector2(world.x, world.z))
				elif world is Vector2:
					source_points.append(world)
		break
	var runtime_points: PackedVector2Array = building.get_meta("footprint_world_xz", PackedVector2Array())
	var normalized_points: PackedVector2Array = building.get_meta("footprint_world_xz_normalized", PackedVector2Array())
	if source_points.size() > 1 and source_points[0].distance_to(source_points[source_points.size() - 1]) < 0.02:
		source_points.remove_at(source_points.size() - 1)
	if runtime_points.size() != source_points.size():
		_fail("runtime footprint coordinate count changed for %s: %d/%d" % [feature_id, runtime_points.size(), source_points.size()])
		return
	for index in source_points.size():
		if runtime_points[index].distance_to(source_points[index]) > 0.01:
			_fail("runtime footprint coordinate changed for %s[%d]" % [feature_id, index])
	if normalized_points.size() != source_points.size() or _polygon_area(normalized_points) > -0.001:
		_fail("runtime normalized footprint is not clockwise in world XZ: %s" % feature_id)
	else:
		for source_point in source_points:
			var found := false
			for normalized_point in normalized_points:
				if source_point.distance_to(normalized_point) <= 0.01:
					found = true
					break
			if not found:
				_fail("runtime normalized footprint changed a coordinate for %s" % feature_id)

func _polygon_area(polygon: PackedVector2Array) -> float:
	if polygon.size() < 3:
		return 0.0
	var area := 0.0
	for index in polygon.size():
		var current := polygon[index]
		var next := polygon[(index + 1) % polygon.size()]
		area += current.x * next.y - next.x * current.y
	return area * 0.5

func _ground_height(xz: Vector2, geography: Object) -> float:
	if _with_landscape and _landscape != null and _landscape.has_method("sample_mesh_triangle"):
		var sampled = _landscape.call("sample_mesh_triangle", xz)
		if sampled is Dictionary and sampled.has("height"):
			return float(sampled["height"])
		return NAN
	return float(geography.call("height_world", xz))

func _verify_mesh_levels(building: Node3D, wall: MeshInstance3D, roof: MeshInstance3D, eave_y: float, ridge_y: float) -> void:
	var wall_faces: PackedVector3Array = wall.mesh.get_faces()
	var roof_faces: PackedVector3Array = roof.mesh.get_faces()
	if wall_faces.is_empty() or wall_faces.size() % 3 != 0:
		_fail("runtime wall mesh has no complete triangles: %s" % building.name)
	if roof_faces.is_empty() or roof_faces.size() % 3 != 0:
		_fail("runtime roof mesh has no complete triangles: %s" % building.name)
	var max_wall_y := -INF
	for vertex in wall_faces:
		if not _finite_vec3(vertex):
			_fail("runtime wall mesh has non-finite vertex: %s" % building.name)
		max_wall_y = maxf(max_wall_y, vertex.y)
	if absf(max_wall_y - eave_y) > 0.03:
		_fail("runtime wall top is not at common eave: %s top=%.3f eave=%.3f" % [building.name, max_wall_y, eave_y])
	for vertex in roof_faces:
		if not _finite_vec3(vertex):
			_fail("runtime roof mesh has non-finite vertex: %s" % building.name)
		if absf(vertex.y - eave_y) > 0.03 and absf(vertex.y - ridge_y) > 0.03:
			_fail("runtime roof vertex is off eave/ridge levels: %s y=%.3f" % [building.name, vertex.y])

func _verify_facade_height_spans(building: Node3D, facade: Node3D, eave_y: float) -> void:
	for child in facade.get_children():
		if not child.has_meta("facade_face_ground_y"):
			continue
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var box := mesh_instance.mesh as BoxMesh
		if box == null:
			continue
		var local_position := building.to_local(child.global_position)
		var bottom_y := local_position.y - box.size.y * 0.5
		var top_y := local_position.y + box.size.y * 0.5
		var face_ground_y := float(child.get_meta("facade_face_ground_y", NAN))
		if not is_finite(face_ground_y) or bottom_y < face_ground_y - 0.03:
			_fail("runtime facade feature is below its sampled face ground: %s child=%s" % [building.name, child.name])
		elif String(child.name).begins_with("Window_") and top_y > eave_y + 0.03:
			_fail("runtime facade window rises above common eave: %s child=%s" % [building.name, child.name])

func _verify_array_normals(building: Node3D, wall: MeshInstance3D, roof: MeshInstance3D, roof_cap_face_offsets: Array, roof_cap_outward: Array) -> void:
	for mesh_item in [{"label": "wall", "mesh": wall.mesh}, {"label": "roof", "mesh": roof.mesh}]:
		var label: String = mesh_item["label"]
		var mesh: ArrayMesh = mesh_item["mesh"]
		var arrays: Array = mesh.surface_get_arrays(0)
		if arrays.size() <= Mesh.ARRAY_NORMAL or arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_NORMAL] == null:
			_fail("runtime %s mesh lacks ARRAY_VERTEX/ARRAY_NORMAL streams: %s" % [label, building.name])
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices := PackedInt32Array()
		if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
			indices = arrays[Mesh.ARRAY_INDEX]
		var element_count := indices.size() if not indices.is_empty() else vertices.size()
		if vertices.size() != normals.size() or element_count % 3 != 0:
			_fail("runtime %s mesh streams are not complete: %s" % [label, building.name])
			continue
		for face_offset in range(0, element_count, 3):
			var a_index := indices[face_offset] if not indices.is_empty() else face_offset
			var b_index := indices[face_offset + 1] if not indices.is_empty() else face_offset + 1
			var c_index := indices[face_offset + 2] if not indices.is_empty() else face_offset + 2
			var a := vertices[a_index]
			var b := vertices[b_index]
			var c := vertices[c_index]
			var godot_normal := (c - a).cross(b - a)
			if godot_normal.length_squared() < 0.000001:
				continue
			godot_normal = godot_normal.normalized()
			var mesh_normal := normals[a_index]
			var cap_index := roof_cap_face_offsets.find(face_offset) if label == "roof" else -1
			if cap_index >= 0:
				if cap_index >= roof_cap_outward.size():
					_fail("runtime roof gable cap is not outward: %s face=%d" % [building.name, face_offset / 3])
					continue
				var expected_cap_outward := (roof_cap_outward[cap_index] as Vector3).normalized()
				if godot_normal.dot(expected_cap_outward) <= 0.0:
					_fail("runtime roof gable cap geometry is not outward: %s face=%d" % [building.name, face_offset / 3])
				elif mesh_normal.length_squared() < 0.000001 or mesh_normal.normalized().dot(godot_normal) < 0.99:
					_fail("runtime roof gable cap ARRAY_NORMAL disagrees with its face: %s face=%d" % [building.name, face_offset / 3])
				continue
			if mesh_normal.length_squared() < 0.000001 or mesh_normal.normalized().dot(godot_normal) < 0.99:
				if mesh_normal.length_squared() < 0.000001:
					_fail("runtime %s ARRAY_NORMAL is empty: %s face=%d" % [label, building.name, face_offset / 3])
				else:
					_fail("runtime %s ARRAY_NORMAL disagrees with its face: %s face=%d" % [label, building.name, face_offset / 3])
			elif label == "wall":
				var edge := c - a
				edge.y = 0.0
				var expected_outward := edge.normalized().cross(Vector3.UP) if edge.length_squared() > 0.000001 else Vector3.ZERO
				if expected_outward.length_squared() > 0.0 and mesh_normal.normalized().dot(expected_outward) < 0.99:
					_fail("runtime wall ARRAY_NORMAL is not outward: %s face=%d" % [building.name, face_offset / 3])
			elif label == "roof" and mesh_normal.normalized().y < -0.001:
				_fail("runtime roof ARRAY_NORMAL is not upward: %s face=%d" % [building.name, face_offset / 3])

func _finite_vec3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _route_has_property(route: Node3D, property_name: String) -> bool:
	for property in route.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES GEO BUILDINGS VERIFY: " + message)

func _finish() -> void:
	if not _errors.is_empty():
		print("SAISIES GEO BUILDINGS VERIFY FAIL (%d errors)" % _errors.size())
		quit(1)
	else:
		print("SAISIES GEO BUILDINGS VERIFY PASS")
		quit(0)
