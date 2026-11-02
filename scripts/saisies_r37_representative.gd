extends Node3D

## R37 diagnostic representative-route candidate.
##
## The candidate is an isolated copy of the R14 world plus the frozen R36
## geometry cache.  It reads a local fit description and applies one smooth
## source-frame -> fitted-frame warp to the route samples, visible meshes,
## MultiMesh props, and concave road collision.  It is deliberately diagnostic:
## no release scene or frozen route source is changed.

const DRESSING_SCRIPT = preload("res://scripts/saisies_r37_dressing.gd")
const GROUND_AUDIT = preload("res://scripts/saisies_release_roadside_ground.gd")

@export_file("*.json") var representatives_path := "res://data/saisies_r37_representatives.json"
@export_file("*.tscn") var world_scene_path := "res://export/saisies/SaisiesEnvironment_geo_r14.scn"
@export_file("*.scn") var geometry_cache_path := "res://export/saisies/release_candidate/saisies_release_geometry_cache.scn"
@export_file("*.json") var dressing_path := "res://data/saisies_r37_dressing.json"
@export var candidate_id := "S06"
@export var wait_frames := 600
@export var capture_dir := ""
@export var report_path := "user://saisies_r37_representative_report.json"
@export var auto_quit := true
@export var auto_capture := true
@export var enable_dressing := true
@export var auto_tour := false
@export var tour_loop := true
@export var tour_playback_rate := 1.0

const EXPECTED_ROUTE_LENGTH_M := 14615.087922
const SOURCE_BIN_SIZE_M := 40.0
const DEFAULT_CORRIDOR_HALF_WIDTH_M := 40.0
const DEFAULT_CORRIDOR_FALLOFF_M := 40.0
const DEFAULT_HEIGHT_M := 1.65
const DEFAULT_FOV_DEG := 78.0
const DEFAULT_PITCH_DEG := -8.0
const DEFAULT_YAW_DEG := 0.0
const DEFAULT_LATERAL_M := -1.8
const R36_S01_SUN_YAW_DEG := 148.0
const S10_TERRAIN_PROFILE_STATION_STEP_M := 20.0
const S10_TERRAIN_PROFILE_LATERALS := [0.0, 4.0, 8.0, 16.0, 30.0, 45.0, 80.0]
const S10_TERRAIN_PROFILE_DESIRED_RELATIVE_M := [0.0, 0.0, -1.0, -4.0, -10.0, -18.0, 0.0]

var _config: Dictionary = {}
var _candidate: Dictionary = {}
var _world: Node3D
var _geometry_cache: Node3D
var _dressing: Node3D
var _route: Node
var _rig: Node3D
var _camera: Camera3D
var _source_samples: Array[Vector3] = []
var _source_headings := PackedFloat32Array()
var _source_elevations := PackedFloat32Array()
var _source_grades := PackedFloat32Array()
var _source_spacing_m := 10.0
var _route_length_m := 0.0
var _source_bins: Dictionary = {}
var _fit_samples: Array = []
var _cross_section_overrides: Array = []
var _window_start_m := 0.0
var _window_end_m := 0.0
var _authored_window_start_m := 0.0
var _authored_window_end_m := 0.0
var _corridor_half_width_m := DEFAULT_CORRIDOR_HALF_WIDTH_M
var _corridor_falloff_m := DEFAULT_CORRIDOR_FALLOFF_M
var _fit_source := ""
var _fit_endpoint_residual_m := 0.0
var _fit_height_closure_peak_pct := 0.0
var _mesh_node_count := 0
var _multimesh_node_count := 0
var _collision_node_count := 0
var _warped_vertex_count := 0
var _warped_instance_count := 0
var _error_message := ""
var _override_candidate_id := ""
var _override_capture_dir := ""
var _override_report_path := ""
var _override_station := NAN
var _r36_environment_state: Dictionary = {}
var _dressing_report: Dictionary = {}
var _source_sequence: Array = []
var _source_time_start_s := 0.0
var _source_time_end_s := 0.0
var _tour_time_s := 0.0
var _tour_paused := false
var _tour_active := false
var _tour_ready := false
var _camera_data: Dictionary = {}
var _terrain_profile_sampler: Object
var _terrain_profile_stations := PackedFloat32Array()
var _terrain_profile_offsets: Array = []
var _terrain_profile_ready := false
var _terrain_profile_source := "disabled"
var _terrain_profile_sample_count := 0
var _terrain_profile_miss_count := 0
var _terrain_profile_edit_start_m := 0.0
var _terrain_profile_edit_end_m := 0.0
var _terrain_profile_outer_start_m := 0.0
var _terrain_profile_outer_end_m := 0.0
var _warp_bounds_min := Vector2.ZERO
var _warp_bounds_max := Vector2.ZERO
var _warp_bounds_ready := false
var _cross_section_override_source := "candidate"

func _ready() -> void:
	call_deferred("_start_candidate")

func _process(delta: float) -> void:
	if not _tour_ready or not _tour_active or _tour_paused:
		return
	var span := _source_time_end_s - _source_time_start_s
	if span <= 0.0001:
		_tour_active = false
		return
	_tour_time_s += delta * maxf(tour_playback_rate, 0.0)
	if _tour_time_s > _source_time_end_s:
		if tour_loop:
			_tour_time_s = _source_time_start_s + fmod(_tour_time_s - _source_time_start_s, span)
		else:
			_tour_time_s = _source_time_end_s
			_tour_active = false
	_apply_camera_source_time(_tour_time_s)
	_update_tour_meta()

func _unhandled_input(event: InputEvent) -> void:
	if not _tour_active:
		return
	var key_event := event as InputEventKey
	if key_event != null and key_event.pressed and not key_event.echo and key_event.keycode == KEY_SPACE:
		_tour_paused = not _tour_paused
		_update_tour_meta()

func _start_candidate() -> void:
	_parse_args()
	if not _load_config():
		_fail(_error_message)
		return
	if not _build_world():
		_fail(_error_message)
		return
	if not await _wait_for_route():
		_fail(_error_message)
		return
	if not _snapshot_source_route():
		_fail(_error_message)
		return
	if not _load_fit_samples():
		_fail(_error_message)
		return
	_load_source_sequence()
	if not _prepare_terrain_profile():
		_fail(_error_message)
		return
	_prepare_source_bins()
	_warp_scene_geometry(_world)
	_warp_scene_geometry(_geometry_cache)
	print("SAISIES R37 representative geometry warp complete candidate=%s mesh=%d multimesh=%d collision=%d vertices=%d instances=%d" % [candidate_id, _mesh_node_count, _multimesh_node_count, _collision_node_count, _warped_vertex_count, _warped_instance_count])
	_apply_route_fit()
	if not _build_dressing():
		_fail(_error_message)
		return
	_freeze_camera_writers()
	_apply_camera_pose()
	var report := _build_report()
	if not _write_json(_resolved_report_path(), report):
		_fail(_error_message)
		return
	if auto_capture and not _resolved_capture_dir().is_empty():
		await _capture_frame()
	set_meta("saisies_r37_representative_ready", true)
	set_meta("saisies_r37_representative_candidate", candidate_id)
	set_meta("saisies_r37_representative_report", _resolved_report_path())
	set_meta("saisies_r37_representative_world_path", _world.get_path() if _world != null else NodePath())
	set_meta("saisies_r37_representative_route_path", _route.get_path() if _route != null else NodePath())
	set_meta("saisies_r37_representative_camera_path", _camera.get_path() if _camera != null else NodePath())
	_tour_ready = true
	_update_tour_meta()
	print("SAISIES R37 REPRESENTATIVE READY candidate=", candidate_id, " report=", _resolved_report_path())
	if auto_quit:
		get_tree().quit(0)

func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--config="):
			representatives_path = arg.substr(9)
		elif arg.begins_with("--candidate="):
			_override_candidate_id = arg.substr(12).strip_edges()
		elif arg.begins_with("--capture-dir="):
			_override_capture_dir = arg.substr(14)
		elif arg.begins_with("--report="):
			_override_report_path = arg.substr(9)
		elif arg.begins_with("--station="):
			_override_station = float(arg.substr(10))
		elif arg == "--interactive":
			auto_quit = false
			auto_tour = true
		elif arg == "--tour":
			auto_quit = false
			auto_tour = true
		elif arg == "--no-tour":
			auto_tour = false
		elif arg == "--no-quit":
			auto_quit = false
		elif arg == "--no-capture":
			auto_capture = false
		elif arg == "--no-dressing":
			enable_dressing = false
	if not _override_candidate_id.is_empty():
		candidate_id = _override_candidate_id

func _load_config() -> bool:
	if not FileAccess.file_exists(representatives_path):
		_error_message = "R37 representatives config is missing: %s" % representatives_path
		return false
	var file := FileAccess.open(representatives_path, FileAccess.READ)
	if file == null:
		_error_message = "R37 representatives config could not be opened: %s" % representatives_path
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		_error_message = "R37 representatives config must be a JSON object"
		return false
	_config = parsed as Dictionary
	var config_status := String(_config.get("status", "diagnostic_only"))
	if config_status != "diagnostic_only" and config_status != "draft_for_integrate":
		_error_message = "R37 representative config has unsupported status: %s" % config_status
		return false
	if bool(_config.get("formal_integration_allowed", true)) or bool(_config.get("visual_acceptance", false)):
		_error_message = "R37 representative candidates must remain unaccepted and formal_integration_allowed=false"
		return false
	var candidates_variant: Variant = _config.get("representatives", _config.get("candidates", _config.get("segments", [])))
	if not (candidates_variant is Array):
		_error_message = "R37 representatives config needs representatives/candidates/segments array"
		return false
	for candidate_variant in candidates_variant as Array:
		if candidate_variant is Dictionary and String((candidate_variant as Dictionary).get("id", (candidate_variant as Dictionary).get("scene_id", ""))).to_upper() == candidate_id.to_upper():
			_candidate = (candidate_variant as Dictionary).duplicate(true)
			break
	if _candidate.is_empty():
		_error_message = "R37 representative candidate is missing: %s" % candidate_id
		return false
	world_scene_path = String(_config.get("world_scene", world_scene_path))
	geometry_cache_path = String(_config.get("geometry_cache", geometry_cache_path))
	return true

func _build_dressing() -> bool:
	if not enable_dressing:
		_dressing_report = {"enabled": false, "ready": false, "reason": "disabled_by_flag"}
		set_meta("saisies_r37_representative_dressing_ready", false)
		set_meta("saisies_r37_representative_dressing_report", _dressing_report)
		return true
	var dressing_instance: Object = DRESSING_SCRIPT.new()
	_dressing = dressing_instance as Node3D
	if _dressing == null:
		_error_message = "R37 representative could not instantiate dressing module"
		return false
	_dressing.name = "SaisiesR37Dressing_%s" % candidate_id.to_upper()
	_dressing.set("candidate_path", dressing_path)
	add_child(_dressing)
	var result: Variant = _dressing.call("build_for_representative", _world, _route, candidate_id, {"container": self})
	if not (result is Dictionary):
		_error_message = "R37 dressing returned an invalid build report"
		return false
	_dressing_report = result as Dictionary
	set_meta("saisies_r37_representative_dressing_ready", bool(_dressing_report.get("ready", false)))
	set_meta("saisies_r37_representative_dressing_report", _dressing_report)
	if not bool(_dressing_report.get("ready", false)):
		_error_message = "R37 dressing failed for %s: %s" % [candidate_id, String(_dressing_report.get("error", "unknown error"))]
		return false
	return true

func _build_world() -> bool:
	var world_pack := load(world_scene_path) as PackedScene
	if world_pack == null:
		_error_message = "R37 representative could not load world: %s" % world_scene_path
		return false
	_world = world_pack.instantiate() as Node3D
	if _world == null:
		_error_message = "R37 representative world is not Node3D"
		return false
	_world.name = "World"
	add_child(_world)
	_apply_r36_environment_baseline()
	var cache_pack := load(geometry_cache_path) as PackedScene
	if cache_pack == null:
		_error_message = "R37 representative could not load geometry cache: %s" % geometry_cache_path
		return false
	_geometry_cache = cache_pack.instantiate() as Node3D
	if _geometry_cache == null:
		_error_message = "R37 representative geometry cache is not Node3D"
		return false
	_geometry_cache.name = "ReleaseGeometryCache"
	add_child(_geometry_cache)
	return true

func _apply_r36_environment_baseline() -> void:
	# Keep representative captures comparable with the R37 probe and the frozen
	# R36 S01 review: R14 already carries the environment resource, while the
	# review mutates only the directional-light yaw in the live scene.
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
		push_warning("R37 representative could not resolve R14 World/Sun for the R36 S01 lighting baseline")
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
		_error_message = "R37 representative could not resolve Route/CameraRig"
		return false
	_camera = _rig.find_child("Camera3D", true, false) as Camera3D
	if _camera == null:
		_error_message = "R37 representative could not resolve Camera3D"
		return false
	for _frame in range(wait_frames):
		if _route.has_method("route_ready") and bool(_route.call("route_ready")):
			_route_length_m = float(_route.get("length_m"))
			if absf(_route_length_m - EXPECTED_ROUTE_LENGTH_M) > 0.25:
				_error_message = "R37 representative route length %.6f differs from frozen %.6f" % [_route_length_m, EXPECTED_ROUTE_LENGTH_M]
				return false
			return true
		await get_tree().process_frame
	_error_message = "R37 representative timed out waiting for Route"
	return false

func _snapshot_source_route() -> bool:
	_source_spacing_m = maxf(float(_route.get("sample_spacing_m")), 0.1)
	var raw_samples: Variant = _route.get("_samples")
	if raw_samples is Array and not (raw_samples as Array).is_empty():
		for value in raw_samples as Array:
			if value is Vector3:
				_source_samples.append(value as Vector3)
	if _source_samples.size() < 2:
		for index in range(int(ceil(_route_length_m / _source_spacing_m)) + 1):
			_source_samples.append(Vector3(_route.call("pos_at", minf(float(index) * _source_spacing_m, _route_length_m))))
	if _source_samples.size() < 2:
		_error_message = "R37 representative could not read route samples"
		return false
	var raw_headings: Variant = _route.get("_headings")
	if raw_headings is PackedFloat32Array:
		_source_headings = raw_headings as PackedFloat32Array
	_source_elevations = _read_packed_float_array("_elevations", _source_samples.size())
	_source_grades = _read_packed_float_array("_grades", _source_samples.size())
	if _source_headings.size() != _source_samples.size():
		_source_headings.resize(_source_samples.size())
		for index in _source_samples.size():
			_source_headings[index] = _heading_from_vector(_source_tangent_at(float(index) * _source_spacing_m))
	return true

func _read_packed_float_array(property_name: String, count: int) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	var raw: Variant = _route.get(property_name)
	if raw is PackedFloat32Array:
		result = raw as PackedFloat32Array
	if result.size() != count:
		result.resize(count)
		for index in count:
			if property_name == "_grades":
				result[index] = _source_grade_at(minf(float(index) * _source_spacing_m, _route_length_m))
			else:
				result[index] = _source_samples[index].y
	return result

func _load_fit_samples() -> bool:
	var raw_fit: Variant = _candidate.get("fit_samples", _candidate.get("compiled_fit_samples", _candidate.get("route_samples", _candidate.get("samples", _candidate.get("frames", [])))))
	if raw_fit is Array and not (raw_fit as Array).is_empty():
		_fit_source = "explicit_fit_samples"
		for item_variant in raw_fit as Array:
			_append_fit_sample(item_variant)
	else:
		_fit_source = "segments_knots_integrated"
		if not _build_fit_samples_from_knots():
			return false
	if _fit_samples.is_empty():
		_error_message = "R37 representative %s has no usable fit samples or knot fit" % candidate_id
		return false
	_fit_samples.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("station_m", 0.0)) < float(b.get("station_m", 0.0)))
	_rebuild_fit_tangents_from_positions()
	var station_window_variant: Variant = _candidate.get("station_window", {})
	if station_window_variant is Dictionary:
		var station_window: Dictionary = station_window_variant as Dictionary
		_window_start_m = float(station_window.get("outer_start_m", station_window.get("window_start_m", _fit_samples.front().get("station_m", 0.0))))
		_window_end_m = float(station_window.get("outer_end_m", station_window.get("window_end_m", _fit_samples.back().get("station_m", _route_length_m))))
	else:
		_window_start_m = float(_candidate.get("window_start_m", _candidate.get("start_m", _fit_samples.front().get("station_m", 0.0))))
		_window_end_m = float(_candidate.get("window_end_m", _candidate.get("end_m", _fit_samples.back().get("station_m", _route_length_m))))
	_window_start_m = clampf(minf(_window_start_m, _window_end_m), 0.0, _route_length_m)
	_window_end_m = clampf(maxf(_window_start_m, _window_end_m), _window_start_m, _route_length_m)
	_authored_window_start_m = _window_start_m
	_authored_window_end_m = _window_end_m
	# Route samples are fixed on the native source grid. A changed sample affects
	# the preceding/following interpolated cell, so align the effective deformation
	# envelope to grid cells and report the authored window separately.
	_window_start_m = floorf(_window_start_m / maxf(_source_spacing_m, 0.001)) * _source_spacing_m
	_window_end_m = ceilf(_window_end_m / maxf(_source_spacing_m, 0.001)) * _source_spacing_m
	_window_start_m = clampf(_window_start_m, 0.0, _route_length_m)
	_window_end_m = clampf(_window_end_m, _window_start_m, _route_length_m)
	_corridor_half_width_m = maxf(float(_candidate.get("corridor_half_width_m", DEFAULT_CORRIDOR_HALF_WIDTH_M)), 1.0)
	var default_falloff := DEFAULT_CORRIDOR_FALLOFF_M
	if station_window_variant is Dictionary:
		default_falloff = float((station_window_variant as Dictionary).get("boundary_blend_range_m", default_falloff))
	_corridor_falloff_m = maxf(float(_candidate.get("corridor_falloff_m", default_falloff)), 1.0)
	var raw_cross_section: Variant = _candidate.get("cross_section_overrides", _candidate.get("cross_section", []))
	if raw_cross_section is Array:
		_cross_section_overrides = raw_cross_section as Array
	if _cross_section_overrides.is_empty():
		_cross_section_overrides = _default_cross_section_overrides()
	return true

func _load_source_sequence() -> void:
	_source_sequence.clear()
	var sequence_variant: Variant = _candidate.get("source_sequence", {})
	if sequence_variant is Dictionary:
		var rows_variant: Variant = (sequence_variant as Dictionary).get("time_to_station_estimates", [])
		if rows_variant is Array:
			for raw_row in rows_variant as Array:
				if not (raw_row is Dictionary):
					continue
				var row: Dictionary = raw_row as Dictionary
				var source_time := float(row.get("source_time_s", NAN))
				var station := float(row.get("station_m", NAN))
				if not is_finite(source_time) or not is_finite(station):
					continue
				_source_sequence.append({
					"source_time_s": source_time,
					"station_m": clampf(station, 0.0, _route_length_m),
					"phase": String(row.get("phase", "")),
				})
	_source_sequence.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("source_time_s", 0.0)) < float(b.get("source_time_s", 0.0)))
	var range_variant: Variant = _candidate.get("source_time_range_s", [])
	if range_variant is Array and (range_variant as Array).size() >= 2:
		_source_time_start_s = float((range_variant as Array)[0])
		_source_time_end_s = float((range_variant as Array)[1])
	elif _source_sequence.size() >= 2:
		_source_time_start_s = float((_source_sequence.front() as Dictionary).get("source_time_s", 0.0))
		_source_time_end_s = float((_source_sequence.back() as Dictionary).get("source_time_s", _source_time_start_s))
	else:
		_source_time_start_s = 0.0
		_source_time_end_s = 0.0
	if _source_time_end_s < _source_time_start_s:
		var swap_time := _source_time_start_s
		_source_time_start_s = _source_time_end_s
		_source_time_end_s = swap_time
	_tour_time_s = _source_time_start_s

func _station_for_source_time(source_time: float) -> float:
	if _source_sequence.is_empty():
		return 0.0
	var first: Dictionary = _source_sequence.front() as Dictionary
	var last: Dictionary = _source_sequence.back() as Dictionary
	if source_time <= float(first.get("source_time_s", source_time)):
		return float(first.get("station_m", 0.0))
	if source_time >= float(last.get("source_time_s", source_time)):
		return float(last.get("station_m", 0.0))
	for index in range(_source_sequence.size() - 1):
		var left: Dictionary = _source_sequence[index] as Dictionary
		var right: Dictionary = _source_sequence[index + 1] as Dictionary
		var left_time := float(left.get("source_time_s", source_time))
		var right_time := float(right.get("source_time_s", left_time))
		if source_time <= right_time:
			var weight := clampf((source_time - left_time) / maxf(right_time - left_time, 0.001), 0.0, 1.0)
			return lerpf(float(left.get("station_m", 0.0)), float(right.get("station_m", 0.0)), weight)
	return float(last.get("station_m", 0.0))

func _prepare_terrain_profile() -> bool:
	_terrain_profile_ready = false
	_terrain_profile_source = "disabled"
	_terrain_profile_sampler = null
	_terrain_profile_stations.clear()
	_terrain_profile_offsets.clear()
	_terrain_profile_sample_count = 0
	_terrain_profile_miss_count = 0
	if candidate_id.to_upper() != "S10":
		return true
	var edit_start := 0.0
	var edit_end := 0.0
	var fit_report_variant: Variant = _candidate.get("fit_report", {})
	if fit_report_variant is Dictionary:
		var actual_core_variant: Variant = (fit_report_variant as Dictionary).get("actual_core_validation", {})
		if actual_core_variant is Dictionary:
			var core_range_variant: Variant = (actual_core_variant as Dictionary).get("core_station_range_m", [])
			if core_range_variant is Array and (core_range_variant as Array).size() >= 2:
				edit_start = float((core_range_variant as Array)[0])
				edit_end = float((core_range_variant as Array)[1])
	if edit_end <= edit_start:
		var sequence_variant: Variant = _candidate.get("source_sequence", {})
		if sequence_variant is Dictionary:
			var rows_variant: Variant = (sequence_variant as Dictionary).get("time_to_station_estimates", [])
			if rows_variant is Array and (rows_variant as Array).size() >= 2:
				var first_row: Dictionary = (rows_variant as Array).front() as Dictionary
				var last_row: Dictionary = (rows_variant as Array).back() as Dictionary
				edit_start = float(first_row.get("station_m", 0.0))
				edit_end = float(last_row.get("station_m", edit_start))
	if edit_end <= edit_start:
		_error_message = "R37 S10 terrain profile has no valid edit core"
		return false
	var outer_start := float(_candidate.get("window_start_m", edit_start - _corridor_falloff_m))
	var outer_end := float(_candidate.get("window_end_m", edit_end + _corridor_falloff_m))
	_terrain_profile_edit_start_m = edit_start
	_terrain_profile_edit_end_m = edit_end
	_terrain_profile_outer_start_m = minf(outer_start, edit_start)
	_terrain_profile_outer_end_m = maxf(outer_end, edit_end)
	var terrain_node := _resolve_visible_terrain_node_for_profile()
	if terrain_node == null:
		_error_message = "R37 S10 terrain profile could not resolve visible terrain mesh"
		return false
	var helper: RefCounted = GROUND_AUDIT.new()
	if helper == null or not helper.has_method("configure") or not helper.has_method("sample_mesh_triangle"):
		_error_message = "R37 S10 terrain profile could not instantiate visible-ground sampler"
		return false
	helper.call("configure", _route, terrain_node)
	var station_span := _terrain_profile_outer_end_m - _terrain_profile_outer_start_m
	var station_count := maxi(int(ceil(station_span / S10_TERRAIN_PROFILE_STATION_STEP_M)), 1)
	for station_index in range(station_count + 1):
		var station_t := float(station_index) / float(station_count)
		_terrain_profile_stations.append(lerpf(_terrain_profile_outer_start_m, _terrain_profile_outer_end_m, station_t))
	var warm_points: Array[Vector3] = []
	for station_value in _terrain_profile_stations:
		for lateral_variant in S10_TERRAIN_PROFILE_LATERALS:
			var lateral := float(lateral_variant)
			if lateral >= 79.9:
				continue
			warm_points.append(_source_route_point(float(station_value), lateral))
	helper.call("_prepare_visible_mesh_cache", warm_points)
	_terrain_profile_sampler = helper
	for station_value in _terrain_profile_stations:
		var station := float(station_value)
		var source_road_y := _source_pos_at(station).y
		var row: Array = []
		for lateral_variant in S10_TERRAIN_PROFILE_LATERALS:
			var lateral := float(lateral_variant)
			if lateral >= 79.9:
				row.append(0.0)
				continue
			# Keep the asphalt, markings, and collision shoulder in their
			# existing road frame.  The authored bank correction starts after
			# u=4 m, so the first two lookup columns are exact zero offsets.
			if lateral <= 4.0:
				row.append(0.0)
				continue
			var ground_y := _sample_profile_ground_y(_source_route_point(station, lateral))
			if not is_finite(ground_y):
				_terrain_profile_miss_count += 1
				row.append(0.0)
				continue
			_terrain_profile_sample_count += 1
			var old_height_above_road := ground_y - source_road_y
			var desired_height_above_road := float(S10_TERRAIN_PROFILE_DESIRED_RELATIVE_M[row.size()])
			row.append(desired_height_above_road - old_height_above_road)
		_terrain_profile_offsets.append(row)
	if _terrain_profile_sample_count <= 0:
		_error_message = "R37 S10 terrain profile visible sampler returned no triangle samples"
		return false
	_terrain_profile_ready = true
	_terrain_profile_source = "old_visible_triangle_grid"
	_cross_section_override_source = "visible_terrain_profile_S10"
	return true

func _resolve_visible_terrain_node_for_profile() -> Node:
	if _world == null:
		return null
	if _world.has_method("sample_mesh_triangle"):
		return _world
	for child in _world.find_children("*", "", true, false):
		if child is Node and (child as Node).has_method("sample_mesh_triangle"):
			return child as Node
	var landscape := _world.find_child("Landscape", true, false)
	if landscape != null:
		return landscape
	var terrain := _world.find_child("SaisiesGeoTerrain", true, false)
	if terrain != null:
		return terrain
	for child in _world.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance != null and String(mesh_instance.name).contains("SaisiesGeoTerrain"):
			return mesh_instance
	return null

func _source_route_point(station: float, lateral: float) -> Vector3:
	var center := _source_pos_at(station)
	var tangent := _source_tangent_at(station)
	var left := Vector3(tangent.z, 0.0, -tangent.x).normalized()
	return center + left * lateral

func _sample_profile_ground_y(point: Vector3) -> float:
	if _terrain_profile_sampler == null:
		return NAN
	var raw: Variant = _terrain_profile_sampler.call("sample_mesh_triangle", Vector2(point.x, point.z))
	if not (raw is Dictionary):
		return NAN
	var sample: Dictionary = raw as Dictionary
	var height_variant: Variant = sample.get("height", sample.get("ground_y", NAN))
	if not is_finite(float(height_variant)):
		return NAN
	for key in ["a", "b", "c"]:
		if not (sample.get(key, null) is Vector3):
			return NAN
	return float(height_variant)

func _default_cross_section_overrides() -> Array:
	# The native representative route has a persistent left-side bank/guardrail
	# silhouette in S10 and S12. Keep the road and route-right rock profile at
	# zero offset, then lower only the outside of the route-left bank. The route
	# station weight supplies the smooth 250 m outer blend back to the old DEM.
	var upper_id := candidate_id.to_upper()
	if upper_id == "S10":
		# S10 is corrected from the old visible terrain triangle profile below.
		# Do not stack the former three-metre generic bank on that measured field.
		_cross_section_override_source = "visible_terrain_profile_pending_S10"
		return []
	if upper_id != "S12":
		return []
	var bank_drop := -3.0 if upper_id == "S10" else -2.5
	var profile: Array = [
		{"lateral_m": -40.0, "height_offset_m": 0.0},
		{"lateral_m": -8.0, "height_offset_m": 0.0},
		{"lateral_m": -3.2, "height_offset_m": 0.0},
		{"lateral_m": 3.2, "height_offset_m": 0.0},
		{"lateral_m": 8.0, "height_offset_m": bank_drop * 0.16},
		{"lateral_m": 16.0, "height_offset_m": bank_drop * 0.42},
		{"lateral_m": 28.0, "height_offset_m": bank_drop * 0.72},
		{"lateral_m": 40.0, "height_offset_m": bank_drop},
	]
	_cross_section_override_source = "representative_default_left_bank_%s" % upper_id
	return [{"start_m": _window_start_m, "end_m": _window_end_m, "samples": profile}]

func _rebuild_fit_tangents_from_positions() -> void:
	if _fit_samples.size() < 2:
		return
	for index in _fit_samples.size():
		var current: Dictionary = _fit_samples[index]
		var previous_index := maxi(index - 1, 0)
		var next_index := mini(index + 1, _fit_samples.size() - 1)
		var previous: Dictionary = _fit_samples[previous_index]
		var next: Dictionary = _fit_samples[next_index]
		var current_position: Vector3 = current.get("position", Vector3.ZERO)
		var previous_position: Vector3 = previous.get("position", current_position)
		var next_position: Vector3 = next.get("position", current_position)
		var tangent := (next_position - previous_position).normalized()
		if tangent.length_squared() <= 0.000001:
			tangent = _source_tangent_at(float(current.get("station_m", 0.0)))
		current["tangent"] = tangent
		_fit_samples[index] = current

func _append_fit_sample(item_variant: Variant) -> void:
	if not (item_variant is Dictionary):
		return
	var item: Dictionary = item_variant as Dictionary
	var station := float(item.get("station_m", item.get("source_station_m", NAN)))
	if not is_finite(station):
		return
	station = clampf(station, 0.0, _route_length_m)
	var source_position := _source_pos_at(station)
	var position := _read_vec3(item, ["position", "center", "route_position"], source_position)
	if item.has("offset_x_m") or item.has("offset_y_m") or item.has("offset_z_m"):
		var source_tangent := _source_tangent_at(station)
		var source_left := Vector3(source_tangent.z, 0.0, -source_tangent.x).normalized()
		position = source_position + source_left * float(item.get("offset_x_m", 0.0)) + Vector3.UP * float(item.get("offset_y_m", 0.0)) + source_tangent * float(item.get("offset_z_m", 0.0))
	var tangent := _read_vec3(item, ["tangent", "forward"], Vector3.ZERO)
	if item.has("absolute_heading_deg") or item.has("heading_deg"):
		var heading := deg_to_rad(float(item.get("absolute_heading_deg", item.get("heading_deg", 0.0))))
		tangent = Vector3(sin(heading), 0.0, -cos(heading))
	_fit_samples.append({"station_m": station, "position": position, "tangent": tangent})

func _build_fit_samples_from_knots() -> bool:
	var station_window_variant: Variant = _candidate.get("station_window", {})
	if not (station_window_variant is Dictionary):
		_error_message = "R37 representative %s has no station_window for knot fit" % candidate_id
		return false
	var station_window: Dictionary = station_window_variant as Dictionary
	var heading_variant: Variant = _candidate.get("heading_delta_knots_deg", [])
	var absolute_heading_variant: Variant = _candidate.get("absolute_heading_knots_deg", _candidate.get("heading_absolute_knots_deg", []))
	var grade_variant: Variant = _candidate.get("grade_knots_pct", [])
	var has_heading_delta := heading_variant is Array and not (heading_variant as Array).is_empty()
	var has_absolute_heading := absolute_heading_variant is Array and not (absolute_heading_variant as Array).is_empty()
	if (not has_heading_delta and not has_absolute_heading) or not (grade_variant is Array) or (grade_variant as Array).is_empty():
		_error_message = "R37 representative %s needs heading knots and grade_knots_pct" % candidate_id
		return false
	var heading_knots: Array = []
	if has_heading_delta:
		heading_knots = heading_variant as Array
	var absolute_heading_knots: Array = []
	if absolute_heading_variant is Array:
		absolute_heading_knots = absolute_heading_variant as Array
	var grade_knots: Array = grade_variant as Array
	var outer_start := clampf(float(station_window.get("outer_start_m", 0.0)), 0.0, _route_length_m)
	var outer_end := clampf(float(station_window.get("outer_end_m", _route_length_m)), outer_start, _route_length_m)
	if outer_end <= outer_start + 0.001:
		_error_message = "R37 representative %s has an empty outer window" % candidate_id
		return false
	var edit_start := clampf(float(station_window.get("edit_start_m", outer_start)), outer_start, outer_end)
	var edit_end := clampf(float(station_window.get("edit_end_m", outer_end)), edit_start, outer_end)
	var stations: Array = []
	var step := maxf(_source_spacing_m, 1.0)
	var station := outer_start
	while station < outer_end - 0.001:
		stations.append(station)
		station += step
	stations.append(outer_end)
	for knot_variant in heading_knots:
		if knot_variant is Dictionary:
			stations.append(clampf(float((knot_variant as Dictionary).get("station_m", outer_start)), outer_start, outer_end))
	for knot_variant in absolute_heading_knots:
		if knot_variant is Dictionary:
			stations.append(clampf(float((knot_variant as Dictionary).get("station_m", outer_start)), outer_start, outer_end))
	for knot_variant in grade_knots:
		if knot_variant is Dictionary:
			stations.append(clampf(float((knot_variant as Dictionary).get("station_m", outer_start)), outer_start, outer_end))
	stations.sort()
	var unique_stations: Array = []
	for station_variant in stations:
		var unique_station := float(station_variant)
		if unique_stations.is_empty() or absf(unique_station - float(unique_stations.back())) > 0.001:
			unique_stations.append(unique_station)
	if unique_stations.size() < 2:
		_error_message = "R37 representative %s could not generate knot stations" % candidate_id
		return false
	var positions: Array[Vector3] = []
	var target_headings: Array[float] = []
	var target_grades: Array[float] = []
	for station_variant in unique_stations:
		var sample_station := float(station_variant)
		var target_heading := _source_heading_at(sample_station) + deg_to_rad(_piecewise_knot_value(heading_knots, sample_station, "delta_deg"))
		if not absolute_heading_knots.is_empty():
			target_heading = deg_to_rad(_piecewise_knot_value(absolute_heading_knots, sample_station, "absolute_heading_deg"))
		target_headings.append(target_heading)
		target_grades.append(_target_grade_from_knots(grade_knots, sample_station, edit_start, edit_end, outer_start, outer_end))
	_apply_grade_closure(target_grades, unique_stations, edit_start, edit_end, outer_start, outer_end)
	positions.append(Vector3.ZERO)
	positions[0] = _source_pos_at(outer_start)
	for index in range(1, unique_stations.size()):
		var previous_station := float(unique_stations[index - 1])
		var current_station := float(unique_stations[index])
		var span := maxf(current_station - previous_station, 0.001)
		var mean_heading := lerp_angle(target_headings[index - 1], target_headings[index], 0.5)
		var horizontal_forward := Vector3(sin(mean_heading), 0.0, -cos(mean_heading))
		var mean_grade := 0.5 * (target_grades[index - 1] + target_grades[index])
		var previous_position: Vector3 = positions[index - 1]
		positions[index] = previous_position + horizontal_forward * span + Vector3.UP * (mean_grade * span / 100.0)
	var endpoint_residual: Vector3 = _source_pos_at(outer_end) - positions.back()
	_fit_endpoint_residual_m = endpoint_residual.length()
	_fit_samples.clear()
	for index in unique_stations.size():
		var sample_station := float(unique_stations[index])
		var normalized := (sample_station - outer_start) / maxf(outer_end - outer_start, 0.001)
		var correction_weight := smoothstep(0.0, 1.0, normalized)
		var corrected_position: Vector3 = (positions[index] as Vector3) + endpoint_residual * correction_weight
		var heading := target_headings[index]
		var tangent := Vector3(sin(heading), target_grades[index] * 0.01, -cos(heading)).normalized()
		_fit_samples.append({"station_m": sample_station, "position": corrected_position, "tangent": tangent})
	_window_start_m = outer_start
	_window_end_m = outer_end
	_authored_window_start_m = outer_start
	_authored_window_end_m = outer_end
	_window_start_m = floorf(outer_start / maxf(_source_spacing_m, 0.001)) * _source_spacing_m
	_window_end_m = ceilf(outer_end / maxf(_source_spacing_m, 0.001)) * _source_spacing_m
	_window_start_m = clampf(_window_start_m, 0.0, _route_length_m)
	_window_end_m = clampf(_window_end_m, _window_start_m, _route_length_m)
	_corridor_falloff_m = maxf(float(station_window.get("boundary_blend_range_m", DEFAULT_CORRIDOR_FALLOFF_M)), 1.0)
	return true

func _apply_grade_closure(grades: Array[float], stations: Array, edit_start: float, edit_end: float, outer_start: float, outer_end: float) -> void:
	if grades.size() < 2 or stations.size() != grades.size():
		return
	var integrated_height := 0.0
	var bump_integral := 0.0
	for index in range(1, stations.size()):
		var previous_station := float(stations[index - 1])
		var current_station := float(stations[index])
		var span := maxf(current_station - previous_station, 0.001)
		integrated_height += 0.5 * (grades[index - 1] + grades[index]) * span / 100.0
		var previous_bump := _blend_bump(previous_station, outer_start, edit_start) + _blend_bump(previous_station, edit_end, outer_end)
		var current_bump := _blend_bump(current_station, outer_start, edit_start) + _blend_bump(current_station, edit_end, outer_end)
		bump_integral += 0.5 * (previous_bump + current_bump) * span / 100.0
	var native_height_delta := _source_pos_at(outer_end).y - _source_pos_at(outer_start).y
	var raw_residual := integrated_height - native_height_delta
	var amplitude := -raw_residual / bump_integral if absf(bump_integral) > 0.000001 else 0.0
	_fit_height_closure_peak_pct = amplitude
	for index in grades.size():
		var station := float(stations[index])
		var bump := _blend_bump(station, outer_start, edit_start) + _blend_bump(station, edit_end, outer_end)
		grades[index] += amplitude * bump

func _blend_bump(station: float, start: float, end: float) -> float:
	if station <= start or station >= end or end <= start:
		return 0.0
	var normalized := clampf((station - start) / (end - start), 0.0, 1.0)
	return 4.0 * normalized * (1.0 - normalized)

func _piecewise_knot_value(knots: Array, station: float, value_key: String) -> float:
	if knots.is_empty():
		return 0.0
	var first: Dictionary = knots.front() as Dictionary
	var last: Dictionary = knots.back() as Dictionary
	if station <= float(first.get("station_m", station)):
		return float(first.get(value_key, 0.0))
	if station >= float(last.get("station_m", station)):
		return float(last.get(value_key, 0.0))
	for index in range(knots.size() - 1):
		var left: Dictionary = knots[index] as Dictionary
		var right: Dictionary = knots[index + 1] as Dictionary
		var left_station := float(left.get("station_m", station))
		var right_station := float(right.get("station_m", left_station))
		if station <= right_station:
			var weight := clampf((station - left_station) / maxf(right_station - left_station, 0.001), 0.0, 1.0)
			return lerpf(float(left.get(value_key, 0.0)), float(right.get(value_key, 0.0)), smoothstep(0.0, 1.0, weight))
	return float(last.get(value_key, 0.0))

func _target_grade_from_knots(knots: Array, station: float, edit_start: float, edit_end: float, outer_start: float, outer_end: float) -> float:
	var native_grade := _source_grade_at(station)
	if station < edit_start:
		if station <= outer_start:
			return native_grade
		var first_target := _piecewise_knot_value(knots, edit_start, "target_pct")
		var weight := smoothstep(0.0, 1.0, (station - outer_start) / maxf(edit_start - outer_start, 0.001))
		return lerpf(native_grade, first_target, weight)
	if station > edit_end:
		if station >= outer_end:
			return native_grade
		var last_target := _piecewise_knot_value(knots, edit_end, "target_pct")
		var weight_after := smoothstep(0.0, 1.0, (outer_end - station) / maxf(outer_end - edit_end, 0.001))
		return lerpf(native_grade, last_target, weight_after)
	return _piecewise_knot_value(knots, station, "target_pct")

func _prepare_source_bins() -> void:
	_source_bins.clear()
	var first := maxi(int(floor((_window_start_m - _corridor_falloff_m) / _source_spacing_m)) - 2, 0)
	var last := mini(_source_samples.size() - 2, int(ceil((_window_end_m + _corridor_falloff_m) / _source_spacing_m)) + 2)
	if _source_samples.size() < 2 or last < first:
		_warp_bounds_ready = false
		return
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for index in range(first, mini(last + 1, _source_samples.size() - 1) + 1):
		var sample := _source_samples[index]
		min_x = minf(min_x, sample.x)
		min_z = minf(min_z, sample.z)
		max_x = maxf(max_x, sample.x)
		max_z = maxf(max_z, sample.z)
	var lateral_margin := _corridor_half_width_m + _corridor_falloff_m + SOURCE_BIN_SIZE_M
	_warp_bounds_min = Vector2(min_x - lateral_margin, min_z - lateral_margin)
	_warp_bounds_max = Vector2(max_x + lateral_margin, max_z + lateral_margin)
	_warp_bounds_ready = is_finite(min_x) and is_finite(min_z) and is_finite(max_x) and is_finite(max_z)
	for index in range(first, last + 1):
		var a := _source_samples[index]
		var b := _source_samples[index + 1]
		var bin_min_x := floori(minf(a.x, b.x) / SOURCE_BIN_SIZE_M)
		var bin_max_x := floori(maxf(a.x, b.x) / SOURCE_BIN_SIZE_M)
		var bin_min_z := floori(minf(a.z, b.z) / SOURCE_BIN_SIZE_M)
		var bin_max_z := floori(maxf(a.z, b.z) / SOURCE_BIN_SIZE_M)
		for bin_x in range(bin_min_x, bin_max_x + 1):
			for bin_z in range(bin_min_z, bin_max_z + 1):
				var key := _bin_key(bin_x, bin_z)
				if not _source_bins.has(key):
					_source_bins[key] = []
				(_source_bins[key] as Array).append(index)

func _bin_key(bin_x: int, bin_z: int) -> String:
	return "%d:%d" % [bin_x, bin_z]

func _warp_scene_geometry(root: Node) -> void:
	if root == null:
		return
	for child in root.get_children():
		var mesh_node := child as MeshInstance3D
		if mesh_node != null:
			if _warp_mesh_node(mesh_node, not _is_road_surface_node(mesh_node)):
				_mesh_node_count += 1
		var multimesh_node := child as MultiMeshInstance3D
		if multimesh_node != null:
			if _warp_multimesh_node(multimesh_node, not _is_road_surface_node(multimesh_node)):
				_multimesh_node_count += 1
		var collision_node := child as CollisionShape3D
		if collision_node != null:
			if _warp_collision_node(collision_node, not _is_road_surface_node(collision_node)):
				_collision_node_count += 1
		_warp_scene_geometry(child)

func _warp_mesh_node(mesh_node: MeshInstance3D, apply_terrain_profile := true) -> bool:
	if mesh_node.mesh == null or mesh_node.mesh.get_surface_count() <= 0:
		return false
	if not _world_aabb_overlaps_warp_bounds(mesh_node.global_transform, mesh_node.get_aabb()):
		return false
	var source_mesh: Mesh = mesh_node.mesh
	var replacement := ArrayMesh.new()
	var transformed_any := false
	var node_transform := mesh_node.global_transform
	var inverse_transform := node_transform.affine_inverse()
	var keep_upright := _is_upright_rigid_node(mesh_node)
	for surface_index in source_mesh.get_surface_count():
		var arrays: Array = source_mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
			continue
		var source_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var warped_vertices := PackedVector3Array()
		warped_vertices.resize(source_vertices.size())
		for index in source_vertices.size():
			var world := node_transform * source_vertices[index]
			var warped_world := _warp_world_point(world, keep_upright, apply_terrain_profile)
			warped_vertices[index] = inverse_transform * warped_world
			if warped_world.distance_squared_to(world) > 0.000001:
				transformed_any = true
			_warped_vertex_count += 1
		arrays[Mesh.ARRAY_VERTEX] = warped_vertices
		replacement.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material := source_mesh.surface_get_material(surface_index)
		if material != null:
			replacement.surface_set_material(replacement.get_surface_count() - 1, material)
	if not transformed_any:
		return false
	mesh_node.mesh = replacement
	return true

func _warp_multimesh_node(instance: MultiMeshInstance3D, apply_terrain_profile := true) -> bool:
	if instance.multimesh == null or instance.multimesh.transform_format != MultiMesh.TRANSFORM_3D:
		return false
	if not _world_aabb_overlaps_warp_bounds(instance.global_transform, instance.multimesh.get_aabb()):
		return false
	var source_multi: MultiMesh = instance.multimesh
	var replacement := source_multi.duplicate(true) as MultiMesh
	if replacement == null:
		return false
	var changed := false
	var inverse := instance.global_transform.affine_inverse()
	var keep_upright := _is_upright_multimesh(instance)
	for index in source_multi.instance_count:
		var local_transform := source_multi.get_instance_transform(index)
		var world_transform := instance.global_transform * local_transform
		var warped_origin := _warp_world_point(world_transform.origin, false, apply_terrain_profile)
		var station := _source_station_for_world(world_transform.origin)
		var weight := _station_weight(station) * _lateral_weight(station, world_transform.origin)
		var delta_basis := _frame_delta_basis(station, keep_upright)
		var blended_basis := Basis(Quaternion().slerp(delta_basis.get_rotation_quaternion(), weight)) * world_transform.basis
		var warped_world := Transform3D(blended_basis, warped_origin)
		replacement.set_instance_transform(index, inverse * warped_world)
		if warped_origin.distance_squared_to(world_transform.origin) > 0.000001:
			changed = true
		_warped_instance_count += 1
	if not changed:
		return false
	instance.multimesh = replacement
	return true

func _warp_collision_node(collision_node: CollisionShape3D, apply_terrain_profile := true) -> bool:
	var source_shape := collision_node.shape as ConcavePolygonShape3D
	if source_shape == null:
		return false
	var source_faces := source_shape.get_faces()
	if source_faces.is_empty():
		return false
	var replacement_faces := PackedVector3Array()
	var inverse := collision_node.global_transform.affine_inverse()
	var changed := false
	for point in source_faces:
		var world := collision_node.global_transform * point
		var warped_world := _warp_world_point(world, false, apply_terrain_profile)
		replacement_faces.append(inverse * warped_world)
		if warped_world.distance_squared_to(world) > 0.000001:
			changed = true
	if not changed:
		return false
	var replacement := ConcavePolygonShape3D.new()
	replacement.set_faces(replacement_faces)
	collision_node.shape = replacement
	return true

func _apply_route_fit() -> void:
	var warped_samples: Array[Vector3] = []
	var warped_headings := PackedFloat32Array()
	var warped_elevations := PackedFloat32Array()
	warped_headings.resize(_source_samples.size())
	warped_elevations.resize(_source_samples.size())
	var geo_datum_m := 0.0
	var geo_datum_value: Variant = _route.get("geo_datum_m")
	if geo_datum_value != null:
		geo_datum_m = float(geo_datum_value)
	for index in _source_samples.size():
		var station := minf(float(index) * _source_spacing_m, _route_length_m)
		var weight := _station_weight(station)
		var frame := _target_frame_at(station)
		var source_position := _source_samples[index]
		var target_position: Vector3 = frame.get("position", source_position)
		warped_samples.append(source_position.lerp(target_position, weight))
		# SaisiesGeoRoute stores ASL elevations while route sample Y is local
		# DEM-minus-datum space. Keep the route's public elevation contract in ASL.
		warped_elevations[index] = warped_samples[index].y + geo_datum_m
	# Derive headings from the final warped positions. This keeps Route.tangent_at,
	# the visible road mesh, and the anchored fit on one geometric source of truth.
	for index in warped_samples.size():
		var previous_index := maxi(index - 1, 0)
		var next_index := mini(index + 1, warped_samples.size() - 1)
		var delta := warped_samples[next_index] - warped_samples[previous_index]
		var horizontal_tangent := Vector3(delta.x, 0.0, delta.z)
		if horizontal_tangent.length_squared() > 0.000001:
			warped_headings[index] = _heading_from_vector(horizontal_tangent.normalized())
		else:
			warped_headings[index] = float(_source_headings[index])
	var warped_grades := PackedFloat32Array()
	warped_grades.resize(warped_samples.size())
	for index in warped_samples.size():
		if index == 0:
			warped_grades[index] = _grade_between(warped_samples[0], warped_samples[1])
		elif index == warped_samples.size() - 1:
			warped_grades[index] = _grade_between(warped_samples[index - 1], warped_samples[index])
		else:
			warped_grades[index] = _grade_between(warped_samples[index - 1], warped_samples[index + 1])
	_route.set("_samples", warped_samples)
	_route.set("_headings", warped_headings)
	_route.set("_elevations", warped_elevations)
	_route.set("_grades", warped_grades)
	if _route.has_method("_build_curve"):
		_route.call("_build_curve")
	_refresh_geography_route_samples(warped_samples)
	_refresh_landscape_road_cache()

func _refresh_geography_route_samples(samples: Array[Vector3]) -> void:
	if _route == null:
		return
	var geography := _route.get("geography") as Object
	if geography == null or not geography.has_method("set_route_samples"):
		return
	var points := PackedVector3Array()
	points.resize(samples.size())
	for index in samples.size():
		points[index] = samples[index]
	var half_width := float(_route.get("road_width_m")) * 0.5
	geography.call("set_route_samples", points, maxf(half_width, 2.0))
	set_meta("saisies_r37_geography_route_updated", true)

func _refresh_landscape_road_cache() -> void:
	if _world == null:
		return
	var landscape := _world.find_child("SaisiesGeoLandscape", true, false)
	if landscape != null and landscape.has_method("_build_road_surface_cache"):
		landscape.call("_build_road_surface_cache")
		set_meta("saisies_r37_landscape_road_cache_updated", true)

func _grade_between(a: Vector3, b: Vector3) -> float:
	var horizontal_span_m := Vector2(b.x, b.z).distance_to(Vector2(a.x, a.z))
	return (b.y - a.y) / maxf(horizontal_span_m, 0.001) * 100.0

func _freeze_camera_writers() -> void:
	if _rig == null or _camera == null:
		return
	_rig.set_process(false)
	_rig.set_physics_process(false)
	if _rig.has_method("set"):
		_rig.set("auto_advance", false)
	_freeze_named_writers(_world)
	_camera.current = true

func _freeze_named_writers(node: Node) -> void:
	for child in node.get_children():
		if String(child.name) in ["S01CameraController", "S02ReviewController", "S03ReviewController", "S04LinkedBendsReview", "S04LateBendsReview", "S04BatchReview"]:
			child.set_process(false)
			child.set_physics_process(false)
		_freeze_named_writers(child)

func _apply_camera_pose() -> void:
	var camera_variant: Variant = _candidate.get("camera", {})
	var camera_data: Dictionary = {}
	if camera_variant is Dictionary:
		camera_data = camera_variant as Dictionary
	_camera_data = camera_data.duplicate(true)
	var station := _initial_camera_station(camera_data)
	var initial_source_time := _initial_source_time(camera_data, station)
	_tour_time_s = initial_source_time
	_tour_active = auto_tour and not is_finite(_override_station) and _source_sequence.size() >= 2 and _source_time_end_s > _source_time_start_s
	if _tour_active:
		_tour_time_s = _source_time_start_s
		_apply_camera_source_time(_tour_time_s, camera_data)
		return
	_apply_camera_station(station, camera_data)

func _initial_camera_station(camera_data: Dictionary) -> float:
	var default_station := float((_fit_samples.front() as Dictionary).get("station_m", 0.0)) if not _fit_samples.is_empty() else 0.0
	var anchor_variant: Variant = _candidate.get("baseline_anchor", {})
	var anchor_data: Dictionary = anchor_variant as Dictionary if anchor_variant is Dictionary else {}
	if anchor_data.has("station_m"):
		default_station = float(anchor_data.get("station_m", default_station))
	var station := default_station
	if camera_data.has("station_m"):
		station = float(camera_data.get("station_m", station))
	elif camera_data.has("source_time_s"):
		station = _station_for_source_time(float(camera_data.get("source_time_s", _source_time_start_s)))
	elif anchor_data.has("source_time_s"):
		station = _station_for_source_time(float(anchor_data.get("source_time_s", _source_time_start_s)))
	if camera_data.has("station_m") or camera_data.has("source_time_s") or anchor_data.has("station_m") or anchor_data.has("source_time_s"):
		station = clampf(station, 0.0, _route_length_m)
	if is_finite(_override_station):
		station = _override_station
	return clampf(station, 0.0, _route_length_m)

func _initial_source_time(camera_data: Dictionary, station: float) -> float:
	if camera_data.has("source_time_s"):
		return float(camera_data.get("source_time_s", _source_time_start_s))
	var anchor_variant: Variant = _candidate.get("baseline_anchor", {})
	if anchor_variant is Dictionary and (anchor_variant as Dictionary).has("source_time_s"):
		return float((anchor_variant as Dictionary).get("source_time_s", _source_time_start_s))
	if _source_sequence.size() >= 2:
		var best_time := _source_time_start_s
		var best_distance := INF
		for raw_row in _source_sequence:
			var row: Dictionary = raw_row as Dictionary
			var distance := absf(float(row.get("station_m", 0.0)) - station)
			if distance < best_distance:
				best_distance = distance
				best_time = float(row.get("source_time_s", best_time))
		return best_time
	return _source_time_start_s

func _apply_camera_source_time(source_time: float, camera_data: Dictionary = {}) -> void:
	_tour_time_s = clampf(source_time, _source_time_start_s, _source_time_end_s)
	var station := _station_for_source_time(_tour_time_s)
	var effective_camera_data: Dictionary = _camera_data if camera_data.is_empty() else camera_data
	_apply_camera_station(station, effective_camera_data)

func _apply_camera_station(station: float, camera_data: Dictionary = {}) -> void:
	station = clampf(station, 0.0, _route_length_m)
	var tangent := Vector3(_route.call("tangent_at", station)).normalized()
	var left := Vector3(_route.call("left_at", station)).normalized()
	var lateral := float(camera_data.get("lateral_m", DEFAULT_LATERAL_M))
	var default_pitch := DEFAULT_PITCH_DEG
	if candidate_id.to_upper() == "S06":
		default_pitch = -16.0
	var pitch := float(camera_data.get("pitch_deg", default_pitch))
	var position := Vector3(_route.call("pos_at", station)) + left * lateral
	if _route.has_method("ground_y"):
		position.y = float(_route.call("ground_y", station, lateral))
	_rig.global_position = position
	_rig.rotation = Vector3(deg_to_rad(pitch), atan2(-tangent.x, -tangent.z) + deg_to_rad(float(camera_data.get("yaw_deg", DEFAULT_YAW_DEG))), 0.0)
	_camera.global_position = position + Vector3.UP * float(camera_data.get("height_m", DEFAULT_HEIGHT_M))
	_camera.rotation = Vector3.ZERO
	_camera.fov = clampf(float(camera_data.get("fov_deg", DEFAULT_FOV_DEG)), 30.0, 120.0)
	_camera.current = true

func _update_tour_meta() -> void:
	set_meta("saisies_r37_representative_tour_enabled", auto_tour)
	set_meta("saisies_r37_representative_tour_active", _tour_active)
	set_meta("saisies_r37_representative_tour_paused", _tour_paused)
	set_meta("saisies_r37_representative_source_time_s", _tour_time_s)
	set_meta("saisies_r37_representative_source_time_range_s", [_source_time_start_s, _source_time_end_s])

func _source_pos_at(station: float) -> Vector3:
	if _source_samples.is_empty():
		return Vector3.ZERO
	var f := clampf(station / maxf(_source_spacing_m, 0.001), 0.0, float(_source_samples.size() - 1))
	var index := clampi(int(floor(f)), 0, _source_samples.size() - 1)
	var next := mini(index + 1, _source_samples.size() - 1)
	return _source_samples[index].lerp(_source_samples[next], f - float(index))

func _source_tangent_at(station: float) -> Vector3:
	var before := _source_pos_at(maxf(station - 2.0, 0.0))
	var after := _source_pos_at(minf(station + 2.0, _route_length_m))
	var tangent := (after - before).normalized()
	return tangent if tangent.length_squared() > 0.000001 else Vector3(0.0, 0.0, -1.0)

func _source_heading_at(station: float) -> float:
	if _source_headings.size() == _source_samples.size() and not _source_headings.is_empty():
		var f := clampf(station / maxf(_source_spacing_m, 0.001), 0.0, float(_source_headings.size() - 1))
		var index := clampi(int(floor(f)), 0, _source_headings.size() - 1)
		var next := mini(index + 1, _source_headings.size() - 1)
		return lerp_angle(float(_source_headings[index]), float(_source_headings[next]), f - float(index))
	return _heading_from_vector(_source_tangent_at(station))

func _source_grade_at(station: float) -> float:
	if _source_grades.size() == _source_samples.size() and not _source_grades.is_empty():
		var f := clampf(station / maxf(_source_spacing_m, 0.001), 0.0, float(_source_grades.size() - 1))
		var index := clampi(int(floor(f)), 0, _source_grades.size() - 1)
		var next := mini(index + 1, _source_grades.size() - 1)
		return lerpf(float(_source_grades[index]), float(_source_grades[next]), f - float(index))
	if _route != null and _route.has_method("grade_at"):
		return float(_route.call("grade_at", station))
	var before := _source_pos_at(maxf(station - 2.0, 0.0))
	var after := _source_pos_at(minf(station + 2.0, _route_length_m))
	return _grade_between(before, after)

func _target_frame_at(station: float) -> Dictionary:
	if _fit_samples.is_empty():
		return {"position": _source_pos_at(station), "tangent": _source_tangent_at(station)}
	var first: Dictionary = _fit_samples.front()
	var last: Dictionary = _fit_samples.back()
	if _fit_samples.size() == 1:
		return {"position": first.get("position", _source_pos_at(station)), "tangent": first.get("tangent", _source_tangent_at(station))}
	var first_station := float(first.get("station_m", station))
	var last_station := float(last.get("station_m", station))
	if station <= first_station or station >= last_station:
		return {"position": _source_pos_at(station), "tangent": _source_tangent_at(station)}
	var a: Dictionary = first
	var b: Dictionary = last
	for index in range(_fit_samples.size() - 1):
		var candidate_a: Dictionary = _fit_samples[index]
		var candidate_b: Dictionary = _fit_samples[index + 1]
		if station <= float(candidate_b.get("station_m", station)):
			a = candidate_a
			b = candidate_b
			break
	var s0 := float(a.get("station_m", station))
	var s1 := float(b.get("station_m", s0))
	var t := clampf((station - s0) / maxf(s1 - s0, 0.001), 0.0, 1.0)
	var position_a: Vector3 = a.get("position", _source_pos_at(s0))
	var position_b: Vector3 = b.get("position", _source_pos_at(s1))
	var position := position_a.lerp(position_b, t)
	var tangent_a: Vector3 = a.get("tangent", Vector3.ZERO)
	var tangent_b: Vector3 = b.get("tangent", Vector3.ZERO)
	var tangent := tangent_a.lerp(tangent_b, t).normalized()
	if tangent.length_squared() <= 0.000001:
		tangent = (position_b - position_a).normalized()
	if tangent.length_squared() <= 0.000001:
		tangent = _source_tangent_at(station)
	return {"position": position, "tangent": tangent}

func _frame_delta_basis(station: float, keep_upright := false) -> Basis:
	var source_tangent := _source_tangent_at(station)
	var target_frame := _target_frame_at(station)
	var target_tangent: Vector3 = target_frame.get("tangent", source_tangent)
	if keep_upright:
		source_tangent = _horizontal_tangent(source_tangent)
		target_tangent = _horizontal_tangent(target_tangent)
	var source_basis := Basis.looking_at(source_tangent, Vector3.UP)
	var target_basis := Basis.looking_at(target_tangent, Vector3.UP)
	return target_basis * source_basis.inverse()

func _station_weight(station: float) -> float:
	if station < _window_start_m - _corridor_falloff_m or station > _window_end_m + _corridor_falloff_m:
		return 0.0
	var weight := 1.0
	if station < _window_start_m:
		weight = smoothstep(0.0, 1.0, (station - (_window_start_m - _corridor_falloff_m)) / _corridor_falloff_m)
	elif station > _window_end_m:
		weight = 1.0 - smoothstep(0.0, 1.0, (station - _window_end_m) / _corridor_falloff_m)
	return clampf(weight, 0.0, 1.0)

func _lateral_weight(station: float, world_position: Vector3) -> float:
	var center := _source_pos_at(station)
	var tangent := _source_tangent_at(station)
	var left := Vector3(tangent.z, 0.0, -tangent.x).normalized()
	var lateral := absf(left.dot(world_position - center))
	if lateral <= _corridor_half_width_m:
		return 1.0
	return 1.0 - smoothstep(_corridor_half_width_m, _corridor_half_width_m + _corridor_falloff_m, lateral)

func _frame_delta_transform(station: float, keep_upright := false) -> Transform3D:
	var source_center := _source_pos_at(station)
	var target_frame := _target_frame_at(station)
	var source_tangent := _source_tangent_at(station)
	var target_tangent: Vector3 = target_frame.get("tangent", source_tangent)
	if keep_upright:
		source_tangent = _horizontal_tangent(source_tangent)
		target_tangent = _horizontal_tangent(target_tangent)
	var source_basis := Basis.looking_at(source_tangent, Vector3.UP)
	var target_basis := Basis.looking_at(target_tangent, Vector3.UP)
	var rotation := target_basis * source_basis.inverse()
	var target_position: Vector3 = target_frame.get("position", source_center)
	return Transform3D(rotation, target_position - rotation * source_center)

func _warp_world_point(world_position: Vector3, keep_upright := false, apply_terrain_profile := true) -> Vector3:
	if not _warp_bounds_contains(world_position):
		return world_position
	var station := _source_station_for_world(world_position)
	if station < 0.0:
		return world_position
	var weight := _station_weight(station) * _lateral_weight(station, world_position)
	if weight <= 0.00001:
		return world_position
	var mapped := _frame_delta_transform(station, keep_upright) * world_position
	var result := world_position.lerp(mapped, weight)
	var tangent := _source_tangent_at(station)
	var left := Vector3(tangent.z, 0.0, -tangent.x).normalized()
	var lateral := left.dot(world_position - _source_pos_at(station))
	result.y += _cross_section_y_offset(station, lateral) * weight
	if apply_terrain_profile and _terrain_profile_ready:
		result.y += _terrain_profile_y_offset(station, lateral) * _terrain_profile_station_weight(station)
	return result

func _terrain_profile_station_weight(station: float) -> float:
	if not _terrain_profile_ready or station <= _terrain_profile_outer_start_m or station >= _terrain_profile_outer_end_m:
		return 0.0
	if station < _terrain_profile_edit_start_m:
		return smoothstep(0.0, 1.0, (station - _terrain_profile_outer_start_m) / maxf(_terrain_profile_edit_start_m - _terrain_profile_outer_start_m, 0.001))
	if station <= _terrain_profile_edit_end_m:
		return 1.0
	return 1.0 - smoothstep(0.0, 1.0, (station - _terrain_profile_edit_end_m) / maxf(_terrain_profile_outer_end_m - _terrain_profile_edit_end_m, 0.001))

func _terrain_profile_y_offset(station: float, lateral: float) -> float:
	if not _terrain_profile_ready or _terrain_profile_stations.size() < 2 or _terrain_profile_offsets.is_empty() or lateral <= 4.0 or lateral >= 80.0:
		return 0.0
	var station_f := clampf(station, float(_terrain_profile_stations[0]), float(_terrain_profile_stations[_terrain_profile_stations.size() - 1]))
	var lower_station_index := 0
	for index in range(_terrain_profile_stations.size() - 1):
		if station_f <= float(_terrain_profile_stations[index + 1]):
			lower_station_index = index
			break
	var upper_station_index := mini(lower_station_index + 1, _terrain_profile_stations.size() - 1)
	var station_t := clampf((station_f - float(_terrain_profile_stations[lower_station_index])) / maxf(float(_terrain_profile_stations[upper_station_index] - _terrain_profile_stations[lower_station_index]), 0.001), 0.0, 1.0)
	var lower_row: Array = _terrain_profile_offsets[lower_station_index] as Array
	var upper_row: Array = _terrain_profile_offsets[upper_station_index] as Array
	var lower_offset := _terrain_profile_lateral_offset(lower_row, lateral)
	var upper_offset := _terrain_profile_lateral_offset(upper_row, lateral)
	return lerpf(lower_offset, upper_offset, station_t)

func _terrain_profile_lateral_offset(row: Array, lateral: float) -> float:
	if row.is_empty():
		return 0.0
	var lateral_f := clampf(lateral, float(S10_TERRAIN_PROFILE_LATERALS[0]), float(S10_TERRAIN_PROFILE_LATERALS.back()))
	for index in range(row.size() - 1):
		var left_lateral := float(S10_TERRAIN_PROFILE_LATERALS[index])
		var right_lateral := float(S10_TERRAIN_PROFILE_LATERALS[index + 1])
		if lateral_f <= right_lateral:
			var t := clampf((lateral_f - left_lateral) / maxf(right_lateral - left_lateral, 0.001), 0.0, 1.0)
			return lerpf(float(row[index]), float(row[index + 1]), t)
	return float(row.back())

func _cross_section_y_offset(station: float, lateral: float) -> float:
	for override_variant in _cross_section_overrides:
		if not (override_variant is Dictionary):
			continue
		var override: Dictionary = override_variant as Dictionary
		var start := float(override.get("start_m", override.get("station_start_m", _window_start_m)))
		var end := float(override.get("end_m", override.get("station_end_m", _window_end_m)))
		if station < start or station > end:
			continue
		var profile_variant: Variant = override.get("samples", override.get("profile", []))
		if not (profile_variant is Array):
			continue
		var profile: Array = profile_variant as Array
		if profile.is_empty():
			continue
		var lower: Dictionary = profile.front() as Dictionary
		var upper: Dictionary = profile.back() as Dictionary
		var first_lateral := float(lower.get("lateral_m", 0.0))
		var last_lateral := float(upper.get("lateral_m", first_lateral))
		if lateral <= first_lateral:
			return float(lower.get("height_offset_m", lower.get("y_offset_m", 0.0)))
		if lateral >= last_lateral:
			return float(upper.get("height_offset_m", upper.get("y_offset_m", 0.0)))
		for index in range(profile.size() - 1):
			var a: Dictionary = profile[index]
			var b: Dictionary = profile[index + 1]
			if lateral <= float(b.get("lateral_m", 0.0)):
				lower = a
				upper = b
				break
		var l0 := float(lower.get("lateral_m", lateral))
		var l1 := float(upper.get("lateral_m", l0))
		var t := clampf((lateral - l0) / maxf(l1 - l0, 0.001), 0.0, 1.0)
		return lerpf(float(lower.get("height_offset_m", lower.get("y_offset_m", 0.0))), float(upper.get("height_offset_m", upper.get("y_offset_m", 0.0))), t)
	return 0.0

func _horizontal_tangent(value: Vector3) -> Vector3:
	var horizontal := Vector3(value.x, 0.0, value.z)
	return horizontal.normalized() if horizontal.length_squared() > 0.000001 else Vector3(0.0, 0.0, -1.0)

func _is_road_surface_node(node: Node) -> bool:
	# The S10 bank profile is a terrain-only correction.  The baked road mesh,
	# centre markings, and concave road collision must continue to follow the
	# fitted Route samples exactly; applying a terrain offset to any of their
	# vertices creates an API/visible-road mismatch at the steep S10 grade.
	var current := node
	while current != null:
		var name := String(current.name).to_lower()
		if name == "saisiesasphalt" or name == "centredashedmarkings" or name == "saisiesroadcollision" or name == "continuousroadsurface":
			return true
		if name.contains("roadcollision") or name.contains("asphalt") or name.contains("marking"):
			return true
		current = current.get_parent()
	return false

func _is_upright_multimesh(instance: MultiMeshInstance3D) -> bool:
	var name := String(instance.name).to_lower()
	var source_module := String(instance.get_meta("saisies_release_cache_source_module", "")).to_lower()
	return source_module.contains("forest") or name.contains("forest") or name.contains("tree") or instance.has_meta("saisies_release_forest_family")

func _is_upright_rigid_node(node: Node) -> bool:
	var identity := (String(node.name) + " " + String(node.get_meta("saisies_release_cache_source_path", ""))).to_lower()
	for token in ["chalet", "farm", "barn", "shed", "kiosk", "building", "house", "cafe", "shop"]:
		if identity.contains(token):
			return true
	return false

func _warp_bounds_contains(world_position: Vector3) -> bool:
	return _warp_bounds_ready and world_position.x >= _warp_bounds_min.x and world_position.x <= _warp_bounds_max.x and world_position.z >= _warp_bounds_min.y and world_position.z <= _warp_bounds_max.y

func _world_aabb_overlaps_warp_bounds(transform: Transform3D, local_aabb: AABB) -> bool:
	if not _warp_bounds_ready:
		return true
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for x in [local_aabb.position.x, local_aabb.end.x]:
		for y in [local_aabb.position.y, local_aabb.end.y]:
			for z in [local_aabb.position.z, local_aabb.end.z]:
				var point := transform * Vector3(float(x), float(y), float(z))
				min_x = minf(min_x, point.x)
				min_z = minf(min_z, point.z)
				max_x = maxf(max_x, point.x)
				max_z = maxf(max_z, point.z)
	return max_x >= _warp_bounds_min.x and min_x <= _warp_bounds_max.x and max_z >= _warp_bounds_min.y and min_z <= _warp_bounds_max.y

func _source_station_for_world(world_position: Vector3) -> float:
	if _source_samples.size() < 2:
		return -1.0
	if not _warp_bounds_contains(world_position):
		return -1.0
	var bin_x := floori(world_position.x / SOURCE_BIN_SIZE_M)
	var bin_z := floori(world_position.z / SOURCE_BIN_SIZE_M)
	var seen_segments: Dictionary = {}
	var best_distance := INF
	var best_station := clampf(_window_start_m, 0.0, _route_length_m)
	for radius in range(0, 4):
		var ring_segments: Array = []
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				var key := _bin_key(bin_x + dx, bin_z + dz)
				if _source_bins.has(key):
					for index in _source_bins[key] as Array:
						var segment_index := int(index)
						if seen_segments.has(segment_index):
							continue
						seen_segments[segment_index] = true
						ring_segments.append(segment_index)
		for raw_index in ring_segments:
			var index := int(raw_index)
			if index < 0 or index + 1 >= _source_samples.size():
				continue
			var a := _source_samples[index]
			var b := _source_samples[index + 1]
			var delta := Vector2(b.x - a.x, b.z - a.z)
			var t := 0.0
			if delta.length_squared() > 0.000001:
				t = clampf(Vector2(world_position.x - a.x, world_position.z - a.z).dot(delta) / delta.length_squared(), 0.0, 1.0)
			var nearest := a.lerp(b, t)
			var distance := Vector2(world_position.x - nearest.x, world_position.z - nearest.z).length_squared()
			if distance < best_distance:
				best_distance = distance
				best_station = minf((float(index) + t) * _source_spacing_m, _route_length_m)
		if best_distance < INF and radius < 3:
			var outside_lower_bound := _source_bin_exit_lower_bound(world_position, bin_x, bin_z, radius)
			if best_distance <= outside_lower_bound * outside_lower_bound:
				break
	if best_distance == INF:
		return -1.0
	return best_station

func _source_bin_exit_lower_bound(world_position: Vector3, bin_x: int, bin_z: int, radius: int) -> float:
	# Any segment not yet searched must be registered in a bin outside the
	# current square.  Its AABB would also have been registered in an inner bin
	# if it crossed that square, so the distance to the square's outside edge is
	# a safe lower bound for all remaining segment distances.
	var left_distance := world_position.x - float(bin_x - radius) * SOURCE_BIN_SIZE_M
	var right_distance := float(bin_x + radius + 1) * SOURCE_BIN_SIZE_M - world_position.x
	var back_distance := world_position.z - float(bin_z - radius) * SOURCE_BIN_SIZE_M
	var front_distance := float(bin_z + radius + 1) * SOURCE_BIN_SIZE_M - world_position.z
	return maxf(0.0, minf(minf(left_distance, right_distance), minf(back_distance, front_distance)))

func _read_vec3(source: Dictionary, keys: Array, fallback: Vector3) -> Vector3:
	for key_variant in keys:
		var key := String(key_variant)
		if source.has(key):
			var value: Variant = source.get(key)
			if value is Array and (value as Array).size() >= 3:
				var values: Array = value as Array
				return Vector3(float(values[0]), float(values[1]), float(values[2]))
			if value is Dictionary:
				var d: Dictionary = value as Dictionary
				return Vector3(float(d.get("x", fallback.x)), float(d.get("y", fallback.y)), float(d.get("z", fallback.z)))
	return fallback

func _heading_from_vector(value: Vector3) -> float:
	var horizontal := Vector3(value.x, 0.0, value.z)
	return atan2(horizontal.x, -horizontal.z) if horizontal.length_squared() > 0.000001 else 0.0

func _vec3_array(value: Vector3) -> Array[float]:
	return [value.x, value.y, value.z]

func _dressing_summary() -> Dictionary:
	return {
		"enabled": enable_dressing,
		"ready": bool(_dressing_report.get("ready", false)),
		"candidate_id": String(_dressing_report.get("candidate_id", candidate_id)),
		"terrain_sampler": String(_dressing_report.get("terrain_sampler", "")),
		"tree_count": int(_dressing_report.get("tree_count", 0)),
		"tree_target_count": int(_dressing_report.get("tree_target_count", 0)),
		"structure_count": int(_dressing_report.get("structure_count", 0)),
		"contact_count": int(_dressing_report.get("contact_count", 0)),
		"contact_miss_count": int(_dressing_report.get("contact_miss_count", 0)),
		"density_contract": bool(_dressing_report.get("density_contract", false)),
		"reason": String(_dressing_report.get("reason", "")),
		"error": String(_dressing_report.get("error", "")),
		"source_estimated": bool(_dressing_report.get("source_estimated", false)),
	}

func _terrain_profile_summary() -> Dictionary:
	return {
		"enabled": candidate_id.to_upper() == "S10",
		"ready": _terrain_profile_ready,
		"source": _terrain_profile_source,
		"station_step_m": S10_TERRAIN_PROFILE_STATION_STEP_M,
		"station_sample_count": _terrain_profile_stations.size(),
		"triangle_sample_count": _terrain_profile_sample_count,
		"triangle_miss_count": _terrain_profile_miss_count,
		"edit_start_m": _terrain_profile_edit_start_m,
		"edit_end_m": _terrain_profile_edit_end_m,
		"outer_start_m": _terrain_profile_outer_start_m,
		"outer_end_m": _terrain_profile_outer_end_m,
		"lateral_axis_m": S10_TERRAIN_PROFILE_LATERALS,
		"desired_height_above_road_m": S10_TERRAIN_PROFILE_DESIRED_RELATIVE_M,
	}

func _build_report() -> Dictionary:
	return {
		"schema_version": 1,
		"kind": "saisies_r37_representative_candidate",
		"status": "diagnostic_only",
		"formal_integration_allowed": false,
		"candidate_id": candidate_id,
		"candidate": _candidate,
		"world_scene": world_scene_path,
		"geometry_cache": geometry_cache_path,
		"dressing_path": dressing_path,
		"route": {
			"length_m": _route_length_m,
			"source_sample_count": _source_samples.size(),
			"source_spacing_m": _source_spacing_m,
			# The authored fit bounds may fall between native route samples.
			"authored_window_start_m": _authored_window_start_m,
			"authored_window_end_m": _authored_window_end_m,
			# Geometry deformation uses this grid-aligned envelope so the boundary
			# samples are retained instead of leaking one interpolation cell outside.
			"effective_window_start_m": _window_start_m,
			"effective_window_end_m": _window_end_m,
			# A vertex can interpolate against an adjacent native sample. Keep this
			# explicit for acceptance checks that compare unchanged geometry bounds.
			"affected_window_start_m": maxf(0.0, _window_start_m - _source_spacing_m),
			"affected_window_end_m": minf(_route_length_m, _window_end_m + _source_spacing_m),
			"window_start_m": _window_start_m,
			"window_end_m": _window_end_m,
			"corridor_half_width_m": _corridor_half_width_m,
			"corridor_falloff_m": _corridor_falloff_m,
			"geography_route_updated": bool(get_meta("saisies_r37_geography_route_updated", false)),
			"landscape_road_cache_updated": bool(get_meta("saisies_r37_landscape_road_cache_updated", false))
		},
		"fit": {"source": _fit_source, "sample_count": _fit_samples.size(), "endpoint_residual_m": _fit_endpoint_residual_m, "height_closure_peak_pct": _fit_height_closure_peak_pct},
		"geometry": {"mesh_node_count": _mesh_node_count, "multimesh_node_count": _multimesh_node_count, "collision_node_count": _collision_node_count, "warped_vertex_count": _warped_vertex_count, "warped_instance_count": _warped_instance_count},
		"r36_environment_baseline": _r36_environment_state,
		"interactive": {
			"auto_tour_requested": auto_tour,
			"tour_active": _tour_active,
			"tour_loop": tour_loop,
			"tour_playback_rate": tour_playback_rate,
			"tour_paused": _tour_paused,
			"source_time_s": _tour_time_s,
			"source_time_range_s": [_source_time_start_s, _source_time_end_s],
			"source_sequence": _source_sequence,
			"space_toggles_pause": true
		},
		"cross_section_override_count": _cross_section_overrides.size(),
		"cross_section_override_source": _cross_section_override_source,
		"cross_section_overrides": _cross_section_overrides,
		"terrain_profile": _terrain_profile_summary(),
		"dressing": _dressing_summary(),
		"notes": ["R37 diagnostic candidate only", "route samples and visible geometry use the same source-frame to fit-frame mapping", "terrain and props outside the local station/lateral corridor remain unchanged"]
	}

func _capture_frame() -> void:
	for _frame in 12:
		await get_tree().process_frame
	RenderingServer.force_draw()
	var image := get_viewport().get_texture().get_image()
	var output := _resolved_capture_dir().path_join("%s_representative.png" % candidate_id.to_lower())
	var absolute := ProjectSettings.globalize_path(output) if output.begins_with("res://") or output.begins_with("user://") else output
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	image.save_png(absolute)

func _resolved_capture_dir() -> String:
	return _override_capture_dir if not _override_capture_dir.is_empty() else capture_dir

func _resolved_report_path() -> String:
	return _override_report_path if not _override_report_path.is_empty() else report_path

func _write_json(path: String, payload: Dictionary) -> bool:
	var absolute := ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_error_message = "R37 representative could not write report: %s" % path
		return false
	file.store_string(JSON.stringify(payload, "  "))
	file.close()
	return true

func _fail(message: String) -> void:
	_error_message = message
	set_meta("saisies_r37_representative_ready", false)
	set_meta("saisies_r37_representative_error", message)
	push_error(message)
	if auto_quit:
		get_tree().quit(1)
