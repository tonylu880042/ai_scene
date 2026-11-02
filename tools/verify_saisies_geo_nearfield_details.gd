extends SceneTree

const RouteScript = preload("res://scripts/saisies_geo_route.gd")
const LandscapeScript = preload("res://scripts/saisies_geo_landscape.gd")
const DetailsScript = preload("res://scripts/saisies_geo_nearfield_details.gd")
const GEO_SCENE := "res://scenes/MainScene_saisies_geo.tscn"
const MAX_TRIANGLES := 12000
const S09_MAX_TRIANGLES := 10000
const EXPECTED_TERRAIN_VERTICES := 750058
const EXPECTED_TERRAIN_TRIANGLES := 1491246
const EXPECTED_S13_VERTICES := 9396
const EXPECTED_S13_TRIANGLES := 3132
const EXPECTED_S09_WALL_VERTICES := 5994
const EXPECTED_S09_WALL_TRIANGLES := 1998
const EXPECTED_S09_BANK_VERTICES := 444
const EXPECTED_S09_BANK_TRIANGLES := 660
const S09_MIN_HEIGHT_M := 0.75
const S09_MAX_HEIGHT_M := 1.85
const S09_REFERENCE_STATION_M := 5431.282674
const S09_CONTACT_SHALLOW_LIMIT_M := -0.02
const S09_CONTACT_DEEP_LIMIT_M := -0.50
const S09_END_TAPER_M := 12.0
const MIN_HEIGHT_M := 5.0
const MAX_HEIGHT_M := 10.0
const CONTACT_SHALLOW_LIMIT_M := -0.03
const CONTACT_DEEP_LIMIT_M := -0.50
const EPS := 0.000001

var _errors: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_verify_scene_contract()
	var route := RouteScript.new()
	root.add_child(route)
	if not await _wait_for_route(route):
		_fail("geo route did not become ready")
	else:
		var landscape := LandscapeScript.new()
		landscape.route = route
		landscape.build_grid_size = 769
		landscape.max_vertices = 700000
		landscape.route_sample_step_m = 20.0
		root.add_child(landscape)
		if not await _wait_for_landscape(landscape):
			_fail("geo landscape did not become ready")
		else:
			_verify_terrain_material(landscape, route)
			var details := DetailsScript.new()
			details.route = route
			details.landscape = landscape
			details.sample_spacing_m = 0.5
			root.add_child(details)
			if not await _wait_for_details(details):
				_fail("S13 nearfield details did not become ready")
			else:
				_verify_details(route, landscape, details)
			landscape.queue_free()
		route.queue_free()
	if _errors.is_empty():
		print("SAISIES GEO NEARFIELD DETAILS VERIFY PASS")
		quit(0)
	else:
		print("SAISIES GEO NEARFIELD DETAILS VERIFY FAIL (%d errors)" % _errors.size())
		quit(1)

func _wait_for_route(route) -> bool:
	for _i in range(180):
		if route.has_method("route_ready") and bool(route.call("route_ready")):
			return true
		await process_frame
	return false

func _wait_for_landscape(landscape) -> bool:
	for _i in range(240):
		if bool(landscape.get("landscape_ready")):
			return true
		await process_frame
	return false

func _wait_for_details(details) -> bool:
	for _i in range(180):
		if bool(details.get("details_ready")):
			return true
		await process_frame
	return false

func _verify_scene_contract() -> void:
	# Read only the scene contract here.  Instantiating the full staging scene
	# would eagerly parse unrelated forest/building scripts and turn this focused
	# rock-wall audit into a concurrent-scene integration test.
	if not FileAccess.file_exists(GEO_SCENE):
		_fail("geo scene file is missing")
		return
	var source := FileAccess.get_file_as_string(GEO_SCENE)
	var required_fragments := [
		"path=\"res://scripts/saisies_geo_nearfield_details.gd\"",
		"path=\"res://scripts/saisies_geo_camera.gd\"",
		"[node name=\"NearfieldDetails\" type=\"Node3D\" parent=\".\"]",
		"script = ExtResource(\"10_nearfield_details\")",
		"route_path = NodePath(\"../Route\")",
		"landscape_path = NodePath(\"../Landscape\")",
		"[node name=\"CameraRig\" type=\"Node3D\" parent=\".\"]",
		"script = ExtResource(\"2_camera\")"
	]
	for fragment in required_fragments:
		if not source.contains(fragment):
			_fail("geo scene contract is missing: %s" % fragment)

func _verify_details(route, landscape, details) -> void:
	var window: Vector2 = details.route_window()
	var length_m := float(route.get("length_m"))
	if not _finite_vector2(window) or window.x <= 0.0 or window.y <= window.x:
		_fail("invalid S13 route window: %s" % window)
	if window.x < 0.0 or window.y > length_m:
		_fail("S13 route window leaves route: %s length=%.2f" % [window, length_m])
	var source_s := float(route.call("distance_for_video_seconds", 630.0))
	if source_s < window.x or source_s > window.y:
		_fail("S13 630s station %.2f is outside details window %s" % [source_s, window])
	if window.y - window.x < 30.0 or window.y - window.x > 160.0:
		_fail("S13 interval has implausible geometry span %.2fm" % (window.y - window.x))
	var back_top_u: Vector2 = details.get_meta("saisies_geo_nearfield_details_back_top_u_range", Vector2(NAN, NAN))
	var back_top_ground: Vector2 = details.get_meta("saisies_geo_nearfield_details_back_top_ground_range", Vector2(NAN, NAN))
	if not _finite_vector2(back_top_u) or not _finite_vector2(back_top_ground):
		_fail("uphill back/top diagnostics are non-finite")
	elif back_top_u.x < 10.0:
		_fail("uphill back/top search stayed in the near-road clearance core: %s" % back_top_u)
	else:
		print("details uphill back_top_u=%.2f..%.2f ground=%.2f..%.2f" % [back_top_u.x, back_top_u.y, back_top_ground.x, back_top_ground.y])

	var vertices: PackedVector3Array = details.mesh_vertices()
	var normals: PackedVector3Array = details.mesh_normals()
	var uvs: PackedVector2Array = details.mesh_uvs()
	var indices: PackedInt32Array = details.mesh_indices()
	if vertices.is_empty() or indices.is_empty():
		_fail("details mesh arrays are empty")
		return
	if indices.size() % 3 != 0:
		_fail("details index count is not divisible by three")
	var triangle_count := indices.size() / 3
	if vertices.size() != EXPECTED_S13_VERTICES or triangle_count != EXPECTED_S13_TRIANGLES:
		_fail("S13 physical mesh changed during material-only task: vertices=%d/%d triangles=%d/%d" % [vertices.size(), EXPECTED_S13_VERTICES, triangle_count, EXPECTED_S13_TRIANGLES])
	if triangle_count > MAX_TRIANGLES:
		_fail("details triangle budget exceeded: %d" % triangle_count)
	if triangle_count < 100:
		_fail("details mesh has too few triangles for a closed layered wall: %d" % triangle_count)
	if normals.size() != vertices.size() or uvs.size() != vertices.size():
		_fail("details attributes do not match vertices: v=%d n=%d uv=%d" % [vertices.size(), normals.size(), uvs.size()])
	for vertex in vertices:
		if not _finite_vector3(vertex):
			_fail("details contains non-finite vertex")
			break
	for uv_value in uvs:
		if not _finite_vector2(uv_value):
			_fail("details contains non-finite UV")
			break
	_verify_winding_and_normals(vertices, normals, indices)
	_verify_closed_edges(vertices, indices)
	_verify_contacts_and_heights(route, landscape, details, vertices, window)
	_verify_road_clearance(route, vertices, window)
	_verify_frontfoot_continuity(landscape, details, vertices)
	_verify_front_relief(route, details, vertices)
	_verify_wall_asphalt_footprint(route, vertices, indices)
	_verify_material(details)
	print("S13 details: window=%.2f..%.2f span=%.2fm vertices=%d triangles=%d" % [window.x, window.y, window.y - window.x, vertices.size(), triangle_count])
	_verify_s09(route, landscape, details)

func _verify_terrain_material(landscape, route) -> void:
	var terrain_node := landscape.get_node_or_null("SaisiesGeoTerrain") as MeshInstance3D
	if terrain_node == null or terrain_node.mesh == null:
		_fail("SaisiesGeoTerrain material target is missing")
		return
	var material := terrain_node.material_override as ShaderMaterial
	if material == null or material.shader == null:
		_fail("SaisiesGeoTerrain does not use the bounded ShaderMaterial")
		return
	var terrain_arrays := terrain_node.mesh.surface_get_arrays(0)
	var terrain_vertices: PackedVector3Array = terrain_arrays[Mesh.ARRAY_VERTEX]
	var terrain_normals: PackedVector3Array = terrain_arrays[Mesh.ARRAY_NORMAL]
	var terrain_tangents: PackedFloat32Array = terrain_arrays[Mesh.ARRAY_TANGENT]
	var terrain_indices: PackedInt32Array = terrain_arrays[Mesh.ARRAY_INDEX]
	if terrain_vertices.size() != EXPECTED_TERRAIN_VERTICES or terrain_indices.size() / 3 != EXPECTED_TERRAIN_TRIANGLES:
		_fail("terrain geometry changed during material-only task: vertices=%d/%d triangles=%d/%d" % [terrain_vertices.size(), EXPECTED_TERRAIN_VERTICES, terrain_indices.size() / 3, EXPECTED_TERRAIN_TRIANGLES])
	_verify_tangent_array("geo terrain", terrain_vertices, terrain_normals, terrain_tangents)
	var shader_path := String(material.shader.resource_path)
	if shader_path != "res://shaders/saisies_geo_terrain_detail.gdshader":
		_fail("SaisiesGeoTerrain shader is not bounded S09 detail shader: %s" % shader_path)
	var detail_enabled := bool(material.get_shader_parameter("detail_enabled"))
	if not detail_enabled:
		_fail("SaisiesGeoTerrain local S09 detail mask is disabled")
	if bool(material.get_shader_parameter("detail_force")):
		_fail("SaisiesGeoTerrain detail_force must remain false for the bounded world mask")
	var detail_albedo = material.get_shader_parameter("detail_albedo_tex")
	var detail_normal = material.get_shader_parameter("detail_normal_tex")
	if detail_albedo == null or detail_normal == null:
		_fail("SaisiesGeoTerrain S09 detail textures are not bound")
	var centre: Variant = material.get_shader_parameter("detail_center_xz")
	var forward: Variant = material.get_shader_parameter("detail_forward_xz")
	var left: Variant = material.get_shader_parameter("detail_left_xz")
	if not (centre is Vector2) or not _finite_vector2(centre):
		_fail("SaisiesGeoTerrain detail center is non-finite: %s" % centre)
	if not (forward is Vector2) or not _finite_vector2(forward) or forward.length_squared() < 0.90 or forward.length_squared() > 1.10:
		_fail("SaisiesGeoTerrain detail forward axis is invalid: %s" % forward)
	if not (left is Vector2) or not _finite_vector2(left) or left.length_squared() < 0.90 or left.length_squared() > 1.10:
		_fail("SaisiesGeoTerrain detail left axis is invalid: %s" % left)
	var side_start := float(material.get_shader_parameter("detail_side_start_m"))
	var side_full := float(material.get_shader_parameter("detail_side_full_m"))
	var side_end := float(material.get_shader_parameter("detail_side_end_m"))
	var side_fade := float(material.get_shader_parameter("detail_side_fade_m"))
	var along_full := float(material.get_shader_parameter("detail_along_full_m"))
	var along_edge := float(material.get_shader_parameter("detail_along_edge_m"))
	var uv_scale := float(material.get_shader_parameter("detail_uv_scale"))
	if not is_finite(side_start) or not is_finite(side_full) or not is_finite(side_end) or not is_finite(side_fade) or not is_finite(along_full) or not is_finite(along_edge) or not is_finite(uv_scale):
		_fail("SaisiesGeoTerrain detail mask has non-finite parameters")
	if side_start < 5.0 or side_full <= side_start or side_end < 90.0 or side_end > 120.0 or side_fade <= 0.0 or side_fade > 32.0:
		_fail("SaisiesGeoTerrain detail side mask is outside local S09 scope: %.2f..%.2f..%.2f fade=%.2f" % [side_start, side_full, side_end, side_fade])
	if along_full < 50.0 or along_edge <= along_full or along_edge > 140.0:
		_fail("SaisiesGeoTerrain detail along mask is outside local S09 scope: %.2f..%.2f" % [along_full, along_edge])
	if uv_scale < 0.15 or uv_scale > 0.35:
		_fail("SaisiesGeoTerrain detail UV scale is outside 0.15..0.35/m: %.3f" % uv_scale)
	var anchor_s := float(landscape.get_meta("saisies_geo_terrain_detail_station_m", NAN))
	var expected_s := float(route.call("distance_for_video_seconds", 330.0))
	if not is_finite(anchor_s) or absf(anchor_s - expected_s) > 0.05:
		_fail("SaisiesGeoTerrain detail anchor drift: %.3f expected %.3f" % [anchor_s, expected_s])
	print("geo terrain material: shader=%s detail_enabled=%s center=%s station=%.3f side=%.1f..%.1f..%.1f+%.1f along=%.1f..%.1f uv=%.3f" % [shader_path, detail_enabled, centre, anchor_s, side_start, side_full, side_end, side_fade, along_full, along_edge, uv_scale])

func _verify_s09(route, landscape, details) -> void:
	if not details.has_method("s09_route_window") or not details.has_method("s09_mesh_vertices"):
		_fail("S09 details API is missing")
		return
	var window: Vector2 = details.s09_route_window()
	var length_m := float(route.get("length_m"))
	var expected_start := float(route.call("distance_for_video_seconds", 328.0))
	var expected_end := float(route.call("distance_for_video_seconds", 336.0))
	var source_station := float(route.call("distance_for_video_seconds", 330.0))
	if not _finite_vector2(window) or window.x < 0.0 or window.y <= window.x or window.y > length_m:
		_fail("invalid S09 route window: %s" % window)
		return
	if absf(window.x - expected_start) > 0.05 or absf(window.y - expected_end) > 0.05:
		_fail("S09 window is not dynamic 328..336s mapping: %s expected %.2f..%.2f" % [window, expected_start, expected_end])
	if source_station < window.x or source_station > window.y:
		_fail("S09 330s station %.2f is outside details window %s" % [source_station, window])
	if absf(source_station - S09_REFERENCE_STATION_M) > 8.0:
		_fail("S09 frozen station drift %.2f vs %.2f" % [source_station, S09_REFERENCE_STATION_M])

	var wall_vertices: PackedVector3Array = details.s09_mesh_vertices()
	var wall_normals: PackedVector3Array = details.s09_mesh_normals()
	var wall_uvs: PackedVector2Array = details.s09_mesh_uvs()
	var wall_indices: PackedInt32Array = details.s09_mesh_indices()
	var bank_vertices: PackedVector3Array = details.s09_bank_vertices()
	var bank_normals: PackedVector3Array = details.s09_bank_normals()
	var bank_tangents: PackedFloat32Array = details.s09_bank_tangents()
	var bank_uvs: PackedVector2Array = details.s09_bank_uvs()
	var bank_indices: PackedInt32Array = details.s09_bank_indices()
	var wall_triangles := wall_indices.size() / 3
	var bank_triangles := bank_indices.size() / 3
	if wall_vertices.is_empty() or wall_indices.is_empty() or bank_vertices.is_empty() or bank_indices.is_empty():
		_fail("S09 wall/bank mesh arrays are empty")
		return
	if wall_triangles + bank_triangles > S09_MAX_TRIANGLES:
		_fail("S09 wall+bank triangle budget exceeded: wall=%d bank=%d" % [wall_triangles, bank_triangles])
	if wall_vertices.size() != EXPECTED_S09_WALL_VERTICES or wall_triangles != EXPECTED_S09_WALL_TRIANGLES:
		_fail("S09 wall physical mesh changed during material-only task: vertices=%d/%d triangles=%d/%d" % [wall_vertices.size(), EXPECTED_S09_WALL_VERTICES, wall_triangles, EXPECTED_S09_WALL_TRIANGLES])
	if bank_vertices.size() != EXPECTED_S09_BANK_VERTICES or bank_triangles != EXPECTED_S09_BANK_TRIANGLES:
		_fail("S09 bank physical mesh changed during material-only task: vertices=%d/%d triangles=%d/%d" % [bank_vertices.size(), EXPECTED_S09_BANK_VERTICES, bank_triangles, EXPECTED_S09_BANK_TRIANGLES])
	_verify_mesh_arrays("S09 wall", wall_vertices, wall_normals, wall_uvs, wall_indices)
	_verify_mesh_arrays("S09 bank", bank_vertices, bank_normals, bank_uvs, bank_indices)
	_verify_tangent_array("S09 bank", bank_vertices, bank_normals, bank_tangents)
	_verify_winding_and_normals(wall_vertices, wall_normals, wall_indices)
	_verify_winding_and_normals(bank_vertices, bank_normals, bank_indices)
	_verify_closed_edges(wall_vertices, wall_indices)
	_verify_s09_contacts_and_heights(route, landscape, details, wall_vertices, window)
	_verify_road_clearance(route, wall_vertices, window)
	_verify_frontfoot_continuity(landscape, details, wall_vertices, details.s09_base_contact_records())
	_verify_s09_bank_contacts(route, landscape, details, bank_vertices)
	_verify_wall_asphalt_footprint(route, wall_vertices, wall_indices)
	_verify_wall_asphalt_footprint(route, bank_vertices, bank_indices)
	_verify_s09_front_irregularity(route, details, wall_vertices)
	_verify_s09_material(details)
	print("S09 low stone wall: window=%.2f..%.2f span=%.2fm station330=%.2f wall_vertices=%d wall_triangles=%d bank_vertices=%d bank_triangles=%d" % [window.x, window.y, window.y - window.x, source_station, wall_vertices.size(), wall_triangles, bank_vertices.size(), bank_triangles])

func _verify_mesh_arrays(label: String, vertices: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array) -> void:
	if indices.size() % 3 != 0:
		_fail("%s index count is not divisible by three" % label)
	if normals.size() != vertices.size() or uvs.size() != vertices.size():
		_fail("%s attributes do not match vertices: v=%d n=%d uv=%d" % [label, vertices.size(), normals.size(), uvs.size()])
	for point in vertices:
		if not _finite_vector3(point):
			_fail("%s contains non-finite vertex" % label)
			break
	for normal in normals:
		if not _finite_vector3(normal) or normal.length_squared() < EPS:
			_fail("%s contains invalid normal" % label)
			break
	for uv_value in uvs:
		if not _finite_vector2(uv_value):
			_fail("%s contains non-finite UV" % label)
			break
	for index in indices:
		if int(index) < 0 or int(index) >= vertices.size():
			_fail("%s contains out-of-range index" % label)
			break

func _verify_tangent_array(label: String, vertices: PackedVector3Array, normals: PackedVector3Array, tangents: PackedFloat32Array) -> void:
	if tangents.size() != vertices.size() * 4:
		_fail("%s tangent attribute count is invalid: %d expected %d" % [label, tangents.size(), vertices.size() * 4])
		return
	var bad := 0
	var direction_sample := -1
	var direction_sample_up := -INF
	for i in range(vertices.size()):
		var tangent := Vector3(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2])
		var handedness := tangents[i * 4 + 3]
		var normal := normals[i].normalized()
		if not _finite_vector3(tangent) or not is_finite(handedness) or tangent.length_squared() < 0.80 or tangent.length_squared() > 1.20 or absf(tangent.normalized().dot(normal)) > 0.03 or absf(absf(handedness) - 1.0) > 0.01:
			bad += 1
		# Pick an explicit near-horizontal vertex as a positive direction
		# sample.  The detail shader's UV is world XZ, so +X and +Z must be
		# preserved after projecting them onto this vertex's surface.
		if normal.y > direction_sample_up:
			direction_sample_up = normal.y
			direction_sample = i
	if bad > 0:
		_fail("%s tangent basis is invalid: bad=%d/%d" % [label, bad, vertices.size()])
	if direction_sample < 0:
		_fail("%s tangent basis has no finite direction sample" % label)
	else:
		var sample_normal := normals[direction_sample].normalized()
		var sample_tangent := Vector3(tangents[direction_sample * 4], tangents[direction_sample * 4 + 1], tangents[direction_sample * 4 + 2]).normalized()
		var sample_handedness := tangents[direction_sample * 4 + 3]
		var expected_x := Vector3.RIGHT - sample_normal * sample_normal.dot(Vector3.RIGHT)
		var expected_z := Vector3(0.0, 0.0, 1.0) - sample_normal * sample_normal.dot(Vector3(0.0, 0.0, 1.0))
		var tangent_x_dot := -1.0
		var bitangent_z_dot := -1.0
		if expected_x.length_squared() > 0.25 and expected_z.length_squared() > 0.25:
			tangent_x_dot = sample_tangent.dot(expected_x.normalized())
			var sample_bitangent := sample_normal.cross(sample_tangent) * sample_handedness
			bitangent_z_dot = sample_bitangent.dot(expected_z.normalized())
		if tangent_x_dot < 0.80 or bitangent_z_dot < 0.80:
			_fail("%s tangent direction does not match world detail UV: sample=%d normal=%s +X=%.3f +Z=%.3f" % [label, direction_sample, sample_normal, tangent_x_dot, bitangent_z_dot])
		print("%s tangent basis: attributes=%d vertices=%d invalid=%d direction_sample=%d normal_y=%.3f world_x_dot=%.3f world_z_dot=%.3f" % [label, tangents.size(), vertices.size(), bad, direction_sample, direction_sample_up, tangent_x_dot, bitangent_z_dot])

func _verify_s09_contacts_and_heights(route, landscape, details, vertices: PackedVector3Array, window: Vector2) -> void:
	var contacts: Array = details.s09_base_contact_records()
	if contacts.size() < 4:
		_fail("S09 has too few actual base contact records: %d" % contacts.size())
	var min_s := INF
	var max_s := -INF
	var min_delta := INF
	var max_delta := -INF
	var bad_contacts := 0
	var shallow_bad := 0
	var deep_bad := 0
	for record in contacts:
		var index := int(record.get("vertex_index", -1))
		if index < 0 or index >= vertices.size():
			bad_contacts += 1
			continue
		var point := vertices[index]
		var sample: Dictionary = landscape.sample_mesh_triangle(Vector2(point.x, point.z))
		if sample.is_empty() or not sample.has("height"):
			bad_contacts += 1
			continue
		var delta := point.y - float(sample["height"])
		min_delta = minf(min_delta, delta)
		max_delta = maxf(max_delta, delta)
		if delta > S09_CONTACT_SHALLOW_LIMIT_M:
			bad_contacts += 1
			shallow_bad += 1
		elif delta < S09_CONTACT_DEEP_LIMIT_M:
			bad_contacts += 1
			deep_bad += 1
		min_s = minf(min_s, float(record.get("s", NAN)))
		max_s = maxf(max_s, float(record.get("s", NAN)))
	if bad_contacts > 0 or min_s > window.x + 0.1 or max_s < window.y - 0.1:
		_fail("S09 actual base contacts failed: bad=%d/%d shallow=%d deep=%d delta=%.4f..%.4f s=%.2f..%.2f" % [bad_contacts, contacts.size(), shallow_bad, deep_bad, min_delta, max_delta, min_s, max_s])

	var heights: Array = details.s09_height_records()
	var interior_count := 0
	var tapered_count := 0
	var interior_min := INF
	var interior_max := -INF
	for record in heights:
		var base_index := int(record.get("base_vertex_index", -1))
		var top_index := int(record.get("top_vertex_index", -1))
		if base_index < 0 or top_index < 0 or base_index >= vertices.size() or top_index >= vertices.size():
			_fail("S09 height record points outside actual vertex array")
			continue
		var height := vertices[top_index].y - vertices[base_index].y
		var s := float(record.get("s", NAN))
		if s >= window.x + S09_END_TAPER_M and s <= window.y - S09_END_TAPER_M:
			interior_count += 1
			interior_min = minf(interior_min, height)
			interior_max = maxf(interior_max, height)
		else:
			tapered_count += 1
	if interior_count < 3 or interior_min < S09_MIN_HEIGHT_M or interior_max > S09_MAX_HEIGHT_M:
		_fail("S09 interior wall heights outside %.2f..%.2fm: count=%d range=%.3f..%.3f" % [S09_MIN_HEIGHT_M, S09_MAX_HEIGHT_M, interior_count, interior_min, interior_max])
	if tapered_count < 2:
		_fail("S09 wall has no tapered end columns")
	print("S09 actual contacts: records=%d s=%.2f..%.2f embed_delta=%.4f..%.4f shallow_bad=%d deep_bad=%d interior_height=%.3f..%.3f tapered=%d" % [contacts.size(), min_s, max_s, min_delta, max_delta, shallow_bad, deep_bad, interior_min, interior_max, tapered_count])

func _verify_s09_bank_contacts(route, landscape, details, vertices: PackedVector3Array) -> void:
	var records: Array = details.s09_bank_contact_records()
	if records.size() < 3:
		_fail("S09 bank has too few actual outer-ground contacts: %d" % records.size())
		return
	var min_delta := INF
	var max_delta := -INF
	var worst_delta := 0.0
	var worst_s := 0.0
	var worst_u := 0.0
	var worst_point := Vector3.ZERO
	var worst_ground := NAN
	var worst_expected_xz := Vector2.ZERO
	var bad := 0
	for record in records:
		var index := int(record.get("vertex_index", -1))
		var s := float(record.get("s", NAN))
		var u := float(record.get("u", NAN))
		if index < 0 or index >= vertices.size() or not is_finite(s) or not is_finite(u):
			bad += 1
			continue
		var point := vertices[index]
		var sample: Dictionary = landscape.sample_mesh_triangle(Vector2(point.x, point.z))
		if sample.is_empty() or not sample.has("height"):
			bad += 1
			continue
		var delta := point.y - float(sample["height"])
		min_delta = minf(min_delta, delta)
		max_delta = maxf(max_delta, delta)
		if absf(delta) > absf(worst_delta):
			worst_delta = delta
			worst_s = s
			worst_u = u
			worst_point = point
			worst_ground = float(sample["height"])
			var centre: Vector3 = route.call("pos_at", s)
			var left: Vector3 = route.call("left_at", s)
			worst_expected_xz = Vector2(centre.x + left.x * u, centre.z + left.z * u)
		var half := float(route.call("road_width_at", s)) * 0.5
		if delta < -0.02 or delta > 0.16 or u < half + 1.0:
			bad += 1
	if bad > 0:
		_fail("S09 bank outer-ground contact failed: bad=%d/%d delta=%.4f..%.4f worst=%.4f s=%.2f u=%.2f point=%s expected_xz=%s ground=%.4f" % [bad, records.size(), min_delta, max_delta, worst_delta, worst_s, worst_u, worst_point, worst_expected_xz, worst_ground])
	print("S09 grass bank contacts: records=%d ground_delta=%.4f..%.4f bad=%d worst=%.4f s=%.2f u=%.2f point=%s expected_xz=%s ground=%.4f" % [records.size(), min_delta, max_delta, bad, worst_delta, worst_s, worst_u, worst_point, worst_expected_xz, worst_ground])

func _verify_s09_front_irregularity(route, details, vertices: PackedVector3Array) -> void:
	var records: Array = details.s09_front_lateral_records()
	if records.size() < 14:
		_fail("S09 front records have too few layer samples: %d" % records.size())
		return
	var current_s := NAN
	var current_min := INF
	var current_max := -INF
	var columns := 0
	var irregular := 0
	var min_range := INF
	var max_range := -INF
	for record in records:
		var s := float(record.get("s", NAN))
		var index := int(record.get("vertex_index", -1))
		if not is_finite(s) or index < 0 or index >= vertices.size():
			_fail("S09 front relief contains invalid record")
			continue
		var centre: Vector3 = route.call("pos_at", s)
		var left: Vector3 = route.call("left_at", s)
		var point := vertices[index]
		var u := Vector2(point.x - centre.x, point.z - centre.z).dot(Vector2(left.x, left.z))
		if is_finite(current_s) and absf(s - current_s) > 0.01:
			var span := current_max - current_min
			columns += 1
			min_range = minf(min_range, span)
			max_range = maxf(max_range, span)
			if span >= 0.08:
				irregular += 1
			current_min = INF
			current_max = -INF
		current_s = s
		current_min = minf(current_min, u)
		current_max = maxf(current_max, u)
	if is_finite(current_s):
		var final_span := current_max - current_min
		columns += 1
		min_range = minf(min_range, final_span)
		max_range = maxf(max_range, final_span)
		if final_span >= 0.08:
			irregular += 1
	if columns < 3 or irregular < maxi(int(ceil(float(columns) * 0.35)), 3):
		_fail("S09 stone frontage is too uniform: columns=%d lateral_range=%.3f..%.3fm irregular=%d" % [columns, min_range, max_range, irregular])
	print("S09 stone frontage: columns=%d lateral_range=%.3f..%.3fm irregular=%d" % [columns, min_range, max_range, irregular])

func _verify_winding_and_normals(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array) -> void:
	var degenerate := 0
	var normal_mismatch := 0
	for face_start in range(0, indices.size(), 3):
		var ia := int(indices[face_start])
		var ib := int(indices[face_start + 1])
		var ic := int(indices[face_start + 2])
		if ia < 0 or ib < 0 or ic < 0 or ia >= vertices.size() or ib >= vertices.size() or ic >= vertices.size():
			_fail("details index out of bounds at face %d" % (face_start / 3))
			continue
		var a := vertices[ia]
		var b := vertices[ib]
		var c := vertices[ic]
		var face := (c - a).cross(b - a)
		if face.length_squared() < EPS:
			degenerate += 1
			continue
		face = face.normalized()
		if normals[ia].length_squared() < EPS or face.dot(normals[ia].normalized()) < 0.70:
			normal_mismatch += 1
	if degenerate > 0:
		_fail("details has %d degenerate triangles" % degenerate)
	if normal_mismatch > 0:
		_fail("details has %d triangles whose lighting normal disagrees with winding" % normal_mismatch)
	print("details winding/normals: faces=%d degenerate=%d normal_mismatch=%d" % [indices.size() / 3, degenerate, normal_mismatch])

func _verify_closed_edges(vertices: PackedVector3Array, indices: PackedInt32Array) -> void:
	var edges: Dictionary = {}
	for face_start in range(0, indices.size(), 3):
		var points := [vertices[indices[face_start]], vertices[indices[face_start + 1]], vertices[indices[face_start + 2]]]
		for edge_index in range(3):
			var a_key := _point_key(points[edge_index])
			var b_key := _point_key(points[(edge_index + 1) % 3])
			var edge_key := a_key + "|" + b_key if a_key < b_key else b_key + "|" + a_key
			edges[edge_key] = int(edges.get(edge_key, 0)) + 1
	var open_edges := 0
	var over_shared_edges := 0
	for edge_key in edges:
		var count := int(edges[edge_key])
		if count == 1:
			open_edges += 1
		elif count != 2:
			over_shared_edges += 1
	if open_edges > 0 or over_shared_edges > 0:
		_fail("details surface is not closed: unique_edges=%d open=%d over_shared=%d" % [edges.size(), open_edges, over_shared_edges])
	print("details closed surface: unique_edges=%d open=%d over_shared=%d" % [edges.size(), open_edges, over_shared_edges])

func _verify_contacts_and_heights(route, landscape, details, vertices: PackedVector3Array, window: Vector2) -> void:
	var contacts: Array = details.base_contact_records()
	if contacts.size() < 4:
		_fail("details has too few actual base contact records: %d" % contacts.size())
	var min_s := INF
	var max_s := -INF
	var contact_error := 0
	var contact_shallow_bad := 0
	var contact_deep_bad := 0
	var contact_min_delta := INF
	var contact_max_delta := -INF
	for record in contacts:
		if not record.has("vertex_index"):
			contact_error += 1
			continue
		var index := int(record["vertex_index"])
		if index < 0 or index >= vertices.size():
			contact_error += 1
			continue
		var point := vertices[index]
		var sample: Dictionary = landscape.sample_mesh_triangle(Vector2(point.x, point.z))
		if sample.is_empty() or not sample.has("height"):
			contact_error += 1
			continue
		var ground := float(sample["height"])
		var embedded := point.y - ground
		if not is_finite(embedded):
			contact_error += 1
		else:
			contact_min_delta = minf(contact_min_delta, embedded)
			contact_max_delta = maxf(contact_max_delta, embedded)
			if embedded > CONTACT_SHALLOW_LIMIT_M:
				contact_error += 1
				contact_shallow_bad += 1
			elif embedded < CONTACT_DEEP_LIMIT_M:
				contact_error += 1
				contact_deep_bad += 1
		min_s = minf(min_s, float(record.get("s", NAN)))
		max_s = maxf(max_s, float(record.get("s", NAN)))
	if contact_error > 0:
		_fail("details actual mesh base contacts failed: %d/%d shallow=%d deep=%d observed_delta=%.4f..%.4f" % [contact_error, contacts.size(), contact_shallow_bad, contact_deep_bad, contact_min_delta, contact_max_delta])
	if min_s > window.x + 0.01 or max_s < window.y - 0.01:
		_fail("base contacts do not span full wall interval: %.2f..%.2f vs %.2f..%.2f" % [min_s, max_s, window.x, window.y])

	var records: Array = details.height_records()
	if records.size() < 3:
		_fail("details has too few height records: %d" % records.size())
	var interior_count := 0
	var interior_min := INF
	var interior_max := -INF
	var tapered_end_count := 0
	for record in records:
		var base_index := int(record.get("base_vertex_index", -1))
		var top_index := int(record.get("top_vertex_index", -1))
		if base_index < 0 or top_index < 0 or base_index >= vertices.size() or top_index >= vertices.size():
			_fail("height record points outside actual vertex array")
			continue
		var height := vertices[top_index].y - vertices[base_index].y
		var s := float(record.get("s", NAN))
		if not is_finite(height) or not is_finite(s):
			_fail("non-finite height record")
		elif s >= window.x + 8.0 and s <= window.y - 8.0:
			interior_count += 1
			interior_min = minf(interior_min, height)
			interior_max = maxf(interior_max, height)
		elif s <= window.x + 8.0 or s >= window.y - 8.0:
			tapered_end_count += 1
		if absf(height - float(record.get("height_m", height))) > 0.01:
			_fail("height record metadata disagrees with actual vertices at s=%.2f" % s)
	if interior_count < 3 or interior_min < MIN_HEIGHT_M - 0.2 or interior_max > MAX_HEIGHT_M + 0.2:
		_fail("interior wall heights outside 5..10m: count=%d range=%.2f..%.2f" % [interior_count, interior_min, interior_max])
	if tapered_end_count < 2:
		_fail("wall has no sampled tapered end columns")
	print("details actual contacts: records=%d s=%.2f..%.2f embed_delta=%.4f..%.4f shallow_bad=%d deep_bad=%d interior_height=%.2f..%.2f tapered=%d" % [contacts.size(), min_s, max_s, contact_min_delta, contact_max_delta, contact_shallow_bad, contact_deep_bad, interior_min, interior_max, tapered_end_count])

func _verify_road_clearance(route, vertices: PackedVector3Array, window: Vector2) -> void:
	var min_clearance := INF
	var worst := Vector3.ZERO
	var worst_s := 0.0
	var over_count := 0
	for point in vertices:
		var s := _nearest_local_route_s(route, point, window)
		var centre: Vector3 = route.call("pos_at", s)
		var left: Vector3 = route.call("left_at", s)
		var lateral := (Vector2(point.x - centre.x, point.z - centre.z)).dot(Vector2(left.x, left.z))
		var half := float(route.call("road_width_at", s)) * 0.5
		var clearance := lateral - half
		if clearance < min_clearance:
			min_clearance = clearance
			worst = point
			worst_s = s
		if clearance < 0.35:
			over_count += 1
	if over_count > 0:
		_fail("details has %d vertices inside road clearance; min=%.3fm at s=%.2f p=%s" % [over_count, min_clearance, worst_s, worst])
	print("details asphalt clearance: min=%.3fm at s=%.2f point=%s violating_vertices=%d" % [min_clearance, worst_s, worst, over_count])

func _verify_frontfoot_continuity(landscape, details, vertices: PackedVector3Array, supplied_contacts: Array = []) -> void:
	var front_records: Array = []
	var contact_source: Array = supplied_contacts if not supplied_contacts.is_empty() else details.base_contact_records()
	for record in contact_source:
		if record.get("kind", "") == "front":
			front_records.append(record)
	if front_records.size() < 2:
		_fail("frontfoot continuity has too few front columns: %d" % front_records.size())
		return
	var sample_count := 0
	var missing_count := 0
	var bad_count := 0
	var shallow_bad := 0
	var deep_bad := 0
	var min_delta := INF
	var max_delta := -INF
	var worst_delta := 0.0
	var worst_s := 0.0
	for i in range(front_records.size() - 1):
		var first: Dictionary = front_records[i]
		var second: Dictionary = front_records[i + 1]
		var first_index := int(first.get("vertex_index", -1))
		var second_index := int(second.get("vertex_index", -1))
		if first_index < 0 or second_index < 0 or first_index >= vertices.size() or second_index >= vertices.size():
			missing_count += 1
			continue
		var s0 := float(first.get("s", NAN))
		var s1 := float(second.get("s", NAN))
		var segment_count := maxi(int(ceil(absf(s1 - s0) / 0.5)), 1)
		var a := vertices[first_index]
		var b := vertices[second_index]
		for j in range(segment_count + 1):
			if i > 0 and j == 0:
				continue
			var t := float(j) / float(segment_count)
			var point := a.lerp(b, t)
			var sample: Dictionary = landscape.sample_mesh_triangle(Vector2(point.x, point.z))
			sample_count += 1
			if sample.is_empty() or not sample.has("height"):
				missing_count += 1
				continue
			var delta := point.y - float(sample["height"])
			if not is_finite(delta):
				bad_count += 1
				continue
			min_delta = minf(min_delta, delta)
			max_delta = maxf(max_delta, delta)
			if absf(delta) > absf(worst_delta):
				worst_delta = delta
				worst_s = lerpf(s0, s1, t)
			if delta > CONTACT_SHALLOW_LIMIT_M:
				bad_count += 1
				shallow_bad += 1
			elif delta < CONTACT_DEEP_LIMIT_M:
				bad_count += 1
				deep_bad += 1
		if not is_finite(s0) or not is_finite(s1):
			bad_count += 1
	if missing_count > 0 or bad_count > 0:
		_fail("frontfoot 0.5m actual terrain continuity failed: samples=%d missing=%d shallow_bad=%d deep_bad=%d observed_delta=%.4f..%.4f worst_delta=%.4fm at s=%.2f" % [sample_count, missing_count, shallow_bad, deep_bad, min_delta, max_delta, worst_delta, worst_s])
	print("details frontfoot actual terrain: columns=%d samples=%.0f missing=%d shallow_bad=%d deep_bad=%d observed_delta=%.4f..%.4f worst_delta=%.4fm at s=%.2f criterion=%.2f..%.2fm" % [front_records.size(), sample_count, missing_count, shallow_bad, deep_bad, min_delta, max_delta, worst_delta, worst_s, CONTACT_DEEP_LIMIT_M, CONTACT_SHALLOW_LIMIT_M])

func _verify_front_relief(route, details, vertices: PackedVector3Array) -> void:
	var records: Array = details.front_lateral_records()
	if records.size() < 14:
		_fail("front relief metadata has too few layer records: %d" % records.size())
		return
	var current_s := NAN
	var current_min := INF
	var current_max := -INF
	var column_count := 0
	var strong_columns := 0
	var max_relief := 0.0
	var min_relief := INF
	for record in records:
		var s := float(record.get("s", NAN))
		var index := int(record.get("vertex_index", -1))
		if not is_finite(s) or index < 0 or index >= vertices.size():
			_fail("front relief contains invalid s/vertex index")
			continue
		var centre: Vector3 = route.call("pos_at", s)
		var left: Vector3 = route.call("left_at", s)
		var point := vertices[index]
		var u := Vector2(point.x - centre.x, point.z - centre.z).dot(Vector2(left.x, left.z))
		if is_finite(current_s) and absf(s - current_s) > 0.01:
			var relief := current_max - current_min
			column_count += 1
			min_relief = minf(min_relief, relief)
			max_relief = maxf(max_relief, relief)
			if relief >= 2.0:
				strong_columns += 1
			current_min = INF
			current_max = -INF
		current_s = s
		current_min = minf(current_min, u)
		current_max = maxf(current_max, u)
	if is_finite(current_s):
		var final_relief := current_max - current_min
		column_count += 1
		min_relief = minf(min_relief, final_relief)
		max_relief = maxf(max_relief, final_relief)
		if final_relief >= 2.0:
			strong_columns += 1
	if max_relief < 1.0 or strong_columns < 4:
		_fail("front rock relief is too smooth/shallow: columns=%d range=%.2f..%.2fm strong>=2m=%d" % [column_count, min_relief, max_relief, strong_columns])
	print("details front strata relief: columns=%d lateral_range=%.2f..%.2fm strong_columns>=2m=%d" % [column_count, min_relief, max_relief, strong_columns])

func _verify_wall_asphalt_footprint(route, vertices: PackedVector3Array, indices: PackedInt32Array) -> void:
	var asphalt := route.get_node_or_null("SaisiesAsphalt") as MeshInstance3D
	if asphalt == null or asphalt.mesh == null:
		_fail("wall/asphalt footprint check cannot find actual SaisiesAsphalt mesh")
		return
	var road_faces: PackedVector3Array = asphalt.mesh.get_faces()
	if road_faces.size() < 3 or road_faces.size() % 3 != 0:
		_fail("actual SaisiesAsphalt face buffer is invalid: %d vertices" % road_faces.size())
		return
	var overlap_count := 0
	var candidate_pairs := 0
	var first_wall_face := -1
	var first_road_face := -1
	for wall_start in range(0, indices.size(), 3):
		var wall_a := vertices[indices[wall_start]]
		var wall_b := vertices[indices[wall_start + 1]]
		var wall_c := vertices[indices[wall_start + 2]]
		var wall_min_x := minf(wall_a.x, minf(wall_b.x, wall_c.x))
		var wall_max_x := maxf(wall_a.x, maxf(wall_b.x, wall_c.x))
		var wall_min_z := minf(wall_a.z, minf(wall_b.z, wall_c.z))
		var wall_max_z := maxf(wall_a.z, maxf(wall_b.z, wall_c.z))
		for road_start in range(0, road_faces.size(), 3):
			var road_a := road_faces[road_start]
			var road_b := road_faces[road_start + 1]
			var road_c := road_faces[road_start + 2]
			var road_min_x := minf(road_a.x, minf(road_b.x, road_c.x))
			var road_max_x := maxf(road_a.x, maxf(road_b.x, road_c.x))
			var road_min_z := minf(road_a.z, minf(road_b.z, road_c.z))
			var road_max_z := maxf(road_a.z, maxf(road_b.z, road_c.z))
			if wall_max_x < road_min_x - 0.005 or road_max_x < wall_min_x - 0.005 or wall_max_z < road_min_z - 0.005 or road_max_z < wall_min_z - 0.005:
				continue
			candidate_pairs += 1
			if _triangles_overlap_xz(wall_a, wall_b, wall_c, road_a, road_b, road_c):
				overlap_count += 1
				if first_wall_face < 0:
					first_wall_face = wall_start / 3
					first_road_face = road_start / 3
		if overlap_count > 0:
				break
		if overlap_count > 0:
			break
	if overlap_count > 0:
		_fail("wall triangle footprint intersects actual asphalt: overlaps=%d first_wall_face=%d first_road_face=%d" % [overlap_count, first_wall_face, first_road_face])
	print("details wall/asphalt footprint: wall_triangles=%d asphalt_triangles=%d aabb_candidates=%d overlaps=%d" % [indices.size() / 3, road_faces.size() / 3, candidate_pairs, overlap_count])

func _triangles_overlap_xz(a: Vector3, b: Vector3, c: Vector3, d: Vector3, e: Vector3, f: Vector3) -> bool:
	var first := [Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z)]
	var second := [Vector2(d.x, d.z), Vector2(e.x, e.z), Vector2(f.x, f.z)]
	var axes: Array[Vector2] = []
	for triangle in [first, second]:
		for i in range(3):
			var edge: Vector2 = triangle[(i + 1) % 3] - triangle[i]
			var axis := Vector2(-edge.y, edge.x)
			if axis.length_squared() > EPS:
				axes.append(axis.normalized())
	for axis in axes:
		var projection_a := _project_triangle(first, axis)
		var projection_b := _project_triangle(second, axis)
		if projection_a.y < projection_b.x - 0.005 or projection_b.y < projection_a.x - 0.005:
			return false
	return true

func _project_triangle(points: Array, axis: Vector2) -> Vector2:
	var minimum := INF
	var maximum := -INF
	for point_variant in points:
		var point: Vector2 = point_variant
		var value: float = point.dot(axis)
		minimum = minf(minimum, value)
		maximum = maxf(maximum, value)
	return Vector2(minimum, maximum)

func _nearest_local_route_s(route, point: Vector3, window: Vector2) -> float:
	var best_s := window.x
	var best_distance := INF
	var count := maxi(int(ceil((window.y - window.x) / 1.5)), 1)
	for i in range(count + 1):
		var s := lerpf(window.x, window.y, float(i) / float(count))
		var centre: Vector3 = route.call("pos_at", s)
		var distance := Vector2(point.x - centre.x, point.z - centre.z).length_squared()
		if distance < best_distance:
			best_distance = distance
			best_s = s
	return best_s

func _verify_material(details) -> void:
	var node := details.get_node_or_null("SaisiesGeoNearfieldS13RockWall") as MeshInstance3D
	if node == null or node.mesh == null:
		_fail("details MeshInstance3D is missing")
		return
	var material := node.mesh.surface_get_material(0) as StandardMaterial3D
	if material == null:
		_fail("details material is not StandardMaterial3D")
		return
	if material.albedo_texture == null or material.normal_texture == null or material.roughness_texture == null:
		_fail("details material is missing rock albedo/normal/roughness texture")
	var color := material.albedo_color
	if color.r > 0.80 or color.g > 0.80 or color.b > 0.80:
		_fail("details rock tint is too white: %s" % color)
	if absf(color.r - color.b) > 0.12 or absf(color.g - color.b) > 0.12:
		_fail("details rock tint is too warm/saturated: %s" % color)
	if material.normal_scale < 1.0 or material.uv1_scale.x < 0.50:
		_fail("details rock material lacks near-field normal/texture scale: normal=%.2f uv_scale=%s" % [material.normal_scale, material.uv1_scale])
	if material.cull_mode != BaseMaterial3D.CULL_BACK:
		_fail("details material cull mode is not backface")
	print("details material: tint=%s roughness=%.2f normal_scale=%.2f uv_scale=%s triplanar=%s cull=%d" % [color, material.roughness, material.normal_scale, material.uv1_scale, material.uv1_triplanar, material.cull_mode])

func _verify_s09_material(details) -> void:
	var wall_node := details.get_node_or_null("SaisiesGeoNearfieldS09LowStoneWall") as MeshInstance3D
	var bank_node := details.get_node_or_null("SaisiesGeoNearfieldS09GrassBank") as MeshInstance3D
	if wall_node == null or wall_node.mesh == null or bank_node == null or bank_node.mesh == null:
		_fail("S09 wall/bank MeshInstance3D is missing")
		return
	var wall_material := wall_node.mesh.surface_get_material(0) as StandardMaterial3D
	var bank_material := bank_node.mesh.surface_get_material(0) as ShaderMaterial
	if wall_material == null or bank_material == null or bank_material.shader == null:
		_fail("S09 wall/bank material contract is invalid")
		return
	if wall_material.albedo_texture == null or wall_material.normal_texture == null or wall_material.roughness_texture == null:
		_fail("S09 stone wall is missing albedo/normal/roughness textures")
	var bank_shader_path := String(bank_material.shader.resource_path)
	if bank_shader_path != "res://shaders/saisies_geo_terrain_detail.gdshader":
		_fail("S09 grass bank shader is not shared terrain detail mapping: %s" % bank_shader_path)
	var bank_albedo = bank_material.get_shader_parameter("detail_albedo_tex")
	var bank_normal = bank_material.get_shader_parameter("detail_normal_tex")
	if bank_albedo == null or bank_normal == null:
		_fail("S09 grass bank is missing shared albedo/normal detail textures")
	if not bool(bank_material.get_shader_parameter("detail_enabled")) or not bool(bank_material.get_shader_parameter("detail_force")):
		_fail("S09 grass bank must force the shared green detail mapping")
	var bank_uv_scale := float(bank_material.get_shader_parameter("detail_uv_scale"))
	var bank_brightness := float(bank_material.get_shader_parameter("detail_brightness"))
	if not is_finite(bank_uv_scale) or bank_uv_scale < 0.15 or bank_uv_scale > 0.35 or not is_finite(bank_brightness) or bank_brightness <= 0.0 or bank_brightness > 1.25:
		_fail("S09 grass bank detail parameters are invalid: uv=%.3f brightness=%.3f" % [bank_uv_scale, bank_brightness])
	var wall_color := wall_material.albedo_color
	if wall_color.r > 0.86 or wall_color.g > 0.86 or wall_color.b > 0.86:
		_fail("S09 stone wall tint is too white: %s" % wall_color)
	if absf(wall_color.r - wall_color.b) > 0.12 or absf(wall_color.g - wall_color.b) > 0.12:
		_fail("S09 stone wall tint is too warm/saturated: %s" % wall_color)
	if wall_material.normal_scale < 0.8 or wall_material.uv1_scale.x < 0.5 or not wall_material.uv1_triplanar:
		_fail("S09 stone wall lacks near-field block texture scale: normal=%.2f uv=%s triplanar=%s" % [wall_material.normal_scale, wall_material.uv1_scale, wall_material.uv1_triplanar])
	if wall_material.cull_mode != BaseMaterial3D.CULL_BACK:
		_fail("S09 stone wall material cull mode is not backface")
	print("S09 materials: stone=%s normal=%.2f uv=%s grass_shader=%s force=%s uv=%.3f brightness=%.3f" % [wall_color, wall_material.normal_scale, wall_material.uv1_scale, bank_shader_path, bool(bank_material.get_shader_parameter("detail_force")), bank_uv_scale, bank_brightness])

func _point_key(point: Vector3) -> String:
	return "%d,%d,%d" % [roundi(point.x * 1000.0), roundi(point.y * 1000.0), roundi(point.z * 1000.0)]

func _finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _finite_vector2(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES GEO NEARFIELD DETAILS: " + message)
