extends "res://scripts/saisies_s04_linked_bends_review.gd"

## R34 late-bends review wrapper.
##
## This controller reuses the frozen R31 pose implementation and only extends
## its local time/station candidate through 135 seconds.  R33 remains the
## complete scenery base; no route, terrain, camera asset, or forest data is
## edited here.

@export var forest_base_path: NodePath = NodePath("../ForestBase")
@export_file("*.json") var late_candidate_path := "res://data/saisies_s04_late_bends.json"
@export var late_default_video_seconds := 130.0

const LATE_REVIEW_STATUS := "root_selected_for_integrated_review"
const LATE_FIRST_VIDEO_SECONDS := 100.0
const LATE_FOREST_ENDPOINT_SECONDS := 120.0
const LATE_LAST_VIDEO_SECONDS := 135.0
const LATE_FOREST_ENDPOINT_STATION_M := 1770.0
const LATE_LAST_STATION_M := 1950.0
const LATE_PREVIEW_START_SECONDS := 120.0

var _old_r31_anchors: Array[Dictionary] = []
var _old_r31_video_seconds := 110.0
var _old_r31_station_m := 1540.0
var _old_r31_preview_active := false
var _old_r31_preview_finished := false
var _old_r31_initialized := false
var _old_r31_released := false
var _old_r31_state_captured := false

func _ready() -> void:
	process_priority = -100
	_parse_args()
	call_deferred("_try_initialize")

func _base_ready() -> bool:
	if _base == null:
		return false
	if bool(_base.get_meta("saisies_s04_forest_review_ready", false)):
		return true
	var forest_distribution := _base.find_child("ForestDistribution", true, false)
	if forest_distribution != null and bool(forest_distribution.get_meta("saisies_s04_forest_ready", false)):
		return true
	var parent := get_parent()
	return parent != null and bool(parent.get_meta("saisies_s04_forest_review_ready", false))

func _load_candidate() -> bool:
	if not FileAccess.file_exists(late_candidate_path):
		push_error("S04 late-bends candidate is missing: %s" % late_candidate_path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(late_candidate_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("S04 late-bends candidate is not a JSON object")
		return false
	_candidate_payload = parsed as Dictionary
	if String(_candidate_payload.get("status", "")) != LATE_REVIEW_STATUS or String(_candidate_payload.get("visual_acceptance", "")) != "pending":
		push_error("S04 late-bends candidate status is not review-pending root selection")
		return false
	if bool(_candidate_payload.get("gps_calibrated", true)) or bool(_candidate_payload.get("formal_route_edit", true)):
		push_error("S04 late-bends candidate must remain visual-estimate-only")
		return false
	var raw_anchors: Variant = _candidate_payload.get("anchors", [])
	if typeof(raw_anchors) != TYPE_ARRAY:
		push_error("S04 late-bends candidate anchors must be an array")
		return false
	_anchors.clear()
	for raw_anchor in raw_anchors as Array:
		if typeof(raw_anchor) != TYPE_DICTIONARY:
			push_error("S04 late-bends candidate anchor is not an object")
			return false
		var anchor: Dictionary = raw_anchor as Dictionary
		var video_seconds := float(anchor.get("video_seconds", NAN))
		var station := float(anchor.get("station_m", NAN))
		if not is_finite(video_seconds) or not is_finite(station):
			push_error("S04 late-bends candidate anchor is non-finite")
			return false
		_anchors.append({"video_seconds": video_seconds, "station_m": station})
	if _anchors.size() != 8:
		push_error("S04 late-bends candidate requires eight 100..135s anchors")
		return false
	if not _validate_late_anchors():
		return false
	return _validate_late_interpolation()

func _validate_late_anchors() -> bool:
	var expected := [
		[100.0, 1340.0],
		[105.0, 1435.0],
		[110.0, 1540.0],
		[115.0, 1630.0],
		[120.0, 1770.0],
		[125.0, 1830.0],
		[130.0, 1890.0],
		[135.0, 1950.0],
	]
	for index in range(_anchors.size()):
		var anchor: Dictionary = _anchors[index]
		if absf(float(anchor["video_seconds"]) - float(expected[index][0])) > 0.001 or absf(float(anchor["station_m"]) - float(expected[index][1])) > 0.001:
			push_error("S04 late-bends anchor %d differs from the selected R31/late candidate" % index)
			return false
		if index > 0:
			var previous: Dictionary = _anchors[index - 1]
			if float(anchor["video_seconds"]) <= float(previous["video_seconds"]) or float(anchor["station_m"]) <= float(previous["station_m"]):
				push_error("S04 late-bends anchors must be strictly monotonic")
				return false
	return true

func _validate_late_interpolation() -> bool:
	var previous_station := -INF
	var previous_video := LATE_FIRST_VIDEO_SECONDS
	for sample_index in range(0, 71):
		var ratio := float(sample_index) / 70.0
		var video_seconds := lerpf(LATE_FIRST_VIDEO_SECONDS, LATE_LAST_VIDEO_SECONDS, ratio)
		var station := _station_for_video_seconds(video_seconds)
		var round_trip_video := _video_seconds_for_station(station)
		if not is_finite(station) or station <= previous_station or round_trip_video < previous_video - 0.001 or absf(round_trip_video - video_seconds) > 0.01:
			push_error("S04 late-bends interpolation is not monotonic/continuous")
			return false
		previous_station = station
		previous_video = round_trip_video
	var tour_station := _station_for_video_seconds(LATE_PREVIEW_START_SECONDS)
	var tour_end := _station_for_video_seconds(LATE_LAST_VIDEO_SECONDS)
	var tour_step := maxf(preview_speed_kmh / 3.6 * 0.25, 0.001)
	var tour_video := LATE_PREVIEW_START_SECONDS
	while tour_station < tour_end - 0.001:
		var next_station := minf(tour_station + tour_step, tour_end)
		var next_video := _video_seconds_for_station(next_station)
		if next_station <= tour_station or next_video < tour_video - 0.001:
			push_error("S04 late-bends 30 km/h preview tour is not continuous")
			return false
		tour_station = next_station
		tour_video = next_video
	return absf(tour_station - tour_end) <= 0.001 and absf(tour_video - LATE_LAST_VIDEO_SECONDS) <= 0.01

func _capture_original_state() -> void:
	super._capture_original_state()
	if _old_s03_controller == null or _old_r31_state_captured:
		return
	_old_r31_anchors = _copy_anchor_array(_old_s03_controller.get("_anchors"))
	_old_r31_video_seconds = float(_old_s03_controller.get("_current_video_seconds"))
	_old_r31_station_m = float(_old_s03_controller.get("_current_station_m"))
	_old_r31_preview_active = bool(_old_s03_controller.get("_preview_active"))
	_old_r31_preview_finished = bool(_old_s03_controller.get("_preview_finished"))
	_old_r31_initialized = bool(_old_s03_controller.get("_initialized"))
	_old_r31_released = bool(_old_s03_controller.get("_released"))
	_old_r31_state_captured = true
	set_meta("saisies_s04_late_bends_old_r31_anchor_count", _old_r31_anchors.size())
	set_meta("saisies_s04_late_bends_old_r31_video_seconds", _old_r31_video_seconds)
	set_meta("saisies_s04_late_bends_old_r31_station_m", _old_r31_station_m)

func _settle_and_apply() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if _released:
		_settling = false
		return
	await get_tree().process_frame
	await get_tree().process_frame
	_current_video_seconds = clampf(late_default_video_seconds, LATE_FIRST_VIDEO_SECONDS, LATE_LAST_VIDEO_SECONDS)
	_current_station_m = _station_for_video_seconds(_current_video_seconds)
	if _has_preview_argument():
		_preview_active = true
		_preview_finished = false
		_current_video_seconds = LATE_PREVIEW_START_SECONDS
		_current_station_m = _station_for_video_seconds(LATE_PREVIEW_START_SECONDS)
	if not _apply_review_pose():
		_settling = false
		_retry("S04 late-bends review could not apply selected camera pose")
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
			_station_for_video_seconds(LATE_LAST_VIDEO_SECONDS)
		)
		_current_video_seconds = _video_seconds_for_station(_current_station_m)
		if _current_station_m >= _station_for_video_seconds(LATE_LAST_VIDEO_SECONDS) - 0.0001:
			_current_station_m = _station_for_video_seconds(LATE_LAST_VIDEO_SECONDS)
			_current_video_seconds = LATE_LAST_VIDEO_SECONDS
			_preview_active = false
			_preview_finished = true
			set_meta("saisies_s04_late_bends_preview_tour_finished", true)
	_apply_review_pose()

func apply_video_time(video_seconds: float) -> Dictionary:
	if not is_finite(video_seconds):
		return {"ok": false, "error": "video_seconds must be finite"}
	_current_video_seconds = clampf(video_seconds, LATE_FIRST_VIDEO_SECONDS, LATE_LAST_VIDEO_SECONDS)
	_current_station_m = _station_for_video_seconds(_current_video_seconds)
	_preview_active = false
	_preview_finished = false
	if not _initialized or _released:
		return {"ok": false, "error": "late-bends review controller is not ready", "video_seconds": _current_video_seconds, "station_m": _current_station_m}
	var ok := _apply_review_pose()
	return _pose_record(ok)

func release_camera() -> bool:
	var result := super.release_camera()
	_restore_old_r31_state()
	return result

func _restore_old_r31_state() -> void:
	if not _old_r31_state_captured or not is_instance_valid(_old_s03_controller):
		return
	_old_s03_controller.set("_anchors", _old_r31_anchors.duplicate(true))
	_old_s03_controller.set("_current_video_seconds", _old_r31_video_seconds)
	_old_s03_controller.set("_current_station_m", _old_r31_station_m)
	_old_s03_controller.set("_preview_active", _old_r31_preview_active)
	_old_s03_controller.set("_preview_finished", _old_r31_preview_finished)
	_old_s03_controller.set("_initialized", _old_r31_initialized)
	_old_s03_controller.set("_released", _old_r31_released)
	set_meta("saisies_s04_late_bends_old_r31_restored", true)

func _publish_ready_state() -> void:
	super._publish_ready_state()
	set_meta("saisies_s04_late_bends_ready", true)
	set_meta("saisies_s04_late_bends_status", LATE_REVIEW_STATUS)
	set_meta("saisies_s04_late_bends_visual_acceptance", "pending")
	set_meta("saisies_s04_late_bends_candidate_file", late_candidate_path)
	set_meta("saisies_s04_late_bends_camera_mode", "controlled_review_pose")
	set_meta("saisies_s04_late_bends_preview_speed_kmh", preview_speed_kmh)
	set_meta("saisies_s04_late_bends_anchor_count", _anchors.size())
	set_meta("saisies_s04_late_bends_preserves_100_120", true)
	set_meta("saisies_s04_late_bends_120_endpoint_station_m", LATE_FOREST_ENDPOINT_STATION_M)
	set_meta("saisies_s04_late_bends_135_endpoint_station_m", LATE_LAST_STATION_M)
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s04_late_bends_ready", true)
		parent.set_meta("saisies_s04_late_bends_status", LATE_REVIEW_STATUS)

func _publish_pose_state() -> void:
	super._publish_pose_state()
	set_meta("saisies_s04_late_bends_video_seconds", _current_video_seconds)
	set_meta("saisies_s04_late_bends_station_m", _current_station_m)
	set_meta("saisies_s04_late_bends_fov_deg", fov_deg)
	set_meta("saisies_s04_late_bends_height_m", camera_height_m)
	set_meta("saisies_s04_late_bends_pitch_deg", pitch_deg)
	set_meta("saisies_s04_late_bends_yaw_deg", yaw_deg)
	set_meta("saisies_s04_late_bends_lateral_m", lateral_m)
	set_meta("saisies_s04_late_bends_roll_deg", roll_deg)
	set_meta("saisies_s04_late_bends_preview_active", _preview_active)
	set_meta("saisies_s04_late_bends_preview_finished", _preview_finished)

func _pose_record(ok: bool) -> Dictionary:
	var record := super._pose_record(ok)
	record["video_seconds"] = _current_video_seconds
	record["station_m"] = _current_station_m
	record["mode"] = "preview_tour" if _preview_active else "fixed_video_time"
	record["visual_acceptance"] = "pending"
	return record

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

func _parse_args() -> void:
	for argument in OS.get_cmdline_user_args():
		var arg := String(argument)
		if arg.begins_with("--s04-late-seconds="):
			late_default_video_seconds = float(arg.trim_prefix("--s04-late-seconds="))
		elif arg == "--s04-late-tour":
			_preview_active = true

func _retry(message: String) -> void:
	_attempts += 1
	if _attempts < 240:
		call_deferred("_retry_next_frame")
		return
	set_meta("saisies_s04_late_bends_ready", false)
	set_meta("saisies_s04_late_bends_error", message)
	push_error(message)

func _copy_anchor_array(value: Variant) -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	if typeof(value) != TYPE_ARRAY:
		return copy
	for entry in value as Array:
		if typeof(entry) == TYPE_DICTIONARY:
			copy.append((entry as Dictionary).duplicate(true))
	return copy
