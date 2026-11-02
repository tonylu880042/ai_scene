class_name SaisiesRoadsideChalets
extends Node3D

## Two adjoining alpine timber chalets observed in Saisies source frames 336/337.
## The prefab is intentionally self-contained: a parent scene can place this
## node on a flat route datum without needing route or terrain dependencies.

@export var build_on_ready := true

const CHALET_WIDTH := 6.5
const CHALET_DEPTH := 7.0
const LOWER_HEIGHT := 2.2
const UPPER_HEIGHT := 2.3
const EAVE_Y := LOWER_HEIGHT + UPPER_HEIGHT
const ROOF_RISE := 2.0
const EAVE_OVERHANG := 0.42
const BALCONY_Y := 2.92

var chalets_ready := false
var _materials: Dictionary = {}
var _gable_mesh: ArrayMesh

func _ready() -> void:
	if build_on_ready:
		_build()

func _build() -> void:
	if chalets_ready:
		return
	_make_materials()
	_gable_mesh = _make_gable_mesh(CHALET_WIDTH, EAVE_Y, EAVE_Y + ROOF_RISE, CHALET_DEPTH)
	var group := Node3D.new()
	group.name = "AdjoiningAlpineChalets"
	add_child(group)
	# The nearer chalet is offset toward the camera. The second chalet steps
	# 1.3 m back and right, matching the stagger visible in frame 336.
	_build_chalet(group, "NearChalet", Vector3(-3.6, 0.0, 0.0), false)
	_build_chalet(group, "RearChalet", Vector3(3.6, 0.0, 1.3), true)
	chalets_ready = true
	set_meta("saisies_roadside_chalets_ready", true)
	set_meta("saisies_roadside_chalets_count", 2)
	set_meta("saisies_roadside_chalets_front_axis", "local -Z")
	set_meta("saisies_roadside_chalets_ridge_axis", "local Z")
	set_meta("saisies_roadside_chalets_footprint_m", Vector3(14.1, 6.5, 8.72))
	set_meta("saisies_roadside_chalets_texture_set", [
		"brown_planks_09", "wood_planks_grey", "painted_plaster_wall",
		"old_stone_wall", "asphalt_02"
	])
	print("saisies roadside chalets: built two staggered 6.5x7m alpine timber houses")

## Optional terrain adapter. Keep floors level, then extend each stone base to
## the visible terrain instead of grounding only the adjoining group's origin.
func fit_foundations(sample_ground: Callable, fit_bottom: Callable, embed_depth_m := 0.08) -> Dictionary:
	var houses: Array = []
	var fitted_parts := 0
	for house_name in ["NearChalet", "RearChalet"]:
		var house := get_node("AdjoiningAlpineChalets/" + house_name) as Node3D
		var supports: Array[MeshInstance3D] = []
		var lift := 0.0
		for child in house.get_children():
			if not child is MeshInstance3D or not (String(child.name) == "StonePlinth" or String(child.name).begins_with("RetainingStone")):
				continue
			var part := child as MeshInstance3D
			if not part.mesh is BoxMesh:
				return {"passed": false, "reason": "foundation already fitted or not a box"}
			var box := part.mesh.duplicate() as BoxMesh
			# A dense bottom grid also supports the edges between the four corners.
			box.subdivide_width = maxi(int(ceil(box.size.x / 0.5)) - 1, 0)
			box.subdivide_depth = maxi(int(ceil(box.size.z / 0.5)) - 1, 0)
			part.mesh = box
			supports.append(part)
			var vertices: PackedVector3Array = box.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			for vertex in vertices:
				if vertex.y > -box.size.y * 0.5 + 0.002:
					continue
				var point := part.global_transform * vertex
				var ground: Dictionary = sample_ground.call(Vector2(point.x, point.z))
				if ground.is_empty() or not ground.has("height"):
					return {"passed": false, "reason": "foundation footprint has no visible terrain"}
				var top := part.global_transform * Vector3(vertex.x, box.size.y * 0.5, vertex.z)
				lift = maxf(lift, float(ground["height"]) + 0.06 - top.y)
		# Determine the final floor height before fitting any bases: moving the
		# house after a base was fitted would lift that base off the ground again.
		house.global_position.y += lift
		for part in supports:
			if not bool(fit_bottom.call(part, embed_depth_m, false)):
				return {"passed": false, "reason": "foundation mesh fitting failed"}
			fitted_parts += 1
		houses.append({"house": house_name, "floor_lift_m": lift, "support_parts": supports.size()})
	var report := {"passed": true, "houses": houses, "support_parts": fitted_parts, "embed_depth_m": embed_depth_m}
	set_meta("saisies_chalet_foundations", report)
	return report

func _make_materials() -> void:
	_materials["dark_timber"] = _texture_mat("brown_planks_09", Color(0.54, 0.34, 0.22), 0.34)
	_materials["weathered_timber"] = _texture_mat("wood_planks_grey", Color(0.68, 0.67, 0.61), 0.30)
	_materials["plaster"] = _texture_mat("painted_plaster_wall", Color(0.92, 0.89, 0.79), 0.50)
	_materials["stone"] = _texture_mat("old_stone_wall", Color(0.70, 0.67, 0.59), 0.46)
	_materials["roof"] = _texture_mat("asphalt_02", Color(0.73, 0.76, 0.78), 0.72)
	_materials["warm_wood"] = _texture_mat("brown_planks_09", Color(0.72, 0.46, 0.25), 0.32)
	_materials["seam"] = _mat(Color(0.105, 0.068, 0.045), 0.92)
	_materials["dark_recess"] = _mat(Color(0.035, 0.040, 0.038), 0.80)
	_materials["shutter_red"] = _mat(Color(0.48, 0.075, 0.048), 0.78)
	_materials["frame"] = _mat(Color(0.18, 0.115, 0.070), 0.82)
	_materials["roof_underside"] = _mat(Color(0.47, 0.27, 0.13), 0.88)

func _texture_mat(stem: String, tint: Color, scale: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = load("res://assets/textures/%s_diff.jpg" % stem)
	material.normal_enabled = true
	material.normal_texture = load("res://assets/textures/%s_nor.jpg" % stem)
	material.roughness_texture = load("res://assets/textures/%s_rough.jpg" % stem)
	material.albedo_color = tint
	material.roughness = 0.84
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * scale
	return material

func _mat(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material

func _build_chalet(parent: Node3D, chalet_name: String, origin: Vector3, rear_plaster: bool) -> void:
	var chalet := Node3D.new()
	chalet.name = chalet_name
	chalet.position = origin
	chalet.set_meta("front_face", "-Z")
	chalet.set_meta("ridge_axis", "Z")
	parent.add_child(chalet)

	var lower_material: Material = _materials["plaster"] if rear_plaster else _materials["weathered_timber"]
	# Both buildings have a real low stone plinth. The rear house continues this
	# into an uneven retaining platform rather than sitting on a floating slab.
	_box(chalet, "StonePlinth", Vector3(CHALET_WIDTH + 0.16, 0.42, CHALET_DEPTH + 0.16), Vector3(0, 0.21, 0), _materials["stone"])
	_box(chalet, "LowerFloor", Vector3(CHALET_WIDTH, LOWER_HEIGHT - 0.18, CHALET_DEPTH), Vector3(0, 0.42 + (LOWER_HEIGHT - 0.18) * 0.5, 0), lower_material)
	_box(chalet, "UpperTimber", Vector3(CHALET_WIDTH, UPPER_HEIGHT, CHALET_DEPTH), Vector3(0, LOWER_HEIGHT + UPPER_HEIGHT * 0.5, 0), _materials["dark_timber"])
	_mesh_instance(chalet, "FrontGable", _gable_mesh, Vector3.ZERO, _materials["dark_timber"])

	_add_timber_details(chalet)
	_add_roof(chalet)
	_add_balcony(chalet, rear_plaster)
	if rear_plaster:
		_add_rear_facade(chalet)
		_add_retaining_platform(chalet)
	else:
		_add_near_facade(chalet)

func _add_timber_details(chalet: Node3D) -> void:
	var front_z := -CHALET_DEPTH * 0.5 - 0.016
	var back_z := CHALET_DEPTH * 0.5 + 0.016
	# Deliberately broad seams make the weathered plank scale read at route
	# distance; the textured boxes provide the smaller grain between each seam.
	for index in range(1, 7):
		var y := LOWER_HEIGHT + 0.23 + float(index) * 0.32
		_box(chalet, "FrontPlankSeam%02d" % index, Vector3(CHALET_WIDTH - 0.18, 0.026, 0.026), Vector3(0, y, front_z), _materials["seam"])
		_box(chalet, "BackPlankSeam%02d" % index, Vector3(CHALET_WIDTH - 0.18, 0.026, 0.026), Vector3(0, y, back_z), _materials["seam"])
		_box(chalet, "LeftPlankSeam%02d" % index, Vector3(0.026, 0.026, CHALET_DEPTH - 0.18), Vector3(-CHALET_WIDTH * 0.5 - 0.016, y, 0), _materials["seam"])
		_box(chalet, "RightPlankSeam%02d" % index, Vector3(0.026, 0.026, CHALET_DEPTH - 0.18), Vector3(CHALET_WIDTH * 0.5 + 0.016, y, 0), _materials["seam"])
	for x in [-CHALET_WIDTH * 0.5 + 0.14, CHALET_WIDTH * 0.5 - 0.14]:
		_box(chalet, "CornerPost_%s" % str(x), Vector3(0.25, UPPER_HEIGHT + 0.08, 0.25), Vector3(x, LOWER_HEIGHT + UPPER_HEIGHT * 0.5, front_z + 0.02), _materials["warm_wood"])
		_box(chalet, "RearCornerPost_%s" % str(x), Vector3(0.25, UPPER_HEIGHT + 0.08, 0.25), Vector3(x, LOWER_HEIGHT + UPPER_HEIGHT * 0.5, back_z - 0.02), _materials["warm_wood"])
	_box(chalet, "UpperWallBeam", Vector3(CHALET_WIDTH + 0.16, 0.20, 0.28), Vector3(0, LOWER_HEIGHT + 0.03, front_z + 0.03), _materials["warm_wood"])
	_box(chalet, "UpperWallBeamBack", Vector3(CHALET_WIDTH + 0.16, 0.20, 0.28), Vector3(0, LOWER_HEIGHT + 0.03, back_z - 0.03), _materials["warm_wood"])

func _add_roof(chalet: Node3D) -> void:
	var half_span := CHALET_WIDTH * 0.5 + EAVE_OVERHANG
	var slope_angle := atan2(ROOF_RISE, half_span)
	var slope_length := sqrt(half_span * half_span + ROOF_RISE * ROOF_RISE)
	var roof_depth := CHALET_DEPTH + EAVE_OVERHANG * 2.0
	var roof_center_y := EAVE_Y + ROOF_RISE * 0.5
	_box_rot(chalet, "RoofLeft", Vector3(slope_length, 0.22, roof_depth), Vector3(-half_span * 0.5, roof_center_y, 0), Vector3(0, 0, slope_angle), _materials["roof"])
	_box_rot(chalet, "RoofRight", Vector3(slope_length, 0.22, roof_depth), Vector3(half_span * 0.5, roof_center_y, 0), Vector3(0, 0, -slope_angle), _materials["roof"])
	# Warm boards remain visible below the wide eaves and make the roof read as
	# a timber assembly instead of a single dark wedge.
	_box_rot(chalet, "RoofUnderLeft", Vector3(slope_length - 0.06, 0.055, roof_depth - 0.03), Vector3(-half_span * 0.5, roof_center_y - 0.125, 0), Vector3(0, 0, slope_angle), _materials["roof_underside"])
	_box_rot(chalet, "RoofUnderRight", Vector3(slope_length - 0.06, 0.055, roof_depth - 0.03), Vector3(half_span * 0.5, roof_center_y - 0.125, 0), Vector3(0, 0, -slope_angle), _materials["roof_underside"])
	_add_roof_ribs(chalet, half_span, roof_depth, slope_angle)
	_box(chalet, "RidgeCap", Vector3(0.28, 0.22, roof_depth + 0.08), Vector3(0, EAVE_Y + ROOF_RISE + 0.06, 0), _materials["roof"])
	_box(chalet, "FrontEaveBeam", Vector3(CHALET_WIDTH + EAVE_OVERHANG * 2.0, 0.18, 0.18), Vector3(0, EAVE_Y + 0.03, -CHALET_DEPTH * 0.5 - EAVE_OVERHANG + 0.04), _materials["warm_wood"])

func _add_roof_ribs(chalet: Node3D, half_span: float, roof_depth: float, slope_angle: float) -> void:
	# Raised parallel ribs stand in for the ridges visible in the dark roof while
	# the asphalt texture supplies quiet weathering between them.
	for branch in [-1.0, 1.0]:
		for index in range(1, 7):
			var fraction := 0.08 + float(index) * 0.13
			var x_abs := half_span * fraction
			var y := EAVE_Y + ROOF_RISE * (1.0 - x_abs / half_span) + 0.04
			var rotation_z := slope_angle if branch < 0.0 else -slope_angle
			_box_rot(chalet, "RoofRib_%s_%02d" % [str(branch), index], Vector3(0.075, 0.060, roof_depth - 0.10), Vector3(branch * x_abs, y, 0), Vector3(0, 0, rotation_z), _materials["roof"])

func _add_balcony(chalet: Node3D, rear_plaster: bool) -> void:
	var width := CHALET_WIDTH - (0.70 if rear_plaster else 0.46)
	var outer_z := -CHALET_DEPTH * 0.5 - 0.98
	var center_z := -CHALET_DEPTH * 0.5 - 0.43
	_box(chalet, "BalconyFloor", Vector3(width, 0.18, 1.08), Vector3(0, BALCONY_Y, center_z), _materials["warm_wood"])
	_box(chalet, "BalconyFrontBeam", Vector3(width + 0.10, 0.18, 0.16), Vector3(0, BALCONY_Y - 0.12, outer_z), _materials["warm_wood"])
	for x in [-width * 0.5 + 0.10, width * 0.5 - 0.10]:
		for z in [outer_z + 0.04, -CHALET_DEPTH * 0.5 + 0.03]:
			_box(chalet, "BalconyPost_%s_%s" % [str(x), str(z)], Vector3(0.17, 1.30, 0.17), Vector3(x, BALCONY_Y + 0.65, z), _materials["warm_wood"])
	for rail_y in [BALCONY_Y + 0.58, BALCONY_Y + 1.00]:
		_box(chalet, "BalconyFrontRail_%s" % str(rail_y), Vector3(width, 0.12, 0.12), Vector3(0, rail_y, outer_z), _materials["warm_wood"])
	for x in [-width * 0.25, 0.0, width * 0.25]:
		_box(chalet, "BalconyBaluster_%s" % str(x), Vector3(0.095, 0.98, 0.095), Vector3(x, BALCONY_Y + 0.54, outer_z), _materials["warm_wood"])

func _add_near_facade(chalet: Node3D) -> void:
	var z := -CHALET_DEPTH * 0.5 - 0.055
	# A red shutter panel is the visible colour accent on the nearer chalet.
	_box(chalet, "NearWindowRecess", Vector3(1.10, 1.22, 0.08), Vector3(-1.48, 1.28, z), _materials["dark_recess"])
	_box(chalet, "RedShutterLeft", Vector3(0.34, 1.27, 0.10), Vector3(-2.04, 1.28, z - 0.045), _materials["shutter_red"])
	_box(chalet, "RedShutterRight", Vector3(0.34, 1.27, 0.10), Vector3(-0.92, 1.28, z - 0.045), _materials["shutter_red"])
	_box(chalet, "NearWindowLintel", Vector3(1.25, 0.11, 0.12), Vector3(-1.48, 1.94, z - 0.045), _materials["frame"])
	_box(chalet, "NearDoor", Vector3(0.86, 1.58, 0.11), Vector3(1.42, 0.92, z - 0.04), _materials["warm_wood"])
	for index in range(1, 4):
		_box(chalet, "NearDoorSeam%02d" % index, Vector3(0.73, 0.025, 0.025), Vector3(1.42, 0.46 + index * 0.30, z - 0.105), _materials["seam"])

func _add_rear_facade(chalet: Node3D) -> void:
	var z := -CHALET_DEPTH * 0.5 - 0.055
	# Frame 337 exposes two narrow dark windows beside a warm timber door.
	for index in range(2):
		var x := -1.72 + float(index) * 1.00
		_box(chalet, "TallWindowRecess%02d" % index, Vector3(0.52, 1.40, 0.09), Vector3(x, 1.26, z), _materials["dark_recess"])
		_box(chalet, "TallWindowFrameTop%02d" % index, Vector3(0.68, 0.10, 0.11), Vector3(x, 2.01, z - 0.045), _materials["frame"])
		_box(chalet, "TallWindowFrameLeft%02d" % index, Vector3(0.09, 1.48, 0.11), Vector3(x - 0.31, 1.26, z - 0.045), _materials["frame"])
		_box(chalet, "TallWindowFrameRight%02d" % index, Vector3(0.09, 1.48, 0.11), Vector3(x + 0.31, 1.26, z - 0.045), _materials["frame"])
	_box(chalet, "RearDoor", Vector3(0.86, 1.58, 0.12), Vector3(1.45, 0.92, z - 0.04), _materials["warm_wood"])
	for index in range(1, 4):
		_box(chalet, "RearDoorSeam%02d" % index, Vector3(0.73, 0.025, 0.025), Vector3(1.45, 0.46 + index * 0.30, z - 0.105), _materials["seam"])
	_box(chalet, "RearDoorFrame", Vector3(1.00, 0.11, 0.13), Vector3(1.45, 1.76, z - 0.055), _materials["frame"])

func _add_retaining_platform(chalet: Node3D) -> void:
	var z := -CHALET_DEPTH * 0.5 - 0.22
	for index in range(7):
		var x := -CHALET_WIDTH * 0.5 - 0.25 + float(index) * 1.05
		var stone_height := 0.30 + float(index % 2) * 0.12
		_box_rot(chalet, "RetainingStoneFront%02d" % index, Vector3(1.28, stone_height, 0.58), Vector3(x, stone_height * 0.5, z), Vector3(0, float(index % 3 - 1) * 0.08, 0), _materials["stone"])
	for index in range(5):
		var zz := -2.35 + float(index) * 1.15
		_box_rot(chalet, "RetainingStoneSide%02d" % index, Vector3(0.58, 0.42, 1.22), Vector3(CHALET_WIDTH * 0.5 + 0.22, 0.21 + float(index % 2) * 0.05, zz), Vector3(0, float(index % 2) * 0.08, 0), _materials["stone"])

func _box(parent: Node3D, node_name: String, size: Vector3, position: Vector3, material: Material) -> MeshInstance3D:
	return _box_rot(parent, node_name, size, position, Vector3.ZERO, material)

func _box_rot(parent: Node3D, node_name: String, size: Vector3, position: Vector3, rotation: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	instance.rotation = rotation
	parent.add_child(instance)
	return instance

func _mesh_instance(parent: Node3D, node_name: String, mesh: Mesh, position: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	parent.add_child(instance)
	return instance

func _make_gable_mesh(width: float, base_y: float, ridge_y: float, depth: float) -> ArrayMesh:
	var half_width := width * 0.5
	var half_depth := depth * 0.5
	var front_left := Vector3(-half_width, base_y, -half_depth)
	var front_right := Vector3(half_width, base_y, -half_depth)
	var front_peak := Vector3(0, ridge_y, -half_depth)
	var back_left := Vector3(-half_width, base_y, half_depth)
	var back_right := Vector3(half_width, base_y, half_depth)
	var back_peak := Vector3(0, ridge_y, half_depth)
	# Front triangle is ordered for an outward -Z normal (Godot's clockwise
	# front-face convention); the back and side quads follow outward normals.
	var faces := [
		[front_left, front_peak, front_right],
		[back_left, back_right, back_peak],
		[front_left, back_left, back_right], [front_left, back_right, front_right],
		[front_left, front_peak, back_peak], [front_left, back_peak, back_left],
		[front_right, back_right, back_peak], [front_right, back_peak, front_peak]
	]
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in faces:
		for point: Vector3 in face:
			surface.set_uv(Vector2(point.x / width + 0.5, point.y / maxf(ridge_y, 0.01)))
			surface.add_vertex(point)
	surface.generate_normals()
	return surface.commit()
