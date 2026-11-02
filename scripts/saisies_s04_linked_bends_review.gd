extends Node3D

## S04 linked-bends review wrapper over the frozen R28 S03 environment.
##
## This controller owns only the shared review CameraRig pose.  It maps the
## selected 100..120 second source interval to a local, piecewise-linear
## station candidate and leaves GeoRoute, scenery, and production checkpoints
## untouched.

@export var base_scene_path: NodePath = NodePath("../S03Base")
@export var world_path: NodePath = NodePath("../S03Base/JunctionShapeReview/ParasolReview/CafeTreesReview/RightForestReview/LeftForestReview/FlowersReview/SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/World")
@export var s03_review_controller_path: NodePath = NodePath("../S03Base/JunctionShapeReview/ParasolReview/CafeTreesReview/RightForestReview/LeftForestReview/FlowersReview/SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S03ReviewController")
@export_file("*.json") var candidate_path := "res://data/saisies_s04_linked_bends.json"
@export var default_video_seconds := 110.0
@export var fov_deg := 58.0
@export var camera_height_m := 1.67
@export var pitch_deg := -8.0
@export var yaw_deg := 0.0
@export var lateral_m := -1.6
@export var roll_deg := 0.0
@export var preview_speed_kmh := 30.0

const REVIEW_STATUS := "root_selected_for_integrated_review"
const BASE_READY_META := "saisies_s03_right_forest_distribution_review_ready"
const FIRST_VIDEO_SECONDS := 100.0
const LAST_VIDEO_SECONDS := 120.0

var _base: Node
var _world: Node3D
var _route: Node
var _rig: Node3D
var _camera: Camera3D
var _old_s03_controller: Node
var _anchors: Array[Dictionary] = []
var _candidate_payload: Dictionary = {}
var _current_video_seconds := 110.0
var _current_station_m := 1540.0
var _preview_active := false
var _preview_finished := false
var _initialized := false
var _settling := false
var _released := false
var _attempts := 0

var _original_captured := false
var _original_rig_process := false
var _original_rig_physics_process := false
var _original_rig_auto_advance := true
var _original_rig_cruise_speed_mps := 17.0
var _original_rig_distance_m := 0.0
var _original_requested_scene_id := ""
var _original_rig_local_position := Vector3.ZERO
var _original_rig_local_rotation := Vector3.ZERO
var _original_rig_local_scale := Vector3.ONE
var _original_camera_local_position := Vector3.ZERO
var _original_camera_local_rotation := Vector3.ZERO
var _original_camera_local_scale := Vector3.ONE
var _original_camera_fov := 75.0
var _original_camera_current := false
var _original_old_controller_process := false
var _original_old_controller_physics_process := false

func _ready() -> void:
	process_priority = -100
	_parse_args()
	call_deferred("_try_initialize")

func _try_initialize() -> void:
	if _initialized or _settling or _released:
		return
	if not _resolve_nodes():
		_retry("S04 linked-bends review dependencies are incomplete")
		return
	if not _base_ready():
		_retry("S04 linked-bends review is waiting for R28 S03 base readiness")
		return
	if not _load_candidate():
		return
	_capture_original_state()
	_old_s03_controller.set_process(false)
	_old_s03_controller.set_physics_process(false)
	_rig.set_process(false)
	_rig.set_physics_process(false)
	_settling = true
	call_deferred("_settle_and_apply")

func _settle_and_apply() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if _released:
		_settling = false
		return
	# Drain the old fixed S03 controller and the rig's deferred placement before
	# this review wrapper becomes the sole writer of the shared camera pose.
	await get_tree().process_frame
	await get_tree().process_frame
	_current_video_seconds = clampf(default_video_seconds, FIRST_VIDEO_SECONDS, LAST_VIDEO_SECONDS)
	_current_station_m = _station_for_video_seconds(_current_video_seconds)
	if _has_preview_argument():
		_preview_active = true
		_preview_finished = false
		_current_video_seconds = FIRST_VIDEO_SECONDS
		_current_station_m = _station_for_video_seconds(FIRST_VIDEO_SECONDS)
	if not _apply_review_pose():
		_settling = false
		_retry("S04 linked-bends review could not apply selected camera pose")
		return
	_initialized = true
	_settling = false
	_publish_ready_state()

func _process(delta: float) -> void:
	if not _initialized or _released:
		return
	if _preview_active:
		_current_station_m = minf(
			_current_station_m + maxf(delta, 0.0) * (preview_speed_kmh / 3.6),
			_station_for_video_seconds(LAST_VIDEO_SECONDS)
		)
		_current_video_seconds = _video_seconds_for_station(_current_station_m)
		if _current_station_m >= _station_for_video_seconds(LAST_VIDEO_SECONDS) - 0.0001:
			_current_station_m = _station_for_video_seconds(LAST_VIDEO_SECONDS)
			_current_video_seconds = LAST_VIDEO_SECONDS
			_preview_active = false
			_preview_finished = true
			set_meta("saisies_s04_linked_bends_preview_tour_finished", true)
	_apply_review_pose()

func apply_video_time(video_seconds: float) -> Dictionary:
	## Public root/native-capture hook for a fixed source-time view.
	if not is_finite(video_seconds):
		return {"ok": false, "error": "video_seconds must be finite"}
	_current_video_seconds = clampf(video_seconds, FIRST_VIDEO_SECONDS, LAST_VIDEO_SECONDS)
	_current_station_m = _station_for_video_seconds(_current_video_seconds)
	_preview_active = false
	_preview_finished = false
	if not _initialized or _released:
		return {"ok": false, "error": "review controller is not ready", "video_seconds": _current_video_seconds, "station_m": _current_station_m}
	var ok := _apply_review_pose()
	return _pose_record(ok)

func release_camera() -> bool:
	## Stop this wrapper and restore every shared rig/controller state captured
	## before the linked-bends review took ownership.
	if _released:
		return true
	_released = true
	_preview_active = false
	_initialized = false
	if _original_captured:
		if is_instance_valid(_rig):
			_rig.position = _original_rig_local_position
			_rig.rotation = _original_rig_local_rotation
			_rig.scale = _original_rig_local_scale
			_rig.set("auto_advance", _original_rig_auto_advance)
			_rig.set("cruise_speed_mps", _original_rig_cruise_speed_mps)
			_rig.set("distance_m", _original_rig_distance_m)
			_rig.set("_requested_scene_id", _original_requested_scene_id)
			_rig.set_process(_original_rig_process)
			_rig.set_physics_process(_original_rig_physics_process)
		if is_instance_valid(_camera):
			_camera.position = _original_camera_local_position
			_camera.rotation = _original_camera_local_rotation
			_camera.scale = _original_camera_local_scale
			_camera.fov = _original_camera_fov
			_camera.current = _original_camera_current
		if is_instance_valid(_old_s03_controller):
			_old_s03_controller.set_process(_original_old_controller_process)
			_old_s03_controller.set_physics_process(_original_old_controller_physics_process)
	set_meta("saisies_s04_linked_bends_review_released", true)
	set_process(false)
	return true

func _resolve_nodes() -> bool:
	_base = get_node_or_null(base_scene_path)
	_world = get_node_or_null(world_path) as Node3D
	_old_s03_controller = get_node_or_null(s03_review_controller_path)
	_route = _world.get_node_or_null("Route") as Node if _world != null else null
	_rig = _world.get_node_or_null("CameraRig") as Node3D if _world != null else null
	_camera = _rig.get_node_or_null("Camera3D") as Camera3D if _rig != null else null
	return _base != null and _world != null and _route != null and _rig != null and _camera != null and _old_s03_controller != null and _route.has_method("pos_at") and _route.has_method("tangent_at") and _route.has_method("left_at") and _route.has_method("ground_y")

func _base_ready() -> bool:
	if bool(_base.get_meta(BASE_READY_META, false)):
		return true
	var distribution := _base.find_child("RightForestDistribution", true, false)
	if distribution != null and bool(distribution.get_meta("saisies_s03_right_forest_distribution_ready", false)):
		return true
	var parent := get_parent()
	return parent != null and bool(parent.get_meta(BASE_READY_META, false))

func _load_candidate() -> bool:
	if not FileAccess.file_exists(candidate_path):
		push_error("S04 linked-bends candidate is missing: %s" % candidate_path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(candidate_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("S04 linked-bends candidate is not a JSON object")
		return false
	_candidate_payload = parsed as Dictionary
	if String(_candidate_payload.get("status", "")) != REVIEW_STATUS or String(_candidate_payload.get("visual_acceptance", "")) != "pending":
		push_error("S04 linked-bends candidate status is not review-pending root selection")
		return false
	if bool(_candidate_payload.get("gps_calibrated", true)) or bool(_candidate_payload.get("formal_route_edit", true)):
		push_error("S04 linked-bends candidate must remain visual-estimate-only")
		return false
	var raw_anchors: Variant = _candidate_payload.get("anchors", [])
	if typeof(raw_anchors) != TYPE_ARRAY:
		push_error("S04 linked-bends candidate anchors must be an array")
		return false
	_anchors.clear()
	for raw_anchor in raw_anchors as Array:
		if typeof(raw_anchor) != TYPE_DICTIONARY:
			push_error("S04 linked-bends candidate anchor is not an object")
			return false
		var anchor: Dictionary = raw_anchor as Dictionary
		var video_seconds := float(anchor.get("video_seconds", NAN))
		var station := float(anchor.get("station_m", NAN))
		if not is_finite(video_seconds) or not is_finite(station):
			push_error("S04 linked-bends candidate anchor is non-finite")
			return false
		_anchors.append({"video_seconds": video_seconds, "station_m": station})
	if _anchors.size() != 5:
		push_error("S04 linked-bends candidate requires five 100..120s anchors")
		return false
	if absf(float(_anchors[0]["video_seconds"]) - FIRST_VIDEO_SECONDS) > 0.001 or absf(float(_anchors[0]["station_m"]) - 1340.0) > 0.001:
		push_error("S04 linked-bends candidate first endpoint is invalid")
		return false
	if absf(float(_anchors.back()["video_seconds"]) - LAST_VIDEO_SECONDS) > 0.001 or absf(float(_anchors.back()["station_m"]) - 1770.0) > 0.001:
		push_error("S04 linked-bends candidate last endpoint is invalid")
		return false
	for index in range(1, _anchors.size()):
		var previous: Dictionary = _anchors[index - 1]
		var current: Dictionary = _anchors[index]
		if float(current["video_seconds"]) <= float(previous["video_seconds"]) or float(current["station_m"]) <= float(previous["station_m"]):
			push_error("S04 linked-bends candidate anchors must be strictly monotonic")
			return false
	return _validate_candidate_interpolation()

func _validate_candidate_interpolation() -> bool:
	var previous_station := -INF
	var previous_video := FIRST_VIDEO_SECONDS
	for sample_index in range(0, 41):
		var ratio := float(sample_index) / 40.0
		var video_seconds := lerpf(FIRST_VIDEO_SECONDS, LAST_VIDEO_SECONDS, ratio)
		var station := _station_for_video_seconds(video_seconds)
		var round_trip_video := _video_seconds_for_station(station)
		if not is_finite(station) or station <= previous_station or round_trip_video < previous_video - 0.001 or absf(round_trip_video - video_seconds) > 0.01:
			push_error("S04 linked-bends candidate interpolation is not monotonic/continuous")
			return false
		previous_station = station
		previous_video = round_trip_video
	var tour_station := _station_for_video_seconds(FIRST_VIDEO_SECONDS)
	var tour_end := _station_for_video_seconds(LAST_VIDEO_SECONDS)
	var tour_step := maxf(preview_speed_kmh / 3.6 * 0.25, 0.001)
	var tour_video := FIRST_VIDEO_SECONDS
	while tour_station < tour_end - 0.001:
		var next_station := minf(tour_station + tour_step, tour_end)
		var next_video := _video_seconds_for_station(next_station)
		if next_station <= tour_station or next_video < tour_video - 0.001:
			push_error("S04 linked-bends 30 km/h preview tour is not continuous")
			return false
		tour_station = next_station
		tour_video = next_video
	return absf(tour_station - tour_end) <= 0.001 and absf(tour_video - LAST_VIDEO_SECONDS) <= 0.01

func _capture_original_state() -> void:
	if _original_captured:
		return
	_original_rig_process = _rig.is_processing()
	_original_rig_physics_process = _rig.is_physics_processing()
	_original_rig_auto_advance = bool(_rig.get("auto_advance"))
	_original_rig_cruise_speed_mps = float(_rig.get("cruise_speed_mps"))
	_original_rig_distance_m = float(_rig.get("distance_m"))
	_original_requested_scene_id = String(_rig.get("_requested_scene_id"))
	_original_rig_local_position = _rig.position
	_original_rig_local_rotation = _rig.rotation
	_original_rig_local_scale = _rig.scale
	_original_camera_local_position = _camera.position
	_original_camera_local_rotation = _camera.rotation
	_original_camera_local_scale = _camera.scale
	_original_camera_fov = _camera.fov
	_original_camera_current = _camera.current
	_original_old_controller_process = _old_s03_controller.is_processing()
	_original_old_controller_physics_process = _old_s03_controller.is_physics_processing()
	_original_captured = true

func _apply_review_pose() -> bool:
	if _route == null or _rig == null or _camera == null or _anchors.is_empty():
		return false
	var station := clampf(_current_station_m, float(_anchors[0]["station_m"]), float(_anchors.back()["station_m"]))
	var route_point: Vector3 = _route.call("pos_at", station)
	var tangent: Vector3 = Vector3(_route.call("tangent_at", station)).normalized()
	var left: Vector3 = Vector3(_route.call("left_at", station)).normalized()
	if tangent.length_squared() <= 0.000001 or left.length_squared() <= 0.000001 or not route_point.is_finite():
		return false
	_rig.set("auto_advance", false)
	_rig.set("distance_m", station)
	_rig.set("_requested_scene_id", "")
	_rig.global_position = route_point + left * lateral_m
	var heading := atan2(-tangent.x, -tangent.z)
	_rig.rotation = Vector3(deg_to_rad(pitch_deg), heading + deg_to_rad(yaw_deg), deg_to_rad(roll_deg))
	# Set the camera in world space after pitching the rig.  A local UP offset
	# would rotate forward and shift the view by roughly 0.23m at pitch -8°.
	_camera.global_position = route_point + left * lateral_m + Vector3.UP * camera_height_m
	_camera.rotation = Vector3.ZERO
	_camera.fov = fov_deg
	_camera.current = true
	_current_station_m = station
	_publish_pose_state()
	return is_finite(_rig.global_position.x) and is_finite(_rig.global_position.y) and is_finite(_rig.global_position.z)

func _publish_ready_state() -> void:
	set_meta("saisies_s04_linked_bends_review_ready", true)
	set_meta("saisies_s04_linked_bends_review_status", REVIEW_STATUS)
	set_meta("saisies_s04_linked_bends_visual_acceptance", "pending")
	set_meta("saisies_s04_linked_bends_candidate_file", candidate_path)
	set_meta("saisies_s04_linked_bends_camera_mode", "controlled_review_pose")
	set_meta("saisies_s04_linked_bends_preview_speed_kmh", preview_speed_kmh)
	_publish_pose_state()
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s04_linked_bends_review_ready", true)
		parent.set_meta("saisies_s04_linked_bends_review_status", REVIEW_STATUS)

func _publish_pose_state() -> void:
	set_meta("saisies_s04_linked_bends_video_seconds", _current_video_seconds)
	set_meta("saisies_s04_linked_bends_station_m", _current_station_m)
	set_meta("saisies_s04_linked_bends_fov_deg", fov_deg)
	set_meta("saisies_s04_linked_bends_height_m", camera_height_m)
	set_meta("saisies_s04_linked_bends_pitch_deg", pitch_deg)
	set_meta("saisies_s04_linked_bends_yaw_deg", yaw_deg)
	set_meta("saisies_s04_linked_bends_lateral_m", lateral_m)
	set_meta("saisies_s04_linked_bends_roll_deg", roll_deg)
	set_meta("saisies_s04_linked_bends_preview_active", _preview_active)
	set_meta("saisies_s04_linked_bends_preview_finished", _preview_finished)

func _station_for_video_seconds(video_seconds: float) -> float:
	if _anchors.is_empty():
		return NAN
	if video_seconds <= float(_anchors[0]["video_seconds"]):
		return float(_anchors[0]["station_m"])
	for index in range(1, _anchors.size()):
		var previous: Dictionary = _anchors[index - 1]
		var current: Dictionary = _anchors[index]
		if video_seconds <= float(current["video_seconds"]):
			var span := float(current["video_seconds"]) - float(previous["video_seconds"])
			return lerpf(float(previous["station_m"]), float(current["station_m"]), (video_seconds - float(previous["video_seconds"])) / span)
	return float(_anchors.back()["station_m"])

func _video_seconds_for_station(station: float) -> float:
	if _anchors.is_empty():
		return NAN
	if station <= float(_anchors[0]["station_m"]):
		return float(_anchors[0]["video_seconds"])
	for index in range(1, _anchors.size()):
		var previous: Dictionary = _anchors[index - 1]
		var current: Dictionary = _anchors[index]
		if station <= float(current["station_m"]):
			var span := float(current["station_m"]) - float(previous["station_m"])
			return lerpf(float(previous["video_seconds"]), float(current["video_seconds"]), (station - float(previous["station_m"])) / span)
	return float(_anchors.back()["video_seconds"])

func _pose_record(ok: bool) -> Dictionary:
	return {"ok": ok, "mode": "preview_tour" if _preview_active else "fixed_video_time", "video_seconds": _current_video_seconds, "station_m": _current_station_m, "fov_deg": fov_deg, "height_m": camera_height_m, "pitch_deg": pitch_deg, "yaw_deg": yaw_deg, "lateral_m": lateral_m, "roll_deg": roll_deg, "visual_acceptance": "pending"}

func _parse_args() -> void:
	for argument in OS.get_cmdline_user_args():
		var arg := String(argument)
		if arg.begins_with("--s04-seconds="):
			default_video_seconds = float(arg.trim_prefix("--s04-seconds="))
		elif arg == "--s04-preview-tour":
			_preview_active = true

func _has_preview_argument() -> bool:
	return _preview_active

func _retry(message: String) -> void:
	_attempts += 1
	if _attempts < 240:
		call_deferred("_retry_next_frame")
		return
	set_meta("saisies_s04_linked_bends_review_ready", false)
	set_meta("saisies_s04_linked_bends_review_error", message)
	push_error(message)

func _retry_next_frame() -> void:
	await get_tree().process_frame
	_try_initialize()
