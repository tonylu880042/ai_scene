class_name SaisiesVillage
extends Node3D

## Authored resort frontage for S01-S03 of the continuous Saisies route.
##
## The module owns the summit street, its sidewalks/planting island, and the
## first chairlift crossing.  Every anchor is resolved from the shared Route;
## there are no disconnected set pieces or camera-facing backdrops.

@export var route_path: NodePath
@export var from_m := 0.0
@export var to_m := 1300.0
@export var random_seed := 9127

var route: SaisiesRoute
var village_ready := false
var _rng := RandomNumberGenerator.new()
var _materials := {}
var _mesh_cache := {}

func _ready() -> void:
	route = get_node_or_null(route_path) as SaisiesRoute
	if route == null and get_parent() != null:
		route = get_parent().get_node_or_null("Route") as SaisiesRoute
	if route == null or not route.route_ready():
		call_deferred("_try_build")
		return
	_build()

func _try_build() -> void:
	if village_ready:
		return
	if route == null:
		route = get_node_or_null(route_path) as SaisiesRoute
	if route != null and route.route_ready():
		_build()
	else:
		call_deferred("_try_build")

func _build() -> void:
	if village_ready or route == null:
		return
	_rng.seed = random_seed
	from_m = clampf(from_m, 0.0, route.length_m)
	to_m = clampf(maxf(to_m, from_m + 1.0), 0.0, route.length_m)
	_make_materials()
	var street := _group("S01S03Street")
	var buildings := _group("S01S03Buildings")
	var details := _group("S01S03StreetDetails")
	var chairlift := _group("S03Chairlift")
	add_child(street)
	add_child(buildings)
	add_child(details)
	add_child(chairlift)

	_build_sidewalks(street)
	_build_resort_frontage(buildings)
	_build_s02_intersection(details)
	_build_s03_chairlift(chairlift)
	set_meta("saisies_village_ready", true)
	set_meta("saisies_village_scene_ids", ["S01", "S02", "S03"])
	set_meta("saisies_village_from_m", from_m)
	set_meta("saisies_village_to_m", to_m)
	set_meta("saisies_village_building_count", buildings.get_child_count())
	set_meta("saisies_village_chairlift_towers", chairlift.get_meta("tower_count", 0))
	village_ready = true

func _group(node_name: String) -> Node3D:
	var group := Node3D.new()
	group.name = node_name
	return group

func _make_materials() -> void:
	_materials["cream"] = _texture_mat("painted_plaster_wall", Color(1.16, 1.04, 0.84), 0.84)
	_materials["cream_light"] = _texture_mat("painted_plaster_wall", Color(1.34, 1.22, 1.00), 0.82)
	_materials["timber"] = _texture_mat("brown_planks_09", Color(0.72, 0.46, 0.25), 0.86)
	_materials["timber_resort_dark"] = _texture_mat("brown_planks_09", Color(0.34, 0.20, 0.12), 0.92)
	_materials["timber_dark"] = _texture_mat("wood_planks_grey", Color(0.34, 0.33, 0.30), 0.90)
	_materials["hotel"] = _mat(Color(0.085, 0.095, 0.09), 0.88)
	_materials["roof"] = _texture_mat("clay_roof_tiles_02", Color(0.45, 0.44, 0.41), 0.90)
	# The source right-hand lodge has a pale grey metal roof.  The clay tile
	# texture carries a red/orange base, so use a neutral material here instead
	# of tinting that texture and leaving the roof visually terracotta.
	_materials["roof_grey"] = _mat(Color(0.42, 0.46, 0.46), 0.94)
	_materials["roof_dark"] = _mat(Color(0.15, 0.17, 0.17), 0.94)
	_materials["roof_restaurant"] = _mat(Color(0.24, 0.20, 0.16), 0.92)
	_materials["window"] = _mat(Color(0.025, 0.07, 0.09), 0.23)
	# Street-facing shop glazing should read as dark reflective glass rather than
	# the flat grey-brown panels that previously swallowed the mullions.
	_materials["window_warm"] = _mat(Color(0.035, 0.095, 0.105), 0.16, 0.22)
	_materials["glass"] = _mat(Color(0.035, 0.11, 0.15), 0.18, 0.05)
	_materials["stone"] = _texture_mat("stacked_stone_wall", Color(0.84, 0.82, 0.72), 0.96)
	_materials["concrete"] = _mat(Color(0.39, 0.41, 0.39), 0.94)
	_materials["concrete"].cull_mode = BaseMaterial3D.CULL_DISABLED
	_materials["asphalt"] = _texture_mat("gravel_floor_02", Color(0.62, 0.63, 0.59), 0.97)
	_materials["soil"] = _mat(Color(0.24, 0.17, 0.09), 1.0)
	_materials["grass"] = _mat(Color(0.29, 0.52, 0.16), 0.98)
	_materials["leaf"] = _mat(Color(0.20, 0.40, 0.13), 0.96)
	_materials["metal"] = _mat(Color(0.54, 0.60, 0.61), 0.42, 0.35)
	_materials["cable"] = _mat(Color(0.06, 0.07, 0.07), 0.75)
	_materials["sign"] = _mat(Color(0.92, 0.86, 0.67), 0.72)
	_materials["awning"] = _mat(Color(0.94, 0.84, 0.67), 0.82)
	_materials["awning_shadow"] = _mat(Color(0.62, 0.47, 0.28), 0.86)
	_materials["store_interior"] = _mat(Color(0.045, 0.038, 0.030), 0.92)
	# The restaurant ground-floor panes are thin reflective glazing.  Keep a
	# dark interior behind them, but let the display geometry read through the
	# glass instead of turning the whole shop into one opaque grey slab.
	_materials["store_glass"] = _mat(Color(0.035, 0.12, 0.16, 0.28), 0.14, 0.05)
	_materials["store_glass"].transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_materials["store_glass"].cull_mode = BaseMaterial3D.CULL_DISABLED
	_materials["flowers"] = _mat(Color(0.88, 0.16, 0.22), 0.82)
	_materials["timber_lodge"] = _texture_mat("brown_planks_09", Color(0.22, 0.12, 0.07), 0.92)

func _mat(color: Color, roughness := 0.84, metallic := 0.0) -> StandardMaterial3D:
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
	var distance := clampf(s, from_m, to_m)
	anchor.position = route.pos_at(distance) + route.left_at(distance) * u
	anchor.position.y = route.ground_y(distance, u)
	anchor.basis = Basis.looking_at(route.tangent_at(distance), Vector3.UP)
	parent.add_child(anchor)
	return anchor

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

func _cylinder(top: float, bottom: float, height: float, segments := 16) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top
	mesh.bottom_radius = bottom
	mesh.height = height
	mesh.radial_segments = segments
	return mesh

func _sphere(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	return mesh

func _instance_model(parent: Node3D, model_name: String, position: Vector3, scale: Vector3 = Vector3.ONE, yaw := 0.0) -> Node3D:
	var path := "res://assets/models/%s/%s_1k.gltf" % [model_name, model_name]
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var instance := packed.instantiate() as Node3D
	if instance == null:
		return null
	instance.position = position
	instance.scale = scale
	instance.rotation.y = yaw
	parent.add_child(instance)
	return instance

func _build_resort_frontage(parent: Node3D) -> void:
	# S01: close left restaurant, taller dark hotel behind it, and an offset
	# timber resort block on the right.  These are deliberately different
	# masses so the first frame reads as a real street frontage.
	_build_restaurant_block(parent)
	_build_hotel_block(parent, 82.0, 10.0, 16.0, 9.6, 4)
	_build_resort_block(parent, 94.0, -19.0, 18.5, 8.0, 2, _materials["timber_lodge"], _materials["roof_grey"], "Right_Alpine_Lodge", false)
	_build_s01_middle_houses(parent)
	_build_resort_block(parent, 171.0, -11.8, 14.0, 8.0, 2, _materials["cream_light"], _materials["roof"], "Street_Cafe", true)
	_build_resort_block(parent, 237.0, 11.4, 16.0, 8.0, 2, _materials["timber_dark"], _materials["roof_dark"], "Shop_Block", true)
	_build_resort_block(parent, 333.0, -11.2, 15.0, 8.5, 2, _materials["timber"], _materials["roof"], "Intersection_Lodge", false)
	_build_resort_block(parent, 433.0, 12.5, 18.0, 8.5, 2, _materials["cream"], _materials["roof"], "Lower_Resort_House", false)
	_build_resort_block(parent, 523.0, -14.5, 12.0, 7.5, 1, _materials["timber"], _materials["roof_dark"], "Exit_Shed", false)

	# Real asset props make the sidewalk scale legible and break up the repeated
	# primitive facades without adding people or vehicles.
	for spec in [
		{"s": 158.0, "u": 8.4, "model": "painted_wooden_bench", "scale": 0.84},
		{"s": 188.0, "u": -8.8, "model": "street_lamp_02", "scale": 1.05},
		{"s": 246.0, "u": 8.2, "model": "planter_box_01", "scale": 1.10},
		{"s": 362.0, "u": -8.8, "model": "potted_plant_02", "scale": 0.90},
		{"s": 452.0, "u": 8.3, "model": "street_lamp_02", "scale": 1.00}
	]:
		var spec_dict: Dictionary = spec
		var distance := float(spec_dict["s"])
		var lateral := float(spec_dict["u"])
		var prop_anchor := _anchor(parent, distance, lateral, "S01S03Prop_%03d" % int(distance))
		_instance_model(prop_anchor, String(spec_dict["model"]), Vector3.ZERO, Vector3.ONE * float(spec_dict["scale"]), _rng.randf_range(-0.12, 0.12))

	# Fill the grass gap between each resort footprint and the curb with short,
	# route-aligned paving.  The blocks remain on their own anchors, while these
	# pads make the street frontage read as a connected village sidewalk.
	for spec in [
		{"s": 58.0, "u": 11.8, "width": 27.0, "depth": 8.8},
		{"s": 84.0, "u": 13.0, "width": 18.0, "depth": 8.2},
		{"s": 94.0, "u": -19.0, "width": 18.5, "depth": 8.0},
		{"s": 124.0, "u": -11.0, "width": 9.5, "depth": 6.2},
		{"s": 141.0, "u": 10.2, "width": 10.5, "depth": 6.0},
		{"s": 158.0, "u": -11.4, "width": 8.5, "depth": 5.8},
		{"s": 171.0, "u": -11.8, "width": 14.0, "depth": 8.0},
		{"s": 237.0, "u": 11.4, "width": 16.0, "depth": 8.0}
	]:
		var pad: Dictionary = spec
		_build_frontage_pad(parent, float(pad["s"]), float(pad["u"]), float(pad["width"]), float(pad["depth"]))

func _build_frontage_pad(parent: Node3D, s: float, u: float, width: float, depth: float) -> void:
	var side := 1.0 if u >= 0.0 else -1.0
	var road_edge := route.road_width_at(s) * 0.5 + 0.14
	var building_edge := absf(u) - depth * 0.5 + 0.12
	var span := maxf(building_edge - road_edge, 1.0)
	var s0 := maxf(from_m, s - (width + 1.1) * 0.5)
	var s1 := minf(to_m, s + (width + 1.1) * 0.5)
	var u0 := side * road_edge
	var u1 := side * building_edge
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := _route_point(s0, u0, 0.055)
	var b := _route_point(s0, u1, 0.055)
	var c := _route_point(s1, u1, 0.055)
	var d := _route_point(s1, u0, 0.055)
	_add_surface_quad(surface, a, b, c, d)
	surface.generate_normals()
	var pad := MeshInstance3D.new()
	pad.name = "S01FrontagePaving_%03d" % int(s)
	pad.mesh = surface.commit()
	pad.material_override = _materials["concrete"]
	parent.add_child(pad)

func _build_restaurant_block(parent: Node3D) -> void:
	# The source opening is a two-storey cream restaurant with a broad timber
	# gable and a commercial ground floor.  It is authored separately from the
	# repeated lodge blocks so its frontage reads immediately at S01 scale.
	var s := 58.0
	var u := 11.8
	var width := 27.0
	var depth := 8.8
	var stories := 2
	var block := _anchor(parent, s, u, "Restaurant_Ravoula")
	var floor_height := 2.55
	var foundation := 0.38
	var body_height := floor_height * float(stories)
	var foundation_burial := _foundation_burial_depth(block, depth + 0.42, width + 0.42)
	_part(block, _box(Vector3(depth + 0.42, foundation + foundation_burial, width + 0.42)), _materials["stone"], Vector3(0.0, foundation * 0.5 - foundation_burial * 0.5, 0.0))
	# Keep the upper floor as one weather-tight volume, but leave the commercial
	# floor open behind its framed glazing.  The rear and side returns supply a
	# real shop interior without a solid cream slab behind every window.
	_part(block, _box(Vector3(depth, floor_height, width)), _materials["cream"], Vector3(0.0, foundation + floor_height * 1.5, 0.0))
	_part(block, _box(Vector3(0.62, floor_height - 0.12, width - 0.34)), _materials["cream"], Vector3(-depth * 0.5 + 0.31, foundation + 0.5 + (floor_height - 0.12) * 0.5, 0.0))
	_part(block, _box(Vector3(depth - 0.62, floor_height - 0.12, 0.58)), _materials["cream"], Vector3(0.31, foundation + 0.5 + (floor_height - 0.12) * 0.5, -width * 0.5 + 0.29))
	_part(block, _box(Vector3(depth - 0.62, floor_height - 0.12, 0.58)), _materials["cream"], Vector3(0.31, foundation + 0.5 + (floor_height - 0.12) * 0.5, width * 0.5 - 0.29))
	_part(block, _box(Vector3(depth, 0.30, width)), _materials["cream_light"], Vector3(0.0, foundation + floor_height - 0.12, 0.0))
	# The road-facing facade is the broad end of the building.  The ridge runs
	# through the short building depth, so the roof must use the frontage as its
	# span and rotate that span onto local Z.  This keeps the roof footprint on
	# the same 8.8 x 27 m body instead of turning a long flat strip into the hero.
	var roof_eave_y := foundation + body_height
	_add_gable_roof(block, width, depth, roof_eave_y, _materials["roof_restaurant"], PI * 0.5)
	var restaurant_roof_half_span := width * 0.5 + 0.34
	var restaurant_gable_height := restaurant_roof_half_span * tan(deg_to_rad(28.0))
	var front_sign := 1.0
	var front_x := front_sign * (depth * 0.5 + 0.055)
	_add_restaurant_gable_end(block, front_sign * (depth * 0.5 + 0.04), "RestaurantFrontGableEnd", width, roof_eave_y, restaurant_gable_height, true)
	_add_restaurant_gable_end(block, -front_sign * (depth * 0.5 + 0.04), "RestaurantRearGableEnd", width, roof_eave_y, restaurant_gable_height, false)

	# Large upper panes with timber mullions and a continuous balcony panel.
	var upper_y := foundation + floor_height * 1.55
	# The source upper storey is a pale facade with broad glass bays and a dark
	# timber centre gable.  Keep the horizontal surround light; timber remains
	# in the mullions and balcony rail rather than becoming one brown band.
	_part(block, _box(Vector3(0.12, 1.58, width * 0.94)), _materials["cream_light"], Vector3(front_x + 0.02, foundation + floor_height * 1.55, 0.0))
	for z in [-width * 0.39, -width * 0.26, -width * 0.13, 0.0, width * 0.13, width * 0.26, width * 0.39]:
		_part(block, _box(Vector3(0.14, 1.42, width * 0.095)), _materials["glass"], Vector3(front_x + 0.10, upper_y, z))
		_part(block, _box(Vector3(0.16, 1.52, 0.085)), _materials["timber_dark"], Vector3(front_x + 0.095, upper_y, z - width * 0.065))
	_part(block, _box(Vector3(0.18, 0.11, width * 0.86)), _materials["timber"], Vector3(front_x + 0.10, upper_y - 0.67, 0.0))
	_part(block, _box(Vector3(0.14, 0.48, width * 0.86)), _materials["timber"], Vector3(front_x + 0.19, upper_y - 0.36, 0.0))
	_part(block, _box(Vector3(0.14, 0.11, width * 0.88)), _materials["timber_dark"], Vector3(front_x + 0.24, upper_y - 0.10, 0.0))
	var balcony_upright_count := 0
	for upright_index in range(11):
		var upright_t := float(upright_index) / 10.0
		var upright_z := lerpf(-width * 0.43, width * 0.43, upright_t)
		_part(block, _box(Vector3(0.18, 0.96, 0.18)), _materials["timber_dark"], Vector3(front_x + 0.23, upper_y - 0.22, upright_z))
		balcony_upright_count += 1

	# Ground-floor glazing is a set of recessed, individually framed bays rather
	# than one opaque rectangle.  The dark interior layer gives each pane a real
	# reveal, while the smaller glass faces leave visible plaster and timber.
	var storefront_y := foundation + 1.02
	var storefront_zs := [-width * 0.40, -width * 0.265, -width * 0.13, width * 0.13, width * 0.265, width * 0.40]
	var storefront_index := 0
	for z_value in storefront_zs:
		var bay_z: float = float(z_value)
		var bay_span := width * 0.095
		var interior := _part(block, _box(Vector3(0.42, 1.78, bay_span + 0.18)), _materials["store_interior"], Vector3(front_x + 0.24, storefront_y, bay_z))
		interior.name = "RestaurantStoreInterior_%02d" % storefront_index
		var pane := _part(block, _box(Vector3(0.07, 1.54, bay_span)), _materials["store_glass"], Vector3(front_x + 0.54, storefront_y, bay_z))
		pane.name = "RestaurantStorePane_%02d" % storefront_index
		storefront_index += 1
	for z_value in [-width * 0.468, -width * 0.332, -width * 0.198, -width * 0.065, width * 0.065, width * 0.198, width * 0.332, width * 0.468]:
		var frame_z: float = float(z_value)
		_part(block, _box(Vector3(0.16, 1.84, 0.085)), _materials["timber_dark"], Vector3(front_x + 0.65, storefront_y, frame_z))
	_part(block, _box(Vector3(0.18, 0.12, width * 0.88)), _materials["timber_dark"], Vector3(front_x + 0.66, storefront_y - 0.82, 0.0))
	_part(block, _box(Vector3(0.18, 0.13, width * 0.91)), _materials["timber_dark"], Vector3(front_x + 0.66, foundation + 2.12, 0.0))

	# A recessed entrance interrupts the storefront rhythm and exposes a narrow
	# dark vestibule, with proper jambs, lintel, and a small metal handle.
	var door_interior := _part(block, _box(Vector3(0.42, 1.90, 1.26)), _materials["store_interior"], Vector3(front_x + 0.25, storefront_y, 0.0))
	door_interior.name = "RestaurantDoorInterior"
	var door_glass := _part(block, _box(Vector3(0.07, 1.68, 0.92)), _materials["store_glass"], Vector3(front_x + 0.56, storefront_y, 0.0))
	door_glass.name = "RestaurantDoorGlass"
	for door_z in [-0.58, 0.58]:
		_part(block, _box(Vector3(0.16, 1.92, 0.11)), _materials["timber_dark"], Vector3(front_x + 0.67, storefront_y, door_z))
	_part(block, _box(Vector3(0.16, 0.12, 1.30)), _materials["timber_dark"], Vector3(front_x + 0.67, foundation + 1.98, 0.0))
	_part(block, _cylinder(0.035, 0.035, 0.16, 10), _materials["metal"], Vector3(front_x + 0.68, storefront_y, 0.28), Vector3(PI * 0.5, 0.0, 0.0))
	# Two simple clothing racks occupy the canopy depth.  They use folded/hung
	# rectangular garments only, so the shop reads as merchandise without people.
	_add_restaurant_clothing_display(block, front_x, -width * 0.28, foundation, 0)
	_add_restaurant_clothing_display(block, front_x, width * 0.28, foundation, 1)
	# Four compact racks sit just inside separate window bays.  Their rails,
	# hanging colour blocks, and posters remain behind the thin pane, while the
	# two racks above stay under the canopy for a layered street display.
	for display_index in range(4):
		var display_z: float = float([-width * 0.40, -width * 0.13, width * 0.13, width * 0.40][display_index])
		_add_restaurant_interior_display(block, front_x, display_z, foundation, display_index)

	# The shop awning is a real 1.65 m projection with a sloped canopy, dark
	# alternating stripes, a valance, and four street-side support posts.
	var awning_depth := 1.65
	var awning_angle := deg_to_rad(-7.0)
	var awning_center_x := front_x + awning_depth * 0.52
	var awning_y := foundation + 2.39
	var restaurant_awning := _part(block, _box(Vector3(awning_depth, 0.12, width * 0.93)), _materials["awning"], Vector3(awning_center_x, awning_y, 0.0), Vector3(0.0, 0.0, awning_angle))
	restaurant_awning.name = "RestaurantAwning_1p65m"
	for stripe_z_value in [-width * 0.39, -width * 0.26, -width * 0.13, 0.0, width * 0.13, width * 0.26, width * 0.39]:
		var stripe_z: float = float(stripe_z_value)
		_part(block, _box(Vector3(awning_depth - 0.08, 0.035, 0.105)), _materials["awning_shadow"], Vector3(awning_center_x, awning_y + 0.075, stripe_z), Vector3(0.0, 0.0, awning_angle))
	var awning_edge_x := front_x + awning_depth + 0.08
	_part(block, _box(Vector3(0.12, 0.28, width * 0.94)), _materials["awning"], Vector3(awning_edge_x, foundation + 2.22, 0.0))
	for support_z_value in [-width * 0.40, -width * 0.135, width * 0.135, width * 0.40]:
		var support_z: float = float(support_z_value)
		_part(block, _box(Vector3(0.12, 1.95, 0.12)), _materials["timber_dark"], Vector3(front_x + awning_depth - 0.12, foundation + 1.05, support_z))
		_part(block, _box(Vector3(0.10, 0.10, 0.62)), _materials["timber_dark"], Vector3(front_x + awning_depth - 0.17, foundation + 1.73, support_z), Vector3(0.0, 0.0, deg_to_rad(-32.0)))

	# Two separate dark sign bands sit above the awning: one just under the
	# gable and one between the upper glazing and canopy, matching the source's
	# readable commercial lettering instead of hiding it behind the awning.
	_add_restaurant_sign_band(block, front_x, -width * 0.23, foundation + 4.92, width * 0.38, "RESTAURANT", "RestaurantSignBandUpper", 0.26)
	_add_restaurant_sign_band(block, front_x, width * 0.23, foundation + 2.98, width * 0.40, "LA TABLE DE L'ALPAGE", "RestaurantSignBandLower", 0.30)

	# A few real terrace tables and chairs occupy the awning depth and give the
	# shopfront a human-scale edge without introducing animated people.
	for table_z_value in [-width * 0.28, width * 0.28]:
		var table_z: float = float(table_z_value)
		var table_x := front_x + 1.05
		_part(block, _box(Vector3(0.72, 0.10, 0.72)), _materials["timber"], Vector3(table_x, foundation + 0.92, table_z))
		_part(block, _cylinder(0.055, 0.075, 0.82, 12), _materials["metal"], Vector3(table_x, foundation + 0.49, table_z))
		for chair_side in [-1.0, 1.0]:
			_part(block, _box(Vector3(0.46, 0.10, 0.46)), _materials["timber_dark"], Vector3(table_x + chair_side * 0.62, foundation + 0.58, table_z))
			_part(block, _box(Vector3(0.10, 0.52, 0.46)), _materials["timber_dark"], Vector3(table_x + chair_side * 0.82, foundation + 0.82, table_z))

	# The short end of the restaurant carries the source's side terrace: a
	# planted/paved apron, red sun umbrellas, and a small A-board.  It gives the
	# gable end a second readable face instead of ending in a blank wall.
	var terrace_z := width * 0.5 + 1.05
	_part(block, _box(Vector3(depth + 1.45, 0.16, 3.55)), _materials["concrete"], Vector3(0.28, foundation + 0.08, terrace_z))
	_part(block, _box(Vector3(depth + 1.42, 0.12, 0.12)), _materials["timber_dark"], Vector3(0.28, foundation + 0.78, terrace_z + 1.66))
	for terrace_x in [-depth * 0.38, 0.0, depth * 0.38]:
		_part(block, _box(Vector3(0.12, 0.92, 0.12)), _materials["timber_dark"], Vector3(terrace_x, foundation + 0.50, terrace_z + 1.63))
	for umbrella_x_value in [-depth * 0.30, 0.0, depth * 0.30]:
		var umbrella_x: float = float(umbrella_x_value)
		_part(block, _cylinder(0.08, 0.92, 0.16, 24), _materials["flowers"], Vector3(umbrella_x, foundation + 2.24, terrace_z + 0.42))
		_part(block, _cylinder(0.035, 0.035, 1.72, 10), _materials["metal"], Vector3(umbrella_x, foundation + 1.34, terrace_z + 0.42))
		_part(block, _box(Vector3(0.52, 0.08, 0.52)), _materials["timber_dark"], Vector3(umbrella_x, foundation + 0.48, terrace_z + 0.42))
	var board_z := terrace_z + 1.42
	for board_side in [-1.0, 1.0]:
		_part(block, _box(Vector3(0.12, 1.06, 0.72)), _materials["sign"], Vector3(front_x + 1.08, foundation + 0.68, board_z + board_side * 0.16), Vector3(0.0, 0.0, deg_to_rad(16.0 * board_side)))

	# Keep the street-facing upper edge as a narrow timber fascia.  The previous
	# full-height triangle read as a single wooden wall and hid the restaurant's
	# roof silhouette in the reference camera.
	_part(block, _box(Vector3(0.22, 0.22, width * 0.92)), _materials["timber_dark"], Vector3(front_x + 0.16, foundation + body_height + 0.10, 0.0))
	block.set_meta("saisies_s01_upper_window_bays", 7)
	block.set_meta("saisies_s01_ground_window_bays", 6)
	block.set_meta("saisies_s01_awning_supports", 4)
	block.set_meta("saisies_s01_awning_depth_m", awning_depth)
	block.set_meta("saisies_s01_sign_bands", 2)
	block.set_meta("saisies_s01_has_shop_sign", true)
	block.set_meta("saisies_s01_has_label_sign", true)
	block.set_meta("saisies_s01_display_bays", 6)
	block.set_meta("saisies_s01_clothing_display_racks", 2)
	block.set_meta("saisies_s01_clothing_display_items", 6)
	block.set_meta("saisies_s01_terrace_tables", 2)
	block.set_meta("saisies_s01_has_roof", true)
	block.set_meta("saisies_s01_balcony_uprights", balcony_upright_count)
	block.set_meta("saisies_s01_gable_caps", 2)
	block.set_meta("saisies_s01_foundation_burial_m", foundation_burial)

func _add_restaurant_clothing_display(parent: Node3D, front_x: float, z: float, foundation: float, index: int) -> void:
	var rack := Node3D.new()
	rack.name = "RestaurantClothingDisplay_%02d" % index
	rack.position = Vector3(front_x + 1.02, 0.0, z)
	parent.add_child(rack)
	var post := _part(rack, _box(Vector3(0.08, 1.35, 0.08)), _materials["metal"], Vector3(0.0, foundation + 0.68, 0.0))
	post.name = "DisplayPost"
	var rail := _part(rack, _box(Vector3(0.10, 0.08, 1.22)), _materials["metal"], Vector3(0.0, foundation + 1.35, 0.0))
	rail.name = "DisplayRail"
	var garment_materials: Array[Material] = [_materials["flowers"], _materials["timber"], _materials["awning_shadow"]]
	for item_index in range(3):
		var garment_material: Material = garment_materials[(item_index + index) % garment_materials.size()]
		var garment_z := -0.42 + float(item_index) * 0.42
		var garment := _part(rack, _box(Vector3(0.14, 0.54, 0.30)), garment_material, Vector3(0.03, foundation + 1.05, garment_z))
		garment.name = "DisplayGarment_%02d" % item_index

func _add_restaurant_interior_display(parent: Node3D, front_x: float, z: float, foundation: float, index: int) -> void:
	var display := Node3D.new()
	display.name = "RestaurantInteriorDisplay_%02d" % index
	display.position = Vector3(front_x + 0.41, 0.0, z)
	parent.add_child(display)
	var post := _part(display, _box(Vector3(0.055, 1.20, 0.055)), _materials["metal"], Vector3(0.0, foundation + 0.63, 0.0))
	post.name = "InteriorDisplayPost"
	var rail := _part(display, _box(Vector3(0.065, 0.055, 0.92)), _materials["metal"], Vector3(0.0, foundation + 1.25, 0.0))
	rail.name = "InteriorDisplayRail"
	var garment_materials: Array[Material] = [_materials["flowers"], _materials["timber"], _materials["awning_shadow"]]
	for item_index in range(3):
		var garment_material: Material = garment_materials[(item_index + index) % garment_materials.size()]
		var garment_z := -0.30 + float(item_index) * 0.30
		var garment := _part(display, _box(Vector3(0.075, 0.44, 0.19)), garment_material, Vector3(0.035, foundation + 0.98, garment_z))
		garment.name = "InteriorDisplayGarment_%02d" % item_index
	var poster_material: Material = _materials["awning_shadow"] if index % 2 == 0 else _materials["flowers"]
	var poster := _part(display, _box(Vector3(0.035, 0.58, 0.30)), poster_material, Vector3(0.025, foundation + 1.00, 0.40))
	poster.name = "InteriorDisplayPoster"

func _add_restaurant_sign_band(parent: Node3D, front_x: float, z: float, y: float, length: float, text_value: String, node_name: String, band_height := 0.34) -> void:
	var backing := _part(parent, _box(Vector3(0.18, band_height, length)), _materials["roof_dark"], Vector3(front_x + 0.28, y, z))
	backing.name = node_name
	var plaque := _part(parent, _box(Vector3(0.12, band_height * 0.72, length * 0.92)), _materials["roof_dark"], Vector3(front_x + 0.40, y, z))
	plaque.name = "%sPlaque" % node_name
	var shop_label := Label3D.new()
	shop_label.name = "%sLabel" % node_name
	shop_label.text = text_value
	shop_label.font_size = 72
	shop_label.pixel_size = 0.005
	shop_label.modulate = Color(0.98, 0.92, 0.70)
	shop_label.outline_size = 6
	shop_label.outline_modulate = Color(0.08, 0.045, 0.025)
	shop_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	shop_label.rotation.y = PI * 0.5
	shop_label.position = Vector3(front_x + 0.54, y, z)
	parent.add_child(shop_label)

func _build_hotel_block(parent: Node3D, s: float, u: float, width: float, depth: float, stories: int) -> void:
	# The hotel sits immediately behind the restaurant as a dark, low-slope
	# volume.  Each street-facing floor gets a full-width balcony so the source
	# reads as a stacked lodging block rather than a single pointed tower.
	var block := _anchor(parent, s, u, "Rear_Hotel")
	var floor_height := 2.45
	var foundation := 0.70
	var body_height := floor_height * float(stories)
	var foundation_burial := _foundation_burial_depth(block, depth + 0.42, width + 0.42)
	_part(block, _box(Vector3(depth + 0.42, foundation + foundation_burial, width + 0.42)), _materials["stone"], Vector3(0.0, foundation * 0.5 - foundation_burial * 0.5, 0.0))
	_part(block, _box(Vector3(depth, body_height, width)), _materials["hotel"], Vector3(0.0, foundation + body_height * 0.5, 0.0))
	var front_sign := 1.0 if u >= 0.0 else -1.0
	var front_x := front_sign * (depth * 0.5 + 0.055)
	var balcony_count := 0
	for floor in range(stories):
		var floor_y := foundation + floor_height * (float(floor) + 0.55)
		for z in [-width * 0.38, -width * 0.13, width * 0.13, width * 0.38]:
			_part(block, _box(Vector3(0.10, 1.30, width * 0.14)), _materials["window_warm"], Vector3(front_x, floor_y, z))
			_part(block, _box(Vector3(0.12, 1.40, 0.08)), _materials["timber_dark"], Vector3(front_x + front_sign * 0.07, floor_y, z - width * 0.075))
		var balcony_width := width * 0.93
		var balcony_x := front_x + front_sign * 0.42
		var balcony_deck := _part(block, _box(Vector3(0.82, 0.12, balcony_width)), _materials["timber"], Vector3(balcony_x, floor_y - 0.22, 0.0))
		balcony_deck.name = "HotelBalconyDeck_%02d" % floor
		var rail_x := balcony_x + front_sign * 0.30
		var balcony_rail := _part(block, _box(Vector3(0.12, 0.52, balcony_width * 0.94)), _materials["timber"], Vector3(rail_x, floor_y + 0.12, 0.0))
		balcony_rail.name = "HotelBalconyRail_%02d" % floor
		_part(block, _box(Vector3(0.16, 0.10, balcony_width * 0.98)), _materials["timber_dark"], Vector3(rail_x + front_sign * 0.06, floor_y + 0.42, 0.0))
		for rail_index in range(9):
			var rail_t := float(rail_index) / 8.0
			var rail_z := lerpf(-balcony_width * 0.46, balcony_width * 0.46, rail_t)
			_part(block, _box(Vector3(0.14, 0.62, 0.10)), _materials["timber_dark"], Vector3(rail_x + front_sign * 0.07, floor_y + 0.13, rail_z))
		balcony_count += 1
	# Small end windows keep the hotel volume closed when the camera passes the
	# restaurant's gable without turning the end into another hero facade.
	for floor in range(stories):
		var end_y := foundation + floor_height * (float(floor) + 0.55)
		for end_sign in [-1.0, 1.0]:
			var end_z: float = float(end_sign) * (width * 0.5 + 0.055)
			_part(block, _box(Vector3(depth * 0.24, 1.02, 0.10)), _materials["window"], Vector3(-depth * 0.22, end_y, end_z))
			_part(block, _box(Vector3(depth * 0.24, 1.02, 0.10)), _materials["window"], Vector3(depth * 0.22, end_y, end_z))
	var roof := _add_hotel_low_slope_roof(block, depth, width, foundation + body_height, _materials["roof_dark"])
	roof.name = "HotelLowSlopeRoof"
	block.set_meta("saisies_s01_hotel_stories", stories)
	block.set_meta("saisies_s01_hotel_balconies", balcony_count)
	block.set_meta("saisies_s01_hotel_roof_angle_deg", 9.0)
	block.set_meta("saisies_s01_hotel_grounded", true)
	block.set_meta("saisies_s01_hotel_foundation_burial_m", foundation_burial)

func _add_hotel_low_slope_roof(parent: Node3D, depth: float, width: float, eave_y: float, material: Material) -> Node3D:
	var roof_parent := Node3D.new()
	roof_parent.name = "HotelLowSlopeRoof"
	parent.add_child(roof_parent)
	var angle := deg_to_rad(9.0)
	var half_span := depth * 0.5 + 0.32
	var slab_length := half_span / cos(angle)
	var center_y := eave_y + half_span * 0.5 * tan(angle)
	var roof_neg := _part(roof_parent, _box(Vector3(slab_length, 0.22, width + 0.48)), material, Vector3(-half_span * 0.5, center_y, 0.0), Vector3(0.0, 0.0, angle))
	roof_neg.name = "RoofSlopeNegX"
	var roof_pos := _part(roof_parent, _box(Vector3(slab_length, 0.22, width + 0.48)), material, Vector3(half_span * 0.5, center_y, 0.0), Vector3(0.0, 0.0, -angle))
	roof_pos.name = "RoofSlopePosX"
	var ridge := _part(roof_parent, _box(Vector3(0.28, 0.22, width + 0.56)), material, Vector3(0.0, eave_y + half_span * tan(angle), 0.0))
	ridge.name = "RoofRidgeCap"
	var roof_rise := half_span * tan(angle)
	for end_value in [-1.0, 1.0]:
		var end_sign: float = float(end_value)
		var gable := _part(roof_parent, _gable_triangle_mesh(0.14, depth, roof_rise), material, Vector3(0.0, eave_y - 0.04, end_sign * (width * 0.5 + 0.07)), Vector3(0.0, PI * 0.5, 0.0))
		gable.name = "SealedGableEndNeg" if end_sign < 0.0 else "SealedGableEndPos"
	return roof_parent

func _build_s01_middle_houses(parent: Node3D) -> void:
	# Three staggered, route-anchored houses close the empty middle distance while
	# leaving a clear road corridor and visible depth between the footprints.
	var specs := [
		{"s": 124.0, "u": -11.0, "width": 9.5, "depth": 6.2, "stories": 2, "body": _materials["cream_light"], "roof": _materials["roof_grey"], "name": "S01MiddleHouse_A"},
		{"s": 141.0, "u": 10.2, "width": 10.5, "depth": 6.0, "stories": 2, "body": _materials["timber_dark"], "roof": _materials["roof_dark"], "name": "S01MiddleHouse_B"},
		{"s": 158.0, "u": -11.4, "width": 8.5, "depth": 5.8, "stories": 1, "body": _materials["cream"], "roof": _materials["roof"], "name": "S01MiddleHouse_C"}
	]
	for item in specs:
		var spec: Dictionary = item
		_build_resort_block(parent, float(spec["s"]), float(spec["u"]), float(spec["width"]), float(spec["depth"]), int(spec["stories"]), spec["body"] as Material, spec["roof"] as Material, String(spec["name"]), false)
	parent.get_parent().set_meta("saisies_s01_middle_house_count", specs.size())

func _gable_triangle_mesh(thickness: float, span: float, height: float) -> Mesh:
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
	# Front/back triangular faces.
	surface.add_vertex(front_left); surface.add_vertex(front_right); surface.add_vertex(front_peak)
	surface.add_vertex(back_right); surface.add_vertex(back_left); surface.add_vertex(back_peak)
	# Sloped sides, base, and end caps close the shallow timber gable.
	surface.add_vertex(front_left); surface.add_vertex(front_peak); surface.add_vertex(back_peak)
	surface.add_vertex(front_left); surface.add_vertex(back_peak); surface.add_vertex(back_left)
	surface.add_vertex(front_peak); surface.add_vertex(front_right); surface.add_vertex(back_right)
	surface.add_vertex(front_peak); surface.add_vertex(back_right); surface.add_vertex(back_peak)
	surface.add_vertex(front_left); surface.add_vertex(back_left); surface.add_vertex(back_right)
	surface.add_vertex(front_left); surface.add_vertex(back_right); surface.add_vertex(front_right)
	surface.generate_normals()
	return surface.commit()

func _add_restaurant_gable_end(parent: Node3D, x: float, node_name: String, width: float, eave_y: float, gable_height: float, with_front_glass: bool) -> void:
	var gable := Node3D.new()
	gable.name = node_name
	gable.position = Vector3(x, 0.0, 0.0)
	parent.add_child(gable)
	# Both end caps close the roof volume.  The front cap carries the source's
	# central timber triangle; the rear cap stays weather-tight and unobtrusive.
	_part(gable, _gable_triangle_mesh(0.22, width * 0.96, gable_height), _materials["cream_light"], Vector3(0.0, eave_y, 0.0))
	var outward := 1.0 if x >= 0.0 else -1.0
	_part(gable, _gable_triangle_mesh(0.12, width * 0.38, gable_height * 0.82), _materials["timber_resort_dark"], Vector3(outward * 0.13, eave_y + 0.23, 0.0))
	if with_front_glass:
		# Wide side panes sit under the gable peak and keep the cream / glass /
		# timber division legible when the camera sees the end head-on.
		for pane_z in [-width * 0.39, -width * 0.24, width * 0.24, width * 0.39]:
			_part(gable, _box(Vector3(0.10, 1.12, 1.28)), _materials["glass"], Vector3(outward * 0.15, eave_y - 0.78, pane_z))
			_part(gable, _box(Vector3(0.12, 1.24, 0.12)), _materials["timber_dark"], Vector3(outward * 0.22, eave_y - 0.78, pane_z))

func _build_resort_block(parent: Node3D, s: float, u: float, width: float, depth: float, stories: int, body_material: Material, roof_material: Material, block_name: String, storefront: bool) -> void:
	var block := _anchor(parent, s, u, block_name)
	var floor_height := 2.55
	var foundation := 0.62 if stories < 3 else 0.92
	var body_height := floor_height * float(stories)
	var foundation_burial := _foundation_burial_depth(block, depth + 0.42, width + 0.42)
	_part(block, _box(Vector3(depth + 0.42, foundation + foundation_burial, width + 0.42)), _materials["stone"], Vector3(0.0, foundation * 0.5 - foundation_burial * 0.5, 0.0))
	_part(block, _box(Vector3(depth, body_height, width)), body_material, Vector3(0.0, foundation + body_height * 0.5, 0.0))
	_add_gable_roof(block, depth, width, foundation + body_height, roof_material)
	if block_name == "Right_Alpine_Lodge":
		_add_right_lodge_roof_grid(block, depth, width, foundation + body_height)
		block.set_meta("saisies_s01_right_lodge_roof_grid", true)
		block.set_meta("saisies_s01_right_lodge_roof_ribs", 7)
		block.set_meta("saisies_s01_right_lodge_width_m", width)
		block.set_meta("saisies_s01_right_lodge_foundation_burial_m", foundation_burial)
	var front_sign := 1.0 if u > 0.0 else -1.0
	var front_x := front_sign * (depth * 0.5 + 0.055)
	for floor in stories:
		var y := foundation + floor_height * (float(floor) + 0.56)
		for face_sign in [-1.0, 1.0]:
			var face_x: float = float(face_sign) * (depth * 0.5 + 0.055)
			for z in [-width * 0.28, width * 0.04, width * 0.32]:
				var window_material: Material = _materials["window_warm"] if (floor + int(absf(z) * 10.0)) % 4 == 0 else _materials["window"]
				_part(block, _box(Vector3(0.09, 1.30, 1.55)), window_material, Vector3(face_x, y, z))
				_part(block, _box(Vector3(0.10, 0.08, 1.67)), _materials["timber_dark"], Vector3(face_x + face_sign * 0.055, y - 0.70, z))
		# Gable-end windows keep the near end legible when the camera approaches
		# along the street axis.
		for end_sign in [-1.0, 1.0]:
			var end_z: float = float(end_sign) * (width * 0.5 + 0.055)
			for x in [-depth * 0.22, depth * 0.22]:
				_part(block, _box(Vector3(1.12, 1.08, 0.09)), _materials["window"], Vector3(x, y, end_z))
		if floor < stories - 1 or storefront:
			var balcony_width := width * (0.78 if storefront else 0.54)
			var balcony_x := front_sign * (depth * 0.5 + 0.48)
			_part(block, _box(Vector3(0.86, 0.12, balcony_width)), _materials["timber"], Vector3(balcony_x, y - 0.18, 0.0))
			# Broad wood railing panel, with a cap and evenly spaced uprights so
			# balconies read as usable resort architecture at distance.
			var rail_x := balcony_x + front_sign * 0.30
			_part(block, _box(Vector3(0.12, 0.46, balcony_width * 0.86)), _materials["timber"], Vector3(rail_x, y + 0.12, 0.0))
			_part(block, _box(Vector3(0.16, 0.10, balcony_width * 0.94)), _materials["timber_dark"], Vector3(rail_x + front_sign * 0.06, y + 0.40, 0.0))
			for rail_z in [-balcony_width * 0.47, -balcony_width * 0.24, 0.0, balcony_width * 0.24, balcony_width * 0.47]:
				_part(block, _box(Vector3(0.14, 0.58, 0.11)), _materials["timber_dark"], Vector3(rail_x + front_sign * 0.07, y + 0.12, rail_z))
	if storefront:
		var awning_y := foundation + 2.25
		_part(block, _box(Vector3(0.95, 0.10, width * 0.74)), _materials["awning"], Vector3(front_x + front_sign * 0.47, awning_y, 0.0), Vector3(0.0, 0.0, deg_to_rad(-8.0 * front_sign)))
		_part(block, _box(Vector3(0.13, 0.10, width * 0.80)), _materials["awning"], Vector3(front_x + front_sign * 0.92, awning_y - 0.13, 0.0))
		var storefront_y := foundation + 1.10
		for z in [-width * 0.34, -width * 0.11, width * 0.11, width * 0.34]:
			_part(block, _box(Vector3(0.14, 1.72, width * 0.16)), _materials["window_warm"], Vector3(front_x + front_sign * 0.06, storefront_y, z))
		for z in [-width * 0.225, 0.0, width * 0.225]:
			_part(block, _box(Vector3(0.16, 1.84, 0.10)), _materials["timber_dark"], Vector3(front_x + front_sign * 0.15, storefront_y, z))
		_part(block, _box(Vector3(0.18, 0.22, width * 0.84)), _materials["timber_dark"], Vector3(front_x + front_sign * 0.17, foundation + 2.28, 0.0))
		_part(block, _box(Vector3(0.18, 0.22, width * 0.70)), _materials["sign"], Vector3(front_x + front_sign * 0.38, foundation + 2.62, 0.0))

func _add_gable_roof(parent: Node3D, depth: float, width: float, eave_y: float, material: Material, roof_yaw := 0.0) -> void:
	var roof_parent := parent
	if absf(roof_yaw) > 0.001:
		roof_parent = Node3D.new()
		roof_parent.name = "RestaurantGableRoof"
		roof_parent.rotation.y = roof_yaw
		parent.add_child(roof_parent)
	var angle := deg_to_rad(28.0)
	var half_span := depth * 0.5 + 0.34
	var slab_length := half_span / cos(angle)
	var center_y := eave_y + half_span * 0.5 * tan(angle)
	var roof_neg := _part(roof_parent, _box(Vector3(slab_length, 0.24, width + 0.56)), material, Vector3(-half_span * 0.5, center_y, 0.0), Vector3(0.0, 0.0, angle))
	roof_neg.name = "RoofSlopeNegX"
	var roof_pos := _part(roof_parent, _box(Vector3(slab_length, 0.24, width + 0.56)), material, Vector3(half_span * 0.5, center_y, 0.0), Vector3(0.0, 0.0, -angle))
	roof_pos.name = "RoofSlopePosX"
	var ridge := _part(roof_parent, _box(Vector3(0.34, 0.25, width + 0.64)), material, Vector3(0.0, eave_y + half_span * tan(angle), 0.0))
	ridge.name = "RoofRidgeCap"
	if absf(roof_yaw) < 0.001:
		var roof_rise := half_span * tan(angle)
		for end_value in [-1.0, 1.0]:
			var end_sign: float = float(end_value)
			var gable := _part(roof_parent, _gable_triangle_mesh(0.14, depth, roof_rise), material, Vector3(0.0, eave_y - 0.04, end_sign * (width * 0.5 + 0.07)), Vector3(0.0, PI * 0.5, 0.0))
			gable.name = "SealedGableEndNeg" if end_sign < 0.0 else "SealedGableEndPos"

func _add_right_lodge_roof_grid(parent: Node3D, depth: float, width: float, eave_y: float) -> void:
	# Narrow dark ribs break the pale roof into the source's fine metal grid.  They
	# sit just above the existing slabs and follow their exact slope/footprint.
	var angle := deg_to_rad(28.0)
	var half_span := depth * 0.5 + 0.34
	var slab_length := half_span / cos(angle)
	var center_y := eave_y + half_span * 0.5 * tan(angle) + 0.13
	var roof_material: Material = _materials["metal"]
	for side in [-1.0, 1.0]:
		var side_f: float = float(side)
		for rib_index in range(7):
			var rib_t := float(rib_index) / 6.0
			var rib_z := lerpf(-width * 0.45, width * 0.45, rib_t)
			var rib := _part(parent, _box(Vector3(slab_length, 0.035, 0.055)), roof_material, Vector3(side_f * half_span * 0.5, center_y, rib_z), Vector3(0.0, 0.0, -side_f * angle))
			rib.name = "RightLodgeRoofRib_%d_%02d" % [int(side_f), rib_index]

func _build_sidewalks(parent: Node3D) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var s := from_m
	while s < minf(to_m, 560.0):
		var s1 := minf(s + 10.0, minf(to_m, 560.0))
		for side in [-1.0, 1.0]:
			var side_f: float = float(side)
			var half0 := route.road_width_at(s) * 0.5
			var half1 := route.road_width_at(s1) * 0.5
			var inner0: float = side_f * (half0 + 0.10)
			var inner1: float = side_f * (half1 + 0.10)
			var outer0: float = side_f * (half0 + 2.05)
			var outer1: float = side_f * (half1 + 2.05)
			var a := _route_point(s, inner0, 0.035)
			var b := _route_point(s, outer0, 0.035)
			var c := _route_point(s1, outer1, 0.035)
			var d := _route_point(s1, inner1, 0.035)
			_add_surface_quad(surface, a, b, c, d)
		s = s1
	surface.generate_normals()
	var sidewalk := MeshInstance3D.new()
	sidewalk.name = "S01S03ContinuousSidewalks"
	sidewalk.mesh = surface.commit()
	sidewalk.material_override = _materials["concrete"]
	parent.add_child(sidewalk)

	# Small paved bays leave the building frontage readable as a street rather
	# than a grass verge, while keeping the route road mesh authoritative.
	for spec in [
		{"s": 24.0, "u": -8.3, "size": Vector3(5.0, 0.06, 7.0)},
		{"s": 134.0, "u": 8.3, "size": Vector3(5.0, 0.06, 6.0)},
		{"s": 276.0, "u": -8.4, "size": Vector3(5.5, 0.06, 8.0)},
		{"s": 407.0, "u": 8.5, "size": Vector3(5.0, 0.06, 7.0)}
	]:
		var item: Dictionary = spec
		var bay := _anchor(parent, float(item["s"]), float(item["u"]), "S01S03PavedBay_%03d" % int(item["s"]))
		_part(bay, _box(item["size"]), _materials["asphalt"], Vector3(0.0, 0.04, 0.0))

func _route_point(s: float, u: float, lift := 0.0) -> Vector3:
	var distance := clampf(s, 0.0, route.length_m)
	var p := route.pos_at(distance) + route.left_at(distance) * u
	p.y = route.ground_y(distance, u) + lift
	return p

func _foundation_burial_depth(parent: Node3D, footprint_x: float, footprint_z: float) -> float:
	# The route grade changes across each building footprint.  Sample corners and
	# edge midpoints in the building's actual world transform, then extend only
	# the foundation downward so the body/roof projection stays fixed.
	var half_x := footprint_x * 0.5
	var half_z := footprint_z * 0.5
	var footprint := [
		Vector3(-half_x, 0.0, -half_z),
		Vector3(half_x, 0.0, -half_z),
		Vector3(half_x, 0.0, half_z),
		Vector3(-half_x, 0.0, half_z),
		Vector3(0.0, 0.0, -half_z),
		Vector3(half_x, 0.0, 0.0),
		Vector3(0.0, 0.0, half_z),
		Vector3(-half_x, 0.0, 0.0)
	]
	var minimum_ground_y := INF
	for local_point in footprint:
		var world_point: Vector3 = parent.global_transform * local_point
		var sample_s := route.distance_for_position(world_point)
		var route_point := route.pos_at(sample_s)
		var route_left := route.left_at(sample_s)
		var lateral := (world_point - route_point).dot(route_left)
		minimum_ground_y = minf(minimum_ground_y, route.ground_y(sample_s, lateral))
	var current_bottom_y := (parent.global_transform * Vector3.ZERO).y
	var local_up_y := maxf(parent.global_transform.basis.y.y, 0.001)
	return maxf((current_bottom_y - minimum_ground_y + 0.10) / local_up_y, 0.10)

func _add_surface_quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	surface.add_vertex(a)
	surface.add_vertex(b)
	surface.add_vertex(c)
	surface.add_vertex(a)
	surface.add_vertex(c)
	surface.add_vertex(d)

func _build_s02_intersection(parent: Node3D) -> void:
	# The left planted island is the strongest S02 landmark. A raised stone
	# ellipse with real rocks, shrubs and a broadleaf model reads at the route
	# camera scale and remains anchored to the Saisies road surface.
	# Keep the entire island on the left verge.  The former center at u=4.4
	# overlapped the 7.6 m village road and put the acceptance camera inside the
	# planting bed; u=8 with a 3.2 m radius leaves a clear road margin.
	var island := _anchor(parent, 320.0, 8.0, "S02StonePlantedIsland")
	var stone := _part(island, _cylinder(1.0, 1.0, 0.62, 28), _materials["stone"], Vector3(0.0, 0.32, 0.0))
	stone.scale = Vector3(3.2, 1.0, 6.0)
	var soil := _part(island, _cylinder(1.0, 1.0, 0.22, 28), _materials["soil"], Vector3(0.0, 0.75, 0.0))
	soil.scale = Vector3(2.72, 1.0, 5.35)
	var planting := _part(island, _cylinder(1.0, 1.0, 0.08, 28), _materials["grass"], Vector3(0.0, 0.90, 0.0))
	planting.scale = Vector3(2.45, 1.0, 5.10)
	for local_position in [Vector3(-1.25, 1.05, -3.8), Vector3(1.1, 1.05, 0.0), Vector3(-0.8, 1.05, 3.7)]:
		var rock := _instance_model(island, "namaqualand_boulder_03", local_position, Vector3.ONE * 0.65, _rng.randf_range(-0.4, 0.4))
		if rock:
			rock.name = "S02IslandBoulder"
	var broadleaf_variants: Array[Mesh] = SaisiesTrees.broadleaf_variants()
	if not broadleaf_variants.is_empty():
		var tree := MeshInstance3D.new()
		tree.name = "S02IslandBroadleaf"
		tree.mesh = broadleaf_variants[1 % broadleaf_variants.size()]
		tree.position = Vector3(0.55, 0.96, -1.8)
		tree.scale = Vector3.ONE * 1.12
		island.add_child(tree)
	for spec in [
		{"s": 276.0, "u": -8.6, "scale": 1.20},
		{"s": 314.0, "u": -8.9, "scale": 1.10},
		{"s": 350.0, "u": 8.6, "scale": 1.05},
		{"s": 386.0, "u": -8.4, "scale": 1.15}
	]:
		var item: Dictionary = spec
		var prop_anchor := _anchor(parent, float(item["s"]), float(item["u"]), "S02Planter_%03d" % int(item["s"]))
		_instance_model(prop_anchor, "planter_box_01", Vector3.ZERO, Vector3.ONE * float(item["scale"]), _rng.randf_range(-0.08, 0.08))
		_instance_model(prop_anchor, "potted_plant_02", Vector3(0.0, 0.62, 0.0), Vector3.ONE * 0.50, _rng.randf_range(-0.1, 0.1))

	# Four broad transverse stripes show the S02 street crossing without
	# replacing the route's continuous centerline mesh.
	for i in range(4):
		var crossing := _anchor(parent, 308.0 + float(i) * 1.25, 0.0, "S02Crosswalk_%02d" % i)
		_part(crossing, _box(Vector3(route.road_width_at(308.0) * 0.86, 0.025, 0.72)), _materials["sign"], Vector3(0.0, 0.045, 0.0))

func _build_s03_chairlift(parent: Node3D) -> void:
	var distance := 1060.0
	var tower_us := [-31.0, 31.0]
	var tower_count := 0
	for index in tower_us.size():
		var u := float(tower_us[index])
		var base := _route_point(distance, u)
		var tower := _world_anchor(parent, base, route.tangent_at(distance), "S03ChairliftTower_%d" % index)
		var height := 10.0
		_part(tower, _cylinder(0.16, 0.23, height, 10), _materials["metal"], Vector3(0.0, height * 0.5, 0.0))
		_part(tower, _box(Vector3(2.8, 0.24, 0.28)), _materials["metal"], Vector3(0.0, height, 0.0))
		_part(tower, _box(Vector3(0.16, 0.45, 0.16)), _materials["metal"], Vector3(-1.02, height + 0.17, 0.0))
		_part(tower, _box(Vector3(0.16, 0.45, 0.16)), _materials["metal"], Vector3(1.02, height + 0.17, 0.0))
		tower_count += 1
	var left_top := _route_point(distance, tower_us[0]) + Vector3.UP * 10.25
	var right_top := _route_point(distance, tower_us[1]) + Vector3.UP * 10.25
	_add_sagging_cable(parent, left_top, right_top, "S03ChairliftCable")
	for i in range(5):
		var t := 0.12 + float(i) * 0.19
		var point := left_top.lerp(right_top, t)
		point.y -= 2.3
		var seat := _world_anchor(parent, point, route.tangent_at(distance), "S03Chair_%02d" % i)
		_part(seat, _box(Vector3(1.25, 0.10, 0.60)), _materials["metal"], Vector3.ZERO)
		_part(seat, _box(Vector3(0.08, 2.0, 0.08)), _materials["metal"], Vector3(0.0, 1.15, 0.0))
		_part(seat, _box(Vector3(1.35, 0.08, 0.08)), _materials["metal"], Vector3(0.0, 2.08, 0.0))
	for i in range(3):
		var sign_anchor := _anchor(parent, 1010.0 + float(i) * 24.0, 8.2, "S03DirectionSign_%02d" % i)
		_part(sign_anchor, _cylinder(0.045, 0.06, 2.3, 10), _materials["metal"], Vector3(0.0, 1.15, 0.0))
		_part(sign_anchor, _box(Vector3(0.08, 0.45, 1.45)), _materials["sign"], Vector3(0.0, 2.15, 0.0))
	_build_s03_junction_apron(parent)
	_build_resort_block(parent, 1048.0, 12.0, 18.0, 6.6, 1, _materials["cream_light"], _materials["roof_grey"], "S03LeftLiftLodge", true)
	var board_anchor := _anchor(parent, 1028.0, 8.0, "S03RoadBoards")
	_part(board_anchor, _cylinder(0.06, 0.08, 2.5, 10), _materials["metal"], Vector3(0.0, 1.25, 0.0))
	_part(board_anchor, _box(Vector3(0.12, 0.66, 1.70)), _materials["sign"], Vector3(0.0, 2.18, 0.0))
	_part(board_anchor, _box(Vector3(0.14, 0.08, 1.45)), _materials["timber_dark"], Vector3(0.0, 2.18, 0.0))
	_part(board_anchor, _box(Vector3(0.12, 0.55, 1.45)), _materials["sign"], Vector3(0.0, 2.90, 0.0))
	for index in range(3):
		var flower_s := 1018.0 + float(index) * 30.0
		var flower_anchor := _anchor(parent, flower_s, -7.25, "S03RightFlowerbox_%02d" % index)
		_part(flower_anchor, _box(Vector3(0.92, 0.48, 1.30)), _materials["timber"], Vector3(0.0, 0.24, 0.0))
		_part(flower_anchor, _box(Vector3(0.72, 0.08, 1.06)), _materials["soil"], Vector3(0.0, 0.51, 0.0))
		_part(flower_anchor, _sphere(0.38), _materials["leaf"], Vector3(-0.22, 0.78, 0.0))
		_part(flower_anchor, _sphere(0.28), _materials["flowers"], Vector3(0.22, 0.82, 0.12))
	parent.set_meta("tower_count", tower_count)

func _build_s03_junction_apron(parent: Node3D) -> void:
	# A pair of paved side aprons widens the lift junction while leaving the
	# continuous centerline and collision surface visible through the middle.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var s := 990.0
	while s < 1110.0:
		var s1 := minf(s + 10.0, 1110.0)
		for side in [-1.0, 1.0]:
			var side_f: float = float(side)
			var inner0 := side_f * (route.road_width_at(s) * 0.5 + 0.08)
			var outer0 := side_f * 13.5
			var inner1 := side_f * (route.road_width_at(s1) * 0.5 + 0.08)
			var outer1 := side_f * 13.5
			if side_f < 0.0:
				_add_surface_quad(surface, _route_point(s, outer0, 0.055), _route_point(s, inner0, 0.055), _route_point(s1, inner1, 0.055), _route_point(s1, outer1, 0.055))
			else:
				_add_surface_quad(surface, _route_point(s, inner0, 0.055), _route_point(s, outer0, 0.055), _route_point(s1, outer1, 0.055), _route_point(s1, inner1, 0.055))
		s = s1
	surface.generate_normals()
	var apron := MeshInstance3D.new()
	apron.name = "S03BroadJunctionApron"
	apron.mesh = surface.commit()
	apron.material_override = _materials["asphalt"]
	parent.add_child(apron)

func _world_anchor(parent: Node3D, position: Vector3, forward: Vector3, node_name: String) -> Node3D:
	var anchor := Node3D.new()
	anchor.name = node_name
	anchor.position = position
	anchor.basis = Basis.looking_at(forward, Vector3.UP)
	parent.add_child(anchor)
	return anchor

func _add_sagging_cable(parent: Node3D, a: Vector3, b: Vector3, node_name: String) -> void:
	var previous := a
	for i in range(1, 7):
		var t := float(i) / 6.0
		var current := a.lerp(b, t)
		current.y -= sin(t * PI) * 1.6
		_add_segment(parent, previous, current, 0.055, _materials["cable"], "%s_%02d" % [node_name, i])
		previous = current

func _add_segment(parent: Node3D, a: Vector3, b: Vector3, thickness: float, material: Material, node_name: String) -> void:
	var length := a.distance_to(b)
	if length < 0.01:
		return
	var segment := MeshInstance3D.new()
	segment.name = node_name
	segment.mesh = _box(Vector3(thickness, thickness, length))
	segment.material_override = material
	segment.position = (a + b) * 0.5
	segment.basis = Basis.looking_at((b - a).normalized(), Vector3.UP)
	parent.add_child(segment)
