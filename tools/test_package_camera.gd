extends SceneTree
## The automatic camera must follow a bend's tangent instead of looking through its inside terrain.
const Viewer = preload("res://scripts/package_preview.gd")
const Reader = preload("res://scripts/route_data.gd")

func _initialize() -> void:
	call_deferred("_test")

func _fixture() -> String:
	var samples := {}
	for key in Reader.NUMERIC: samples[key] = []
	samples["s"] = []
	samples["surface_type"] = []
	for i in range(41):
		var s := float(i)
		samples.s.append(s)
		samples.x.append(12.0*sin(s/12.0))
		samples.z.append(-12.0*(1.0-cos(s/12.0)))
		samples.y.append(5.0+s*.025)
		samples.elevation_m.append(5.0+s*.025)
		samples.grade_percent.append(2.5)
		samples.heading_deg.append(fposmod(90.0-rad_to_deg(s/12.0),360.0))
		samples.curvature.append(1.0/12.0)
		samples.width_left_m.append(2.0)
		samples.width_right_m.append(2.0)
		samples.surface_type.append("concrete")
	var temp := OS.get_environment("TMPDIR")
	if temp.is_empty(): temp = "/tmp"
	var path := temp.path_join("ai_scene_camera_fixture_%d.json" % OS.get_process_id())
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify({"total_length_m":40.0,"samples":samples}))
	file.close()
	return path

func _test() -> void:
	var viewer := Viewer.new()
	assert(viewer._route_right(Vector3(0, 0, -1)).distance_to(Vector3(1, 0, 0)) < 0.0001)
	assert(viewer._route_right(Vector3(1, 0, 0)).distance_to(Vector3(0, 0, 1)) < 0.0001)
	viewer.add_child(viewer.tiles)
	viewer.add_child(viewer.label)
	var path := _fixture()
	viewer.route = Reader.load_file(path)
	DirAccess.remove_absolute(path)
	root.add_child(viewer.camera)
	var max_error := 0.0
	for s in [0.0, 5.0, 15.0, 25.0, 35.0, viewer.route.length]:
		viewer.progress = s
		viewer._pose()
		var location: Vector3 = viewer.route.position_at(s)
		assert(absf(viewer.camera.position.y - location.y - 1.65) < 0.001)
		var tangent: Vector3 = viewer.route.position_at(minf(s + 0.1, viewer.route.length)) - viewer.route.position_at(maxf(0, s - 0.1))
		tangent.y = 0
		var facing: Vector3 = -viewer.camera.basis.z
		facing.y = 0
		var error := rad_to_deg(tangent.normalized().angle_to(facing.normalized()))
		max_error = maxf(max_error,error)
		if error > 10.0:
			push_error("Automatic camera looks across the inside of a bend: %.2f degrees at s=%.1f" % [error,s])
			viewer.camera.free()
			viewer.free()
			quit(1)
			return
	# Capture-only overrides must be opt-in and must not leak into the next automatic view.
	viewer.progress = 15.0
	viewer._pose()
	var auto_position: Vector3 = viewer.camera.position
	var auto_forward: Vector3 = -viewer.camera.basis.z
	var auto_fov: float = viewer.camera.fov
	viewer._apply_capture_camera_override({"s": 15.0})
	assert(viewer.camera.position.distance_to(auto_position) < 0.0001)
	assert((-viewer.camera.basis.z).distance_to(auto_forward) < 0.0001)
	assert(is_equal_approx(viewer.camera.fov, auto_fov))
	viewer._apply_capture_camera_override({"camera_override": {
		"position_offset_route_m": [2.0, 0.5, 1.0],
		"pitch_down_deg": 8.0,
		"yaw_offset_deg": 3.0,
		"roll_offset_deg": 1.0,
		"vertical_fov_deg": 65.0
	}})
	assert(viewer.camera.position.distance_to(auto_position) > 0.5)
	assert((-viewer.camera.basis.z).distance_to(auto_forward) > 0.01)
	assert(is_equal_approx(viewer.camera.fov, 65.0))
	viewer._pose()
	assert(viewer.camera.position.distance_to(auto_position) < 0.0001)
	assert((-viewer.camera.basis.z).distance_to(auto_forward) < 0.0001)
	assert(is_equal_approx(viewer.camera.fov, 75.0))
	viewer.camera.free()
	viewer.free()
	print("PACKAGE_CAMERA_TEST_OK; max tangent error %.3f deg; eye height 1.65 m; capture override resets" % max_error)
	quit()
