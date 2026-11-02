extends Node3D

## Runtime-only S01 camera wrapper for the focused review scene.
##
## The frozen R14 CameraRig remains the owner of route placement.  This node
## applies the root-selected S01 visual pose after the rig's normal placement,
## without editing route, terrain, authored geometry, or camera data.  In the
## review scene the default mode holds the selected station; --tour advances
## from 0 m at 30 km/h and stops at the 220 m S01 boundary.

@export var world_path: NodePath = NodePath("../World")
@export_file("*.json") var calibration_path := "res://data/saisies_s01_camera_calibration.json"
@export var tour_speed_kmh := 30.0
@export var tour_max_station_m := 220.0

const SELECTED_STATUS := "root_selected_for_integrated_review"
const S01_ID := "S01"

var _world: Node3D
var _route: Node
var _rig: Node3D
var _camera: Camera3D
var _selected: Dictionary = {}
var _tour_active := false
var _tour_finished := false
var _tour_station_m := 0.0
var _initialized := false
var _initialization_attempts := 0
var _frame_apply_queued := false

var _original_state_captured := false
var _original_auto_advance := true
var _original_cruise_speed_mps := 17.0
var _original_distance_m := 0.0
var _original_requested_scene_id := ""
var _original_s01_pose_present := false
var _original_s01_pose = null
var _original_s01_lateral_present := false
var _original_s01_lateral = null

func _ready() -> void:
	# The baked CameraRig is nested under World while this wrapper is a sibling
	# in the review scene.  A deferred final write keeps the rig's normal
	# placement authoritative until the end of each frame, then applies only
	# this local candidate pose.
	process_priority = -100
	call_deferred("_initialize")

func _initialize() -> void:
	if _initialized:
		return
	if not _resolve_nodes():
		_initialization_attempts += 1
		if _initialization_attempts < 40:
			call_deferred("_initialize")
		else:
			push_error("Saisies S01 camera controller could not resolve world_path %s" % world_path)
		return
	if not _load_selected_candidate():
		return
	_capture_original_state()
	_rig.set("auto_advance", false)
	_tour_active = _has_tour_argument()
	_tour_finished = false
	_tour_station_m = 0.0 if _tour_active else float(_selected.get("station_m", 50.0))
	if not _apply_selected_pose(_tour_station_m):
		push_error("Saisies S01 camera controller could not apply selected pose")
		return
	_initialized = true
	set_meta("saisies_s01_camera_controller_ready", true)
	set_meta("saisies_s01_camera_selected_candidate", String(_selected.get("id", "")))
	set_meta("saisies_s01_camera_selected_status", SELECTED_STATUS)
	set_meta("saisies_s01_camera_mode", "tour" if _tour_active else "fixed")
	set_meta("saisies_s01_camera_scope", "0..220m")

func _process(delta: float) -> void:
	if not _initialized:
		return
	if _tour_active:
		_tour_station_m = minf(
			_tour_station_m + maxf(delta, 0.0) * (tour_speed_kmh / 3.6),
			tour_max_station_m
		)
		if _tour_station_m >= tour_max_station_m - 0.0001:
			# The focused review tour is deliberately bounded to S01.  Keep the
			# selected pose stopped at the boundary instead of entering S02 or
			# changing the existing full-route launcher behaviour.
			_tour_active = false
			_tour_finished = true
			_rig.set("auto_advance", false)
			set_meta("saisies_s01_camera_tour_finished", true)
	if _frame_apply_queued:
		return
	_frame_apply_queued = true
	call_deferred("_apply_frame_pose")

func _apply_frame_pose() -> void:
	_frame_apply_queued = false
	if not _initialized:
		return
	var station_m := _tour_station_m if (_tour_active or _tour_finished) else float(_selected.get("station_m", 50.0))
	if not _apply_selected_pose(station_m):
		_tour_active = false

func _resolve_nodes() -> bool:
	_world = get_node_or_null(world_path) as Node3D
	if _world == null:
		return false
	_route = _world.get_node_or_null("Route") as Node
	_rig = _world.get_node_or_null("CameraRig") as Node3D
	if _route == null or _rig == null:
		return false
	_camera = _rig.get_node_or_null("Camera3D") as Camera3D
	return _camera != null and _route.has_method("pos_at") and _route.has_method("left_at") and _route.has_method("ground_y") and _route.has_method("tangent_at")

func _load_selected_candidate() -> bool:
	if not FileAccess.file_exists(calibration_path):
		push_error("Saisies S01 camera calibration is missing: %s" % calibration_path)
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(calibration_path))
	if not (parsed is Dictionary):
		push_error("Saisies S01 camera calibration is not a JSON object")
		return false
	var payload: Dictionary = parsed
	var status := String(payload.get("selection_status", payload.get("selected_candidate_status", "")))
	if status != SELECTED_STATUS:
		push_error("Saisies S01 camera calibration has unexpected selection status: %s" % status)
		return false
	var selected_id := String(payload.get("selected_candidate", ""))
	if selected_id.is_empty():
		push_error("Saisies S01 camera calibration has no selected_candidate")
		return false
	for collection_value in [payload.get("candidates", []), payload.get("combined_candidates", [])]:
		if not (collection_value is Array):
			continue
		for item in collection_value:
			if item is Dictionary and String(item.get("id", "")) == selected_id:
				_selected = item.duplicate(true)
				return _validate_selected_candidate()
	push_error("Saisies S01 selected candidate is not present in the calibration lists: %s" % selected_id)
	return false

func _validate_selected_candidate() -> bool:
	var station_m := float(_selected.get("station_m", -1.0))
	var pitch_deg := float(_selected.get("pitch_deg", NAN))
	var yaw_deg := float(_selected.get("yaw_deg", NAN))
	var lateral_m := float(_selected.get("lateral_m", NAN))
	var height_m := float(_selected.get("height_m", NAN))
	var fov_deg := float(_selected.get("fov_deg", NAN))
	var roll_deg := float(_selected.get("roll_deg", NAN))
	for value in [station_m, pitch_deg, yaw_deg, lateral_m, height_m, fov_deg, roll_deg]:
		if not is_finite(value):
			push_error("Saisies S01 selected candidate contains a non-finite value")
			return false
	if station_m < 0.0 or station_m > tour_max_station_m:
		push_error("Saisies S01 selected station is outside 0..%.1f m: %.3f" % [tour_max_station_m, station_m])
		return false
	if fov_deg < 30.0 or fov_deg > 120.0 or height_m < 0.5 or height_m > 5.0:
		push_error("Saisies S01 selected camera height/FOV is outside the runtime contract")
		return false
	if absf(roll_deg) > 45.0:
		push_error("Saisies S01 selected roll is outside the runtime contract: %.3f" % roll_deg)
		return false
	return true

func _capture_original_state() -> void:
	if _original_state_captured:
		return
	_original_auto_advance = bool(_rig.get("auto_advance"))
	_original_cruise_speed_mps = float(_rig.get("cruise_speed_mps"))
	_original_distance_m = float(_rig.get("distance_m"))
	_original_requested_scene_id = String(_rig.get("_requested_scene_id"))
	var pose_cache = _rig.get("_acceptance_pose_by_id")
	if pose_cache is Dictionary and pose_cache.has(S01_ID):
		_original_s01_pose_present = true
		_original_s01_pose = pose_cache[S01_ID]
	var lateral_cache = _rig.get("_acceptance_lateral_by_id")
	if lateral_cache is Dictionary and lateral_cache.has(S01_ID):
		_original_s01_lateral_present = true
		_original_s01_lateral = lateral_cache[S01_ID]
	_original_state_captured = true

func _apply_selected_pose(station_m: float) -> bool:
	if _route == null or _rig == null or _camera == null:
		return false
	var route_length := float(_route.get("length_m"))
	if route_length <= 0.0:
		return false
	var clamped_station := clampf(station_m, 0.0, minf(tour_max_station_m, route_length))
	if _rig.has_method("reset_to_distance"):
		_rig.call("reset_to_distance", clamped_station)
	else:
		_rig.set("distance_m", clamped_station)
	var route_point: Vector3 = _route.call("pos_at", clamped_station)
	var left: Vector3 = _route.call("left_at", clamped_station)
	var tangent: Vector3 = _route.call("tangent_at", clamped_station)
	if tangent.length_squared() <= 0.000001:
		return false
	var lateral_m := float(_selected.get("lateral_m", -2.2))
	var ground_y := float(_route.call("ground_y", clamped_station, lateral_m))
	var heading := atan2(-tangent.x, -tangent.z)
	_rig.global_position = Vector3(
		route_point.x + left.x * lateral_m,
		ground_y + 0.02,
		route_point.z + left.z * lateral_m
	)
	_rig.rotation = Vector3(
		deg_to_rad(float(_selected.get("pitch_deg", -14.0))),
		heading + deg_to_rad(float(_selected.get("yaw_deg", 24.0))),
		deg_to_rad(float(_selected.get("roll_deg", 0.0)))
	)
	var camera_local := _camera.position
	camera_local.y = float(_selected.get("height_m", 1.65))
	_camera.position = camera_local
	_camera.fov = float(_selected.get("fov_deg", 79.0))
	_camera.current = true
	_update_s01_pose_cache(lateral_m)
	_rig.set("_requested_scene_id", S01_ID)
	_rig.set_meta("saisies_s01_camera_controller", true)
	_rig.set_meta("saisies_s01_camera_candidate_id", String(_selected.get("id", "")))
	_rig.set_meta("saisies_s01_camera_station_m", clamped_station)
	_rig.set_meta("saisies_s01_camera_lateral_m", lateral_m)
	_rig.set_meta("saisies_s01_camera_roll_deg", float(_selected.get("roll_deg", 0.0)))
	return true

func _update_s01_pose_cache(lateral_m: float) -> void:
	var pose_cache = _rig.get("_acceptance_pose_by_id")
	if pose_cache is Dictionary:
		pose_cache[S01_ID] = Vector2(
			deg_to_rad(float(_selected.get("pitch_deg", -14.0))),
			deg_to_rad(float(_selected.get("yaw_deg", 24.0)))
		)
	var lateral_cache = _rig.get("_acceptance_lateral_by_id")
	if lateral_cache is Dictionary:
		lateral_cache[S01_ID] = lateral_m

func _has_tour_argument() -> bool:
	for argument in OS.get_cmdline_user_args():
		if String(argument) == "--tour":
			return true
	return false

func _exit_tree() -> void:
	# The wrapper does not disable the CameraRig process.  If the focused node
	# is removed, restore its runtime fields so the frozen R14 rig keeps its
	# original behaviour for any caller that continues using the scene.
	if not _original_state_captured or not is_instance_valid(_rig):
		return
	_rig.set("auto_advance", _original_auto_advance)
	_rig.set("cruise_speed_mps", _original_cruise_speed_mps)
	_rig.set("distance_m", _original_distance_m)
	_rig.set("_requested_scene_id", _original_requested_scene_id)
	var pose_cache = _rig.get("_acceptance_pose_by_id")
	if pose_cache is Dictionary:
		if _original_s01_pose_present:
			pose_cache[S01_ID] = _original_s01_pose
		else:
			pose_cache.erase(S01_ID)
	var lateral_cache = _rig.get("_acceptance_lateral_by_id")
	if lateral_cache is Dictionary:
		if _original_s01_lateral_present:
			lateral_cache[S01_ID] = _original_s01_lateral
		else:
			lateral_cache.erase(S01_ID)
