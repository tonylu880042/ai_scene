extends SceneTree

## Native route-only gray capture for the R12 S09 sequence candidates.
##
## The instantiated geo scene is pruned before it enters the tree.  Route is
## retained because it creates the road; CameraRig, WorldEnvironment and Sun
## are retained for the same camera/lighting contract.  Landscape, buildings,
## forest, roadside and nearfield details are intentionally absent.

const SCENE_PATH := "res://scenes/MainScene_saisies_geo.tscn"
const DEFAULT_OUTPUT_DIR := "res://export/saisies/review/round12_analysis/native_sequence"
const CAPTURE_SIZE := Vector2i(1920, 1080)
const FOV_DEG := 78.0
const CAMERA_HEIGHT_M := 1.65
const CAMERA_LATERAL_M := -2.0
const CAMERA_PITCH_DEG := -8.0
const CAMERA_YAW_DEG := -4.0
const CENTER_STATIONS_M := [5274.916403, 5352.116403, 5427.116403, 5497.116403, 5550.449736, 5587.116403]
const TIMES_S := [326.0, 330.0, 334.0, 338.0, 342.0, 346.0]
const CANDIDATES := [
	{"id": "A", "label": "A_center", "offset_m": 0.0},
	{"id": "B", "label": "B_minus25m", "offset_m": -25.0},
	{"id": "C", "label": "C_plus25m", "offset_m": 25.0}
]
const KEEP_TOP_LEVEL_CHILDREN := ["Route", "CameraRig", "WorldEnvironment", "Sun"]

var _output_dir := DEFAULT_OUTPUT_DIR
var _dry_run := false
var _errors: Array[String] = []
var _capture_records: Array = []
var _capture_started := false
var _capture_completion_checked := false

func _initialize() -> void:
	_parse_args()
	call_deferred("_run")

func _parse_args() -> void:
	for arg in _all_cmdline_args():
		var value := String(arg)
		if value.begins_with("--output-dir="):
			_output_dir = value.substr("--output-dir=".length())
		elif value == "--dry-run":
			_dry_run = true

func _all_cmdline_args() -> PackedStringArray:
	var args := PackedStringArray()
	args.append_array(OS.get_cmdline_args())
	args.append_array(OS.get_cmdline_user_args())
	return args

func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("geo scene could not be loaded: %s" % SCENE_PATH)
		_finish()
		return
	var scene := packed.instantiate()
	_prune_scene_before_ready(scene)
	get_root().add_child(scene)
	var root_window := get_root() as Window
	if root_window:
		root_window.size = CAPTURE_SIZE
		root_window.content_scale_size = CAPTURE_SIZE
	await process_frame
	await process_frame
	var route := scene.get_node_or_null("Route") as SaisiesRoute
	var rig := scene.get_node_or_null("CameraRig") as SaisiesCamera
	if route == null or not route.route_ready():
		_fail("pruned scene Route is not ready")
	if rig == null:
		_fail("pruned scene CameraRig is missing")
	var camera := rig.get_node_or_null("Camera3D") as Camera3D if rig != null else null
	if camera == null:
		_fail("pruned scene CameraRig/Camera3D is missing")
	if not _errors.is_empty():
		_finish()
		return
	_prepare_instance(rig, camera)
	_write_capture_manifest(route, rig, camera, "prepared", false)
	if _dry_run:
		print("round12 dry run: scene pruned and route/camera ready; no GPU images requested")
		_finish()
		return
	DirAccess.make_dir_recursive_absolute(_global_path(_output_dir))
	_capture_started = true
	for candidate in CANDIDATES:
		for index in TIMES_S.size():
			await _capture_one(route, rig, camera, candidate, index)
	_assert_native_capture_complete()
	_write_capture_manifest(route, rig, camera, "captured" if _errors.is_empty() else "failed", true)
	_finish()

func _prune_scene_before_ready(scene: Node) -> void:
	for child in scene.get_children():
		if KEEP_TOP_LEVEL_CHILDREN.has(String(child.name)):
			continue
		scene.remove_child(child)
		child.free()
	print("round12 scene prune retained=%s" % ",".join(KEEP_TOP_LEVEL_CHILDREN))

func _prepare_instance(rig: SaisiesCamera, camera: Camera3D) -> void:
	_prepare_pose_override(rig, camera)
	rig.auto_advance = false
	camera.current = true
	camera.fov = FOV_DEG
	camera.position.y = CAMERA_HEIGHT_M
	rig.set_meta("saisies_round12_temporary_pose_override", {
		"scene_id": "S09",
		"lateral_m": CAMERA_LATERAL_M,
		"pitch_deg": CAMERA_PITCH_DEG,
		"yaw_deg": CAMERA_YAW_DEG,
		"height_m": CAMERA_HEIGHT_M,
		"fov_deg": FOV_DEG,
		"production_data_changed": false
	})

func _prepare_pose_override(rig: SaisiesCamera, camera: Camera3D) -> void:
	# This is an instance-local override.  It is deliberately kept in the
	# capture tool instead of changing data/saisies_geo_camera_poses.json.
	rig._acceptance_lateral_by_id["S09"] = CAMERA_LATERAL_M
	rig._acceptance_pose_by_id["S09"] = Vector2(deg_to_rad(CAMERA_PITCH_DEG), deg_to_rad(CAMERA_YAW_DEG))
	camera.position.y = CAMERA_HEIGHT_M

func _capture_one(route: SaisiesRoute, rig: SaisiesCamera, camera: Camera3D, candidate: Dictionary, index: int) -> void:
	var requested_station := float(CENTER_STATIONS_M[index]) + float(candidate["offset_m"])
	var station := clampf(requested_station, 0.0, route.length_m)
	# Apply the existing S09 pose first, then reset after replacing the private
	# cache values so _place() uses this temporary pose on every settled frame.
	_prepare_pose_override(rig, camera)
	rig.reset_to_distance(station)
	rig.apply_acceptance_pose("S09")
	rig._acceptance_lateral_by_id["S09"] = CAMERA_LATERAL_M
	rig._acceptance_pose_by_id["S09"] = Vector2(deg_to_rad(CAMERA_PITCH_DEG), deg_to_rad(CAMERA_YAW_DEG))
	rig.reset_to_distance(station)
	for _settle in range(8):
		await process_frame
	# Match the R11 native readback pattern: force the Metal draw, then read the
	# root viewport texture directly.  No secondary SubViewport is introduced.
	RenderingServer.force_draw()
	_save_viewport(_output_dir.path_join("%s_T%d.png" % [String(candidate["id"]), int(round(float(TIMES_S[index])))]))
	var forward := (-camera.global_transform.basis.z).normalized()
	var tangent := route.tangent_at(station)
	var record := {
		"id": "%s_T%d" % [String(candidate["id"]), int(round(float(TIMES_S[index])))],
		"candidate": candidate["label"],
		"time_s": TIMES_S[index],
		"requested_station_m": requested_station,
		"actual_station_m": rig.distance_m,
		"camera_position_xyz": _vector_for(camera.global_position),
		"rig_rotation_deg": _vector_for(Vector3(rad_to_deg(rig.rotation.x), rad_to_deg(rig.rotation.y), rad_to_deg(rig.rotation.z))),
		"route_tangent_xyz": _vector_for(tangent),
		"camera_forward_xyz": _vector_for(forward),
		"output": _output_dir.path_join("%s_T%d.png" % [String(candidate["id"]), int(round(float(TIMES_S[index])))]),
		"renderer": RenderingServer.get_current_rendering_driver_name()
	}
	_capture_records.append(record)
	print("ROUND12 CAPTURE ", JSON.stringify(record))

func _save_viewport(output_path: String) -> void:
	var viewport := get_root() as Viewport
	if viewport == null:
		_fail("root viewport is unavailable")
		return
	var texture := viewport.get_texture()
	if texture == null:
		_fail("root viewport texture is unavailable")
		return
	var image := texture.get_image()
	if image == null:
		_fail("root viewport image is unavailable")
		return
	if not _image_has_visible_pixels(image):
		_fail("capture viewport image is black or empty: %s" % output_path)
		return
	var global_output := _global_path(output_path)
	DirAccess.make_dir_recursive_absolute(global_output.get_base_dir())
	var error := image.save_png(global_output)
	if error != OK:
		_fail("reference PNG save failed (%s): %s" % [error, global_output])
	else:
		print("round12 image saved: ", global_output)

func _image_has_visible_pixels(image: Image) -> bool:
	var size := image.get_size()
	if size.x <= 0 or size.y <= 0:
		return false
	var stride := maxi(1, mini(size.x, size.y) / 128)
	var max_value := 0.0
	for y in range(0, size.y, stride):
		for x in range(0, size.x, stride):
			var pixel := image.get_pixel(x, y)
			max_value = maxf(max_value, maxf(pixel.r, maxf(pixel.g, pixel.b)))
	return max_value > 0.01

func _write_capture_manifest(route: SaisiesRoute, rig: SaisiesCamera, camera: Camera3D, state: String, include_records: bool) -> void:
	var payload := {
		"schema_version": 1,
		"id": "saisies_round12_native_sequence_capture",
		"status": state,
		"scope": "route-plus-road-native-gray-probe",
		"production_change": false,
		"scene": SCENE_PATH,
		"retained_top_level_children": KEEP_TOP_LEVEL_CHILDREN,
		"removed_top_level_children": ["Landscape", "Roadbed", "Buildings", "Forest", "Roadside", "NearfieldDetails"],
		"route_length_m": route.length_m,
		"resolution_px": [CAPTURE_SIZE.x, CAPTURE_SIZE.y],
		"camera": {
			"height_m": CAMERA_HEIGHT_M,
			"fov_deg": FOV_DEG,
			"lateral_m": CAMERA_LATERAL_M,
			"pitch_deg": CAMERA_PITCH_DEG,
			"yaw_deg": CAMERA_YAW_DEG,
			"pose_override_scene_id": "S09",
			"pose_override_scope": "instance-local temporary cache; global data untouched"
		},
		"candidates": CANDIDATES,
		"times_s": TIMES_S,
		"center_stations_m": CENTER_STATIONS_M,
		"records": _capture_records if include_records else [],
		"renderer": RenderingServer.get_current_rendering_driver_name(),
		"generated_by": "tools/capture_saisies_round12_sequence.gd"
	}
	var path := _output_dir.path_join("capture_manifest.json")
	var global_path := _global_path(path)
	DirAccess.make_dir_recursive_absolute(global_path.get_base_dir())
	var file := FileAccess.open(global_path, FileAccess.WRITE)
	if file == null:
		_fail("could not write capture manifest: %s" % path)
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()

func _assert_native_capture_complete() -> void:
	if _dry_run or not _capture_started or _capture_completion_checked:
		return
	_capture_completion_checked = true
	var expected_count := CANDIDATES.size() * TIMES_S.size()
	if _capture_records.size() != expected_count:
		_fail("native capture record count is %d; expected %d" % [_capture_records.size(), expected_count])
	var seen_ids := {}
	for record_value in _capture_records:
		if not (record_value is Dictionary):
			_fail("native capture record is not a dictionary")
			continue
		var record: Dictionary = record_value
		var record_id := str(record.get("id", ""))
		if record_id.is_empty():
			_fail("native capture record has no id")
		elif seen_ids.has(record_id):
			_fail("native capture record id is duplicated: %s" % record_id)
		else:
			seen_ids[record_id] = true
		var output_path := str(record.get("output", ""))
		var global_output := _global_path(output_path)
		if output_path.is_empty() or not FileAccess.file_exists(global_output):
			_fail("native capture image is missing for %s: %s" % [record_id, output_path])
			continue
		var image := Image.load_from_file(global_output)
		if image == null:
			_fail("native capture image could not be read for %s: %s" % [record_id, output_path])
		elif image.get_width() != CAPTURE_SIZE.x or image.get_height() != CAPTURE_SIZE.y:
			_fail("native capture image size for %s is %dx%d; expected %dx%d" % [record_id, image.get_width(), image.get_height(), CAPTURE_SIZE.x, CAPTURE_SIZE.y])
	if seen_ids.size() != expected_count:
		_fail("native capture unique record ids are %d; expected %d" % [seen_ids.size(), expected_count])

func _vector_for(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}

func _global_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path if path.is_absolute_path() else ProjectSettings.globalize_path(path)

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES R12 CAPTURE: " + message)

func _finish() -> void:
	_assert_native_capture_complete()
	if _errors.is_empty():
		print("SAISIES R12 CAPTURE READY/HOLD")
		quit(0)
	else:
		for error in _errors:
			print("SAISIES R12 CAPTURE ERROR: " + error)
		quit(1)
