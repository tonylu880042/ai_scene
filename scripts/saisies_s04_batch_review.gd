extends "res://scripts/saisies_s04_late_bends_review.gd"

## R35 integrated S04 batch review.
##
## The R34 late-bends controller remains the base.  This wrapper only copies
## its saved pose state, extends the local anchor list back to 80 seconds, and
## controls the two new continuation modules placed beside the base scene.

@export_file("*.json") var batch_candidate_path := "res://data/saisies_s04_batch.json"
@export var batch_default_video_seconds := 130.0

const BATCH_REVIEW_STATUS := "root_selected_for_integrated_review"
const BATCH_FIRST_VIDEO_SECONDS := 80.0
const BATCH_LAST_VIDEO_SECONDS := 135.0
const BATCH_FIRST_STATION_M := 1030.0
const BATCH_LAST_STATION_M := 1950.0

var _batch_enabled := true
var _batch_off_requested := false

func _ready() -> void:
	process_priority = -120
	_batch_off_requested = _has_command_line_flag("--s04-batch-off")
	_batch_enabled = not _batch_off_requested
	_set_batch_module_flags(_batch_enabled)
	_parse_args()
	call_deferred("_try_initialize")

func get_batch_modules() -> Dictionary:
	var root := get_parent()
	return {
		"forest": root.get_node_or_null("ForestContinuation") if root != null else null,
		"guardrail": root.get_node_or_null("GuardrailContinuation") if root != null else null,
	}

func set_batch_enabled(enabled: bool) -> bool:
	_batch_enabled = enabled
	_batch_off_requested = not enabled
	_set_batch_module_flags(enabled)
	if enabled:
		_reactivate_batch_module("forest", "_try_build_s04")
		_reactivate_batch_module("guardrail", "_try_build")
	else:
		_update_batch_module_visibility()
	_publish_batch_module_state()
	return true

func start_preview_tour() -> bool:
	if not _initialized or _released:
		return false
	_preview_active = true
	_preview_finished = false
	_current_video_seconds = BATCH_FIRST_VIDEO_SECONDS
	_current_station_m = _station_for_video_seconds(BATCH_FIRST_VIDEO_SECONDS)
	set_meta("saisies_s04_batch_preview_tour_finished", false)
	return _apply_review_pose()

func _base_ready() -> bool:
	var root := get_parent()
	if _base == null or root == null:
		return false
	var late := _base.find_child("S04LateBendsReview", true, false)
	var modules := get_batch_modules()
	var forest: Node = modules.get("forest") as Node
	var guardrail: Node = modules.get("guardrail") as Node
	var late_ready := late != null and bool(late.get_meta("saisies_s04_late_bends_ready", false))
	var forest_ready := forest != null and bool(forest.get_meta("saisies_s04_forest_ready", false))
	var guardrail_ready := guardrail != null and bool(guardrail.get_meta("saisies_s04_bend_guardrail_ready", false))
	return late_ready and forest_ready and guardrail_ready

func _load_candidate() -> bool:
	if not FileAccess.file_exists(batch_candidate_path):
		push_error("S04 batch candidate is missing: %s" % batch_candidate_path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(batch_candidate_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("S04 batch candidate is not a JSON object")
		return false
	_candidate_payload = parsed as Dictionary
	if String(_candidate_payload.get("status", "")) != BATCH_REVIEW_STATUS or String(_candidate_payload.get("visual_acceptance", "")) != "pending":
		push_error("S04 batch candidate status is not review-pending root selection")
		return false
	if bool(_candidate_payload.get("gps_calibrated", true)) or bool(_candidate_payload.get("formal_route_edit", true)):
		push_error("S04 batch candidate must remain visual-estimate-only")
		return false
	var raw_anchors: Variant = _candidate_payload.get("anchors", [])
	if typeof(raw_anchors) != TYPE_ARRAY:
		push_error("S04 batch candidate anchors must be an array")
		return false
	_anchors.clear()
	for raw_anchor in raw_anchors as Array:
		if typeof(raw_anchor) != TYPE_DICTIONARY:
			push_error("S04 batch candidate anchor is not an object")
			return false
		var anchor: Dictionary = raw_anchor as Dictionary
		var video_seconds := float(anchor.get("video_seconds", NAN))
		var station := float(anchor.get("station_m", NAN))
		if not is_finite(video_seconds) or not is_finite(station):
			push_error("S04 batch candidate anchor is non-finite")
			return false
		_anchors.append({"video_seconds": video_seconds, "station_m": station})
	if _anchors.size() != 11 or not _validate_batch_anchors():
		return false
	return _validate_batch_interpolation()

func _validate_batch_anchors() -> bool:
	var expected := [
		[80.0, 1030.0], [90.0, 1190.0], [95.0, 1280.0], [100.0, 1340.0],
		[105.0, 1435.0], [110.0, 1540.0], [115.0, 1630.0], [120.0, 1770.0],
		[125.0, 1830.0], [130.0, 1890.0], [135.0, 1950.0],
	]
	for index in range(_anchors.size()):
		var anchor: Dictionary = _anchors[index]
		if absf(float(anchor["video_seconds"]) - float(expected[index][0])) > 0.001 or absf(float(anchor["station_m"]) - float(expected[index][1])) > 0.001:
			push_error("S04 batch anchor %d differs from the selected batch candidate" % index)
			return false
		if index > 0:
			var previous: Dictionary = _anchors[index - 1]
			if float(anchor["video_seconds"]) <= float(previous["video_seconds"]) or float(anchor["station_m"]) <= float(previous["station_m"]):
				push_error("S04 batch anchors must be strictly monotonic")
				return false
	return true

func _validate_batch_interpolation() -> bool:
	var previous_station := -INF
	var previous_video := BATCH_FIRST_VIDEO_SECONDS
	for sample_index in range(0, 111):
		var ratio := float(sample_index) / 110.0
		var video_seconds := lerpf(BATCH_FIRST_VIDEO_SECONDS, BATCH_LAST_VIDEO_SECONDS, ratio)
		var station := _station_for_video_seconds(video_seconds)
		var round_trip_video := _video_seconds_for_station(station)
		if not is_finite(station) or station <= previous_station or round_trip_video < previous_video - 0.001 or absf(round_trip_video - video_seconds) > 0.01:
			push_error("S04 batch interpolation is not monotonic/continuous")
			return false
		previous_station = station
		previous_video = round_trip_video
	var tour_station := _station_for_video_seconds(BATCH_FIRST_VIDEO_SECONDS)
	var tour_end := _station_for_video_seconds(BATCH_LAST_VIDEO_SECONDS)
	var tour_step := maxf(preview_speed_kmh / 3.6 * 0.25, 0.001)
	var tour_video := BATCH_FIRST_VIDEO_SECONDS
	while tour_station < tour_end - 0.001:
		var next_station := minf(tour_station + tour_step, tour_end)
		var next_video := _video_seconds_for_station(next_station)
		if next_station <= tour_station or next_video < tour_video - 0.001:
			push_error("S04 batch 30 km/h preview tour is not continuous")
			return false
		tour_station = next_station
		tour_video = next_video
	return absf(tour_station - tour_end) <= 0.001 and absf(tour_video - BATCH_LAST_VIDEO_SECONDS) <= 0.01

func _capture_original_state() -> void:
	super._capture_original_state()
	set_meta("saisies_s04_batch_saved_base_anchor_count", _old_r31_anchors.size())
	set_meta("saisies_s04_batch_saved_base_video_seconds", _old_r31_video_seconds)
	set_meta("saisies_s04_batch_saved_base_station_m", _old_r31_station_m)

func _settle_and_apply() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if _released:
		_settling = false
		return
	await get_tree().process_frame
	await get_tree().process_frame
	_current_video_seconds = clampf(batch_default_video_seconds, BATCH_FIRST_VIDEO_SECONDS, BATCH_LAST_VIDEO_SECONDS)
	_current_station_m = _station_for_video_seconds(_current_video_seconds)
	if _has_preview_argument():
		_preview_active = true
		_preview_finished = false
		_current_video_seconds = BATCH_FIRST_VIDEO_SECONDS
		_current_station_m = _station_for_video_seconds(BATCH_FIRST_VIDEO_SECONDS)
	if not _apply_review_pose():
		_settling = false
		_retry("S04 batch review could not apply selected camera pose")
		return
	_initialized = true
	_settling = false
	_publish_ready_state()

func _process(delta: float) -> void:
	super._process(delta)
	if _preview_finished:
		set_meta("saisies_s04_batch_preview_tour_finished", true)
		set_meta("saisies_s04_batch_preview_tour_end_video_seconds", BATCH_LAST_VIDEO_SECONDS)
		set_meta("saisies_s04_batch_preview_tour_end_station_m", BATCH_LAST_STATION_M)
	_update_batch_module_visibility()

func apply_video_time(video_seconds: float) -> Dictionary:
	if not is_finite(video_seconds):
		return {"ok": false, "error": "video_seconds must be finite"}
	_current_video_seconds = clampf(video_seconds, BATCH_FIRST_VIDEO_SECONDS, BATCH_LAST_VIDEO_SECONDS)
	_current_station_m = _station_for_video_seconds(_current_video_seconds)
	_preview_active = false
	_preview_finished = false
	if not _initialized or _released:
		return {"ok": false, "error": "batch review controller is not ready", "video_seconds": _current_video_seconds, "station_m": _current_station_m}
	var ok := _apply_review_pose()
	return _pose_record(ok)

func _publish_ready_state() -> void:
	super._publish_ready_state()
	set_meta("saisies_s04_batch_ready", true)
	set_meta("saisies_s04_batch_status", BATCH_REVIEW_STATUS)
	set_meta("saisies_s04_batch_visual_acceptance", "pending")
	set_meta("saisies_s04_batch_candidate_file", batch_candidate_path)
	set_meta("saisies_s04_batch_camera_mode", "controlled_review_pose")
	set_meta("saisies_s04_batch_anchor_count", _anchors.size())
	set_meta("saisies_s04_batch_preview_speed_kmh", preview_speed_kmh)
	set_meta("saisies_s04_batch_first_video_seconds", BATCH_FIRST_VIDEO_SECONDS)
	set_meta("saisies_s04_batch_first_station_m", BATCH_FIRST_STATION_M)
	set_meta("saisies_s04_batch_last_video_seconds", BATCH_LAST_VIDEO_SECONDS)
	set_meta("saisies_s04_batch_last_station_m", BATCH_LAST_STATION_M)
	set_meta("saisies_s04_batch_enabled", _batch_enabled)
	_publish_batch_module_state()
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s04_batch_ready", true)
		parent.set_meta("saisies_s04_batch_status", BATCH_REVIEW_STATUS)

func _publish_pose_state() -> void:
	super._publish_pose_state()
	set_meta("saisies_s04_batch_video_seconds", _current_video_seconds)
	set_meta("saisies_s04_batch_station_m", _current_station_m)
	set_meta("saisies_s04_batch_preview_active", _preview_active)
	set_meta("saisies_s04_batch_preview_finished", _preview_finished)
	set_meta("saisies_s04_batch_enabled", _batch_enabled)

func _pose_record(ok: bool) -> Dictionary:
	var record := super._pose_record(ok)
	record["video_seconds"] = _current_video_seconds
	record["station_m"] = _current_station_m
	record["mode"] = "preview_tour" if _preview_active else "fixed_video_time"
	record["visual_acceptance"] = "pending"
	return record

func _parse_args() -> void:
	for argument in OS.get_cmdline_user_args():
		var arg := String(argument)
		if arg.begins_with("--s04-batch-seconds="):
			batch_default_video_seconds = float(arg.trim_prefix("--s04-batch-seconds="))
		elif arg == "--s04-batch-tour":
			_preview_active = true

func _has_command_line_flag(flag: String) -> bool:
	for argument in OS.get_cmdline_user_args():
		if String(argument) == flag:
			return true
	return false

func _has_preview_argument() -> bool:
	return _preview_active

func _set_batch_module_flags(enabled: bool) -> void:
	var modules := get_batch_modules()
	for module_variant in modules.values():
		var module := module_variant as Node
		if module == null:
			continue
		if module.has_method("set"):
			module.set("enable_refinement", enabled)
			module.set("_off_requested", not enabled)

func _reactivate_batch_module(kind: String, build_method: String) -> void:
	var modules := get_batch_modules()
	var module := modules.get(kind) as Node
	if module == null:
		return
	module.set("enable_refinement", true)
	module.set("_off_requested", false)
	var needs_build := false
	if kind == "forest":
		needs_build = not bool(module.get("_candidate_built"))
	else:
		needs_build = module.get("_beam_instance") == null
	if needs_build:
		module.set("_ready_published", false)
		module.set("_built", false)
		if build_method == "_try_build_s04":
			module.set("_candidate_built", false)
		module.call_deferred(build_method)

func _update_batch_module_visibility() -> void:
	var modules := get_batch_modules()
	var forest := modules.get("forest") as Node
	var guardrail := modules.get("guardrail") as Node
	if forest != null and forest.has_method("_update_s04_lod_gate"):
		forest.call("_update_s04_lod_gate")
	if guardrail != null and guardrail.has_method("_update_visibility_gate"):
		guardrail.call("_update_visibility_gate")

func _publish_batch_module_state() -> void:
	var modules := get_batch_modules()
	var forest := modules.get("forest") as Node
	var guardrail := modules.get("guardrail") as Node
	set_meta("saisies_s04_batch_forest_ready", forest != null and bool(forest.get_meta("saisies_s04_forest_ready", false)))
	set_meta("saisies_s04_batch_forest_enabled", forest != null and bool(forest.get_meta("saisies_s04_forest_enabled", false)))
	set_meta("saisies_s04_batch_forest_count", int(forest.get_meta("saisies_s04_forest_new_count", 0)) if forest != null else 0)
	set_meta("saisies_s04_batch_guardrail_ready", guardrail != null and bool(guardrail.get_meta("saisies_s04_bend_guardrail_ready", false)))
	set_meta("saisies_s04_batch_guardrail_enabled", guardrail != null and bool(guardrail.get_meta("saisies_s04_bend_guardrail_enabled", false)))
	set_meta("saisies_s04_batch_guardrail_beam_count", int(guardrail.get_meta("saisies_s04_bend_guardrail_beam_count", 0)) if guardrail != null else 0)

func _retry(message: String) -> void:
	_attempts += 1
	if _attempts < 240:
		call_deferred("_retry_next_frame")
		return
	set_meta("saisies_s04_batch_ready", false)
	set_meta("saisies_s04_batch_error", message)
	push_error(message)
