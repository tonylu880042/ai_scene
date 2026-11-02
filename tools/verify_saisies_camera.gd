extends SceneTree

## Headless camera contract for the authored v2 Saisies route.
##
## Default mode checks the normal traversal against every source-view anchor,
## continuity on either side of each anchor, and the route endpoint.  It also
## starts a fresh headless child process for every fixed scene id, so a static
## capture cannot depend on state left in the parent process.
##
## Direct static mode is useful when diagnosing one process:
##   godot --headless --path . --script res://tools/verify_saisies_camera.gd -- --scene-id=S13

const SCENE_PATH := "res://scenes/MainScene_saisies_v2.tscn"
const ROUTE_SCRIPT_PATH := "res://scripts/saisies_route.gd"
const CAMERA_SCRIPT_PATH := "res://scripts/saisies_camera.gd"
const ROUTE_FILE := "res://data/saisies_route_v2.json"
const SCENE_IDS := [
	"S01", "S02", "S03", "S04", "S05", "S06", "S07", "S08", "S09",
	"S10", "S11", "S12", "S13", "S14", "S15", "S16", "S17", "S18"
]
const POSE_EPSILON_DEG := 0.05
const CONTINUITY_STEP_M := 1.0
const MAX_LOCAL_PITCH_STEP_DEG := 8.0
const MAX_LOCAL_YAW_STEP_DEG := 10.0
const MAX_LOCAL_LATERAL_STEP_M := 0.20

class CameraProbeRoute extends SaisiesRoute:
	func _ready() -> void:
		# The probe builds route samples explicitly and does not need render meshes.
		pass

var _errors: Array[String] = []
var _requested_scene_id := ""
var _child_scene_id := ""
var _route: SaisiesRoute
var _rig: SaisiesCamera
var _probe_holder: Node3D
var _scene_lateral_cache_ready := false
var _scene_lateral_by_id: Dictionary = {}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scene-id="):
			_requested_scene_id = arg.substr(11).to_upper()
		elif arg.begins_with("--child-scene-id="):
			_child_scene_id = arg.substr(17).to_upper()
	call_deferred("_run")

func _run() -> void:
	if not _child_scene_id.is_empty():
		await _run_child_static(_child_scene_id)
	elif not _requested_scene_id.is_empty():
		await _load_full_scene()
		if _route != null and _rig != null:
			await _verify_static_pose(_requested_scene_id)
	else:
		await _load_full_scene()
		if _route != null and _rig != null:
			_verify_normal_traversal()
			_verify_static_poses_in_fresh_processes()
	_finish()

func _load_full_scene() -> void:
	# Keep this contract probe on the real v2 route data while avoiding unrelated
	# scenery scripts.  The camera and route are the only dependencies of the
	# interpolation contract, and this keeps their log free of other modules'
	# in-progress diagnostics.
	var route_script := load(ROUTE_SCRIPT_PATH)
	var camera_script := load(CAMERA_SCRIPT_PATH)
	if route_script == null or camera_script == null:
		_fail("camera probe scripts could not be loaded")
		return
	var route := CameraProbeRoute.new() as SaisiesRoute
	route.name = "Route"
	route.route_file = ROUTE_FILE
	var rig := camera_script.new() as SaisiesCamera
	_setup_camera_probe(rig)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.current = true
	camera.fov = 78.0
	rig.add_child(camera)
	_probe_holder = Node3D.new()
	_probe_holder.add_child(route)
	_probe_holder.add_child(rig)
	# Build route data and curve before adding the holder so CameraProbeRoute's
	# intentionally empty _ready does not create render meshes.
	route._load_route_data()
	route._build_samples()
	route._build_curve()
	get_root().add_child(_probe_holder)
	await process_frame
	_route = route
	_rig = rig
	if _route.length_m < 14700.0 or _route.length_m > 14900.0:
		_fail("v2 route length %.2f m is outside the authored 14.8 km route" % _route.length_m)

func _run_child_static(scene_id: String) -> void:
	if not SCENE_IDS.has(scene_id):
		_fail("unknown child scene id: %s" % scene_id)
		return
	# Keep this probe on the real v2 route data while avoiding unrelated scenery
	# generation in each child process.  The camera still parses --scene-id in its
	# own process and applies the cached fixed pose during _ready().
	var route_script := load(ROUTE_SCRIPT_PATH)
	var camera_script := load(CAMERA_SCRIPT_PATH)
	if route_script == null or camera_script == null:
		_fail("camera probe scripts could not be loaded")
		return
	var route := CameraProbeRoute.new() as SaisiesRoute
	route.name = "Route"
	route.route_file = ROUTE_FILE
	var rig := camera_script.new() as SaisiesCamera
	_setup_camera_probe(rig)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.current = true
	rig.add_child(camera)
	# Build only the route data/curve needed by the camera.  This avoids regenerating
	# the full road mesh 18 times while still exercising the shipped v2 route
	# implementation and data file.
	_probe_holder = Node3D.new()
	_probe_holder.add_child(route)
	_probe_holder.add_child(rig)
	route._load_route_data()
	route._build_samples()
	route._build_curve()
	get_root().add_child(_probe_holder)
	await process_frame
	_route = route
	_rig = rig
	if route.length_m < 14700.0 or route.length_m > 14900.0 or route.pos_at(0.0) == route.pos_at(route.length_m):
		_fail("child v2 route data did not build")
		return
	await _verify_static_pose(scene_id)

func _setup_camera_probe(rig: SaisiesCamera) -> void:
	rig.name = "CameraRig"
	rig.route_path = NodePath("../Route")
	rig.auto_advance = true
	rig.camera_height = 1.65

func _verify_normal_traversal() -> void:
	if _route.length_m < 14700.0 or _route.length_m > 14900.0:
		_fail("v2 route length %.2f m is outside the authored 14.8 km route" % _route.length_m)
	if _rig.get_node_or_null("Camera3D") == null:
		_fail("CameraRig/Camera3D is missing")
	else:
		var camera := _rig.get_node("Camera3D") as Camera3D
		if absf(camera.position.y - 1.65) > 0.001:
			_fail("camera height changed: %.3f m" % camera.position.y)
	var previous_distance := -INF
	for scene_id in SCENE_IDS:
		var distance := _route.acceptance_distance(scene_id)
		if distance <= previous_distance:
			_fail("scene anchors are not strictly ordered at %s" % scene_id)
		previous_distance = distance
		_rig.auto_advance = false
		_rig.reset_to_distance(distance)
		_verify_pose(scene_id, "normal anchor")
		_verify_anchor_continuity(scene_id, distance)
	_verify_explicit_pose_override("S01", _route.acceptance_distance("S01") + 7.0)

	# The authored pose is clamped before the first and after the last anchor.
	_rig.reset_to_distance(-100.0)
	_verify_pose(SCENE_IDS.front(), "before first anchor")
	_rig.reset_to_distance(_route.length_m + 100.0)
	_verify_pose(SCENE_IDS.back(), "after last anchor")

	# A large simulated frame still uses the real auto-advance path and reaches
	# the terminal route distance without changing the route's public API.
	_rig.auto_advance = true
	_rig.reset_to_distance(0.0)
	_rig._process(3600.0)
	if absf(_rig.distance_m - _route.length_m) > 0.01:
		_fail("normal traversal did not reach endpoint: %.2f / %.2f m" % [_rig.distance_m, _route.length_m])
	print("camera normal traversal: anchors=%d endpoint=%.2f m" % [SCENE_IDS.size(), _rig.distance_m])

func _verify_explicit_pose_override(scene_id: String, distance: float) -> void:
	# Explicit scene-id poses own lateral placement as well as pitch/yaw, even
	# when a caller applies the pose at a nearby diagnostic distance.
	_rig.auto_advance = false
	_rig.reset_to_distance(distance)
	_rig.apply_acceptance_pose(scene_id)
	_verify_pose_values(scene_id, _route.acceptance_pose(scene_id), "explicit nearby pose")
	_rig.apply_acceptance_pose("")

func _verify_anchor_continuity(scene_id: String, distance: float) -> void:
	var left_distance := maxf(0.0, distance - CONTINUITY_STEP_M)
	var right_distance := minf(_route.length_m, distance + CONTINUITY_STEP_M)
	_rig.reset_to_distance(left_distance)
	var left_pitch := _rig.rotation.x
	var left_yaw := _relative_yaw()
	var left_lateral := _actual_lateral()
	_rig.reset_to_distance(right_distance)
	var right_pitch := _rig.rotation.x
	var right_yaw := _relative_yaw()
	var right_lateral := _actual_lateral()
	var pitch_delta := absf(rad_to_deg(right_pitch - left_pitch))
	var yaw_delta := absf(rad_to_deg(_angle_delta(right_yaw, left_yaw)))
	var lateral_delta := absf(right_lateral - left_lateral)
	if pitch_delta > MAX_LOCAL_PITCH_STEP_DEG:
		_fail("pitch discontinuity around %s: %.3f deg over %.1f m" % [scene_id, pitch_delta, right_distance - left_distance])
	if yaw_delta > MAX_LOCAL_YAW_STEP_DEG:
		_fail("yaw discontinuity around %s: %.3f deg over %.1f m" % [scene_id, yaw_delta, right_distance - left_distance])
	if lateral_delta > MAX_LOCAL_LATERAL_STEP_M:
		_fail("lateral discontinuity around %s: %.3f m over %.1f m" % [scene_id, lateral_delta, right_distance - left_distance])

func _verify_static_poses_in_fresh_processes() -> void:
	var executable := OS.get_executable_path()
	var project_path := ProjectSettings.globalize_path("res://")
	var script_path := ProjectSettings.globalize_path("res://tools/verify_saisies_camera.gd")
	for scene_id in SCENE_IDS:
		var output: Array = []
		var args := PackedStringArray([
			"--headless", "--path", project_path, "--script", script_path, "--",
			"--child-scene-id=%s" % scene_id, "--scene-id=%s" % scene_id
		])
		var exit_code := OS.execute(executable, args, output, true)
		if exit_code != 0:
			_fail("fresh process static %s failed (%d): %s" % [scene_id, exit_code, str(output)])
	print("camera static poses: %d fresh processes" % SCENE_IDS.size())

func _verify_static_pose(scene_id: String, context: String = "static") -> void:
	if not SCENE_IDS.has(scene_id):
		_fail("unknown scene id: %s" % scene_id)
		return
	var distance := _route.acceptance_distance(scene_id)
	var pose := _route.acceptance_pose(scene_id)
	if _rig.auto_advance:
		_fail("%s %s unexpectedly has auto advance enabled" % [context, scene_id])
	if absf(_rig.distance_m - distance) > 0.01:
		_fail("%s %s distance %.2f != %.2f" % [context, scene_id, _rig.distance_m, distance])
	_verify_pose(scene_id, context)
	var fixed_distance := _rig.distance_m
	for _frame in range(3):
		await process_frame
	if absf(_rig.distance_m - fixed_distance) > 0.01:
		_fail("%s %s advanced while fixed" % [context, scene_id])
	# Check the values after a few frames as well, which catches a later _process
	# placement accidentally replacing the fixed pose.
	_verify_pose_values(scene_id, pose, context)
	print("camera static pose: %s pitch=%.2f yaw=%.2f lateral=%.2f" % [scene_id, rad_to_deg(_rig.rotation.x), rad_to_deg(_relative_yaw()), _actual_lateral()])

func _verify_pose(scene_id: String, context: String) -> void:
	var pose := _route.acceptance_pose(scene_id)
	_verify_pose_values(scene_id, pose, context)

func _verify_pose_values(scene_id: String, pose: Dictionary, context: String) -> void:
	var expected_pitch := float(pose.get("pitch_deg", -8.0))
	var expected_yaw := float(pose.get("yaw_deg", 0.0))
	var expected_lateral := _expected_lateral(scene_id)
	var actual_pitch := rad_to_deg(_rig.rotation.x)
	var actual_yaw := rad_to_deg(_relative_yaw())
	var actual_lateral := _actual_lateral()
	if absf(actual_pitch - expected_pitch) > POSE_EPSILON_DEG:
		_fail("%s %s pitch %.3f != %.3f" % [context, scene_id, actual_pitch, expected_pitch])
	if absf(rad_to_deg(_angle_delta(deg_to_rad(actual_yaw), deg_to_rad(expected_yaw)))) > POSE_EPSILON_DEG:
		_fail("%s %s yaw %.3f != %.3f" % [context, scene_id, actual_yaw, expected_yaw])
	if absf(actual_lateral - expected_lateral) > 0.01:
		_fail("%s %s lateral %.3f != %.3f" % [context, scene_id, actual_lateral, expected_lateral])
	if absf(actual_lateral) > _route.road_width_at(_rig.distance_m) * 0.5 + 0.01:
		_fail("%s %s lateral %.3f left the road corridor" % [context, scene_id, actual_lateral])
	var expected_ground_y := _route.ground_y(_rig.distance_m, expected_lateral) + 0.02
	if absf(_rig.global_position.y - expected_ground_y) > 0.02:
		_fail("%s %s ground placement %.3f != %.3f" % [context, scene_id, _rig.global_position.y, expected_ground_y])

func _relative_yaw() -> float:
	var tangent := _route.tangent_at(_rig.distance_m)
	var heading := atan2(-tangent.x, -tangent.z)
	return _angle_delta(_rig.rotation.y, heading)

func _angle_delta(a: float, b: float) -> float:
	return wrapf(a - b + PI, 0.0, TAU) - PI

func _actual_lateral() -> float:
	return (_rig.global_position - _route.pos_at(_rig.distance_m)).dot(_route.left_at(_rig.distance_m))

func _expected_lateral(scene_id: String) -> float:
	if not _scene_lateral_cache_ready:
		_scene_lateral_cache_ready = true
		var scene_map_file := "res://data/saisies_scene_map.json"
		if FileAccess.file_exists(scene_map_file):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(scene_map_file))
			if parsed is Dictionary:
				for item in parsed.get("scenes", []):
					if item is Dictionary and item.has("acceptance_lateral_m"):
						_scene_lateral_by_id[String(item.get("scene_id", ""))] = float(item.get("acceptance_lateral_m", 0.0))
	return float(_scene_lateral_by_id.get(scene_id, 0.0))

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES CAMERA VERIFY: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES CAMERA VERIFY PASS")
		quit(0)
	else:
		print("SAISIES CAMERA VERIFY FAIL (%d errors)" % _errors.size())
		quit(1)
