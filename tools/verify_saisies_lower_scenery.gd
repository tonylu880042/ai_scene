extends SceneTree

## Focused runtime contract check for SaisiesLowerScenery.
## It builds the route and lower module without opening a window, then checks
## the authored range, foliage count, and landmark node names.

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var root := Node3D.new()
	root.name = "LowerSceneryVerifyRoot"
	root.set_script(null)
	root.add_to_group("verify")
	get_root().add_child(root)

	var route := SaisiesRoute.new()
	route.name = "Route"
	route.route_file = "res://data/saisies_route.json"
	root.add_child(route)
	await process_frame
	print("ROUTE_READY=%s length=%.1f" % [route.route_ready(), route.length_m])
	if not route.route_ready():
		push_error("route did not become ready")
		quit(2)
		return

	var lower := SaisiesLowerScenery.new()
	lower.route_path = NodePath("../Route")
	lower.build_foliage = true
	lower.build_roadside_detail = true
	root.add_child(lower)
	for _i in range(6):
		await process_frame
	print("LOWER_STATE ready=%s route=%s children=%d" % [lower.scenery_ready, lower.route != null, lower.get_child_count()])

	var tree_count := int(lower.get_meta("saisies_lower_tree_instance_count", 0))
	var child_count := lower.get_child_count()
	var start_m := float(lower.get_meta("saisies_lower_start_m", -1.0))
	var end_m := float(lower.get_meta("saisies_lower_end_m", -1.0))
	var s13 := float(lower.call("_s_at_time", 630.0))
	var clearance_ok := bool(lower.call("landmark_clearance_ok"))
	var visibility_ok := bool(lower.call("landmark_camera_visibility_ok"))
	var visibility_report = lower.call("_landmark_camera_visibility_report")
	print("LANDMARK_CLEARANCE_OK=%s" % clearance_ok)
	print("LANDMARK_CAMERA_VISIBILITY_OK=%s" % visibility_ok)
	for item in visibility_report:
		print("LANDMARK_CAMERA label=%s scene=%s depth=%.2f yaw=%.2f pitch=%.2f ok=%s" % [item["label"], item["scene"], item["depth"], item["yaw_deg"], item["pitch_deg"], item["ok"]])
	print("ROCK_FACE_AABB face01=%s face02=%s" % [lower._rock_face_01.get_aabb() if lower._rock_face_01 else "null", lower._rock_face_02.get_aabb() if lower._rock_face_02 else "null"])
	if not bool(lower.get_meta("saisies_lower_scenery_ready", false)):
		push_error("lower scenery did not become ready")
		quit(3)
		return
	if tree_count < 1000:
		push_error("expected dense lower forest, got %d tree instances" % tree_count)
		quit(4)
		return
	if end_m <= start_m or start_m < 6000.0 or end_m < 14000.0:
		push_error("lower route range is invalid: %.1f..%.1f" % [start_m, end_m])
		quit(5)
		return
	if absf(s13 - 10470.0) > 3.0:
		push_error("checkpoint mapping put S13 at %.1f m, expected 10470 m" % s13)
		quit(7)
		return
	if child_count < 30:
		push_error("expected authored scenery children, got %d" % child_count)
		quit(6)
		return
	if not clearance_ok:
		push_error("one or more S16-S18 landmarks intersect the road envelope")
		quit(8)
		return
	if not visibility_ok:
		push_error("one or more S17-S18 landmarks are outside the acceptance camera frustum")
		quit(9)
		return
	var continuous_wall_count := 0
	var rock_material: Material = lower._materials.get("rock")
	for child in lower.get_children():
		var wall := child as MeshInstance3D
		if wall != null and wall.mesh != null and wall.mesh.get_surface_count() > 0 and wall.mesh.surface_get_material(0) == rock_material:
			continuous_wall_count += 1
	if continuous_wall_count < 5:
		push_error("continuous lower rock wall set is incomplete: %d" % continuous_wall_count)
		quit(10)
		return
	print("LOWER_CONTINUOUS_ROCK_WALLS count=%d" % continuous_wall_count)

	print("LOWER_SCENERY_OK trees=%d children=%d range=%.1f..%.1f" % [tree_count, child_count, start_m, end_m])
	quit(0)
