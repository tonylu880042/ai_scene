class_name SaisiesS02Shop
extends Node3D

## Isolated low shop observed in the S02 acceptance frame.
##
## The dimensions below are visual estimates from the source image, expressed
## in local metres for a later route placement. They are not GPS measurements.
## The source only exposes the front/gable and one long roof side; the rear
## facade and any real shop lettering remain intentionally unspecified.

@export var build_on_ready := true

const SOURCE_FRAME := "video/saisies_analysis/acceptance/S02_f000719.png"
const SOURCE_SHA256 := "3c692e306cd0ebcb6eb677f7b18678f8379e6c8bbdfdab782a2f32dd8fc3c958"

const SHOP_LENGTH := 7.4
const SHOP_WIDTH := 4.4
const STONE_HEIGHT := 0.42
const BASE_HEIGHT := 0.55
const WALL_HEIGHT := 2.45
const EAVE_Y := STONE_HEIGHT + BASE_HEIGHT + WALL_HEIGHT
const ROOF_RISE := 1.35
const ROOF_OVERHANG := 0.42

var shop_ready := false
var _materials: Dictionary = {}

func _ready() -> void:
	if build_on_ready:
		_build()

func _build() -> void:
	if shop_ready:
		return
	_make_materials()
	var shop := Node3D.new()
	shop.name = "S02LowShopBuilding"
	shop.set_meta("saisies_s02_shop_front_axis", "local -X")
	shop.set_meta("saisies_s02_shop_roof_axis", "local +X")
	shop.set_meta("saisies_s02_shop_dimensions_basis", "visual estimate from S02 source frame; not GPS")
	add_child(shop)

	# The opaque shell remains closed behind the front details. A low stone/plaster
	# base separates the shop from the street while dark timber carries the gable.
	_box(shop, "StonePlinth", Vector3(SHOP_LENGTH + 0.18, STONE_HEIGHT, SHOP_WIDTH + 0.18), Vector3(0.0, STONE_HEIGHT * 0.5, 0.0), _materials["stone"])
	_box(shop, "LightBase", Vector3(SHOP_LENGTH, BASE_HEIGHT, SHOP_WIDTH), Vector3(0.0, STONE_HEIGHT + BASE_HEIGHT * 0.5, 0.0), _materials["light_base"])
	_box(shop, "OpaqueTimberShell", Vector3(SHOP_LENGTH, WALL_HEIGHT, SHOP_WIDTH), Vector3(0.0, STONE_HEIGHT + BASE_HEIGHT + WALL_HEIGHT * 0.5, 0.0), _materials["dark_timber"])
	_mesh_instance(shop, "FrontGable", _make_gable_mesh(SHOP_LENGTH, SHOP_WIDTH, EAVE_Y, EAVE_Y + ROOF_RISE), Vector3.ZERO, _materials["dark_timber"])
	
	_add_front_shopfront(shop)
	_add_side_windows(shop)
	_add_roof(shop)
	_add_chimney_and_roof_fittings(shop)

	set_meta("saisies_s02_shop_ready", true)
	set_meta("saisies_s02_shop_source_frame", SOURCE_FRAME)
	set_meta("saisies_s02_shop_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s02_shop_dimensions_m", Vector3(SHOP_LENGTH, EAVE_Y + ROOF_RISE, SHOP_WIDTH))
	set_meta("saisies_s02_shop_footprint_m", Vector2(SHOP_LENGTH + ROOF_OVERHANG * 2.0, SHOP_WIDTH + ROOF_OVERHANG * 2.0))
	set_meta("saisies_s02_shop_roof_length_m", SHOP_LENGTH + ROOF_OVERHANG * 2.0)
	set_meta("saisies_s02_shop_roof_slope_deg", 28.0)
	set_meta("saisies_s02_shop_local_space", true)
	set_meta("saisies_s02_shop_opaque_shell", true)
	set_meta("saisies_s02_shop_has_people_or_vehicles", false)
	set_meta("saisies_s02_shop_unknowns", ["sign lettering", "rear facade beyond source view", "route/time placement"])
	shop_ready = true
	print("saisies s02 shop: local low-shop prefab ready source=%s footprint=%.1fx%.1fm" % [SOURCE_FRAME, SHOP_LENGTH, SHOP_WIDTH])

func _make_materials() -> void:
	_materials["dark_timber"] = _texture_mat("brown_planks_09", Color(0.42, 0.25, 0.15), 0.42)
	_materials["frame_timber"] = _texture_mat("wood_planks_grey", Color(0.56, 0.48, 0.37), 0.46)
	_materials["light_base"] = _texture_mat("painted_plaster_wall", Color(1.12, 1.02, 0.82), 0.56)
	_materials["stone"] = _texture_mat("old_stone_wall", Color(0.72, 0.69, 0.60), 0.58)
	# The source roof reads as a mid-grey painted/metal plane. A plain material
	# keeps the asphalt texture's dark albedo from multiplying it into a black
	# tile roof at native preview scale.
	_materials["roof"] = _mat(Color(0.47, 0.50, 0.52), 0.72, 0.08)
	_materials["roof_rib"] = _mat(Color(0.34, 0.37, 0.39), 0.70, 0.10)
	_materials["roof_under"] = _mat(Color(0.22, 0.19, 0.16), 0.88)
	_materials["dark_recess"] = _mat(Color(0.030, 0.040, 0.042), 0.82)
	_materials["glass"] = _mat(Color(0.035, 0.095, 0.115), 0.28)
	_materials["sign_panel"] = _mat(Color(0.075, 0.060, 0.047), 0.88)
	_materials["sign_face"] = _mat(Color(0.94, 0.89, 0.76), 0.78)
	_materials["metal"] = _mat(Color(0.48, 0.50, 0.49), 0.46, 0.35)

func _texture_mat(stem: String, tint: Color, roughness: float) -> StandardMaterial3D:
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

func _mat(color: Color, roughness: float, metallic := 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	return material

func _add_front_shopfront(shop: Node3D) -> void:
	var front_x := -SHOP_LENGTH * 0.5 - 0.055
	# A cream sign face and an unlettered dark plaque preserve the source's
	# commercial silhouette without inventing a brand name.
	var sign_y := STONE_HEIGHT + BASE_HEIGHT + WALL_HEIGHT - 0.38
	_box(shop, "FrontSignBacking", Vector3(0.14, 0.84, 3.55), Vector3(front_x - 0.045, sign_y, 0.0), _materials["sign_face"])
	_box(shop, "FrontSignPanel", Vector3(0.055, 0.58, 3.20), Vector3(front_x - 0.125, sign_y, 0.0), _materials["sign_face"])
	_box(shop, "FrontSignOutlineTop", Vector3(0.08, 0.06, 3.34), Vector3(front_x - 0.16, sign_y + 0.31, 0.0), _materials["sign_panel"])
	_box(shop, "FrontSignOutlineBottom", Vector3(0.08, 0.06, 3.34), Vector3(front_x - 0.16, sign_y - 0.31, 0.0), _materials["sign_panel"])
	_box(shop, "FrontSignOutlineLeft", Vector3(0.08, 0.68, 0.06), Vector3(front_x - 0.16, sign_y, -1.64), _materials["sign_panel"])
	_box(shop, "FrontSignOutlineRight", Vector3(0.08, 0.68, 0.06), Vector3(front_x - 0.16, sign_y, 1.64), _materials["sign_panel"])

	var door_y := STONE_HEIGHT + 1.03
	_box(shop, "FrontDoor", Vector3(0.12, 2.00, 0.92), Vector3(front_x - 0.085, door_y, 0.0), _materials["dark_recess"])
	_box(shop, "FrontDoorFrameLeft", Vector3(0.15, 2.12, 0.11), Vector3(front_x - 0.16, door_y, -0.55), _materials["frame_timber"])
	_box(shop, "FrontDoorFrameRight", Vector3(0.15, 2.12, 0.11), Vector3(front_x - 0.16, door_y, 0.55), _materials["frame_timber"])
	_box(shop, "FrontDoorLintel", Vector3(0.15, 0.14, 1.28), Vector3(front_x - 0.16, door_y + 1.10, 0.0), _materials["light_base"])
	_cylinder(shop, "FrontDoorHandle", 0.035, 0.035, 0.16, Vector3(front_x - 0.18, door_y, 0.23), Vector3(PI * 0.5, 0.0, 0.0), _materials["metal"])

	for index in range(2):
		var z := -1.30 + float(index) * 2.60
		var window_name := "FrontWindow_%02d" % index
		_box(shop, window_name, Vector3(0.10, 1.10, 0.94), Vector3(front_x - 0.08, STONE_HEIGHT + 1.92, z), _materials["glass"])
		_box(shop, "%sFrameTop" % window_name, Vector3(0.15, 0.10, 1.10), Vector3(front_x - 0.15, STONE_HEIGHT + 2.52, z), _materials["frame_timber"])
		_box(shop, "%sFrameBottom" % window_name, Vector3(0.15, 0.10, 1.10), Vector3(front_x - 0.15, STONE_HEIGHT + 1.32, z), _materials["frame_timber"])
		_box(shop, "%sFrameLeft" % window_name, Vector3(0.15, 1.22, 0.10), Vector3(front_x - 0.15, STONE_HEIGHT + 1.92, z - 0.53), _materials["frame_timber"])
		_box(shop, "%sFrameRight" % window_name, Vector3(0.15, 1.22, 0.10), Vector3(front_x - 0.15, STONE_HEIGHT + 1.92, z + 0.53), _materials["frame_timber"])

func _add_side_windows(shop: Node3D) -> void:
	var side_z := SHOP_WIDTH * 0.5 + 0.055
	for index in range(2):
		var x := -1.05 + float(index) * 2.25
		var window_name := "SideWindow_%02d" % index
		_box(shop, window_name, Vector3(1.10, 1.08, 0.10), Vector3(x, STONE_HEIGHT + 1.88, side_z), _materials["glass"])
		_box(shop, "%sFrameTop" % window_name, Vector3(1.26, 0.10, 0.15), Vector3(x, STONE_HEIGHT + 2.49, side_z + 0.06), _materials["frame_timber"])
		_box(shop, "%sFrameBottom" % window_name, Vector3(1.26, 0.10, 0.15), Vector3(x, STONE_HEIGHT + 1.27, side_z + 0.06), _materials["frame_timber"])
		_box(shop, "%sFrameLeft" % window_name, Vector3(0.10, 1.20, 0.15), Vector3(x - 0.63, STONE_HEIGHT + 1.88, side_z + 0.06), _materials["frame_timber"])
		_box(shop, "%sFrameRight" % window_name, Vector3(0.10, 1.20, 0.15), Vector3(x + 0.63, STONE_HEIGHT + 1.88, side_z + 0.06), _materials["frame_timber"])

func _add_roof(shop: Node3D) -> void:
	var angle := deg_to_rad(28.0)
	var half_span := SHOP_WIDTH * 0.5 + ROOF_OVERHANG
	var slope_length := half_span / cos(angle)
	var roof_length := SHOP_LENGTH + ROOF_OVERHANG * 2.0
	var center_y := EAVE_Y + half_span * 0.5 * tan(angle)
	# Rotation signs are opposite on the two sides: after Godot's X rotation,
	# each local inner edge must rise toward the local-Z ridge.
	_box_rot(shop, "RoofSlopeNegZ", Vector3(roof_length, 0.20, slope_length), Vector3(0.0, center_y, -half_span * 0.5), Vector3(-angle, 0.0, 0.0), _materials["roof"])
	_box_rot(shop, "RoofSlopePosZ", Vector3(roof_length, 0.20, slope_length), Vector3(0.0, center_y, half_span * 0.5), Vector3(angle, 0.0, 0.0), _materials["roof"])
	_box(shop, "RoofRidgeCap", Vector3(roof_length + 0.18, 0.24, 0.30), Vector3(0.0, EAVE_Y + half_span * tan(angle) + 0.07, 0.0), _materials["roof"])
	_box(shop, "FrontEaveBeam", Vector3(0.18, 0.18, SHOP_WIDTH + ROOF_OVERHANG * 2.0), Vector3(-SHOP_LENGTH * 0.5 - ROOF_OVERHANG + 0.06, EAVE_Y + 0.04, 0.0), _materials["light_base"])
	_box(shop, "RearEaveBeam", Vector3(0.18, 0.18, SHOP_WIDTH + ROOF_OVERHANG * 2.0), Vector3(SHOP_LENGTH * 0.5 + ROOF_OVERHANG - 0.06, EAVE_Y + 0.04, 0.0), _materials["roof_under"])
	for side in [-1.0, 1.0]:
		var side_f: float = float(side)
		for index in range(1, 4):
			var fraction := 0.18 + float(index) * 0.18
			var rib_z := side_f * half_span * fraction
			var rib_y := EAVE_Y + (half_span - absf(rib_z)) * tan(angle) + 0.035
			_box_rot(shop, "RoofRib_%s_%02d" % ["NegZ" if side_f < 0.0 else "PosZ", index], Vector3(roof_length - 0.22, 0.055, 0.065), Vector3(0.0, rib_y, rib_z), Vector3(side_f * angle, 0.0, 0.0), _materials["roof_rib"])
	set_meta("saisies_s02_shop_roof_length_m", roof_length)
	set_meta("saisies_s02_shop_roof_slope_deg", 28.0)

func _add_chimney_and_roof_fittings(shop: Node3D) -> void:
	var angle := deg_to_rad(28.0)
	var half_span := SHOP_WIDTH * 0.5 + ROOF_OVERHANG
	var chimney_z := 0.62
	var roof_y_at_chimney := EAVE_Y + (half_span - absf(chimney_z)) * tan(angle)
	_box(shop, "Chimney", Vector3(0.48, 1.10, 0.48), Vector3(1.25, roof_y_at_chimney + 0.44, chimney_z), _materials["stone"])
	_box(shop, "ChimneyCap", Vector3(0.68, 0.12, 0.58), Vector3(1.25, roof_y_at_chimney + 1.02, chimney_z), _materials["roof_under"])
	var vent_z := -0.82
	var roof_y_at_vent := EAVE_Y + (half_span - absf(vent_z)) * tan(angle)
	_box(shop, "RoofVent", Vector3(0.30, 0.40, 0.42), Vector3(2.25, roof_y_at_vent + 0.20, vent_z), _materials["roof_under"])
	_box(shop, "RoofVentCap", Vector3(0.48, 0.08, 0.58), Vector3(2.25, roof_y_at_vent + 0.44, vent_z), _materials["metal"])

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

func _cylinder(parent: Node3D, node_name: String, top: float, bottom: float, height: float, position: Vector3, rotation: Vector3, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top
	mesh.bottom_radius = bottom
	mesh.height = height
	mesh.radial_segments = 12
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

func _make_gable_mesh(depth: float, width: float, base_y: float, ridge_y: float) -> ArrayMesh:
	var half_depth := depth * 0.5
	var half_width := width * 0.5
	var front_left := Vector3(-half_depth, base_y, -half_width)
	var front_right := Vector3(-half_depth, base_y, half_width)
	var front_peak := Vector3(-half_depth, ridge_y, 0.0)
	var back_left := Vector3(half_depth, base_y, -half_width)
	var back_right := Vector3(half_depth, base_y, half_width)
	var back_peak := Vector3(half_depth, ridge_y, 0.0)
	# The front gable is ordered for an outward -X normal. The remaining side
	# triangles follow the outward normals so the closed shell remains cull-safe.
	var faces := [
		[front_left, front_right, front_peak],
		[back_left, back_peak, back_right],
		[front_left, front_peak, back_peak], [front_left, back_peak, back_left],
		[front_right, back_right, back_peak], [front_right, back_peak, front_peak]
	]
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in faces:
		for point: Vector3 in face:
			surface.set_uv(Vector2(point.x / maxf(depth, 0.01) + 0.5, point.y / maxf(ridge_y, 0.01)))
			surface.add_vertex(point)
	surface.generate_normals()
	return surface.commit()
