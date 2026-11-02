extends Node3D

## Whole-route release controller for the frozen R35 geographic world.
##
## This node is the only runtime camera writer in the release scene.  It keeps
## the accepted S01-S04 modules and the two whole-route scenery workers beside
## the R14 world, disables historical review pose writers, and exposes
## source-view and configurable traversal hooks for one continuous run.

@export var world_path: NodePath
@export var release_base_path: NodePath
@export_file("*.json") var release_candidate_path := "res://data/saisies_release.json"
@export var default_video_seconds := 5.0
@export var preview_speed_kmh := 30.0
@export var camera_height_m := 1.65
@export var default_fov_deg := 78.0
@export var default_pitch_deg := -8.0
@export var default_yaw_deg := 0.0
@export var default_lateral_m := -1.8
@export var roll_deg := 0.0
@export var release_forest_path: NodePath
@export var release_roadside_path: NodePath
@export var release_terminals_path: NodePath

const RELEASE_STATUS := "root_selected_for_integrated_review"
const FIRST_VIDEO_SECONDS := 0.0
const LAST_VIDEO_SECONDS := 920.067
const EXPECTED_ROUTE_LENGTH_M := 14615.087922
const DEFAULT_MAX_RETRIES := 240
const SOURCE_VIEW_COUNT := 18
const R35_MAPPING_BRIDGE_SECONDS := 15.0

var _world: Node3D
var _release_base: Node
var _route: Node
var _rig: Node3D
var _camera: Camera3D
var _candidate: Dictionary = {}
var _source_views: Array[Dictionary] = []
var _release_mapping_anchors: Array[Dictionary] = []
var _current_video_seconds := 0.0
var _current_station_m := 0.0
var _preview_active := false
var _preview_finished := false
var _release_enabled := true
var _initialized := false
var _released := false
var _attempts := 0
var _quit_after_ready := false
var _legacy_source_pose_enabled := true

var _original_captured := false
var _original_rig_process := false
var _original_rig_physics_process := false
var _original_rig_auto_advance := true
var _original_rig_cruise_speed_mps := 17.0
var _original_rig_distance_m := 0.0
var _original_rig_requested_scene_id := ""
var _original_rig_position := Vector3.ZERO
var _original_rig_rotation := Vector3.ZERO
var _original_rig_scale := Vector3.ONE
var _original_camera_position := Vector3.ZERO
var _original_camera_rotation := Vector3.ZERO
var _original_camera_scale := Vector3.ONE
var _original_camera_fov := 78.0
var _original_camera_current := false
var _writer_states: Array[Dictionary] = []

func _ready() -> void:
	process_priority = -220
	_parse_args()
	_release_enabled = _release_enabled and not _has_flag("--saisies-release-off")
	call_deferred("_try_initialize")

func _try_initialize() -> void:
	if _initialized or _released:
		return
	if not _resolve_nodes():
		_retry("release controller dependencies are incomplete")
		return
	if not bool(_route.call("route_ready")):
		_retry("release controller is waiting for the geographic route")
		return
	# R35/R34/R31 review builders can finish on deferred frames after the
	# geographic route is ready.  Do not capture or disable their pose writers
	# until the complete release base has published its batch-ready contract;
	# otherwise a late builder can re-enable a historical camera writer.
	if _release_base == null or not bool(_release_base.get_meta("saisies_s04_batch_ready", false)):
		_retry("release controller is waiting for R35 batch readiness")
		return
	if not _load_candidate():
		return
	if not _validate_route_contract():
		_retry("release controller route length does not match the release candidate")
		return
	if not _load_release_mapping_anchors():
		_retry("release controller could not load the R35 80..135s mapping")
		return
	_capture_original_state()
	if _release_enabled:
		_disable_historical_pose_writers()
	_set_scenery_visible(_release_enabled)
	_recover_release_module_builds()
	_initialized = true
	_current_video_seconds = clampf(default_video_seconds, FIRST_VIDEO_SECONDS, LAST_VIDEO_SECONDS)
	_current_station_m = _station_for_video_seconds(_current_video_seconds)
	if _has_source_argument():
		_current_video_seconds = _source_seconds_from_argument()
		_current_station_m = _station_for_video_seconds(_current_video_seconds)
	if _preview_active:
		_current_video_seconds = FIRST_VIDEO_SECONDS
		_current_station_m = _station_for_video_seconds(FIRST_VIDEO_SECONDS)
		_preview_finished = false
		_legacy_source_pose_enabled = false
	else:
		# A fixed launch/source-view request is allowed to use the accepted legacy
		# S01-S03 helper pose. Continuous tours stay on release interpolation so
		# they cannot jump at an exact source timestamp.
		_legacy_source_pose_enabled = true
	if _release_enabled:
		_apply_release_pose()
	_publish_ready_state()
	if _quit_after_ready:
		call_deferred("_quit_after_ready_frame")

func _process(delta: float) -> void:
	if not _initialized or _released or not _release_enabled:
		return
	if _preview_active:
		_current_station_m = minf(
			_current_station_m + maxf(delta, 0.0) * maxf(preview_speed_kmh, 0.0) / 3.6,
			float(_route.get("length_m"))
		)
		_current_video_seconds = _video_seconds_for_station(_current_station_m)
		if _current_station_m >= float(_route.get("length_m")) - 0.0001:
			_current_station_m = float(_route.get("length_m"))
			_current_video_seconds = LAST_VIDEO_SECONDS
			_preview_active = false
			_preview_finished = true
			set_meta("saisies_release_preview_tour_finished", true)
	_apply_release_pose()
	_recover_release_module_builds()
	_publish_pose_state()
	_publish_module_state()

func apply_video_time(video_seconds: float) -> Dictionary:
	if not is_finite(video_seconds):
		return {"ok": false, "error": "video_seconds must be finite"}
	_current_video_seconds = clampf(video_seconds, FIRST_VIDEO_SECONDS, LAST_VIDEO_SECONDS)
	_current_station_m = _station_for_video_seconds(_current_video_seconds)
	_preview_active = false
	_preview_finished = false
	_legacy_source_pose_enabled = true
	if not _initialized or _released or not _release_enabled:
		return {"ok": false, "error": "release controller is not enabled and ready", "video_seconds": _current_video_seconds, "station_m": _current_station_m}
	var ok := _apply_release_pose()
	_publish_pose_state()
	return _pose_record(ok)

func apply_source_view(scene_id: String) -> Dictionary:
	var wanted := scene_id.to_upper()
	_legacy_source_pose_enabled = true
	for view in _source_views:
		if String(view.get("scene_id", "")).to_upper() == wanted:
			return apply_video_time(float(view.get("video_seconds", NAN)))
	return {"ok": false, "error": "unknown release source view: %s" % scene_id}

func get_source_views() -> Array[Dictionary]:
	return _source_views.duplicate(true)

func get_release_modules() -> Dictionary:
	return {
		"forest": get_node_or_null(release_forest_path),
		"roadside": get_node_or_null(release_roadside_path),
		"terminals": get_node_or_null(release_terminals_path)
	}

func start_preview_tour() -> bool:
	if not _initialized or _released or not _release_enabled:
		return false
	_preview_active = true
	_preview_finished = false
	_legacy_source_pose_enabled = false
	_current_video_seconds = FIRST_VIDEO_SECONDS
	_current_station_m = _station_for_video_seconds(FIRST_VIDEO_SECONDS)
	set_meta("saisies_release_preview_tour_finished", false)
	return _apply_release_pose()

func set_release_enabled(enabled: bool) -> bool:
	_release_enabled = enabled
	_set_scenery_visible(enabled)
	if not enabled:
		_preview_active = false
		_publish_pose_state()
		_publish_module_state()
		return true
	if not _initialized or _released:
		return false
	_disable_historical_pose_writers()
	_legacy_source_pose_enabled = not _preview_active
	_apply_release_pose()
	_publish_pose_state()
	_publish_module_state()
	return true

func release_camera() -> bool:
	if _released:
		return true
	_released = true
	_preview_active = false
	_initialized = false
	if _original_captured:
		if is_instance_valid(_rig):
			_rig.position = _original_rig_position
			_rig.rotation = _original_rig_rotation
			_rig.scale = _original_rig_scale
			_rig.set("auto_advance", _original_rig_auto_advance)
			_rig.set("cruise_speed_mps", _original_rig_cruise_speed_mps)
			_rig.set("distance_m", _original_rig_distance_m)
			_rig.set("_requested_scene_id", _original_rig_requested_scene_id)
			_rig.set_process(_original_rig_process)
			_rig.set_physics_process(_original_rig_physics_process)
		if is_instance_valid(_camera):
			_camera.position = _original_camera_position
			_camera.rotation = _original_camera_rotation
			_camera.scale = _original_camera_scale
			_camera.fov = _original_camera_fov
			_camera.current = _original_camera_current
		_restore_pose_writers()
	_set_scenery_visible(false)
	set_meta("saisies_release_released", true)
	set_process(false)
	return true

func _resolve_nodes() -> bool:
	_release_base = get_node_or_null(release_base_path)
	_world = get_node_or_null(world_path) as Node3D
	if _world == null:
		return false
	_route = _world.get_node_or_null("Route") as Node
	_rig = _world.get_node_or_null("CameraRig") as Node3D
	_camera = _rig.get_node_or_null("Camera3D") as Camera3D if _rig != null else null
	return _release_base != null and _route != null and _rig != null and _camera != null and _route.has_method("route_ready") and _route.has_method("distance_for_video_seconds")

func _load_candidate() -> bool:
	if not FileAccess.file_exists(release_candidate_path):
		push_error("Saisies release candidate is missing: %s" % release_candidate_path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(release_candidate_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Saisies release candidate is not a JSON object")
		return false
	_candidate = parsed as Dictionary
	if String(_candidate.get("status", "")) != RELEASE_STATUS or String(_candidate.get("visual_acceptance", "")) != "pending":
		push_error("Saisies release candidate status must remain review-pending")
		return false
	if bool(_candidate.get("gps_calibrated", true)) or bool(_candidate.get("formal_route_edit", true)):
		push_error("Saisies release candidate must remain visual-estimate-only")
		return false
	_source_views.clear()
	var raw_views: Variant = _candidate.get("source_views", [])
	if typeof(raw_views) != TYPE_ARRAY or (raw_views as Array).size() != SOURCE_VIEW_COUNT:
		push_error("Saisies release candidate needs %d source views" % SOURCE_VIEW_COUNT)
		return false
	for view_index in range((raw_views as Array).size()):
		var raw_view: Variant = (raw_views as Array)[view_index]
		if typeof(raw_view) != TYPE_DICTIONARY:
			return false
		var view: Dictionary = raw_view as Dictionary
		var expected_scene_id := "S%02d" % (view_index + 1)
		if String(view.get("scene_id", "")).to_upper() != expected_scene_id:
			push_error("Saisies release source views must be ordered S01 through S18")
			return false
		var seconds := float(view.get("video_seconds", NAN))
		var view_height := float(view.get("height_m", camera_height_m))
		for value in [seconds, float(view.get("pitch_deg", NAN)), float(view.get("yaw_deg", NAN)), float(view.get("lateral_m", NAN)), view_height, float(view.get("fov_deg", NAN))]:
			if not is_finite(value):
				push_error("Saisies release source view contains a non-finite pose")
				return false
		if view_height < 0.5 or view_height > 5.0:
			push_error("Saisies release source view height is outside the runtime contract")
			return false
		_source_views.append(view.duplicate(true))
	for index in range(_source_views.size() - 1):
		if float(_source_views[index + 1]["video_seconds"]) <= float(_source_views[index]["video_seconds"]):
			push_error("Saisies release source views must be strictly ordered")
			return false
	return absf(float(_source_views.front()["video_seconds"]) - 5.0) < 0.01 and absf(float(_source_views.back()["video_seconds"]) - 900.0) < 0.01

func _validate_route_contract() -> bool:
	if _route == null:
		return false
	var route_length := float(_route.get("length_m"))
	var route_variant: Variant = _candidate.get("route", {})
	if typeof(route_variant) != TYPE_DICTIONARY or not is_finite(route_length):
		push_error("Saisies release candidate route contract is missing")
		return false
	var route_payload: Dictionary = route_variant as Dictionary
	var expected_length := float(route_payload.get("station_end_m", EXPECTED_ROUTE_LENGTH_M))
	if not is_finite(expected_length) or expected_length <= 0.0 or absf(route_length - expected_length) > 0.25:
		push_error("Saisies release route length %.6f does not match candidate %.6f" % [route_length, expected_length])
		return false
	return absf(route_length - EXPECTED_ROUTE_LENGTH_M) <= 0.25

func _load_release_mapping_anchors() -> bool:
	_release_mapping_anchors.clear()
	var batch_controller := _release_base.find_child("S04BatchReview", true, false) if _release_base != null else null
	var raw_anchors: Variant = batch_controller.get("_anchors") if batch_controller != null else null
	if typeof(raw_anchors) != TYPE_ARRAY or (raw_anchors as Array).size() != 11:
		push_error("Saisies release could not read the selected R35 S04 batch anchors")
		set_meta("saisies_release_r35_mapping_ready", false)
		return false
	var expected := [
		[80.0, 1030.0], [90.0, 1190.0], [95.0, 1280.0], [100.0, 1340.0],
		[105.0, 1435.0], [110.0, 1540.0], [115.0, 1630.0], [120.0, 1770.0],
		[125.0, 1830.0], [130.0, 1890.0], [135.0, 1950.0],
	]
	for index in range((raw_anchors as Array).size()):
		var raw_anchor: Variant = (raw_anchors as Array)[index]
		if typeof(raw_anchor) != TYPE_DICTIONARY:
			push_error("Saisies release R35 mapping anchor is not an object")
			_release_mapping_anchors.clear()
			return false
		var anchor: Dictionary = raw_anchor as Dictionary
		var seconds := float(anchor.get("video_seconds", NAN))
		var station := float(anchor.get("station_m", NAN))
		if not is_finite(seconds) or not is_finite(station) or absf(seconds - float(expected[index][0])) > 0.001 or absf(station - float(expected[index][1])) > 0.001:
			push_error("Saisies release R35 mapping anchor %d differs from the selected batch" % index)
			_release_mapping_anchors.clear()
			return false
		if index > 0:
			var previous: Dictionary = _release_mapping_anchors.back()
			if seconds <= float(previous["video_seconds"]) or station <= float(previous["station_m"]):
				push_error("Saisies release R35 mapping anchors must be strictly monotonic")
				_release_mapping_anchors.clear()
				return false
		_release_mapping_anchors.append({"video_seconds": seconds, "station_m": station})
	if _release_mapping_anchors.is_empty():
		return false
	# The selected R35 span replaces the generic geo estimate only in 80..135s.
	# Add bounded bridges so the whole 0..920s map remains continuous at both
	# edges while retaining the exact local stations inside the accepted span.
	var first_local: Dictionary = _release_mapping_anchors.front()
	var last_local: Dictionary = _release_mapping_anchors.back()
	var bridge_start_seconds := float(first_local["video_seconds"]) - R35_MAPPING_BRIDGE_SECONDS
	var bridge_end_seconds := float(last_local["video_seconds"]) + R35_MAPPING_BRIDGE_SECONDS
	var bridge_start_station := _generic_station_for_video_seconds(bridge_start_seconds)
	var bridge_end_station := _generic_station_for_video_seconds(bridge_end_seconds)
	if bridge_start_seconds <= FIRST_VIDEO_SECONDS or bridge_end_seconds >= LAST_VIDEO_SECONDS or bridge_start_station >= float(first_local["station_m"] ) or bridge_end_station <= float(last_local["station_m"]):
		push_error("Saisies release R35 mapping bridges are not strictly monotonic")
		_release_mapping_anchors.clear()
		return false
	var local_anchors := _release_mapping_anchors.duplicate(true)
	_release_mapping_anchors.clear()
	_release_mapping_anchors.append({"video_seconds": bridge_start_seconds, "station_m": bridge_start_station})
	_release_mapping_anchors.append_array(local_anchors)
	_release_mapping_anchors.append({"video_seconds": bridge_end_seconds, "station_m": bridge_end_station})
	if not _validate_release_mapping_functions():
		_release_mapping_anchors.clear()
		set_meta("saisies_release_r35_mapping_ready", false)
		return false
	set_meta("saisies_release_r35_mapping_ready", true)
	set_meta("saisies_release_r35_mapping_anchor_count", _release_mapping_anchors.size())
	set_meta("saisies_release_r35_mapping_anchors", _release_mapping_anchors.duplicate(true))
	return true

func _validate_release_mapping_functions() -> bool:
	# Exercise the runtime mapping function itself so a control-flow regression
	# cannot silently skip later R35 anchors and fall back to generic mapping.
	var previous_station := -INF
	for anchor in _release_mapping_anchors:
		var seconds := float(anchor.get("video_seconds", NAN))
		var expected_station := float(anchor.get("station_m", NAN))
		var actual_station := _station_for_video_seconds(seconds)
		if not is_finite(seconds) or not is_finite(expected_station) or not is_finite(actual_station) or absf(actual_station - expected_station) > 0.001 or actual_station <= previous_station:
			push_error("Saisies release runtime mapping failed exact anchor at %.3fs: %.6f != %.6f" % [seconds, actual_station, expected_station])
			return false
		previous_station = actual_station
	var route_length := float(_route.get("length_m"))
	if absf(_station_for_video_seconds(FIRST_VIDEO_SECONDS)) > 0.001 or absf(_station_for_video_seconds(LAST_VIDEO_SECONDS) - route_length) > 0.001:
		push_error("Saisies release runtime mapping failed route endpoints")
		return false
	return true

func _capture_original_state() -> void:
	if _original_captured:
		return
	_original_rig_process = _rig.is_processing()
	_original_rig_physics_process = _rig.is_physics_processing()
	_original_rig_auto_advance = bool(_rig.get("auto_advance"))
	_original_rig_cruise_speed_mps = float(_rig.get("cruise_speed_mps"))
	_original_rig_distance_m = float(_rig.get("distance_m"))
	_original_rig_requested_scene_id = String(_rig.get("_requested_scene_id"))
	_original_rig_position = _rig.position
	_original_rig_rotation = _rig.rotation
	_original_rig_scale = _rig.scale
	_original_camera_position = _camera.position
	_original_camera_rotation = _camera.rotation
	_original_camera_scale = _camera.scale
	_original_camera_fov = _camera.fov
	_original_camera_current = _camera.current
	_original_captured = true

func _disable_historical_pose_writers() -> void:
	_writer_states.clear()
	var release_root: Node = _release_base.get_parent() if _release_base != null else get_parent()
	_collect_pose_writers(release_root if release_root != null else self)
	_rig.set_process(false)
	_rig.set_physics_process(false)
	_rig.set("auto_advance", false)
	set_meta("saisies_release_historical_pose_writers_disabled", true)
	set_meta("saisies_release_historical_pose_writer_count", _writer_states.size())

func _recover_release_module_builds() -> void:
	# ReleaseRoadside creates ReleaseUpperScenery dynamically.  Its inherited
	# builder has a short route-readiness retry budget, so a slow baked route can
	# leave that child present but unbuilt even though the release route is ready.
	# Retry it from this controller after the release route contract is satisfied;
	# the child returns immediately once its own ready flag is published.
	var roadside := get_node_or_null(release_roadside_path) as Node
	if roadside == null:
		return
	var upper := roadside.get_node_or_null("ReleaseUpperScenery")
	if upper != null and upper.has_method("_try_build") and not bool(upper.get("upper_scenery_ready")):
		upper.call("_try_build")

func _collect_pose_writers(node: Node) -> void:
	for child in node.get_children():
		if child == self:
			continue
		if _is_historical_pose_writer(child):
			_writer_states.append({"node": child, "process": child.is_processing(), "physics_process": child.is_physics_processing()})
			child.set_process(false)
			child.set_physics_process(false)
			child.set_meta("saisies_release_pose_writer_disabled", true)
		_collect_pose_writers(child)

func _is_historical_pose_writer(node: Node) -> bool:
	var node_name := String(node.name)
	return node_name in [
		"S01CameraController", "S02ReviewController", "S03ReviewController",
		"S04LinkedBendsReview", "S04LateBendsReview", "S04BatchReview"
	]

func _restore_pose_writers() -> void:
	for record in _writer_states:
		var node := record.get("node") as Node
		if node == null or not is_instance_valid(node):
			continue
		node.set_process(bool(record.get("process", false)))
		node.set_physics_process(bool(record.get("physics_process", false)))

func _set_scenery_visible(enabled: bool) -> void:
	for path in [release_forest_path, release_roadside_path, release_terminals_path]:
		if path.is_empty():
			continue
		var node := get_node_or_null(path) as Node3D
		if node != null:
			node.visible = enabled
			if node.has_method("set"):
				node.set("enable_refinement", enabled)
	set_meta("saisies_release_scenery_enabled", enabled)

func _apply_release_pose() -> bool:
	if _route == null or _rig == null or _camera == null or not bool(_route.call("route_ready")):
		return false
	var station := clampf(_current_station_m, 0.0, float(_route.get("length_m")))
	var route_point: Vector3 = _route.call("pos_at", station)
	var left: Vector3 = _route.call("left_at", station)
	var tangent: Vector3 = _route.call("tangent_at", station)
	if tangent.length_squared() <= 0.000001:
		return false
	var pose := _pose_for_seconds(_current_video_seconds)
	var lateral := float(pose.get("lateral_m", default_lateral_m))
	var rig_point := route_point + left * lateral
	if _route.has_method("ground_y"):
		var ground_y := float(_route.call("ground_y", station, lateral))
		if is_finite(ground_y):
			rig_point.y = ground_y + 0.02
	if not rig_point.is_finite():
		return false
	if _rig.has_method("reset_to_distance"):
		_rig.call("reset_to_distance", station)
	_rig.set("distance_m", station)
	_rig.set("_requested_scene_id", "")
	_rig.set("auto_advance", false)
	_rig.global_position = rig_point
	var heading := atan2(-tangent.x, -tangent.z)
	_rig.rotation = Vector3(
		deg_to_rad(float(pose.get("pitch_deg", default_pitch_deg))),
		heading + deg_to_rad(float(pose.get("yaw_deg", default_yaw_deg))),
		deg_to_rad(roll_deg)
	)
	_camera.global_position = rig_point + Vector3.UP * float(pose.get("height_m", camera_height_m))
	_camera.rotation = Vector3.ZERO
	_camera.fov = clampf(float(pose.get("fov_deg", default_fov_deg)), 30.0, 120.0)
	_camera.current = true
	_rig.set("distance_m", station)
	if _legacy_source_pose_enabled:
		_apply_accepted_legacy_source_pose_if_exact()
		station = clampf(_current_station_m, 0.0, float(_route.get("length_m")))
	_rig.set_meta("saisies_release_controller", true)
	_rig.set_meta("saisies_release_video_seconds", _current_video_seconds)
	_rig.set_meta("saisies_release_station_m", station)
	return true

func _apply_accepted_legacy_source_pose_if_exact() -> void:
	# S01-S03 already passed their dedicated visual acceptance with the legacy
	# CameraRig placement helpers.  Reuse those helpers at their exact release
	# source timestamps; continuous traversal still uses the release pose
	# interpolation above.  This keeps the whole-route wrapper from subtly
	# moving the accepted opening frames to the generic global-UP camera mode.
	var scene_id := ""
	for view in _source_views:
		if absf(float(view.get("video_seconds", NAN)) - _current_video_seconds) <= 0.001:
			scene_id = String(view.get("scene_id", "")).to_upper()
			break
	if scene_id.is_empty() or not ["S01", "S02", "S03"].has(scene_id):
		return
	var pose_height := float(_pose_for_seconds(_current_video_seconds).get("height_m", camera_height_m))
	_camera.position = Vector3(0.0, pose_height, 0.0)
	var accepted_station := _current_station_m
	if _route != null and _route.has_method("acceptance_distance"):
		accepted_station = float(_route.call("acceptance_distance", scene_id))
	_current_station_m = accepted_station
	if scene_id == "S01":
		var s01_controller := _release_base.find_child("S01CameraController", true, false) if _release_base != null else null
		if s01_controller != null and s01_controller.has_method("_apply_selected_pose"):
			var applied := bool(s01_controller.call("_apply_selected_pose", accepted_station))
			set_meta("saisies_release_legacy_source_pose_applied", applied)
			set_meta("saisies_release_legacy_source_pose_scene", scene_id)
			return
	elif scene_id == "S02" or scene_id == "S03":
		if _rig.has_method("reset_to_distance") and _rig.has_method("apply_acceptance_pose"):
			_rig.set("auto_advance", false)
			_rig.call("reset_to_distance", accepted_station)
			_rig.call("apply_acceptance_pose", scene_id)
			_camera.fov = clampf(float(_pose_for_seconds(_current_video_seconds).get("fov_deg", default_fov_deg)), 30.0, 120.0)
			_camera.current = true
			set_meta("saisies_release_legacy_source_pose_applied", true)
			set_meta("saisies_release_legacy_source_pose_scene", scene_id)

func _pose_for_seconds(seconds: float) -> Dictionary:
	if _source_views.is_empty():
		return {"pitch_deg": default_pitch_deg, "yaw_deg": default_yaw_deg, "lateral_m": default_lateral_m, "fov_deg": default_fov_deg}
	var pose: Dictionary
	if seconds <= float(_source_views.front()["video_seconds"]):
		pose = _source_views.front().duplicate(true)
	else:
		pose = _source_views.back().duplicate(true)
		for index in range(_source_views.size() - 1):
			var a: Dictionary = _source_views[index]
			var b: Dictionary = _source_views[index + 1]
			var ta := float(a["video_seconds"])
			var tb := float(b["video_seconds"])
			if seconds <= tb:
				var weight := clampf((seconds - ta) / maxf(tb - ta, 0.001), 0.0, 1.0)
				pose = {
					"pitch_deg": lerpf(float(a["pitch_deg"]), float(b["pitch_deg"]), weight),
					"yaw_deg": rad_to_deg(lerp_angle(deg_to_rad(float(a["yaw_deg"])), deg_to_rad(float(b["yaw_deg"])), weight)),
					"lateral_m": lerpf(float(a["lateral_m"]), float(b["lateral_m"]), weight),
					"height_m": lerpf(float(a.get("height_m", camera_height_m)), float(b.get("height_m", camera_height_m)), weight),
					"fov_deg": lerpf(float(a["fov_deg"]), float(b["fov_deg"]), weight)
				}
				break
	# S18 deliberately turns toward the junction at its accepted 900 s frame.
	# Over the final 80 route metres, ease that review yaw back to the route
	# tangent so the authored arrival gate remains ahead of the stopping frame.
	# The exact S18 source pose is unchanged; this only affects the final tour
	# tail and keeps the endpoint composition usable at the actual route stop.
	if _route != null and _route.get("length_m") != null:
		var route_length := float(_route.get("length_m"))
		var endpoint_start_seconds := _video_seconds_for_station(maxf(route_length - 80.0, 0.0))
		if seconds > endpoint_start_seconds and LAST_VIDEO_SECONDS > endpoint_start_seconds:
			var endpoint_weight := smoothstep(0.0, 1.0, clampf((seconds - endpoint_start_seconds) / maxf(LAST_VIDEO_SECONDS - endpoint_start_seconds, 0.001), 0.0, 1.0))
			pose["yaw_deg"] = rad_to_deg(lerp_angle(deg_to_rad(float(pose.get("yaw_deg", default_yaw_deg))), 0.0, endpoint_weight))
	return pose

func _station_for_video_seconds(seconds: float) -> float:
	if _route == null:
		return 0.0
	var clamped_seconds := clampf(seconds, FIRST_VIDEO_SECONDS, LAST_VIDEO_SECONDS)
	if not _release_mapping_anchors.is_empty():
		if clamped_seconds <= float(_release_mapping_anchors.front()["video_seconds"]):
			return _generic_station_for_video_seconds(clamped_seconds)
		for index in range(1, _release_mapping_anchors.size()):
			var previous: Dictionary = _release_mapping_anchors[index - 1]
			var current: Dictionary = _release_mapping_anchors[index]
			if clamped_seconds <= float(current["video_seconds"]):
				var span := maxf(float(current["video_seconds"]) - float(previous["video_seconds"]), 0.001)
				return lerpf(float(previous["station_m"]), float(current["station_m"]), (clamped_seconds - float(previous["video_seconds"])) / span)
		# The selected R35 span ends at the bounded bridge; continue with the
		# geographic mapping for the remainder of the 0..920.067s route.
		return _generic_station_for_video_seconds(clamped_seconds)
	return _generic_station_for_video_seconds(clamped_seconds)

func _video_seconds_for_station(station: float) -> float:
	if _route == null:
		return FIRST_VIDEO_SECONDS
	var target := clampf(station, 0.0, float(_route.get("length_m")))
	if not _release_mapping_anchors.is_empty():
		var first_station := float(_release_mapping_anchors.front()["station_m"])
		var last_station := float(_release_mapping_anchors.back()["station_m"])
		if target >= first_station and target <= last_station:
			for index in range(1, _release_mapping_anchors.size()):
				var previous: Dictionary = _release_mapping_anchors[index - 1]
				var current: Dictionary = _release_mapping_anchors[index]
				if target <= float(current["station_m"]):
					var span := maxf(float(current["station_m"]) - float(previous["station_m"]), 0.001)
					return lerpf(float(previous["video_seconds"]), float(current["video_seconds"]), (target - float(previous["station_m"])) / span)
			return float(_release_mapping_anchors.back()["video_seconds"])
	return _generic_video_seconds_for_station(target)

func _generic_station_for_video_seconds(seconds: float) -> float:
	if _route == null or not _route.has_method("distance_for_video_seconds"):
		return 0.0
	return clampf(float(_route.call("distance_for_video_seconds", clampf(seconds, FIRST_VIDEO_SECONDS, LAST_VIDEO_SECONDS))), 0.0, float(_route.get("length_m")))

func _generic_video_seconds_for_station(target: float) -> float:
	var low := FIRST_VIDEO_SECONDS
	var high := LAST_VIDEO_SECONDS
	for _i in range(32):
		var mid := (low + high) * 0.5
		var sample := _generic_station_for_video_seconds(mid)
		if sample < target:
			low = mid
		else:
			high = mid
	return (low + high) * 0.5

func _pose_record(ok: bool) -> Dictionary:
	return {
		"ok": ok,
		"video_seconds": _current_video_seconds,
		"station_m": _current_station_m,
		"preview_active": _preview_active,
		"preview_finished": _preview_finished,
		"visual_acceptance": "pending"
	}

func _publish_ready_state() -> void:
	var route_length := float(_route.get("length_m"))
	set_meta("saisies_release_ready", true)
	set_meta("saisies_release_status", RELEASE_STATUS)
	set_meta("saisies_release_visual_acceptance", "pending")
	set_meta("saisies_release_enabled", _release_enabled)
	set_meta("saisies_release_route_length_m", route_length)
	set_meta("saisies_release_first_video_seconds", FIRST_VIDEO_SECONDS)
	set_meta("saisies_release_last_video_seconds", LAST_VIDEO_SECONDS)
	set_meta("saisies_release_preview_speed_kmh", preview_speed_kmh)
	set_meta("saisies_release_preview_traverse_seconds", route_length / (preview_speed_kmh / 3.6) if preview_speed_kmh > 0.0 else INF)
	set_meta("saisies_release_source_view_count", _source_views.size())
	set_meta("saisies_release_candidate_file", release_candidate_path)
	set_meta("saisies_release_module_nodes", [String(release_forest_path), String(release_roadside_path), String(release_terminals_path)])
	set_meta("saisies_release_r35_mapping_ready", not _release_mapping_anchors.is_empty())
	set_meta("saisies_release_r35_mapping_anchor_count", _release_mapping_anchors.size())
	_publish_module_state()
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_release_ready", true)
		parent.set_meta("saisies_release_visual_acceptance", "pending")

func _publish_pose_state() -> void:
	set_meta("saisies_release_video_seconds", _current_video_seconds)
	set_meta("saisies_release_station_m", _current_station_m)
	set_meta("saisies_release_preview_active", _preview_active)
	set_meta("saisies_release_preview_finished", _preview_finished)
	set_meta("saisies_release_enabled", _release_enabled)
	if _route != null and _route.get("length_m") != null:
		var route_length := float(_route.get("length_m"))
		var endpoint_pose := _pose_for_seconds(LAST_VIDEO_SECONDS)
		set_meta("saisies_release_endpoint_camera_yaw_deg", float(endpoint_pose.get("yaw_deg", default_yaw_deg)))
		set_meta("saisies_release_endpoint_camera_yaw_stabilized", float(endpoint_pose.get("yaw_deg", default_yaw_deg)) == 0.0)
		set_meta("saisies_release_endpoint_station_m", route_length)

func _publish_module_state() -> void:
	var forest := get_node_or_null(release_forest_path) as Node
	var roadside := get_node_or_null(release_roadside_path) as Node
	var terminals := get_node_or_null(release_terminals_path) as Node
	var forest_present := not release_forest_path.is_empty()
	var roadside_present := not release_roadside_path.is_empty()
	var terminals_present := not release_terminals_path.is_empty()
	var forest_ready := not forest_present or (forest != null and bool(forest.get_meta("saisies_release_forest_ready", false)))
	var roadside_ready := not roadside_present or (roadside != null and bool(roadside.get_meta("saisies_release_roadside_ready", false)))
	var terminals_ready := not terminals_present or (terminals != null and bool(terminals.get_meta("saisies_release_terminals_ready", false)))
	set_meta("saisies_release_forest_ready", forest_ready)
	set_meta("saisies_release_roadside_ready", roadside_ready)
	set_meta("saisies_release_terminals_ready", terminals_ready)
	set_meta("saisies_release_forest_enabled", not forest_present or forest != null and forest.get("enable_refinement") == true)
	set_meta("saisies_release_roadside_enabled", not roadside_present or roadside != null and roadside.get("enable_refinement") == true)
	set_meta("saisies_release_terminals_enabled", not terminals_present or terminals != null and terminals.get("enable_refinement") == true)
	set_meta("saisies_release_forest_count", _first_module_count(forest, ["saisies_release_forest_count", "saisies_release_forest_tree_count", "saisies_release_forest_instance_count"]))
	set_meta("saisies_release_roadside_count", _first_module_count(roadside, ["saisies_release_roadside_count", "saisies_release_roadside_instance_count", "saisies_release_roadside_geometry_count"]))
	set_meta("saisies_release_terminals_count", _first_module_count(terminals, ["saisies_release_terminals_geometry_count"]))
	set_meta("saisies_release_modules_ready", forest_ready and roadside_ready and terminals_ready)

func _first_module_count(module: Node, keys: Array) -> int:
	if module == null:
		return 0
	for key_variant in keys:
		var key := String(key_variant)
		if module.has_meta(key):
			return int(module.get_meta(key, 0))
	return 0

func _parse_args() -> void:
	for argument in OS.get_cmdline_user_args():
		var arg := String(argument)
		if arg.begins_with("--saisies-release-seconds="):
			default_video_seconds = float(arg.trim_prefix("--saisies-release-seconds="))
		elif arg.begins_with("--saisies-release-source="):
			set_meta("saisies_release_requested_source", arg.trim_prefix("--saisies-release-source=").to_upper())
		elif arg.begins_with("--saisies-release-scene="):
			set_meta("saisies_release_requested_source", arg.trim_prefix("--saisies-release-scene=").to_upper())
		elif arg.begins_with("--saisies-release-speed-kmh="):
			var requested_speed := float(arg.trim_prefix("--saisies-release-speed-kmh="))
			if is_finite(requested_speed) and requested_speed >= 0.0:
				preview_speed_kmh = requested_speed
		elif arg == "--saisies-release-tour":
			_preview_active = true
		elif arg == "--saisies-release-quit-after-ready":
			_quit_after_ready = true

func _has_source_argument() -> bool:
	return has_meta("saisies_release_requested_source")

func _source_seconds_from_argument() -> float:
	var wanted := String(get_meta("saisies_release_requested_source", ""))
	for view in _source_views:
		if String(view.get("scene_id", "")).to_upper() == wanted:
			return float(view.get("video_seconds", default_video_seconds))
	return default_video_seconds

func _has_flag(flag: String) -> bool:
	for argument in OS.get_cmdline_user_args():
		if String(argument) == flag:
			return true
	return false

func _quit_after_ready_frame() -> void:
	await get_tree().process_frame
	get_tree().quit()

func _retry(message: String) -> void:
	_attempts += 1
	if _attempts < DEFAULT_MAX_RETRIES:
		call_deferred("_retry_next_frame")
		return
	set_meta("saisies_release_ready", false)
	set_meta("saisies_release_error", message)
	push_error(message)

func _retry_next_frame() -> void:
	await get_tree().process_frame
	_try_initialize()
