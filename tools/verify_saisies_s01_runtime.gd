extends SceneTree

## Bounded S01 runtime QA for the frozen review scene.
##
## Default mode is --check-only so parsing is safe while the review scene is
## being assembled.  --headless-contract loads the scene and checks the fixed
## C pose plus deterministic controller deltas.  --native performs the GPU
## MultiMesh readback and two real 3D side-view captures; it refuses Dummy or
## headless renderers.  No mode claims visual acceptance.
##
## Examples:
##   godot --path <frozen-project> --script res://tools/verify_saisies_s01_runtime.gd -- \
##     --check-only --output-dir=res://export/saisies/review/round15_s01/runtime_qa
##   godot --path <frozen-project> --script res://tools/verify_saisies_s01_runtime.gd -- \
##     --headless-contract --output-dir=res://export/saisies/review/round15_s01/runtime_qa
##   godot --path <frozen-project> --script res://tools/verify_saisies_s01_runtime.gd -- \
##     --native --output-dir=res://export/saisies/review/round15_s01/runtime_qa

const REVIEW_SCENE_PATH := "res://scenes/MainScene_saisies_s01_review.tscn"
const CONFIG_PATH := "res://data/saisies_s01_camera_calibration.json"
const CONTROLLER_SCRIPT_PATH := "res://scripts/saisies_s01_camera_controller.gd"
const LANDSCAPE_SCRIPT_PATH := "res://scripts/saisies_s01_landscape.gd"
const DEFAULT_OUTPUT_DIR := "res://export/saisies/review/round15_s01/runtime_qa"
const SELECTED_ID := "combined_C_yaw24_pitch14_roll0_lateral22"
const SELECTED_STATUS := "root_selected_for_integrated_review"
const ORIGINAL_FOREST_TREE_COUNT := 6487
const CAPTURE_SIZE := Vector2i(1920, 1080)
const FIXED_STATION_M := 50.0
const TOUR_MAX_STATION_M := 220.0
const TOUR_SPEED_MPS := 30.0 / 3.6
const TOUR_SAMPLE_DELTAS := [1.2, 24.0, 2.0]
const SIDE_VIEWS := [
	{"id": "side_right_from_C", "station_m": 50.0, "lateral_m": -4.7},
	{"id": "side_left_from_C", "station_m": 50.0, "lateral_m": 0.3},
]

var _mode := "check-only"
var _output_dir := DEFAULT_OUTPUT_DIR
var _errors: Array[String] = []
var _warnings: Array[String] = []
var _checks: Dictionary = {}
var _config: Dictionary = {}
var _selected: Dictionary = {}
var _scene_instance: Node3D

func _initialize() -> void:
	_parse_arguments()
	call_deferred("_run")

func _parse_arguments() -> void:
	for raw_arg in OS.get_cmdline_user_args():
		var arg := String(raw_arg)
		if arg == "--check-only":
			_mode = "check-only"
		elif arg == "--headless-contract":
			_mode = "headless-contract"
		elif arg == "--native":
			_mode = "native"
		elif arg.begins_with("--output-dir="):
			_output_dir = arg.substr(13)

func _run() -> void:
	if _mode == "check-only":
		_run_check_only()
		return
	if _mode == "native" and _unsafe_renderer():
		_warnings.append("native GPU checks were not run on renderer %s" % DisplayServer.get_name())
		_checks["native_gpu_status"] = "not_run_unsafe_renderer"
		_write_report()
		print("SAISIES S01 RUNTIME QA HOLD: native mode requires a windowed GPU renderer")
		quit(1)
		return
	if not _load_contract_inputs():
		_write_report()
		_finish()
		return
	if _mode == "headless-contract":
		await _run_headless_contract()
	else:
		await _run_native()
	_write_report()
	_finish()

func _run_check_only() -> void:
	var scripts_ok := true
	for script_path in [CONTROLLER_SCRIPT_PATH, LANDSCAPE_SCRIPT_PATH]:
		var script := load(script_path) as Script
		if script == null:
			_fail("script could not be parsed: %s" % script_path)
			scripts_ok = false
	_checks["scripts_parse"] = scripts_ok
	if not _load_config_only():
		_write_report()
		_finish()
		return
	var packed := load(REVIEW_SCENE_PATH) as PackedScene
	if packed == null:
		_fail("review scene could not be loaded: %s" % REVIEW_SCENE_PATH)
	else:
		_checks["review_scene_load"] = true
		var instance := packed.instantiate() as Node3D
		if instance == null:
			_fail("review scene instantiate returned null")
		else:
			var controller := instance.find_child("S01CameraController", true, false) as Node
			_checks["controller_node_declared"] = controller != null
			if controller == null:
				_fail("review scene has no S01CameraController node")
			else:
				var script := controller.get_script() as Script
				if script == null or script.resource_path != CONTROLLER_SCRIPT_PATH:
					_fail("review scene controller script does not resolve to %s" % CONTROLLER_SCRIPT_PATH)
			instance.queue_free()
	_write_report()
	if _errors.is_empty():
		print("SAISIES S01 RUNTIME QA PARSE READY")
	else:
		print("SAISIES S01 RUNTIME QA PARSE HOLD: %s" % "; ".join(_errors))
	_finish()

func _load_config_only() -> bool:
	if not FileAccess.file_exists(CONFIG_PATH):
		_fail("calibration config is missing: %s" % CONFIG_PATH)
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if not (parsed is Dictionary):
		_fail("calibration config is not a JSON object")
		return false
	_config = parsed
	var status := String(_config.get("selection_status", ""))
	var selected_id := String(_config.get("selected_candidate", ""))
	_checks["calibration_selection"] = {
		"id": selected_id,
		"status": status,
		"expected_id": SELECTED_ID,
		"expected_status": SELECTED_STATUS,
	}
	if selected_id != SELECTED_ID or status != SELECTED_STATUS:
		_fail("calibration selection is not root-selected C: id=%s status=%s" % [selected_id, status])
		return false
	for collection_value in [_config.get("candidates", []), _config.get("combined_candidates", [])]:
		if not (collection_value is Array):
			continue
		for item in collection_value:
			if item is Dictionary and String(item.get("id", "")) == SELECTED_ID:
				_selected = item.duplicate(true)
				return _verify_selected_values()
	_fail("selected C candidate is missing from calibration arrays")
	return false

func _verify_selected_values() -> bool:
	var expected := {
		"station_m": 50.0,
		"pitch_deg": -14.0,
		"yaw_deg": 24.0,
		"lateral_m": -2.2,
		"height_m": 1.65,
		"fov_deg": 79.0,
		"roll_deg": 0.0,
	}
	var values_ok := true
	for key in expected.keys():
		var actual := float(_selected.get(key, NAN))
		if not is_finite(actual) or absf(actual - float(expected[key])) > 0.001:
			_fail("selected C %s mismatch: expected=%s actual=%s" % [key, expected[key], actual])
			values_ok = false
	_checks["selected_candidate_values"] = _selected.duplicate(true)
	return values_ok

func _load_contract_inputs() -> bool:
	if not _load_config_only():
		return false
	if not FileAccess.file_exists(REVIEW_SCENE_PATH):
		_fail("review scene is missing: %s" % REVIEW_SCENE_PATH)
		return false
	return true

func _run_headless_contract() -> void:
	var packed := load(REVIEW_SCENE_PATH) as PackedScene
	if packed == null:
		_fail("review scene could not be loaded")
		return
	_scene_instance = packed.instantiate() as Node3D
	if _scene_instance == null:
		_fail("review scene instantiate returned null")
		return
	get_root().add_child(_scene_instance)
	await process_frame
	await process_frame
	var controller := _scene_instance.find_child("S01CameraController", true, false) as Node
	var world := _scene_instance.get_node_or_null("World") as Node3D
	var route := world.get_node_or_null("Route") if world != null else null
	var rig := world.get_node_or_null("CameraRig") as Node3D if world != null else null
	if controller == null or world == null or route == null or rig == null:
		_fail("review scene runtime nodes are incomplete")
		return
	for _frame in range(120):
		if bool(controller.get_meta("saisies_s01_camera_controller_ready", false)):
			break
		await process_frame
	if not bool(controller.get_meta("saisies_s01_camera_controller_ready", false)):
		_fail("S01 camera controller did not publish ready metadata")
	else:
		_verify_fixed_controller(controller, route, rig)
		await _verify_tour_process(controller, rig)
	_verify_forest_counts(world)
	await _verify_s01_tree_count(_scene_instance)
	_checks["native_gpu_status"] = "not_run_headless_contract"
	_scene_instance.queue_free()

func _verify_fixed_controller(controller: Node, route: Node, rig: Node3D) -> void:
	var camera := rig.get_node_or_null("Camera3D") as Camera3D
	var fixed := {
		"candidate_id": String(controller.get_meta("saisies_s01_camera_selected_candidate", "")),
		"status": String(controller.get_meta("saisies_s01_camera_selected_status", "")),
		"mode": String(controller.get_meta("saisies_s01_camera_mode", "")),
		"station_m": float(rig.get("distance_m")),
		"auto_advance": bool(rig.get("auto_advance")),
		"controller_process_active": controller.is_processing(),
	}
	_checks["fixed_controller"] = fixed
	if fixed["candidate_id"] != SELECTED_ID or fixed["status"] != SELECTED_STATUS:
		_fail("fixed controller candidate/status mismatch")
	if fixed["mode"] != "fixed" or absf(float(fixed["station_m"]) - FIXED_STATION_M) > 0.01:
		_fail("fixed controller is not stopped at station 50")
	if bool(fixed["auto_advance"]):
		_fail("fixed controller left CameraRig auto_advance enabled")
	if not bool(fixed["controller_process_active"]):
		_fail("fixed controller Node _process is disabled")
	if camera == null:
		_fail("CameraRig/Camera3D is missing")
		return
	var tangent: Vector3 = route.call("tangent_at", FIXED_STATION_M)
	var heading := atan2(-tangent.x, -tangent.z)
	var pose := {
		"pitch_deg": rad_to_deg(float(rig.rotation.x)),
		"yaw_offset_deg": rad_to_deg(wrapf(rig.rotation.y - heading + PI, 0.0, TAU) - PI),
		"roll_deg": rad_to_deg(float(rig.rotation.z)),
		"lateral_m": float(rig.get_meta("saisies_s01_camera_lateral_m", NAN)),
		"fov_deg": float(camera.fov),
	}
	_checks["fixed_pose"] = pose
	for key in ["pitch_deg", "yaw_offset_deg", "roll_deg", "lateral_m", "fov_deg"]:
		var actual := float(pose[key])
		var expected := float(_selected.get(key if key != "yaw_offset_deg" else "yaw_deg", NAN))
		if not is_finite(actual) or not is_finite(expected) or absf(actual - expected) > 0.02:
			_fail("fixed C pose mismatch for %s: expected=%.3f actual=%.3f" % [key, expected, actual])
	if controller.get_meta("saisies_s01_camera_scope", "") != "0..220m":
		_fail("controller scope is not bounded to 0..220m")

func _verify_tour_process(controller: Node, rig: Node3D) -> void:
	# Invoke the actual Node _process(delta) method with exact deltas while
	# temporarily pausing engine scheduling. This avoids wall-clock drift while
	# still exercising the shipped runtime method, not a duplicate formula.
	var was_processing := controller.is_processing()
	controller.set_process(false)
	controller.set("_tour_active", true)
	controller.set("_tour_finished", false)
	controller.set("_tour_station_m", 0.0)
	rig.set("auto_advance", false)
	var samples: Array[Dictionary] = []
	for delta in TOUR_SAMPLE_DELTAS:
		var before := float(controller.get("_tour_station_m"))
		controller.call("_process", float(delta))
		await process_frame
		var after := float(controller.get("_tour_station_m"))
		samples.append({"delta_s": float(delta), "before_m": before, "after_m": after})
	if was_processing:
		controller.set_process(true)
	var expected_after_first := TOUR_SAMPLE_DELTAS[0] * TOUR_SPEED_MPS
	var expected_after_second := (TOUR_SAMPLE_DELTAS[0] + TOUR_SAMPLE_DELTAS[1]) * TOUR_SPEED_MPS
	if absf(float(samples[0]["after_m"]) - expected_after_first) > 0.02:
		_fail("tour first exact-delta advance mismatch")
	if absf(float(samples[1]["after_m"]) - expected_after_second) > 0.02:
		_fail("tour continuous exact-delta advance mismatch")
	if float(samples[2]["after_m"]) > TOUR_MAX_STATION_M + 0.001:
		_fail("tour exceeded S01 220m cutoff")
	if not bool(controller.get_meta("saisies_s01_camera_tour_finished", false)):
		_fail("tour did not publish bounded completion")
	if bool(rig.get("auto_advance")):
		_fail("tour re-enabled CameraRig beyond S01 cutoff")
	_checks["tour_process"] = {
		"speed_kmh": 30.0,
		"speed_mps": TOUR_SPEED_MPS,
		"samples": samples,
		"cutoff_station_m": float(controller.get("_tour_station_m")),
		"finished": bool(controller.get_meta("saisies_s01_camera_tour_finished", false)),
		"controller_process_restored": controller.is_processing(),
		"s02_entered": false,
	}

func _verify_forest_counts(world: Node3D) -> void:
	var forest := world.find_child("Forest", true, false) as Node
	if forest == null:
		_fail("World/Forest is missing")
		return
	var total := 0
	var multimesh_nodes := 0
	for descendant in forest.find_children("*", "MultiMeshInstance3D", true, false):
		var instance := descendant as MultiMeshInstance3D
		if instance == null or instance.multimesh == null:
			continue
		multimesh_nodes += 1
		total += instance.multimesh.instance_count
	_checks["forest_counts"] = {
		"original_r14_expected_tree_count": ORIGINAL_FOREST_TREE_COUNT,
		"r14_forest_tree_count": total,
		"forest_multimesh_nodes": multimesh_nodes,
	}
	if total != ORIGINAL_FOREST_TREE_COUNT:
		_fail("R14 forest tree count changed: expected=%d actual=%d" % [ORIGINAL_FOREST_TREE_COUNT, total])

func _verify_s01_tree_count(scene: Node3D) -> void:
	var landscape := scene.find_child("S01Landscape", true, false) as Node
	if landscape == null:
		_fail("S01Landscape node is missing")
		return
	for _frame in range(240):
		if bool(landscape.get_meta("saisies_s01_landscape_ready", false)):
			break
		await process_frame
	var tree_count := int(landscape.get_meta("saisies_s01_tree_instance_count", -1))
	var multimesh_count := int(landscape.get_meta("saisies_s01_tree_multimesh_node_count", -1))
	_checks["s01_tree_counts"] = {
		"tree_instance_count": tree_count,
		"multimesh_node_count": multimesh_count,
		"ready": bool(landscape.get_meta("saisies_s01_landscape_ready", false)),
	}
	if not bool(landscape.get_meta("saisies_s01_landscape_ready", false)) or tree_count <= 0 or multimesh_count <= 0:
		_fail("S01 landscape tree count is missing or empty: trees=%d multimeshes=%d" % [tree_count, multimesh_count])

func _run_native() -> void:
	var packed := load(REVIEW_SCENE_PATH) as PackedScene
	if packed == null:
		_fail("review scene could not be loaded for native QA")
		return
	_scene_instance = packed.instantiate() as Node3D
	if _scene_instance == null:
		_fail("review scene instantiate returned null for native QA")
		return
	# Keep every review node in the scene for native QA.  In particular, the
	# architecture module chooses the lodge face from the live CameraRig during
	# its deferred build; detaching the controller before add_child would produce
	# a different rendered asset than the frozen review scene.
	get_root().add_child(_scene_instance)
	var window := get_root() as Window
	if window != null:
		window.size = CAPTURE_SIZE
		window.content_scale_size = CAPTURE_SIZE
	var controller := _scene_instance.find_child("S01CameraController", true, false) as Node
	var world := _scene_instance.get_node_or_null("World") as Node3D
	var route := world.get_node_or_null("Route") if world != null else null
	var rig := world.get_node_or_null("CameraRig") as Node3D if world != null else null
	if world == null or route == null or rig == null:
		_fail("native scene runtime nodes are incomplete")
		_scene_instance.queue_free()
		return
	if controller == null:
		_fail("native QA could not find S01CameraController")
		_scene_instance.queue_free()
		return
	if not await _await_native_scene_ready(controller, world):
		_scene_instance.queue_free()
		return
	_verify_fixed_controller(controller, route, rig)
	await _measure_native_tour(controller, rig)
	# Let the controller's already queued deferred pose application drain before
	# freezing the baked CameraRig.  The controller remains in the tree, so its
	# _exit_tree restoration path cannot run and alter the native scene.
	controller.set_process(false)
	await process_frame
	await process_frame
	rig.set_process(false)
	_checks["controller_disabled_for_native"] = not controller.is_processing()
	_checks["rig_disabled_for_side_views"] = not rig.is_processing()
	rig.set("auto_advance", false)
	var root_viewport := get_root() as Viewport
	var captures: Array[Dictionary] = []
	for view in SIDE_VIEWS:
		var row := await _capture_side_view(root_viewport, route, rig, view)
		captures.append(row)
	_checks["side_view_captures"] = captures
	_verify_side_view_separation(captures)
	RenderingServer.force_draw()
	_checks["multimesh_readback"] = _summarize_native_multimeshes(_scene_instance)
	_verify_forest_counts(world)
	await _verify_s01_tree_count(_scene_instance)
	_checks["native_gpu_status"] = "force_draw_direct_readback"
	_scene_instance.queue_free()

func _await_native_scene_ready(controller: Node, world: Node3D) -> bool:
	var architecture := _scene_instance.find_child("S01Architecture", true, false) as Node
	var landscape := _scene_instance.find_child("S01Landscape", true, false) as Node
	var lodge := world.get_node_or_null("VillageS01S02/S01S02Buildings/Right_Alpine_Lodge") as Node3D
	var ready := false
	for _frame in range(600):
		var controller_ready := bool(controller.get_meta("saisies_s01_camera_controller_ready", false))
		var architecture_ready := architecture != null and bool(architecture.get_meta("saisies_s01_architecture_ready", false))
		var landscape_ready := landscape != null and bool(landscape.get_meta("saisies_s01_landscape_ready", false))
		var lodge_detail_ready := lodge != null and not String(lodge.get_meta("saisies_s01_lodge_visible_face_detail", "")).is_empty()
		if controller_ready and architecture_ready and landscape_ready and lodge_detail_ready:
			ready = true
			break
		await process_frame
	var status := {
		"controller_ready": controller != null and bool(controller.get_meta("saisies_s01_camera_controller_ready", false)),
		"architecture_ready": architecture != null and bool(architecture.get_meta("saisies_s01_architecture_ready", false)),
		"landscape_ready": landscape != null and bool(landscape.get_meta("saisies_s01_landscape_ready", false)),
		"lodge_detail_ready": lodge != null and not String(lodge.get_meta("saisies_s01_lodge_visible_face_detail", "")).is_empty(),
		"lodge_detail": String(lodge.get_meta("saisies_s01_lodge_visible_face_detail", "")) if lodge != null else "",
		"frames_waited_max": 600,
		"ready": ready,
	}
	_checks["native_scene_readiness"] = status
	if not ready:
		_fail("native review scene did not reach controller/architecture/landscape/lodge-detail ready state: %s" % str(status))
	return ready

func _measure_native_tour(controller: Node, rig: Node3D) -> void:
	# Exercise the shipped Node _process(delta) using wall-clock frame deltas for
	# roughly two seconds.  The exact-delta cutoff contract remains covered by
	# --headless-contract; this short native run only proves the real process is
	# advancing at the selected 30 km/h rate on the live scene.
	controller.set("_tour_active", true)
	controller.set("_tour_finished", false)
	controller.set("_tour_station_m", 0.0)
	controller.set_meta("saisies_s01_camera_tour_finished", false)
	rig.set("auto_advance", false)
	controller.set_process(true)
	var start_usec := Time.get_ticks_usec()
	var elapsed_s := 0.0
	while elapsed_s < 2.0:
		await process_frame
		elapsed_s = float(Time.get_ticks_usec() - start_usec) / 1000000.0
	var station_m := float(controller.get("_tour_station_m"))
	var expected_m := elapsed_s * TOUR_SPEED_MPS
	var distance_error_m := absf(station_m - expected_m)
	var tolerance_m := maxf(1.25, expected_m * 0.12)
	var within_rate := station_m >= 0.0 and distance_error_m <= tolerance_m and station_m < TOUR_MAX_STATION_M
	_checks["native_tour_process"] = {
		"elapsed_s": elapsed_s,
		"speed_kmh": 30.0,
		"expected_distance_m": expected_m,
		"actual_distance_m": station_m,
		"distance_error_m": distance_error_m,
		"tolerance_m": tolerance_m,
		"within_rate": within_rate,
		"cutoff_not_reached": station_m < TOUR_MAX_STATION_M,
	}
	if not within_rate:
		_fail("native 30 km/h process distance is outside tolerance: %s" % str(_checks["native_tour_process"]))
func _capture_side_view(root_viewport: Viewport, route: Node, rig: Node3D, view: Dictionary) -> Dictionary:
	var station_m := float(view.get("station_m", FIXED_STATION_M))
	var lateral_m := float(view.get("lateral_m", -2.2))
	var camera := rig.get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		_fail("side view has no Camera3D")
		return {"id": String(view.get("id", "unnamed")), "ok": false}
	var tangent: Vector3 = route.call("tangent_at", station_m)
	var left: Vector3 = route.call("left_at", station_m)
	var point: Vector3 = route.call("pos_at", station_m)
	var ground_y := float(route.call("ground_y", station_m, lateral_m))
	var heading := atan2(-tangent.x, -tangent.z)
	rig.set("distance_m", station_m)
	rig.global_position = Vector3(point.x + left.x * lateral_m, ground_y + 0.02, point.z + left.z * lateral_m)
	rig.rotation = Vector3(deg_to_rad(-14.0), heading + deg_to_rad(24.0), 0.0)
	camera.position.y = 1.65
	camera.fov = 79.0
	camera.current = true
	for _frame in range(3):
		await process_frame
	RenderingServer.force_draw()
	var image := root_viewport.get_texture().get_image()
	var id := String(view.get("id", "unnamed"))
	var output_path := ProjectSettings.globalize_path(_output_dir.path_join(id + ".png"))
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var save_error := image.save_png(output_path) if image != null else ERR_CANT_CREATE
	if save_error != OK:
		_fail("side view %s PNG save failed: %s" % [id, output_path])
	var camera_position := camera.global_position
	var rig_position := rig.global_position
	var expected_camera_position := rig.to_global(camera.position)
	var expected_rotation := Vector3(deg_to_rad(-14.0), heading + deg_to_rad(24.0), 0.0)
	var rig_position_error_m := rig_position.distance_to(Vector3(point.x + left.x * lateral_m, ground_y + 0.02, point.z + left.z * lateral_m))
	var camera_position_error_m := camera_position.distance_to(expected_camera_position)
	var rotation_error_deg := _rotation_error_degrees(rig.rotation, expected_rotation)
	var fov_error_deg := absf(camera.fov - 79.0)
	var transform_match := rig_position_error_m <= 0.05 and camera_position_error_m <= 0.05 and rotation_error_deg <= 0.05 and fov_error_deg <= 0.05
	if not transform_match:
		_fail("side view %s actual 3D transform differs from requested pose: rig_error=%.4fm camera_error=%.4fm rotation_error=%.4fdeg fov_error=%.4fdeg" % [id, rig_position_error_m, camera_position_error_m, rotation_error_deg, fov_error_deg])
	return {
		"id": id,
		"ok": save_error == OK and image != null and transform_match,
		"image_ok": save_error == OK and image != null,
		"transform_match": transform_match,
		"station_m": station_m,
		"lateral_m": lateral_m,
		"expected_rig_world_position": _vec3_array(Vector3(point.x + left.x * lateral_m, ground_y + 0.02, point.z + left.z * lateral_m)),
		"rig_world_position": _vec3_array(rig_position),
		"rig_position_error_m": rig_position_error_m,
		"expected_camera_world_position": _vec3_array(expected_camera_position),
		"camera_world_position": _vec3_array(camera_position),
		"camera_world_rotation_deg": [rad_to_deg(camera.global_rotation.x), rad_to_deg(camera.global_rotation.y), rad_to_deg(camera.global_rotation.z)],
		"camera_rotation_deg": [rad_to_deg(rig.rotation.x), rad_to_deg(rig.rotation.y), rad_to_deg(rig.rotation.z)],
		"camera_position_error_m": camera_position_error_m,
		"rotation_error_deg": rotation_error_deg,
		"fov_deg": camera.fov,
		"fov_error_deg": fov_error_deg,
		"image": output_path,
		"draw_policy": "3 process_frame + RenderingServer.force_draw + direct Viewport readback",
	}

func _rotation_error_degrees(actual: Vector3, expected: Vector3) -> float:
	var error := Vector3(
		absf(rad_to_deg(wrapf(actual.x - expected.x + PI, 0.0, TAU) - PI)),
		absf(rad_to_deg(wrapf(actual.y - expected.y + PI, 0.0, TAU) - PI)),
		absf(rad_to_deg(wrapf(actual.z - expected.z + PI, 0.0, TAU) - PI))
	)
	return maxf(error.x, maxf(error.y, error.z))

func _verify_side_view_separation(captures: Array[Dictionary]) -> void:
	var expected := absf(float(SIDE_VIEWS[1].get("lateral_m", 0.0)) - float(SIDE_VIEWS[0].get("lateral_m", 0.0)))
	var check := {
		"expected_lateral_separation_m": expected,
		"tolerance_m": 0.15,
		"capture_count": captures.size(),
		"transform_matches": true,
		"rig_separation_m": NAN,
		"camera_separation_m": NAN,
		"pass": false,
	}
	if captures.size() == 2:
		check["transform_matches"] = bool(captures[0].get("transform_match", false)) and bool(captures[1].get("transform_match", false))
		var first_rig := _array_vec3(captures[0].get("rig_world_position", []))
		var second_rig := _array_vec3(captures[1].get("rig_world_position", []))
		var first_camera := _array_vec3(captures[0].get("camera_world_position", []))
		var second_camera := _array_vec3(captures[1].get("camera_world_position", []))
		check["rig_separation_m"] = first_rig.distance_to(second_rig)
		check["camera_separation_m"] = first_camera.distance_to(second_camera)
		check["pass"] = bool(check["transform_matches"]) \
			and absf(float(check["rig_separation_m"]) - expected) <= 0.15 \
			and absf(float(check["camera_separation_m"]) - expected) <= 0.15
	_checks["side_view_3d_separation"] = check
	if not bool(check["pass"]):
		_fail("side view 3D separation/transform check failed: %s" % str(check))

func _array_vec3(value: Variant) -> Vector3:
	if not (value is Array) or value.size() < 3:
		return Vector3(NAN, NAN, NAN)
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

func _summarize_native_multimeshes(scene: Node) -> Dictionary:
	var node_count := 0
	var instance_count := 0
	var finite_count := 0
	var nonzero_count := 0
	var zero_count := 0
	var error_count := 0
	var zeroish_samples: Array[Dictionary] = []
	for descendant in scene.find_children("*", "MultiMeshInstance3D", true, false):
		var instance := descendant as MultiMeshInstance3D
		if instance == null or instance.multimesh == null:
			continue
		node_count += 1
		var multimesh := instance.multimesh
		instance_count += multimesh.instance_count
		for index in multimesh.instance_count:
			var transform := multimesh.get_instance_transform(index)
			if not _transform_finite(transform):
				error_count += 1
				continue
			finite_count += 1
			if _transform_zeroish(transform):
				zero_count += 1
				if zeroish_samples.size() < 16:
					zeroish_samples.append({
						"node": str(instance.get_path()),
						"index": index,
						"reason": "near-identity transform is not accepted for this review scene; no legal identity exception configured",
						"origin": _vec3_array(transform.origin),
						"basis_x": _vec3_array(transform.basis.x),
						"basis_y": _vec3_array(transform.basis.y),
						"basis_z": _vec3_array(transform.basis.z),
					})
			else:
				nonzero_count += 1
	var summary := {
		"multimesh_nodes": node_count,
		"instances": instance_count,
		"finite_transforms": finite_count,
		"nonzero_transforms": nonzero_count,
		"zeroish_transforms": zero_count,
		"zeroish_samples": zeroish_samples,
		"zeroish_policy": "fail every zeroish transform; inspect listed node/index rather than accepting a silent identity exception",
		"nonfinite_transforms": error_count,
	}
	if node_count <= 0 or instance_count <= 0 or error_count > 0 or zero_count > 0 or finite_count != instance_count or nonzero_count != instance_count:
		_fail("native MultiMesh transform summary failed: %s" % str(summary))
	return summary

func _transform_finite(value: Transform3D) -> bool:
	return _finite_vec3(value.origin) and _finite_vec3(value.basis.x) and _finite_vec3(value.basis.y) and _finite_vec3(value.basis.z)

func _transform_zeroish(value: Transform3D) -> bool:
	return value.origin.length_squared() <= 0.000001 \
		and value.basis.x.distance_to(Vector3.RIGHT) <= 0.0001 \
		and value.basis.y.distance_to(Vector3.UP) <= 0.0001 \
		and value.basis.z.distance_to(Vector3.BACK) <= 0.0001

func _finite_vec3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _unsafe_renderer() -> bool:
	var name := DisplayServer.get_name().to_lower()
	return OS.has_feature("headless") or name.contains("headless") or name.contains("dummy")

func _write_report() -> void:
	var report := {
		"schema_version": 1,
		"scope": "bounded S01 runtime QA",
		"visual_acceptance": "not claimed by this tool",
		"mode": _mode,
		"scene_path": REVIEW_SCENE_PATH,
		"renderer": DisplayServer.get_name(),
		"checks": _checks,
		"errors": _errors,
		"warnings": _warnings,
		"passed": _errors.is_empty(),
		"draw_policy": "native side views use process_frame then RenderingServer.force_draw; no frame_post_draw",
	}
	var path := ProjectSettings.globalize_path(_output_dir.path_join("s01_runtime_qa.json"))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("could not write QA report: %s" % path)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("Saisies S01 runtime QA report: %s" % path)

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES S01 RUNTIME QA: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES S01 RUNTIME QA READY (visual acceptance pending)")
		quit(0)
	else:
		print("SAISIES S01 RUNTIME QA HOLD (%d errors)" % _errors.size())
		quit(1)

func _vec3_array(value: Vector3) -> Array[float]:
	return [value.x, value.y, value.z]
