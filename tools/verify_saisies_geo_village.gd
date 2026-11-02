extends SceneTree

## Focused headless contract for the geographic S01/S02/S03 village restoration.
## It exercises the retained v2 frontage through the GeoLandscape mesh without
## starting the full forest/roadside scene.

const SCENE_PATH := "res://scenes/MainScene_saisies_geo.tscn"
const ROUTE_SCRIPT_PATH := "res://scripts/saisies_geo_route.gd"
const LANDSCAPE_SCRIPT_PATH := "res://scripts/saisies_geo_landscape.gd"
const VILLAGE_SCRIPT_PATH := "res://scripts/saisies_geo_village.gd"
const S02_SHOP_SCENE_PATH := "res://scenes/props/SaisiesS02Shop.tscn"
const S02_SHOP_SCRIPT_PATH := "res://scripts/saisies_s02_shop.gd"
const PROPS_SCRIPT_PATH := "res://scripts/saisies_geo_village_props.gd"
const BUILDINGS_SCRIPT_PATH := "res://scripts/saisies_geo_buildings.gd"
const ROUTE_FILE := "res://data/saisies_geo_route.json"
const DEFAULT_OUTPUT_DIR := "res://export/saisies/review/round14_village_analysis"
const S02_SHOP_STATION_M := 340.0
const S02_SHOP_LATERAL_M := -9.5
const S02_SHOP_PREVIOUS_STATION_M := 350.0
const S02_SHOP_PREVIOUS_LATERAL_M := -11.6
const S02_INTERSECTION_LODGE_STATION_M := 320.0
const S02_INTERSECTION_LODGE_LATERAL_M := -14.0
const S02_INTERSECTION_LODGE_PREVIOUS_STATION_M := 333.0
const S02_INTERSECTION_LODGE_PREVIOUS_LATERAL_M := -11.2
const S02_INTERSECTION_LODGE_REJECTED_STATION_M := 333.0
const S02_INTERSECTION_LODGE_REJECTED_LATERAL_M := -20.0
const S02_ISLAND_STATION_M := 308.0
const S02_ISLAND_PREVIOUS_STATION_M := 320.0
const S03_CAFE_STATION_M := 970.0
const S03_CAFE_PREVIOUS_STATION_M := 943.0

var _errors: Array[String] = []
var _verification_grid_size := 385
var _output_dir := DEFAULT_OUTPUT_DIR
var _verification_snapshot: Dictionary = {}

func _initialize() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	if "--production-grid" in args:
		_verification_grid_size = 769
	for arg in args:
		var value := String(arg)
		if value.begins_with("--grid="):
			var parsed_size := value.trim_prefix("--grid=").to_int()
			if parsed_size >= 2:
				_verification_grid_size = parsed_size
		elif value.begins_with("--output-dir="):
			_output_dir = value.trim_prefix("--output-dir=")
	call_deferred("_run")

func _run() -> void:
	_verify_scene_contract()
	var route_script := load(ROUTE_SCRIPT_PATH) as Script
	var landscape_script := load(LANDSCAPE_SCRIPT_PATH) as Script
	var village_script := load(VILLAGE_SCRIPT_PATH) as Script
	var props_script := load(PROPS_SCRIPT_PATH) as Script
	var buildings_script := load(BUILDINGS_SCRIPT_PATH) as Script
	if route_script == null or landscape_script == null or village_script == null or props_script == null or buildings_script == null:
		_fail("one or more geographic village scripts could not be loaded")
		_finish()
		return

	var holder := Node3D.new()
	holder.name = "SaisiesGeoVillageVerification"
	get_root().add_child(holder)
	var route := route_script.new() as Node3D
	route.name = "Route"
	route.set("geo_route_file", ROUTE_FILE)
	holder.add_child(route)
	for _attempt in range(180):
		if bool(route.call("route_ready")):
			break
		await process_frame
	if not bool(route.call("route_ready")):
		_fail("geographic route did not become ready")
	else:
		var landscape := landscape_script.new() as Node3D
		landscape.name = "Landscape"
		landscape.set("route_path", NodePath("../Route"))
		# The production scene keeps the authored 769 grid.  The default focused
		# contract uses a smaller displayed mesh for quick CI/headless checks while
		# exercising the same sample_mesh_triangle API. Pass --production-grid or
		# --grid=769 when the frozen production mesh must be checked.
		landscape.set("build_grid_size", _verification_grid_size)
		landscape.set("max_vertices", 700000 if _verification_grid_size >= 769 else 200000)
		holder.add_child(landscape)
		var village := village_script.new() as Node3D
		village.name = "VillageS01S02"
		village.set("route_path", NodePath("../Route"))
		village.set("landscape_path", NodePath("../Landscape"))
		village.set("from_m", 0.0)
		village.set("to_m", 560.0)
		holder.add_child(village)
		var props := props_script.new() as Node3D
		props.name = "VillagePropsS01"
		props.set("route_path", NodePath("../Route"))
		props.set("landscape_path", NodePath("../Landscape"))
		props.set("from_m", 0.0)
		props.set("to_m", 220.0)
		holder.add_child(props)
		var buildings := buildings_script.new() as Node3D
		buildings.name = "Buildings"
		buildings.set("route_path", NodePath("../Route"))
		buildings.set("landscape_path", NodePath("../Landscape"))
		buildings.set("authored_village_path", NodePath("../VillageS01S02"))
		holder.add_child(buildings)

		for _attempt in range(480):
			if bool(landscape.get("landscape_ready")) and bool(village.get("village_ready")) and bool(props.get("props_ready")) and bool(buildings.get("buildings_ready")):
				break
			await process_frame
		if not bool(landscape.get("landscape_ready")):
			_fail("focused GeoLandscape did not become ready")
		if not bool(village.get("village_ready")):
			_fail("SaisiesGeoVillage did not become ready")
		if not bool(props.get("props_ready")):
			_fail("SaisiesGeoVillageProps did not become ready")
		if not bool(buildings.get("buildings_ready")):
			_fail("SaisiesGeoBuildings did not become ready")
		if bool(village.get("village_ready")):
			_verify_village(route, landscape, village)
		if bool(props.get("props_ready")):
			_verify_props(props)
		if bool(buildings.get("buildings_ready")):
			_verify_osm_suppression(buildings)
		holder.queue_free()
	_finish()

func _verify_scene_contract() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("MainScene_saisies_geo.tscn could not be loaded")
		return
	var root := packed.instantiate() as Node3D
	if root == null:
		_fail("MainScene_saisies_geo.tscn did not instantiate a Node3D root")
		return
	var names: Array[String] = []
	for child in root.get_children():
		names.append(String(child.name))
	var landscape_index := names.find("Landscape")
	var village_index := names.find("VillageS01S02")
	var props_index := names.find("VillagePropsS01")
	var buildings_index := names.find("Buildings")
	if landscape_index < 0 or village_index < 0 or props_index < 0 or buildings_index < 0:
		_fail("geo scene is missing Landscape/VillageS01S02/VillagePropsS01/Buildings nodes")
	else:
		if not (landscape_index < village_index and village_index < props_index and props_index < buildings_index):
			_fail("geo scene node order must be Landscape, VillageS01S02, VillagePropsS01, then Buildings")
		var village := root.get_node_or_null("VillageS01S02") as Node3D
		var props := root.get_node_or_null("VillagePropsS01") as Node3D
		if village == null or String((village.get_script() as Script).resource_path) != VILLAGE_SCRIPT_PATH:
			_fail("VillageS01S02 does not use saisies_geo_village.gd")
		if props == null or String((props.get_script() as Script).resource_path) != PROPS_SCRIPT_PATH:
			_fail("VillagePropsS01 does not use saisies_geo_village_props.gd")
		var buildings := root.get_node_or_null("Buildings") as Node3D
		if buildings != null and _has_property(buildings, "authored_village_path"):
			if buildings.get("authored_village_path") != NodePath("../VillageS01S02"):
				_fail("Buildings.authored_village_path does not point to ../VillageS01S02")
	root.free()

func _verify_village(route: Node3D, landscape: Node3D, village: Node3D) -> void:
	var from_m := float(village.get_meta("saisies_village_from_m", -1.0))
	var to_m := float(village.get_meta("saisies_village_to_m", -1.0))
	if absf(from_m) > 0.01 or absf(to_m - 560.0) > 0.01:
		_fail("geo village corridor is %.1f..%.1f m, expected 0..560 m" % [from_m, to_m])
	var scene_ids: Array = village.get_meta("saisies_village_scene_ids", [])
	if not scene_ids.has("S01") or not scene_ids.has("S02") or not scene_ids.has("S03"):
		_fail("geo village scene ids must contain S01/S02/S03: %s" % scene_ids)
	if int(village.get_meta("saisies_village_chairlift_towers", -1)) != 2:
		_fail("geo village must report two S03 chairlift towers")
	if String(village.get_meta("saisies_geo_village_ground_source", "")) != "Landscape.sample_mesh_triangle":
		_fail("geo village ground source is not Landscape.sample_mesh_triangle")
	if int(village.get_meta("saisies_geo_village_contact_fallback_count", -1)) != 0:
		_fail("geo village used %d non-mesh contact fallbacks" % int(village.get_meta("saisies_geo_village_contact_fallback_count", -1)))
	if bool(village.get_meta("saisies_geo_village_osm_duplicate_claimed", true)):
		_fail("geo village claimed OSM duplicates before Buildings consumed the API")
	if absf(float(village.get_meta("saisies_geo_village_s02_shop_station_m", -1.0)) - S02_SHOP_STATION_M) > 0.01 or absf(float(village.get_meta("saisies_geo_village_s02_shop_lateral_m", 999.0)) - S02_SHOP_LATERAL_M) > 0.01:
		_fail("geo village S02 low-shop root station metadata is stale")
	if absf(float(village.get_meta("saisies_geo_village_s03_cafe_station_m", -1.0)) - S03_CAFE_STATION_M) > 0.01 or absf(float(village.get_meta("saisies_geo_village_s03_cafe_previous_station_m", -1.0)) - S03_CAFE_PREVIOUS_STATION_M) > 0.01:
		_fail("geo village S03 café root station metadata is stale")

	var buildings := village.get_node_or_null("S01S02Buildings") as Node3D
	var details := village.get_node_or_null("S01S02StreetDetails") as Node3D
	if buildings == null or details == null:
		_fail("geo village groups are incomplete")
		return
	var restaurant := buildings.get_node_or_null("Restaurant_Ravoula") as Node3D
	if restaurant == null:
		_fail("retained S01 restaurant is missing")
	else:
		if int(restaurant.get_meta("saisies_s01_upper_window_bays", 0)) < 7 or int(restaurant.get_meta("saisies_s01_ground_window_bays", 0)) < 6:
			_fail("restaurant window bays were not retained")
		if int(restaurant.get_meta("saisies_s01_balcony_uprights", 0)) < 9:
			_fail("restaurant balcony uprights were not retained")
		if restaurant.get_node_or_null("RestaurantAwning_1p65m") == null or restaurant.get_node_or_null("RestaurantFrontGableEnd") == null:
			_fail("restaurant awning/gable detail was not retained")
		if restaurant.get_node_or_null("RestaurantSignBandUpper") == null or restaurant.get_node_or_null("RestaurantSignBandLower") == null:
			_fail("restaurant signed shop bands were not retained")
		var upper_sign := restaurant.get_node_or_null("RestaurantSignBandUpperLabel") as Label3D
		var lower_sign := restaurant.get_node_or_null("RestaurantSignBandLowerLabel") as Label3D
		if upper_sign == null or not upper_sign.text.contains("SAVOYARD"):
			_fail("restaurant upper sign must retain SAVOYARD source wording")
		if lower_sign == null or not lower_sign.text.contains("OLYMPE"):
			_fail("restaurant lower sign must retain OLYMPE source wording")
		if (upper_sign != null and upper_sign.pixel_size > 0.004) or (lower_sign != null and lower_sign.pixel_size > 0.004):
			_fail("restaurant source sign labels exceed the authored band scale")
		var pane_count := 0
		for index in range(6):
			if restaurant.get_node_or_null("RestaurantStorePane_%02d" % index) != null and restaurant.get_node_or_null("RestaurantStoreInterior_%02d" % index) != null:
				pane_count += 1
		if pane_count != 6:
			_fail("restaurant show-window geometry is incomplete: %d/6 panes" % pane_count)

	var hotel := buildings.get_node_or_null("Rear_Hotel") as Node3D
	if hotel == null:
		_fail("retained S01 dark hotel is missing")
	else:
		if int(hotel.get_meta("saisies_s01_hotel_stories", 0)) < 4 or int(hotel.get_meta("saisies_s01_hotel_balconies", 0)) < 4:
			_fail("dark hotel floors/balconies were not retained")
		if hotel.get_node_or_null("HotelLowSlopeRoof") == null or hotel.get_node_or_null("HotelBalconyDeck_03") == null:
			_fail("dark hotel roof/balcony geometry is incomplete")

	var lodge := buildings.get_node_or_null("Right_Alpine_Lodge") as Node3D
	if lodge == null:
		_fail("retained right alpine lodge is missing")
	else:
		if not bool(lodge.get_meta("saisies_s01_right_lodge_roof_grid", false)) or int(lodge.get_meta("saisies_s01_right_lodge_roof_ribs", 0)) < 6:
			_fail("right alpine lodge roof grid was not retained")
		if lodge.get_node_or_null("RightLodgeRoofRib_-1_00") == null or lodge.get_node_or_null("RightLodgeRoofRib_1_06") == null:
			_fail("right alpine lodge roof rib geometry is incomplete")

	var intersection_lodge := buildings.get_node_or_null("Intersection_Lodge") as Node3D
	if intersection_lodge == null:
		_fail("retained S02 intersection lodge is missing")
	else:
		if absf(float(intersection_lodge.get_meta("saisies_s02_intersection_lodge_station_m", -1.0)) - S02_INTERSECTION_LODGE_STATION_M) > 0.01:
			_fail("S02 intersection lodge station metadata changed")
		if absf(float(intersection_lodge.get_meta("saisies_s02_intersection_lodge_lateral_m", 999.0)) - S02_INTERSECTION_LODGE_LATERAL_M) > 0.01:
			_fail("S02 intersection lodge must use visual candidate s320/u-14.0")
		if absf(float(intersection_lodge.get_meta("saisies_s02_intersection_lodge_previous_station_m", -1.0)) - S02_INTERSECTION_LODGE_PREVIOUS_STATION_M) > 0.01 or absf(float(intersection_lodge.get_meta("saisies_s02_intersection_lodge_previous_lateral_m", 999.0)) - S02_INTERSECTION_LODGE_PREVIOUS_LATERAL_M) > 0.01:
			_fail("S02 intersection lodge original 333/u-11.2 metadata is missing")
		if absf(float(intersection_lodge.get_meta("saisies_s02_intersection_lodge_rejected_station_m", -1.0)) - S02_INTERSECTION_LODGE_REJECTED_STATION_M) > 0.01 or absf(float(intersection_lodge.get_meta("saisies_s02_intersection_lodge_rejected_lateral_m", 999.0)) - S02_INTERSECTION_LODGE_REJECTED_LATERAL_M) > 0.01:
			_fail("S02 intersection lodge rejected 333/u-20 metadata is missing")
		if String(intersection_lodge.get_meta("saisies_s02_intersection_lodge_placement_basis", "")) != "visual_estimate_after_native_probe":
			_fail("S02 intersection lodge placement basis must remain an explicit visual estimate")
		if int(intersection_lodge.get_meta("saisies_s02_intersection_lodge_stories", 0)) < 3:
			_fail("S02 intersection lodge did not retain the taller three-level proportion")
		if not bool(intersection_lodge.get_meta("saisies_s02_intersection_lodge_cream_base", false)) or not bool(intersection_lodge.get_meta("saisies_s02_intersection_lodge_dark_timber", false)):
			_fail("S02 intersection lodge cream base/dark timber mass is incomplete")
		if int(intersection_lodge.get_meta("saisies_s02_intersection_lodge_white_eaves", 0)) < 3 or int(intersection_lodge.get_meta("saisies_s02_intersection_lodge_balconies", 0)) < 2:
			_fail("S02 intersection lodge eave/gallery layers are incomplete")
		if intersection_lodge.get_node_or_null("IntersectionLodgeCreamBase") == null or intersection_lodge.get_node_or_null("IntersectionLodgeDarkTimberBody") == null:
			_fail("S02 intersection lodge layered wall masses are missing")
		if intersection_lodge.get_node_or_null("IntersectionLodgeWhiteEave_01") == null or intersection_lodge.get_node_or_null("IntersectionLodgeWhiteEave_02") == null:
			_fail("S02 intersection lodge white eave bands are missing")
		if intersection_lodge.get_node_or_null("IntersectionLodgeBalconyDeck_01") == null or intersection_lodge.get_node_or_null("IntersectionLodgeBalconyDeck_02") == null:
			_fail("S02 intersection lodge external galleries are missing")
		if intersection_lodge.get_node_or_null("IntersectionLodgeFrontDoor") == null or intersection_lodge.get_node_or_null("IntersectionLodgeWhiteRoofFasciaFront") == null:
			_fail("S02 intersection lodge door/roof details are missing")
		var cream_base_mesh := intersection_lodge.get_node_or_null("IntersectionLodgeCreamBase") as MeshInstance3D
		var dark_body_mesh := intersection_lodge.get_node_or_null("IntersectionLodgeDarkTimberBody") as MeshInstance3D
		var door_mesh := intersection_lodge.get_node_or_null("IntersectionLodgeFrontDoor") as MeshInstance3D
		var ground_window_mesh := intersection_lodge.get_node_or_null("IntersectionLodgeFrontWindow_00_00") as MeshInstance3D
		if cream_base_mesh == null or not (cream_base_mesh.mesh is BoxMesh) or dark_body_mesh == null or not (dark_body_mesh.mesh is BoxMesh):
			_fail("S02 intersection lodge floor masses are not BoxMesh dimensions")
		else:
			var cream_height := (cream_base_mesh.mesh as BoxMesh).size.y
			var upper_height := (dark_body_mesh.mesh as BoxMesh).size.y
			if cream_height < 2.40 or upper_height < 4.80 or cream_height + upper_height < 7.20:
				_fail("S02 intersection lodge floor/body dimensions are too short: base=%.2f upper=%.2f" % [cream_height, upper_height])
		if door_mesh == null or not (door_mesh.mesh is BoxMesh) or (door_mesh.mesh as BoxMesh).size.y < 1.90:
			_fail("S02 intersection lodge door must be approximately human scale")
		if ground_window_mesh == null or not (ground_window_mesh.mesh is BoxMesh) or (ground_window_mesh.mesh as BoxMesh).size.y < 1.05:
			_fail("S02 intersection lodge ground windows are too short")

	var island := details.get_node_or_null("S02StonePlantedIsland") as Node3D
	if island == null:
		_fail("S02 planted junction island is missing")
	else:
		if absf(float(island.get_meta("route_distance_m", -1.0)) - S02_ISLAND_STATION_M) > 0.01:
			_fail("S02 planted island must be built at Geo visual candidate station 308m")
		if absf(float(island.get_meta("saisies_geo_s02_island_station_m", -1.0)) - S02_ISLAND_STATION_M) > 0.01:
			_fail("S02 planted island station metadata is stale")
		if absf(float(island.get_meta("saisies_geo_s02_island_previous_station_m", -1.0)) - S02_ISLAND_PREVIOUS_STATION_M) > 0.01:
			_fail("S02 planted island previous 320m metadata is missing")
		if String(island.get_meta("saisies_geo_s02_island_station_basis", "")) != "visual_estimate_after_native_probe":
			_fail("S02 planted island station must remain an explicit visual estimate")
		if String(island.get_meta("saisies_geo_s02_island_planting_material", "")) != "dark_natural_green":
			_fail("S02 island planting cap must use the dark natural green override")
		var planting_cap := island.get_node_or_null("S02IslandPlantingCap") as MeshInstance3D
		if planting_cap == null or planting_cap.material_override == null:
			_fail("S02 island planting cap mesh/material is missing")
		else:
			var planting_material := planting_cap.material_override as StandardMaterial3D
			if planting_material == null:
				_fail("S02 island planting cap material is not StandardMaterial3D")
			elif planting_material.albedo_color.g > 0.35 or planting_material.albedo_color.b > 0.18:
				_fail("S02 island planting cap is not dark natural green: %s" % planting_material.albedo_color)
	if details.get_node_or_null("S02Crosswalk_00") == null:
		_fail("S02 junction crossing detail is missing")
	_verify_s02_shop(route, landscape, village)
	_verify_s02_building_separation(village)
	_verify_s03(route, landscape, village)

	_verify_finite(village)
	_verify_forbidden_content(village)
	_verify_foundations_and_road(route, landscape, village, buildings)
	var s03_group := village.get_node_or_null("S03Chairlift") as Node3D
	if s03_group != null:
		_verify_foundations_and_road(route, landscape, village, s03_group)
	var polygons_variant = village.call("get_authored_building_footprints")
	if not (polygons_variant is Array):
		_fail("authored footprint API did not return an Array")
	else:
		var polygons: Array = polygons_variant
		if polygons.size() < 8:
			_fail("authored footprint API returned only %d building polygons" % polygons.size())
		for polygon_item in polygons:
			if not (polygon_item is PackedVector2Array) or (polygon_item as PackedVector2Array).size() < 4:
				_fail("authored footprint API returned a non-polygon record")
	var records_variant = village.call("get_authored_footprint_records")
	if not (records_variant is Array) or (records_variant as Array).size() != polygons_variant.size():
		_fail("authored footprint record API does not align with polygon API")
		print("geo village: grid=%d range=%.0f..%.0f m buildings=%d footprints=%d S01/S02 retained, S03 mapped" % [_verification_grid_size, from_m, to_m, int(village.get_meta("saisies_village_building_count", 0)), polygons_variant.size()])

func _verify_s03(route: Node3D, landscape: Node3D, village: Node3D) -> void:
	var group := village.get_node_or_null("S03Chairlift") as Node3D
	if group == null:
		_fail("mapped S03Chairlift group is missing")
		return
	if String(group.get_meta("saisies_geo_s03_ground_source", "")) != "Landscape.sample_mesh_triangle":
		_fail("S03 group ground source is not Landscape.sample_mesh_triangle")
	if int(group.get_meta("saisies_geo_s03_tower_count", 0)) != 2:
		_fail("S03 group must contain exactly two tower anchors")
	if int(group.get_meta("saisies_geo_s03_flowerbox_count", 0)) != 3:
		_fail("S03 group must retain three right-side flowerboxes")
	if int(group.get_meta("saisies_geo_s03_direction_sign_count", 0)) != 3:
		_fail("S03 group must retain three direction signs")
	var expected_tower_stations := [955.0, 955.0]
	for index in range(2):
		var tower := group.get_node_or_null("S03ChairliftTower_%d" % index) as Node3D
		if tower == null:
			_fail("S03 tower %d is missing" % index)
			continue
		if String(tower.get_meta("saisies_geo_contact_source", "")) != "landscape.sample_mesh_triangle":
			_fail("S03 tower %d base is not sampled from Landscape triangles" % index)
		if absf(float(tower.get_meta("saisies_geo_s03_tower_station_m", -1.0)) - expected_tower_stations[index]) > 0.01:
			_fail("S03 tower %d is not at the mapped 955m cable station" % index)
		if tower.global_transform.basis.y.normalized().dot(Vector3.UP) < 0.95:
			_fail("S03 tower %d is not upright" % index)
		var expected_ground: Variant = landscape.call("sample_mesh_triangle", Vector2(tower.global_position.x, tower.global_position.z))
		if not (expected_ground is Dictionary) or not expected_ground.has("height") or absf(float(expected_ground["height"]) - tower.global_position.y) > 0.03:
			_fail("S03 tower %d base does not contact the displayed mesh" % index)

	var cable_segments: Array[Node3D] = []
	for index in range(1, 7):
		var segment := group.get_node_or_null("S03ChairliftCable_%02d" % index) as Node3D
		if segment == null:
			_fail("S03 cable segment %02d is missing" % index)
			continue
		cable_segments.append(segment)
		if not bool(segment.get_meta("saisies_geo_s03_cable_continuous", false)):
			_fail("S03 cable segment %02d lacks continuity metadata" % index)
		var a: Vector3 = segment.get_meta("saisies_geo_s03_cable_a", Vector3(NAN, NAN, NAN))
		var b: Vector3 = segment.get_meta("saisies_geo_s03_cable_b", Vector3(NAN, NAN, NAN))
		for endpoint in [a, b]:
			var sampled: Variant = landscape.call("sample_mesh_triangle", Vector2(endpoint.x, endpoint.z))
			if not (sampled is Dictionary) or not sampled.has("height") or endpoint.y < float(sampled["height"]) + 0.05:
				_fail("S03 cable segment %02d endpoint is below the displayed road/terrain" % index)
		var midpoint := (a + b) * 0.5
		var midpoint_sampled: Variant = landscape.call("sample_mesh_triangle", Vector2(midpoint.x, midpoint.z))
		if not (midpoint_sampled is Dictionary) or not midpoint_sampled.has("height") or midpoint.y < float(midpoint_sampled["height"]) + 0.05:
			_fail("S03 cable segment %02d midpoint is below the displayed road/terrain" % index)
		if index > 1 and cable_segments[index - 2].get_meta("saisies_geo_s03_cable_b", Vector3.ZERO).distance_to(a) > 0.02:
			_fail("S03 cable segments are not continuous at %02d" % index)

	var apron := group.get_node_or_null("S03BroadJunctionApron") as MeshInstance3D
	if apron == null or apron.mesh == null:
		_fail("S03 broad junction apron mesh is missing")
	else:
		if String(apron.get_meta("saisies_geo_s03_ground_source", "")) != "Landscape.sample_mesh_triangle":
			_fail("S03 apron does not report triangle sampled ground")
		var faces := apron.mesh.get_faces()
		if faces.size() < 12 or faces.size() % 3 != 0:
			_fail("S03 apron has too few triangle faces")
		else:
			for face_offset in range(0, faces.size(), 3):
				var a: Vector3 = apron.global_transform * faces[face_offset]
				var b: Vector3 = apron.global_transform * faces[face_offset + 1]
				var c: Vector3 = apron.global_transform * faces[face_offset + 2]
				# Mesh.get_faces() follows Godot's clockwise front-face convention;
				# this is the same winding test used by the geographic building and
				# landscape verifiers.
				var normal := (c - a).cross(b - a)
				if normal.length_squared() < 0.000001 or normal.normalized().y < 0.001:
					_fail("S03 apron triangle winding is not Godot clockwise/up at face %d" % face_offset)
				for point in [a, b, c]:
					var sampled: Variant = landscape.call("sample_mesh_triangle", Vector2(point.x, point.z))
					if not (sampled is Dictionary) or not sampled.has("height") or absf(point.y - float(sampled["height"]) - 0.055) > 0.08:
						_fail("S03 apron vertex is not on sampled terrain at face %d" % face_offset)

	var cafe := group.get_node_or_null("S03LeftLiftLodge") as Node3D
	if cafe == null:
		_fail("S03 low café/lift-lodge footprint is missing")
	else:
		if not bool(cafe.get_meta("saisies_s03_cafe", false)) or not bool(cafe.get_meta("saisies_s03_cafe_low_gable", false)):
			_fail("S03 left building is not marked as the low-gable café")
		if int(cafe.get_meta("saisies_s03_cafe_stories", 0)) != 1:
			_fail("S03 café must be one storey")
		if absf(float(cafe.get_meta("saisies_s03_cafe_station_m", -1.0)) - S03_CAFE_STATION_M) > 0.01:
			_fail("S03 café is not at visual candidate station 970m")
		if absf(float(cafe.get_meta("saisies_s03_cafe_previous_station_m", -1.0)) - S03_CAFE_PREVIOUS_STATION_M) > 0.01:
			_fail("S03 café previous 943m station metadata is missing")
		if String(cafe.get_meta("saisies_s03_cafe_station_basis", "")) != "visual_estimate_after_native_probe":
			_fail("S03 café station must remain an explicit visual estimate")
		if String(cafe.get_meta("saisies_s03_cafe_wall_material", "")) != "dark_wood":
			_fail("S03 café wall material is not the dark wood candidate")
		if String(cafe.get_meta("saisies_s03_cafe_roof_material", "")) != "medium_grey":
			_fail("S03 café roof material contract changed from medium grey")
		var cafe_body := cafe.get_node_or_null("S03CafeLowBody") as MeshInstance3D
		if cafe_body == null or cafe_body.material_override == null:
			_fail("S03 café dark wood body mesh/material is missing")
		else:
			var cafe_body_material := cafe_body.material_override as StandardMaterial3D
			if cafe_body_material == null or cafe_body_material.albedo_color.r > 0.40 or cafe_body_material.albedo_color.g > 0.30:
				_fail("S03 café body remains too light for the dark wood candidate")
		var cafe_roof := cafe.get_node_or_null("RoofSlopeNegX") as MeshInstance3D
		if cafe_roof == null or cafe_roof.material_override == null:
			_fail("S03 café medium-grey roof mesh/material is missing")
		else:
			var cafe_roof_material := cafe_roof.material_override as StandardMaterial3D
			if cafe_roof_material == null or cafe_roof_material.albedo_color.r < 0.30 or cafe_roof_material.albedo_color.r > 0.55 or absf(cafe_roof_material.albedo_color.g - cafe_roof_material.albedo_color.r) > 0.10:
				_fail("S03 café roof is not the medium-grey candidate")
		var terrace := group.get_node_or_null("S03CafeFrontTerrace") as MeshInstance3D
		if cafe.get_node_or_null("S03CafeSign") == null or terrace == null:
			_fail("S03 café foundation/sign/terrace details are incomplete")
		if terrace != null:
			_verify_s03_cafe_terrace(route, landscape, cafe, terrace)
		if cafe.get_node_or_null("GeoVillageFoundation") == null:
			_fail("S03 café footprint API did not publish GeoVillageFoundation")
	_verification_snapshot["s03"] = {
		"group": String(group.name),
		"ground_source": group.get_meta("saisies_geo_s03_ground_source", ""),
		"tower_count": int(group.get_meta("saisies_geo_s03_tower_count", 0)),
		"cable_segment_count": cable_segments.size(),
		"flowerbox_count": int(group.get_meta("saisies_geo_s03_flowerbox_count", 0)),
		"direction_sign_count": int(group.get_meta("saisies_geo_s03_direction_sign_count", 0)),
		"cable_station_m": group.get_meta("saisies_geo_s03_cable_station_m", null),
		"cafe_station_m": group.get_meta("saisies_geo_s03_cafe_station_m", null),
		"cafe_previous_station_m": group.get_meta("saisies_geo_s03_cafe_previous_station_m", null),
		"cafe_station_basis": group.get_meta("saisies_geo_s03_cafe_station_basis", ""),
		"apron_from_m": group.get_meta("saisies_geo_s03_apron_from_m", null),
		"apron_to_m": group.get_meta("saisies_geo_s03_apron_to_m", null)
	}

func _verify_s03_cafe_terrace(route: Node3D, landscape: Node3D, cafe: Node3D, terrace: MeshInstance3D) -> void:
	if terrace.mesh == null:
		_fail("S03 café front terrace mesh is missing")
		return
	var faces := terrace.mesh.get_faces()
	if faces.size() < 6 or faces.size() % 3 != 0:
		_fail("S03 café front terrace has too few triangle vertices")
		return
	var min_station := INF
	var max_station := -INF
	var min_lateral := INF
	var max_lateral := -INF
	var cafe_body_polygon: PackedVector2Array = cafe.get_meta("saisies_geo_authored_footprint_world_xz", PackedVector2Array())
	var cafe_front_min_lateral := INF
	for body_point in cafe_body_polygon:
		var body_world := Vector3(body_point.x, 0.0, body_point.y)
		var body_station := float(route.call("distance_for_position", body_world))
		var body_route_point: Vector3 = route.call("pos_at", body_station)
		var body_left: Vector3 = route.call("left_at", body_station)
		var body_lateral := (body_world - Vector3(body_route_point.x, 0.0, body_route_point.z)).dot(Vector3(body_left.x, 0.0, body_left.z))
		cafe_front_min_lateral = minf(cafe_front_min_lateral, body_lateral)
	if not is_finite(cafe_front_min_lateral):
		_fail("S03 café body footprint cannot establish the road-facing front")
		return
	var sampled_vertices := 0
	for local_point in faces:
		var world_point: Vector3 = terrace.global_transform * local_point
		var station := float(route.call("distance_for_position", world_point))
		var route_point: Vector3 = route.call("pos_at", station)
		var left: Vector3 = route.call("left_at", station)
		var world_xz := Vector3(world_point.x, 0.0, world_point.z)
		var lateral := (world_xz - Vector3(route_point.x, 0.0, route_point.z)).dot(Vector3(left.x, 0.0, left.z))
		min_station = minf(min_station, station)
		max_station = maxf(max_station, station)
		min_lateral = minf(min_lateral, lateral)
		max_lateral = maxf(max_lateral, lateral)
		var sampled: Variant = landscape.call("sample_mesh_triangle", Vector2(world_point.x, world_point.z))
		if not (sampled is Dictionary) or not sampled.has("height"):
			_fail("S03 café front terrace vertex left the displayed terrain mesh")
		else:
			sampled_vertices += 1
			if absf(world_point.y - float(sampled["height"]) - 0.045) > 0.08:
				_fail("S03 café front terrace vertex is not grounded on the sampled mesh")
		if lateral <= float(route.call("road_width_at", station)) * 0.5 + 0.05:
			_fail("S03 café front terrace intrudes the road core at s=%.2f" % station)
	if min_station < S03_CAFE_STATION_M - 4.10 or max_station > S03_CAFE_STATION_M + 4.10:
		_fail("S03 café front terrace station span is not adjacent to the café: %.2f..%.2f" % [min_station, max_station])
	if max_lateral >= cafe_front_min_lateral - 0.02:
		_fail("S03 café front terrace is not between the road and café front: terrace_max=%.3f cafe_front=%.3f" % [max_lateral, cafe_front_min_lateral])
	_verification_snapshot["s03_terrace"] = {
		"ground_source": terrace.get_meta("saisies_geo_s03_ground_source", ""),
		"sampled_vertices": sampled_vertices,
		"vertex_count": faces.size(),
		"station_min_m": min_station,
		"station_max_m": max_station,
		"lateral_min_m": min_lateral,
		"lateral_max_m": max_lateral,
		"cafe_front_min_lateral_m": cafe_front_min_lateral,
		"road_and_cafe_front_order": "road < terrace < cafe front"
	}

func _verify_s02_shop(route: Node3D, landscape: Node3D, village: Node3D) -> void:
	var buildings := village.get_node_or_null("S01S02Buildings") as Node3D
	var anchor := buildings.get_node_or_null("S02LowShop") as Node3D if buildings != null else null
	if anchor == null:
		_fail("S02 low shop anchor is missing")
		return
	if absf(float(anchor.get_meta("saisies_s02_shop_anchor_station_m", -1.0)) - S02_SHOP_STATION_M) > 0.01:
		_fail("S02 low shop is not at visual candidate station 340m")
	if absf(float(anchor.get_meta("saisies_s02_shop_anchor_lateral_m", 999.0)) - S02_SHOP_LATERAL_M) > 0.01:
		_fail("S02 low shop is not at visual candidate lateral -9.5m")
	if absf(float(anchor.get_meta("saisies_s02_shop_previous_station_m", -1.0)) - S02_SHOP_PREVIOUS_STATION_M) > 0.01:
		_fail("S02 low shop previous station metadata is missing")
	if absf(float(anchor.get_meta("saisies_s02_shop_previous_lateral_m", 999.0)) - S02_SHOP_PREVIOUS_LATERAL_M) > 0.01:
		_fail("S02 low shop previous lateral metadata is missing")
	if String(anchor.get_meta("saisies_s02_shop_placement_basis", "")) != "visual_estimate_after_native_probe":
		_fail("S02 low shop placement must remain an explicit visual estimate")
	if String(anchor.get_meta("saisies_s02_shop_ground_source", "")) != "Landscape.sample_mesh_triangle":
		_fail("S02 low shop does not report triangle sampled ground")
	var centre_sample: Variant = landscape.call("sample_mesh_triangle", Vector2(anchor.global_position.x, anchor.global_position.z))
	if not (centre_sample is Dictionary) or not centre_sample.has("height") or absf(anchor.global_position.y - float(centre_sample["height"])) > 0.03:
		_fail("S02 low shop anchor centre is not on the displayed terrain mesh")
	var shop_instance := anchor.get_node_or_null("SaisiesS02Shop") as Node3D
	if shop_instance == null:
		_fail("S02 low shop prefab instance is missing")
		return
	if not bool(shop_instance.get_meta("saisies_s02_shop_ready", false)):
		_fail("S02 low shop prefab did not publish its ready contract")
	if String(shop_instance.get_meta("saisies_s02_shop_source_frame", "")) != "video/saisies_analysis/acceptance/S02_f000719.png":
		_fail("S02 low shop prefab source frame metadata changed")
	var building := shop_instance.get_node_or_null("S02LowShopBuilding") as Node3D
	if building == null:
		_fail("S02 low shop building node is missing")
	else:
		if String(building.get_meta("saisies_s02_shop_front_axis", "")) != "local -X" or String(building.get_meta("saisies_s02_shop_roof_axis", "")) != "local +X":
			_fail("S02 low shop local front/roof axes changed")
		if building.scale.distance_to(Vector3.ONE) > 0.001 or building.rotation.length() > 0.001:
			_fail("S02 low shop prefab must remain unscaled and unrotated")
		var shell := building.get_node_or_null("OpaqueTimberShell") as MeshInstance3D
		if shell == null or not (shell.mesh is BoxMesh):
			_fail("S02 low shop opaque shell is missing")
		else:
			var shell_size := (shell.mesh as BoxMesh).size
			if absf(shell_size.x - 7.4) > 0.01 or absf(shell_size.y - 2.45) > 0.01 or absf(shell_size.z - 4.4) > 0.01:
				_fail("S02 low shop shell dimensions changed: %s" % shell_size)
		if building.get_node_or_null("FrontDoor") == null or building.get_node_or_null("RoofRidgeCap") == null:
			_fail("S02 low shop door/long roof details are missing")
	var foundation := anchor.get_node_or_null("GeoVillageFoundation") as MeshInstance3D
	var foundation_box := foundation.mesh as BoxMesh if foundation != null else null
	if foundation_box == null:
		_fail("S02 low shop lacks a measurable GeoVillageFoundation mesh")
	else:
		if foundation_box.size.x < 7.80 or foundation_box.size.z < 4.80 or foundation_box.size.y < 0.42:
			_fail("S02 low shop foundation does not cover the prefab plinth and terrain support: %s" % foundation_box.size)
		var samples: Array = anchor.get_meta("saisies_geo_foundation_contact_samples", [])
		var min_ground := float(anchor.get_meta("saisies_geo_foundation_min_ground_y", NAN))
		var bottom_world: Vector3 = foundation.global_transform * Vector3(0.0, -foundation_box.size.y * 0.5, 0.0)
		if samples.size() < 8:
			_fail("S02 low shop foundation must sample all eight min-mesh corners/edges: %d" % samples.size())
		if not is_finite(min_ground) or bottom_world.y > min_ground + 0.20:
			_fail("S02 low shop foundation does not support the minimum sampled terrain: bottom=%.3f min_ground=%.3f" % [bottom_world.y, min_ground])
	var body_polygon: PackedVector2Array = anchor.get_meta("saisies_geo_authored_footprint_world_xz", PackedVector2Array())
	var foundation_polygon: PackedVector2Array = anchor.get_meta("saisies_geo_authored_foundation_footprint_world_xz", PackedVector2Array())
	if body_polygon.size() < 4 or foundation_polygon.size() < 4:
		_fail("S02 low shop body/foundation WORLDXZ footprint API is incomplete")
	_verification_snapshot["s02_shop"] = {
		"station_m": anchor.get_meta("saisies_s02_shop_anchor_station_m", null),
		"lateral_m": anchor.get_meta("saisies_s02_shop_anchor_lateral_m", null),
		"front_axis": anchor.get_meta("saisies_s02_shop_front_axis", ""),
		"roof_axis": anchor.get_meta("saisies_s02_shop_roof_axis", ""),
		"asset_ready": shop_instance.get_meta("saisies_s02_shop_ready", false),
		"body_footprint_vertices": body_polygon.size(),
		"foundation_footprint_vertices": foundation_polygon.size(),
		"foundation_contact_samples": int(anchor.get_meta("saisies_geo_foundation_contact_samples", []).size()),
		"foundation_min_ground_y": anchor.get_meta("saisies_geo_foundation_min_ground_y", null),
		"ground_source": anchor.get_meta("saisies_s02_shop_ground_source", "")
	}

func _verify_s02_building_separation(village: Node3D) -> void:
	var buildings := village.get_node_or_null("S01S02Buildings") as Node3D
	var details := village.get_node_or_null("S01S02StreetDetails") as Node3D
	var island := details.get_node_or_null("S02StonePlantedIsland") as Node3D if details != null else null
	var shop := buildings.get_node_or_null("S02LowShop") as Node3D if buildings != null else null
	var lodge := buildings.get_node_or_null("Intersection_Lodge") as Node3D if buildings != null else null
	if shop == null or lodge == null:
		return
	var polygon_pairs := [
		{"label": "body", "a": shop.get_meta("saisies_geo_authored_footprint_world_xz", PackedVector2Array()), "b": lodge.get_meta("saisies_geo_authored_footprint_world_xz", PackedVector2Array())},
		{"label": "foundation", "a": shop.get_meta("saisies_geo_authored_foundation_footprint_world_xz", PackedVector2Array()), "b": lodge.get_meta("saisies_geo_authored_foundation_footprint_world_xz", PackedVector2Array())}
	]
	for pair_value in polygon_pairs:
		var pair: Dictionary = pair_value
		var a: PackedVector2Array = pair["a"]
		var b: PackedVector2Array = pair["b"]
		if a.size() < 4 or b.size() < 4:
			_fail("S02 shop/lodge %s footprint pair is incomplete" % String(pair["label"]))
			continue
		var intersections := Geometry2D.intersect_polygons(a, b)
		for intersection_value in intersections:
			if intersection_value is PackedVector2Array and _polygon_area_abs(intersection_value as PackedVector2Array) > 0.005:
				_fail("S02 low shop and Intersection_Lodge %s footprints interpenetrate" % String(pair["label"]))
	_verification_snapshot["s02_layout"] = {
		"island_station_m": island.get_meta("route_distance_m", null) if island != null else null,
		"shop_station_m": shop.get_meta("saisies_s02_shop_anchor_station_m", null),
		"shop_lateral_m": shop.get_meta("saisies_s02_shop_anchor_lateral_m", null),
		"intersection_lodge_station_m": lodge.get_meta("saisies_s02_intersection_lodge_station_m", null),
		"intersection_lodge_lateral_m": lodge.get_meta("saisies_s02_intersection_lodge_lateral_m", null),
		"body_and_foundation_intersection_policy": "positive polygon area must be zero"
	}

func _polygon_area_abs(polygon: PackedVector2Array) -> float:
	var area := 0.0
	for index in range(polygon.size()):
		var next_index := (index + 1) % polygon.size()
		area += polygon[index].x * polygon[next_index].y - polygon[next_index].x * polygon[index].y
	return absf(area) * 0.5

func _verify_osm_suppression(buildings: Node3D) -> void:
	var count := int(buildings.get_meta("saisies_geo_buildings_authored_village_suppressed_count", -1))
	var ids: Array = buildings.get_meta("saisies_geo_buildings_authored_village_suppressed_ids", [])
	var records: Array = buildings.get_meta("saisies_geo_buildings_authored_village_suppressions", [])
	var footprint_count := int(buildings.get_meta("saisies_geo_buildings_authored_village_footprint_count", -1))
	var clean_records: Array = []
	for record_value in records:
		if not (record_value is Dictionary):
			_fail("GeoBuildings suppression record is not a dictionary")
			continue
		var record: Dictionary = record_value
		var areas: Array = record.get("positive_intersection_areas_m2", [])
		if areas.is_empty():
			_fail("GeoBuildings suppression record %s lacks positive intersection areas" % String(record.get("id", "")))
		clean_records.append({
			"osm_id": String(record.get("osm_id", record.get("id", ""))),
			"authored_footprint_ids": record.get("authored_footprint_ids", []),
			"positive_intersection_areas_m2": areas
		})
	if count < 0 or count != records.size() or count != ids.size():
		_fail("GeoBuildings suppression metadata is inconsistent count=%d ids=%d records=%d" % [count, ids.size(), records.size()])
	if footprint_count < 1:
		_fail("GeoBuildings did not consume authored village footprints")
	_verification_snapshot["osm_suppression"] = {
		"suppressed_count": count,
		"suppressed_osm_ids": ids,
		"records": clean_records,
		"authored_footprint_count": footprint_count,
		"policy": "positive polygon intersection only; no blanket S03 residential suppression"
	}
	print("geo buildings authored suppression count=%d ids=%s records=%s" % [count, ids, JSON.stringify(clean_records)])

func _write_verification_report() -> void:
	var payload := {
		"schema_version": 1,
		"id": "saisies_round14_geo_village_s02_s03_verify",
		"status": "pass" if _errors.is_empty() else "failed",
		"grid_size": _verification_grid_size,
		"errors": _errors,
		"production_data_changed": false,
		"s02_shop_station_contract": {"station_m": S02_SHOP_STATION_M, "lateral_m": S02_SHOP_LATERAL_M, "previous_station_m": S02_SHOP_PREVIOUS_STATION_M, "previous_lateral_m": S02_SHOP_PREVIOUS_LATERAL_M, "placement_basis": "visual_estimate_after_native_probe", "asset_scene": S02_SHOP_SCENE_PATH},
		"s02_intersection_lodge_layout_contract": {"station_m": S02_INTERSECTION_LODGE_STATION_M, "lateral_m": S02_INTERSECTION_LODGE_LATERAL_M, "previous_station_m": S02_INTERSECTION_LODGE_PREVIOUS_STATION_M, "previous_lateral_m": S02_INTERSECTION_LODGE_PREVIOUS_LATERAL_M, "rejected_station_m": S02_INTERSECTION_LODGE_REJECTED_STATION_M, "rejected_lateral_m": S02_INTERSECTION_LODGE_REJECTED_LATERAL_M, "placement_basis": "visual_estimate_after_native_probe"},
		"s03_station_contract": {"cafe_m": S03_CAFE_STATION_M, "cafe_previous_m": S03_CAFE_PREVIOUS_STATION_M, "cafe_basis": "visual_estimate_after_native_probe", "cable_m": 955.0, "apron_from_m": 885.0, "apron_to_m": 1005.0},
		"village_script_sha256": _sha256_file(VILLAGE_SCRIPT_PATH),
		"s02_shop_scene_sha256": _sha256_file(S02_SHOP_SCENE_PATH),
		"s02_shop_script_sha256": _sha256_file(S02_SHOP_SCRIPT_PATH),
		"verify_script_sha256": _sha256_file("res://tools/verify_saisies_geo_village.gd"),
		"snapshot": _verification_snapshot
	}
	var path := _global_path(_output_dir.path_join("round14_geo_village_s03_verify_grid%d.json" % _verification_grid_size))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		print("could not write verification report: %s" % path)
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	print("geo village verify report=%s" % path)

func _global_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path if path.is_absolute_path() else ProjectSettings.globalize_path(path)

func _sha256_file(path: String) -> String:
	var file := FileAccess.open(_global_path(path), FileAccess.READ)
	if file == null:
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_buffer(file.get_length()))
	return context.finish().hex_encode()

func _verify_props(props: Node3D) -> void:
	if int(props.get_meta("saisies_village_props_flowerbox_count", 0)) != 5:
		_fail("geo village props did not retain five right flowerboxes")
	if int(props.get_meta("saisies_village_props_flagpole_count", 0)) != 4:
		_fail("geo village props did not retain four flags")
	if not bool(props.get_meta("saisies_geo_village_props_actual_mesh_contact", false)):
		_fail("geo village props did not report actual mesh contact")
	var group := props.get_node_or_null("S01VillageStreetProps") as Node3D
	if group == null:
		_fail("geo village props group is missing")
	else:
		for child in group.get_children():
			if not child is Node3D:
				continue
			var anchor := child as Node3D
			if String(anchor.get_meta("saisies_geo_contact_source", "")) != "landscape.sample_mesh_triangle":
				_fail("prop anchor %s lacks actual mesh contact" % anchor.name)
	_verify_finite(props)
	_verify_forbidden_content(props)

func _verify_forbidden_content(parent: Node) -> void:
	for child in parent.get_children():
		if String(child.name) == "PeriwinkleCanopyCards":
			continue
		var lower_name := String(child.name).to_lower()
		for forbidden in ["car", "vehicle", "bicycle", "bike", "person", "rider", "hud"]:
			if lower_name.contains(forbidden):
				_fail("forbidden village content node: %s" % child.get_path())
		_verify_forbidden_content(child)

func _verify_foundations_and_road(route: Node3D, landscape: Node3D, village: Node3D, buildings: Node3D) -> void:
	for child in buildings.get_children():
		if not child is Node3D:
			continue
		var block := child as Node3D
		if not block.has_meta("saisies_geo_authored_footprint_world_xz"):
			continue
		var samples: Array = block.get_meta("saisies_geo_foundation_contact_samples", [])
		if samples.size() < 6:
			_fail("%s has too few actual terrain foundation samples: %d" % [block.name, samples.size()])
		var foundation := block.get_node_or_null("GeoVillageFoundation") as MeshInstance3D
		var foundation_box := foundation.mesh as BoxMesh if foundation != null else null
		if foundation_box == null:
			_fail("%s lacks a measurable GeoVillageFoundation mesh" % block.name)
		else:
			var bottom_world: Vector3 = foundation.global_transform * Vector3(0.0, -foundation_box.size.y * 0.5, 0.0)
			var min_ground := float(block.get_meta("saisies_geo_foundation_min_ground_y", NAN))
			if not is_finite(bottom_world.y) or not is_finite(min_ground) or bottom_world.y > min_ground + 0.20:
				_fail("%s foundation does not contact actual mesh: bottom=%.3f min_ground=%.3f" % [block.name, bottom_world.y, min_ground])
			for sample_item in samples:
				if not (sample_item is Dictionary):
					_fail("%s foundation contact sample is not a dictionary" % block.name)
					continue
				var sample: Dictionary = sample_item
				var xz: Vector2 = sample.get("world_xz", Vector2(NAN, NAN))
				var actual = landscape.call("sample_mesh_triangle", xz)
				if not (actual is Dictionary) or not actual.has("height"):
					_fail("%s foundation sample left the GeoLandscape mesh" % block.name)
				elif absf(float(actual["height"]) - float(sample.get("ground_y", NAN))) > 0.03:
					_fail("%s foundation sample does not match actual mesh triangle" % block.name)
		_verify_footprint_clearance(route, block)

func _verify_footprint_clearance(route: Node3D, block: Node3D) -> void:
	var polygon: PackedVector2Array = block.get_meta("saisies_geo_authored_footprint_world_xz", PackedVector2Array())
	if polygon.size() < 4:
		_fail("%s authored footprint is degenerate" % block.name)
		return
	for edge_index in range(polygon.size()):
		var a := polygon[edge_index]
		var b := polygon[(edge_index + 1) % polygon.size()]
		for step in range(3):
			var point := a.lerp(b, float(step) * 0.5)
			var s := float(route.call("distance_for_position", Vector3(point.x, 0.0, point.y)))
			var route_point: Vector3 = route.call("pos_at", s)
			var lateral := (Vector3(point.x, 0.0, point.y) - route_point).dot(route.call("left_at", s))
			var clearance := absf(lateral) - float(route.call("road_width_at", s)) * 0.5
			if not is_finite(clearance) or clearance < 0.05:
				_fail("%s authored footprint intrudes road at s=%.1f clearance=%.2f m" % [block.name, s, clearance])
	var foundation := block.get_node_or_null("GeoVillageFoundation") as MeshInstance3D
	var foundation_box := foundation.mesh as BoxMesh if foundation != null else null
	if foundation_box == null:
		return
	var local_aabb := foundation.get_aabb()
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				var local_point := Vector3(local_aabb.position.x if x < 0.0 else local_aabb.end.x, local_aabb.position.y if y < 0.0 else local_aabb.end.y, local_aabb.position.z if z < 0.0 else local_aabb.end.z)
				var world_point: Vector3 = foundation.global_transform * local_point
				var s := float(route.call("distance_for_position", world_point))
				var route_point: Vector3 = route.call("pos_at", s)
				var lateral := (world_point - route_point).dot(route.call("left_at", s))
				var clearance := absf(lateral) - float(route.call("road_width_at", s)) * 0.5
				if not is_finite(clearance) or clearance < 0.0:
					_fail("%s foundation mesh intrudes road at s=%.1f clearance=%.2f m" % [block.name, s, clearance])

func _verify_finite(parent: Node) -> void:
	if parent is Node3D:
		var node := parent as Node3D
		var transform := node.global_transform
		for value in [transform.origin.x, transform.origin.y, transform.origin.z, transform.basis.x.x, transform.basis.x.y, transform.basis.x.z, transform.basis.y.x, transform.basis.y.y, transform.basis.y.z, transform.basis.z.x, transform.basis.z.y, transform.basis.z.z]:
			if not is_finite(float(value)):
				_fail("non-finite transform at %s" % node.get_path())
	for child in parent.get_children():
		_verify_finite(child)

func _has_property(node: Object, property_name: String) -> bool:
	for property in node.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES GEO VILLAGE VERIFY: " + message)

func _finish() -> void:
	_write_verification_report()
	if _errors.is_empty():
		print("SAISIES GEO VILLAGE VERIFY PASS")
		quit(0)
	else:
		print("SAISIES GEO VILLAGE VERIFY FAIL (%d errors)" % _errors.size())
		quit(1)

