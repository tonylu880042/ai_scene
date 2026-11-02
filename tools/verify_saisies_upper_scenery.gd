extends SceneTree

## Focused smoke test for the S04-S09 upper meadow/farm/wall corridor.
## The main scene is intentionally not edited here; this harness exercises the
## module against the real SaisiesRoute contract before integration.

var _errors: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var route_script := load("res://scripts/saisies_route.gd") as Script
	var scenery_script := load("res://scripts/saisies_upper_scenery.gd") as Script
	if route_script == null:
		_fail("saisies_route.gd could not be loaded")
	if scenery_script == null:
		_fail("saisies_upper_scenery.gd could not be loaded")
	if not _errors.is_empty():
		_finish()
		return
	var holder := Node3D.new()
	holder.name = "SaisiesUpperSceneryVerification"
	get_root().add_child(holder)
	var route := route_script.new() as Node3D
	route.name = "Route"
	# Match the integrated v2 scene so farm anchors and bank-side geometry are
	# verified against the same corrected time/elevation profile as Metal review.
	route.set("route_file", "res://data/saisies_route_v2.json")
	route.set("fallback_length_m", 14800.0)
	route.set("fallback_start_elevation_m", 1608.0)
	route.set("fallback_end_elevation_m", 689.0)
	route.set("fallback_road_width_m", 6.4)
	route.set("shoulder_width_m", 0.28)
	route.set("downhill_terrain_factor", 1.0)
	route.set("village_flatten_radius_m", 18.0)
	holder.add_child(route)
	var scenery := scenery_script.new() as Node3D
	scenery.name = "UpperScenery"
	scenery.set("route_path", NodePath("../Route"))
	holder.add_child(scenery)
	await process_frame
	await process_frame
	if not bool(route.call("route_ready")):
		_fail("route did not become ready")
	else:
		_verify_v2_route_settings(route)
	if not bool(scenery.get("upper_scenery_ready")):
		_fail("upper scenery did not become ready")
	else:
		_verify_contract(route, scenery)
	holder.queue_free()
	_finish()

func _verify_contract(route: Node3D, scenery: Node3D) -> void:
	var from_m := float(scenery.get_meta("saisies_upper_from_m", -1.0))
	var to_m := float(scenery.get_meta("saisies_upper_to_m", -1.0))
	if from_m > 1400.0 or to_m < 6400.0 or to_m <= from_m:
		_fail("upper corridor range %.0f..%.0f m is too small" % [from_m, to_m])
	var from_video := float(scenery.get_meta("saisies_upper_from_video_seconds", -1.0))
	var to_video := float(scenery.get_meta("saisies_upper_to_video_seconds", -1.0))
	if absf(from_video - 80.0) > 0.01 or absf(to_video - 395.0) > 0.01:
		_fail("upper corridor video range %.1f..%.1f s does not cover S04-S09" % [from_video, to_video])
	var farms := int(scenery.get_meta("saisies_upper_farmhouses", 0))
	var drives := int(scenery.get_meta("saisies_upper_driveways", 0))
	var poles := int(scenery.get_meta("saisies_upper_power_poles", 0))
	var tree_instances := int(scenery.get_meta("saisies_upper_tree_instances", 0))
	var s05_rail := int(scenery.get_meta("saisies_upper_s05_guardrail_beams", 0))
	var patches := int(scenery.get_meta("saisies_upper_meadow_patch_quads", 0))
	if farms < 6:
		_fail("upper scenery has too few authored farm buildings: %d" % farms)
	if drives < farms:
		_fail("farm driveways %d do not cover %d farms" % [drives, farms])
	_verify_s06_s07_farm_fronts(route, scenery)
	if poles < 3:
		_fail("upper corridor has too few power poles: %d" % poles)
	if tree_instances < 360:
		_fail("S08/S09 tree groups are too sparse: %d instances" % tree_instances)
	var forward_offsets: Array = scenery.get_meta("saisies_upper_farm_forward_offsets_m", [])
	var forward_by_id := {}
	for item in forward_offsets:
		if item is Dictionary:
			forward_by_id[String(item.get("id", ""))] = float(item.get("forward_m", 0.0))
	_check_forward_offset(forward_by_id, "S04_low_shed", 40.0, 60.0)
	_check_forward_offset(forward_by_id, "S06_main_chalet", 20.0, 35.0)
	_check_forward_offset(forward_by_id, "S06_low_barn", 30.0, 40.0)
	_check_forward_offset(forward_by_id, "S07_upper_house", 30.0, 60.0)
	_check_forward_offset(forward_by_id, "S07_low_longhouse", 20.0, 50.0)
	if s05_rail < 80:
		_fail("S05 right guardrail is too short: %d beams" % s05_rail)
	if float(scenery.get_meta("saisies_upper_s05_guardrail_side", 0.0)) != -1.0:
		_fail("S05 guardrail is not on the right side")
	var s08_parapet := int(scenery.get_meta("saisies_upper_s08_parapet_segments", 0))
	var s09_wall := int(scenery.get_meta("saisies_upper_s09_stonewall_segments", 0))
	var s09_rail := int(scenery.get_meta("saisies_upper_s09_guardrail_beams", 0))
	if s08_parapet < 20:
		_fail("S08 right parapet is too short: %d segments" % s08_parapet)
	if s09_wall < 40 or s09_rail < 40:
		_fail("S09 wall/rail corridor is too short: %d / %d" % [s09_wall, s09_rail])
	if float(scenery.get_meta("saisies_upper_s08_parapet_side", 0.0)) != -1.0:
		_fail("S08 parapet is not on the right side")
	if float(scenery.get_meta("saisies_upper_s09_initial_wall_side", 0.0)) != 1.0:
		_fail("S09 initial stone wall is not on the left side")
	if float(scenery.get_meta("saisies_upper_s09_initial_rail_side", 0.0)) != -1.0:
		_fail("S09 initial rail is not on the right side")
	if float(scenery.get_meta("saisies_upper_s09_switched_wall_side", 0.0)) != -1.0:
		_fail("S09 switched stone wall is not on the right side")
	if float(scenery.get_meta("saisies_upper_s09_switched_rail_side", 0.0)) != 1.0:
		_fail("S09 switched rail is not on the left side")
	var alignment := float(scenery.get_meta("saisies_upper_guardrail_min_alignment", 0.0))
	var upright := float(scenery.get_meta("saisies_upper_guardrail_post_upright", 0.0))
	if alignment < 0.999:
		_fail("upper guardrail beams have direction dot %.5f" % alignment)
	if upright < 0.999:
		_fail("upper guardrail posts have upright dot %.5f" % upright)
	var route_length := float(route.get("length_m"))
	for s in [1500.0, 2880.0, 4150.0, 4400.0, 5150.0, 5500.0, 6400.0]:
		if s > route_length:
			_fail("anchor %.0f m exceeds route length" % s)
	print("saisies upper scenery: farms=%d drives=%d poles=%d trees=%d S05_rail=%d meadow_quads=%d S08_parapet=%d S09_wall=%d S09_rail=%d alignment=%.5f upright=%.5f" % [farms, drives, poles, tree_instances, s05_rail, patches, s08_parapet, s09_wall, s09_rail, alignment, upright])

func _verify_v2_route_settings(route: Node3D) -> void:
	if String(route.get("route_file")) != "res://data/saisies_route_v2.json":
		_fail("upper verification is not using saisies_route_v2.json")
	if absf(float(route.get("shoulder_width_m")) - 0.28) > 0.001:
		_fail("v2 shoulder width is not 0.28m")
	if absf(float(route.get("downhill_terrain_factor")) - 1.0) > 0.001:
		_fail("v2 downhill terrain factor is not 1.0")

func _verify_s06_s07_farm_fronts(route: Node3D, scenery: Node3D) -> void:
	var farms := scenery.get_node_or_null("SaisiesUpperFarms") as Node3D
	if farms == null:
		_fail("upper farm group is missing")
		return
	var s06 := farms.get_node_or_null("SaisiesUpperFarm_S06_main_chalet") as Node3D
	if s06 == null:
		_fail("S06 main chalet is missing")
	else:
		# The main uphill chalet remains a 28 m forward anchor on the left;
		# the 35 m right/valley anchor belongs to S06_low_barn below.
		_verify_farm_geometry(s06, route, "S06_main_chalet", 225.0, 28.0, 20.0, false, "S06 chalet")
	var s06_low := farms.get_node_or_null("SaisiesUpperFarm_S06_low_barn") as Node3D
	if s06_low == null:
		_fail("S06 low barn is missing")
	else:
		_verify_farm_geometry(s06_low, route, "S06_low_barn", 225.0, 35.0, -42.0, true, "S06 low barn")
	var s07 := farms.get_node_or_null("SaisiesUpperFarm_S07_upper_house") as Node3D
	if s07 == null:
		_fail("S07 upper house is missing")
	else:
		_verify_farm_geometry(s07, route, "S07_upper_house", 270.0, 45.0, 30.0, false, "S07 upper house")
	var low := farms.get_node_or_null("SaisiesUpperFarm_S07_low_longhouse") as Node3D
	if low == null:
		_fail("S07 low longhouse is missing")
	else:
		_verify_farm_geometry(low, route, "S07_low_longhouse", 270.0, 35.0, -38.0, true, "S07 low longhouse")

func _verify_farm_geometry(node: Node3D, route: Node3D, anchor_id: String, capture_seconds: float, forward_m: float, expected_lateral: float, require_grey_roof: bool, label: String) -> void:
	var farms := node.get_parent()
	var offsets: Array = farms.get_parent().get_meta("saisies_upper_farm_forward_offsets_m", [])
	var found_anchor := false
	for item in offsets:
		if item is Dictionary and String(item.get("id", "")) == anchor_id:
			found_anchor = true
			if absf(float(item.get("video_seconds", -1.0)) - capture_seconds) > 0.01:
				_fail("%s is not anchored to %.1fs" % [label, capture_seconds])
			if absf(float(item.get("forward_m", -1.0)) - forward_m) > 0.01:
				_fail("%s forward anchor is %.1fm, expected %.1fm" % [label, float(item.get("forward_m", -1.0)), forward_m])
			break
	if not found_anchor:
		_fail("%s capture anchor record is missing" % label)
	var foundation := node.get_child(0) as MeshInstance3D
	if foundation == null or foundation.mesh == null or not (foundation.mesh is BoxMesh):
		_fail("%s has no measurable stone foundation" % label)
	else:
		_verify_foundation_footprint(foundation, route, label)
	var gable_count := 0
	for child in node.get_children():
		if child is MeshInstance3D and String(child.name).begins_with("SealedGableEnd"):
			gable_count += 1
			if child.mesh == null or child.mesh.get_surface_count() < 1:
				_fail("%s has an empty sealed gable mesh" % label)
	if gable_count != 2:
		_fail("%s has %d sealed gable ends, expected 2" % [label, gable_count])
	var object_s := float(route.call("distance_for_video_seconds", capture_seconds)) + forward_m
	var route_pos: Vector3 = route.call("pos_at", object_s)
	var left: Vector3 = route.call("left_at", object_s)
	var lateral := (node.position - route_pos).dot(left)
	# Farm specs use a local offset of roughly 20--42 m.  Keep a 1 m
	# numerical/terrain tolerance around the smallest 20 m anchor while still
	# rejecting a building that has slipped back into the road corridor.
	var side_threshold := 19.0
	if expected_lateral < 0.0 and lateral > -side_threshold:
		_fail("%s is not on the valley/right side: lateral %.1fm" % [label, lateral])
	if expected_lateral > 0.0 and lateral < side_threshold:
		_fail("%s is not on the uphill/left side: lateral %.1fm" % [label, lateral])
	if expected_lateral < 0.0:
		var road_y := float(route.call("ground_y", object_s, 0.0))
		if node.position.y >= road_y - 0.15:
			_fail("%s is not below the road grade: object_y=%.2f road_y=%.2f" % [label, node.position.y, road_y])
	if require_grey_roof and String(node.get_meta("saisies_farm_roof_style", "")) != "grey":
		_fail("%s does not use the authored grey roof" % label)
	_verify_chimney_roof_contact(node, label)

func _verify_chimney_roof_contact(node: Node3D, label: String) -> void:
	var chimney: MeshInstance3D
	var roof_slope: MeshInstance3D
	for child in node.get_children():
		if not child is MeshInstance3D:
			continue
		if child.name == "FarmChimney":
			chimney = child as MeshInstance3D
	if chimney == null:
		_fail("%s has no named farm chimney" % label)
		return
	var chimney_mesh := chimney.mesh as CylinderMesh
	if chimney_mesh == null:
		_fail("%s chimney is not a CylinderMesh" % label)
		return
	var chimney_bottom_world: Vector3 = chimney.global_transform * Vector3(0.0, -chimney_mesh.height * 0.5, 0.0)
	var chimney_bottom_local: Vector3 = node.global_transform.affine_inverse() * chimney_bottom_world
	var expected_roof_name := "RoofSlopePosX" if chimney_bottom_local.x >= 0.0 else "RoofSlopeNegX"
	roof_slope = node.get_node_or_null(expected_roof_name) as MeshInstance3D
	if roof_slope == null or not (roof_slope.mesh is BoxMesh):
		_fail("%s has no measurable %s roof slab" % [label, expected_roof_name])
		return
	var roof_box := roof_slope.mesh as BoxMesh
	var half_len := roof_box.size.x * 0.5
	var slab_half_thickness := roof_box.size.y * 0.5
	var slab_a: Vector3 = roof_slope.transform * Vector3(-half_len, slab_half_thickness, 0.0)
	var slab_b: Vector3 = roof_slope.transform * Vector3(half_len, slab_half_thickness, 0.0)
	var x_span := slab_b.x - slab_a.x
	if absf(x_span) < 0.001:
		_fail("%s %s roof slab has no measurable x span" % [label, expected_roof_name])
		return
	var roof_surface_y := slab_a.y + (chimney_bottom_local.x - slab_a.x) * (slab_b.y - slab_a.y) / x_span
	var burial := roof_surface_y - chimney_bottom_local.y
	if burial < 0.07 or burial > 0.13:
		_fail("%s chimney bottom is %.3fm below local roof surface, expected ~0.10m" % [label, burial])
	print("%s chimney roof burial: %.3f m" % [label, burial])

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
		_fail("%s foundation footprint is floating: burial margin %.3f..%.3f m" % [label, min_burial_margin, max_burial_margin])
	elif min_burial_margin > 0.35:
		_fail("%s foundation footprint is buried too deeply: %.3f..%.3f m" % [label, min_burial_margin, max_burial_margin])
	print("%s foundation footprint burial: %.3f..%.3f m" % [label, min_burial_margin, max_burial_margin])

func _check_forward_offset(offsets: Dictionary, id: String, minimum: float, maximum: float) -> void:
	if not offsets.has(id):
		_fail("missing authored forward offset for %s" % id)
		return
	var value := float(offsets[id])
	if value < minimum or value > maximum:
		_fail("%s forward offset %.1f m is outside %.1f..%.1f m" % [id, value, minimum, maximum])

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES UPPER VERIFY: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES UPPER VERIFY PASS")
		quit(0)
	else:
		print("SAISIES UPPER VERIFY FAIL (%d errors)" % _errors.size())
		quit(1)
