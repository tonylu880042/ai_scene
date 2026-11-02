extends SceneTree

## Focused smoke test for the static Saisies landscape generator.
##
## This deliberately instantiates SaisiesRoute and SaisiesLandscape without
## changing the source scene, so the contract can be checked before the main
## agent wires the landscape node into MainScene_saisies.tscn.

var _errors: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var route_script := load("res://scripts/saisies_route.gd") as Script
	var landscape_script := load("res://scripts/saisies_landscape.gd") as Script
	if route_script == null:
		_fail("saisies_route.gd could not be loaded")
	if landscape_script == null:
		_fail("saisies_landscape.gd could not be loaded")
	if not _errors.is_empty():
		_finish()
		return

	var holder := Node3D.new()
	holder.name = "SaisiesLandscapeVerification"
	get_root().add_child(holder)
	var route := route_script.new() as Node3D
	route.name = "Route"
	# The integrated reconstruction uses the v2 route overlay. Keep this
	# verifier on the same route as MainScene_saisies_v2 so ridge clearance and
	# all 18 acceptance anchors are checked against the shipped world.
	route.set("route_file", "res://data/saisies_route_v2.json")
	holder.add_child(route)
	var landscape := landscape_script.new() as Node3D
	landscape.name = "Landscape"
	landscape.set("route_path", NodePath("../Route"))
	holder.add_child(landscape)

	await process_frame
	await process_frame
	if not bool(route.call("route_ready")):
		_fail("route did not become ready")
	if not bool(landscape.get("landscape_ready")):
		_fail("landscape did not become ready")
	else:
		_verify_route_profile(route)
		_verify_landscape(route, landscape)
		_verify_s05_static_projection(route, landscape)
	holder.queue_free()
	_finish()

func _verify_route_profile(route: Node3D) -> void:
	var length_m := float(route.get("length_m"))
	if absf(length_m - 14800.0) > 1.0:
		_fail("v2 route length %.1f m is not 14800 m" % length_m)
	var first_elevation := float(route.call("elevation_at", 0.0))
	var last_elevation := float(route.call("elevation_at", length_m))
	if absf(first_elevation - 1608.0) > 1.0 or absf(last_elevation - 689.0) > 1.0:
		_fail("v2 elevation endpoints %.1f -> %.1f m are wrong" % [first_elevation, last_elevation])
	var previous := route.call("pos_at", 0.0) as Vector3
	var route_samples := 0
	for distance_i in range(20, 14801, 20):
		var distance := minf(float(distance_i), length_m)
		var point := route.call("pos_at", distance) as Vector3
		if previous.distance_to(point) > 42.0:
			_fail("v2 route has a discontinuity near %.0f m" % distance)
		var grade := float(route.call("grade_at", distance))
		if absf(grade) > 20.0:
			_fail("v2 route grade %.2f%% is too steep near %.0f m" % [grade, distance])
		previous = point
		route_samples += 1
	var previous_s := -1.0
	for video_seconds in [0.0, 180.0, 190.0, 210.0, 240.0, 270.0, 296.0, 312.0, 330.0, 630.0, 900.0, 920.067]:
		var distance := float(route.call("distance_at_video_time", video_seconds))
		if distance < previous_s:
			_fail("v2 video-time mapping reverses at %.3f s" % video_seconds)
		previous_s = distance
	print("v2 route profile: %.1f m, elevation %.1f -> %.1f m, %d continuity samples" % [length_m, first_elevation, last_elevation, route_samples])

func _verify_landscape(route: Node3D, landscape: Node3D) -> void:
	var length_m := float(route.get("length_m"))
	var vertices := int(landscape.get_meta("saisies_landscape_vertex_count", 0))
	var triangles := int(landscape.get_meta("saisies_landscape_triangle_count", 0))
	if vertices < 8000 or vertices > 100000:
		_fail("landscape vertex count %d is outside 8k..100k" % vertices)
	if triangles < 15000 or triangles > 200000:
		_fail("landscape triangle count %d is outside 15k..200k" % triangles)
	var bounds := landscape.call("landscape_bounds") as AABB
	if bounds.size.x < 5000.0 or bounds.size.z < 15000.0:
		_fail("landscape bounds are too small: %s" % bounds)
	for s in [0.0, length_m * 0.25, length_m * 0.5, length_m * 0.75, length_m - 0.1]:
		var p: Vector3 = route.call("pos_at", s)
		if p.x < bounds.position.x or p.x > bounds.end.x or p.z < bounds.position.z or p.z > bounds.end.z:
			_fail("route sample %.0f m is outside static landscape bounds" % s)
		var left: Vector3 = route.call("left_at", s)
		for u in [-110.0, -55.0, 0.0, 55.0, 110.0]:
			var corridor_point: Vector3 = p + left * u
			var terrain_y := float(landscape.call("sample_landscape_height", Vector2(corridor_point.x, corridor_point.z)))
			var road_y := float(route.call("ground_y", s, u))
			if terrain_y > road_y - 8.0:
				_fail("terrain enters road corridor at %.0f m / offset %.0f: %.2f vs ribbon %.2f" % [s, u, terrain_y, road_y])
	var massif := landscape.get_node_or_null("SaisiesStaticS05Massif") as MeshInstance3D
	if massif == null or massif.mesh == null:
		_fail("static S05 massif mesh is missing")
	else:
		var massif_arrays := massif.mesh.surface_get_arrays(0)
		var massif_vertices := massif_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var massif_bounds := massif.get_aabb()
		if massif_vertices.size() < 300:
			_fail("S05 massif has too few vertices: %d" % massif_vertices.size())
		if massif_bounds.size.x < 2500.0 or massif_bounds.size.z < 2500.0 or massif_bounds.size.y < 250.0:
			_fail("S05 massif footprint/height is too small: %s" % massif_bounds)
	var village_ridge := landscape.get_node_or_null("SaisiesStaticVillageRidge") as MeshInstance3D
	if village_ridge == null or village_ridge.mesh == null:
		_fail("static village ridge mesh is missing")
	else:
		var village_bounds := village_ridge.get_aabb()
		if village_bounds.size.x < 1000.0 or village_bounds.size.z < 600.0 or village_bounds.size.y < 50.0:
			_fail("village ridge footprint/height is too small: %s" % village_bounds)
	_verify_static_ridge_clearance(route, landscape, ["SaisiesStaticVillageRidge", "SaisiesStaticS05Massif"])
	_verify_static_ridge_faces(route, landscape, ["SaisiesStaticVillageRidge", "SaisiesStaticS05Massif"])
	_verify_static_ridge_normals(landscape, ["SaisiesStaticVillageRidge", "SaisiesStaticS05Massif"])
	print("saisies landscape: %d vertices, %d triangles, bounds %s, village ridge %s, S05 massif %s" % [vertices, triangles, bounds, village_ridge.get_aabb() if village_ridge else AABB(), massif.get_aabb() if massif else AABB()])

func _verify_static_ridge_normals(landscape: Node3D, node_names: Array[String]) -> void:
	for node_name in node_names:
		var node := landscape.get_node_or_null(node_name) as MeshInstance3D
		if node == null or node.mesh == null:
			continue
		var arrays := node.mesh.surface_get_arrays(0)
		var normals := arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
		var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
		var upward := 0
		for normal in normals:
			if normal.y > 0.001:
				upward += 1
		if upward != normals.size():
			_fail("%s has %d/%d upward vertex normals" % [node_name, upward, normals.size()])
		var winding_upward := 0
		for face_start in range(0, indices.size(), 3):
			var a := vertices[indices[face_start]]
			var b := vertices[indices[face_start + 1]]
			var c := vertices[indices[face_start + 2]]
			if (b - a).cross(c - a).y > 0.001:
				winding_upward += 1
		var face_count := indices.size() / 3
		if winding_upward != face_count:
			_fail("%s has %d/%d upward triangle windings" % [node_name, winding_upward, face_count])
		print("%s normals/winding: %d/%d, %d/%d upward" % [node_name, upward, normals.size(), winding_upward, face_count])

func _verify_s05_static_projection(route: Node3D, landscape: Node3D) -> void:
	# Diagnostic only: report each fixed mesh in the S05 camera frame so a large
	# foreground plane can be attributed without launching a renderer.
	var anchor_s := float(route.call("acceptance_distance", "S05"))
	var origin := route.call("pos_at", anchor_s) as Vector3
	var forward := route.call("tangent_at", anchor_s) as Vector3
	var camera := Camera3D.new()
	camera.fov = 78.0
	camera.far = 10000.0
	var ground_y := float(route.call("ground_y", anchor_s, 0.0))
	camera.position = Vector3(origin.x, ground_y + 1.67, origin.z)
	camera.rotation = Vector3(deg_to_rad(-8.0), atan2(-forward.x, -forward.z), 0.0)
	get_root().add_child(camera)
	# Headless's root viewport is usually 64x64. Use the capture contract's
	# fixed size instead of Camera3D.unproject_position(), which would make this
	# attribution depend on whichever viewport happened to be active.
	var capture_width := 1920.0
	var capture_height := 1080.0
	var vertical_tan := tan(deg_to_rad(camera.fov) * 0.5)
	var horizontal_tan := vertical_tan * (capture_width / capture_height)
	var view_basis := camera.global_transform.basis.inverse()
	var camera_position := camera.global_position
	for node_name in ["SaisiesStaticLandscape", "SaisiesStaticVillageRidge", "SaisiesStaticS05Massif"]:
		var node := landscape.get_node_or_null(node_name) as MeshInstance3D
		if node == null or node.mesh == null:
			continue
		var arrays := node.mesh.surface_get_arrays(0)
		var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var min_depth := INF
		var max_depth := -INF
		var min_right := INF
		var max_right := -INF
		var min_height := INF
		var max_height := -INF
		var front_count := 0
		var nearest_front_depth := INF
		var viewport_count := 0
		var viewport_min_x := INF
		var viewport_max_x := -INF
		var viewport_min_y := INF
		var viewport_max_y := -INF
		var min_pixel_x := INF
		var max_pixel_x := -INF
		var min_pixel_y := INF
		var max_pixel_y := -INF
		var sky_right_count := 0
		var sky_right_min_y := INF
		var sky_right_max_y := -INF
		var sky_right_details: Array[String] = []
		var vertex_index := 0
		for vertex in vertices:
			var world := node.to_global(vertex)
			var local := view_basis * (world - camera_position)
			var depth := -local.z
			var lateral := local.x
			min_depth = minf(min_depth, depth)
			max_depth = maxf(max_depth, depth)
			min_right = minf(min_right, lateral)
			max_right = maxf(max_right, lateral)
			min_height = minf(min_height, local.y)
			max_height = maxf(max_height, local.y)
			if depth > 0.0 and depth < 10000.0:
				front_count += 1
				nearest_front_depth = minf(nearest_front_depth, depth)
			if depth > 1.0 and depth < 10000.0:
				var ndc_x := (local.x / depth) / horizontal_tan
				var ndc_y := (local.y / depth) / vertical_tan
				var pixel_x := (ndc_x * 0.5 + 0.5) * capture_width
				var pixel_y := (0.5 - ndc_y * 0.5) * capture_height
				min_pixel_x = minf(min_pixel_x, pixel_x)
				max_pixel_x = maxf(max_pixel_x, pixel_x)
				min_pixel_y = minf(min_pixel_y, pixel_y)
				max_pixel_y = maxf(max_pixel_y, pixel_y)
				if pixel_x >= 0.0 and pixel_x <= capture_width and pixel_y >= 0.0 and pixel_y <= capture_height:
					viewport_count += 1
					viewport_min_x = minf(viewport_min_x, pixel_x)
					viewport_max_x = maxf(viewport_max_x, pixel_x)
					viewport_min_y = minf(viewport_min_y, pixel_y)
					viewport_max_y = maxf(viewport_max_y, pixel_y)
				if pixel_x >= 1300.0 and pixel_y <= 450.0:
					sky_right_count += 1
					sky_right_min_y = minf(sky_right_min_y, pixel_y)
					sky_right_max_y = maxf(sky_right_max_y, pixel_y)
					if sky_right_details.size() < 64:
						sky_right_details.append("v%d d%.0f r%.0f h%.0f px%.0f py%.0f" % [vertex_index, depth, lateral, local.y, pixel_x, pixel_y])
			vertex_index += 1
		print("S05 projection %s: depth %.0f..%.0f (nearest front %.0f), camera_right %.0f..%.0f, camera_height %.0f..%.0f, front vertices %d/%d, pixels %.0f..%.0f x %.0f..%.0f, viewport vertices %d px %.0f..%.0f x %.0f..%.0f, right_sky_vertices %d y %.0f..%.0f" % [node_name, min_depth, max_depth, nearest_front_depth, min_right, max_right, min_height, max_height, front_count, vertices.size(), min_pixel_x, max_pixel_x, min_pixel_y, max_pixel_y, viewport_count, viewport_min_x, viewport_max_x, viewport_min_y, viewport_max_y, sky_right_count, sky_right_min_y, sky_right_max_y])
		if not sky_right_details.is_empty():
			print("S05 right-sky candidates %s: %s" % [node_name, "; ".join(sky_right_details)])
	camera.queue_free()

func _verify_static_ridge_clearance(route: Node3D, landscape: Node3D, node_names: Array[String]) -> void:
	# Check every fixed ridge against the complete route envelope and every
	# acceptance camera anchor. This catches a distant mesh becoming an overhead
	# roof after the route bends away from its authoring view.
	var anchors: Array[Vector3] = []
	for scene_id in ["S01", "S02", "S03", "S04", "S05", "S06", "S07", "S08", "S09", "S10", "S11", "S12", "S13", "S14", "S15", "S16", "S17", "S18"]:
		var s := float(route.call("acceptance_distance", scene_id))
		anchors.append(route.call("pos_at", s))
	var checked := 0
	var anchor_checks := PackedInt32Array()
	anchor_checks.resize(anchors.size())
	for node_name in node_names:
		var node := landscape.get_node_or_null(node_name) as MeshInstance3D
		if node == null or node.mesh == null:
			continue
		var arrays := node.mesh.surface_get_arrays(0)
		var ridge_vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		for vertex in ridge_vertices:
			var world := node.to_global(vertex)
			# Use an XZ-only route search. distance_for_position() compares full
			# 3D points, which can select a visually distant downhill sample for a
			# high ridge vertex and under-report the horizontal clearance.
			var nearest_s := _nearest_route_distance_xz(route, world)
			var nearest := route.call("pos_at", nearest_s) as Vector3
			var lateral := Vector2(world.x - nearest.x, world.z - nearest.z).length()
			var road_y := float(route.call("ground_y", nearest_s, 0.0))
			if lateral < 820.0 and world.y > road_y + 80.0:
				_fail("%s rises into route envelope at %.0f m: lateral %.1f, y %.1f vs road %.1f" % [node_name, nearest_s, lateral, world.y, road_y])
			for anchor_index in anchors.size():
				var anchor := anchors[anchor_index]
				var anchor_distance := Vector2(world.x - anchor.x, world.z - anchor.z).length()
				if anchor_distance < 700.0:
					anchor_checks[anchor_index] += 1
					# Compare with the route elevation at the vertex's nearest
					# horizontal point, rather than the anchor elevation. The route
					# drops hundreds of metres between early and late anchors, so
					# anchor.y would reject a safe road-level shoulder.
					if world.y > road_y + 80.0:
						_fail("%s is above route near anchor %d at %.0f m: distance %.1f, y %.1f vs road %.1f" % [node_name, anchor_index + 1, nearest_s, anchor_distance, world.y, road_y])
			checked += 1
	if checked < 300:
		_fail("static ridge clearance inspected too few vertices: %d" % checked)
	else:
		print("static ridge clearance: %d vertices checked across 18 anchors (%s anchor samples)" % [checked, str(anchor_checks)])

func _verify_static_ridge_faces(route: Node3D, landscape: Node3D, node_names: Array[String]) -> void:
	# Validate rendered faces, not only the authored rise values. A base face can
	# still become a grey roof after a route bend even when its mountain lift is
	# zero, so every face touching the protected corridor must sit below its local
	# road and below each nearby acceptance camera's road level.
	var anchors: Array[Vector3] = []
	var camera_heights := PackedFloat32Array()
	for scene_id in ["S01", "S02", "S03", "S04", "S05", "S06", "S07", "S08", "S09", "S10", "S11", "S12", "S13", "S14", "S15", "S16", "S17", "S18"]:
		var s := float(route.call("acceptance_distance", scene_id))
		anchors.append(route.call("pos_at", s))
		camera_heights.append(float(route.call("ground_y", s, 0.0)) + 1.67)
	var checked_faces := 0
	var protected_faces := 0
	var anchor_face_counts := PackedInt32Array()
	anchor_face_counts.resize(anchors.size())
	for node_name in node_names:
		var node := landscape.get_node_or_null(node_name) as MeshInstance3D
		if node == null or node.mesh == null:
			continue
		var arrays := node.mesh.surface_get_arrays(0)
		var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
		for face_start in range(0, indices.size(), 3):
			var face_max_y := -INF
			var face_min_lateral := INF
			var face_road_y := INF
			var nearby_anchor := -1
			var face_anchor_hits := PackedByteArray()
			face_anchor_hits.resize(anchors.size())
			for corner in 3:
				var world := node.to_global(vertices[indices[face_start + corner]])
				var nearest_s := _nearest_route_distance_xz(route, world)
				var nearest := route.call("pos_at", nearest_s) as Vector3
				var lateral := Vector2(world.x - nearest.x, world.z - nearest.z).length()
				face_min_lateral = minf(face_min_lateral, lateral)
				face_road_y = minf(face_road_y, float(route.call("ground_y", nearest_s, 0.0)))
				face_max_y = maxf(face_max_y, world.y)
				for anchor_index in anchors.size():
					var anchor_distance := Vector2(world.x - anchors[anchor_index].x, world.z - anchors[anchor_index].z).length()
					if anchor_distance < 700.0:
						face_anchor_hits[anchor_index] = 1
			for anchor_index in anchors.size():
				if face_anchor_hits[anchor_index] > 0:
					if nearby_anchor < 0:
						nearby_anchor = anchor_index
					anchor_face_counts[anchor_index] += 1
			checked_faces += 1
			var touches_corridor := face_min_lateral < 820.0
			if touches_corridor:
				protected_faces += 1
				if face_max_y > face_road_y - 1.0:
					_fail("%s face enters protected corridor: lateral %.1f, max y %.1f vs road %.1f" % [node_name, face_min_lateral, face_max_y, face_road_y])
			if nearby_anchor >= 0 and face_max_y > face_road_y - 1.0:
				_fail("%s face is above road near S%02d camera (camera y %.1f): max y %.1f vs road %.1f" % [node_name, nearby_anchor + 1, camera_heights[nearby_anchor], face_max_y, face_road_y])
	if checked_faces < 300:
		_fail("static ridge face safety inspected too few rendered faces: %d" % checked_faces)
	else:
		print("static ridge face safety: %d faces checked, %d protected faces, 18 camera samples %s" % [checked_faces, protected_faces, str(anchor_face_counts)])

func _nearest_route_distance_xz(route: Node3D, world: Vector3) -> float:
	var length_m := float(route.get("length_m"))
	var step_m := 20.0
	var count := int(ceil(length_m / step_m)) + 1
	var best_s := 0.0
	var best_distance_sq := INF
	for i in count:
		var s := minf(float(i) * step_m, length_m)
		var route_point: Vector3 = route.call("pos_at", s)
		var dx := world.x - route_point.x
		var dz := world.z - route_point.z
		var distance_sq := dx * dx + dz * dz
		if distance_sq < best_distance_sq:
			best_distance_sq = distance_sq
			best_s = s
	return best_s

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES LANDSCAPE VERIFY: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES LANDSCAPE VERIFY PASS")
		quit(0)
	else:
		print("SAISIES LANDSCAPE VERIFY FAIL (%d errors)" % _errors.size())
		quit(1)
