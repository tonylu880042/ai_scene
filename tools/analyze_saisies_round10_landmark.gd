extends SceneTree

## Offline R10 source-sequence and geographic road-turn diagnostic.
##
## This tool deliberately stops at evidence gathering.  It loads the real
## SaisiesGeoRoute and uses its public route/geography helpers to describe the
## S13 +/-250 m road window, then extracts adjacent source-video frames around
## the S13 reference time.  It does not change camera poses, route data,
## scene maps, or acceptance references.  Candidate view offsets are labelled
## as source-view inference: they are not camera calibration or GPS.

const DEFAULT_ROUTE_SCRIPT := "res://scripts/saisies_geo_route.gd"
const DEFAULT_ROUTE_FILE := "res://data/saisies_geo_route.json"
const DEFAULT_VIDEO := "res://video/Descending Col des Saisies _ French Alps #3_1080p.mp4"
const DEFAULT_OUTPUT_DIR := "res://export/saisies/review/round10_analysis"
const DEFAULT_FROM_TIME := 620.0
const DEFAULT_TO_TIME := 645.0
const DEFAULT_SOURCE_FPS := 1.0
const DEFAULT_ANALYSIS_STEP_M := 5.0
const S13_TIME_S := 630.0
const S13_WINDOW_HALF_M := 250.0
const S08_ACCEPTANCE_S := 5143.26
const S08_ALTERNATE_S := 5408.0
const SOURCE_VIDEO_FPS := 24000.0 / 1001.0

var _route: SaisiesRoute
var _route_script_path := DEFAULT_ROUTE_SCRIPT
var _route_file := DEFAULT_ROUTE_FILE
var _video_path := DEFAULT_VIDEO
var _output_dir := DEFAULT_OUTPUT_DIR
var _from_time := DEFAULT_FROM_TIME
var _to_time := DEFAULT_TO_TIME
var _source_fps := DEFAULT_SOURCE_FPS
var _analysis_step_m := DEFAULT_ANALYSIS_STEP_M
var _errors: Array[String] = []
var _frame_manifest: Array = []
var _datum_m := 0.0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_parse_args()
	var route_loaded: bool = await _load_route()
	if not route_loaded:
		_finish()
		return
	if not _extract_source_sequence():
		_finish()
		return

	var s13_acceptance := clampf(_route.acceptance_distance("S13"), 0.0, _route.length_m)
	var s13_checkpoint := clampf(_route.distance_for_video_seconds(S13_TIME_S), 0.0, _route.length_m)
	var s13_window := _build_route_window(s13_acceptance, S13_WINDOW_HALF_M)
	var s13_summary := _summarise_window(s13_window, s13_acceptance)
	var s13_candidates := _build_candidates(s13_window, s13_acceptance, s13_checkpoint)
	var current_s13_curvature := float(s13_candidates.front().get("curvature_deg_per_100m", 0.0)) if not s13_candidates.is_empty() else 0.0
	var current_s13_direction := String(s13_candidates.front().get("turn_direction_route_convention", "near_straight")) if not s13_candidates.is_empty() else "near_straight"
	var true_left_candidates: Array = []
	for candidate in s13_candidates:
		if String(candidate.get("turn_direction_route_convention", "")) == "left":
			true_left_candidates.append({
				"station_m": candidate["station_m"],
				"source": candidate["source"],
				"curvature_deg_per_100m": candidate.get("curvature_deg_per_100m", 0.0),
				"delta_from_s13_acceptance_m": candidate.get("delta_from_s13_acceptance_m", 0.0),
				"source_backed": candidate.get("source_backed", false)
			})
	var s08_comparison := _build_s08_comparison()
	var pose := _route.acceptance_pose("S13")
	var output := {
		"schema_version": 1,
		"id": "saisies_round10_landmark_diagnostic",
		"status": "diagnostic_only",
		"note": "Estimated source-view landmark analysis using authored geographic route geometry; not camera calibration, GPS, or a claim that source lens distortion is pinhole.",
		"inference_policy": {
			"source_points_have_no_route_s": true,
			"road_centerline_pixels_are_visual_evidence_only": true,
			"native_probe_required_before_any_runtime_change": true,
			"camera_pose_offsets_are_artistic_view_inference": true,
			"route_frame_is_shared_SaisiesGeoRoute_helper": true,
			"heading_turn_sign_verified_with_synthetic_and_route_basis_dot": true
		},
		"route": {
			"script": _route_script_path,
			"file": _route_file,
			"length_m": _route.length_m,
			"geography_frame": _route.frame(),
			"datum_m": _datum_m,
			"api_methods": ["pos_at", "tangent_at", "left_at", "road_width_at", "ground_y", "grade_at", "raw_height_world", "height_world"]
		},
		"source_sequence": {
			"video": _video_path,
			"from_time_s": _from_time,
			"to_time_s": _to_time,
			"fps": _source_fps,
			"source_video_fps_nominal": SOURCE_VIDEO_FPS,
			"manifest": _output_dir.path_join("source_sequence/source_sequence_manifest.json"),
			"contact_sheet": _output_dir.path_join("source_sequence/source_sequence_contact.jpg"),
			"frame_count": _frame_manifest.size(),
			"reading_note": "Use the manifest time labels when comparing the 620-645 s sequence; contact-sheet tiles are ordered source_001 onward."
		},
		"s13": {
			"reference_scene_id": "S13",
			"reference_time_s": S13_TIME_S,
			"acceptance_station_m": s13_acceptance,
			"video_checkpoint_station_m": s13_checkpoint,
			"acceptance_pose": pose,
			"window_half_m": S13_WINDOW_HALF_M,
			"window_summary": s13_summary,
			"route_samples": s13_window,
			"candidate_stations": s13_candidates,
			"direction_sign_proof": _direction_sign_proof(s13_acceptance),
			"source_observation": {
				"reference_image": "res://video/saisies_analysis/acceptance/S13_f015105.png",
				"reference_image_size_px": [1920, 1080],
				"description": "Source sequence shows a left-bending road with a readable white centerline, left rock/edge corner, and near/far road endpoints; those pixels are not assigned route distances here.",
				"centerline_pixels_approx": [{"x": 205, "y": 744}, {"x": 456, "y": 532}, {"x": 550, "y": 449}, {"x": 660, "y": 394}, {"x": 744, "y": 364}],
				"centerline_observation": "Approximate source pixels move from lower-left toward the distant bend; cyclist masking, rolling shutter/lens motion, and no known route s make them qualitative evidence only.",
				"left_rock_wall_contact_pixels_approx": [{"x": 0, "y": 478}, {"x": 140, "y": 444}, {"x": 270, "y": 420}, {"x": 400, "y": 403}, {"x": 525, "y": 395}, {"x": 605, "y": 393}],
				"left_rock_corner_endpoints_approx": [{"label": "near lower-left wall/road contact", "x": 0, "y": 478}, {"label": "far rock/road bend exit", "x": 605, "y": 393}],
				"left_rock_corner_observation": "The left rock wall/road contact and far bend endpoint are hand-read approximate pixels, retained to guide native probes; the route JSON contains an estimated left rock landmark near 10171 m.",
				"confidence": "qualitative / requires native probe"
			},
			"diagnosis": {
				"finding": "At the current S13 station the authored route curvature is %.3f deg/100 m and is labelled %s after the verified sign correction; the +/-250 m route window contains strong alternating curvature and a net heading change. A source frame with a visible left bend can therefore be at a different local route segment than the fixed station." % [current_s13_curvature, current_s13_direction],
				"plausible_causes": ["camera lateral/yaw placement relative to the right lane", "estimated video-time station offset within the route window", "remaining route/terrain landmark mismatch"],
				"next_probe_order": ["native station probes at the corrected true-left candidates", "lateral -2.4..-1.2 m while keeping route station", "small yaw/pitch probes around existing S13 pose"],
				"true_left_route_candidates": true_left_candidates,
				"turn_sign_correction": "Earlier output inverted left/right labels; positive heading delta, positive tangent cross.y, and positive future-tangent dot current-left are left.",
				"confidence": "route geometry plus qualitative source comparison; no calibrated correspondence"
			}
		},
		"s08": s08_comparison,
		"view_probe_range_inference": {
			"reason": "Source centerline and native probes indicate the rider is in the right lane while the current S13 camera is centered; probe lateral/yaw/pitch together before changing route geometry.",
			"absolute_pose_ranges": {
				"lateral_m": {"min": -2.4, "max": -1.4, "convention": "route.left_at is positive; negative is right of centerline"},
				"yaw_deg": {"min": -10.0, "max": -4.0, "reference": "existing S13 acceptance yaw 0 deg"},
				"pitch_deg": {"min": -28.0, "max": -20.0, "reference": "existing S13 acceptance pitch -20 deg"}
			},
			"native_probe_evidence": [
				"lateral -1.4 m improves near white-line placement",
				"yaw -4 deg moves the forward white line left toward the source",
				"pitch -16 deg puts the road exit near y=420 while source exit is about y=350; test more negative pitch -20..-28 deg"
			],
			"status": "inference range for native render probing only; no values were applied"
		},
		"generated_by": "tools/analyze_saisies_round10_landmark.gd"
	}
	_write_json(_output_dir.path_join("round10_s13_landmark_analysis.json"), output)
	_write_markdown(_output_dir.path_join("round10_s13_landmark_analysis.md"), output)
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
			_from_time = float(arg.substr("--from-time=".length()))
		elif arg.begins_with("--to-time="):
			_to_time = float(arg.substr("--to-time=".length()))
		elif arg.begins_with("--fps="):
			_source_fps = maxf(float(arg.substr("--fps=".length())), 0.25)
		elif arg.begins_with("--step-m="):
			_analysis_step_m = maxf(float(arg.substr("--step-m=".length())), 1.0)
	if _to_time < _from_time:
		var swap := _from_time
		_from_time = _to_time
		_to_time = swap

func _user_args() -> Array:
	var result: Array = []
	for arg in OS.get_cmdline_user_args():
		result.append(String(arg))
	# Older Godot builds expose arguments after `--` only through get_cmdline_args.
	# De-duplicate them so a caller can use either interface.
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
	_route.name = "SaisiesRound10LandmarkDiagnosticRoute"
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
	print("round10 route ready length=%.3f samples=%d datum=%.3f" % [_route.length_m, _route.get("_samples").size() if _route.get("_samples") is Array else -1, _datum_m])
	return true

func _extract_source_sequence() -> bool:
	if not FileAccess.file_exists(_video_path):
		var global_video := _global_path(_video_path)
		if not FileAccess.file_exists(global_video):
			_fail("source video does not exist: %s" % _video_path)
			return false
	var output_dir_global := _global_path(_output_dir)
	var sequence_dir := output_dir_global.path_join("source_sequence")
	DirAccess.make_dir_recursive_absolute(sequence_dir)
	var frame_count := int(round((_to_time - _from_time) * _source_fps)) + 1
	frame_count = maxi(frame_count, 1)
	var pattern := sequence_dir.path_join("source_%03d.jpg")
	var duration := float(frame_count) / _source_fps
	var extract_args := PackedStringArray([
		"-y", "-hide_banner", "-loglevel", "error",
		"-ss", "%.6f" % _from_time,
		"-i", _global_path(_video_path),
		"-t", "%.6f" % duration,
		"-vf", "fps=%.6f,scale=320:-2" % _source_fps,
		"-frames:v", str(frame_count),
		"-q:v", "2", pattern
	])
	var command_output: Array = []
	var extract_code := OS.execute("ffmpeg", extract_args, command_output, true)
	if extract_code != 0:
		_fail("ffmpeg source extraction failed (%d): %s" % [extract_code, str(command_output)])
		return false
	_frame_manifest.clear()
	for index in range(frame_count):
		var time_s := _from_time + float(index) / _source_fps
		var path := sequence_dir.path_join("source_%03d.jpg" % (index + 1))
		if not FileAccess.file_exists(path):
			_fail("source frame missing after extraction: %s" % path)
			continue
		_frame_manifest.append({
			"sequence_index": index + 1,
			"video_time_s": time_s,
			"nominal_source_frame": int(round(time_s * SOURCE_VIDEO_FPS)),
			"file": _output_dir.path_join("source_sequence/source_%03d.jpg" % (index + 1))
		})
	if _frame_manifest.size() != frame_count:
		return false
	_write_json(_output_dir.path_join("source_sequence/source_sequence_manifest.json"), {
		"note": "Frame times are extraction timestamps; nominal source frame numbers use 24000/1001 and are for reference only.",
		"from_time_s": _from_time,
		"to_time_s": _to_time,
		"fps": _source_fps,
		"frames": _frame_manifest
	})
	var contact_path := sequence_dir.path_join("source_sequence_contact.jpg")
	var contact_args := PackedStringArray([
		"-y", "-hide_banner", "-loglevel", "error",
		"-i", sequence_dir.path_join("source_%03d.jpg"),
		"-vf", "tile=5x6:padding=4:margin=4",
		"-frames:v", "1", "-q:v", "2", contact_path
	])
	command_output.clear()
	var contact_code := OS.execute("ffmpeg", contact_args, command_output, true)
	if contact_code != 0 or not FileAccess.file_exists(contact_path):
		_fail("ffmpeg contact sheet failed (%d): %s" % [contact_code, str(command_output)])
		return false
	print("round10 source sequence frames=%d contact=%s" % [_frame_manifest.size(), _output_dir.path_join("source_sequence/source_sequence_contact.jpg")])
	return true

func _build_route_window(center_s: float, half_window: float) -> Array:
	var start_s := maxf(0.0, center_s - half_window)
	var end_s := minf(_route.length_m, center_s + half_window)
	var samples: Array = []
	var count := maxi(int(floor((end_s - start_s) / _analysis_step_m)), 1)
	for index in range(count + 1):
		var s := minf(start_s + float(index) * _analysis_step_m, end_s)
		if not samples.is_empty() and absf(float(samples.back()["s_m"]) - s) < 0.001:
			continue
		samples.append(_route_sample(s))
	if samples.is_empty() or absf(float(samples.back()["s_m"]) - end_s) > 0.001:
		samples.append(_route_sample(end_s))
	var headings: Array[float] = []
	for sample in samples:
		headings.append(float(sample["heading_deg"]))
	var unwrapped := 0.0
	for index in samples.size():
		if index > 0:
			unwrapped += _angle_delta_deg(headings[index - 1], headings[index])
		samples[index]["heading_unwrapped_deg"] = unwrapped
		var previous_s := maxf(start_s, float(samples[index]["s_m"]) - _analysis_step_m)
		var next_s := minf(end_s, float(samples[index]["s_m"]) + _analysis_step_m)
		if next_s - previous_s > 0.001:
			var turn_deg := _angle_delta_deg(_heading_deg(previous_s), _heading_deg(next_s))
			var curvature := deg_to_rad(turn_deg) / (next_s - previous_s)
			samples[index]["turn_delta_deg"] = turn_deg
			samples[index]["curvature_inv_m"] = curvature
			samples[index]["curvature_deg_per_100m"] = turn_deg / (next_s - previous_s) * 100.0
			samples[index]["turn_direction_route_convention"] = _turn_direction_from_delta(turn_deg)
		else:
			samples[index]["turn_delta_deg"] = 0.0
			samples[index]["curvature_inv_m"] = 0.0
			samples[index]["curvature_deg_per_100m"] = 0.0
			samples[index]["turn_direction_route_convention"] = "near_straight"
	return samples

func _route_sample(s: float) -> Dictionary:
	var clamped_s := clampf(s, 0.0, _route.length_m)
	var center: Vector3 = _route.pos_at(clamped_s)
	var tangent: Vector3 = _route.tangent_at(clamped_s)
	var left: Vector3 = _route.left_at(clamped_s)
	var half_width := _route.road_width_at(clamped_s) * 0.5
	var left_edge := center + left * half_width
	var right_edge := center - left * half_width
	left_edge.y = _route.ground_y(clamped_s, half_width)
	right_edge.y = _route.ground_y(clamped_s, -half_width)
	var center_runtime_asl := center.y + _datum_m
	var left_runtime_asl := left_edge.y + _datum_m
	var right_runtime_asl := right_edge.y + _datum_m
	var heading := _heading_deg(clamped_s)
	var result := {
		"s_m": clamped_s,
		"latlon_center": _latlon_for(Vector2(center.x, center.z)),
		"center": _vector_for(center),
		"left_edge": _vector_for(left_edge),
		"right_edge": _vector_for(right_edge),
		"tangent_xz": {"x": tangent.x, "z": tangent.z},
		"left_xz": {"x": left.x, "z": left.z},
		"road_width_m": _route.road_width_at(clamped_s),
		"heading_deg": heading,
		"grade_pct": _route.grade_at(clamped_s),
		"runtime_road_asl_m": center_runtime_asl,
		"runtime_left_edge_asl_m": left_runtime_asl,
		"runtime_right_edge_asl_m": right_runtime_asl,
		"raw_dem_center_asl_m": _raw_height_asl(Vector2(center.x, center.z), false),
		"raw_dem_coarse_center_asl_m": _raw_height_asl(Vector2(center.x, center.z), true),
		"raw_dem_left_edge_asl_m": _raw_height_asl(Vector2(left_edge.x, left_edge.z), false),
		"raw_dem_right_edge_asl_m": _raw_height_asl(Vector2(right_edge.x, right_edge.z), false)
	}
	return result

func _summarise_window(samples: Array, center_s: float) -> Dictionary:
	if samples.is_empty():
		return {}
	var min_grade := INF
	var max_grade := -INF
	var sum_grade_sq := 0.0
	var min_curvature := INF
	var max_curvature := -INF
	var max_abs_curvature := -INF
	var max_abs_station := center_s
	var max_residual := 0.0
	var max_residual_station := center_s
	var residual_sum_sq := 0.0
	var finite_residual_count := 0
	for sample in samples:
		var grade := float(sample.get("grade_pct", 0.0))
		var curvature := float(sample.get("curvature_deg_per_100m", 0.0))
		min_grade = minf(min_grade, grade)
		max_grade = maxf(max_grade, grade)
		sum_grade_sq += grade * grade
		min_curvature = minf(min_curvature, curvature)
		max_curvature = maxf(max_curvature, curvature)
		if absf(curvature) > max_abs_curvature:
			max_abs_curvature = absf(curvature)
			max_abs_station = float(sample["s_m"])
		var raw = sample.get("raw_dem_center_asl_m", null)
		if raw is float or raw is int:
			var residual := float(sample["runtime_road_asl_m"]) - float(raw)
			if is_finite(residual):
				max_residual = maxf(max_residual, absf(residual))
				if absf(residual) >= max_residual - 0.0001:
					max_residual_station = float(sample["s_m"])
				residual_sum_sq += residual * residual
				finite_residual_count += 1
	var first: Dictionary = samples.front()
	var last: Dictionary = samples.back()
	return {
		"sample_count": samples.size(),
		"station_start_m": first["s_m"],
		"station_end_m": last["s_m"],
		"heading_start_deg": first["heading_deg"],
		"heading_end_deg": last["heading_deg"],
		"heading_delta_unwrapped_deg": last.get("heading_unwrapped_deg", 0.0),
		"grade_min_pct": min_grade,
		"grade_max_pct": max_grade,
		"grade_rms_pct": sqrt(sum_grade_sq / float(maxi(samples.size(), 1))),
		"curvature_min_deg_per_100m": min_curvature,
		"curvature_max_deg_per_100m": max_curvature,
		"max_abs_curvature_deg_per_100m": max_abs_curvature,
		"max_abs_curvature_station_m": max_abs_station,
		"runtime_minus_raw_dem_max_abs_m": max_residual,
		"runtime_minus_raw_dem_max_station_m": max_residual_station,
		"runtime_minus_raw_dem_rms_m": sqrt(residual_sum_sq / float(maxi(finite_residual_count, 1))),
		"nearest_left_rock_landmarks": _landmarks_near(center_s, S13_WINDOW_HALF_M, "rock", "left")
	}

func _build_candidates(samples: Array, acceptance_s: float, checkpoint_s: float) -> Array:
	var candidates: Array = []
	candidates.append(_candidate_at(acceptance_s, "S13 acceptance station", "fixed geo scene-map anchor; estimated visual inference"))
	candidates.append(_candidate_at(checkpoint_s, "S13 630 s route checkpoint", "legacy time checkpoint; estimated mapping"))
	for landmark in _landmarks_near(acceptance_s, S13_WINDOW_HALF_M, "rock", "left"):
		candidates.append(_candidate_at(float(landmark.get("distance_m", acceptance_s)), "left rock landmark", String(landmark.get("mapping", "estimated landmark"))))
	var extrema: Array = []
	for index in range(1, samples.size() - 1):
		var current := absf(float(samples[index].get("curvature_deg_per_100m", 0.0)))
		var before := absf(float(samples[index - 1].get("curvature_deg_per_100m", 0.0)))
		var after := absf(float(samples[index + 1].get("curvature_deg_per_100m", 0.0)))
		if current >= before and current >= after:
			extrema.append(samples[index])
	extrema.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return absf(float(a.get("curvature_deg_per_100m", 0.0))) > absf(float(b.get("curvature_deg_per_100m", 0.0)))
	)
	var selected_stations: Array[float] = []
	for sample in extrema:
		var station := float(sample["s_m"])
		var separated := true
		for prior in selected_stations:
			if absf(station - prior) < 30.0:
				separated = false
				break
		if not separated:
			continue
		selected_stations.append(station)
		candidates.append(_candidate_from_sample(sample, "local curvature extremum", "route geometry candidate; source matching unverified"))
		if selected_stations.size() >= 6:
			break
	return candidates

func _candidate_at(station: float, source: String, evidence: String) -> Dictionary:
	var clamped := clampf(station, 0.0, _route.length_m)
	var sample := _route_sample(clamped)
	_set_curvature_metrics(sample, clamped)
	var candidate := _candidate_from_sample(sample, source, evidence)
	candidate["delta_from_s13_acceptance_m"] = clamped - _route.acceptance_distance("S13")
	return candidate

func _candidate_from_sample(sample: Dictionary, source: String, evidence: String) -> Dictionary:
	return {
		"station_m": sample["s_m"],
		"source": source,
		"evidence": evidence,
		"heading_deg": sample["heading_deg"],
		"grade_pct": sample["grade_pct"],
		"curvature_deg_per_100m": sample.get("curvature_deg_per_100m", 0.0),
		"turn_direction_route_convention": sample.get("turn_direction_route_convention", "near_straight"),
		"center": sample["center"],
		"left_edge": sample["left_edge"],
		"right_edge": sample["right_edge"],
		"runtime_road_asl_m": sample["runtime_road_asl_m"],
		"raw_dem_center_asl_m": sample["raw_dem_center_asl_m"],
		"delta_from_s13_acceptance_m": float(sample["s_m"]) - _route.acceptance_distance("S13"),
		"needs_native_probe": true
	}

func _set_curvature_metrics(sample: Dictionary, station: float) -> void:
	var clamped := clampf(station, 0.0, _route.length_m)
	var previous_s := maxf(0.0, clamped - _analysis_step_m)
	var next_s := minf(_route.length_m, clamped + _analysis_step_m)
	if next_s - previous_s <= 0.001:
		sample["turn_delta_deg"] = 0.0
		sample["curvature_inv_m"] = 0.0
		sample["curvature_deg_per_100m"] = 0.0
		sample["turn_direction_route_convention"] = "near_straight"
		return
	var turn_deg := _angle_delta_deg(_heading_deg(previous_s), _heading_deg(next_s))
	sample["turn_delta_deg"] = turn_deg
	sample["curvature_inv_m"] = deg_to_rad(turn_deg) / (next_s - previous_s)
	sample["curvature_deg_per_100m"] = turn_deg / (next_s - previous_s) * 100.0
	sample["turn_direction_route_convention"] = _turn_direction_from_delta(turn_deg)

func _build_s08_comparison() -> Dictionary:
	var acceptance := _candidate_at(S08_ACCEPTANCE_S, "S08 current acceptance", "existing fixed scene station; kept for comparison only")
	var alternate := _candidate_at(S08_ALTERNATE_S, "S08 alternate diagnostic", "HUD/elevation candidate; not a production anchor")
	var delta_position := Vector3(
		float(alternate["center"]["x"]) - float(acceptance["center"]["x"]),
		float(alternate["center"]["y"]) - float(acceptance["center"]["y"]),
		float(alternate["center"]["z"]) - float(acceptance["center"]["z"])
	)
	return {
		"note": "S08 station comparison is a separate diagnostic; no acceptance mapping was changed.",
		"current_acceptance_station_m": S08_ACCEPTANCE_S,
		"alternate_diagnostic_station_m": S08_ALTERNATE_S,
		"station_delta_m": S08_ALTERNATE_S - S08_ACCEPTANCE_S,
		"world_delta": _vector_for(delta_position),
		"current": acceptance,
		"alternate": alternate
	}

func _landmarks_near(center_s: float, radius: float, kind := "", side := "") -> Array:
	var result: Array = []
	for item in _route.landmarks():
		if not (item is Dictionary):
			continue
		var landmark: Dictionary = item
		var station := float(landmark.get("distance_m", landmark.get("s_m", INF)))
		if absf(station - center_s) > radius:
			continue
		if not kind.is_empty() and String(landmark.get("type", "")) != kind:
			continue
		if not side.is_empty() and String(landmark.get("side", "")) != side:
			continue
		result.append(landmark.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return absf(float(a.get("distance_m", INF)) - center_s) < absf(float(b.get("distance_m", INF)) - center_s)
	)
	return result

func _heading_deg(s: float) -> float:
	var tangent := _route.tangent_at(clampf(s, 0.0, _route.length_m))
	return _heading_deg_from_tangent(tangent)

func _heading_deg_from_tangent(tangent: Vector3) -> float:
	return rad_to_deg(atan2(-tangent.x, -tangent.z))

func _turn_direction_from_delta(turn_deg: float) -> String:
	# Local -Z is forward and local -X is left.  Positive yaw/heading therefore
	# turns toward left; this is verified below with a synthetic basis and the
	# actual route tangent/left_at dot product.
	return "left" if turn_deg > 0.05 else ("right" if turn_deg < -0.05 else "near_straight")

func _direction_sign_proof(station: float) -> Dictionary:
	var synthetic_angle_deg := 15.0
	var synthetic_forward := Vector3(0.0, 0.0, -1.0)
	var synthetic_world_left := Vector3(-1.0, 0.0, 0.0)
	var synthetic_left_tangent := Vector3(
		-sin(deg_to_rad(synthetic_angle_deg)),
		0.0,
		-cos(deg_to_rad(synthetic_angle_deg))
	)
	var synthetic_start_heading := _heading_deg_from_tangent(synthetic_forward)
	var synthetic_left_heading := _heading_deg_from_tangent(synthetic_left_tangent)
	var synthetic_delta := _angle_delta_deg(synthetic_start_heading, synthetic_left_heading)
	var clamped := clampf(station, 0.0, _route.length_m)
	var previous_s := maxf(0.0, clamped - _analysis_step_m)
	var next_s := minf(_route.length_m, clamped + _analysis_step_m)
	var tangent := _route.tangent_at(clamped)
	var left := _route.left_at(clamped)
	var previous_tangent := _route.tangent_at(previous_s)
	var next_tangent := _route.tangent_at(next_s)
	var route_previous_heading := _heading_deg(previous_s)
	var route_next_heading := _heading_deg(next_s)
	var route_delta := _angle_delta_deg(route_previous_heading, route_next_heading)
	return {
		"convention": "forward local -Z, world-left local -X; positive heading delta and positive tangent cross.y mean left",
		"synthetic_forward": _vector_for(synthetic_forward),
		"synthetic_world_left": _vector_for(synthetic_world_left),
		"synthetic_left_tangent": _vector_for(synthetic_left_tangent),
		"synthetic_start_heading_deg": synthetic_start_heading,
		"synthetic_left_heading_deg": synthetic_left_heading,
		"synthetic_turn_delta_deg": synthetic_delta,
		"synthetic_turn_direction": _turn_direction_from_delta(synthetic_delta),
		"route_station_m": clamped,
		"route_step_m": _analysis_step_m,
		"route_tangent": _vector_for(tangent),
		"route_left_basis": _vector_for(left),
		"route_tangent_dot_left": tangent.dot(left),
		"route_previous_heading_deg": route_previous_heading,
		"route_next_heading_deg": route_next_heading,
		"route_turn_delta_deg": route_delta,
		"route_turn_cross_y": tangent.cross(next_tangent).y,
		"route_future_tangent_dot_current_left": next_tangent.dot(left),
		"route_future_tangent_dot_current_right": next_tangent.dot(-left),
		"route_turn_direction": _turn_direction_from_delta(route_delta)
	}

func _angle_delta_deg(from_heading: float, to_heading: float) -> float:
	return rad_to_deg(wrapf(deg_to_rad(to_heading - from_heading) + PI, 0.0, TAU) - PI)

func _raw_height_asl(xz: Vector2, coarse: bool) -> Variant:
	var geography = _route.get("geography")
	if geography is Object:
		var method := "raw_height_asl_world_coarse" if coarse else "raw_height_asl_world"
		if geography.has_method(method):
			var value = geography.call(method, xz)
			if is_finite(float(value)):
				return float(value)
		if geography.has_method("raw_height_world"):
			var local_value = geography.call("raw_height_world", xz)
			if is_finite(float(local_value)):
				return float(local_value) + _datum_m
	return null

func _latlon_for(xz: Vector2) -> Variant:
	var geography = _route.get("geography")
	if geography is Object and geography.has_method("latlon_from_world"):
		var latlon: Vector2 = geography.call("latlon_from_world", xz)
		return {"lat": latlon.x, "lon": latlon.y}
	return null

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

func _write_markdown(path: String, output: Dictionary) -> void:
	var s13: Dictionary = output["s13"]
	var summary: Dictionary = s13["window_summary"]
	var lines := PackedStringArray()
	lines.append("# Saisies R10 S13 landmark diagnostic")
	lines.append("")
	lines.append("Status: diagnostic only. The values below are estimated source-view/route-geometry evidence, not camera calibration or GPS. No runtime route, camera, scene map, or 18-reference file was changed.")
	lines.append("")
	lines.append("## Source sequence")
	lines.append("")
	lines.append("The contact sheet covers %.3f–%.3f s at %.3f fps. Use `source_sequence/source_sequence_manifest.json` for exact tile times; tiles are ordered source_001 onward." % [_from_time, _to_time, _source_fps])
	lines.append("")
	lines.append("## S13 route window")
	lines.append("")
	lines.append("Acceptance station: %.3f m; 630 s checkpoint station: %.3f m; acceptance pose pitch %.3f deg, yaw %.3f deg." % [float(s13["acceptance_station_m"]), float(s13["video_checkpoint_station_m"]), float(s13["acceptance_pose"].get("pitch_deg", 0.0)), float(s13["acceptance_pose"].get("yaw_deg", 0.0))])
	lines.append("Window %.3f–%.3f m, %d samples at %.3f m. Heading changes %.3f deg unwrapped; grade range %.3f..%.3f%%; curvature range %.3f..%.3f deg/100 m." % [float(summary["station_start_m"]), float(summary["station_end_m"]), int(summary["sample_count"]), _analysis_step_m, float(summary["heading_delta_unwrapped_deg"]), float(summary["grade_min_pct"]), float(summary["grade_max_pct"]), float(summary["curvature_min_deg_per_100m"]), float(summary["curvature_max_deg_per_100m"])])
	lines.append("Largest absolute route curvature is %.3f deg/100 m at s=%.3f m. Runtime road minus raw DEM center height reaches %.3f m at s=%.3f m (RMS %.3f m)." % [float(summary["max_abs_curvature_deg_per_100m"]), float(summary["max_abs_curvature_station_m"]), float(summary["runtime_minus_raw_dem_max_abs_m"]), float(summary["runtime_minus_raw_dem_max_station_m"]), float(summary["runtime_minus_raw_dem_rms_m"])])
	lines.append("")
	var sign_proof: Dictionary = s13["direction_sign_proof"]
	lines.append("### Heading-turn sign proof")
	lines.append("")
	lines.append("Synthetic forward is local -Z and world-left is local -X: a 15° left turn produces heading delta %.3f° and is labelled `%s`. Positive heading delta is therefore left; negative is right." % [float(sign_proof["synthetic_turn_delta_deg"]), String(sign_proof["synthetic_turn_direction"])])
	lines.append("At actual route s=%.3f m with ±%.3f m samples, previous→next heading delta is %.3f° and tangent×next-tangent Y is %.6f; future tangent dot current left is %.6f (dot current right %.6f), so this station is labelled `%s`." % [float(sign_proof["route_station_m"]), float(sign_proof["route_step_m"]), float(sign_proof["route_turn_delta_deg"]), float(sign_proof["route_turn_cross_y"]), float(sign_proof["route_future_tangent_dot_current_left"]), float(sign_proof["route_future_tangent_dot_current_right"]), String(sign_proof["route_turn_direction"])])
	lines.append("This sign proof uses the route's actual `tangent_at`/`left_at` basis and corrects the earlier diagnostic labels; it does not change production route or camera data.")
	lines.append("")
	lines.append("### Candidate stations")
	lines.append("")
	lines.append("| station m | source | heading deg | curvature deg/100m | turn convention | evidence | native probe |")
	lines.append("|---:|---|---:|---:|---|---|---|")
	for candidate in s13["candidate_stations"]:
		lines.append("| %.3f | %s | %.3f | %.3f | %s | %s | required |" % [float(candidate["station_m"]), String(candidate["source"]), float(candidate["heading_deg"]), float(candidate.get("curvature_deg_per_100m", 0.0)), String(candidate.get("turn_direction_route_convention", "")), String(candidate.get("evidence", ""))])
	lines.append("")
	lines.append("The source centerline and left rock/edge corner are retained as visual observations without assigning source pixels to route s. The route samples include centerline, left/right road-edge world points, heading, grade, runtime road elevation, raw DEM elevations, and lat/lon returned by the shared geography helper.")
	lines.append("Approximate S13 centerline pixels used as qualitative evidence: (205,744), (456,532), (550,449), (660,394), (744,364). Approximate left rock/road contact runs from (0,478) toward the far bend endpoint near (605,393); these are hand-read image points and are not route correspondences.")
	lines.append("")
	lines.append("## View probe range (inference only)")
	lines.append("")
	lines.append("Native-probe range: lateral -2.4..-1.4 m (negative route.left is right of center), absolute yaw -10..-4 deg, and absolute pitch -28..-20 deg. Lateral -1.4 and yaw -4 moved the near/forward white line toward the source; pitch -16 placed the road exit around y=420 versus source around y=350, so the next pitch sweep should be more negative. These are native-render probe ranges only; this tool applied none of them.")
	lines.append("")
	lines.append("## S08 comparison")
	lines.append("")
	lines.append("Current acceptance s=%.3f m versus alternate diagnostic s=%.3f m (delta %.3f m). The alternate is retained as evidence only and is not a production anchor." % [float(output["s08"]["current_acceptance_station_m"]), float(output["s08"]["alternate_diagnostic_station_m"]), float(output["s08"]["station_delta_m"])])
	lines.append("")
	lines.append("Generated by `tools/analyze_saisies_round10_landmark.gd`.")
	var global_path := _global_path(path)
	DirAccess.make_dir_recursive_absolute(global_path.get_base_dir())
	var file := FileAccess.open(global_path, FileAccess.WRITE)
	if file == null:
		_fail("could not write Markdown: %s" % path)
		return
	file.store_string("\n".join(lines) + "\n")
	file.close()

func _print_summary(output: Dictionary) -> void:
	var summary: Dictionary = output["s13"]["window_summary"]
	print("round10 S13 station acceptance=%.3f checkpoint=%.3f" % [float(output["s13"]["acceptance_station_m"]), float(output["s13"]["video_checkpoint_station_m"])])
	print("round10 S13 heading_delta=%.3f deg curvature_abs_max=%.3f deg/100m at s=%.3f" % [float(summary["heading_delta_unwrapped_deg"]), float(summary["max_abs_curvature_deg_per_100m"]), float(summary["max_abs_curvature_station_m"])])
	print("round10 S13 runtime_raw_residual_max=%.3f m rms=%.3f m" % [float(summary["runtime_minus_raw_dem_max_abs_m"]), float(summary["runtime_minus_raw_dem_rms_m"])])
	var sign_proof: Dictionary = output["s13"]["direction_sign_proof"]
	print("round10 turn-sign synthetic_delta=%.3f direction=%s route_station=%.3f route_delta=%.3f route_dot_left=%.6f direction=%s" % [float(sign_proof["synthetic_turn_delta_deg"]), String(sign_proof["synthetic_turn_direction"]), float(sign_proof["route_station_m"]), float(sign_proof["route_turn_delta_deg"]), float(sign_proof["route_future_tangent_dot_current_left"]), String(sign_proof["route_turn_direction"])])
	for candidate in output["s13"]["candidate_stations"]:
		print("round10 candidate s=%.3f source=%s heading=%.3f curvature=%.3f turn=%s" % [float(candidate["station_m"]), String(candidate["source"]), float(candidate["heading_deg"]), float(candidate.get("curvature_deg_per_100m", 0.0)), String(candidate.get("turn_direction_route_convention", ""))])
	print("round10 outputs json=%s markdown=%s contact=%s" % [_output_dir.path_join("round10_s13_landmark_analysis.json"), _output_dir.path_join("round10_s13_landmark_analysis.md"), _output_dir.path_join("source_sequence/source_sequence_contact.jpg")])

func _global_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path if path.is_absolute_path() else ProjectSettings.globalize_path(path)

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES R10 LANDMARK: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES R10 LANDMARK READY/HOLD")
		quit(0)
	else:
		for error in _errors:
			print("SAISIES R10 LANDMARK ERROR: " + error)
		quit(1)
