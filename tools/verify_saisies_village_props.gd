extends SceneTree

## Headless contract and projection diagnostic for the S01 route props.
##
## This builds the real v2 route with the shipped camera and props scripts, then
## checks the scene registration separately.  Contact and alignment are
## measured from transforms; count metadata is used only as a quick inventory.

const SCENE_PATH := "res://scenes/MainScene_saisies_v2.tscn"
const ROUTE_SCRIPT_PATH := "res://scripts/saisies_route.gd"
const CAMERA_SCRIPT_PATH := "res://scripts/saisies_camera.gd"
const PROPS_SCRIPT_PATH := "res://scripts/saisies_village_props.gd"
const ROUTE_FILE := "res://data/saisies_route_v2.json"
const PERIWINKLE_SCENE := "res://assets/models/periwinkle_plant/periwinkle_plant_1k.gltf"
const PERIWINKLE_ATLAS := "res://assets/models/periwinkle_plant/textures/periwinkle_plant_diff_1k.jpg"
const PERIWINKLE_NORMAL_ATLAS := "res://assets/models/periwinkle_plant/textures/periwinkle_plant_nor_gl_1k.jpg"
const CANOPY_SHADER := "res://shaders/saisies_flower_canopy.gdshader"
const LEAF_UV_RECT := Rect2(210.0 / 1024.0, 130.0 / 1024.0, 170.0 / 1024.0, 85.0 / 1024.0)
const FLOWER_UV_RECT := Rect2(300.0 / 1024.0, 250.0 / 1024.0, 240.0 / 1024.0, 255.0 / 1024.0)
const CAPTURE_SIZE := Vector2i(1920, 1080)
const EXPECTED_FLOWERBOX_S := [58.0, 64.0, 72.0, 84.0, 100.0]
const EXPECTED_FLAG_S := [90.0, 98.0, 106.0, 114.0]
const CANOPY_TRIANGLE_BUDGET_PER_BOX := 4000

var _errors: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var route_script := load(ROUTE_SCRIPT_PATH)
	var camera_script := load(CAMERA_SCRIPT_PATH)
	var props_script := load(PROPS_SCRIPT_PATH)
	if route_script == null or camera_script == null or props_script == null:
		_fail("v2 route/camera/props scripts could not be loaded")
		_finish()
		return
	var holder := Node3D.new()
	holder.name = "SaisiesVillagePropsVerification"
	var route := route_script.new() as SaisiesRoute
	route.name = "Route"
	route.route_file = ROUTE_FILE
	route.fallback_length_m = 14800.0
	route.fallback_start_elevation_m = 1608.0
	route.fallback_end_elevation_m = 717.0
	route.fallback_road_width_m = 6.4
	route.shoulder_width_m = 0.28
	route.downhill_terrain_factor = 1.0
	route.village_flatten_radius_m = 18.0
	var rig := camera_script.new() as SaisiesCamera
	rig.name = "CameraRig"
	rig.route_path = NodePath("../Route")
	rig.auto_advance = false
	rig.camera_height = 1.65
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.current = true
	camera.fov = 79.0
	rig.add_child(camera)
	var props := props_script.new() as Node3D
	props.name = "VillagePropsS01"
	props.set("route_path", NodePath("../Route"))
	props.set("from_m", 0.0)
	props.set("to_m", 220.0)
	holder.add_child(route)
	holder.add_child(rig)
	holder.add_child(props)
	get_root().add_child(holder)
	var window := get_root() as Window
	if window != null:
		window.size = CAPTURE_SIZE
		window.content_scale_size = CAPTURE_SIZE
	await process_frame
	await process_frame
	if route.length_m < 14700.0 or route.length_m > 14900.0:
		_fail("v2 route length %.2f m is outside the authored 14.8 km route" % route.length_m)
	var scene_text := FileAccess.get_file_as_string(SCENE_PATH)
	if not scene_text.contains("VillagePropsS01") or not scene_text.contains("10_village_props"):
		_fail("v2 scene registration for VillagePropsS01 is missing")
	_verify_atlas_pixels()
	if not _errors.is_empty():
		_finish()
		return
	if not bool(props.get("props_ready")):
		_fail("village props module did not become ready")
	else:
		_verify_props(route, props)
		_verify_projection(route, props, rig)
	props.queue_free()
	_finish()

func _verify_props(route: SaisiesRoute, props: Node3D) -> void:
	var group := props.get_node_or_null("S01VillageStreetProps") as Node3D
	if group == null:
		_fail("S01VillageStreetProps group is missing")
		return
	var flowerboxes: Array[Node3D] = []
	var flags: Array[Node3D] = []
	for child in group.get_children():
		if not child is Node3D:
			continue
		var child_node := child as Node3D
		if child_node.name.begins_with("S01RightLogFlowerbox_"):
			flowerboxes.append(child_node)
		elif child_node.name.begins_with("S01RightFlag_"):
			flags.append(child_node)
	if flowerboxes.size() < 4:
		_fail("too few right log flowerboxes: %d" % flowerboxes.size())
	if flags.size() < 3:
		_fail("too few right flag groups: %d" % flags.size())
	if int(props.get_meta("saisies_village_props_log_count", 0)) < flowerboxes.size() * 4:
		_fail("log inventory is too small for the flowerbox groups")
	var canopy_leaf_cards := int(props.get_meta("saisies_village_props_canopy_leaf_cards", 0))
	var canopy_flower_cards := int(props.get_meta("saisies_village_props_canopy_flower_cards", 0))
	var canopy_triangles := int(props.get_meta("saisies_village_props_canopy_triangles", 0))
	if canopy_leaf_cards < flowerboxes.size() * 800 or canopy_leaf_cards > flowerboxes.size() * 1200:
		_fail("atlas canopy leaf-card inventory is outside 800-1200 per box: %d" % canopy_leaf_cards)
	if canopy_flower_cards < flowerboxes.size() * 150 or canopy_flower_cards > flowerboxes.size() * 300:
		_fail("atlas canopy flower-card inventory is outside 150-300 per box: %d" % canopy_flower_cards)
	if canopy_triangles <= 0 or canopy_triangles > flowerboxes.size() * CANOPY_TRIANGLE_BUDGET_PER_BOX:
		_fail("atlas canopy triangle budget is invalid: %d (limit %d)" % [canopy_triangles, flowerboxes.size() * CANOPY_TRIANGLE_BUDGET_PER_BOX])
	for source_path in [PERIWINKLE_SCENE, PERIWINKLE_ATLAS, PERIWINKLE_NORMAL_ATLAS, CANOPY_SHADER]:
		if not FileAccess.file_exists(source_path):
			_fail("authored periwinkle canopy source is missing: %s" % source_path)
	_verify_authored_layout(flowerboxes, flags)
	for box in flowerboxes:
		_verify_flowerbox(route, box)
	for flag_group in flags:
		_verify_flagpole(route, flag_group)
	_verify_mesh_complexity(group)
	_verify_no_forbidden_props(group)
	print("saisies village props: flowerboxes=%d flags=%d logs=%d leaf_cards=%d flower_cards=%d canopy_triangles=%d" % [
		flowerboxes.size(), flags.size(),
		int(props.get_meta("saisies_village_props_log_count", 0)),
		canopy_leaf_cards,
		canopy_flower_cards,
		canopy_triangles
	])

func _verify_flowerbox(route: SaisiesRoute, anchor: Node3D) -> void:
	var s := float(anchor.get_meta("route_distance_m", -1.0))
	var u := float(anchor.get_meta("route_lateral_m", 0.0))
	if s < 0.0:
		_fail("flowerbox %s is missing route distance" % anchor.name)
		return
	var body := anchor.get_node_or_null("FlowerboxBody") as MeshInstance3D
	if body == null or not (body.mesh is BoxMesh):
		_fail("flowerbox %s has no measurable body" % anchor.name)
		return
	var body_box := body.mesh as BoxMesh
	if body_box.size.x < 0.78 or body_box.size.x > 0.95 or body_box.size.z < 1.70 or body_box.size.z > 2.10:
		_fail("%s is not a small fixed-size planter: depth=%.2f length=%.2f" % [anchor.name, body_box.size.x, body_box.size.z])
	if body.scale.distance_to(Vector3.ONE) > 0.001:
		_fail("%s uses distance-dependent mesh scaling" % anchor.name)
	var body_bottom_y := -body_box.size.y * 0.5
	for x_sign in [-1.0, 1.0]:
		for z_sign in [-1.0, 1.0]:
			var corner := body.global_transform * Vector3(float(x_sign) * body_box.size.x * 0.5, body_bottom_y, float(z_sign) * body_box.size.z * 0.5)
			_verify_terrain_contact(route, corner, "%s body corner" % anchor.name)
	var route_point := route.pos_at(s)
	var lateral := (anchor.global_position - route_point).dot(route.left_at(s))
	if lateral > -(route.road_width_at(s) * 0.5 + 0.25):
		_fail("%s intrudes into the road corridor: lateral=%.2f" % [anchor.name, lateral])
	var tangent := route.tangent_at(s)
	var log_count := 0
	var post_points: Array[Vector3] = []
	for child in anchor.get_children():
		if not child is MeshInstance3D or not String(child.name).begins_with("GuardrailPost_"):
			continue
		var post := child as MeshInstance3D
		var post_mesh := post.mesh as CylinderMesh
		if post_mesh == null:
			_fail("%s post is not a measurable cylinder" % post.name)
			continue
		var post_bottom := post.global_transform * Vector3(0.0, -post_mesh.height * 0.5, 0.0)
		_verify_terrain_contact(route, post_bottom, "%s post" % anchor.name)
		post_points.append(post.global_position)
	for child in anchor.get_children():
		if not child is MeshInstance3D:
			continue
		var mesh_instance := child as MeshInstance3D
		if String(mesh_instance.name).begins_with("GuardrailPost_"):
			continue
		elif String(mesh_instance.name).begins_with("GuardrailLog_"):
			var log := mesh_instance
			var log_mesh := log.mesh as CylinderMesh
			if log_mesh == null:
				_fail("%s log is not a measurable cylinder" % log.name)
				continue
			var axis := log.global_transform.basis.y.normalized()
			if absf(axis.dot(tangent)) < 0.97:
				_fail("%s log is not route-aligned: dot=%.3f" % [log.name, absf(axis.dot(tangent))])
			for end_sign in [-1.0, 1.0]:
				var endpoint := log.global_transform * Vector3(0.0, float(end_sign) * log_mesh.height * 0.5, 0.0)
				var nearest_post := INF
				for post_point in post_points:
					nearest_post = minf(nearest_post, endpoint.distance_to(post_point))
				if nearest_post > 0.55:
					_fail("%s log end is unsupported: nearest post %.3fm" % [log.name, nearest_post])
			log_count += 1
	if log_count < 4:
		_fail("%s has too few route-aligned logs: %d" % [anchor.name, log_count])
	_verify_canopy(anchor, body)

func _verify_terrain_contact(route: SaisiesRoute, world_point: Vector3, label: String) -> void:
	var sample_s := route.distance_for_position(world_point)
	var route_point := route.pos_at(sample_s)
	var lateral := (world_point - route_point).dot(route.left_at(sample_s))
	var terrain_y := route.ground_y(sample_s, lateral)
	var margin := terrain_y - world_point.y
	if margin < -0.15 or margin > 0.35:
		_fail("%s terrain contact margin %.3fm (terrain=%.3f point=%.3f)" % [label, margin, terrain_y, world_point.y])

func _verify_canopy(anchor: Node3D, body: MeshInstance3D) -> void:
	var canopy := anchor.get_node_or_null("PeriwinkleCanopyCards") as MeshInstance3D
	if canopy == null or not (canopy.mesh is ArrayMesh):
		_fail("%s has no atlas ArrayMesh canopy" % anchor.name)
		return
	var mesh := canopy.mesh as ArrayMesh
	if mesh.get_surface_count() != 1:
		_fail("%s canopy should have one shared ArrayMesh surface, found %d" % [anchor.name, mesh.get_surface_count()])
		return
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if vertices.size() == 0 or normals.size() != vertices.size() or tangents.size() != vertices.size() * 4 or uvs.size() != vertices.size() or indices.size() == 0:
		_fail("%s canopy mesh has incomplete vertex/normal/tangent/UV/index arrays" % anchor.name)
		return
	var card_count := vertices.size() / 4
	var actual_triangles := indices.size() / 3
	if vertices.size() % 4 != 0 or indices.size() != card_count * 6:
		_fail("%s canopy cards are not two triangles each: vertices=%d indices=%d" % [anchor.name, vertices.size(), indices.size()])
	var leaf_count := 0
	var flower_count := 0
	var high_count := 0
	var overhang_count := 0
	var leaf_layer_counts := [0, 0, 0, 0]
	var leaf_layer_radius_sum := [0.0, 0.0, 0.0, 0.0]
	var leaf_layer_radius_count := [0, 0, 0, 0]
	var leaf_bottom_min := INF
	var body_box := body.mesh as BoxMesh
	var body_height := float(canopy.get_meta("canopy_body_height_m", body_box.size.y))
	var max_x := body_box.size.x * 0.5 + 0.27
	var max_z := body_box.size.z * 0.5 + 0.25
	var soil := anchor.get_node_or_null("FlowerboxSoil") as MeshInstance3D
	if soil == null or not (soil.mesh is BoxMesh):
		_fail("%s is missing measurable soil for canopy volume contact" % anchor.name)
		return
	var soil_box := soil.mesh as BoxMesh
	var soil_top := soil.position.y + soil_box.size.y * 0.5
	var crown_span_x := body_box.size.x * 0.5 + 0.16
	var crown_half_length := maxf(body_box.size.z * 0.5 - 0.06, 0.1)
	for card_index in range(card_count):
		var base := card_index * 4
		var uv_center := (uvs[base] + uvs[base + 2]) * 0.5
		var is_leaf := _rect_contains(LEAF_UV_RECT, uv_center)
		var is_flower := _rect_contains(FLOWER_UV_RECT, uv_center)
		if is_leaf == is_flower:
			_fail("%s card %d UV center is outside exactly one atlas source rect: %s" % [anchor.name, card_index, uv_center])
		elif is_leaf:
			leaf_count += 1
		else:
			flower_count += 1
		var center := (vertices[base] + vertices[base + 1] + vertices[base + 2] + vertices[base + 3]) * 0.25
		var card_width := vertices[base].distance_to(vertices[base + 1])
		var card_height := vertices[base].distance_to(vertices[base + 3])
		var expected_normal := (vertices[base + 1] - vertices[base]).cross(vertices[base + 3] - vertices[base]).normalized()
		for vertex_index in range(4):
			var vertex_normal := normals[base + vertex_index]
			var tangent_offset := (base + vertex_index) * 4
			var vertex_tangent := Vector3(tangents[tangent_offset], tangents[tangent_offset + 1], tangents[tangent_offset + 2])
			if not is_finite(vertex_normal.x) or not is_finite(vertex_normal.y) or not is_finite(vertex_normal.z) or absf(vertex_normal.length() - 1.0) > 0.02:
				_fail("%s card %d vertex %d has invalid normal: %s" % [anchor.name, card_index, vertex_index, vertex_normal])
			if not is_finite(vertex_tangent.x) or not is_finite(vertex_tangent.y) or not is_finite(vertex_tangent.z) or absf(vertex_tangent.length() - 1.0) > 0.02:
				_fail("%s card %d vertex %d has invalid tangent: %s" % [anchor.name, card_index, vertex_index, vertex_tangent])
			if absf(vertex_normal.dot(vertex_tangent)) > 0.025:
				_fail("%s card %d vertex %d normal/tangent are not orthogonal: dot=%.4f" % [anchor.name, card_index, vertex_index, vertex_normal.dot(vertex_tangent)])
			if vertex_normal.dot(expected_normal) < 0.98:
				_fail("%s card %d vertex %d normal does not match card plane: dot=%.3f" % [anchor.name, card_index, vertex_index, vertex_normal.dot(expected_normal)])
		if is_leaf:
			if card_width < 0.039 or card_width > 0.081 or card_height < 0.030 or card_height > 0.072:
				_fail("%s leaf card %d size %.3fx%.3f is outside 4-8cm target" % [anchor.name, card_index, card_width, card_height])
		else:
			if card_width < 0.028 or card_width > 0.061 or card_height < 0.028 or card_height > 0.061:
				_fail("%s flower card %d size %.3fx%.3f is outside 3-6cm target" % [anchor.name, card_index, card_width, card_height])
		if card_width > 0.2 or card_height > 0.2:
			_fail("%s canopy card %d is implausibly large: %.3fx%.3f" % [anchor.name, card_index, card_width, card_height])
		if absf(center.x) > max_x or absf(center.z) > max_z:
			_fail("%s canopy card %d leaves the planter envelope: center=%s" % [anchor.name, card_index, center])
		if is_leaf:
			for vertex_index in range(4):
				leaf_bottom_min = minf(leaf_bottom_min, vertices[base + vertex_index].y)
			var soil_relative_y := center.y - soil_top
			var layer_index := floori(soil_relative_y / 0.15)
			if layer_index >= 0 and layer_index < 4:
				leaf_layer_counts[layer_index] += 1
				var layer_radius := maxf(absf(center.x) / maxf(crown_span_x, 0.001), absf(center.z) / maxf(crown_half_length, 0.001))
				leaf_layer_radius_sum[layer_index] += layer_radius
				leaf_layer_radius_count[layer_index] += 1
		if center.y >= body_height + 0.32 and center.y <= body_height + 0.70:
			high_count += 1
		if absf(center.x) >= body_box.size.x * 0.5 + 0.08 and absf(center.x) <= body_box.size.x * 0.27 + body_box.size.x * 0.5:
			overhang_count += 1
	var expected_leaf := int(canopy.get_meta("canopy_leaf_cards", -1))
	var expected_flower := int(canopy.get_meta("canopy_flower_cards", -1))
	var expected_triangles := int(canopy.get_meta("canopy_triangles", -1))
	if leaf_count < 800 or leaf_count > 1200:
		_fail("%s has %d leaf cards; expected 800-1200" % [anchor.name, leaf_count])
	if flower_count < 150 or flower_count > 300:
		_fail("%s has %d flower cards; expected 150-300" % [anchor.name, flower_count])
	if expected_leaf != leaf_count or expected_flower != flower_count:
		_fail("%s canopy card metadata mismatch: meta=%d/%d actual=%d/%d" % [anchor.name, expected_leaf, expected_flower, leaf_count, flower_count])
	if expected_triangles != actual_triangles or actual_triangles != card_count * 2:
		_fail("%s canopy triangle metadata mismatch: meta=%d actual=%d" % [anchor.name, expected_triangles, actual_triangles])
	if actual_triangles > CANOPY_TRIANGLE_BUDGET_PER_BOX:
		_fail("%s canopy has too many triangles: %d (limit %d)" % [anchor.name, actual_triangles, CANOPY_TRIANGLE_BUDGET_PER_BOX])
	if high_count < int(card_count * 0.50):
		_fail("%s crown has too few cards in the upper 0.4-0.6m band: %d/%d" % [anchor.name, high_count, card_count])
	if overhang_count < int(leaf_count * 0.08):
		_fail("%s crown has too few cards spilling over the box edge: %d/%d" % [anchor.name, overhang_count, leaf_count])
	for layer_index in range(4):
		if leaf_layer_counts[layer_index] == 0:
			_fail("%s leaf crown layer %d has no cards in soil-relative band %.2f-%.2fm" % [anchor.name, layer_index, float(layer_index) * 0.15, float(layer_index + 1) * 0.15])
	if leaf_bottom_min < soil_top - 0.025 or leaf_bottom_min > soil_top + 0.045:
		_fail("%s lowest leaf card does not meet soil: bottom=%.3f soil_top=%.3f" % [anchor.name, leaf_bottom_min, soil_top])
	var low_radius: float = leaf_layer_radius_sum[0] / maxf(float(leaf_layer_radius_count[0]), 1.0)
	var high_radius: float = leaf_layer_radius_sum[3] / maxf(float(leaf_layer_radius_count[3]), 1.0)
	if high_radius >= low_radius * 0.92:
		_fail("%s crown radius does not contract with height: low=%.3f high=%.3f" % [anchor.name, low_radius, high_radius])
	var material := canopy.get_active_material(0) as ShaderMaterial
	if material == null:
		_fail("%s canopy has no ShaderMaterial" % anchor.name)
	else:
		var shader := material.shader
		if shader == null or shader.resource_path != CANOPY_SHADER:
			_fail("%s canopy does not use %s" % [anchor.name, CANOPY_SHADER])
		else:
			var source_code := shader.code
			for token in ["atlas_texture", "normal_atlas", "brightness", "ALPHA_SCISSOR_THRESHOLD"]:
				if not source_code.contains(token):
					_fail("%s canopy shader is missing %s alpha/normal contract" % [anchor.name, token])
		var atlas := material.get_shader_parameter("atlas_texture") as Texture2D
		var normal_atlas := material.get_shader_parameter("normal_atlas") as Texture2D
		if atlas == null or not String(atlas.resource_path).contains("periwinkle_plant_diff_1k"):
			_fail("%s canopy does not use the source diffuse atlas" % anchor.name)
		if normal_atlas == null or not String(normal_atlas.resource_path).contains("periwinkle_plant_nor_gl_1k"):
			_fail("%s canopy does not use the source normal atlas" % anchor.name)
	print("%s atlas canopy leaf_cards=%d flower_cards=%d triangles=%d high=%d overhang=%d leaf_layers=%s soil_bottom=%.3f radius_low=%.3f radius_high=%.3f" % [anchor.name, leaf_count, flower_count, actual_triangles, high_count, overhang_count, leaf_layer_counts, leaf_bottom_min - soil_top, low_radius, high_radius])

func _rect_contains(rect: Rect2, point: Vector2) -> bool:
	return point.x >= rect.position.x - 0.0001 and point.x <= rect.end.x + 0.0001 and point.y >= rect.position.y - 0.0001 and point.y <= rect.end.y + 0.0001

func _verify_atlas_pixels() -> void:
	var image := Image.load_from_file(ProjectSettings.globalize_path(PERIWINKLE_ATLAS))
	if image == null or image.is_empty():
		_fail("could not read periwinkle atlas pixels: %s" % PERIWINKLE_ATLAS)
		return
	var leaf_samples := 0
	var leaf_nonblack := 0
	var leaf_green := 0
	var flower_samples := 0
	var flower_nonblack := 0
	var flower_pink := 0
	for y in range(130, 215, 4):
		for x in range(210, 380, 4):
			var pixel := image.get_pixel(x, y)
			leaf_samples += 1
			var brightness := (pixel.r + pixel.g + pixel.b) / 3.0
			if brightness > 0.035:
				leaf_nonblack += 1
				if pixel.g > pixel.r * 1.03 and pixel.g >= pixel.b * 0.90:
					leaf_green += 1
	for y in range(250, 505, 4):
		for x in range(300, 540, 4):
			var pixel := image.get_pixel(x, y)
			flower_samples += 1
			var brightness := (pixel.r + pixel.g + pixel.b) / 3.0
			if brightness > 0.035:
				flower_nonblack += 1
				if pixel.r > pixel.g * 1.35 and pixel.b > pixel.g * 1.15 and pixel.r > 0.15:
					flower_pink += 1
	if leaf_nonblack < int(leaf_samples * 0.20) or leaf_green < int(leaf_samples * 0.10):
		_fail("leaf UV rect does not contain enough green atlas pixels: green=%d/%d nonblack=%d/%d" % [leaf_green, leaf_samples, leaf_nonblack, leaf_samples])
	if flower_nonblack < int(flower_samples * 0.20) or flower_pink < int(flower_samples * 0.20):
		_fail("flower UV rect does not contain enough pink atlas pixels: pink=%d/%d nonblack=%d/%d" % [flower_pink, flower_samples, flower_nonblack, flower_samples])
	print("periwinkle atlas pixels: leaf_green=%d/%d leaf_nonblack=%d/%d flower_pink=%d/%d flower_nonblack=%d/%d" % [leaf_green, leaf_samples, leaf_nonblack, leaf_samples, flower_pink, flower_samples, flower_nonblack, flower_samples])

func _aabb_in_space(node: MeshInstance3D, target: Node3D) -> AABB:
	var local_aabb := node.get_aabb()
	var transform := target.global_transform.affine_inverse() * node.global_transform
	var min_v := Vector3(INF, INF, INF)
	var max_v := Vector3(-INF, -INF, -INF)
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				var local_point := Vector3(local_aabb.position.x if x < 0.0 else local_aabb.end.x, local_aabb.position.y if y < 0.0 else local_aabb.end.y, local_aabb.position.z if z < 0.0 else local_aabb.end.z)
				var point: Vector3 = transform * local_point
				min_v = min_v.min(point)
				max_v = max_v.max(point)
	return AABB(min_v, max_v - min_v)

func _mesh_triangle_count(mesh: Mesh) -> int:
	var total := 0
	for surface in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if not indices.is_empty():
			total += indices.size() / 3
		else:
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			total += vertices.size() / 3
	return total

func _verify_authored_layout(flowerboxes: Array[Node3D], flags: Array[Node3D]) -> void:
	var actual_box_s: Array = []
	for box in flowerboxes:
		actual_box_s.append(float(box.get_meta("route_distance_m", -1.0)))
	actual_box_s.sort()
	if actual_box_s.size() != EXPECTED_FLOWERBOX_S.size():
		_fail("expected %d fixed-size flowerboxes, found %d" % [EXPECTED_FLOWERBOX_S.size(), actual_box_s.size()])
	else:
		for index in range(EXPECTED_FLOWERBOX_S.size()):
			if absf(float(actual_box_s[index]) - float(EXPECTED_FLOWERBOX_S[index])) > 0.2:
				_fail("flowerbox %d is at s=%.2f, expected %.2f" % [index, actual_box_s[index], EXPECTED_FLOWERBOX_S[index]])
	var actual_flag_s: Array = []
	for flag in flags:
		actual_flag_s.append(float(flag.get_meta("route_distance_m", -1.0)))
	actual_flag_s.sort()
	if actual_flag_s.size() != EXPECTED_FLAG_S.size():
		_fail("expected %d relocated flagpoles, found %d" % [EXPECTED_FLAG_S.size(), actual_flag_s.size()])
	else:
		for index in range(EXPECTED_FLAG_S.size()):
			if absf(float(actual_flag_s[index]) - float(EXPECTED_FLAG_S[index])) > 0.2:
				_fail("flagpole %d is at s=%.2f, expected %.2f" % [index, actual_flag_s[index], EXPECTED_FLAG_S[index]])

func _verify_flagpole(route: SaisiesRoute, group: Node3D) -> void:
	var s := float(group.get_meta("route_distance_m", -1.0))
	var u := float(group.get_meta("route_lateral_m", 0.0))
	var pole := group.get_node_or_null("Flagpole") as MeshInstance3D
	var flag := group.get_node_or_null("FlagPanel") as MeshInstance3D
	if pole == null or flag == null:
		_fail("%s is missing its pole or flag panel" % group.name)
		return
	var pole_mesh := pole.mesh as CylinderMesh
	if pole_mesh == null:
		_fail("%s pole is not a CylinderMesh" % group.name)
		return
	var bottom_world: Vector3 = pole.global_transform * Vector3(0.0, -pole_mesh.height * 0.5, 0.0)
	var terrain_y := route.ground_y(s, u)
	if absf(bottom_world.y - terrain_y) > 0.12:
		_fail("%s pole is not grounded: bottom=%.3f terrain=%.3f" % [group.name, bottom_world.y, terrain_y])
	if not (flag.mesh is BoxMesh):
		_fail("%s flag panel is not a low-poly box" % group.name)

func _verify_mesh_complexity(group: Node3D) -> void:
	for node in _descendants(group):
		if not node is MeshInstance3D:
			continue
		var mesh := (node as MeshInstance3D).mesh
		var node_name := String(node.name)
		if (node_name.begins_with("LeafBlade_") or node_name.begins_with("PinkPetal_")) and not mesh is QuadMesh:
			_fail("%s is not a flat low-poly leaf/petal mesh" % node.name)
		if node_name.begins_with("LeafBlade_") or node_name.begins_with("PinkPetal_"):
			var quad := mesh as QuadMesh
			if quad != null and (quad.size.x < 0.018 or quad.size.x > 0.050 or quad.size.y < 0.028 or quad.size.y > 0.055):
				_fail("%s flat element is outside the 0.02-0.05m visual scale: %.3fx%.3f" % [node.name, quad.size.x, quad.size.y])
		if mesh is SphereMesh:
			_fail("%s uses a sphere for foliage; flat leaf/petal meshes are required" % node.name)
		if mesh is CylinderMesh and (mesh as CylinderMesh).radial_segments > 10:
			_fail("%s uses too many cylinder sides: %d" % [node.name, (mesh as CylinderMesh).radial_segments])

func _verify_no_forbidden_props(group: Node3D) -> void:
	for node in _descendants(group):
		if String(node.name) == "PeriwinkleCanopyCards":
			continue
		var lower_name := String(node.name).to_lower()
		for forbidden in ["car", "vehicle", "bicycle", "bike", "person", "rider"]:
			if lower_name.contains(forbidden):
				_fail("forbidden street prop node: %s" % node.name)

func _verify_projection(route: SaisiesRoute, props: Node3D, rig: SaisiesCamera) -> void:
	rig.auto_advance = false
	var s01 := route.acceptance_distance("S01")
	rig.reset_to_distance(s01)
	rig.apply_acceptance_pose("S01")
	var camera := rig.get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		_fail("S01 camera is missing for projection diagnosis")
		return
	var group := props.get_node_or_null("S01VillageStreetProps") as Node3D
	if group == null:
		return
	var projected := 0
	var total_canopy_inside := 0
	var aggregate_screen_bins := {}
	for child in group.get_children():
		if not child is Node3D:
			continue
		var anchor := child as Node3D
		var screen := camera.unproject_position(anchor.global_position + Vector3(0.0, 0.7, 0.0))
		var front := not camera.is_position_behind(anchor.global_position)
		if not is_finite(screen.x) or not is_finite(screen.y):
			_fail("projection for %s is non-finite" % anchor.name)
			continue
		print("S01 props projection %s: x=%.1f y=%.1f front=%s" % [anchor.name, screen.x, screen.y, front])
		if anchor.name.begins_with("S01RightLogFlowerbox_"):
			var canopy_projection := _verify_canopy_projection(anchor, camera)
			total_canopy_inside += int(canopy_projection.get("inside", 0))
			for bin in canopy_projection.get("bins", {}).keys():
				aggregate_screen_bins[bin] = true
		projected += 1
	if projected < 7:
		_fail("projection diagnosis covered only %d prop groups" % projected)
	if total_canopy_inside < 100:
		_fail("aggregate canopy projection contains too few cards inside the capture: %d" % total_canopy_inside)
	if aggregate_screen_bins.size() < 8:
		_fail("aggregate canopy projection occupies too few screen bins: %d" % aggregate_screen_bins.size())

func _verify_canopy_projection(anchor: Node3D, camera: Camera3D) -> Dictionary:
	var canopy := anchor.get_node_or_null("PeriwinkleCanopyCards") as MeshInstance3D
	if canopy == null or canopy.mesh == null:
		_fail("projection has no canopy mesh for %s" % anchor.name)
		return {"inside": 0, "bins": {}}
	var mesh := canopy.mesh as ArrayMesh
	if mesh == null or mesh.get_surface_count() == 0:
		_fail("projection canopy mesh is not measurable for %s" % anchor.name)
		return {"inside": 0, "bins": {}}
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var card_count := vertices.size() / 4
	var front_count := 0
	var finite_count := 0
	var inside_count := 0
	var bins := {}
	var min_screen := Vector2(INF, INF)
	var max_screen := Vector2(-INF, -INF)
	var screen_rect := Rect2(Vector2.ZERO, Vector2(CAPTURE_SIZE))
	for card_index in range(card_count):
		var base := card_index * 4
		var local_center := (vertices[base] + vertices[base + 1] + vertices[base + 2] + vertices[base + 3]) * 0.25
		var world_center: Vector3 = canopy.global_transform * local_center
		if camera.is_position_behind(world_center):
			continue
		front_count += 1
		var screen := camera.unproject_position(world_center)
		if not is_finite(screen.x) or not is_finite(screen.y):
			continue
		finite_count += 1
		if screen_rect.has_point(screen):
			inside_count += 1
			min_screen = min_screen.min(screen)
			max_screen = max_screen.max(screen)
			var bin := Vector2i(clampi(int(screen.x / 80.0), 0, 23), clampi(int(screen.y / 80.0), 0, 13))
			bins[bin] = true
	if front_count < int(card_count * 0.50):
		_fail("projection for %s sees too few canopy cards in front of camera: %d/%d" % [anchor.name, front_count, card_count])
	if finite_count < int(card_count * 0.50):
		_fail("projection for %s produced too few finite canopy card centers: %d/%d" % [anchor.name, finite_count, card_count])
	if inside_count < 20:
		_fail("projection for %s has too few canopy cards inside the capture: %d" % [anchor.name, inside_count])
	if bins.size() < 1:
		_fail("projection for %s contains no occupied screen bin" % anchor.name)
	if max_screen.x - min_screen.x < 1.5 or max_screen.y - min_screen.y < 1.5:
		_fail("projection for %s canopy has no measurable screen-space spread: %s..%s" % [anchor.name, min_screen, max_screen])
	print("S01 canopy projection %s: front=%d finite=%d inside=%d screen_bins=%d bounds=(%.1f,%.1f)-(%.1f,%.1f)" % [anchor.name, front_count, finite_count, inside_count, bins.size(), min_screen.x, min_screen.y, max_screen.x, max_screen.y])
	return {"inside": inside_count, "bins": bins}

func _descendants(parent: Node) -> Array[Node]:
	var result: Array[Node] = []
	for child in parent.get_children():
		result.append(child)
		result.append_array(_descendants(child))
	return result

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES VILLAGE PROPS VERIFY: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES VILLAGE PROPS VERIFY PASS")
		quit(0)
	else:
		print("SAISIES VILLAGE PROPS VERIFY FAIL (%d errors)" % _errors.size())
		quit(1)
