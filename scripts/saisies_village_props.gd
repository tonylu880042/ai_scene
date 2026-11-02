class_name SaisiesVillageProps
extends Node3D

## Small authored S01 street props owned separately from the village buildings.
##
## These are route-space objects: every base is resolved from the shared route,
## and the log rails inherit the route tangent instead of facing the camera.
## The meshes stay deliberately low-poly so the props read as street furniture
## without becoming a second scenery system.

@export var route_path: NodePath
@export var from_m := 0.0
@export var to_m := 220.0
@export var random_seed := 1831

const PERIWINKLE_SCENE := "res://assets/models/periwinkle_plant/periwinkle_plant_1k.gltf"
const PERIWINKLE_ATLAS := "res://assets/models/periwinkle_plant/textures/periwinkle_plant_diff_1k.jpg"
const PERIWINKLE_NORMAL_ATLAS := "res://assets/models/periwinkle_plant/textures/periwinkle_plant_nor_gl_1k.jpg"
const CANOPY_SHADER := "res://shaders/saisies_flower_canopy.gdshader"
# Rects use the imported atlas' top-left pixel convention.  The source image
# remains untouched; the shader removes its black photographic background at
# render time.
const LEAF_UV_RECT := Rect2(210.0 / 1024.0, 130.0 / 1024.0, 170.0 / 1024.0, 85.0 / 1024.0)
const FLOWER_UV_RECT := Rect2(300.0 / 1024.0, 250.0 / 1024.0, 240.0 / 1024.0, 255.0 / 1024.0)
const CANOPY_LEAF_CARDS := 1000
const CANOPY_FLOWER_CARDS := 220

var route: SaisiesRoute
var props_ready := false
var _rng := RandomNumberGenerator.new()
var _materials: Dictionary = {}
var _canopy_material: ShaderMaterial

func _ready() -> void:
	route = get_node_or_null(route_path) as SaisiesRoute
	if route == null and get_parent() != null:
		route = get_parent().get_node_or_null("Route") as SaisiesRoute
	if route == null or not route.route_ready():
		call_deferred("_try_build")
		return
	_build()

func _try_build() -> void:
	if props_ready:
		return
	if route == null:
		route = get_node_or_null(route_path) as SaisiesRoute
	if route != null and route.route_ready():
		_build()
	else:
		call_deferred("_try_build")

func _build() -> void:
	if props_ready or route == null:
		return
	_rng.seed = random_seed
	from_m = clampf(from_m, 0.0, route.length_m)
	to_m = clampf(maxf(to_m, from_m + 1.0), 0.0, route.length_m)
	_make_materials()
	if not _load_canopy_material():
		push_error("SaisiesVillageProps could not load the authored periwinkle canopy atlas")
		return
	var group := Node3D.new()
	group.name = "S01VillageStreetProps"
	add_child(group)
	var flowerbox_count := _build_right_log_flowerboxes(group)
	var flag_count := _build_right_flags(group)
	set_meta("saisies_village_props_ready", true)
	set_meta("saisies_village_props_from_m", from_m)
	set_meta("saisies_village_props_to_m", to_m)
	set_meta("saisies_village_props_flowerbox_count", flowerbox_count)
	set_meta("saisies_village_props_log_count", int(group.get_meta("log_count", 0)))
	set_meta("saisies_village_props_flower_cluster_count", int(group.get_meta("canopy_flower_cards", 0)))
	set_meta("saisies_village_props_periwinkle_count", 0)
	set_meta("saisies_village_props_periwinkle_triangles", int(group.get_meta("canopy_triangle_count", 0)))
	set_meta("saisies_village_props_canopy_leaf_cards", int(group.get_meta("canopy_leaf_cards", 0)))
	set_meta("saisies_village_props_canopy_flower_cards", int(group.get_meta("canopy_flower_cards", 0)))
	set_meta("saisies_village_props_canopy_triangles", int(group.get_meta("canopy_triangle_count", 0)))
	set_meta("saisies_village_props_flagpole_count", flag_count)
	set_meta("saisies_village_props_scene_id", "S01")
	props_ready = true

func _make_materials() -> void:
	# The source rails are weathered grey-brown wood.  Keep the plank texture for
	# fine grain, but desaturate its tint so the close box does not read orange.
	_materials["log"] = _texture_mat("brown_planks_09", Color(0.34, 0.30, 0.25), 0.95)
	_materials["log_end"] = _mat(Color(0.25, 0.22, 0.18), 0.96)
	_materials["soil"] = _mat(Color(0.20, 0.12, 0.065), 1.0)
	_materials["pole"] = _mat(Color(0.16, 0.14, 0.11), 0.93)
	_materials["flag_red"] = _mat(Color(0.68, 0.10, 0.13), 0.88)
	_materials["flag_blue"] = _mat(Color(0.10, 0.29, 0.50), 0.88)
	_materials["flag_gold"] = _mat(Color(0.83, 0.53, 0.12), 0.88)
	_materials["flag_white"] = _mat(Color(0.86, 0.84, 0.73), 0.90)

func _load_canopy_material() -> bool:
	var shader := load(CANOPY_SHADER) as Shader
	var atlas := load(PERIWINKLE_ATLAS) as Texture2D
	var normal_atlas := load(PERIWINKLE_NORMAL_ATLAS) as Texture2D
	if shader == null or atlas == null or normal_atlas == null:
		return false
	_canopy_material = ShaderMaterial.new()
	_canopy_material.shader = shader
	_canopy_material.set_shader_parameter("atlas_texture", atlas)
	_canopy_material.set_shader_parameter("normal_atlas", normal_atlas)
	_canopy_material.set_shader_parameter("alpha_cutoff", 0.035)
	_canopy_material.set_shader_parameter("alpha_softness", 0.018)
	return true

func _mat(color: Color, roughness := 0.86, metallic := 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	return material

func _texture_mat(stem: String, tint: Color, roughness := 0.86) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = load("res://assets/textures/%s_diff.jpg" % stem)
	material.normal_enabled = true
	material.normal_texture = load("res://assets/textures/%s_nor.jpg" % stem)
	material.roughness_texture = load("res://assets/textures/%s_rough.jpg" % stem)
	material.albedo_color = tint
	material.roughness = roughness
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * 0.42
	return material

func _anchor(parent: Node3D, s: float, u: float, node_name: String) -> Node3D:
	var anchor := Node3D.new()
	anchor.name = node_name
	anchor.position = route.world_at(s, u)
	anchor.basis = Basis.looking_at(route.tangent_at(s), Vector3.UP)
	anchor.set_meta("route_distance_m", s)
	anchor.set_meta("route_lateral_m", u)
	parent.add_child(anchor)
	return anchor

func _build_right_log_flowerboxes(parent: Node3D) -> int:
	# These are small, consistently sized street planters.  Perspective supplies
	# the source's apparent size change; authored dimensions do not shrink with
	# distance.  Negative lateral values stay outside the right road shoulder.
	var specs := [
		{"s": 58.0, "u": -5.10, "length": 1.95, "depth": 0.88},
		{"s": 64.0, "u": -5.05, "length": 1.90, "depth": 0.86},
		{"s": 72.0, "u": -5.00, "length": 1.88, "depth": 0.84},
		{"s": 84.0, "u": -4.95, "length": 1.84, "depth": 0.82},
		{"s": 100.0, "u": -4.90, "length": 1.80, "depth": 0.80}
	]
	var flowerbox_count := 0
	var log_count := 0
	var canopy_leaf_cards := 0
	var canopy_flower_cards := 0
	var canopy_triangle_count := 0
	for spec_value in specs:
		var spec: Dictionary = spec_value
		var s := float(spec["s"])
		var u := float(spec["u"])
		if s < from_m or s > to_m:
			continue
		var length := float(spec["length"])
		var depth := float(spec["depth"])
		var anchor := _anchor(parent, s, u, "S01RightLogFlowerbox_%03d" % int(s))
		var body_height := 0.62
		var body := _part(anchor, _box(Vector3(depth, body_height, length)), _materials["log"], Vector3(0.0, body_height * 0.5 - 0.025, 0.0))
		body.name = "FlowerboxBody"
		var soil := _part(anchor, _box(Vector3(depth - 0.14, 0.075, length - 0.16)), _materials["soil"], Vector3(0.0, body_height + 0.012, 0.0))
		soil.name = "FlowerboxSoil"
		# Two low rails on each side make the box read as stacked round timber;
		# the cylinders are eight-sided and follow the anchor's route tangent.
		for side_value in [-1.0, 1.0]:
			var side_sign: float = float(side_value)
			for level in range(3):
				var log_y := body_height * (0.28 + float(level) * 0.35)
				var rail := _part(anchor, _cylinder(0.14, 0.17, length + 0.22, 8), _materials["log"], Vector3(side_sign * (depth * 0.48), log_y, 0.0), Vector3(PI * 0.5, 0.0, 0.0))
				rail.name = "GuardrailLog_%d_%d" % [int(side_sign), level]
				log_count += 1
			# End grain at the two route-facing ends keeps the construction legible
			# without adding another high-poly mesh.
			for end_value in [-1.0, 1.0]:
				var end_sign: float = float(end_value)
				var post_x := side_sign * depth * 0.48
				var post_z := end_sign * length * 0.47
				var post_height := body_height + 0.18
				var post := _part(anchor, _cylinder(0.115, 0.14, post_height, 8), _materials["log_end"], Vector3(post_x, post_height * 0.5, post_z), Vector3.ZERO)
				post.position.y += _ground_offset_for_local_point(anchor, Vector3(post_x, 0.0, post_z))
				post.name = "GuardrailPost_%d_%d" % [int(side_sign), int(end_sign)]
				log_count += 1
		var canopy_result := _add_atlas_canopy(anchor, length, depth, body_height, int(s))
		canopy_leaf_cards += int(canopy_result[0])
		canopy_flower_cards += int(canopy_result[1])
		canopy_triangle_count += int(canopy_result[2])
		flowerbox_count += 1
	parent.set_meta("log_count", log_count)
	parent.set_meta("canopy_leaf_cards", canopy_leaf_cards)
	parent.set_meta("canopy_flower_cards", canopy_flower_cards)
	parent.set_meta("canopy_triangle_count", canopy_triangle_count)
	return flowerbox_count

func _add_atlas_canopy(anchor: Node3D, length: float, depth: float, body_height: float, seed_value: int) -> Array:
	# The imported photograph is a source atlas, not a billboard to paste over the
	# scene.  Build one shared ArrayMesh per box from small, multi-directional
	# cards so the black atlas background is removed by the canopy shader and the
	# crown remains a real, low-cost 3-D volume.
	var local_rng := RandomNumberGenerator.new()
	local_rng.seed = seed_value * 1009 + 17
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var half_length := maxf(length * 0.5 - 0.06, 0.1)
	var half_depth := maxf(depth * 0.5 - 0.07, 0.1)
	var span_x := depth * 0.5 + 0.16
	for index in range(CANOPY_LEAF_CARDS):
		var center := _canopy_card_center(index, half_length, span_x, body_height, local_rng, 0.0, false)
		var width := local_rng.randf_range(0.040, 0.078)
		var height := local_rng.randf_range(0.034, 0.068)
		var yaw := local_rng.randf_range(0.0, TAU)
		var lean := local_rng.randf_range(-0.28, 0.28)
		_append_canopy_card(vertices, normals, tangents, uvs, indices, center, width, height, yaw, lean, LEAF_UV_RECT)
	for index in range(CANOPY_FLOWER_CARDS):
		var center := _canopy_card_center(index, half_length, span_x, body_height, local_rng, 0.37, true)
		var width := local_rng.randf_range(0.030, 0.058)
		var height := local_rng.randf_range(0.030, 0.058)
		var yaw := local_rng.randf_range(0.0, TAU)
		var lean := local_rng.randf_range(-0.24, 0.24)
		_append_canopy_card(vertices, normals, tangents, uvs, indices, center, width, height, yaw, lean, FLOWER_UV_RECT)
	var canopy_mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	canopy_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	canopy_mesh.surface_set_material(0, _canopy_material)
	var canopy := MeshInstance3D.new()
	canopy.name = "PeriwinkleCanopyCards"
	canopy.mesh = canopy_mesh
	canopy.material_override = _canopy_material
	canopy.set_meta("canopy_asset", PERIWINKLE_ATLAS)
	canopy.set_meta("canopy_normal_asset", PERIWINKLE_NORMAL_ATLAS)
	canopy.set_meta("canopy_leaf_cards", CANOPY_LEAF_CARDS)
	canopy.set_meta("canopy_flower_cards", CANOPY_FLOWER_CARDS)
	canopy.set_meta("canopy_triangles", indices.size() / 3)
	canopy.set_meta("canopy_leaf_uv_rect", LEAF_UV_RECT)
	canopy.set_meta("canopy_flower_uv_rect", FLOWER_UV_RECT)
	canopy.set_meta("canopy_box_depth_m", depth)
	canopy.set_meta("canopy_box_length_m", length)
	canopy.set_meta("canopy_body_height_m", body_height)
	anchor.add_child(canopy)
	anchor.set_meta("canopy_leaf_cards", CANOPY_LEAF_CARDS)
	anchor.set_meta("canopy_flower_cards", CANOPY_FLOWER_CARDS)
	anchor.set_meta("canopy_triangle_count", indices.size() / 3)
	anchor.set_meta("canopy_mesh", canopy)
	return [CANOPY_LEAF_CARDS, CANOPY_FLOWER_CARDS, indices.size() / 3]

func _canopy_card_center(index: int, half_length: float, span_x: float, body_height: float, local_rng: RandomNumberGenerator, phase: float, is_flower: bool) -> Vector3:
	var sequence_z := fmod(float(index) * 0.61803398875 + phase, 1.0)
	var sequence_x := fmod(float(index) * 0.75487766625 + phase * 0.43, 1.0)
	# Fill the complete crown volume from just above the soil to roughly 0.55m
	# above it.  Lower layers occupy the planter's full opening; each higher
	# layer narrows in X/Z so the result is a real half-ellipsoid instead of a
	# floating band at one height.
	var layer_t: float
	if is_flower:
		layer_t = lerpf(0.42, 0.92, local_rng.randf())
	else:
		var layer_index := index % 4
		layer_t = (float(layer_index) + local_rng.randf_range(0.12, 0.88)) / 4.0
	var radius_scale := sqrt(maxf(0.08, 1.0 - 0.86 * layer_t * layer_t))
	var z := lerpf(-half_length, half_length, sequence_z) * radius_scale
	var x := lerpf(-span_x, span_x, sequence_x) * radius_scale + local_rng.randf_range(-0.018, 0.018)
	if not is_flower and layer_t < 0.30 and local_rng.randf() < 0.32:
		# Keep a real lower edge spilling 0.1-0.2m beyond the box while the
		# remaining lower cards still fill the opening as a continuous volume.
		var edge_sign := -1.0 if sequence_x < 0.5 else 1.0
		x = edge_sign * local_rng.randf_range(span_x * 0.87, span_x * 0.99)
	var y := body_height + lerpf(0.095, 0.60, layer_t) + local_rng.randf_range(-0.012, 0.012)
	# Some outer flowers hang down from the lower side of the crown while
	# remaining attached to the same volume and planter opening.
	if is_flower and absf(x) > span_x * 0.55 and local_rng.randf() < 0.35:
		y -= local_rng.randf_range(0.035, 0.10)
	return Vector3(x, y, z)

func _append_canopy_card(vertices: PackedVector3Array, normals: PackedVector3Array, tangents: PackedFloat32Array, uvs: PackedVector2Array, indices: PackedInt32Array, center: Vector3, width: float, height: float, yaw: float, lean: float, uv_rect: Rect2) -> void:
	var right := Vector3(cos(yaw), 0.0, sin(yaw)).normalized()
	var up := Vector3(sin(yaw) * lean, 1.0, -cos(yaw) * lean).normalized()
	var normal := right.cross(up).normalized()
	var half_right := right * width * 0.5
	var half_up := up * height * 0.5
	var base := vertices.size()
	vertices.append(center - half_right - half_up)
	vertices.append(center + half_right - half_up)
	vertices.append(center + half_right + half_up)
	vertices.append(center - half_right + half_up)
	for _vertex in range(4):
		normals.append(normal)
		tangents.append(right.x)
		tangents.append(right.y)
		tangents.append(right.z)
		tangents.append(1.0)
	uvs.append(Vector2(uv_rect.position.x, uv_rect.position.y))
	uvs.append(Vector2(uv_rect.end.x, uv_rect.position.y))
	uvs.append(Vector2(uv_rect.end.x, uv_rect.end.y))
	uvs.append(Vector2(uv_rect.position.x, uv_rect.end.y))
	indices.append(base)
	indices.append(base + 1)
	indices.append(base + 2)
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 3)

func _build_right_flags(parent: Node3D) -> int:
	var specs := [
		{"s": 90.0, "u": -14.9, "height": 4.00, "material": "flag_red"},
		{"s": 98.0, "u": -14.7, "height": 3.80, "material": "flag_blue"},
		{"s": 106.0, "u": -14.5, "height": 3.60, "material": "flag_gold"},
		{"s": 114.0, "u": -14.2, "height": 3.40, "material": "flag_white"}
	]
	var count := 0
	for spec_value in specs:
		var spec: Dictionary = spec_value
		var s := float(spec["s"])
		if s < from_m or s > to_m:
			continue
		var u := float(spec["u"])
		var height := float(spec["height"])
		var anchor := _anchor(parent, s, u, "S01RightFlag_%03d" % int(s))
		var pole := _part(anchor, _cylinder(0.035, 0.045, height, 8), _materials["pole"], Vector3(0.0, height * 0.5, 0.0))
		pole.name = "Flagpole"
		var flag := _part(anchor, _box(Vector3(0.045, 0.58, 0.48)), _materials[String(spec["material"])], Vector3(0.12, height * 0.78, 0.0))
		flag.name = "FlagPanel"
		flag.set_meta("flag_color", String(spec["material"]))
		count += 1
	return count

func _part(parent: Node3D, mesh: Mesh, material: Material, position: Vector3, rotation := Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	instance.rotation = rotation
	parent.add_child(instance)
	return instance

func _box(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh

func _cylinder(top_radius: float, bottom_radius: float, height: float, segments := 8) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	mesh.radial_segments = segments
	return mesh

func _ground_offset_for_local_point(anchor: Node3D, local_point: Vector3) -> float:
	var world_point: Vector3 = anchor.global_transform * local_point
	var sample_s := route.distance_for_position(world_point)
	var route_point := route.pos_at(sample_s)
	var lateral := (world_point - route_point).dot(route.left_at(sample_s))
	var target_y := route.ground_y(sample_s, lateral)
	var local_up_y := maxf(anchor.global_transform.basis.y.y, 0.001)
	return (target_y - world_point.y) / local_up_y
