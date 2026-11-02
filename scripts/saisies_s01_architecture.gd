extends Node3D

## S01 review-only local architecture refinement.
##
## The parent scene instances the frozen R14 baked world.  This node keeps the
## baked anchors and their WORLD positions, hides only the S01 proxy visuals,
## and adds a small, named set of real facade, roof, window, porch, flag, and
## log-planter meshes beneath those anchors.  It does not touch route, terrain,
## camera, OSM buildings, or the R14 source scene on disk.

@export var world_path: NodePath = NodePath("../World")
@export var build_on_ready := true
@export var restaurant_awning_y_offset_m := -0.77
@export var restaurant_awning_pitch_deg := 4.0
@export var rear_hotel_height_scale := 1.18
@export var rear_hotel_local_z_offset_m := -0.80
@export var flowerbox_scale := 0.65

const S01_SUN_YAW_DEG := 148.0

var _world: Node3D
var _materials: Dictionary = {}
var _build_attempts := 0
var _built := false
var _lodge_face_attempts := 0
var _lodge_visible_detail_built := false

const RESTAURANT_DEPTH := 8.8
const RESTAURANT_WIDTH := 27.0
const HOTEL_DEPTH := 9.6
const HOTEL_WIDTH := 16.0
const LODGE_DEPTH := 8.0
const LODGE_WIDTH := 18.5
const LODGE_ROOF_DEPTH := 12.0
const LODGE_GROUP_YAW_DEG := 90.0
const LODGE_LONG_SCALE := 0.72
const LODGE_LATERAL_SHIFT_M := 4.50
const LODGE_GROUND_FLOOR_HEIGHT := 2.62
const LODGE_UPPER_FLOOR_HEIGHT := 4.30
const FACADE_ATLAS_SIZE := Vector2(1774.0, 887.0)

func _ready() -> void:
	if build_on_ready:
		call_deferred("_build_when_ready")

func _build_when_ready() -> void:
	if _built:
		return
	_world = get_node_or_null(world_path) as Node3D
	if _world == null:
		_build_attempts += 1
		if _build_attempts < 40:
			call_deferred("_build_when_ready")
		else:
			push_error("Saisies S01 architecture could not resolve world_path %s" % world_path)
		return
	var buildings := _world.get_node_or_null("VillageS01S02/S01S02Buildings") as Node3D
	if buildings == null:
		_build_attempts += 1
		if _build_attempts < 40:
			call_deferred("_build_when_ready")
		else:
			push_error("Saisies S01 architecture could not resolve VillageS01S02/S01S02Buildings")
		return
	_apply_s01_sun_override()
	_make_materials()
	var refinement := Node3D.new()
	refinement.name = "S01Refinement"
	refinement.set_meta("saisies_s01_review_scope", "0..220m local architecture only")
	refinement.set_meta("saisies_s01_source_frame", "video/saisies_analysis/acceptance/S01_f000120.png")
	refinement.set_meta("saisies_s01_geometry_basis", "R14 authored anchors preserved; local facade detail refinement")
	add_child(refinement)

	var restaurant := buildings.get_node_or_null("Restaurant_Ravoula") as Node3D
	var hotel := buildings.get_node_or_null("Rear_Hotel") as Node3D
	var lodge := buildings.get_node_or_null("Right_Alpine_Lodge") as Node3D
	var middle_a := buildings.get_node_or_null("S01MiddleHouse_A") as Node3D
	var middle_b := buildings.get_node_or_null("S01MiddleHouse_B") as Node3D
	var middle_c := buildings.get_node_or_null("S01MiddleHouse_C") as Node3D
	if restaurant != null:
		_refine_restaurant(restaurant)
	if hotel != null:
		_refine_hotel(hotel)
	if lodge != null:
		_refine_lodge(lodge)
	if middle_a != null:
		_refine_middle_house(middle_a, "A", 9.5, 6.2, 2, _materials["cream_light"], _materials["roof_metal"])
	if middle_b != null:
		_refine_middle_house(middle_b, "B", 10.5, 6.0, 2, _materials["timber_grey"], _materials["roof_dark"])
	if middle_c != null:
		_refine_middle_house(middle_c, "C", 8.5, 5.8, 1, _materials["cream"], _materials["roof_metal"])
	_refine_flowerboxes()
	set_meta("saisies_s01_architecture_ready", true)
	set_meta("saisies_s01_original_world_path", str(world_path))
	set_meta("saisies_s01_anchor_count", 6)
	_built = true
	# Camera C is applied by the sibling runtime controller after this node's
	# first deferred build.  Add the lodge detail once that live camera exists so
	# the windows and low porch are placed on the actually visible local face.
	call_deferred("_add_camera_visible_lodge_detail")

func _apply_s01_sun_override() -> void:
	# The selected lighting candidate belongs only to this instantiated review
	# World.  Preserve the frozen light's elevation, roll, energy, and colour;
	# changing the live instance here does not rewrite the R14 PackedScene.
	var sun := _world.get_node_or_null("Sun") as DirectionalLight3D
	if sun == null:
		set_meta("saisies_s01_sun_override_applied", false)
		set_meta("saisies_s01_sun_override_status", "missing_world_sun")
		return
	var rotation := sun.rotation_degrees
	rotation.y = S01_SUN_YAW_DEG
	sun.rotation_degrees = rotation
	sun.set_meta("saisies_s01_review_sun_override", true)
	sun.set_meta("saisies_s01_review_sun_yaw_deg", S01_SUN_YAW_DEG)
	set_meta("saisies_s01_sun_override_applied", true)
	set_meta("saisies_s01_sun_override_status", "review_world_instance_only")
	set_meta("saisies_s01_sun_yaw_deg", S01_SUN_YAW_DEG)

func _make_materials() -> void:
	_materials["cream"] = _texture_material("painted_plaster_wall", Color(1.16, 1.04, 0.84, 1.0), 0.84)
	_materials["cream_light"] = _texture_material("painted_plaster_wall", Color(1.30, 1.18, 0.96, 1.0), 0.82)
	_materials["timber"] = _texture_material("brown_planks_09", Color(0.68, 0.39, 0.20, 1.0), 0.88)
	_materials["timber_dark"] = _texture_material("brown_planks_09", Color(0.30, 0.16, 0.08, 1.0), 0.92)
	_materials["timber_grey"] = _texture_material("wood_planks_grey", Color(0.34, 0.34, 0.31, 1.0), 0.90)
	# S01's exposed planter frame is weathered grey-brown timber.  Keep it
	# separate from the warmer legacy deck material so the supports do not read
	# as orange ground props in the source-facing view.
	_materials["weathered_timber"] = _texture_material("wood_planks_grey", Color(0.27, 0.28, 0.25, 1.0), 0.94)
	_materials["restaurant_facade_atlas"] = _facade_atlas_material(0.88)
	_materials["hotel_plaster"] = _texture_material("painted_plaster_wall", Color(0.22, 0.26, 0.24, 1.0), 0.91)
	_materials["stone"] = _texture_material("stacked_stone_wall", Color(0.84, 0.82, 0.73, 1.0), 0.96)
	_materials["roof_metal"] = _simple_material(Color(0.47, 0.50, 0.50, 1.0), 0.86, 0.28)
	_materials["roof_dark"] = _simple_material(Color(0.12, 0.14, 0.14, 1.0), 0.92, 0.08)
	_materials["roof_seam"] = _simple_material(Color(0.27, 0.29, 0.29, 1.0), 0.76, 0.36)
	_materials["glass"] = _simple_material(Color(0.035, 0.12, 0.16, 1.0), 0.17, 0.08)
	_materials["glass_upper"] = _simple_material(Color(0.10, 0.24, 0.30, 1.0), 0.18, 0.08)
	_materials["glass_warm"] = _simple_material(Color(0.055, 0.14, 0.14, 1.0), 0.20, 0.05)
	_materials["store_glass"] = _glass_material(Color(0.15, 0.30, 0.34, 1.0), 0.30)
	_materials["interior"] = _simple_material(Color(0.035, 0.030, 0.026, 1.0), 0.94)
	_materials["interior_warm"] = _simple_material(Color(0.12, 0.085, 0.055, 1.0), 0.92)
	_materials["white"] = _simple_material(Color(0.94, 0.92, 0.84, 1.0), 0.80)
	_materials["awning"] = _simple_material(Color(0.98, 0.94, 0.82, 1.0), 0.78)
	_materials["awning_shadow"] = _simple_material(Color(0.58, 0.42, 0.26, 1.0), 0.88)
	_materials["metal"] = _simple_material(Color(0.55, 0.60, 0.61, 1.0), 0.38, 0.52)
	_materials["soil"] = _simple_material(Color(0.22, 0.13, 0.07, 1.0), 1.0)
	_materials["leaf"] = _simple_material(Color(0.18, 0.40, 0.13, 1.0), 0.94)
	_materials["flower_pink"] = _simple_material(Color(0.90, 0.20, 0.38, 1.0), 0.82)
	_materials["flower_white"] = _simple_material(Color(0.96, 0.92, 0.78, 1.0), 0.84)
	_materials["flag_blue"] = _simple_material(Color(0.13, 0.31, 0.68, 1.0), 0.88)
	_materials["flag_red"] = _simple_material(Color(0.74, 0.10, 0.10, 1.0), 0.88)
	_materials["flag_yellow"] = _simple_material(Color(0.88, 0.62, 0.09, 1.0), 0.88)

func _simple_material(color: Color, roughness: float, metallic := 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	return material

func _glass_material(color: Color, alpha: float) -> StandardMaterial3D:
	var material := _simple_material(Color(color.r, color.g, color.b, alpha), 0.16, 0.05)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _texture_material(stem: String, tint: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	var albedo := load("res://assets/textures/%s_diff.jpg" % stem)
	var normal := load("res://assets/textures/%s_nor.jpg" % stem)
	var rough := load("res://assets/textures/%s_rough.jpg" % stem)
	if albedo != null:
		material.albedo_texture = albedo
	if normal != null:
		material.normal_enabled = true
		material.normal_texture = normal
	if rough != null:
		material.roughness_texture = rough
	material.albedo_color = tint
	material.roughness = roughness
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * 0.42
	return material

func _facade_atlas_material(roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	var atlas := load("res://assets/textures/saisies_s01_restaurant_facade_v1.png") as Texture2D
	if atlas != null:
		# The material deliberately owns the complete image.  Each front detail
		# quad below supplies explicit normalized UVs for its own pixel crop; a
		# region-wrapped texture would let the 3D UV layout sample the full atlas.
		material.albedo_texture = atlas
		material.albedo_color = Color.WHITE
	material.roughness = roughness
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _front_atlas_quad(parent: Node3D, node_name: String, size_yz: Vector2, center: Vector3, region: Rect2) -> MeshInstance3D:
	# A thin explicit front face preserves the backing BoxMesh's real depth while
	# mapping the selected source pixels directly to this surface.  The +X face
	# is the authored restaurant frontage; UVs are normalized against the full
	# 1774x887 atlas and do not rely on a region-wrapped texture.
	var half_y := size_yz.x * 0.5
	var half_z := size_yz.y * 0.5
	var u0 := region.position.x / FACADE_ATLAS_SIZE.x
	var u1 := (region.position.x + region.size.x) / FACADE_ATLAS_SIZE.x
	var v0 := region.position.y / FACADE_ATLAS_SIZE.y
	var v1 := (region.position.y + region.size.y) / FACADE_ATLAS_SIZE.y
	var vertices := PackedVector3Array([
		Vector3(0.0, -half_y, -half_z),
		Vector3(0.0, half_y, -half_z),
		Vector3(0.0, half_y, half_z),
		Vector3(0.0, -half_y, half_z),
	])
	var normals := PackedVector3Array([
		Vector3.RIGHT, Vector3.RIGHT, Vector3.RIGHT, Vector3.RIGHT,
	])
	var uvs := PackedVector2Array([
		# The Camera C frontage sees the +X face with local -Z on the left side
		# of the image.  Reverse U consistently so words and facade details read
		# left-to-right in the native projection.
		Vector2(u1, v1), Vector2(u1, v0), Vector2(u0, v0), Vector2(u0, v1),
	])
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = _materials["restaurant_facade_atlas"]
	instance.position = center
	instance.set_meta("saisies_s01_explicit_uv_region_px", region)
	instance.set_meta("saisies_s01_explicit_uv_full_atlas_px", FACADE_ATLAS_SIZE)
	parent.add_child(instance)
	return instance

func _hide_visuals(node: Node) -> void:
	for child in node.get_children():
		var visual := child as VisualInstance3D
		if visual != null:
			visual.visible = false
		_hide_visuals(child)

func _new_group(parent: Node3D, node_name: String) -> Node3D:
	var group := Node3D.new()
	group.name = node_name
	group.set_meta("saisies_s01_authored_local_geometry", true)
	parent.add_child(group)
	return group

func _box(parent: Node3D, node_name: String, size: Vector3, position: Vector3, material: Material, rotation := Vector3.ZERO) -> MeshInstance3D:
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

func _cylinder(parent: Node3D, node_name: String, radius: float, height: float, position: Vector3, material: Material, rotation := Vector3.ZERO, sides := 12) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = sides
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	instance.rotation = rotation
	parent.add_child(instance)
	return instance

func _sphere(parent: Node3D, node_name: String, radius: float, position: Vector3, material: Material, scale := Vector3.ONE) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 12
	mesh.rings = 8
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	instance.scale = scale
	parent.add_child(instance)
	return instance

func _label(parent: Node3D, node_name: String, text_value: String, position: Vector3, pixel_size := 0.0042) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.text = text_value
	label.font_size = 72
	label.pixel_size = pixel_size
	label.modulate = Color(0.98, 0.92, 0.70, 1.0)
	label.outline_size = 6
	label.outline_modulate = Color(0.08, 0.045, 0.025, 1.0)
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.rotation.y = PI * 0.5
	label.position = position
	parent.add_child(label)
	return label

func _hide_and_group(anchor: Node3D, group_name: String) -> Node3D:
	_hide_visuals(anchor)
	anchor.set_meta("saisies_s01_review_replaced", true)
	anchor.set_meta("saisies_s01_anchor_preserved", true)
	return _new_group(anchor, group_name)

func _refine_restaurant(anchor: Node3D) -> void:
	var group := _hide_and_group(anchor, "RestaurantFacadeRefinement")
	var foundation := 0.40
	var foundation_contact := _foundation_contact(anchor, foundation, 0.52)
	var floor_height := 2.58
	var body_top := foundation + floor_height * 2.0
	var front_x := RESTAURANT_DEPTH * 0.5 + 0.08
	# Keep the full contact mesh for the sampled-ground contract, but bury it
	# visually below the frontage.  The source reads as a low pale kick rather
	# than the tall dark stone band in the previous candidate.
	var contact_foundation := _box(group, "RestaurantStoneFoundation", Vector3(RESTAURANT_DEPTH + 0.42, foundation_contact["height"], RESTAURANT_WIDTH + 0.42), Vector3(0.0, foundation_contact["center"], 0.0), _materials["stone"])
	contact_foundation.visible = false
	_box(group, "RestaurantThinKick", Vector3(0.26, 0.28, RESTAURANT_WIDTH - 0.18), Vector3(front_x + 0.20, foundation_contact["bottom"] + 0.14, 0.0), _materials["cream_light"])
	# Closed rear and side returns give the facade real depth while the front is
	# assembled from individually recessed glass bays.
	var wall_bottom := float(foundation_contact["bottom"])
	var wall_height := body_top - wall_bottom
	var wall_center := wall_bottom + wall_height * 0.5
	_box(group, "RestaurantRearWall", Vector3(0.56, wall_height, RESTAURANT_WIDTH), Vector3(-RESTAURANT_DEPTH * 0.5 + 0.28, wall_center, 0.0), _materials["cream"])
	_box(group, "RestaurantSideWallNeg", Vector3(RESTAURANT_DEPTH, wall_height, 0.52), Vector3(0.0, wall_center, -RESTAURANT_WIDTH * 0.5 + 0.26), _materials["cream"])
	_box(group, "RestaurantSideWallPos", Vector3(RESTAURANT_DEPTH, wall_height, 0.52), Vector3(0.0, wall_center, RESTAURANT_WIDTH * 0.5 - 0.26), _materials["cream"])
	_box(group, "RestaurantUpperFacade", Vector3(0.30, floor_height * 0.98, RESTAURANT_WIDTH - 0.58), Vector3(RESTAURANT_DEPTH * 0.5 - 0.16, foundation + floor_height * 1.50, 0.0), _materials["cream_light"])
	var ground_top := foundation + floor_height - 0.12
	var ground_height := ground_top - wall_bottom
	_box(group, "RestaurantGroundInterior", Vector3(0.42, ground_height, RESTAURANT_WIDTH - 0.58), Vector3(RESTAURANT_DEPTH * 0.5 - 0.36, wall_bottom + ground_height * 0.5, 0.0), _materials["cream"])
	var upper_y := foundation + floor_height * 1.53
	for bay in range(7):
		var z := lerpf(-RESTAURANT_WIDTH * 0.41, RESTAURANT_WIDTH * 0.41, float(bay) / 6.0)
		_box(group, "RestaurantUpperGlass_%02d" % bay, Vector3(0.09, 1.48, 2.52), Vector3(front_x + 0.10, upper_y, z), _materials["glass_upper"])
		_box(group, "RestaurantUpperMullion_%02d" % bay, Vector3(0.15, 1.66, 0.10), Vector3(front_x + 0.19, upper_y, z - 1.24), _materials["timber_dark"])
	# Thick balcony deck, posts, and cap remain visible in front of the upper bays.
	_box(group, "RestaurantUpperBalconyDeck", Vector3(0.74, 0.18, RESTAURANT_WIDTH * 0.90), Vector3(front_x + 0.38, foundation + floor_height + 0.15, 0.0), _materials["timber"])
	# Source S01 has a continuous timber balcony face below the rail.  Use
	# individually spaced boards with real thickness so the upper facade does not
	# collapse into a row of bare rails and dark window rectangles.
	var balcony_panel_height := 0.65
	var balcony_panel_y := foundation + floor_height + 0.55
	var balcony_panel_width := RESTAURANT_WIDTH * 0.145
	for panel_index in range(7):
		var panel_z := lerpf(-RESTAURANT_WIDTH * 0.385, RESTAURANT_WIDTH * 0.385, float(panel_index) / 6.0)
		_box(group, "RestaurantUpperBalconyPanel_%02d" % panel_index, Vector3(0.18, balcony_panel_height, balcony_panel_width), Vector3(front_x + 0.73, balcony_panel_y, panel_z), _materials["weathered_timber"])
		_front_atlas_quad(group, "RestaurantUpperBalconyPanelDetail_%02d" % panel_index, Vector2(balcony_panel_height, balcony_panel_width), Vector3(front_x + 0.825, balcony_panel_y, panel_z), Rect2(488.0 + float(panel_index) * 176.0, 486.0, 176.0, 112.0))
	# Low timber flower boxes sit on the deck/front edge.  The small clusters
	# retain only the source-facing box and soil geometry; the earlier sphere
	# clusters read as balloons in the native view and are intentionally removed.
	var balcony_box_y := foundation + floor_height + 0.39
	for box_index in range(4):
		var box_z := lerpf(-RESTAURANT_WIDTH * 0.31, RESTAURANT_WIDTH * 0.31, float(box_index) / 3.0)
		_box(group, "RestaurantUpperBalconyFlowerbox_%02d" % box_index, Vector3(0.48, 0.28, 2.10), Vector3(front_x + 0.91, balcony_box_y, box_z), _materials["weathered_timber"])
		_box(group, "RestaurantUpperBalconySoil_%02d" % box_index, Vector3(0.42, 0.10, 1.96), Vector3(front_x + 0.91, balcony_box_y + 0.17, box_z), _materials["soil"])
	group.set_meta("saisies_s01_balcony_panel_height_m", balcony_panel_height)
	group.set_meta("saisies_s01_balcony_flowerbox_count", 4)
	_box(group, "RestaurantUpperBalconyRailCap", Vector3(0.14, 0.11, RESTAURANT_WIDTH * 0.90), Vector3(front_x + 0.73, foundation + floor_height + 1.03, 0.0), _materials["timber_dark"])
	for post_index in range(11):
		var post_z := lerpf(-RESTAURANT_WIDTH * 0.43, RESTAURANT_WIDTH * 0.43, float(post_index) / 10.0)
		_box(group, "RestaurantUpperBalconyPost_%02d" % post_index, Vector3(0.13, 0.95, 0.13), Vector3(front_x + 0.70, foundation + floor_height + 0.58, post_z), _materials["timber_dark"])
	# Tie the storefront sill to the sampled sidewalk.  Openings are taller than
	# the prior 1.98 m proxy and begin a small distance above the actual ground.
	var store_opening_bottom := wall_bottom + 0.30
	var store_opening_height := 2.28
	var ground_y := store_opening_bottom + store_opening_height * 0.5
	var display_floor_y := wall_bottom + 0.05
	for bay in range(6):
		var z_ground := lerpf(-RESTAURANT_WIDTH * 0.40, RESTAURANT_WIDTH * 0.40, float(bay) / 5.0)
		_box(group, "RestaurantStoreRecess_%02d" % bay, Vector3(0.26, store_opening_height, 3.00), Vector3(front_x + 0.05, ground_y, z_ground), _materials["interior_warm"])
		_front_atlas_quad(group, "RestaurantStoreDetail_%02d" % bay, Vector2(store_opening_height, 3.00), Vector3(front_x + 0.185, ground_y, z_ground), Rect2(34.0 + float(bay) * 289.0, 652.0, 276.0, 216.0))
		_add_clothing_display(group, front_x, z_ground, display_floor_y + 0.70, bay)
		_box(group, "RestaurantStoreGlass_%02d" % bay, Vector3(0.07, 2.00, 2.56), Vector3(front_x + 0.25, ground_y, z_ground), _materials["store_glass"])
		_box(group, "RestaurantStoreFrame_%02d" % bay, Vector3(0.13, 2.36, 0.12), Vector3(front_x + 0.34, ground_y, z_ground - 1.40), _materials["timber_dark"])
	var door_z := 0.0
	_box(group, "RestaurantDoorReveal", Vector3(0.40, store_opening_height, 1.32), Vector3(front_x + 0.05, ground_y, door_z), _materials["interior_warm"])
	_box(group, "RestaurantDoorGlass", Vector3(0.07, 2.04, 0.96), Vector3(front_x + 0.28, ground_y, door_z), _materials["store_glass"])
	for side in [-1.0, 1.0]:
		_box(group, "RestaurantDoorJamb_%d" % int(side), Vector3(0.14, 2.34, 0.11), Vector3(front_x + 0.38, ground_y, side * 0.58), _materials["timber_dark"])
	_box(group, "RestaurantDoorLintel", Vector3(0.15, 0.13, 1.30), Vector3(front_x + 0.38, store_opening_bottom + store_opening_height + 0.08, 0.0), _materials["timber_dark"])
	# The source shows a white striped awning with a scalloped hanging edge.
	var awning_y := foundation + floor_height - 0.12 + restaurant_awning_y_offset_m
	var awning_pitch := deg_to_rad(restaurant_awning_pitch_deg)
	var awning_rotation := Vector3(awning_pitch, 0.0, deg_to_rad(-2.0))
	_box(group, "RestaurantWhiteAwning", Vector3(1.78, 0.14, RESTAURANT_WIDTH * 0.92), Vector3(front_x + 0.82, awning_y, 0.0), _materials["awning"], awning_rotation)
	for stripe in range(8):
		var stripe_z := lerpf(-RESTAURANT_WIDTH * 0.41, RESTAURANT_WIDTH * 0.41, float(stripe) / 7.0)
		_box(group, "RestaurantAwningStripe_%02d" % stripe, Vector3(1.66, 0.035, 0.11), Vector3(front_x + 0.84, awning_y + 0.09 - sin(awning_pitch) * stripe_z, stripe_z), _materials["awning_shadow"], awning_rotation)
		_sphere(group, "RestaurantAwningScallop_%02d" % stripe, 0.18, Vector3(front_x + 1.64, awning_y - 0.16 - sin(awning_pitch) * stripe_z, stripe_z), _materials["awning"], Vector3(0.72, 0.34, 0.80))
	for post_z in [-RESTAURANT_WIDTH * 0.42, 0.0, RESTAURANT_WIDTH * 0.42]:
		var post_bottom := wall_bottom + 0.05
		var post_height := maxf(awning_y - post_bottom - 0.12, 1.86)
		_box(group, "RestaurantAwningPost_%d" % int(post_z * 10.0), Vector3(0.10, post_height, 0.10), Vector3(front_x + 1.62, post_bottom + post_height * 0.5, post_z), _materials["metal"])
	# Keep the source words only; no inferred shop branding is added.
	_box(group, "RestaurantSignBandTable", Vector3(0.17, 0.42, 9.80), Vector3(front_x + 0.18, foundation + 4.60, -6.30), _materials["roof_dark"])
	_front_atlas_quad(group, "RestaurantSignBandTableDetail", Vector2(0.42, 9.80), Vector3(front_x + 0.27, foundation + 4.60, -6.30), Rect2(492.0, 306.0, 510.0, 92.0))
	_box(group, "RestaurantSignBandSavoyard", Vector3(0.17, 0.42, 9.80), Vector3(front_x + 0.18, foundation + 4.60, 5.10), _materials["roof_dark"])
	_front_atlas_quad(group, "RestaurantSignBandSavoyardDetail", Vector2(0.42, 9.80), Vector3(front_x + 0.27, foundation + 4.60, 5.10), Rect2(1003.0, 306.0, 535.0, 92.0))
	_label(group, "RestaurantSignTableLabel", "LA TABLE DE L’OLYMPE", Vector3(front_x + 0.30, foundation + 4.60, -6.30), 0.0036)
	_label(group, "RestaurantSignSavoyardLabel", "RESTAURANT SAVOYARD", Vector3(front_x + 0.30, foundation + 4.60, 5.10), 0.0038)
	# The restaurant gable spans the long frontage.  Rotate the generic roof
	# group after swapping its arguments so the slope crosses the 27 m facade,
	# while the ridge runs through the short 8.8 m depth.  The sealed end caps
	# use the same 27 m span and the measured roof rise.
	var restaurant_roof := _add_gable_roof(group, RESTAURANT_WIDTH, RESTAURANT_DEPTH, body_top, _materials["roof_dark"], "RestaurantRoof", 27.0, 8)
	restaurant_roof.rotation.y = PI * 0.5
	var restaurant_roof_rise := (RESTAURANT_WIDTH * 0.5 + 0.34) * tan(deg_to_rad(27.0))
	var roof_valid := _validate_roof_footprint(restaurant_roof, RESTAURANT_DEPTH + 0.80, RESTAURANT_WIDTH + 0.66)
	restaurant_roof.set_meta("saisies_s01_restaurant_roof_slope_span_m", RESTAURANT_WIDTH)
	restaurant_roof.set_meta("saisies_s01_restaurant_roof_ridge_length_m", RESTAURANT_DEPTH)
	restaurant_roof.set_meta("saisies_s01_restaurant_roof_rise_m", restaurant_roof_rise)
	restaurant_roof.set_meta("saisies_s01_restaurant_roof_axis_validated", roof_valid)
	_add_gable_end(group, "RestaurantFrontGable", RESTAURANT_DEPTH * 0.5 + 0.06, RESTAURANT_WIDTH, body_top, restaurant_roof_rise, _materials["cream_light"], _materials["timber_dark"])
	_add_gable_end(group, "RestaurantRearGable", -RESTAURANT_DEPTH * 0.5 - 0.06, RESTAURANT_WIDTH, body_top, restaurant_roof_rise, _materials["cream_light"], _materials["timber_dark"])
	anchor.set_meta("saisies_s01_refinement_restaurant", "deep_glazing_thick_balcony_scalloped_awning_source_labels")
	anchor.set_meta("saisies_s01_refinement_source_words", ["LA TABLE DE L’OLYMPE", "RESTAURANT SAVOYARD"])
	anchor.set_meta("saisies_s01_restaurant_roof_axis_validated", roof_valid)
	anchor.set_meta("saisies_s01_storefront_transparency", 0.30)
	anchor.set_meta("saisies_s01_restaurant_awning_pitch_axis", "local_x_span_pitch")
	anchor.set_meta("saisies_s01_restaurant_awning_screen_target", "near_horizontal_y330")
	anchor.set_meta("saisies_s01_restaurant_store_opening_height_m", store_opening_height)
	anchor.set_meta("saisies_s01_restaurant_foundation_visual", "buried_contact_with_thin_pale_kick")
	anchor.set_meta("saisies_s01_storefront_clothing_bays", 6)
	group.set_meta("saisies_s01_derived_texture_path", "res://assets/textures/saisies_s01_restaurant_facade_v1.png")
	group.set_meta("saisies_s01_derived_texture_scope", ["balcony_boards", "two_sign_bands", "six_store_recesses"])
	group.set_meta("saisies_s01_derived_texture_projection", "explicit_front_arraymesh_uv")
	group.set_meta("saisies_s01_derived_texture_is_acceptance_source", false)

func _add_clothing_display(parent: Node3D, front_x: float, z: float, rack_arg_y: float, index: int) -> void:
	var display := Node3D.new()
	display.name = "RestaurantClothingDisplay_%02d" % index
	display.position = Vector3(front_x + 0.12, 0.0, z)
	parent.add_child(display)
	# rack_arg_y is the original rack datum: its post center is datum-.03,
	# therefore datum=floor+.70 seats the 1.34 m post exactly on the sampled floor.
	_cylinder(display, "RackPost", 0.035, 1.34, Vector3(0.0, rack_arg_y - 0.03, 0.0), _materials["metal"], Vector3.ZERO, 10)
	_box(display, "RackRail", Vector3(0.08, 0.08, 1.86), Vector3(0.0, rack_arg_y + 0.57, 0.0), _materials["metal"])
	var garment_materials: Array[Material] = [_materials["flag_red"], _materials["flag_blue"], _materials["awning"], _materials["flower_pink"]]
	var garment_material: Material = garment_materials[index % garment_materials.size()]
	var item_z := -0.54
	# A compact T-shirt silhouette: body plus two short sleeves and a collar.
	_box(display, "TshirtBody", Vector3(0.12, 0.44, 0.34), Vector3(0.02, rack_arg_y + 0.25, item_z), garment_material)
	_box(display, "TshirtSleeveL", Vector3(0.10, 0.22, 0.16), Vector3(0.02, rack_arg_y + 0.34, item_z - 0.24), garment_material)
	_box(display, "TshirtSleeveR", Vector3(0.10, 0.22, 0.16), Vector3(0.02, rack_arg_y + 0.34, item_z + 0.24), garment_material)
	_box(display, "TshirtCollar", Vector3(0.13, 0.06, 0.12), Vector3(0.03, rack_arg_y + 0.49, item_z), _materials["white"])
	# A second item is split into two trouser legs so the display reads as stock.
	var trouser_material: Material = _materials["timber"] if index % 2 == 0 else _materials["flag_yellow"]
	_box(display, "TrouserWaist", Vector3(0.12, 0.16, 0.36), Vector3(0.02, rack_arg_y + 0.42, item_z + 0.56), trouser_material)
	_box(display, "TrouserLegL", Vector3(0.12, 0.54, 0.14), Vector3(0.02, rack_arg_y + 0.08, item_z + 0.43), trouser_material)
	_box(display, "TrouserLegR", Vector3(0.12, 0.54, 0.14), Vector3(0.02, rack_arg_y + 0.08, item_z + 0.69), trouser_material)

func _refine_hotel(anchor: Node3D) -> void:
	var group := _hide_and_group(anchor, "RearHotelRefinement")
	group.position.z = rear_hotel_local_z_offset_m
	group.scale.y = rear_hotel_height_scale
	var foundation := 0.70
	var foundation_contact := _foundation_contact(anchor, foundation, 0.62)
	var floor_height := 2.55
	var stories := 4
	var body_height := floor_height * float(stories)
	_box(group, "HotelStoneFoundation", Vector3(HOTEL_DEPTH + 0.42, foundation_contact["height"], HOTEL_WIDTH + 0.42), Vector3(0.0, foundation_contact["center"], 0.0), _materials["stone"])
	_box(group, "HotelDarkVolume", Vector3(HOTEL_DEPTH, body_height, HOTEL_WIDTH), Vector3(0.0, foundation + body_height * 0.5, 0.0), _materials["hotel_plaster"])
	var front_sign := 1.0
	var front_x := front_sign * (HOTEL_DEPTH * 0.5 + 0.06)
	for floor in range(stories):
		var floor_y := foundation + floor_height * (float(floor) + 0.55)
		for bay in range(4):
			var z := lerpf(-HOTEL_WIDTH * 0.38, HOTEL_WIDTH * 0.38, float(bay) / 3.0)
			_box(group, "HotelRecessedWindow_%02d_%02d" % [floor, bay], Vector3(0.16, 1.34, 2.20), Vector3(front_x + 0.03, floor_y, z), _materials["glass"])
			_box(group, "HotelWindowJambL_%02d_%02d" % [floor, bay], Vector3(0.18, 1.46, 0.10), Vector3(front_x + 0.14, floor_y, z - 1.12), _materials["timber_dark"])
			_box(group, "HotelWindowJambR_%02d_%02d" % [floor, bay], Vector3(0.18, 1.46, 0.10), Vector3(front_x + 0.14, floor_y, z + 1.12), _materials["timber_dark"])
			_box(group, "HotelBalconyDeck_%02d" % floor, Vector3(0.86, 0.15, HOTEL_WIDTH * 0.93), Vector3(front_x + 0.40, floor_y - 0.28, 0.0), _materials["timber"])
			_box(group, "HotelBalconyRail_%02d" % floor, Vector3(0.12, 0.58, HOTEL_WIDTH * 0.90), Vector3(front_x + 0.77, floor_y + 0.12, 0.0), _materials["white"])
			for post in range(8):
				var post_z := lerpf(-HOTEL_WIDTH * 0.42, HOTEL_WIDTH * 0.42, float(post) / 7.0)
				_box(group, "HotelBalconyPost_%02d_%02d" % [floor, post], Vector3(0.13, 0.66, 0.10), Vector3(front_x + 0.73, floor_y + 0.12, post_z), _materials["timber_dark"])
	_add_low_slope_roof(group, HOTEL_DEPTH, HOTEL_WIDTH, foundation + body_height, _materials["roof_dark"], "HotelLowSlopeRoof")
	anchor.set_meta("saisies_s01_refinement_hotel", "four_story_dark_green_plaster_recessed_glass_light_balcony_rails")
	anchor.set_meta("saisies_s01_refinement_hotel_height_scale", rear_hotel_height_scale)
	anchor.set_meta("saisies_s01_refinement_hotel_local_z_offset_m", rear_hotel_local_z_offset_m)

func _refine_lodge(anchor: Node3D) -> void:
	var group := _hide_and_group(anchor, "RightLodgeRefinement")
	# The source shows the lodge's long side facing the route, with a narrow
	# gable at its left end.  The inherited anchor's authored body is long on
	# local Z, while Camera C sees the anchor from +Z.  Rotate this local
	# refinement once so that the long frontage becomes the camera-facing +Z
	# side and the roof ridge projects along screen right; the anchor and all
	# sampled ground-contact data remain unchanged.
	group.rotation.y = deg_to_rad(LODGE_GROUP_YAW_DEG)
	group.scale.z = LODGE_LONG_SCALE
	# Translate along the rotated long axis in the anchor's local frame.  This is
	# a horizontal frontage fit only; the group origin and its sampled Y contact
	# plane are unchanged.
	group.position += group.transform.basis.z.normalized() * LODGE_LATERAL_SHIFT_M
	group.set_meta("saisies_s01_lodge_group_yaw_deg", LODGE_GROUP_YAW_DEG)
	group.set_meta("saisies_s01_lodge_long_scale", LODGE_LONG_SCALE)
	group.set_meta("saisies_s01_lodge_lateral_shift_m", LODGE_LATERAL_SHIFT_M)
	var foundation := 0.62
	var foundation_contact := _foundation_contact(anchor, foundation, 0.60)
	var ground_floor_height := LODGE_GROUND_FLOOR_HEIGHT
	var upper_floor_height := LODGE_UPPER_FLOOR_HEIGHT
	var stories := 2
	var body_height := ground_floor_height + upper_floor_height
	_box(group, "LodgeStoneFoundation", Vector3(LODGE_DEPTH + 0.42, foundation_contact["height"], LODGE_WIDTH + 0.42), Vector3(0.0, foundation_contact["center"], 0.0), _materials["stone"])
	# Keep a normal ground floor at the sampled foundation and let only the upper
	# timber mass rise to meet the source-height eave.  Splitting the boxes makes
	# the no-floating-ground-floor contract explicit in actual geometry.
	_box(group, "LodgeDarkTimberBody", Vector3(LODGE_DEPTH, ground_floor_height, LODGE_WIDTH), Vector3(0.0, foundation + ground_floor_height * 0.5, 0.0), _materials["timber_dark"])
	_box(group, "LodgeUpperTimberBody", Vector3(LODGE_DEPTH, upper_floor_height, LODGE_WIDTH), Vector3(0.0, foundation + ground_floor_height + upper_floor_height * 0.5, 0.0), _materials["timber_dark"])
	var front_sign := -1.0
	var front_x := front_sign * (LODGE_DEPTH * 0.5 + 0.06)
	for floor in range(stories):
		var floor_height := ground_floor_height if floor == 0 else upper_floor_height
		var floor_bottom := foundation if floor == 0 else foundation + ground_floor_height
		var floor_y := floor_bottom + floor_height * 0.53
		for bay in range(4):
			var z := lerpf(-LODGE_WIDTH * 0.38, LODGE_WIDTH * 0.38, float(bay) / 3.0)
			_box(group, "LodgeGlassWindow_%02d_%02d" % [floor, bay], Vector3(0.10, 1.36, 2.48), Vector3(front_x + front_sign * 0.07, floor_y, z), _materials["glass_warm"])
			_box(group, "LodgeWindowTop_%02d_%02d" % [floor, bay], Vector3(0.13, 0.11, 2.66), Vector3(front_x + front_sign * 0.17, floor_y + 0.73, z), _materials["cream_light"])
			_box(group, "LodgeWindowSill_%02d_%02d" % [floor, bay], Vector3(0.13, 0.10, 2.66), Vector3(front_x + front_sign * 0.17, floor_y - 0.73, z), _materials["cream_light"])
		_box(group, "LodgePorchDeck_%02d" % floor, Vector3(1.10, 0.16, LODGE_WIDTH * 0.78), Vector3(front_x + front_sign * 0.52, floor_bottom + 0.17, 0.0), _materials["timber"])
		_box(group, "LodgePorchRail_%02d" % floor, Vector3(0.12, 0.56, LODGE_WIDTH * 0.76), Vector3(front_x + front_sign * 1.02, floor_bottom + 0.55, 0.0), _materials["white"])
	_box(group, "LodgeDoorReveal", Vector3(0.34, 2.08, 1.04), Vector3(front_x + front_sign * 0.07, foundation + 1.08, 0.0), _materials["interior"])
	_box(group, "LodgeDoorFrame", Vector3(0.16, 2.18, 1.20), Vector3(front_x + front_sign * 0.18, foundation + 1.08, 0.0), _materials["cream_light"])
	# _add_gable_roof slopes across local X and places its ridge along local Z.
	# The group yaw above turns those axes into the narrow roof depth and long
	# screen-facing ridge.  The end gables therefore belong at local Z ends,
	# rather than on the broad local-X side.
	var lodge_roof_angle_deg := 28.0
	var lodge_roof := _add_gable_roof(group, LODGE_ROOF_DEPTH, LODGE_WIDTH, foundation + body_height, _materials["roof_metal"], "LodgeMetalRoof", lodge_roof_angle_deg, 9)
	var lodge_roof_rise := (LODGE_ROOF_DEPTH * 0.5 + 0.34) * tan(deg_to_rad(lodge_roof_angle_deg))
	_add_gable_end_z(group, "LodgeVisibleLeftGable", front_sign * (LODGE_WIDTH * 0.5 + 0.34), LODGE_DEPTH, foundation + body_height, lodge_roof_rise, _materials["timber_dark"], _materials["timber_grey"])
	anchor.set_meta("saisies_s01_lodge_roof_ridge_axis", "world_x_after_local_yaw_left_end_minus_x")
	anchor.set_meta("saisies_s01_lodge_roof_angle_deg", lodge_roof_angle_deg)
	anchor.set_meta("saisies_s01_lodge_roof_rise_m", lodge_roof_rise)
	anchor.set_meta("saisies_s01_lodge_ground_floor_height_m", ground_floor_height)
	anchor.set_meta("saisies_s01_lodge_upper_floor_height_m", upper_floor_height)
	_box(group, "LodgeFrontRoofFascia", Vector3(0.18, 0.18, LODGE_WIDTH + 0.22), Vector3(front_x + front_sign * 0.16, foundation + body_height + 0.06, 0.0), _materials["white"])
	# Small source-like flags are unlabelled colour fields; no text is invented.
	for index in range(3):
		var z_flag := -4.0 + float(index) * 4.0
		_cylinder(group, "LodgeFlagPole_%02d" % index, 0.035, 3.0, Vector3(front_x + front_sign * 0.42, foundation + 2.00, z_flag), _materials["metal"])
		var flag_material: Material = _materials["flag_blue"] if index == 0 else (_materials["flag_red"] if index == 1 else _materials["flag_yellow"])
		_box(group, "LodgeFlag_%02d" % index, Vector3(0.04, 0.62, 0.82), Vector3(front_x + front_sign * 0.45, foundation + 2.87, z_flag + 0.40), flag_material)
	_cylinder(group, "LodgeChimney", 0.18, 1.05, Vector3(0.7, foundation + body_height + 0.58, 4.0), _materials["stone"])
	anchor.set_meta("saisies_s01_refinement_lodge", "dark_timber_grey_seamed_roof_low_porch_glass_flags")

func _add_camera_visible_lodge_detail() -> void:
	if _lodge_visible_detail_built or _world == null:
		return
	var camera_controller := get_node_or_null("../S01CameraController") as Node
	if camera_controller != null and not bool(camera_controller.get_meta("saisies_s01_camera_controller_ready", false)):
		_lodge_face_attempts += 1
		if _lodge_face_attempts < 24:
			call_deferred("_add_camera_visible_lodge_detail")
		return
	var camera := _world.get_node_or_null("CameraRig/Camera3D") as Camera3D
	var lodge := _world.get_node_or_null("VillageS01S02/S01S02Buildings/Right_Alpine_Lodge") as Node3D
	if camera == null or lodge == null:
		return
	var group := lodge.get_node_or_null("RightLodgeRefinement") as Node3D
	if group == null:
		return
	# Resolve the visible face in the refinement's local frame.  The lodge
	# frontage is deliberately yawed to put the inherited long side on Camera C;
	# using the anchor frame here would incorrectly add a second +Z frontage.
	var view_local := group.global_transform.basis.inverse() * (camera.global_position - group.global_position).normalized()
	var face_axis := "z" if absf(view_local.z) >= absf(view_local.x) else "x"
	var face_sign := 1.0 if (view_local.z if face_axis == "z" else view_local.x) >= 0.0 else -1.0
	if face_axis == "z":
		_add_lodge_z_face_detail(group, face_sign)
	elif face_sign > 0.0:
		_add_lodge_x_face_detail(group, face_sign)
	lodge.set_meta("saisies_s01_lodge_visible_face_axis", face_axis)
	lodge.set_meta("saisies_s01_lodge_visible_face_sign", face_sign)
	lodge.set_meta("saisies_s01_lodge_local_view_vector", view_local)
	lodge.set_meta("saisies_s01_lodge_visible_face_detail", "source_windows_low_porch")
	_lodge_visible_detail_built = true

func _add_lodge_z_face_detail(group: Node3D, face_sign: float) -> void:
	var foundation := 0.62
	var floor_height := 2.62
	var body_height := floor_height * 2.0
	var face_z := face_sign * (LODGE_WIDTH * 0.5 + 0.06)
	for floor in range(2):
		var floor_y := foundation + floor_height * (float(floor) + 0.53)
		for bay in range(3):
			var x := lerpf(-LODGE_DEPTH * 0.34, LODGE_DEPTH * 0.34, float(bay) / 2.0)
			_box(group, "LodgeVisibleZGlassWindow_%02d_%02d" % [floor, bay], Vector3(1.55, 1.36, 0.10), Vector3(x, floor_y, face_z), _materials["glass_warm"])
			_box(group, "LodgeVisibleZWindowTop_%02d_%02d" % [floor, bay], Vector3(1.72, 0.11, 0.13), Vector3(x, floor_y + 0.73, face_z + face_sign * 0.08), _materials["cream_light"])
			_box(group, "LodgeVisibleZWindowSill_%02d_%02d" % [floor, bay], Vector3(1.72, 0.10, 0.13), Vector3(x, floor_y - 0.73, face_z + face_sign * 0.08), _materials["cream_light"])
		_box(group, "LodgeVisibleZPorchDeck_%02d" % floor, Vector3(LODGE_DEPTH * 0.80, 0.16, 1.10), Vector3(0.0, foundation + floor_height * float(floor) + 0.17, face_z + face_sign * 0.52), _materials["timber_grey"])
		_box(group, "LodgeVisibleZPorchRail_%02d" % floor, Vector3(LODGE_DEPTH * 0.78, 0.56, 0.12), Vector3(0.0, foundation + floor_height * float(floor) + 0.55, face_z + face_sign * 1.02), _materials["white"])
	_box(group, "LodgeVisibleZEave", Vector3(LODGE_DEPTH + 0.28, 0.18, 0.18), Vector3(0.0, foundation + body_height + 0.06, face_z + face_sign * 0.12), _materials["white"])
	# Keep the source-like flag line on the same camera-visible +Z frontage.
	for index in range(3):
		var flag_x := -2.8 + float(index) * 2.8
		_cylinder(group, "LodgeVisibleZFlagPole_%02d" % index, 0.035, 2.55, Vector3(flag_x, foundation + 2.06, face_z + face_sign * 0.38), _materials["metal"])
		var flag_material: Material = _materials["flag_blue"] if index == 0 else (_materials["flag_red"] if index == 1 else _materials["flag_yellow"])
		_box(group, "LodgeVisibleZFlag_%02d" % index, Vector3(0.82, 0.62, 0.04), Vector3(flag_x + 0.38, foundation + 2.76, face_z + face_sign * 0.40), flag_material)

func _add_lodge_x_face_detail(group: Node3D, face_sign: float) -> void:
	var foundation := 0.62
	var floor_height := 2.62
	var face_x := face_sign * (LODGE_DEPTH * 0.5 + 0.06)
	for floor in range(2):
		var floor_y := foundation + floor_height * (float(floor) + 0.53)
		for bay in range(3):
			var z := lerpf(-LODGE_WIDTH * 0.34, LODGE_WIDTH * 0.34, float(bay) / 2.0)
			_box(group, "LodgeVisibleXGlassWindow_%02d_%02d" % [floor, bay], Vector3(0.10, 1.36, 1.55), Vector3(face_x, floor_y, z), _materials["glass_warm"])
			_box(group, "LodgeVisibleXWindowTop_%02d_%02d" % [floor, bay], Vector3(0.13, 0.11, 1.72), Vector3(face_x + face_sign * 0.08, floor_y + 0.73, z), _materials["cream_light"])
			_box(group, "LodgeVisibleXWindowSill_%02d_%02d" % [floor, bay], Vector3(0.13, 0.10, 1.72), Vector3(face_x + face_sign * 0.08, floor_y - 0.73, z), _materials["cream_light"])

func _refine_middle_house(anchor: Node3D, suffix: String, width: float, depth: float, stories: int, body_material: Material, roof_material: Material) -> void:
	var group := _hide_and_group(anchor, "MiddleHouseRefinement_%s" % suffix)
	# S01's first middle-house anchor is the small road-exit chalet visible in
	# the source right-detail crop.  Keep B/C on their frozen R14 proportions;
	# only this authored replacement gets the bounded screen-space candidate.
	var source_middle_chalet := suffix == "A"
	if source_middle_chalet:
		# The anchor remains the contact reference.  This is a local refinement
		# offset, not a route/world translation, and the Y scale stays one so the
		# sampled foundation burial is preserved.
		group.position += Vector3(-8.0, 0.0, 0.0)
		group.scale = Vector3(1.18, 1.0, 1.18)
	var foundation := 0.72 if source_middle_chalet else 0.52
	var foundation_contact := _foundation_contact(anchor, foundation, 0.48)
	var floor_height := 2.38
	var body_height := floor_height * float(stories)
	_box(group, "MiddleHouseFoundation_%s" % suffix, Vector3(depth + 0.36, foundation_contact["height"], width + 0.36), Vector3(0.0, foundation_contact["center"], 0.0), _materials["stone"])
	var authored_body_material: Material = _materials["timber_dark"] if source_middle_chalet else body_material
	_box(group, "MiddleHouseBody_%s" % suffix, Vector3(depth, body_height, width), Vector3(0.0, foundation + body_height * 0.5, 0.0), authored_body_material)
	var front_sign := -1.0 if suffix != "B" else 1.0
	var front_x := front_sign * (depth * 0.5 + 0.06)
	for floor in range(stories):
		var y := foundation + floor_height * (float(floor) + 0.55)
		for bay in range(2):
			var z := -width * 0.25 + float(bay) * width * 0.50
			_box(group, "MiddleHouseWindow_%s_%02d_%02d" % [suffix, floor, bay], Vector3(0.10, 1.05, width * 0.27), Vector3(front_x + front_sign * 0.07, y, z), _materials["glass"])
			_box(group, "MiddleHouseWindowCap_%s_%02d_%02d" % [suffix, floor, bay], Vector3(0.13, 0.10, width * 0.31), Vector3(front_x + front_sign * 0.14, y + 0.58, z), _materials["cream_light"])
	_add_gable_roof(group, depth, width, foundation + body_height, roof_material, "MiddleHouseRoof_%s" % suffix, 27.0, 6)
	if source_middle_chalet:
		_add_middle_chalet_visible_z_detail(group, depth, width, stories, foundation, floor_height)
	anchor.set_meta("saisies_s01_refinement_middle_house", suffix)
	if source_middle_chalet:
		anchor.set_meta("saisies_s01_middle_chalet_candidate", true)
		anchor.set_meta("saisies_s01_middle_chalet_visible_face", "+z")
		anchor.set_meta("saisies_s01_middle_chalet_local_shift_x_m", -8.0)
		anchor.set_meta("saisies_s01_middle_chalet_horizontal_scale", 1.18)
		anchor.set_meta("saisies_s01_middle_chalet_foundation_top_m", foundation)

func _add_middle_chalet_visible_z_detail(group: Node3D, depth: float, width: float, stories: int, foundation: float, floor_height: float) -> void:
	# Camera C sees the +Z side of anchor A.  The generic helper's -X windows
	# therefore read as a blank body from the review pose; add a restrained real
	# frontage on the actually visible side rather than decorating a hidden face.
	var face_z := width * 0.5 + 0.07
	for floor in range(stories):
		var floor_y := foundation + floor_height * (float(floor) + 0.54)
		for bay in range(2):
			var x := lerpf(-depth * 0.30, depth * 0.30, float(bay))
			_box(group, "MiddleHouseVisibleZGlass_A_%02d_%02d" % [floor, bay], Vector3(1.42, 1.08, 0.10), Vector3(x, floor_y, face_z), _materials["glass_warm"])
			_box(group, "MiddleHouseVisibleZWindowTop_A_%02d_%02d" % [floor, bay], Vector3(1.58, 0.10, 0.13), Vector3(x, floor_y + 0.59, face_z + 0.08), _materials["cream_light"])
			_box(group, "MiddleHouseVisibleZWindowSill_A_%02d_%02d" % [floor, bay], Vector3(1.58, 0.10, 0.13), Vector3(x, floor_y - 0.59, face_z + 0.08), _materials["cream_light"])
		# A shallow low porch keeps the road-facing side readable without making
		# the small chalet another full-width lodge or shopfront.
		_box(group, "MiddleHouseVisibleZPorchDeck_A_%02d" % floor, Vector3(depth * 0.78, 0.16, 0.92), Vector3(0.0, foundation + floor_height * float(floor) + 0.18, face_z + 0.48), _materials["timber_grey"])
		_box(group, "MiddleHouseVisibleZPorchRail_A_%02d" % floor, Vector3(depth * 0.74, 0.48, 0.12), Vector3(0.0, foundation + floor_height * float(floor) + 0.54, face_z + 0.91), _materials["cream_light"])
	_box(group, "MiddleHouseVisibleZEave_A", Vector3(depth + 0.30, 0.18, 0.18), Vector3(0.0, foundation + floor_height * float(stories) + 0.07, face_z + 0.12), _materials["cream_light"])

func _refine_flowerboxes() -> void:
	var props := _world.get_node_or_null("VillagePropsS01") as Node3D
	if props == null:
		return
	var old_group := props.get_node_or_null("S01VillageStreetProps") as Node3D
	if old_group == null:
		return
	# Keep R14's detailed periwinkle canopy cards visible.  Only the old square
	# body, soil, and guardrail base are hidden so the new crossed logs can sit
	# under the authored flower mesh without duplicating a proxy flower crown.
	old_group.visible = true
	var refined := _new_group(props, "S01RefinedLogFlowerboxes")
	refined.set_meta("saisies_s01_planter_source", "five existing S01RightLogFlowerbox anchors")
	var names := ["S01RightLogFlowerbox_058", "S01RightLogFlowerbox_064", "S01RightLogFlowerbox_072", "S01RightLogFlowerbox_084", "S01RightLogFlowerbox_100"]
	var refined_count := 0
	for index in range(names.size()):
		var source := old_group.get_node_or_null(String(names[index])) as Node3D
		if source == null:
			continue
		_hide_flowerbox_base(source)
		# Preserve the authored canopy height while shrinking only its X/Z footprint.
		# This keeps the detailed R14 flower mesh visible instead of turning it into
		# a uniformly flattened proxy.
		source.scale = Vector3(flowerbox_scale, 1.0, flowerbox_scale)
		var planter := Node3D.new()
		planter.name = "S01RefinedPlanter_%02d" % index
		refined.add_child(planter)
		planter.global_transform = source.global_transform
		_build_log_planter(planter, index)
		refined_count += 1
	refined.set_meta("saisies_s01_refined_planter_count", refined_count)

func _build_log_planter(parent: Node3D, index: int) -> void:
	# Crossed round logs are deliberately assembled from thick cylinders instead
	# of a square box; the soil and flower clusters sit inside the timber frame.
	var z_bias := -0.08 if index % 2 == 0 else 0.08
	# Four short vertical log feet reach slightly below the anchor contact plane;
	# this keeps the replacement support physically seated on the same sampled
	# GeoLandscape height used by the R14 flowerbox anchor.
	for foot_x in [-0.30, 0.30]:
		for foot_z in [-0.30, 0.30]:
			_cylinder(parent, "PlanterContactFoot_%d_%d" % [int(foot_x * 10.0), int(foot_z * 10.0)], 0.12, 0.18, Vector3(foot_x, 0.09, foot_z), _materials["weathered_timber"])
	for side in [-1.0, 1.0]:
		# Two horizontal round rails sit across the box, while the short legs
		# cross diagonally in the X/Y plane like the source log supports.
		_cylinder(parent, "PlanterHorizontalLog_%d" % int(side), 0.11, 1.54, Vector3(side * 0.22, 0.44, z_bias), _materials["weathered_timber"], Vector3(PI * 0.5, 0.0, 0.0), 12)
		# These diagonals span from the short contact feet into the soil box, so
		# the visible crossed frame supports the planter instead of splaying on the
		# ground as loose orange sticks.
		_cylinder(parent, "PlanterCrossLog_%d" % int(side), 0.11, 0.98, Vector3(side * 0.38, 0.34, 0.0), _materials["weathered_timber"], Vector3(0.0, 0.0, side * deg_to_rad(35.0)), 12)
	_box(parent, "PlanterSoil", Vector3(1.54, 0.16, 0.76), Vector3(0.0, 0.70, 0.0), _materials["soil"])
	parent.set_meta("saisies_s01_planter_support", "crossed_round_logs")
	parent.set_meta("saisies_s01_planter_canopy_source", "R14 PeriwinkleCanopyCards retained")
	parent.set_meta("saisies_s01_planter_contact_source", "R14 GeoVillageProps sample_mesh_triangle anchor")
	parent.set_meta("saisies_s01_planter_scale", flowerbox_scale)
	parent.set_meta("saisies_s01_planter_scale_xyz", Vector3(flowerbox_scale, 1.0, flowerbox_scale))
	parent.set_meta("saisies_s01_planter_wood_material", "weathered_timber")

func _hide_flowerbox_base(source: Node3D) -> void:
	for child in source.get_children():
		var visual := child as VisualInstance3D
		if visual == null:
			continue
		if child.name == "PeriwinkleCanopyCards":
			visual.visible = true
		else:
			visual.visible = false

func _foundation_contact(anchor: Node3D, top_local_y: float, nominal_height: float) -> Dictionary:
	# R14 stores the eight triangle samples used by the original foundation.  Use
	# its lowest actual sampled world height and extend the replacement base to
	# that plane, leaving a small burial margin instead of a floating slab.
	var sampled_min_world_y := float(anchor.get_meta("saisies_geo_foundation_min_ground_y", anchor.global_position.y - 0.10))
	var local_up_y := maxf(absf(anchor.global_transform.basis.y.y), 0.001)
	var bottom_local_y := (sampled_min_world_y - 0.10 - anchor.global_position.y) / local_up_y
	var height := maxf(top_local_y - bottom_local_y, nominal_height)
	var center := bottom_local_y + height * 0.5
	anchor.set_meta("saisies_s01_refinement_foundation_contact_source", "R14 Landscape.sample_mesh_triangle metadata")
	anchor.set_meta("saisies_s01_refinement_foundation_bottom_local_y", bottom_local_y)
	anchor.set_meta("saisies_s01_refinement_foundation_top_local_y", top_local_y)
	return {"height": height, "center": center, "bottom": bottom_local_y}

func _add_gable_roof(parent: Node3D, depth: float, width: float, eave_y: float, material: Material, roof_name: String, angle_deg: float, seam_count: int) -> Node3D:
	var roof := Node3D.new()
	roof.name = roof_name
	parent.add_child(roof)
	var angle := deg_to_rad(angle_deg)
	var half_span := depth * 0.5 + 0.34
	var slab_length := half_span / cos(angle)
	var center_y := eave_y + half_span * 0.5 * tan(angle)
	_box(roof, "RoofSlopeNegX", Vector3(slab_length, 0.20, width + 0.52), Vector3(-half_span * 0.5, center_y, 0.0), material, Vector3(0.0, 0.0, angle))
	_box(roof, "RoofSlopePosX", Vector3(slab_length, 0.20, width + 0.52), Vector3(half_span * 0.5, center_y, 0.0), material, Vector3(0.0, 0.0, -angle))
	_box(roof, "RoofRidgeCap", Vector3(0.34, 0.24, width + 0.66), Vector3(0.0, eave_y + half_span * tan(angle), 0.0), _materials["roof_seam"])
	for side in [-1.0, 1.0]:
		for seam in range(seam_count):
			var z := lerpf(-width * 0.43, width * 0.43, float(seam) / maxf(float(seam_count - 1), 1.0))
			_box(roof, "RoofSeam_%d_%02d" % [int(side), seam], Vector3(slab_length + 0.06, 0.025, 0.055), Vector3(side * half_span * 0.5, center_y + 0.12, z), _materials["roof_seam"], Vector3(0.0, 0.0, -side * angle))
	return roof

func _validate_roof_footprint(roof: Node3D, expected_x: float, expected_z: float) -> bool:
	# Evaluate the actual transformed mesh corners, including the restaurant's
	# PI/2 yaw, rather than trusting the helper arguments or metadata alone.
	var min_corner := Vector3(1.0e20, 1.0e20, 1.0e20)
	var max_corner := Vector3(-1.0e20, -1.0e20, -1.0e20)
	var found := false
	for child in roof.get_children():
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var aabb := mesh_instance.get_aabb()
		for ix in range(2):
			for iy in range(2):
				for iz in range(2):
					var corner := aabb.position + Vector3(aabb.size.x * float(ix), aabb.size.y * float(iy), aabb.size.z * float(iz))
					var parent_space := roof.transform * mesh_instance.transform * corner
					min_corner.x = minf(min_corner.x, parent_space.x)
					min_corner.y = minf(min_corner.y, parent_space.y)
					min_corner.z = minf(min_corner.z, parent_space.z)
					max_corner.x = maxf(max_corner.x, parent_space.x)
					max_corner.y = maxf(max_corner.y, parent_space.y)
					max_corner.z = maxf(max_corner.z, parent_space.z)
					found = true
	if not found:
		return false
	var span_x := max_corner.x - min_corner.x
	var span_z := max_corner.z - min_corner.z
	var valid := absf(span_x - expected_x) <= 1.0 and absf(span_z - expected_z) <= 1.0
	roof.set_meta("saisies_s01_roof_actual_span_x_m", span_x)
	roof.set_meta("saisies_s01_roof_actual_span_z_m", span_z)
	roof.set_meta("saisies_s01_roof_expected_span_x_m", expected_x)
	roof.set_meta("saisies_s01_roof_expected_span_z_m", expected_z)
	return valid

func _add_low_slope_roof(parent: Node3D, depth: float, width: float, eave_y: float, material: Material, roof_name: String) -> Node3D:
	var roof := Node3D.new()
	roof.name = roof_name
	parent.add_child(roof)
	var angle := deg_to_rad(9.0)
	var half_span := depth * 0.5 + 0.32
	var slab_length := half_span / cos(angle)
	var center_y := eave_y + half_span * 0.5 * tan(angle)
	_box(roof, "RoofSlopeNegX", Vector3(slab_length, 0.22, width + 0.48), Vector3(-half_span * 0.5, center_y, 0.0), material, Vector3(0.0, 0.0, angle))
	_box(roof, "RoofSlopePosX", Vector3(slab_length, 0.22, width + 0.48), Vector3(half_span * 0.5, center_y, 0.0), material, Vector3(0.0, 0.0, -angle))
	_box(roof, "RoofRidgeCap", Vector3(0.28, 0.24, width + 0.56), Vector3(0.0, eave_y + half_span * tan(angle), 0.0), _materials["roof_seam"])
	return roof

func _add_gable_end(parent: Node3D, node_name: String, x: float, span: float, eave_y: float, height: float, face_material: Material, inset_material: Material) -> void:
	var end := Node3D.new()
	end.name = node_name
	end.position = Vector3(x, 0.0, 0.0)
	parent.add_child(end)
	var face := MeshInstance3D.new()
	face.name = "SealedGableFace"
	face.mesh = _gable_triangle_mesh(0.20, span * 0.96, height)
	face.material_override = face_material
	face.position = Vector3(0.0, eave_y, 0.0)
	end.add_child(face)
	var inset := MeshInstance3D.new()
	inset.name = "TimberGableInset"
	inset.mesh = _gable_triangle_mesh(0.10, span * 0.38, height * 0.80)
	inset.material_override = inset_material
	inset.position = Vector3(0.13 if x >= 0.0 else -0.13, eave_y + 0.20, 0.0)
	end.add_child(inset)

func _add_gable_end_z(parent: Node3D, node_name: String, z: float, span: float, eave_y: float, height: float, face_material: Material, inset_material: Material) -> void:
	# _gable_triangle_mesh is authored with thickness on X and span on Z.  A
	# quarter turn makes a sealed end plane normal to local Z while keeping its
	# span on local X, which is the narrow roof depth after the lodge group yaw.
	var end := Node3D.new()
	end.name = node_name
	end.position = Vector3(0.0, 0.0, z)
	end.rotation.y = PI * 0.5
	parent.add_child(end)
	var face := MeshInstance3D.new()
	face.name = "SealedGableFace"
	face.mesh = _gable_triangle_mesh(0.20, span * 0.96, height)
	face.material_override = face_material
	face.position = Vector3(0.0, eave_y, 0.0)
	end.add_child(face)
	var inset := MeshInstance3D.new()
	inset.name = "TimberGableInset"
	inset.mesh = _gable_triangle_mesh(0.10, span * 0.38, height * 0.80)
	inset.material_override = inset_material
	inset.position = Vector3(0.13 if z >= 0.0 else -0.13, eave_y + 0.20, 0.0)
	end.add_child(inset)

func _gable_triangle_mesh(thickness: float, span: float, height: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hx := thickness * 0.5
	var hz := span * 0.5
	var back_left := Vector3(-hx, 0.0, -hz)
	var back_right := Vector3(-hx, 0.0, hz)
	var back_peak := Vector3(-hx, height, 0.0)
	var front_left := Vector3(hx, 0.0, -hz)
	var front_right := Vector3(hx, 0.0, hz)
	var front_peak := Vector3(hx, height, 0.0)
	surface.add_vertex(front_left); surface.add_vertex(front_right); surface.add_vertex(front_peak)
	surface.add_vertex(back_right); surface.add_vertex(back_left); surface.add_vertex(back_peak)
	surface.add_vertex(front_left); surface.add_vertex(front_peak); surface.add_vertex(back_peak)
	surface.add_vertex(front_left); surface.add_vertex(back_peak); surface.add_vertex(back_left)
	surface.add_vertex(front_peak); surface.add_vertex(front_right); surface.add_vertex(back_right)
	surface.add_vertex(front_peak); surface.add_vertex(back_right); surface.add_vertex(back_peak)
	surface.add_vertex(front_left); surface.add_vertex(back_left); surface.add_vertex(back_right)
	surface.add_vertex(front_left); surface.add_vertex(back_right); surface.add_vertex(front_right)
	surface.generate_normals()
	return surface.commit()
