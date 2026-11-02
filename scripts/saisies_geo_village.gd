class_name SaisiesGeoVillage
extends "res://scripts/saisies_village.gd"

## Geographic S01/S02 village frontage plus the mapped S03 chairlift junction.
##
## This module deliberately reuses the authored v2 village geometry.  The only
## geographic-specific work here is resolving anchors and foundations against
## the displayed GeoLandscape mesh, then publishing the authored footprints so
## the OSM building pass can suppress only positive polygon intersections.

@export var landscape_path: NodePath
@export var authored_scope_to_m := 560.0

## The existing scene export remains the S01/S02 frontage scope.  S03 is an
## evidence-backed extension from the geo scene anchor (930m) to the cable
## approach (~955m); these are authored route stations, not GPS claims.
const S03_GEO_CABLE_M := 955.0
const S03_GEO_CAFE_M := 970.0
const S03_GEO_CAFE_PREVIOUS_M := 943.0
const S03_GEO_APRON_FROM_M := 885.0
const S03_GEO_APRON_TO_M := 1005.0
const S03_GEO_TOWER_LATERALS := [-31.0, 31.0]
const S03_GEO_SIGN_STATIONS := [905.0, 929.0, 953.0]
const S03_GEO_FLOWER_STATIONS := [913.0, 943.0, 973.0]
const S02_GEO_ISLAND_M := 308.0
const S02_GEO_ISLAND_PREVIOUS_M := 320.0
const S02_GEO_INTERSECTION_LODGE_M := 320.0
const S02_GEO_INTERSECTION_LODGE_U := -14.0
const S02_GEO_INTERSECTION_LODGE_PREVIOUS_M := 333.0
const S02_GEO_INTERSECTION_LODGE_PREVIOUS_U := -11.2
const S02_GEO_INTERSECTION_LODGE_REJECTED_M := 333.0
const S02_GEO_INTERSECTION_LODGE_REJECTED_U := -20.0
const S02_SHOP_SCENE := preload("res://scenes/props/SaisiesS02Shop.tscn")

var landscape: Node3D
var _geo_build_attempts := 0
var _geo_contact_fallback_count := 0
var _authored_footprint_records: Array[Dictionary] = []

func _ready() -> void:
	route = get_node_or_null(route_path) as SaisiesRoute
	if route == null and get_parent() != null:
		route = get_parent().get_node_or_null("Route") as SaisiesRoute
	_resolve_landscape()
	if not _geo_dependencies_ready():
		call_deferred("_try_geo_build")
		return
	_build()

func _try_geo_build() -> void:
	if village_ready:
		return
	_resolve_landscape()
	if _geo_dependencies_ready():
		_build()
		return
	_geo_build_attempts += 1
	if _geo_build_attempts < 96:
		call_deferred("_try_geo_build")
	else:
		push_error("SaisiesGeoVillage could not resolve a ready route and GeoLandscape")

func _geo_dependencies_ready() -> bool:
	return route != null and route.route_ready() and landscape != null and landscape.has_method("sample_mesh_triangle") and bool(landscape.get("landscape_ready"))

func _resolve_landscape() -> void:
	if landscape != null:
		return
	if landscape_path != NodePath():
		landscape = get_node_or_null(landscape_path)
	if landscape == null and get_parent() != null:
		landscape = get_parent().get_node_or_null("Landscape")

func _build() -> void:
	if village_ready or not _geo_dependencies_ready():
		return
	_rng.seed = random_seed
	from_m = clampf(from_m, 0.0, authored_scope_to_m)
	to_m = clampf(minf(to_m, authored_scope_to_m), from_m + 1.0, authored_scope_to_m)
	_make_materials()
	_authored_footprint_records.clear()
	_geo_contact_fallback_count = 0
	var street := _group("S01S02Street")
	var buildings := _group("S01S02Buildings")
	var details := _group("S01S02StreetDetails")
	var s03 := _group("S03Chairlift")
	add_child(street)
	add_child(buildings)
	add_child(details)
	add_child(s03)

	# Keep the complete authored S01/S02 frontage and junction unchanged.  The
	# mapped S03 group is built separately so the S01/S02 sidewalk scope remains
	# exactly 0..560m while its route anchors use the full geographic route.
	_build_sidewalks(street)
	_build_resort_frontage(buildings)
	_build_s02_low_shop(buildings)
	_build_s02_intersection(details)
	_build_s03_chairlift(s03)

	_publish_authored_footprints()
	set_meta("saisies_village_ready", true)
	set_meta("saisies_geo_village_ready", true)
	set_meta("saisies_village_scene_ids", ["S01", "S02", "S03"])
	set_meta("saisies_village_from_m", from_m)
	set_meta("saisies_village_to_m", to_m)
	set_meta("saisies_village_building_count", buildings.get_child_count())
	set_meta("saisies_village_chairlift_towers", int(s03.get_meta("tower_count", 0)))
	set_meta("saisies_geo_village_scope", "S01/S02 frontage and junction 0..560m; mapped S03 chairlift junction 885..1005m")
	set_meta("saisies_geo_village_s03_group", "S03Chairlift")
	set_meta("saisies_geo_village_s03_cable_station_m", S03_GEO_CABLE_M)
	set_meta("saisies_geo_village_s03_cafe_station_m", S03_GEO_CAFE_M)
	set_meta("saisies_geo_village_s03_cafe_previous_station_m", S03_GEO_CAFE_PREVIOUS_M)
	set_meta("saisies_geo_village_s03_cafe_station_basis", "visual_estimate_after_native_probe")
	set_meta("saisies_geo_village_s03_apron_from_m", S03_GEO_APRON_FROM_M)
	set_meta("saisies_geo_village_s03_apron_to_m", S03_GEO_APRON_TO_M)
	set_meta("saisies_geo_village_s02_shop_station_m", 340.0)
	set_meta("saisies_geo_village_s02_shop_lateral_m", -9.5)
	set_meta("saisies_geo_village_s02_shop_previous_station_m", 350.0)
	set_meta("saisies_geo_village_s02_shop_previous_lateral_m", -11.6)
	set_meta("saisies_geo_village_s02_shop_placement_basis", "visual_estimate_after_native_probe")
	set_meta("saisies_geo_village_s02_shop_source", "scenes/props/SaisiesS02Shop.tscn")
	set_meta("saisies_geo_village_ground_source", "Landscape.sample_mesh_triangle")
	set_meta("saisies_geo_village_contact_fallback_count", _geo_contact_fallback_count)
	set_meta("saisies_geo_village_osm_duplicate_claimed", false)
	set_meta("saisies_geo_village_osm_overlap_policy", "intersection-only; Buildings owns suppression after consuming authored footprint API")
	village_ready = true

func _sample_mesh(point: Vector3) -> Dictionary:
	if landscape == null or not landscape.has_method("sample_mesh_triangle"):
		return {}
	var sampled = landscape.call("sample_mesh_triangle", Vector2(point.x, point.z))
	return sampled if sampled is Dictionary else {}

func _sample_height(point: Vector3) -> float:
	var sampled := _sample_mesh(point)
	if sampled.has("height") and is_finite(float(sampled["height"])):
		return float(sampled["height"])
	return NAN

func _anchor(parent: Node3D, s: float, u: float, node_name: String) -> Node3D:
	var anchor := Node3D.new()
	anchor.name = node_name
	var distance := clampf(s, 0.0, route.length_m)
	if node_name == "S02StonePlantedIsland":
		# The inherited v2 island call remains s320; the Geo scene uses a separate
		# source-derived visual candidate and samples this position directly.
		distance = clampf(S02_GEO_ISLAND_M, 0.0, route.length_m)
	var route_point := route.pos_at(distance) + route.left_at(distance) * u
	var contact_y := _sample_height(route_point)
	if not is_finite(contact_y):
		# Build dependencies are constrained to the GeoLandscape bounds.  Keep a
		# guarded route fallback for a malformed future asset, and expose it in the
		# metadata/verifier instead of silently treating it as mesh contact.
		contact_y = route.ground_y(distance, u)
		_geo_contact_fallback_count += 1
	anchor.position = Vector3(route_point.x, contact_y, route_point.z)
	anchor.basis = Basis.looking_at(route.tangent_at(distance), Vector3.UP)
	anchor.set_meta("route_distance_m", distance)
	anchor.set_meta("route_lateral_m", u)
	anchor.set_meta("saisies_geo_anchor_requested_station_m", s)
	if node_name == "S02StonePlantedIsland":
		anchor.set_meta("saisies_geo_s02_island_station_m", S02_GEO_ISLAND_M)
		anchor.set_meta("saisies_geo_s02_island_previous_station_m", S02_GEO_ISLAND_PREVIOUS_M)
		anchor.set_meta("saisies_geo_s02_island_station_basis", "visual_estimate_after_native_probe")
	var sampled := _sample_mesh(route_point)
	anchor.set_meta("saisies_geo_contact_source", "landscape.sample_mesh_triangle" if sampled.has("height") else "route.ground_y_fallback")
	anchor.set_meta("saisies_geo_contact_height_m", contact_y)
	if sampled.has("triangle_start"):
		anchor.set_meta("saisies_geo_contact_triangle_start", int(sampled["triangle_start"]))
		anchor.set_meta("saisies_geo_contact_barycentric", sampled.get("barycentric", Vector3.ZERO))
	parent.add_child(anchor)
	return anchor

func _route_point(s: float, u: float, lift := 0.0) -> Vector3:
	var distance := clampf(s, 0.0, route.length_m)
	var route_point := route.pos_at(distance) + route.left_at(distance) * u
	var contact_y := _sample_height(route_point)
	if not is_finite(contact_y):
		contact_y = route.ground_y(distance, u)
		_geo_contact_fallback_count += 1
	return Vector3(route_point.x, contact_y + lift, route_point.z)

func _foundation_burial_depth(parent: Node3D, footprint_x: float, footprint_z: float) -> float:
	# Sample the same displayed terrain triangles used by anchors.  The body and
	# roof stay in authored local coordinates; only the foundation extends down
	# far enough to meet the lowest sampled corner/edge.
	var half_x := footprint_x * 0.5
	var half_z := footprint_z * 0.5
	var local_points := [
		Vector3(-half_x, 0.0, -half_z), Vector3(half_x, 0.0, -half_z),
		Vector3(half_x, 0.0, half_z), Vector3(-half_x, 0.0, half_z),
		Vector3(0.0, 0.0, -half_z), Vector3(half_x, 0.0, 0.0),
		Vector3(0.0, 0.0, half_z), Vector3(-half_x, 0.0, 0.0)
	]
	var minimum_ground_y := INF
	var samples: Array[Dictionary] = []
	for local_point in local_points:
		var world_point: Vector3 = parent.global_transform * local_point
		var sampled := _sample_mesh(world_point)
		var ground_y := float(sampled.get("height", NAN))
		if not is_finite(ground_y):
			var sample_s := route.distance_for_position(world_point)
			var route_point := route.pos_at(sample_s)
			var lateral := (world_point - route_point).dot(route.left_at(sample_s))
			ground_y = route.ground_y(sample_s, lateral)
			_geo_contact_fallback_count += 1
		else:
			samples.append({
				"world_xz": Vector2(world_point.x, world_point.z),
				"ground_y": ground_y,
				"triangle_start": int(sampled.get("triangle_start", -1))
			})
		minimum_ground_y = minf(minimum_ground_y, ground_y)
	if not is_finite(minimum_ground_y):
		minimum_ground_y = parent.global_position.y
	var current_bottom_y := (parent.global_transform * Vector3.ZERO).y
	var local_up_y := maxf(parent.global_transform.basis.y.y, 0.001)
	var burial := maxf((current_bottom_y - minimum_ground_y + 0.10) / local_up_y, 0.10)
	parent.set_meta("saisies_geo_foundation_contact_samples", samples)
	parent.set_meta("saisies_geo_foundation_min_ground_y", minimum_ground_y)
	parent.set_meta("saisies_geo_foundation_bottom_world_y", current_bottom_y - burial * local_up_y)
	parent.set_meta("saisies_geo_foundation_contact_source", "landscape.sample_mesh_triangle" if not samples.is_empty() else "route.ground_y_fallback")
	return burial

func _build_restaurant_block(parent: Node3D) -> void:
	super._build_restaurant_block(parent)
	_register_authored_footprint(parent.get_node_or_null("Restaurant_Ravoula") as Node3D, 58.0, 11.8, 27.0, 8.8)

func _add_restaurant_sign_band(parent: Node3D, front_x: float, z: float, y: float, length: float, text_value: String, node_name: String, band_height := 0.34) -> void:
	# The retained source reads the restaurant as Savoyard alpine branding. Keep
	# the inherited band geometry and node IDs, but restore the source wording.
	var source_text := text_value
	if node_name == "RestaurantSignBandUpper":
		source_text = "RESTAURANT SAVOYARD"
	elif node_name == "RestaurantSignBandLower":
		source_text = "LA TABLE DE L’OLYMPE"
	super._add_restaurant_sign_band(parent, front_x, z, y, length, source_text, node_name, band_height)
	var label := parent.get_node_or_null("%sLabel" % node_name) as Label3D
	if label != null:
		# The longer source names need a slightly smaller glyph scale to stay
		# inside the authored plaque span.
		label.pixel_size = 0.0035

func _build_hotel_block(parent: Node3D, s: float, u: float, width: float, depth: float, stories: int) -> void:
	super._build_hotel_block(parent, s, u, width, depth, stories)
	_register_authored_footprint(parent.get_node_or_null("Rear_Hotel") as Node3D, s, u, width, depth)

func _build_resort_block(parent: Node3D, s: float, u: float, width: float, depth: float, stories: int, body_material: Material, roof_material: Material, block_name: String, storefront: bool) -> void:
	if block_name == "Intersection_Lodge":
		# The rejected s333/u-20 candidate dropped the lodge onto a lower DEM
		# slope.  Use the nearer, road-side visual candidate while preserving the
		# inherited v2 call and dimensions.
		_build_geo_intersection_lodge(parent, S02_GEO_INTERSECTION_LODGE_M, S02_GEO_INTERSECTION_LODGE_U, width, depth)
		return
	super._build_resort_block(parent, s, u, width, depth, stories, body_material, roof_material, block_name, storefront)
	_register_authored_footprint(parent.get_node_or_null(block_name) as Node3D, s, u, width, depth)

func _build_s02_low_shop(parent: Node3D) -> void:
	# The source S02 low shop is a separate authored prefab.  Keep its local
	# front (-X) and long roof (+X) axes untouched; only the geographic anchor
	# and terrain-supported foundation are supplied here.
	const station_m := 340.0
	const lateral_m := -9.5
	const body_length_m := 7.4
	const body_width_m := 4.4
	const foundation_length_m := body_length_m + 0.42
	const foundation_width_m := body_width_m + 0.42
	var anchor := _anchor(parent, station_m, lateral_m, "S02LowShop")
	anchor.set_meta("saisies_s02_shop_anchor_station_m", station_m)
	anchor.set_meta("saisies_s02_shop_anchor_lateral_m", lateral_m)
	anchor.set_meta("saisies_s02_shop_ground_source", "Landscape.sample_mesh_triangle")
	anchor.set_meta("saisies_s02_shop_front_axis", "local -X")
	anchor.set_meta("saisies_s02_shop_roof_axis", "local +X")
	anchor.set_meta("saisies_s02_shop_previous_station_m", 350.0)
	anchor.set_meta("saisies_s02_shop_previous_lateral_m", -11.6)
	anchor.set_meta("saisies_s02_shop_placement_basis", "visual_estimate_after_native_probe")
	var foundation_burial := _foundation_burial_depth(anchor, foundation_length_m, foundation_width_m)
	var foundation := _part(anchor, _box(Vector3(foundation_length_m, 0.42 + foundation_burial, foundation_width_m)), _materials["stone"], Vector3(0.0, 0.21 - foundation_burial * 0.5, 0.0))
	foundation.name = "GeoVillageFoundation"
	foundation.set_meta("saisies_s02_shop_foundation_support", true)
	var shop_instance := S02_SHOP_SCENE.instantiate() as Node3D
	if shop_instance == null:
		push_error("SaisiesGeoVillage could not instantiate SaisiesS02Shop.tscn")
		return
	shop_instance.name = "SaisiesS02Shop"
	anchor.add_child(shop_instance)
	anchor.set_meta("saisies_s02_shop_asset_ready", bool(shop_instance.get_meta("saisies_s02_shop_ready", false)))
	anchor.set_meta("saisies_s02_shop_asset_scene", "res://scenes/props/SaisiesS02Shop.tscn")
	anchor.set_meta("saisies_s02_shop_body_dimensions_m", Vector3(body_length_m, 2.45, body_width_m))
	anchor.set_meta("saisies_s02_shop_foundation_dimensions_m", Vector3(foundation_length_m, 0.42 + foundation_burial, foundation_width_m))
	_register_authored_footprint(anchor, station_m, lateral_m, body_width_m, body_length_m)

func _build_s02_intersection(parent: Node3D) -> void:
	# Reuse the inherited island, planters, and crosswalk geometry.  Only the
	# planting cap gets a geographic-scene material override so the island reads
	# as the dark green bed in the source frame without changing global grass.
	super._build_s02_intersection(parent)
	var island := parent.get_node_or_null("S02StonePlantedIsland") as Node3D
	if island == null:
		return
	var dark_natural_green := _mat(Color(0.10, 0.22, 0.08), 0.98)
	var planting_cap: MeshInstance3D
	for child in island.get_children():
		var mesh := child as MeshInstance3D
		if mesh != null and mesh.material_override == _materials["grass"]:
			planting_cap = mesh
			break
	if planting_cap == null:
		island.set_meta("saisies_geo_s02_island_planting_material", "missing")
		return
	planting_cap.name = "S02IslandPlantingCap"
	planting_cap.material_override = dark_natural_green
	island.set_meta("saisies_geo_s02_island_planting_material", "dark_natural_green")
	island.set_meta("saisies_geo_s02_island_planting_color", "#1a3814")
	island.set_meta("saisies_geo_s02_island_planting_cap_node", planting_cap.name)

func _build_geo_intersection_lodge(parent: Node3D, s: float, u: float, width: float, depth: float) -> void:
	# S02's right-hand building reads as a taller timber lodging block than the
	# repeated orange two-storey placeholder. Keep the authored anchor and body
	# footprint, while giving the visible mass a cream base, dark wood upper
	# floors, stepped galleries, and pale horizontal eaves.
	var block := _anchor(parent, s, u, "Intersection_Lodge")
	var floor_height := 2.42
	var stories := 3
	var foundation := 0.68
	var base_height := 2.42
	var upper_height := floor_height * float(stories - 1)
	var foundation_burial := _foundation_burial_depth(block, depth + 0.42, width + 0.42)
	var foundation_mesh := _part(block, _box(Vector3(depth + 0.42, foundation + foundation_burial, width + 0.42)), _materials["stone"], Vector3(0.0, foundation * 0.5 - foundation_burial * 0.5, 0.0))
	foundation_mesh.name = "IntersectionLodgeFoundation"
	var cream_base := _part(block, _box(Vector3(depth, base_height, width)), _materials["cream_light"], Vector3(0.0, foundation + base_height * 0.5, 0.0))
	cream_base.name = "IntersectionLodgeCreamBase"
	var dark_body := _part(block, _box(Vector3(depth, upper_height, width)), _materials["timber_resort_dark"], Vector3(0.0, foundation + base_height + upper_height * 0.5, 0.0))
	dark_body.name = "IntersectionLodgeDarkTimberBody"

	var front_sign := -1.0 if u < 0.0 else 1.0
	var front_x := front_sign * (depth * 0.5 + 0.055)
	# A continuous pale line at the base of the dark floors and beneath the roof
	# supplies the source's readable horizontal bands without changing the mass.
	var base_eave := _part(block, _box(Vector3(depth + 0.20, 0.14, width + 0.16)), _materials["cream_light"], Vector3(0.0, foundation + base_height, 0.0))
	base_eave.name = "IntersectionLodgeWhiteEave_00"
	for level in range(1, stories):
		var eave_y := foundation + base_height + floor_height * float(level)
		var eave := _part(block, _box(Vector3(depth + 0.22, 0.13, width + 0.18)), _materials["cream_light"], Vector3(0.0, eave_y, 0.0))
		eave.name = "IntersectionLodgeWhiteEave_%02d" % level

	# The upper floors carry shallow, road-facing external galleries. Their pale
	# slab edges and dark rails break up the large timber plane at S02 distance.
	for level in range(1, stories):
		var balcony_y := foundation + base_height + floor_height * float(level - 1) + 0.10
		var balcony_width := width * 0.78
		var balcony_center_x := front_x + front_sign * 0.43
		var deck := _part(block, _box(Vector3(0.86, 0.14, balcony_width)), _materials["cream_light"], Vector3(balcony_center_x, balcony_y, 0.0))
		deck.name = "IntersectionLodgeBalconyDeck_%02d" % level
		var deck_floor := _part(block, _box(Vector3(0.72, 0.09, balcony_width * 0.94)), _materials["timber_dark"], Vector3(balcony_center_x - front_sign * 0.06, balcony_y + 0.11, 0.0))
		deck_floor.name = "IntersectionLodgeBalconyFloor_%02d" % level
		var rail_x := balcony_center_x + front_sign * 0.31
		var rail := _part(block, _box(Vector3(0.10, 0.48, balcony_width * 0.90)), _materials["timber_dark"], Vector3(rail_x, balcony_y + 0.38, 0.0))
		rail.name = "IntersectionLodgeBalconyRail_%02d" % level
		var rail_cap := _part(block, _box(Vector3(0.13, 0.10, balcony_width * 0.96)), _materials["cream_light"], Vector3(rail_x + front_sign * 0.05, balcony_y + 0.66, 0.0))
		rail_cap.name = "IntersectionLodgeBalconyCap_%02d" % level
		for rail_index in range(5):
			var rail_t := float(rail_index) / 4.0
			var rail_z := lerpf(-balcony_width * 0.45, balcony_width * 0.45, rail_t)
			var upright := _part(block, _box(Vector3(0.11, 0.58, 0.10)), _materials["timber_dark"], Vector3(rail_x + front_sign * 0.06, balcony_y + 0.35, rail_z))
			upright.name = "IntersectionLodgeBalconyUpright_%02d_%02d" % [level, rail_index]

	# Three narrow front bays per level keep the windows legible behind each
	# gallery; the rear face and gable ends receive matching dark openings.
	for level in range(stories):
		var level_y := foundation + base_height * 0.5 if level == 0 else foundation + base_height + floor_height * (float(level) - 0.5)
		var window_height := 1.10 if level == 0 else 1.18
		var window_material: Material = _materials["window_warm"] if level == 0 else _materials["window"]
		for z_value in [-width * 0.30, 0.0, width * 0.30]:
			var front_window := _part(block, _box(Vector3(0.10, window_height, 1.42)), window_material, Vector3(front_x + front_sign * 0.06, level_y, z_value))
			front_window.name = "IntersectionLodgeFrontWindow_%02d_%02d" % [level, int(round((z_value + width * 0.30) * 10.0))]
			var sill := _part(block, _box(Vector3(0.13, 0.08, 1.56)), _materials["cream_light"], Vector3(front_x + front_sign * 0.12, level_y - window_height * 0.5 - 0.08, z_value))
			sill.name = "IntersectionLodgeWindowSill_%02d_%02d" % [level, int(round((z_value + width * 0.30) * 10.0))]
			var rear_window := _part(block, _box(Vector3(0.10, window_height, 1.42)), window_material, Vector3(-front_x - front_sign * 0.06, level_y, z_value))
			rear_window.name = "IntersectionLodgeRearWindow_%02d_%02d" % [level, int(round((z_value + width * 0.30) * 10.0))]
		for end_sign in [-1.0, 1.0]:
			var end_z: float = end_sign * (width * 0.5 + 0.055)
			for x_value in [-depth * 0.23, depth * 0.23]:
				var end_window := _part(block, _box(Vector3(1.10, window_height * 0.88, 0.10)), window_material, Vector3(x_value, level_y, end_z))
				end_window.name = "IntersectionLodgeEndWindow_%02d_%d" % [level, int(end_sign)]

	# The cream base has a centered dark door with a simple lintel and warm side
	# panes, adding scale without introducing people or vehicles.
	var door_y := foundation + 1.06
	var door := _part(block, _box(Vector3(0.11, 2.00, 0.82)), _materials["store_interior"], Vector3(front_x + front_sign * 0.08, door_y, 0.0))
	door.name = "IntersectionLodgeFrontDoor"
	for door_z in [-0.53, 0.53]:
		var jamb := _part(block, _box(Vector3(0.14, 2.10, 0.10)), _materials["timber_dark"], Vector3(front_x + front_sign * 0.15, door_y, door_z))
		jamb.name = "IntersectionLodgeDoorJamb_%d" % int(door_z * 10.0)
	var lintel := _part(block, _box(Vector3(0.14, 0.12, 1.18)), _materials["cream_light"], Vector3(front_x + front_sign * 0.15, door_y + 1.10, 0.0))
	lintel.name = "IntersectionLodgeDoorLintel"
	var handle := _part(block, _cylinder(0.035, 0.035, 0.16, 10), _materials["metal"], Vector3(front_x + front_sign * 0.17, door_y, 0.22), Vector3(PI * 0.5, 0.0, 0.0))
	handle.name = "IntersectionLodgeDoorHandle"

	var roof_eave_y := foundation + base_height + upper_height
	_add_gable_roof(block, depth, width, roof_eave_y, _materials["roof_dark"])
	var roof_fascia_front := _part(block, _box(Vector3(0.18, 0.18, width + 0.20)), _materials["cream_light"], Vector3(front_x + front_sign * 0.15, roof_eave_y + 0.03, 0.0))
	roof_fascia_front.name = "IntersectionLodgeWhiteRoofFasciaFront"
	block.set_meta("saisies_s02_intersection_lodge_stories", stories)
	block.set_meta("saisies_s02_intersection_lodge_cream_base", true)
	block.set_meta("saisies_s02_intersection_lodge_dark_timber", true)
	block.set_meta("saisies_s02_intersection_lodge_white_eaves", stories)
	block.set_meta("saisies_s02_intersection_lodge_balconies", stories - 1)
	block.set_meta("saisies_s02_intersection_lodge_windows", stories * 3)
	block.set_meta("saisies_s02_intersection_lodge_door", true)
	block.set_meta("saisies_s02_intersection_lodge_station_m", s)
	block.set_meta("saisies_s02_intersection_lodge_lateral_m", u)
	block.set_meta("saisies_s02_intersection_lodge_previous_station_m", S02_GEO_INTERSECTION_LODGE_PREVIOUS_M)
	block.set_meta("saisies_s02_intersection_lodge_previous_lateral_m", S02_GEO_INTERSECTION_LODGE_PREVIOUS_U)
	block.set_meta("saisies_s02_intersection_lodge_rejected_station_m", S02_GEO_INTERSECTION_LODGE_REJECTED_M)
	block.set_meta("saisies_s02_intersection_lodge_rejected_lateral_m", S02_GEO_INTERSECTION_LODGE_REJECTED_U)
	block.set_meta("saisies_s02_intersection_lodge_placement_basis", "visual_estimate_after_native_probe")
	_register_authored_footprint(block, s, u, width, depth)

func _register_authored_footprint(block: Node3D, s: float, u: float, width: float, depth: float) -> void:
	if block == null:
		return
	var body_polygon := _world_xz_polygon(block, depth, width)
	var foundation_polygon := _world_xz_polygon(block, depth + 0.42, width + 0.42)
	var foundation := _first_mesh_child(block)
	if foundation != null:
		foundation.name = "GeoVillageFoundation"
	block.set_meta("saisies_geo_authored_footprint_world_xz", body_polygon)
	block.set_meta("saisies_geo_authored_foundation_footprint_world_xz", foundation_polygon)
	block.set_meta("saisies_geo_authored_footprint_s_m", s)
	block.set_meta("saisies_geo_authored_footprint_u_m", u)
	_authored_footprint_records.append({
		"building_name": String(block.name),
		"source": "saisies_geo_village_s03_cafe_geometry" if block.name == "S03LeftLiftLodge" else ("saisies_geo_village_s02_shop_prefab" if block.name == "S02LowShop" else "saisies_village_v2_authored_geometry"),
		"s_m": s,
		"lateral_m": u,
		"polygon": body_polygon,
		"foundation_polygon": foundation_polygon
	})

func _world_xz_polygon(block: Node3D, depth: float, width: float) -> PackedVector2Array:
	var polygon := PackedVector2Array()
	for local_point in [
		Vector3(-depth * 0.5, 0.0, -width * 0.5),
		Vector3(depth * 0.5, 0.0, -width * 0.5),
		Vector3(depth * 0.5, 0.0, width * 0.5),
		Vector3(-depth * 0.5, 0.0, width * 0.5)
	]:
		var world_point: Vector3 = block.global_transform * local_point
		polygon.append(Vector2(world_point.x, world_point.z))
	return polygon

func _first_mesh_child(parent: Node3D) -> MeshInstance3D:
	for child in parent.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).mesh != null:
			return child as MeshInstance3D
	return null

func _publish_authored_footprints() -> void:
	var polygons: Array[PackedVector2Array] = []
	for record in _authored_footprint_records:
		polygons.append(record["polygon"] as PackedVector2Array)
	set_meta("saisies_geo_village_authored_footprints_world_xz", polygons)
	set_meta("saisies_geo_village_authored_footprint_records", _authored_footprint_records.duplicate(true))
	set_meta("saisies_geo_village_authored_footprint_count", polygons.size())
	set_meta("saisies_geo_village_authored_footprint_api", "get_authored_building_footprints")

## Stable integration API consumed by SaisiesGeoBuildings.
## Each polygon is a PackedVector2Array of WORLD (x,z) coordinates.
func get_authored_building_footprints() -> Array[PackedVector2Array]:
	var polygons: Array[PackedVector2Array] = []
	for record in _authored_footprint_records:
		polygons.append(record["polygon"] as PackedVector2Array)
	return polygons

func get_authored_building_footprints_world_xz() -> Array[PackedVector2Array]:
	return get_authored_building_footprints()

func get_authored_footprint_records() -> Array[Dictionary]:
	return _authored_footprint_records.duplicate(true)

## S03 is intentionally authored here instead of inheriting the old v2
## 990..1110/1048..1060m placement.  The geo scene anchor identifies the
## approach at 930m and the source cable is approximately 25m farther on.
func _add_sagging_cable(parent: Node3D, a: Vector3, b: Vector3, node_name: String) -> void:
	var previous := a
	for index in range(1, 7):
		var t := float(index) / 6.0
		var current := a.lerp(b, t)
		current.y -= sin(t * PI) * 1.6
		_add_segment(parent, previous, current, 0.055, _materials["cable"], "%s_%02d" % [node_name, index])
		var segment := parent.get_node_or_null("%s_%02d" % [node_name, index]) as Node3D
		if segment != null:
			segment.set_meta("saisies_geo_s03_cable_continuous", true)
			segment.set_meta("saisies_geo_s03_cable_a", previous)
			segment.set_meta("saisies_geo_s03_cable_b", current)
		previous = current

func _build_s03_chairlift(parent: Node3D) -> void:
	var tower_count := 0
	for index in S03_GEO_TOWER_LATERALS.size():
		var lateral := float(S03_GEO_TOWER_LATERALS[index])
		var tower := _anchor(parent, S03_GEO_CABLE_M, lateral, "S03ChairliftTower_%d" % index)
		tower.set_meta("saisies_geo_s03_tower_base_sampled", true)
		tower.set_meta("saisies_geo_s03_tower_station_m", S03_GEO_CABLE_M)
		tower.set_meta("saisies_geo_s03_tower_lateral_m", lateral)
		var height := 10.0
		_part(tower, _cylinder(0.16, 0.23, height, 10), _materials["metal"], Vector3(0.0, height * 0.5, 0.0))
		_part(tower, _box(Vector3(2.8, 0.24, 0.28)), _materials["metal"], Vector3(0.0, height, 0.0))
		_part(tower, _box(Vector3(0.16, 0.45, 0.16)), _materials["metal"], Vector3(-1.02, height + 0.17, 0.0))
		_part(tower, _box(Vector3(0.16, 0.45, 0.16)), _materials["metal"], Vector3(1.02, height + 0.17, 0.0))
		tower_count += 1
	var left_top := _route_point(S03_GEO_CABLE_M, float(S03_GEO_TOWER_LATERALS[0]), 10.25)
	var right_top := _route_point(S03_GEO_CABLE_M, float(S03_GEO_TOWER_LATERALS[1]), 10.25)
	_add_sagging_cable(parent, left_top, right_top, "S03ChairliftCable")
	for i in range(4):
		var t := 0.16 + float(i) * 0.22
		var point := left_top.lerp(right_top, t)
		point.y -= 2.3
		var seat := _world_anchor(parent, point, route.tangent_at(S03_GEO_CABLE_M), "S03Chair_%02d" % i)
		_part(seat, _box(Vector3(1.25, 0.10, 0.60)), _materials["metal"], Vector3.ZERO)
		_part(seat, _box(Vector3(0.08, 2.0, 0.08)), _materials["metal"], Vector3(0.0, 1.15, 0.0))
		_part(seat, _box(Vector3(1.35, 0.08, 0.08)), _materials["metal"], Vector3(0.0, 2.08, 0.0))
	for index in S03_GEO_SIGN_STATIONS.size():
		var sign_station := float(S03_GEO_SIGN_STATIONS[index])
		var sign_anchor := _anchor(parent, sign_station, 8.2, "S03DirectionSign_%02d" % index)
		_part(sign_anchor, _cylinder(0.045, 0.06, 2.3, 10), _materials["metal"], Vector3(0.0, 1.15, 0.0))
		_part(sign_anchor, _box(Vector3(0.08, 0.45, 1.45)), _materials["sign"], Vector3(0.0, 2.15, 0.0))
	_build_s03_junction_apron(parent)
	_build_s03_cafe(parent)
	var board_anchor := _anchor(parent, 923.0, 8.0, "S03RoadBoards")
	_part(board_anchor, _cylinder(0.06, 0.08, 2.5, 10), _materials["metal"], Vector3(0.0, 1.25, 0.0))
	_part(board_anchor, _box(Vector3(0.12, 0.66, 1.70)), _materials["sign"], Vector3(0.0, 2.18, 0.0))
	_part(board_anchor, _box(Vector3(0.14, 0.08, 1.45)), _materials["timber_dark"], Vector3(0.0, 2.18, 0.0))
	_part(board_anchor, _box(Vector3(0.12, 0.55, 1.45)), _materials["sign"], Vector3(0.0, 2.90, 0.0))
	for index in S03_GEO_FLOWER_STATIONS.size():
		var flower_station := float(S03_GEO_FLOWER_STATIONS[index])
		var flower_anchor := _anchor(parent, flower_station, -7.25, "S03RightFlowerbox_%02d" % index)
		flower_anchor.set_meta("saisies_geo_s03_flowerbox_sampled", true)
		_part(flower_anchor, _box(Vector3(0.92, 0.48, 1.30)), _materials["timber"], Vector3(0.0, 0.24, 0.0))
		_part(flower_anchor, _box(Vector3(0.72, 0.08, 1.06)), _materials["soil"], Vector3(0.0, 0.51, 0.0))
		_part(flower_anchor, _sphere(0.38), _materials["leaf"], Vector3(-0.22, 0.78, 0.0))
		_part(flower_anchor, _sphere(0.28), _materials["flowers"], Vector3(0.22, 0.82, 0.12))
	parent.set_meta("tower_count", tower_count)
	parent.set_meta("saisies_geo_s03_ground_source", "Landscape.sample_mesh_triangle")
	parent.set_meta("saisies_geo_s03_cable_station_m", S03_GEO_CABLE_M)
	parent.set_meta("saisies_geo_s03_cafe_station_m", S03_GEO_CAFE_M)
	parent.set_meta("saisies_geo_s03_cafe_previous_station_m", S03_GEO_CAFE_PREVIOUS_M)
	parent.set_meta("saisies_geo_s03_cafe_station_basis", "visual_estimate_after_native_probe")
	parent.set_meta("saisies_geo_s03_apron_from_m", S03_GEO_APRON_FROM_M)
	parent.set_meta("saisies_geo_s03_apron_to_m", S03_GEO_APRON_TO_M)
	parent.set_meta("saisies_geo_s03_tower_count", tower_count)
	parent.set_meta("saisies_geo_s03_flowerbox_count", S03_GEO_FLOWER_STATIONS.size())
	parent.set_meta("saisies_geo_s03_direction_sign_count", S03_GEO_SIGN_STATIONS.size())

func _build_s03_junction_apron(parent: Node3D) -> void:
	# The side aprons are generated from the displayed terrain triangles.  Their
	# centre road remains the authoritative continuous Route surface.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var s := S03_GEO_APRON_FROM_M
	while s < S03_GEO_APRON_TO_M:
		var s1 := minf(s + 10.0, S03_GEO_APRON_TO_M)
		for side in [-1.0, 1.0]:
			var side_f := float(side)
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
	apron.set_meta("saisies_geo_s03_ground_source", "Landscape.sample_mesh_triangle")
	apron.set_meta("saisies_geo_s03_apron_from_m", S03_GEO_APRON_FROM_M)
	apron.set_meta("saisies_geo_s03_apron_to_m", S03_GEO_APRON_TO_M)
	parent.add_child(apron)

func _build_s03_cafe(parent: Node3D) -> void:
	# Source S03 shows a small, low one-storey café on the left of the broad
	# junction.  Keep it separate from the old three-storey resort mass.
	var width := 11.0
	var depth := 6.0
	var foundation := 0.34
	var body_height := 2.30
	var cafe_lateral_m := 12.0
	var block := _anchor(parent, S03_GEO_CAFE_M, cafe_lateral_m, "S03LeftLiftLodge")
	var foundation_burial := _foundation_burial_depth(block, depth + 0.42, width + 0.42)
	var foundation_mesh := _part(block, _box(Vector3(depth + 0.42, foundation + foundation_burial, width + 0.42)), _materials["stone"], Vector3(0.0, foundation * 0.5 - foundation_burial * 0.5, 0.0))
	foundation_mesh.name = "S03CafeFoundation"
	var cafe_body := _part(block, _box(Vector3(depth, body_height, width)), _materials["timber_lodge"], Vector3(0.0, foundation + body_height * 0.5, 0.0))
	cafe_body.name = "S03CafeLowBody"
	var roof_eave_y := foundation + body_height
	_add_gable_roof(block, depth, width, roof_eave_y, _materials["roof_grey"])
	var front_sign := 1.0
	var front_x := front_sign * (depth * 0.5 + 0.06)
	for z_value in [-width * 0.30, -width * 0.10, width * 0.10, width * 0.30]:
		var z := float(z_value)
		_part(block, _box(Vector3(0.10, 1.18, 1.35)), _materials["window_warm"], Vector3(front_x, foundation + 1.18, z))
		_part(block, _box(Vector3(0.13, 1.30, 0.10)), _materials["timber_dark"], Vector3(front_x + 0.08, foundation + 1.18, z))
	var cafe_door := _part(block, _box(Vector3(0.12, 1.80, 0.82)), _materials["store_interior"], Vector3(front_x + 0.04, foundation + 0.98, 0.0))
	cafe_door.name = "S03CafeDoor"
	var cafe_fascia := _part(block, _box(Vector3(0.16, 0.12, width * 0.76)), _materials["timber_dark"], Vector3(front_x + 0.12, foundation + 2.38, 0.0))
	cafe_fascia.name = "S03CafeFascia"
	var cafe_sign := _part(block, _box(Vector3(0.14, 0.34, width * 0.48)), _materials["sign"], Vector3(front_x + 0.18, foundation + 2.70, 0.0))
	cafe_sign.name = "S03CafeSign"
	# A short front terrace is sampled directly from the same mesh as the body.
	var terrace := SurfaceTool.new()
	terrace.begin(Mesh.PRIMITIVE_TRIANGLES)
	var terrace_s0 := S03_GEO_CAFE_M - 4.0
	var terrace_s1 := S03_GEO_CAFE_M + 4.0
	var terrace_u0 := cafe_lateral_m - depth * 0.5 - 2.08
	var terrace_u1 := cafe_lateral_m - depth * 0.5 - 0.08
	_add_surface_quad(terrace, _route_point(terrace_s0, terrace_u0, 0.045), _route_point(terrace_s0, terrace_u1, 0.045), _route_point(terrace_s1, terrace_u1, 0.045), _route_point(terrace_s1, terrace_u0, 0.045))
	terrace.generate_normals()
	var terrace_mesh := MeshInstance3D.new()
	terrace_mesh.name = "S03CafeFrontTerrace"
	terrace_mesh.mesh = terrace.commit()
	terrace_mesh.material_override = _materials["concrete"]
	terrace_mesh.set_meta("saisies_geo_s03_ground_source", "Landscape.sample_mesh_triangle")
	terrace_mesh.set_meta("saisies_geo_s03_terrace_station_from_m", terrace_s0)
	terrace_mesh.set_meta("saisies_geo_s03_terrace_station_to_m", terrace_s1)
	terrace_mesh.set_meta("saisies_geo_s03_terrace_lateral_from_m", terrace_u0)
	terrace_mesh.set_meta("saisies_geo_s03_terrace_lateral_to_m", terrace_u1)
	terrace_mesh.set_meta("saisies_geo_s03_terrace_lift_m", 0.045)
	parent.add_child(terrace_mesh)
	block.set_meta("saisies_s03_cafe", true)
	block.set_meta("saisies_s03_cafe_low_gable", true)
	block.set_meta("saisies_s03_cafe_stories", 1)
	block.set_meta("saisies_s03_cafe_station_m", S03_GEO_CAFE_M)
	block.set_meta("saisies_s03_cafe_lateral_m", 12.0)
	block.set_meta("saisies_s03_cafe_previous_station_m", S03_GEO_CAFE_PREVIOUS_M)
	block.set_meta("saisies_s03_cafe_station_basis", "visual_estimate_after_native_probe")
	block.set_meta("saisies_s03_cafe_wall_material", "dark_wood")
	block.set_meta("saisies_s03_cafe_roof_material", "medium_grey")
	block.set_meta("saisies_geo_s03_ground_source", "Landscape.sample_mesh_triangle")
	_register_authored_footprint(block, S03_GEO_CAFE_M, 12.0, width, depth)

