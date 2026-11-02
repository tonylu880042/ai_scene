extends SceneTree

## Offline R11 S12 route and source-sequence diagnostic.
##
## This tool intentionally stays route-only.  It loads the geographic route,
## records the current 570 s station, grade and road-frame basis, and selects
## true-right curvature candidates using the actual future-tangent/current-left
## dot product.  It also extracts a short, full-resolution source sequence
## around S12 so the right bank/rock and bend progression are inspectable.
## No route, scene map, camera pose, terrain or scenery data is changed.

const DEFAULT_ROUTE_SCRIPT := "res://scripts/saisies_geo_route.gd"
const DEFAULT_ROUTE_FILE := "res://data/saisies_geo_route.json"
const DEFAULT_VIDEO := "res://video/Descending Col des Saisies _ French Alps #3_1080p.mp4"
const DEFAULT_OUTPUT_DIR := "res://export/saisies/review/round11_analysis"
const ACCEPTANCE_FRAMES_FILE := "res://data/saisies_acceptance_frames.json"
const S12_TIME_S := 570.0
const S12_WINDOW_HALF_M := 300.0
const ROUTE_SAMPLE_STEP_M := 5.0
const TURN_LOOKAHEAD_M := 60.0
const TURN_SIGN_THRESHOLD := 0.012
const SOURCE_VIDEO_FPS := 24000.0 / 1001.0
const SOURCE_PTS_PER_FRAME := 1001
const DEFAULT_SOURCE_FROM_TIME := 564.0
const DEFAULT_SOURCE_TO_TIME := 576.0
const DEFAULT_SOURCE_STEP_S := 1.0
const S08_FROZEN_STATION_M := 5143.260108
const S09_FROZEN_STATION_M := 5431.282674
const S12_SOURCE_HUD_ALTITUDE_M := 1042.0
const S12_SOURCE_HUD_GRADE_PCT := -3.0

var _route: SaisiesRoute
var _route_script_path := DEFAULT_ROUTE_SCRIPT
var _route_file := DEFAULT_ROUTE_FILE
var _video_path := DEFAULT_VIDEO
var _output_dir := DEFAULT_OUTPUT_DIR
var _source_from_time := DEFAULT_SOURCE_FROM_TIME
var _source_to_time := DEFAULT_SOURCE_TO_TIME
var _source_step_s := DEFAULT_SOURCE_STEP_S
var _analysis_step_m := ROUTE_SAMPLE_STEP_M
var _turn_lookahead_m := TURN_LOOKAHEAD_M
var _errors: Array[String] = []
var _datum_m := 0.0
var _source_manifest: Array = []
var _source_reference: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_parse_args()
	if not await _load_route():
		_finish()
		return
	if not _extract_source_sequence():
		_finish()
		return

	var checkpoint_s := clampf(_route.distance_for_video_seconds(S12_TIME_S), 0.0, _route.length_m)
	var acceptance_s := clampf(_route.acceptance_distance("S12"), 0.0, _route.length_m)
	var current_s := checkpoint_s
	var window := _build_route_window(current_s, S12_WINDOW_HALF_M)
	var right_candidates := _select_true_right_candidates(window, current_s)
	var height_diagnostics := _build_height_diagnostics(current_s, right_candidates)
	var frozen_contracts := _frozen_station_contracts()
	var output := {
		"schema_version": 1,
		"id": "saisies_round11_s12_route_diagnostic",
		"status": "diagnostic_only",
		"scope": "route-only-no-forest",
		"estimated": true,
		"note": "S12 570 s right-bend route/source evidence for native probing. Station and candidates are estimated visual/route inference, not GPS, telemetry, camera calibration, or production approval.",
		"inference_policy": {
			"source_pixels_have_no_route_s": true,
			"source_sequence_is_continuity_evidence_not_pixel_to_station_registration": true,
			"native_probe_required_before_runtime_change": true,
			"route_frame_is_shared_SaisiesGeoRoute_helper": true,
			"true_right_requires_future_tangent_dot_current_left_negative": true,
			"no_forest_or_scenery_loaded": true
		},
		"route": {
			"script": _route_script_path,
			"file": _route_file,
			"length_m": _route.length_m,
			"datum_m": _datum_m,
			"geography_frame": _route.frame(),
			"sample_step_m": _analysis_step_m,
			"turn_lookahead_m": _turn_lookahead_m,
			"height_sources": {
				"datum_source": "SaisiesGeoRoute.frame()['datum_m'] from SaisiesGeography.configure()",
				"raw_asl_method": "SaisiesGeography.raw_height_asl_world(Vector2(x,z))",
				"raw_coarse_asl_method": "SaisiesGeography.raw_height_asl_world_coarse(Vector2(x,z))",
				"route_ground_helper_method": "SaisiesGeoRoute.ground_y(s,u)",
				"route_ground_helper_asl_conversion": "route_ground_helper_local_y + frame datum_m",
				"rendered_mesh_readback": false,
				"note": "The route ground helper is the runtime geographic helper path; this diagnostic does not instantiate the full GeoLandscape mesh or claim a GPU mesh readback."
			},
			"api_methods": ["pos_at", "tangent_at", "left_at", "road_width_at", "ground_y", "grade_at", "distance_for_video_seconds", "acceptance_distance"]
		},
		"source_sequence": {
			"video": _video_path,
			"requested_from_time_s": _source_from_time,
			"requested_to_time_s": _source_to_time,
			"requested_step_s": _source_step_s,
			"source_video_fps_nominal": SOURCE_VIDEO_FPS,
			"time_base": "1/24000",
			"reference": _source_reference,
			"manifest": _output_dir.path_join("source_sequence/source_frames_manifest.json"),
			"showinfo_log": _output_dir.path_join("source_sequence/source_frames_showinfo.log"),
			"contact_sheet": _output_dir.path_join("source_sequence/source_sequence_contact.jpg"),
			"frame_count": _source_manifest.size(),
			"continuity_observations": _source_observations()
		},
		"s12": {
			"scene_id": "S12",
			"reference_time_s": S12_TIME_S,
			"current_station_m": current_s,
			"acceptance_station_m": acceptance_s,
			"video_checkpoint_station_m": checkpoint_s,
			"station_difference_m": acceptance_s - checkpoint_s,
			"current_sample": _route_sample(current_s),
			"window_half_m": S12_WINDOW_HALF_M,
			"route_window": window,
			"window_summary": _summarise_window(window, current_s),
			"direction_sign_proof": _direction_sign_proof(current_s),
			"true_right_candidates": right_candidates,
			"height_profile_diagnostics": height_diagnostics,
			"source_hud_crosscheck": {
				"reference_image": "res://video/saisies_analysis/acceptance/S12_f013666.png",
				"displayed_altitude_m": S12_SOURCE_HUD_ALTITUDE_M,
				"displayed_grade_pct": S12_SOURCE_HUD_GRADE_PCT,
				"runtime_current_road_asl_minus_displayed_m": float(height_diagnostics[0].get("runtime_road_asl_m", NAN)) - S12_SOURCE_HUD_ALTITUDE_M if not height_diagnostics.is_empty() else null,
				"runtime_current_grade_minus_displayed_pct": float(height_diagnostics[0].get("grade_range_next_60m", {}).get("at_start_pct", NAN)) - S12_SOURCE_HUD_GRADE_PCT if not height_diagnostics.is_empty() else null,
				"status": "visual cross-check only; not used to fit station, route profile, or camera pose"
			},
			"candidate_status": "route-only candidates; all require root native probe and visual comparison"
		},
		"frozen_station_contracts": frozen_contracts,
		"prior_context": {
			"S13_current_candidate_station_m": 10120.0,
			"S13_current_candidate_status": "candidate only; not approved, not GPS or calibration",
			"S13_rejected_station_m": 10244.187,
			"S13_rejected_reason": "prior direction diagnostic inverted left/right labels; do not reuse"
		},
		"generated_by": "tools/analyze_saisies_round11_route.gd"
	}
	_write_json(_output_dir.path_join("round11_s12_route_analysis.json"), output)
	_write_markdown(_output_dir.path_join("round11_s12_route_analysis.md"), output)
	_print_summary(output)
	_finish()

func _parse_args() -> void:
	for arg in _user_args():
		if arg.begins_with("--route-script="):
			_route_script_path = arg.substr("--route-script=".length())
		elif arg.begins_with("--route-file="):
			_route_file = arg.substr("--route-file=".length())
		elif arg.begins_with("--video="):
			_video_path = arg.substr("--video=".length())
		elif arg.begins_with("--output-dir="):
			_output_dir = arg.substr("--output-dir=".length())
		elif arg.begins_with("--from-time="):
			_source_from_time = float(arg.substr("--from-time=".length()))
		elif arg.begins_with("--to-time="):
			_source_to_time = float(arg.substr("--to-time=".length()))
		elif arg.begins_with("--source-step="):
			_source_step_s = maxf(float(arg.substr("--source-step=".length())), 0.25)
		elif arg.begins_with("--step-m="):
			_analysis_step_m = maxf(float(arg.substr("--step-m=".length())), 1.0)
		elif arg.begins_with("--lookahead-m="):
			_turn_lookahead_m = maxf(float(arg.substr("--lookahead-m=".length())), 5.0)
	if _source_to_time < _source_from_time:
		var swap := _source_from_time
		_source_from_time = _source_to_time
		_source_to_time = swap

func _user_args() -> Array:
	var result: Array = []
	for arg in OS.get_cmdline_user_args():
		result.append(String(arg))
	var after_separator := false
	for arg in OS.get_cmdline_args():
		var value := String(arg)
		if value == "--":
			after_separator = true
			continue
		if after_separator and not result.has(value):
			result.append(value)
	return result

func _load_route() -> bool:
	var route_script = load(_route_script_path)
	if route_script == null:
		_fail("route script could not load: %s" % _route_script_path)
		return false
	var route_instance = route_script.new()
	_route = route_instance as SaisiesRoute
	if _route == null:
		_fail("route script is not a SaisiesRoute: %s" % _route_script_path)
		return false
	_route.name = "SaisiesRound11S12RouteDiagnostic"
	_route.route_file = _route_file
	for property in _route.get_property_list():
		if String(property.get("name", "")) == "geo_route_file":
			_route.set("geo_route_file", _route_file)
			break
	get_root().add_child(_route)
	for _frame in range(240):
		if _route.route_ready():
			break
		await process_frame
	if not _route.route_ready():
		_fail("geographic route did not become ready")
		return false
	var frame: Dictionary = _route.frame()
	_datum_m = float(frame.get("datum_m", 0.0))
	print("round11 route ready length=%.3f datum=%.3f" % [_route.length_m, _datum_m])
	return true

func _extract_source_sequence() -> bool:
	var global_video := _global_path(_video_path)
	if not FileAccess.file_exists(global_video):
		_fail("source video does not exist: %s" % _video_path)
		return false
	var reference := _load_s12_reference()
	if reference.is_empty():
		_fail("S12 acceptance reference is missing from %s" % ACCEPTANCE_FRAMES_FILE)
		return false
	_source_reference = reference
	var reference_path := _global_path(String(reference.get("reference_image", "")))
	if not FileAccess.file_exists(reference_path):
		_fail("S12 reference image does not exist: %s" % reference_path)
		return false
	_source_reference["sha256"] = _sha256_file(reference_path)

	var output_dir_global := _global_path(_output_dir)
	var sequence_dir := output_dir_global.path_join("source_sequence")
	DirAccess.make_dir_recursive_absolute(sequence_dir)
	var times: Array[float] = []
	var count := maxi(int(round((_source_to_time - _source_from_time) / _source_step_s)) + 1, 1)
	for index in range(count):
		var time_s := minf(_source_from_time + float(index) * _source_step_s, _source_to_time)
		if not times.is_empty() and absf(float(times.back()) - time_s) < 0.0001:
			continue
		times.append(time_s)
	var select_terms := PackedStringArray()
	var source_indices: Array[int] = []
	for time_s in times:
		var source_index := int(round(time_s * SOURCE_VIDEO_FPS))
		source_indices.append(source_index)
		select_terms.append("eq(n\\,%d)" % source_index)
	var pattern := sequence_dir.path_join("source_s12_%02d.png")
	var filter_expr := "select='" + "+".join(select_terms) + "',showinfo"
	var extract_args := PackedStringArray([
		"-y", "-hide_banner", "-loglevel", "info",
		"-i", global_video,
		"-vf", filter_expr,
		"-fps_mode", "vfr",
		"-frames:v", str(times.size()),
		"-start_number", "1",
		"-c:v", "png",
		pattern
	])
	var command_output: Array = []
	var extract_code := OS.execute("ffmpeg", extract_args, command_output, true)
	var showinfo_text := "\n".join(command_output)
	_write_text(_output_dir.path_join("source_sequence/source_frames_showinfo.log"), showinfo_text)
	if extract_code != 0:
		_fail("ffmpeg exact source extraction failed (%d)" % extract_code)
		return false
	var showinfo := _parse_showinfo(showinfo_text)
	_source_manifest.clear()
	for index in range(times.size()):
		var path := sequence_dir.path_join("source_s12_%02d.png" % (index + 1))
		if not FileAccess.file_exists(path):
			_fail("source frame missing after extraction: %s" % path)
			continue
		var time_s := float(times[index])
		var source_index := int(source_indices[index])
		var entry: Dictionary = {
			"sequence_index": index + 1,
			"requested_time_s": time_s,
			"frame_index_zero_based": source_index,
			"expected_pts": source_index * SOURCE_PTS_PER_FRAME,
			"expected_pts_time_s": float(source_index) / SOURCE_VIDEO_FPS,
			"time_base": "1/24000",
			"decoded_width": 1920,
			"decoded_height": 1080,
			"file": _output_dir.path_join("source_sequence/source_s12_%02d.png" % (index + 1)),
			"sha256": _sha256_file(path)
		}
		if index < showinfo.size():
			var decoded: Dictionary = showinfo[index]
			entry["decoded_frame_index"] = decoded.get("n", index)
			entry["decoded_pts"] = decoded.get("pts", source_index * SOURCE_PTS_PER_FRAME)
			entry["decoded_pts_time_s"] = decoded.get("pts_time_s", entry["expected_pts_time_s"])
			entry["decoded_size"] = decoded.get("size", "1920x1080")
			entry["decoded_pts_matches_expected"] = int(decoded.get("pts", source_index * SOURCE_PTS_PER_FRAME)) == source_index * SOURCE_PTS_PER_FRAME
		else:
			entry["decoded_frame_index"] = null
			entry["decoded_pts"] = null
			entry["decoded_pts_time_s"] = null
			entry["decoded_size"] = null
			entry["decoded_pts_matches_expected"] = false
		_source_manifest.append(entry)
	if _source_manifest.size() != times.size():
		_fail("source sequence manifest count mismatch")
		return false
	var reference_index := int(reference.get("frame_index_zero_based", -1))
	for entry in _source_manifest:
		if int(entry.get("frame_index_zero_based", -2)) == reference_index:
			_source_reference["extracted_file"] = entry.get("file", "")
			_source_reference["extracted_sha256"] = entry.get("sha256", "")
			_source_reference["sha256_equal"] = String(entry.get("sha256", "")) == String(_source_reference.get("sha256", ""))
			break
	_write_json(_output_dir.path_join("source_sequence/source_frames_manifest.json"), {
		"schema_version": 1,
		"id": "saisies_round11_s12_source_frames",
		"status": "agent_reviewed_source_evidence",
		"video": _video_path,
		"source_video_fps_nominal": SOURCE_VIDEO_FPS,
		"time_base": "1/24000",
		"requested_time_is_not_decoded_pts": true,
		"reference": _source_reference,
		"frames": _source_manifest
	})
	var contact_path := sequence_dir.path_join("source_sequence_contact.jpg")
	var contact_args := PackedStringArray([
		"-y", "-hide_banner", "-loglevel", "error",
		"-framerate", "1",
		"-i", sequence_dir.path_join("source_s12_%02d.png"),
		"-vf", "scale=480:-2,tile=5x3:padding=4:margin=4",
		"-frames:v", "1", "-q:v", "2", contact_path
	])
	command_output.clear()
	var contact_code := OS.execute("ffmpeg", contact_args, command_output, true)
	if contact_code != 0 or not FileAccess.file_exists(contact_path):
		_fail("ffmpeg source contact sheet failed (%d)" % contact_code)
		return false
	print("round11 source sequence frames=%d contact=%s" % [_source_manifest.size(), _output_dir.path_join("source_sequence/source_sequence_contact.jpg")])
	return true

func _parse_showinfo(text: String) -> Array:
	var result: Array = []
	var regex := RegEx.new()
	regex.compile("n:\\s*(\\d+).*pts:\\s*(-?\\d+).*pts_time:\\s*([-+0-9.eE]+).*s:\\s*(\\d+x\\d+)")
	for line in text.split("\n"):
		var match := regex.search(line)
		if match == null:
			continue
		result.append({
			"n": int(match.get_string(1)),
			"pts": int(match.get_string(2)),
			"pts_time_s": float(match.get_string(3)),
			"size": match.get_string(4)
		})
	return result

func _load_s12_reference() -> Dictionary:
	if not FileAccess.file_exists(ACCEPTANCE_FRAMES_FILE):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(ACCEPTANCE_FRAMES_FILE))
	if not (parsed is Dictionary):
		return {}
	for item in parsed.get("scenes", []):
		if item is Dictionary and String(item.get("scene_id", "")) == "S12":
			return item.duplicate(true)
	return {}

func _build_route_window(center_s: float, half_window: float) -> Array:
	var start_s := maxf(0.0, center_s - half_window)
	var end_s := minf(_route.length_m, center_s + half_window)
	var samples: Array = []
	var count := maxi(int(floor((end_s - start_s) / _analysis_step_m)), 1)
	for index in range(count + 1):
		var s := minf(start_s + float(index) * _analysis_step_m, end_s)
		if not samples.is_empty() and absf(float(samples.back().get("s_m", 0.0)) - s) < 0.001:
			continue
		samples.append(_route_sample(s))
	if samples.is_empty() or absf(float(samples.back().get("s_m", 0.0)) - end_s) > 0.001:
		samples.append(_route_sample(end_s))
	return samples

func _route_sample(s: float) -> Dictionary:
	var clamped := clampf(s, 0.0, _route.length_m)
	var center: Vector3 = _route.pos_at(clamped)
	var tangent: Vector3 = _route.tangent_at(clamped)
	var left: Vector3 = _route.left_at(clamped)
	var half_width := _route.road_width_at(clamped) * 0.5
	var left_edge := center + left * half_width
	var right_edge := center - left * half_width
	left_edge.y = _route.ground_y(clamped, half_width)
	right_edge.y = _route.ground_y(clamped, -half_width)
	var turn := _turn_sign_proof_at(clamped)
	return {
		"s_m": clamped,
		"center": _vector_for(center),
		"left_edge": _vector_for(left_edge),
		"right_edge": _vector_for(right_edge),
		"tangent_xz": {"x": tangent.x, "z": tangent.z},
		"left_xz": {"x": left.x, "z": left.z},
		"road_width_m": _route.road_width_at(clamped),
		"heading_deg": _heading_deg(clamped),
		"grade_pct": _route.grade_at(clamped),
		"runtime_road_asl_m": center.y + _datum_m,
		"turn": turn
	}

func _turn_sign_proof_at(station: float) -> Dictionary:
	var s := clampf(station, 0.0, _route.length_m)
	var future_s := minf(_route.length_m, s + _turn_lookahead_m)
	var tangent: Vector3 = _route.tangent_at(s)
	var left: Vector3 = _route.left_at(s)
	var future_tangent: Vector3 = _route.tangent_at(future_s)
	var dot_left := future_tangent.dot(left)
	var dot_right := future_tangent.dot(-left)
	var turn_delta := _angle_delta_deg(_heading_deg(s), _heading_deg(future_s))
	var direction := "near_straight"
	if dot_left < -TURN_SIGN_THRESHOLD and turn_delta < -0.25:
		direction = "right"
	elif dot_left > TURN_SIGN_THRESHOLD and turn_delta > 0.25:
		direction = "left"
	return {
		"current_station_m": s,
		"future_station_m": future_s,
		"turn_delta_deg": turn_delta,
		"current_tangent": _vector_for(tangent),
		"current_left": _vector_for(left),
		"future_tangent": _vector_for(future_tangent),
		"future_tangent_dot_current_left": dot_left,
		"future_tangent_dot_current_right": dot_right,
		"direction": direction,
		"true_right_sign": dot_left < 0.0
	}

func _select_true_right_candidates(samples: Array, current_s: float) -> Array:
	var right_samples: Array = []
	for sample in samples:
		var turn: Dictionary = sample.get("turn", {})
		if String(turn.get("direction", "")) == "right" and float(turn.get("future_tangent_dot_current_left", 0.0)) < -TURN_SIGN_THRESHOLD:
			right_samples.append(sample)
	var ranked := right_samples.duplicate(true)
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("turn", {}).get("future_tangent_dot_current_left", 0.0)) < float(b.get("turn", {}).get("future_tangent_dot_current_left", 0.0))
	)
	var selected: Array = []
	const MIN_CANDIDATE_SEPARATION_M := 30.0
	for sample in ranked:
		var station := float(sample.get("s_m", 0.0))
		var separated := true
		for prior in selected:
			if absf(station - float(prior.get("station_m", 0.0))) < MIN_CANDIDATE_SEPARATION_M:
				separated = false
				break
		if not separated:
			continue
		selected.append(_candidate_from_sample(sample, current_s, "ranked true-right curvature; route-only candidate"))
		if selected.size() >= 4:
			break
	if selected.size() < 3 and not right_samples.is_empty():
		var stride := maxi(int(floor(float(right_samples.size()) / 3.0)), 1)
		for index in range(0, right_samples.size(), stride):
			var sample: Dictionary = right_samples[index]
			var candidate := _candidate_from_sample(sample, current_s, "continuous true-right run fallback; route-only candidate")
			var duplicate := false
			for prior in selected:
				if absf(float(candidate["station_m"]) - float(prior["station_m"])) < MIN_CANDIDATE_SEPARATION_M:
					duplicate = true
					break
			if not duplicate:
				selected.append(candidate)
			if selected.size() >= 4:
				break
	selected.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("station_m", 0.0)) < float(b.get("station_m", 0.0))
	)
	return selected

func _candidate_from_sample(sample: Dictionary, current_s: float, evidence: String) -> Dictionary:
	var turn: Dictionary = sample.get("turn", {})
	return {
		"station_m": sample.get("s_m", 0.0),
		"delta_from_s12_current_m": float(sample.get("s_m", 0.0)) - current_s,
		"source": "S12 570 s right-bend candidate",
		"evidence": evidence,
		"heading_deg": sample.get("heading_deg", 0.0),
		"grade_pct": sample.get("grade_pct", 0.0),
		"center": sample.get("center", {}),
		"left_edge": sample.get("left_edge", {}),
		"right_edge": sample.get("right_edge", {}),
		"turn_sign_proof": turn,
		"future_tangent_dot_current_left": turn.get("future_tangent_dot_current_left", 0.0),
		"future_tangent_dot_current_right": turn.get("future_tangent_dot_current_right", 0.0),
		"needs_native_probe": true,
		"source_station_pairing": "unknown; source pixels were not assigned route s"
	}

func _build_height_diagnostics(current_s: float, candidates: Array) -> Array:
	var stations: Array = [{"station_m": current_s, "role": "current_s12_570s"}]
	for candidate in candidates:
		stations.append({
			"station_m": float(candidate.get("station_m", current_s)),
			"role": "true_right_candidate",
			"candidate_delta_m": float(candidate.get("delta_from_s12_current_m", 0.0))
		})
	var result: Array = []
	for station_item in stations:
		var station := clampf(float(station_item.get("station_m", current_s)), 0.0, _route.length_m)
		var section := _height_cross_section(station)
		section["role"] = station_item.get("role", "")
		section["candidate_delta_m"] = station_item.get("candidate_delta_m", 0.0)
		section["grade_range_next_60m"] = _grade_range_next(station, 60.0)
		result.append(section)
	return result

func _height_cross_section(station: float) -> Dictionary:
	var s := clampf(station, 0.0, _route.length_m)
	var center: Vector3 = _route.pos_at(s)
	var left: Vector3 = _route.left_at(s)
	var datum := float(_route.frame().get("datum_m", _datum_m))
	var geography = _route.get("geography")
	var center_xz := Vector2(center.x, center.z)
	var runtime_asl := center.y + datum
	var raw_center_asl = _geo_height_asl(geography, "raw_height_asl_world", center_xz)
	var raw_coarse_center_asl = _geo_height_asl(geography, "raw_height_asl_world_coarse", center_xz)
	var offsets := [-30.0, -15.0, 15.0, 30.0]
	var lateral: Array = []
	for offset in offsets:
		var xz := center_xz + Vector2(left.x, left.z) * float(offset)
		var raw_asl = _geo_height_asl(geography, "raw_height_asl_world", xz)
		var raw_coarse_asl = _geo_height_asl(geography, "raw_height_asl_world_coarse", xz)
		var helper_local := _route.ground_y(s, float(offset))
		var helper_asl := helper_local + datum
		lateral.append({
			"u_m": float(offset),
			"side": "right" if float(offset) < 0.0 else "left",
			"world_xz": {"x": xz.x, "z": xz.y},
			"raw_asl_m": raw_asl,
			"raw_coarse_asl_m": raw_coarse_asl,
			"route_ground_helper_local_y_m": helper_local,
			"route_ground_helper_asl_m": helper_asl,
			"route_ground_helper_note": "SaisiesGeoRoute.ground_y helper result; no rendered landscape mesh readback"
		})
	return {
		"station_m": s,
		"runtime_road_asl_m": runtime_asl,
		"runtime_road_local_y_m": center.y,
		"raw_center_asl_m": raw_center_asl,
		"raw_coarse_center_asl_m": raw_coarse_center_asl,
		"datum_m": datum,
		"lateral_u_samples": lateral,
		"height_source_note": "Raw values come from shared SaisiesGeography ASL methods; route_ground_helper values come from SaisiesGeoRoute.ground_y plus the runtime frame datum. Full GeoLandscape mesh/GPU was not loaded."
	}

func _geo_height_asl(geography: Variant, method: String, xz: Vector2) -> Variant:
	if geography is Object and geography.has_method(method):
		var value := float(geography.call(method, xz))
		if is_finite(value):
			return value
	return null

func _grade_range_next(station: float, distance_m: float) -> Dictionary:
	var start := clampf(station, 0.0, _route.length_m)
	var finish := minf(_route.length_m, start + maxf(distance_m, 0.0))
	var step := maxf(_analysis_step_m, 1.0)
	var count := maxi(int(ceil((finish - start) / step)), 1)
	var values: Array[float] = []
	for index in range(count + 1):
		var sample_s := minf(start + float(index) * step, finish)
		values.append(float(_route.grade_at(sample_s)))
	return {
		"method": "SaisiesGeoRoute.grade_at",
		"from_station_m": start,
		"to_station_m": finish,
		"lookahead_m": finish - start,
		"at_start_pct": values.front() if not values.is_empty() else null,
		"at_end_pct": values.back() if not values.is_empty() else null,
		"min_pct": _array_min(values),
		"max_pct": _array_max(values),
		"sample_count": values.size()
	}

func _summarise_window(samples: Array, current_s: float) -> Dictionary:
	if samples.is_empty():
		return {}
	var grades: Array[float] = []
	var headings: Array[float] = []
	var right_samples := 0
	var right_start := INF
	var right_end := -INF
	var right_runs: Array = []
	var active_start := INF
	var active_end := -INF
	for sample in samples:
		grades.append(float(sample.get("grade_pct", 0.0)))
		headings.append(float(sample.get("heading_deg", 0.0)))
		var is_right := String(sample.get("turn", {}).get("direction", "")) == "right"
		if is_right:
			right_samples += 1
			right_start = minf(right_start, float(sample.get("s_m", 0.0)))
			right_end = maxf(right_end, float(sample.get("s_m", 0.0)))
			if is_inf(active_start):
				active_start = float(sample.get("s_m", 0.0))
			active_end = float(sample.get("s_m", 0.0))
		else:
			if not is_inf(active_start):
				right_runs.append({"start_m": active_start, "end_m": active_end, "sample_count": int(round((active_end - active_start) / _analysis_step_m)) + 1})
			active_start = INF
			active_end = -INF
	if not is_inf(active_start):
		right_runs.append({"start_m": active_start, "end_m": active_end, "sample_count": int(round((active_end - active_start) / _analysis_step_m)) + 1})
	var current := _route_sample(current_s)
	var first: Dictionary = samples.front()
	var last: Dictionary = samples.back()
	return {
		"station_start_m": first.get("s_m", 0.0),
		"station_end_m": last.get("s_m", 0.0),
		"sample_count": samples.size(),
		"heading_start_deg": first.get("heading_deg", 0.0),
		"heading_end_deg": last.get("heading_deg", 0.0),
		"heading_delta_unwrapped_deg": _unwrapped_heading_delta(headings),
		"grade_min_pct": _array_min(grades),
		"grade_max_pct": _array_max(grades),
		"current_heading_deg": current.get("heading_deg", 0.0),
		"current_grade_pct": current.get("grade_pct", 0.0),
		"right_sample_count": right_samples,
		"right_run_start_m": right_start if right_samples > 0 else null,
		"right_run_end_m": right_end if right_samples > 0 else null,
		"right_runs": right_runs
	}

func _frozen_station_contracts() -> Dictionary:
	var s08 := _route.distance_for_video_seconds(315.0)
	var s09 := _route.distance_for_video_seconds(330.0)
	return {
		"S08_315s": {"expected_station_m": S08_FROZEN_STATION_M, "actual_station_m": s08, "difference_m": s08 - S08_FROZEN_STATION_M, "status": "PASS" if absf(s08 - S08_FROZEN_STATION_M) <= 0.05 else "FAIL"},
		"S09_330s": {"expected_station_m": S09_FROZEN_STATION_M, "actual_station_m": s09, "difference_m": s09 - S09_FROZEN_STATION_M, "status": "PASS" if absf(s09 - S09_FROZEN_STATION_M) <= 0.05 else "FAIL"}
	}

func _direction_sign_proof(station: float) -> Dictionary:
	var angle := deg_to_rad(15.0)
	var forward := Vector3(0.0, 0.0, -1.0)
	var left_turn := Vector3(-sin(angle), 0.0, -cos(angle))
	var right_turn := Vector3(sin(angle), 0.0, -cos(angle))
	var current_left := Vector3(-1.0, 0.0, 0.0)
	var current := _turn_sign_proof_at(station)
	return {
		"convention": "forward local -Z; current left local -X; positive future tangent dot current left is left, negative is true right",
		"synthetic_forward": _vector_for(forward),
		"synthetic_left_turn": _vector_for(left_turn),
		"synthetic_right_turn": _vector_for(right_turn),
		"synthetic_left_dot_current_left": left_turn.dot(current_left),
		"synthetic_right_dot_current_left": right_turn.dot(current_left),
		"synthetic_left_heading_delta_deg": _angle_delta_deg(_heading_deg_from_tangent(forward), _heading_deg_from_tangent(left_turn)),
		"synthetic_right_heading_delta_deg": _angle_delta_deg(_heading_deg_from_tangent(forward), _heading_deg_from_tangent(right_turn)),
		"actual_current_station_m": station,
		"actual_current_turn": current
	}

func _source_observations() -> Array:
	return [
		{"requested_time_range_s": "564-567", "observation": "The source remains a forest road with the short close bank/rock face on camera-right; the road exit is still constrained by the bend and canopy.", "confidence": "agent visual review of extracted full-resolution sequence; no route station assigned"},
		{"requested_time_range_s": "568-572", "observation": "The white centerline and road edges continue through a rightward bend while the right bank stays close; this is a continuous bend sequence around the S12 reference, not a single-frame landmark.", "confidence": "agent visual review; cyclist/HUD and motion blur limit geometric measurement"},
		{"requested_time_range_s": "573-576", "observation": "The right bank/rock begins to recede as the road opens beyond the bend; the sequence is retained to bound the feature transition rather than claim an exact route station.", "confidence": "agent visual review; transition boundaries are estimated"}
	]

func _heading_deg(station: float) -> float:
	return _heading_deg_from_tangent(_route.tangent_at(clampf(station, 0.0, _route.length_m)))

func _heading_deg_from_tangent(tangent: Vector3) -> float:
	return rad_to_deg(atan2(-tangent.x, -tangent.z))

func _angle_delta_deg(from_heading: float, to_heading: float) -> float:
	return rad_to_deg(wrapf(deg_to_rad(to_heading - from_heading) + PI, 0.0, TAU) - PI)

func _unwrapped_heading_delta(headings: Array[float]) -> float:
	if headings.size() < 2:
		return 0.0
	var total := 0.0
	for index in range(1, headings.size()):
		total += _angle_delta_deg(headings[index - 1], headings[index])
	return total

func _array_min(values: Array[float]) -> float:
	if values.is_empty():
		return NAN
	var result := INF
	for value in values:
		result = minf(result, value)
	return result

func _array_max(values: Array[float]) -> float:
	if values.is_empty():
		return NAN
	var result := -INF
	for value in values:
		result = maxf(result, value)
	return result

func _format_optional_number(value: Variant) -> String:
	if value == null:
		return "n/a"
	var number := float(value)
	return "n/a" if not is_finite(number) else "%.3f" % number

func _vector_for(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}

func _write_json(path: String, value: Variant) -> void:
	var global_path := _global_path(path)
	DirAccess.make_dir_recursive_absolute(global_path.get_base_dir())
	var file := FileAccess.open(global_path, FileAccess.WRITE)
	if file == null:
		_fail("could not write JSON: %s" % path)
		return
	file.store_string(JSON.stringify(value, "\t"))
	file.close()

func _write_text(path: String, value: String) -> void:
	var global_path := _global_path(path)
	DirAccess.make_dir_recursive_absolute(global_path.get_base_dir())
	var file := FileAccess.open(global_path, FileAccess.WRITE)
	if file == null:
		_fail("could not write text: %s" % path)
		return
	file.store_string(value)
	file.close()

func _write_markdown(path: String, output: Dictionary) -> void:
	var s12: Dictionary = output["s12"]
	var summary: Dictionary = s12["window_summary"]
	var lines := PackedStringArray()
	lines.append("# Saisies R11 S12 route diagnostic")
	lines.append("")
	lines.append("Status: READY/HOLD for root native probing. This is route/source evidence only; station values are estimated and are not GPS, telemetry, camera calibration, or production approval.")
	lines.append("")
	lines.append("## Source sequence")
	lines.append("")
	lines.append("Full-resolution exact-frame sequence: %.3f–%.3f s at %.3f s steps. See `source_sequence/source_frames_manifest.json` for requested time, frame index, decoded PTS, time base, dimensions, and SHA256; see `source_frames_showinfo.log` for ffmpeg showinfo evidence." % [_source_from_time, _source_to_time, _source_step_s])
	lines.append("")
	lines.append("The source observation is a continuous S12 right bend: a short close right-side bank/rock remains through the 568–572 s neighborhood while the centerline/road exit turns right, then the bank recedes as the bend opens around 573–576 s. Source pixels are not assigned route stations.")
	lines.append("")
	lines.append("## Route station")
	lines.append("")
	lines.append("Current S12 570 s station: %.3f m; acceptance fallback: %.3f m; heading %.3f deg; grade %.3f%%." % [float(s12["current_station_m"]), float(s12["acceptance_station_m"]), float(s12["current_sample"]["heading_deg"]), float(s12["current_sample"]["grade_pct"])])
	lines.append("Window %.3f–%.3f m, %d samples at %.3f m. Heading delta %.3f deg; grade range %.3f..%.3f%%; true-right samples %d." % [float(summary["station_start_m"]), float(summary["station_end_m"]), int(summary["sample_count"]), _analysis_step_m, float(summary["heading_delta_unwrapped_deg"]), float(summary["grade_min_pct"]), float(summary["grade_max_pct"]), int(summary["right_sample_count"])])
	lines.append("")
	lines.append("## Height corridor cross-check")
	lines.append("")
	lines.append("Values use the shared vertical datum %.6f m. `raw`/`raw_coarse` are SaisiesGeography ASL samples; `route_ground_helper` is SaisiesGeoRoute.ground_y(s,u) plus that datum. No full GeoLandscape mesh or GPU readback was used, so helper values are not rendered-mesh measurements." % float(output["route"]["geography_frame"].get("datum_m", _datum_m)))
	lines.append("Source HUD cross-check only: altitude %.0f m, grade %.0f%%; it was not used to fit station or camera." % [float(s12["source_hud_crosscheck"]["displayed_altitude_m"]), float(s12["source_hud_crosscheck"]["displayed_grade_pct"])])
	lines.append("")
	lines.append("| role | station m | runtime road ASL | raw center ASL | raw coarse center ASL | next 60 m grade min..max |")
	lines.append("|---|---:|---:|---:|---:|---:|")
	for profile in s12["height_profile_diagnostics"]:
		var grade: Dictionary = profile["grade_range_next_60m"]
		lines.append("| %s | %.3f | %.3f | %s | %s | %.3f..%.3f%% |" % [String(profile.get("role", "")), float(profile["station_m"]), float(profile["runtime_road_asl_m"]), _format_optional_number(profile.get("raw_center_asl_m", null)), _format_optional_number(profile.get("raw_coarse_center_asl_m", null)), float(grade.get("min_pct", NAN)), float(grade.get("max_pct", NAN))])
	lines.append("")
	lines.append("Lateral samples (u<0 is route-right; u>0 is route-left):")
	lines.append("")
	lines.append("| role | station m | u m | side | raw ASL | raw coarse ASL | route ground helper ASL |")
	lines.append("|---|---:|---:|---|---:|---:|---:|")
	for profile in s12["height_profile_diagnostics"]:
		for sample in profile["lateral_u_samples"]:
			lines.append("| %s | %.3f | %.1f | %s | %s | %s | %.3f |" % [String(profile.get("role", "")), float(profile["station_m"]), float(sample["u_m"]), String(sample["side"]), _format_optional_number(sample.get("raw_asl_m", null)), _format_optional_number(sample.get("raw_coarse_asl_m", null)), float(sample["route_ground_helper_asl_m"])])
	lines.append("")
	lines.append("## Direction sign proof")
	lines.append("")
	var proof: Dictionary = s12["direction_sign_proof"]
	lines.append("Synthetic forward -Z → left tangent has dot %.6f and heading delta %.3f deg; forward -Z → right tangent has dot %.6f and heading delta %.3f deg. Therefore negative future tangent dot current left is true-right." % [float(proof["synthetic_left_dot_current_left"]), float(proof["synthetic_left_heading_delta_deg"]), float(proof["synthetic_right_dot_current_left"]), float(proof["synthetic_right_heading_delta_deg"])])
	var actual_turn: Dictionary = proof["actual_current_turn"]
	lines.append("At S12 current station, future tangent is %.3f m ahead; dot current left %.6f, dot current right %.6f, heading delta %.3f deg, classified %s." % [float(actual_turn["future_station_m"]), float(actual_turn["future_tangent_dot_current_left"]), float(actual_turn["future_tangent_dot_current_right"]), float(actual_turn["turn_delta_deg"]), String(actual_turn["direction"])])
	lines.append("")
	lines.append("## True-right route candidates")
	lines.append("")
	lines.append("| station m | delta from S12 | heading deg | grade % | future tangent dot current left | turn | status |")
	lines.append("|---:|---:|---:|---:|---:|---|---|")
	for candidate in s12["true_right_candidates"]:
		lines.append("| %.3f | %.3f | %.3f | %.3f | %.6f | %s | native probe required |" % [float(candidate["station_m"]), float(candidate["delta_from_s12_current_m"]), float(candidate["heading_deg"]), float(candidate["grade_pct"]), float(candidate["future_tangent_dot_current_left"]), String(candidate["turn_sign_proof"]["direction"])])
	lines.append("")
	lines.append("Candidates are route geometry options only. No source pixel was paired to a candidate station; root should native-probe the 3–4 candidates and compare the right bank/rock, white-line bend, and road exit.")
	lines.append("")
	lines.append("## Frozen downstream station contracts")
	lines.append("")
	for key in ["S08_315s", "S09_330s"]:
		var item: Dictionary = output["frozen_station_contracts"][key]
		lines.append("%s: expected %.6f m, actual %.6f m, delta %.6f m — %s." % [key, float(item["expected_station_m"]), float(item["actual_station_m"]), float(item["difference_m"]), String(item["status"])])
	lines.append("")
	lines.append("S13 remains candidate-only at 10120 m / pitch -24 from prior native probes; 10244.187 m is rejected after the corrected turn-sign diagnostic. Neither value is approved or calibrated by this R11 tool.")
	lines.append("")
	lines.append("Generated by `tools/analyze_saisies_round11_route.gd`; no production route/map/pose/scene files were modified.")
	_write_text(path, "\n".join(lines) + "\n")

func _print_summary(output: Dictionary) -> void:
	var s12: Dictionary = output["s12"]
	var current: Dictionary = s12["current_sample"]
	print("round11 S12 station=%.3f heading=%.3f grade=%.3f" % [float(s12["current_station_m"]), float(current["heading_deg"]), float(current["grade_pct"])])
	var turn: Dictionary = s12["direction_sign_proof"]["actual_current_turn"]
	print("round11 S12 future station=%.3f dot_left=%.6f dot_right=%.6f turn=%s" % [float(turn["future_station_m"]), float(turn["future_tangent_dot_current_left"]), float(turn["future_tangent_dot_current_right"]), String(turn["direction"])])
	for candidate in s12["true_right_candidates"]:
		print("round11 true-right candidate s=%.3f delta=%.3f dot_left=%.6f heading=%.3f grade=%.3f" % [float(candidate["station_m"]), float(candidate["delta_from_s12_current_m"]), float(candidate["future_tangent_dot_current_left"]), float(candidate["heading_deg"]), float(candidate["grade_pct"])])
	for key in ["S08_315s", "S09_330s"]:
		var item: Dictionary = output["frozen_station_contracts"][key]
		print("round11 frozen %s actual=%.6f expected=%.6f status=%s" % [key, float(item["actual_station_m"]), float(item["expected_station_m"]), String(item["status"])])
	print("round11 outputs json=%s markdown=%s contact=%s" % [_output_dir.path_join("round11_s12_route_analysis.json"), _output_dir.path_join("round11_s12_route_analysis.md"), _output_dir.path_join("source_sequence/source_sequence_contact.jpg")])

func _sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_buffer(file.get_length()))
	return context.finish().hex_encode()

func _global_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path if path.is_absolute_path() else ProjectSettings.globalize_path(path)

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES R11 ROUTE: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES R11 ROUTE READY/HOLD")
		quit(0)
	else:
		for error in _errors:
			print("SAISIES R11 ROUTE ERROR: " + error)
		quit(1)
