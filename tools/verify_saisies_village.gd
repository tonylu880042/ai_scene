extends SceneTree

## Headless contract check for the authored S01-S03 resort module.

var _errors: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var route_script := load("res://scripts/saisies_route.gd") as Script
	var village_script := load("res://scripts/saisies_village.gd") as Script
	if route_script == null:
		_fail("saisies_route.gd could not be loaded")
	if village_script == null:
		_fail("saisies_village.gd could not be loaded")
	if not _errors.is_empty():
		_finish()
		return
	var holder := Node3D.new()
	holder.name = "SaisiesVillageVerification"
	get_root().add_child(holder)
	var route := route_script.new() as Node3D
	route.name = "Route"
	holder.add_child(route)
	var village := village_script.new() as Node3D
	village.name = "VillageS01S03"
	village.set("route_path", NodePath("../Route"))
	holder.add_child(village)
	await process_frame
	await process_frame
	if not bool(route.call("route_ready")):
		_fail("route did not become ready")
	if not bool(village.get("village_ready")):
		_fail("village module did not become ready")
	else:
		_verify(route, village)
	holder.queue_free()
	_finish()

func _verify(route: Node3D, village: Node3D) -> void:
	var from_m := float(village.get_meta("saisies_village_from_m", -1.0))
	var to_m := float(village.get_meta("saisies_village_to_m", -1.0))
	if from_m != 0.0 or to_m < 1200.0:
		_fail("village corridor range is %.0f..%.0f m" % [from_m, to_m])
	var ids: Array = village.get_meta("saisies_village_scene_ids", [])
	for expected in ["S01", "S02", "S03"]:
		if not ids.has(expected):
			_fail("scene id missing from village module: %s" % expected)
	var buildings := int(village.get_meta("saisies_village_building_count", 0))
	if buildings < 4:
		_fail("S01-S03 authored building groups are too sparse: %d" % buildings)
	_verify_s01_frontage(village)
	_verify_s01_right_lodge(route, village)
	var towers := int(village.get_meta("saisies_village_chairlift_towers", 0))
	if towers != 2:
		_fail("S03 chairlift tower count is %d, expected 2" % towers)
	for scene_id in ["S01", "S02", "S03"]:
		var distance := float(route.call("acceptance_distance", scene_id))
		if distance < from_m or distance > to_m:
			_fail("%s maps outside village corridor: %.1f m" % [scene_id, distance])
	print("saisies village: range=%.0f..%.0f m buildings=%d chairlift_towers=%d S01=%.1f S02=%.1f S03=%.1f" % [
		from_m, to_m, buildings, towers,
		float(route.call("acceptance_distance", "S01")),
		float(route.call("acceptance_distance", "S02")),
		float(route.call("acceptance_distance", "S03"))
	])
	_verify_s01_hotel_and_middle(route, village)
	_verify_s01_foundation_contacts(route, village)

func _verify_s01_frontage(village: Node3D) -> void:
	var restaurant := village.get_node_or_null("S01S03Buildings/Restaurant_Ravoula") as Node3D
	if restaurant == null:
		_fail("S01 restaurant frontage node is missing")
		return
	if int(restaurant.get_meta("saisies_s01_upper_window_bays", 0)) < 7:
		_fail("S01 restaurant upper facade has too few window bays")
	if int(restaurant.get_meta("saisies_s01_ground_window_bays", 0)) < 6:
		_fail("S01 restaurant ground facade has too few storefront bays")
	if int(restaurant.get_meta("saisies_s01_awning_supports", 0)) < 4:
		_fail("S01 restaurant awning is missing street supports")
	if int(restaurant.get_meta("saisies_s01_sign_bands", 0)) < 2:
		_fail("S01 restaurant needs two readable dark sign bands")
	var upper_sign := restaurant.get_node_or_null("RestaurantSignBandUpper") as MeshInstance3D
	var lower_sign := restaurant.get_node_or_null("RestaurantSignBandLower") as MeshInstance3D
	if upper_sign == null or lower_sign == null:
		_fail("S01 restaurant sign band geometry is missing")
	else:
		if upper_sign.position.y < 4.90 or upper_sign.position.y > 5.45:
			_fail("S01 restaurant upper sign is not under the gable: y=%.2f" % upper_sign.position.y)
		if lower_sign.position.y < 2.80 or lower_sign.position.y > 3.60:
			_fail("S01 restaurant lower sign is not above the awning: y=%.2f" % lower_sign.position.y)
		for sign_node in [upper_sign, lower_sign]:
			var sign_material := sign_node.material_override as StandardMaterial3D
			if sign_material == null or sign_material.albedo_color.r + sign_material.albedo_color.g + sign_material.albedo_color.b > 1.20:
				_fail("S01 restaurant sign backing lacks dark contrast")
	var upper_label := restaurant.get_node_or_null("RestaurantSignBandUpperLabel") as Label3D
	var lower_label := restaurant.get_node_or_null("RestaurantSignBandLowerLabel") as Label3D
	if upper_label == null or lower_label == null or not upper_label.text.contains("RESTAURANT") or not lower_label.text.contains("LA TABLE"):
		_fail("S01 restaurant readable sign labels are missing")
	elif upper_label.font_size < 64 or lower_label.font_size < 64 or upper_label.pixel_size < 0.004 or lower_label.pixel_size < 0.004:
		_fail("S01 restaurant sign labels are too small")
	var awning_depth := float(restaurant.get_meta("saisies_s01_awning_depth_m", 0.0))
	if absf(awning_depth - 1.65) > 0.03:
		_fail("S01 restaurant awning depth is %.2f m, expected 1.65 m" % awning_depth)
	var awning := restaurant.get_node_or_null("RestaurantAwning_1p65m") as MeshInstance3D
	var awning_box := awning.mesh as BoxMesh if awning != null else null
	if awning_box == null or absf(awning_box.size.x - 1.65) > 0.03:
		_fail("S01 restaurant awning mesh does not preserve the 1.65 m projection")
	if not bool(restaurant.get_meta("saisies_s01_has_shop_sign", false)):
		_fail("S01 restaurant shop sign is missing")
	var roof := restaurant.get_node_or_null("RestaurantGableRoof") as Node3D
	if roof == null:
		_fail("S01 restaurant gable roof node is missing")
	else:
		# The road-facing gable must span the 27 m frontage.  A roof whose
		# unrotated slab is deeper than it is long is the old street-parallel
		# orientation and reads as a flat shop strip from S01.
		var roof_slab := roof.get_child(0) as MeshInstance3D
		var roof_box := roof_slab.mesh as BoxMesh if roof_slab != null else null
		if roof_box == null or roof_box.size.x <= roof_box.size.z:
			_fail("S01 restaurant roof ridge is still aligned with the street frontage")
		if absf(absf(wrapf(roof.rotation.y, -PI, PI)) - PI * 0.5) > 0.02:
			_fail("S01 restaurant roof rotation does not face the road gable")
	if restaurant.get_node_or_null("RestaurantFrontGableEnd") == null:
		_fail("S01 restaurant front gable end is missing")
	if restaurant.get_node_or_null("RestaurantRearGableEnd") == null:
		_fail("S01 restaurant rear gable end is missing")
	if int(restaurant.get_meta("saisies_s01_balcony_uprights", 0)) < 9:
		_fail("S01 restaurant balcony needs broad vertical timber uprights")
	if restaurant.get_node_or_null("RestaurantDoorInterior") == null or restaurant.get_node_or_null("RestaurantDoorGlass") == null:
		_fail("S01 restaurant entrance lacks a recessed interior layer")
	var storefront_pane_count := 0
	for pane_index in range(6):
		var pane := restaurant.get_node_or_null("RestaurantStorePane_%02d" % pane_index) as MeshInstance3D
		var pane_box := pane.mesh as BoxMesh if pane != null else null
		if pane_box == null:
			_fail("S01 restaurant storefront pane is missing: %02d" % pane_index)
			continue
		var pane_material := pane.material_override as StandardMaterial3D
		if pane_box.size.x < 0.02 or pane_box.size.x > 0.12:
			_fail("S01 restaurant storefront pane is not thin: %02d thickness=%.3f" % [pane_index, pane_box.size.x])
		if pane_material == null or pane_material.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA:
			_fail("S01 restaurant storefront pane is not alpha-transparent: %02d" % pane_index)
		elif pane_material.albedo_color.a <= 0.10 or pane_material.albedo_color.a >= 0.70 or pane_material.roughness > 0.35:
			_fail("S01 restaurant storefront pane alpha/roughness is unsuitable: %02d alpha=%.2f roughness=%.2f" % [pane_index, pane_material.albedo_color.a, pane_material.roughness])
		var interior := restaurant.get_node_or_null("RestaurantStoreInterior_%02d" % pane_index) as MeshInstance3D
		var interior_box := interior.mesh as BoxMesh if interior != null else null
		if interior_box == null:
			_fail("S01 restaurant storefront dark interior is missing: %02d" % pane_index)
		elif interior.position.x >= pane.position.x:
			_fail("S01 restaurant storefront interior is not behind pane: %02d" % pane_index)
		elif interior_box.size.x < pane_box.size.x * 3.0:
			_fail("S01 restaurant storefront interior lacks depth behind pane: %02d" % pane_index)
		else:
			var interior_material := interior.material_override as StandardMaterial3D
			if interior_material == null or interior_material.albedo_color.r + interior_material.albedo_color.g + interior_material.albedo_color.b > 0.45:
				_fail("S01 restaurant storefront interior is not a dark backing: %02d" % pane_index)
		storefront_pane_count += 1
	var door_glass := restaurant.get_node_or_null("RestaurantDoorGlass") as MeshInstance3D
	var door_glass_box := door_glass.mesh as BoxMesh if door_glass != null else null
	var door_glass_material := door_glass.material_override as StandardMaterial3D if door_glass != null else null
	if door_glass_box == null or door_glass_box.size.x > 0.12 or door_glass_material == null or door_glass_material.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA:
		_fail("S01 restaurant door glass is not a thin transparent pane")
	for rack_name in ["RestaurantClothingDisplay_00", "RestaurantClothingDisplay_01"]:
		var rack := restaurant.get_node_or_null(rack_name) as Node3D
		if rack == null or rack.get_node_or_null("DisplayPost") == null or rack.get_node_or_null("DisplayRail") == null:
			_fail("S01 restaurant clothing display rack is incomplete: %s" % rack_name)
		else:
			var garment_count := 0
			for child in rack.get_children():
				if String(child.name).begins_with("DisplayGarment_") and child is MeshInstance3D:
					garment_count += 1
			if garment_count < 3:
				_fail("S01 restaurant clothing rack has too few display items: %s" % rack_name)
	var interior_display_count := 0
	for display_index in range(4):
		var display := restaurant.get_node_or_null("RestaurantInteriorDisplay_%02d" % display_index) as Node3D
		if display == null or display.get_node_or_null("InteriorDisplayPost") == null or display.get_node_or_null("InteriorDisplayRail") == null or display.get_node_or_null("InteriorDisplayPoster") == null:
			_fail("S01 restaurant interior display is incomplete: %02d" % display_index)
			continue
		var reference_pane := restaurant.get_node_or_null("RestaurantStorePane_%02d" % display_index) as MeshInstance3D
		if reference_pane == null or display.position.x >= reference_pane.position.x:
			_fail("S01 restaurant interior display is in front of pane: %02d" % display_index)
		var garment_count := 0
		for child in display.get_children():
			if String(child.name).begins_with("InteriorDisplayGarment_") and child is MeshInstance3D:
				garment_count += 1
		if garment_count < 3:
			_fail("S01 restaurant interior display has too few garments: %02d" % display_index)
		interior_display_count += 1
	var frontage_pad := village.get_node_or_null("S01S03Buildings/S01FrontagePaving_058") as MeshInstance3D
	if frontage_pad == null or frontage_pad.mesh == null:
		_fail("S01 restaurant frontage paving is missing")
	print("saisies S01 frontage: upper_bays=%d ground_bays=%d awning_supports=%d storefront_panes=%d interior_displays=%d" % [
		int(restaurant.get_meta("saisies_s01_upper_window_bays", 0)),
		int(restaurant.get_meta("saisies_s01_ground_window_bays", 0)),
		int(restaurant.get_meta("saisies_s01_awning_supports", 0)),
		storefront_pane_count,
		interior_display_count
	])

func _verify_s01_hotel_and_middle(route: Node3D, village: Node3D) -> void:
	var hotel := village.get_node_or_null("S01S03Buildings/Rear_Hotel") as Node3D
	if hotel == null:
		_fail("S01 rear hotel node is missing")
	else:
		var hotel_roof := hotel.get_node_or_null("HotelLowSlopeRoof") as Node3D
		if hotel_roof == null:
			_fail("S01 rear hotel low-slope roof node is missing")
		else:
			var hotel_slab := hotel_roof.get_child(0) as MeshInstance3D
			if hotel_slab == null or absf(rad_to_deg(absf(hotel_slab.rotation.z)) - 9.0) > 0.5:
				_fail("S01 rear hotel roof slab is not the authored 9 degree low slope")
		var roof_angle := float(hotel.get_meta("saisies_s01_hotel_roof_angle_deg", 99.0))
		if roof_angle > 12.0:
			_fail("S01 rear hotel roof is too steep: %.1f deg" % roof_angle)
		if int(hotel.get_meta("saisies_s01_hotel_balconies", 0)) < 3:
			_fail("S01 rear hotel needs stacked street balconies")
		if hotel.get_node_or_null("HotelBalconyDeck_00") == null or hotel.get_node_or_null("HotelBalconyDeck_03") == null:
			_fail("S01 rear hotel balcony deck geometry is incomplete")
		if absf(hotel.position.y - float(route.call("ground_y", 82.0, 10.0))) > 0.03:
			_fail("S01 rear hotel anchor is not grounded")
	var middle_count := int(village.get_meta("saisies_s01_middle_house_count", 0))
	if middle_count < 3:
		_fail("S01 middle village is too sparse: %d houses" % middle_count)
	for item in [
		{"name": "S01MiddleHouse_A", "s": 124.0, "u": -11.0},
		{"name": "S01MiddleHouse_B", "s": 141.0, "u": 10.2},
		{"name": "S01MiddleHouse_C", "s": 158.0, "u": -11.4}
	]:
		var spec: Dictionary = item
		var house := village.get_node_or_null("S01S03Buildings/%s" % String(spec["name"])) as Node3D
		if house == null:
			_fail("S01 middle house is missing: %s" % String(spec["name"]))
			continue
		var expected_y := float(route.call("ground_y", float(spec["s"]), float(spec["u"])))
		if absf(house.position.y - expected_y) > 0.03:
			_fail("S01 middle house is not grounded: %s" % String(spec["name"]))
	for pad_name in ["S01FrontagePaving_124", "S01FrontagePaving_141", "S01FrontagePaving_158"]:
		var pad := village.get_node_or_null("S01S03Buildings/%s" % pad_name) as MeshInstance3D
		if pad == null or pad.mesh == null:
			_fail("S01 middle frontage paving is missing: %s" % pad_name)
	for old_name in ["S01StreetPlanter_042", "S01StreetPlanter_076", "S01S03Prop_047", "S01S03Prop_112"]:
		if village.get_node_or_null("S01S03Buildings/%s" % old_name) != null or village.get_node_or_null("S01S03StreetDetails/%s" % old_name) != null:
			_fail("obsolete S01 planter remains: %s" % old_name)
	print("saisies S01 hotel/middle: balconies=%d middle_houses=%d" % [
		int(hotel.get_meta("saisies_s01_hotel_balconies", 0)) if hotel != null else 0,
		middle_count
	])

func _verify_s01_right_lodge(route: Node3D, village: Node3D) -> void:
	var lodge := village.get_node_or_null("S01S03Buildings/Right_Alpine_Lodge") as Node3D
	if lodge == null:
		_fail("S01 right alpine lodge is missing")
		return
	if not bool(lodge.get_meta("saisies_s01_right_lodge_roof_grid", false)):
		_fail("S01 right alpine lodge roof grid is missing")
	if int(lodge.get_meta("saisies_s01_right_lodge_roof_ribs", 0)) < 6:
		_fail("S01 right alpine lodge roof needs fine metal ribs")
	var first_rib := lodge.get_node_or_null("RightLodgeRoofRib_-1_00") as MeshInstance3D
	var last_rib := lodge.get_node_or_null("RightLodgeRoofRib_1_06") as MeshInstance3D
	if first_rib == null or last_rib == null or first_rib.mesh == null or last_rib.mesh == null:
		_fail("S01 right alpine lodge roof rib geometry is incomplete")
	if float(lodge.get_meta("saisies_s01_right_lodge_width_m", 99.0)) > 20.0:
		_fail("S01 right alpine lodge remains too broad")
	if absf(lodge.position.y - float(route.call("ground_y", 94.0, -19.0))) > 0.03:
		_fail("S01 right alpine lodge anchor is not grounded")

func _verify_s01_foundation_contacts(route: Node3D, village: Node3D) -> void:
	var buildings := village.get_node_or_null("S01S03Buildings") as Node3D
	if buildings == null:
		_fail("S01 buildings group is missing for footprint contact checks")
		return
	for item in [
		{"path": "Restaurant_Ravoula", "label": "S01 restaurant", "roof": "RestaurantGableRoof"},
		{"path": "Rear_Hotel", "label": "S01 rear hotel", "roof": "HotelLowSlopeRoof"},
		{"path": "Right_Alpine_Lodge", "label": "S01 right alpine lodge", "roof": ""},
		{"path": "S01MiddleHouse_A", "label": "S01 middle house A", "roof": ""},
		{"path": "S01MiddleHouse_B", "label": "S01 middle house B", "roof": ""},
		{"path": "S01MiddleHouse_C", "label": "S01 middle house C", "roof": ""}
	]:
		var spec: Dictionary = item
		var building := buildings.get_node_or_null(String(spec["path"])) as Node3D
		if building == null:
			_fail("%s is missing for transformed footprint contact checks" % String(spec["label"]))
			continue
		var foundation := building.get_child(0) as MeshInstance3D
		if foundation == null or not (foundation.mesh is BoxMesh):
			_fail("%s has no measurable BoxMesh foundation" % String(spec["label"]))
		else:
			_verify_foundation_footprint(foundation, route, String(spec["label"]))
		var roof_name := String(spec["roof"])
		if roof_name.is_empty():
			_verify_named_gable_roof(building, String(spec["label"]))
		else:
			_verify_sealed_roof(building.get_node_or_null(roof_name) as Node3D, String(spec["label"]))
			if String(spec["path"]) == "Restaurant_Ravoula":
				_verify_restaurant_gable_caps(building, String(spec["label"]))

func _verify_foundation_footprint(foundation: MeshInstance3D, route: Node3D, label: String) -> void:
	var foundation_box := foundation.mesh as BoxMesh
	var half_x := foundation_box.size.x * 0.5
	var half_z := foundation_box.size.z * 0.5
	var bottom_y := -foundation_box.size.y * 0.5
	var footprint := [
		Vector3(-half_x, bottom_y, -half_z),
		Vector3(half_x, bottom_y, -half_z),
		Vector3(half_x, bottom_y, half_z),
		Vector3(-half_x, bottom_y, half_z),
		Vector3(0.0, bottom_y, -half_z),
		Vector3(half_x, bottom_y, 0.0),
		Vector3(0.0, bottom_y, half_z),
		Vector3(-half_x, bottom_y, 0.0)
	]
	var min_burial_margin := INF
	var max_burial_margin := -INF
	for local_point in footprint:
		var world_point: Vector3 = foundation.global_transform * local_point
		var sample_s := float(route.call("distance_for_position", world_point))
		var route_point: Vector3 = route.call("pos_at", sample_s)
		var route_left: Vector3 = route.call("left_at", sample_s)
		var lateral := (world_point - route_point).dot(route_left)
		var terrain_y := float(route.call("ground_y", sample_s, lateral))
		var burial_margin := terrain_y - world_point.y
		min_burial_margin = minf(min_burial_margin, burial_margin)
		max_burial_margin = maxf(max_burial_margin, burial_margin)
	if min_burial_margin < 0.07:
		_fail("%s foundation footprint floats: margin %.3f..%.3f m" % [label, min_burial_margin, max_burial_margin])
	elif min_burial_margin > 0.35:
		_fail("%s foundation footprint is buried too deeply: %.3f..%.3f m" % [label, min_burial_margin, max_burial_margin])
	print("%s foundation contact: margin %.3f..%.3f m" % [label, min_burial_margin, max_burial_margin])

func _verify_sealed_roof(roof: Node3D, label: String) -> void:
	if roof == null:
		_fail("%s sealed roof node is missing" % label)
		return
	var mesh_count := 0
	for child in roof.get_children():
		if not child is MeshInstance3D:
			continue
		var mesh_instance := child as MeshInstance3D
		if mesh_instance.mesh == null or mesh_instance.mesh.get_surface_count() < 1:
			_fail("%s roof member %s has no closed mesh surface" % [label, child.name])
		else:
			mesh_count += 1
	if mesh_count < 3:
		_fail("%s sealed roof has only %d measurable members" % [label, mesh_count])
	if roof.name == "HotelLowSlopeRoof":
		for cap_name in ["SealedGableEndNeg", "SealedGableEndPos"]:
			var cap := roof.get_node_or_null(cap_name) as MeshInstance3D
			if cap == null or cap.mesh == null or cap.mesh.get_surface_count() < 1:
				_fail("%s sealed roof cap is missing: %s" % [label, cap_name])

func _verify_named_gable_roof(building: Node3D, label: String) -> void:
	var members := 0
	for roof_name in ["RoofSlopeNegX", "RoofSlopePosX", "RoofRidgeCap", "SealedGableEndNeg", "SealedGableEndPos"]:
		var roof_member := building.get_node_or_null(roof_name) as MeshInstance3D
		if roof_member == null or roof_member.mesh == null or roof_member.mesh.get_surface_count() < 1:
			_fail("%s sealed gable member is missing: %s" % [label, roof_name])
		else:
			members += 1
	if members < 5:
		_fail("%s sealed gable roof has only %d measurable members" % [label, members])

func _verify_restaurant_gable_caps(building: Node3D, label: String) -> void:
	for cap_name in ["RestaurantFrontGableEnd", "RestaurantRearGableEnd"]:
		var cap := building.get_node_or_null(cap_name) as Node3D
		var cap_mesh := cap.get_child(0) as MeshInstance3D if cap != null and cap.get_child_count() > 0 else null
		if cap_mesh == null or cap_mesh.mesh == null or cap_mesh.mesh.get_surface_count() < 1:
			_fail("%s sealed restaurant gable cap is missing: %s" % [label, cap_name])

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES VILLAGE VERIFY: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES VILLAGE VERIFY PASS")
		quit(0)
	else:
		print("SAISIES VILLAGE VERIFY FAIL (%d errors)" % _errors.size())
		quit(1)
