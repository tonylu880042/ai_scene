extends Node3D

## R37 route/camera diagnostic probe.
##
## This intentionally instantiates only the frozen R14 geographic world and the
## native R36 geometry cache.  It never instantiates the S01-S04 review builders
## or the release controller, so station, camera pose, and projection can be
## measured independently before a scenery change is proposed.

@export_file("*.json") var probe_config_path := "res://data/saisies_r37_probe.json"
@export var world_scene_path := "res://export/saisies/SaisiesEnvironment_geo_r14.scn"
@export var geometry_cache_path := "res://export/saisies/release_candidate/saisies_release_geometry_cache.scn"
@export var wait_frames := 600

const SCHEMA_VERSION := 1
const DEFAULT_OUTPUT := "user://saisies_r37_probe_trajectory.json"
const DEFAULT_WINDOW_M := 250.0
const DEFAULT_STEP_M := 25.0
const DEFAULT_CURVATURE_DELTA_M := 12.0
const DEFAULT_PROJECTION_AHEAD_M := 25.0
const DEFAULT_HEIGHT_M := 1.65
const DEFAULT_FOV_DEG := 78.0
const DEFAULT_PITCH_DEG := -8.0
const DEFAULT_YAW_DEG := 0.0
const DEFAULT_LATERAL_M := -1.8
const EXPECTED_ROUTE_LENGTH_M := 14615.087922
const R36_S01_SUN_YAW_DEG := 148.0
const DEFAULT_GEOMETRY_AUDIT_CHORD_DELTA_M := 5.0
const DEFAULT_GEOMETRY_AUDIT_STEP_M := 5.0

var _config: Dictionary = {}
var _world: Node3D
var _route: Node
var _rig: Node3D
var _camera: Camera3D
var _geometry_cache: Node3D
var _r36_environment_state: Dictionary = {}
var _geometry_audit_windows: Array = []
var _geometry_audit_chord_delta_m := DEFAULT_GEOMETRY_AUDIT_CHORD_DELTA_M
var _geometry_audit_step_m := DEFAULT_GEOMETRY_AUDIT_STEP_M
var _baked_asphalt_instance: MeshInstance3D
var _baked_asphalt_triangles: Array = []
var _baked_asphalt_path := ""
var _targets: Array = []
var _modes: Array[String] = []
var _target_filter: Array[String] = []
var _capture_target_filter: Array[String] = []
var _window_m := DEFAULT_WINDOW_M
var _step_m := DEFAULT_STEP_M
var _curvature_delta_m := DEFAULT_CURVATURE_DELTA_M
var _projection_ahead_m := DEFAULT_PROJECTION_AHEAD_M
var _camera_height_m := DEFAULT_HEIGHT_M
var _fov_deg := DEFAULT_FOV_DEG
var _pitch_deg := DEFAULT_PITCH_DEG
var _yaw_deg := DEFAULT_YAW_DEG
var _lateral_m := DEFAULT_LATERAL_M
var _output_path := DEFAULT_OUTPUT
var _capture_dir := ""
var _capture_offset_m := 0.0
var _capture_wait_frames := 12
var _direct_station := NAN
var _direct_video_seconds := NAN
var _headless_check := false
var _cli_overrides: Dictionary = {}
var _startup_ms := 0
var _error_message := ""

func _ready() -> void:
	call_deferred("_start_probe")

func _start_probe() -> void:
	_startup_ms = Time.get_ticks_msec()
	_parse_args()
	if not _load_config():
		_fail(_error_message)
		return
	# Config supplies stable defaults; command-line values are the explicit probe
	# knobs and therefore get the final word after the config is loaded.
	_parse_args()
	if not _build_probe_world():
		_fail(_error_message)
		return
	var route_ready: bool = await _wait_for_route()
	if not route_ready:
		_fail(_error_message)
		return
	_prepare_baked_road_audit()
	_freeze_camera_writers()
	if not _resolve_targets():
		_fail(_error_message)
		return
	var records: Array = []
	var captures: Array = []
	for mode in _modes:
		_set_mode_visible(String(mode) == "baseline")
		for target_variant in _targets:
			if not (target_variant is Dictionary):
				continue
			var target: Dictionary = target_variant as Dictionary
			var center_station := float(target.get("station_m", 0.0))
			var offsets: Array[float] = _station_offsets(center_station)
			for offset in offsets:
				var station := clampf(center_station + offset, 0.0, _route_length())
				var record: Dictionary = _apply_probe_pose(mode, target, station, offset)
				await get_tree().process_frame
				record["route_geometry_consistency"] = _route_geometry_consistency_record(station)
				record["projection"] = _projection_record(station)
				record["camera_forward_dot_route_tangent"] = _camera_forward_dot_route(station)
				record["viewport_size"] = _viewport_size_array()
				record["cache_visible_after_frame"] = _geometry_cache != null and _geometry_cache.visible
				record["camera_global_position"] = _vec3_array(_camera.global_position)
				record["camera_global_rotation_deg"] = _vec3_array(_camera.global_rotation_degrees)
				record["camera_fov_deg_actual"] = _camera.fov
				records.append(record)
				var target_scene_id := String(target.get("scene_id", ""))
				var target_tag := String(target.get("tag", ""))
				if absf(offset - _capture_offset_m) <= 0.001 and _capture_requested(target_scene_id, target_tag):
					var capture_record: Dictionary = await _capture_frame(String(mode), target_scene_id, target_tag, station)
					captures.append(capture_record)
	var geometry_audit := _build_geometry_audit()
	var payload: Dictionary = _build_payload(records, captures, geometry_audit)
	if not _write_json(_output_path, payload):
		_fail(_error_message)
		return
	set_meta("saisies_r37_probe_ready", true)
	set_meta("saisies_r37_probe_output", _output_path)
	set_meta("saisies_r37_probe_record_count", records.size())
	set_meta("saisies_r37_probe_modes", _modes)
	print("SAISIES R37 PROBE READY records=", records.size(), " output=", _output_path)
	get_tree().quit(0)

func _load_config() -> bool:
	if not FileAccess.file_exists(probe_config_path):
		_error_message = "R37 probe config is missing: %s" % probe_config_path
		return false
	var file := FileAccess.open(probe_config_path, FileAccess.READ)
	if file == null:
		_error_message = "R37 probe config could not be opened: %s" % probe_config_path
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		_error_message = "R37 probe config must be a JSON object"
		return false
	_config = parsed as Dictionary
	if int(_config.get("schema_version", 0)) != SCHEMA_VERSION:
		_error_message = "R37 probe config schema_version is unsupported"
		return false
	if String(_config.get("kind", "")) != "saisies_r37_camera_route_probe":
		_error_message = "R37 probe config kind is not diagnostic-only"
		return false
	if String(_config.get("status", "")) != "diagnostic_only" or bool(_config.get("visual_acceptance", true)) or bool(_config.get("formal_integration_allowed", true)):
		_error_message = "R37 probe config must remain diagnostic_only and unaccepted"
		return false
	var route_contract_variant: Variant = _config.get("route_contract", {})
	if not (route_contract_variant is Dictionary):
		_error_message = "R37 probe route_contract is missing"
		return false
	var route_contract: Dictionary = route_contract_variant as Dictionary
	if absf(float(route_contract.get("station_end_m", EXPECTED_ROUTE_LENGTH_M)) - EXPECTED_ROUTE_LENGTH_M) > 0.25:
		_error_message = "R37 probe route contract has an unexpected route length"
		return false
	var world_from_config := String(_config.get("world_scene", ""))
	if not world_from_config.is_empty():
		world_scene_path = world_from_config
	var cache_from_config := String(_config.get("geometry_cache", ""))
	if not cache_from_config.is_empty():
		geometry_cache_path = cache_from_config
	var targets_variant: Variant = _config.get("candidates", _config.get("targets", []))
	if not (targets_variant is Array) or (targets_variant as Array).is_empty():
		_error_message = "R37 probe config needs at least one candidate"
		return false
	_targets = (targets_variant as Array).duplicate(true)
	var route_end := float(route_contract.get("station_end_m", EXPECTED_ROUTE_LENGTH_M))
	var candidate_keys: Dictionary = {}
	for candidate_variant in _targets:
		if not (candidate_variant is Dictionary):
			_error_message = "R37 probe candidates must be objects"
			return false
		var candidate: Dictionary = candidate_variant as Dictionary
		var scene_id := String(candidate.get("scene_id", "")).strip_edges()
		var tag := String(candidate.get("tag", "")).strip_edges()
		var raw_seconds: Variant = candidate.get("video_seconds", NAN)
		var raw_station: Variant = candidate.get("station_m", NAN)
		var pose_variant: Variant = candidate.get("pose", candidate.get("source_pose", {}))
		if scene_id.is_empty() or tag.is_empty() or typeof(raw_seconds) not in [TYPE_INT, TYPE_FLOAT] or typeof(raw_station) not in [TYPE_INT, TYPE_FLOAT] or not (pose_variant is Dictionary):
			_error_message = "R37 candidates require scene_id, tag, numeric video_seconds/station_m, and pose"
			return false
		if not is_finite(float(raw_seconds)) or not is_finite(float(raw_station)) or float(raw_station) < 0.0 or float(raw_station) > route_end:
			_error_message = "R37 candidate %s/%s has a non-finite or out-of-route value" % [scene_id, tag]
			return false
		var candidate_key := scene_id.to_upper() + "::" + tag.to_upper()
		if candidate_keys.has(candidate_key):
			_error_message = "R37 candidate scene_id/tag is duplicated: %s" % candidate_key
			return false
		candidate_keys[candidate_key] = true
	_geometry_audit_windows = _default_geometry_audit_windows()
	var audit_variant: Variant = _config.get("geometry_audit", {})
	if audit_variant is Dictionary:
		var audit: Dictionary = audit_variant as Dictionary
		_geometry_audit_chord_delta_m = maxf(float(audit.get("chord_delta_m", DEFAULT_GEOMETRY_AUDIT_CHORD_DELTA_M)), 0.1)
		_geometry_audit_step_m = maxf(float(audit.get("sample_step_m", DEFAULT_GEOMETRY_AUDIT_STEP_M)), 0.1)
		var configured_windows: Variant = audit.get("windows", [])
		if configured_windows is Array and not (configured_windows as Array).is_empty():
			var parsed_windows: Array = []
			for window_variant in configured_windows as Array:
				if not (window_variant is Dictionary):
					continue
				var window: Dictionary = window_variant as Dictionary
				var start_m := float(window.get("start_m", NAN))
				var end_m := float(window.get("end_m", NAN))
				if not is_finite(start_m) or not is_finite(end_m) or end_m < start_m:
					continue
				parsed_windows.append({
					"id": String(window.get("id", window.get("scene_id", "audit_%02d" % parsed_windows.size()))),
					"scene_id": String(window.get("scene_id", "")),
					"start_m": clampf(start_m, 0.0, route_end),
					"end_m": clampf(end_m, 0.0, route_end)
				})
			if not parsed_windows.is_empty():
				_geometry_audit_windows = parsed_windows
	var matrix_variant: Variant = _config.get("matrix", {})
	if matrix_variant is Dictionary:
		var matrix: Dictionary = matrix_variant as Dictionary
		_window_m = maxf(float(matrix.get("station_window_m", DEFAULT_WINDOW_M)), 0.0)
		_step_m = maxf(float(matrix.get("station_step_m", DEFAULT_STEP_M)), 0.1)
		_curvature_delta_m = maxf(float(matrix.get("curvature_delta_m", DEFAULT_CURVATURE_DELTA_M)), 0.1)
		_projection_ahead_m = maxf(float(matrix.get("projection_ahead_m", DEFAULT_PROJECTION_AHEAD_M)), 0.0)
		_camera_height_m = float(matrix.get("camera_height_m", DEFAULT_HEIGHT_M))
		_fov_deg = float(matrix.get("default_fov_deg", DEFAULT_FOV_DEG))
		_pitch_deg = float(matrix.get("default_pitch_deg", DEFAULT_PITCH_DEG))
		_yaw_deg = float(matrix.get("default_yaw_deg", DEFAULT_YAW_DEG))
		_lateral_m = float(matrix.get("default_lateral_m", DEFAULT_LATERAL_M))
		_capture_wait_frames = maxi(int(matrix.get("capture_wait_frames", 12)), 1)
		var configured_modes: Variant = matrix.get("modes", [])
		if configured_modes is Array:
			var parsed_modes: Array[String] = []
			for configured_mode in configured_modes as Array:
				var mode_name := String(configured_mode)
				if mode_name in ["baseline", "route_only"] and not parsed_modes.has(mode_name):
					parsed_modes.append(mode_name)
			if not parsed_modes.is_empty():
				_modes = parsed_modes
	return true

func _default_geometry_audit_windows() -> Array:
	return [
		{"id": "S06_window", "scene_id": "S06", "start_m": 3354.3967, "end_m": 3854.3967},
		{"id": "S10_window", "scene_id": "S10", "start_m": 6396.6746, "end_m": 6896.6746},
		{"id": "S12_pre_right_transition", "scene_id": "S12", "start_m": 8480.0, "end_m": 9000.0},
		{"id": "S12_current_right_bend", "scene_id": "S12", "start_m": 9150.0, "end_m": 9550.0}
	]

func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--config="):
			probe_config_path = arg.substr(9)
		elif arg.begins_with("--output="):
			_output_path = arg.substr(9)
		elif arg.begins_with("--world="):
			world_scene_path = arg.substr(8)
		elif arg.begins_with("--cache="):
			geometry_cache_path = arg.substr(8)
		elif arg.begins_with("--targets="):
			_target_filter = _split_csv(arg.substr(10))
		elif arg.begins_with("--window="):
			_window_m = maxf(float(arg.substr(9)), 0.0)
		elif arg.begins_with("--step="):
			_step_m = maxf(float(arg.substr(7)), 0.1)
		elif arg.begins_with("--curvature-delta="):
			_curvature_delta_m = maxf(float(arg.substr(18)), 0.1)
		elif arg.begins_with("--projection-ahead="):
			_projection_ahead_m = maxf(float(arg.substr(19)), 0.0)
		elif arg.begins_with("--station="):
			_direct_station = float(arg.substr(10))
		elif arg.begins_with("--video-seconds="):
			_direct_video_seconds = float(arg.substr(16))
		elif arg.begins_with("--fov="):
			_fov_deg = float(arg.substr(6))
			_cli_overrides["fov_deg"] = true
		elif arg.begins_with("--pitch="):
			_pitch_deg = float(arg.substr(8))
			_cli_overrides["pitch_deg"] = true
		elif arg.begins_with("--yaw="):
			_yaw_deg = float(arg.substr(6))
			_cli_overrides["yaw_deg"] = true
		elif arg.begins_with("--lateral="):
			_lateral_m = float(arg.substr(10))
			_cli_overrides["lateral_m"] = true
		elif arg.begins_with("--height="):
			_camera_height_m = float(arg.substr(9))
			_cli_overrides["height_m"] = true
		elif arg.begins_with("--capture-dir="):
			_capture_dir = arg.substr(14)
		elif arg.begins_with("--capture-targets="):
			_capture_target_filter = _split_csv(arg.substr(18))
		elif arg.begins_with("--capture-offset="):
			_capture_offset_m = float(arg.substr(17))
		elif arg.begins_with("--capture-wait-frames="):
			_capture_wait_frames = maxi(int(arg.substr(22)), 1)
		elif arg == "--route-only":
			_modes = ["route_only"]
		elif arg == "--baseline":
			_modes = ["baseline"]
		elif arg == "--headless-check":
			_headless_check = true
	if _modes.is_empty():
		_modes = ["baseline", "route_only"]
	if _output_path == DEFAULT_OUTPUT and _headless_check:
		_output_path = "user://saisies_r37_probe_headless.json"
	if is_finite(_direct_station):
		var direct_target: Dictionary = {
			"scene_id": "DIRECT",
			"video_seconds": _direct_video_seconds if is_finite(_direct_video_seconds) else null,
			"station_m": _direct_station,
			"source_pose": {}
		}
		_targets = [direct_target]

func _build_probe_world() -> bool:
	var world_pack: PackedScene = load(world_scene_path) as PackedScene
	if world_pack == null:
		_error_message = "R37 probe could not load R14 world: %s" % world_scene_path
		return false
	_world = world_pack.instantiate() as Node3D
	if _world == null:
		_error_message = "R37 probe R14 world is not Node3D"
		return false
	_world.name = "World"
	add_child(_world)
	_apply_r36_environment_baseline()
	# This is the same explicit frozen-anchor bypass used by the R36 preview
	# harness.  It documents the accepted S04 anchor source without running any
	# S01-S04 builder or pose controller.
	var anchor_node := Node3D.new()
	anchor_node.name = "S04BatchReview"
	anchor_node.set_meta("saisies_s04_batch_ready", true)
	anchor_node.set_meta("saisies_r37_frozen_anchor_bypass", true)
	anchor_node.set_meta("saisies_r37_anchor_source", "res://data/saisies_s04_batch.json")
	if FileAccess.file_exists("res://data/saisies_s04_batch.json"):
		var anchor_file := FileAccess.open("res://data/saisies_s04_batch.json", FileAccess.READ)
		if anchor_file != null:
			var anchor_payload: Variant = JSON.parse_string(anchor_file.get_as_text())
			anchor_file.close()
			if anchor_payload is Dictionary:
				anchor_node.set_meta("anchors", (anchor_payload as Dictionary).get("anchors", []))
	add_child(anchor_node)
	var cache_pack: PackedScene = load(geometry_cache_path) as PackedScene
	if cache_pack == null:
		_error_message = "R37 probe could not load frozen R36 geometry cache: %s" % geometry_cache_path
		return false
	_geometry_cache = cache_pack.instantiate() as Node3D
	if _geometry_cache == null:
		_error_message = "R37 probe geometry cache is not Node3D"
		return false
	_geometry_cache.name = "ReleaseGeometryCache"
	add_child(_geometry_cache)
	return true

func _apply_r36_environment_baseline() -> void:
	# R14 already carries the frozen MainScene_saisies_geo Environment (HDRI,
	# ambient, tone mapping, adjustment, and fog).  R36's S01Architecture review
	# applies one instance-only lighting mutation after loading that same world:
	# scripts/saisies_s01_architecture.gd::_apply_s01_sun_override() preserves
	# elevation/energy/colour and replaces only Sun.rotation_degrees.y with 148.
	# Apply that exact state without instantiating the S01 builder.
	var sun := _world.get_node_or_null("Sun") as DirectionalLight3D
	var sun_applied := false
	var sun_rotation := Vector3.ZERO
	if sun != null:
		sun_rotation = sun.rotation_degrees
		sun_rotation.y = R36_S01_SUN_YAW_DEG
		sun.rotation_degrees = sun_rotation
		sun.set_meta("saisies_s01_review_sun_override", true)
		sun.set_meta("saisies_s01_review_sun_yaw_deg", R36_S01_SUN_YAW_DEG)
		sun_applied = true
	else:
		push_warning("R37 probe could not resolve R14 World/Sun for the R36 S01 lighting baseline")
	var world_environment := _world.get_node_or_null("WorldEnvironment") as WorldEnvironment
	var environment: Environment = world_environment.environment if world_environment != null else null
	_r36_environment_state = {
		"source_scene": "res://scenes/MainScene_saisies_geo.tscn",
		"source_manifest": "res://export/saisies/SaisiesEnvironment_geo_r14.scn.manifest.json",
		"sun_override_source": "res://scripts/saisies_s01_architecture.gd::_apply_s01_sun_override",
		"sun_yaw_deg": R36_S01_SUN_YAW_DEG,
		"sun_applied": sun_applied,
		"sun_rotation_deg": _vec3_array(sun_rotation),
		"environment_present": environment != null,
		"environment_tonemap_exposure": environment.tonemap_exposure if environment != null else null,
		"environment_ambient_energy": environment.ambient_light_energy if environment != null else null,
		"environment_fog_density": environment.fog_density if environment != null else null,
		"environment_adjustment_saturation": environment.adjustment_saturation if environment != null and environment.adjustment_enabled else null,
		"environment_adjustment_contrast": environment.adjustment_contrast if environment != null and environment.adjustment_enabled else null
	}

func _wait_for_route() -> bool:
	_route = _world.find_child("Route", true, false)
	_rig = _world.find_child("CameraRig", true, false) as Node3D
	if _route == null or _rig == null:
		_error_message = "R37 probe could not resolve World/Route or World/CameraRig"
		return false
	_camera = _rig.find_child("Camera3D", true, false) as Camera3D
	if _camera == null:
		_error_message = "R37 probe could not resolve World/CameraRig/Camera3D"
		return false
	for _frame in range(wait_frames):
		if _route.has_method("route_ready") and bool(_route.call("route_ready")):
			var route_length := _route_length()
			if absf(route_length - EXPECTED_ROUTE_LENGTH_M) > 0.25:
				_error_message = "R37 probe route length %.6f differs from frozen %.6f" % [route_length, EXPECTED_ROUTE_LENGTH_M]
				return false
			return true
		await get_tree().process_frame
	_error_message = "R37 probe timed out waiting for World/Route"
	return false

func _prepare_baked_road_audit() -> void:
	_baked_asphalt_instance = null
	_baked_asphalt_triangles.clear()
	_baked_asphalt_path = ""
	if _world == null:
		return
	var asphalt := _world.find_child("SaisiesAsphalt", true, false) as MeshInstance3D
	if asphalt == null or asphalt.mesh == null:
		var pending: Array[Node] = [_world]
		while not pending.is_empty():
			var node: Node = pending.pop_back()
			var mesh_node := node as MeshInstance3D
			if mesh_node != null and mesh_node.mesh != null and String(mesh_node.name).to_lower().contains("asphalt"):
				asphalt = mesh_node
				break
			for child in node.get_children():
				pending.append(child)
	if asphalt == null or asphalt.mesh == null:
		return
	_baked_asphalt_instance = asphalt
	_baked_asphalt_path = str(asphalt.get_path())
	var mesh: Mesh = asphalt.mesh
	var mesh_transform := asphalt.global_transform
	for surface_index in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var raw_indices: Variant = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX else null
		if raw_indices is PackedInt32Array and (raw_indices as PackedInt32Array).size() >= 3:
			var indices: PackedInt32Array = raw_indices
			for start in range(0, indices.size() - 2, 3):
				var ia := int(indices[start])
				var ib := int(indices[start + 1])
				var ic := int(indices[start + 2])
				if ia < 0 or ib < 0 or ic < 0 or ia >= vertices.size() or ib >= vertices.size() or ic >= vertices.size():
					continue
				_append_baked_asphalt_triangle(mesh_transform * vertices[ia], mesh_transform * vertices[ib], mesh_transform * vertices[ic], surface_index, start)
		else:
			for start in range(0, vertices.size() - 2, 3):
				_append_baked_asphalt_triangle(mesh_transform * vertices[start], mesh_transform * vertices[start + 1], mesh_transform * vertices[start + 2], surface_index, start)

func _append_baked_asphalt_triangle(a: Vector3, b: Vector3, c: Vector3, surface_index: int, start: int) -> void:
	if not a.is_finite() or not b.is_finite() or not c.is_finite():
		return
	var edge_a := Vector2(b.x - a.x, b.z - a.z)
	var edge_b := Vector2(c.x - a.x, c.z - a.z)
	if edge_a.length_squared() <= 0.000001 or edge_b.length_squared() <= 0.000001 or absf(edge_a.cross(edge_b)) <= 0.000001:
		return
	_baked_asphalt_triangles.append({"a": a, "b": b, "c": c, "surface": surface_index, "start": start})

func _route_geometry_consistency_record(station: float) -> Dictionary:
	var route_length := _route_length()
	var delta := minf(_geometry_audit_chord_delta_m, maxf(route_length * 0.5, 0.1))
	var before := maxf(station - delta, 0.0)
	var after := minf(station + delta, route_length)
	var before_position := Vector3(_route.call("pos_at", before))
	var after_position := Vector3(_route.call("pos_at", after))
	var chord := after_position - before_position
	var actual_tangent := chord.normalized() if chord.length_squared() > 0.000001 else Vector3.ZERO
	var actual_horizontal := Vector3(chord.x, 0.0, chord.z).normalized() if Vector2(chord.x, chord.z).length_squared() > 0.000001 else Vector3.ZERO
	var api_tangent := Vector3(_route.call("tangent_at", station)).normalized()
	var api_horizontal := Vector3(api_tangent.x, 0.0, api_tangent.z).normalized() if Vector2(api_tangent.x, api_tangent.z).length_squared() > 0.000001 else Vector3.ZERO
	var full_dot := actual_tangent.dot(api_tangent) if actual_tangent != Vector3.ZERO and api_tangent != Vector3.ZERO else NAN
	var horizontal_dot := actual_horizontal.dot(api_horizontal) if actual_horizontal != Vector3.ZERO and api_horizontal != Vector3.ZERO else NAN
	var actual_heading := rad_to_deg(atan2(actual_horizontal.x, -actual_horizontal.z)) if actual_horizontal != Vector3.ZERO else NAN
	var api_heading := rad_to_deg(atan2(api_horizontal.x, -api_horizontal.z)) if api_horizontal != Vector3.ZERO else NAN
	return {
		"sample_before_m": before,
		"sample_after_m": after,
		"chord_span_m": after - before,
		"sample_before_position": _vec3_array(before_position),
		"sample_after_position": _vec3_array(after_position),
		"chord_vector": _vec3_array(chord),
		"actual_tangent": _vec3_array(actual_tangent),
		"actual_horizontal_tangent": _vec3_array(actual_horizontal),
		"api_tangent_at": _vec3_array(api_tangent),
		"api_horizontal_tangent": _vec3_array(api_horizontal),
		"full_dot": full_dot,
		"horizontal_dot": horizontal_dot,
		"full_angle_error_deg": rad_to_deg(acos(clampf(full_dot, -1.0, 1.0))) if is_finite(full_dot) else NAN,
		"horizontal_angle_error_deg": rad_to_deg(acos(clampf(horizontal_dot, -1.0, 1.0))) if is_finite(horizontal_dot) else NAN,
		"actual_heading_deg_raw": actual_heading,
		"api_heading_deg_raw": api_heading,
		"heading_delta_deg_wrapped": wrapf(actual_heading - api_heading, -180.0, 180.0) if is_finite(actual_heading) and is_finite(api_heading) else NAN
	}

func _build_geometry_audit() -> Dictionary:
	var windows: Array = []
	for window_variant in _geometry_audit_windows:
		if not (window_variant is Dictionary):
			continue
		var window: Dictionary = window_variant as Dictionary
		var start_m := clampf(float(window.get("start_m", 0.0)), 0.0, _route_length())
		var end_m := clampf(float(window.get("end_m", start_m)), start_m, _route_length())
		var samples: Array = []
		var station := start_m
		while station <= end_m + 0.001:
			samples.append(_geometry_audit_record(window, station))
			station += _geometry_audit_step_m
		if samples.is_empty() or float((samples.back() as Dictionary).get("station_m", -INF)) < end_m - 0.001:
			samples.append(_geometry_audit_record(window, end_m))
		windows.append({
			"id": String(window.get("id", "audit")),
			"scene_id": String(window.get("scene_id", "")),
			"start_m": start_m,
			"end_m": end_m,
			"sample_count": samples.size(),
			"samples": samples
		})
	return {
		"status": "ready" if not _baked_asphalt_triangles.is_empty() else "unavailable",
		"chord_delta_m": _geometry_audit_chord_delta_m,
		"sample_step_m": _geometry_audit_step_m,
		"baked_asphalt": {
			"available": _baked_asphalt_instance != null and not _baked_asphalt_triangles.is_empty(),
			"node_path": _baked_asphalt_path,
			"triangle_count": _baked_asphalt_triangles.size()
		},
		"windows": windows
	}

func _geometry_audit_record(window: Dictionary, station: float) -> Dictionary:
	var center := Vector3(_route.call("pos_at", station))
	var left := Vector3(_route.call("left_at", station)).normalized()
	var road_width := float(_route.call("road_width_at", station)) if _route.has_method("road_width_at") else 6.4
	var query_lateral: Dictionary = {"center": 0.0, "left_edge": road_width * 0.5, "right_edge": -road_width * 0.5}
	var baked_queries: Dictionary = {}
	for label_variant in query_lateral.keys():
		var label := String(label_variant)
		var lateral := float(query_lateral[label_variant])
		var expected := center + left * lateral
		if _route.has_method("ground_y"):
			expected.y = float(_route.call("ground_y", station, lateral))
		var nearest := _nearest_baked_road_point(expected)
		nearest["expected_position"] = _vec3_array(expected)
		nearest["query_lateral_m"] = lateral
		if bool(nearest.get("available", false)):
			var nearest_position := _array_to_vec3(nearest.get("nearest_position", []))
			nearest["vertical_delta_m"] = nearest_position.y - expected.y
			nearest["nearest_lateral_m"] = left.dot(nearest_position - center)
			if _route.has_method("distance_for_position"):
				nearest["nearest_station_m"] = float(_route.call("distance_for_position", nearest_position))
		baked_queries[label] = nearest
	return {
		"window_id": String(window.get("id", "audit")),
		"scene_id": String(window.get("scene_id", "")),
		"station_m": station,
		"route_position": _vec3_array(center),
		"route_left": _vec3_array(left),
		"road_width_m": road_width,
		"route_geometry_consistency": _route_geometry_consistency_record(station),
		"baked_asphalt_queries": baked_queries
	}

func _nearest_baked_road_point(query: Vector3) -> Dictionary:
	if _baked_asphalt_triangles.is_empty():
		return {"available": false, "horizontal_distance_m": -1.0}
	var best_distance := INF
	var best_position := Vector3.ZERO
	var best_triangle := -1
	var best_surface := -1
	var best_start := -1
	for triangle_index in _baked_asphalt_triangles.size():
		var triangle: Dictionary = _baked_asphalt_triangles[triangle_index]
		var nearest := _nearest_point_on_triangle_xz(query, triangle["a"], triangle["b"], triangle["c"])
		var distance := float(nearest.get("distance_m", INF))
		if distance >= best_distance:
			continue
		best_distance = distance
		best_position = nearest.get("position", Vector3.ZERO)
		best_triangle = triangle_index
		best_surface = int(triangle.get("surface", -1))
		best_start = int(triangle.get("start", -1))
	return {
		"available": best_triangle >= 0,
		"nearest_position": _vec3_array(best_position),
		"horizontal_distance_m": best_distance,
		"triangle_index": best_triangle,
		"surface_index": best_surface,
		"triangle_start": best_start
	}

func _nearest_point_on_triangle_xz(point: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Dictionary:
	var ab := Vector2(b.x - a.x, b.z - a.z)
	var ac := Vector2(c.x - a.x, c.z - a.z)
	var ap := Vector2(point.x - a.x, point.z - a.z)
	var denominator := ab.cross(ac)
	if absf(denominator) > 0.000001:
		var u := ap.cross(ac) / denominator
		var v := ab.cross(ap) / denominator
		if u >= -0.000001 and v >= -0.000001 and u + v <= 1.000001:
			var w := 1.0 - u - v
			var inside_position := a * w + b * u + c * v
			return {"position": inside_position, "distance_m": Vector2(point.x - inside_position.x, point.z - inside_position.z).length(), "inside": true}
	var best := _nearest_point_on_segment_xz(point, a, b)
	for edge in [[b, c], [c, a]]:
		var candidate := _nearest_point_on_segment_xz(point, edge[0], edge[1])
		if float(candidate.get("distance_m", INF)) < float(best.get("distance_m", INF)):
			best = candidate
	return best

func _nearest_point_on_segment_xz(point: Vector3, a: Vector3, b: Vector3) -> Dictionary:
	var delta := Vector2(b.x - a.x, b.z - a.z)
	var denominator := delta.length_squared()
	var t := 0.0
	if denominator > 0.000001:
		t = clampf(Vector2(point.x - a.x, point.z - a.z).dot(delta) / denominator, 0.0, 1.0)
	var position := a.lerp(b, t)
	return {"position": position, "distance_m": Vector2(point.x - position.x, point.z - position.z).length(), "inside": false}

func _array_to_vec3(value: Variant) -> Vector3:
	if value is Array and (value as Array).size() >= 3:
		var values: Array = value as Array
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return Vector3.ZERO

func _freeze_camera_writers() -> void:
	if _rig == null or _camera == null:
		return
	_rig.set_process(false)
	_rig.set_physics_process(false)
	if _rig.has_method("set"):
		_rig.set("auto_advance", false)
	_camera.current = true
	_freeze_named_writers(_world)

func _freeze_named_writers(node: Node) -> void:
	for child in node.get_children():
		var child_name := String(child.name)
		if child_name in [
			"S01CameraController", "S02ReviewController", "S03ReviewController",
			"S04LinkedBendsReview", "S04LateBendsReview", "S04BatchReview"
		]:
			child.set_process(false)
			child.set_physics_process(false)
		_freeze_named_writers(child)

func _resolve_targets() -> bool:
	if _targets.is_empty():
		_error_message = "R37 probe has no targets"
		return false
	if _target_filter.is_empty():
		return true
	var selected: Array = []
	for target_variant in _targets:
		if target_variant is Dictionary:
			var target: Dictionary = target_variant as Dictionary
			var scene_id := String(target.get("scene_id", "")).to_upper()
			var tag := String(target.get("tag", "")).to_upper()
			if _target_filter.has(scene_id) or _target_filter.has(scene_id + "::" + tag):
				selected.append(target_variant)
	if selected.is_empty():
		_error_message = "R37 target filter selected no configured targets"
		return false
	_targets = selected
	return true

func _station_offsets(center_station: float) -> Array[float]:
	var result: Array[float] = []
	if _window_m <= 0.0:
		result.append(0.0)
		return result
	var offset := -_window_m
	while offset <= _window_m + 0.001:
		result.append(offset)
		offset += _step_m
	if result.is_empty() or absf(float(result.back())) < _window_m - 0.001:
		result.append(_window_m)
	return result

func _set_mode_visible(baseline: bool) -> void:
	if _geometry_cache != null:
		_geometry_cache.visible = baseline

func _apply_probe_pose(mode: String, target: Dictionary, station: float, offset: float) -> Dictionary:
	var tangent := Vector3(_route.call("tangent_at", station)).normalized()
	var left := Vector3(_route.call("left_at", station)).normalized()
	var route_position := Vector3(_route.call("pos_at", station))
	var lateral := _pose_value(target, "lateral_m", _lateral_m)
	var height := _pose_value(target, "height_m", _camera_height_m)
	var fov := _pose_value(target, "fov_deg", _fov_deg)
	var pitch := _pose_value(target, "pitch_deg", _pitch_deg)
	var yaw := _pose_value(target, "yaw_deg", _yaw_deg)
	var rig_position := route_position + left * lateral
	if _route.has_method("ground_y"):
		var ground_y := float(_route.call("ground_y", station, lateral))
		if is_finite(ground_y):
			rig_position.y = ground_y + 0.02
	if _rig.has_method("reset_to_distance"):
		_rig.call("reset_to_distance", station)
	_rig.set("distance_m", station)
	_rig.set("auto_advance", false)
	_rig.global_position = rig_position
	var heading := atan2(-tangent.x, -tangent.z)
	_rig.rotation = Vector3(deg_to_rad(pitch), heading + deg_to_rad(yaw), 0.0)
	# Match the release controller's camera placement: height is world-up, not
	# the rig's pitched local Y axis, so baseline pixels remain comparable.
	_camera.global_position = rig_position + Vector3.UP * height
	_camera.rotation = Vector3.ZERO
	_camera.fov = clampf(fov, 30.0, 120.0)
	_camera.current = true
	return _trajectory_record(mode, target, station, offset, route_position, tangent, left, rig_position, lateral, height, fov, pitch, yaw)

func _trajectory_record(mode: String, target: Dictionary, station: float, offset: float, route_position: Vector3, tangent: Vector3, left: Vector3, rig_position: Vector3, lateral: float, height: float, fov: float, pitch: float, yaw: float) -> Dictionary:
	var curvature := _curvature_record(station)
	var ground_y := float(_route.call("ground_y", station, lateral)) if _route.has_method("ground_y") else route_position.y
	var time_alignment := _time_alignment_record(target)
	return {
		"mode": mode,
		"target_scene_id": String(target.get("scene_id", "")),
		"target_tag": String(target.get("tag", "")),
		"target_video_seconds": target.get("video_seconds", null),
		"target_station_m": float(target.get("station_m", station)),
		"station_offset_m": offset,
		"station_m": station,
		"route_position": _vec3_array(route_position),
		"route_ground_y_m": ground_y,
		"route_tangent": _vec3_array(tangent),
		"route_left": _vec3_array(left),
		"heading_deg": rad_to_deg(atan2(tangent.x, -tangent.z)),
		"grade_pct": float(_route.call("grade_at", station)) if _route.has_method("grade_at") else 0.0,
		"road_width_m": float(_route.call("road_width_at", station)) if _route.has_method("road_width_at") else 6.4,
		"curvature": curvature,
		"time_alignment": time_alignment,
		"camera_lateral_m": lateral,
		"camera_height_m": height,
		"camera_fov_deg_requested": fov,
		"camera_pitch_deg_requested": pitch,
		"camera_yaw_deg_requested": yaw,
		"rig_position": _vec3_array(rig_position)
	}

func _time_alignment_record(target: Dictionary) -> Dictionary:
	var raw_video: Variant = target.get("video_seconds", null)
	var requested_station := float(target.get("station_m", NAN))
	if typeof(raw_video) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(raw_video)):
		return {"video_seconds": null, "requested_station_m": requested_station, "route_generic_station_m": null, "delta_m": null, "route_mapping_available": false}
	var video_seconds := float(raw_video)
	if not _route.has_method("distance_for_video_seconds"):
		return {"video_seconds": video_seconds, "requested_station_m": requested_station, "route_generic_station_m": null, "delta_m": null, "route_mapping_available": false}
	var generic_station := float(_route.call("distance_for_video_seconds", video_seconds))
	return {"video_seconds": video_seconds, "requested_station_m": requested_station, "route_generic_station_m": generic_station, "delta_m": generic_station - requested_station, "route_mapping_available": true}

func _curvature_record(station: float) -> Dictionary:
	var route_length := _route_length()
	var before := maxf(station - _curvature_delta_m, 0.0)
	var after := minf(station + _curvature_delta_m, route_length)
	var before_tangent := Vector3(_route.call("tangent_at", before)).normalized()
	var before_left := Vector3(_route.call("left_at", before)).normalized()
	var after_tangent := Vector3(_route.call("tangent_at", after)).normalized()
	var signed_turn := atan2(after_tangent.dot(before_left), after_tangent.dot(before_tangent))
	var span := maxf(after - before, 0.001)
	var curvature := signed_turn / span
	var direction := "straight"
	if curvature > 0.00045:
		direction = "left"
	elif curvature < -0.00045:
		direction = "right"
	return {
		"signed_turn_rad_per_m": curvature,
		"signed_turn_deg_per_10m": rad_to_deg(curvature * 10.0),
		"radius_m": INF if absf(curvature) < 0.000001 else 1.0 / absf(curvature),
		"direction": direction,
		"sample_before_m": before,
		"sample_after_m": after
	}

func _projection_record(station: float) -> Dictionary:
	var look_station := minf(station + _projection_ahead_m, _route_length())
	var road_width := float(_route.call("road_width_at", look_station)) if _route.has_method("road_width_at") else 6.4
	var lateral_values: Dictionary = {"center": 0.0, "left_edge": road_width * 0.5, "right_edge": -road_width * 0.5}
	var result: Dictionary = {"station_m": look_station, "points": {}}
	for label_variant in lateral_values.keys():
		var label := String(label_variant)
		var lateral := float(lateral_values[label_variant])
		var world_point := Vector3(_route.call("pos_at", look_station)) + Vector3(_route.call("left_at", look_station)).normalized() * lateral
		if _route.has_method("ground_y"):
			world_point.y = float(_route.call("ground_y", look_station, lateral)) + 0.03
		var screen := _camera.unproject_position(world_point)
		result["points"][label] = {
			"world_position": _vec3_array(world_point),
			"screen_px": [screen.x, screen.y],
			"behind_camera": _camera.is_position_behind(world_point),
			"screen_inside_viewport": _screen_inside_viewport(screen)
		}
	return result

func _camera_forward_dot_route(station: float) -> float:
	var forward := -_camera.global_basis.z.normalized()
	var tangent := Vector3(_route.call("tangent_at", station)).normalized()
	return forward.dot(tangent)

func _capture_requested(scene_id: String, tag: String) -> bool:
	var key := scene_id.to_upper() + "::" + tag.to_upper()
	return not _capture_dir.is_empty() and (_capture_target_filter.is_empty() or _capture_target_filter.has(scene_id.to_upper()) or _capture_target_filter.has(key))

func _capture_frame(mode: String, scene_id: String, tag: String, station: float) -> Dictionary:
	for _frame in range(_capture_wait_frames):
		await get_tree().process_frame
	RenderingServer.force_draw()
	var image := get_viewport().get_texture().get_image()
	var filename := "%s_%s_%s_s%07d.png" % [scene_id.to_lower(), _safe_file_component(tag), mode, int(round(station))]
	var output := _capture_dir.path_join(filename)
	var absolute := ProjectSettings.globalize_path(output) if output.begins_with("res://") or output.begins_with("user://") else output
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var result_code := image.save_png(absolute)
	return {"mode": mode, "scene_id": scene_id, "tag": tag, "station_m": station, "path": output, "ok": result_code == OK}

func _safe_file_component(value: String) -> String:
	var result := value.to_lower()
	result = result.replace("/", "_").replace("\\", "_").replace(" ", "_")
	return result if not result.is_empty() else "candidate"

func _build_payload(records: Array, captures: Array, geometry_audit: Dictionary) -> Dictionary:
	var target_summary: Array = []
	for target_variant in _targets:
		if target_variant is Dictionary:
			var target: Dictionary = target_variant as Dictionary
			target_summary.append({"scene_id": String(target.get("scene_id", "")), "tag": String(target.get("tag", "")), "video_seconds": target.get("video_seconds", null), "station_m": target.get("station_m", null), "pose": target.get("pose", target.get("source_pose", {}))})
	return {
		"schema_version": 1,
		"kind": "saisies_r37_probe_trajectory_v1",
		"status": "diagnostic_only",
		"visual_acceptance": false,
		"formal_integration_allowed": false,
		"not_validated": true,
		"source_config": probe_config_path,
		"world_scene": world_scene_path,
		"geometry_cache": geometry_cache_path,
		"frozen_anchor_bypass": true,
		"r36_environment_baseline": _r36_environment_state,
		"geometry_audit": geometry_audit,
		"route": {"node": str(_route.get_path()), "length_m": _route_length(), "expected_length_m": EXPECTED_ROUTE_LENGTH_M, "route_ready": _route.has_method("route_ready") and bool(_route.call("route_ready"))},
		"probe": {"window_m": _window_m, "step_m": _step_m, "curvature_delta_m": _curvature_delta_m, "projection_ahead_m": _projection_ahead_m, "capture_wait_frames": _capture_wait_frames, "candidates": target_summary, "modes": _modes, "camera_defaults": {"height_m": _camera_height_m, "fov_deg": _fov_deg, "pitch_deg": _pitch_deg, "yaw_deg": _yaw_deg, "lateral_m": _lateral_m}},
		"runtime": {"startup_ms": Time.get_ticks_msec() - _startup_ms, "viewport_size": _viewport_size_array(), "renderer": RenderingServer.get_current_rendering_driver_name(), "cache_ready_meta": _geometry_cache != null and bool(_geometry_cache.get_meta("saisies_release_cache_ready", false))},
		"captures": captures,
		"records": records
	}

func _route_length() -> float:
	return float(_route.get("length_m")) if _route != null else 0.0

func _pose_value(target: Dictionary, key: String, fallback: float) -> float:
	if _cli_overrides.has(key):
		return fallback
	var source_pose_variant: Variant = target.get("pose", target.get("source_pose", {}))
	if source_pose_variant is Dictionary:
		return float((source_pose_variant as Dictionary).get(key, fallback))
	return fallback

func _vec3_array(value: Vector3) -> Array[float]:
	return [value.x, value.y, value.z]

func _viewport_size_array() -> Array[int]:
	var viewport := get_viewport()
	if viewport == null:
		return [0, 0]
	var size := viewport.get_visible_rect().size
	return [int(size.x), int(size.y)]

func _screen_inside_viewport(screen: Vector2) -> bool:
	var size := _viewport_size_array()
	return screen.x >= 0.0 and screen.y >= 0.0 and screen.x <= float(size[0]) and screen.y <= float(size[1])

func _split_csv(value: String) -> Array[String]:
	var result: Array[String] = []
	for item in value.split(",", false):
		var cleaned := item.strip_edges().to_upper()
		if not cleaned.is_empty():
			result.append(cleaned)
	return result

func _write_json(path: String, payload: Dictionary) -> bool:
	var absolute := ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_error_message = "R37 probe could not write trajectory output: %s" % path
		return false
	file.store_string(JSON.stringify(payload, "  "))
	file.close()
	return true

func _fail(message: String) -> void:
	_error_message = message
	set_meta("saisies_r37_probe_ready", false)
	set_meta("saisies_r37_probe_error", message)
	push_error(message)
	get_tree().quit(1)

