extends SceneTree

## Offline S01 road-edge / camera fit diagnostic.
##
## This tool projects the actual v2 route's two road-edge curves into a pinhole
## camera and searches estimated pitch/yaw/lateral/height/FOV ranges.  It never
## edits the shipped camera, route, scene map, or scene files.  Target pixels
## are manually read from the source S01 frame, so the result is a view-fit
## diagnostic rather than camera calibration, GPS, or a claim about the
## source lens (which may include fisheye distortion and hand motion).
##
## Example:
##   godot --headless --path . --script res://tools/fit_saisies_start_camera.gd -- \
##     --target-file=/tmp/s01_targets.json --output=/tmp/s01_fit.json
##   godot --headless --path . --script res://tools/fit_saisies_start_camera.gd -- \
##     --route-script=res://scripts/saisies_geo_route.gd \
##     --route-file=res://data/saisies_geo_route.json

const DEFAULT_ROUTE_SCRIPT_PATH := "res://scripts/saisies_route.gd"
const DEFAULT_ROUTE_FILE := "res://data/saisies_route_v2.json"
const DEFAULT_TARGET_FILE := "res://export/saisies/review/round7_brief/curb_diagnostic.json"
const DEFAULT_TARGET_RESULT := "yaw20_right17"
const DEFAULT_OUTPUT_FILE := "/tmp/saisies_start_camera_fit.json"
const SOURCE_FRAME := "res://video/saisies_analysis/acceptance/S01_f000120.png"
const REFERENCE_RENDER := "res://export/saisies/review/round7_retained/S01.png"
const CAPTURE_SIZE := Vector2(1920.0, 1080.0)
const EDGE_CURVE_STEP_M := 1.0

var _errors: Array[String] = []
var _route: SaisiesRoute
var _camera_s := 0.0
var _target_file := DEFAULT_TARGET_FILE
var _target_result := DEFAULT_TARGET_RESULT
var _output_file := DEFAULT_OUTPUT_FILE
var _route_script_path := DEFAULT_ROUTE_SCRIPT_PATH
var _route_file := DEFAULT_ROUTE_FILE
var _samples_cache: Array = []
var _edge_curve: Array = []
var _unknown_s_mode := false
var _search_cache: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_parse_args()
	var route_script := load(_route_script_path)
	if route_script == null:
		_fail("could not load route script: %s" % _route_script_path)
		_finish()
		return
	_route = route_script.new() as SaisiesRoute
	_route.name = "Route"
	_route.route_file = _route_file
	# Geographic routes keep their data path in geo_route_file so their loader
	# cannot accidentally fall back to the v2 route_file property.
	for property in _route.get_property_list():
		if String(property.get("name", "")) == "geo_route_file":
			_route.set("geo_route_file", _route_file)
			break
	_route.fallback_length_m = 14800.0
	_route.fallback_start_elevation_m = 1608.0
	_route.fallback_end_elevation_m = 717.0
	_route.fallback_road_width_m = 6.4
	_route.shoulder_width_m = 0.28
	_route.downhill_terrain_factor = 1.0
	_route.village_flatten_radius_m = 18.0
	get_root().add_child(_route)
	await process_frame
	await process_frame
	if not _route.route_ready():
		_fail("v2 route did not become ready")
		_finish()
		return
	_camera_s = _arg_float("camera-s", _route.acceptance_distance("S01"))
	_camera_s = clampf(_camera_s, 0.0, _route.length_m)
	var samples := _load_target_samples()
	if samples.is_empty():
		_fail("no usable S01 road-edge target samples were found")
		_finish()
		return
	_samples_cache = samples
	_edge_curve = _build_edge_curve(samples)
	var search := _search_config()
	_search_cache = search
	var baseline_params := {
		"pitch_deg": _arg_float("baseline-pitch", -16.0),
		"yaw_deg": _arg_float("baseline-yaw", 20.0),
		"lateral_m": _arg_float("baseline-lateral", -1.7),
		"height_m": float(search["primary_height_m"]),
		"fov_deg": float(search["primary_fov_deg"])
	}
	var baseline := _evaluate(samples, baseline_params, false)
	var coarse := _run_grid(samples, search, "primary_coarse", false)
	coarse.sort_custom(_candidate_sort)
	var refine := _run_refinement(samples, coarse, search, false)
	refine.sort_custom(_candidate_sort)
	var combined := []
	combined.append_array(coarse.slice(0, mini(24, coarse.size())))
	combined.append_array(refine)
	combined.sort_custom(_candidate_sort)
	var top_candidates := []
	var seen := {}
	for candidate in combined:
		var key := _candidate_key(candidate)
		if seen.has(key):
			continue
		seen[key] = true
		top_candidates.append(_candidate_for_output(candidate))
		if top_candidates.size() >= 12:
			break
	var free_coarse := _run_grid(samples, search, "free_height_fov_coarse", true)
	free_coarse.sort_custom(_candidate_sort)
	var free_candidates := []
	for candidate in free_coarse.slice(0, mini(8, free_coarse.size())):
		free_candidates.append(_candidate_for_output(candidate))
	var output := {
		"note": "Estimated source-view road fit; manual image points and authored route, not camera calibration/GPS. Source may be fisheye or hand-held.",
		"mode": "unknown_s_polyline_2d" if _unknown_s_mode else "known_s_point_pairs",
		"match_method": "nearest 2D projected road-edge polyline segment distance in pixels" if _unknown_s_mode else "direct projected point residual in pixels",
		"route_script": _route_script_path,
		"route_file": _route_file,
		"route_length_m": _route.length_m,
		"camera_s_m": _camera_s,
		"source_frame": SOURCE_FRAME,
		"reference_render": REFERENCE_RENDER,
		"target_file": _target_file,
		"target_result": _target_result,
		"target_samples": _samples_for_output(samples),
		"road_edge_curve": _road_curve_for_output(samples),
		"baseline": _candidate_for_output(baseline),
		"search": search,
		"primary_contract": {
			"height_m": search["primary_height_m"],
			"fov_deg": search["primary_fov_deg"],
			"optimized_parameters": ["pitch_deg", "yaw_deg", "lateral_m"]
		},
		"free_height_fov_note": "Diagnostic only: height/FOV are weakly identifiable from these hand-read road edges; ranking uses a prior toward the primary 1.65 m / 79 deg contract.",
		"coarse_candidate_count": coarse.size(),
		"refine_candidate_count": refine.size(),
		"primary_candidates": top_candidates,
		"free_height_fov_diagnostic": free_candidates,
		"candidates": top_candidates
	}
	var file := FileAccess.open(_output_file, FileAccess.WRITE)
	if file == null:
		_fail("could not write fit output: %s" % _output_file)
	else:
		file.store_string(JSON.stringify(output, "\t"))
		file.close()
	print("SAISIES START CAMERA FIT output=%s route_s=%.3f targets=%d mode=%s match=%s" % [_output_file, _camera_s, samples.size(), output["mode"], output["match_method"]])
	print("baseline fit_mae=%.2f holdout_mae=%s left_mae=%.2f right_mae=%.2f" % [float(baseline["fit_mae"]), _format_metric(baseline["holdout_mae"]), float(baseline["left_mae"]), float(baseline["right_mae"])])
	for index in range(mini(5, top_candidates.size())):
		var candidate: Dictionary = top_candidates[index]
		var params: Dictionary = candidate["params"]
		print("candidate=%d pitch=%.2f yaw=%.2f lateral=%.3f height=%.3f fov=%.2f fit_mae=%.2f holdout_mae=%s left_mae=%.2f right_mae=%.2f fit_left=%.2f fit_right=%.2f" % [
			index + 1,
			float(params["pitch_deg"]), float(params["yaw_deg"]), float(params["lateral_m"]),
			float(params["height_m"]), float(params["fov_deg"]),
			float(candidate["fit_mae"]), _format_metric(candidate["holdout_mae"]),
			float(candidate["left_mae"]), float(candidate["right_mae"]),
			float(candidate["fit_left_mae"]), float(candidate["fit_right_mae"])
		])
	for index in range(mini(3, free_candidates.size())):
		var diagnostic: Dictionary = free_candidates[index]
		var diagnostic_params: Dictionary = diagnostic["params"]
		print("free_diagnostic=%d pitch=%.2f yaw=%.2f lateral=%.3f height=%.3f fov=%.2f fit_mae=%.2f regularized_score=%.2f prior_penalty=%.2f holdout_mae=%s" % [
			index + 1,
			float(diagnostic_params["pitch_deg"]), float(diagnostic_params["yaw_deg"]), float(diagnostic_params["lateral_m"]),
			float(diagnostic_params["height_m"]), float(diagnostic_params["fov_deg"]),
			float(diagnostic["fit_mae"]), float(diagnostic["regularized_score"]), float(diagnostic["regularization_px"]),
			_format_metric(diagnostic["holdout_mae"])
		])
	_finish()

func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--route-script="):
			_route_script_path = arg.substr(15)
		elif arg.begins_with("--route-file="):
			_route_file = arg.substr(13)
		if arg.begins_with("--target-file="):
			_target_file = arg.substr(14)
		elif arg.begins_with("--target-result="):
			_target_result = arg.substr(16)
		elif arg.begins_with("--output="):
			_output_file = arg.substr(9)

func _arg_float(name: String, default_value: float) -> float:
	var prefix := "--%s=" % name
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return float(arg.substr(prefix.length()))
	return default_value

func _search_config() -> Dictionary:
	return {
		"pitch_min_deg": _arg_float("pitch-min", -24.0),
		"pitch_max_deg": _arg_float("pitch-max", -8.0),
		"pitch_step_deg": _arg_float("pitch-step", 2.0),
		"yaw_min_deg": _arg_float("yaw-min", 8.0),
		"yaw_max_deg": _arg_float("yaw-max", 32.0),
		"yaw_step_deg": _arg_float("yaw-step", 2.0),
		"lateral_min_m": _arg_float("lateral-min", -3.0),
		"lateral_max_m": _arg_float("lateral-max", -0.5),
		"lateral_step_m": _arg_float("lateral-step", 0.5),
		"height_min_m": _arg_float("height-min", 1.45),
		"height_max_m": _arg_float("height-max", 1.85),
		"height_step_m": _arg_float("height-step", 0.10),
		"fov_min_deg": _arg_float("fov-min", 72.0),
		"fov_max_deg": _arg_float("fov-max", 86.0),
		"fov_step_deg": _arg_float("fov-step", 2.0),
		"refine_seeds": int(_arg_float("refine-seeds", 2.0)),
		"primary_height_m": _arg_float("primary-height", 1.65),
		"primary_fov_deg": _arg_float("primary-fov", 79.0),
		"free_prior_weight_px": _arg_float("free-prior-weight", 4.0),
		"free_prior_height_scale_m": _arg_float("free-prior-height-scale", 0.25),
		"free_prior_fov_scale_deg": _arg_float("free-prior-fov-scale", 8.0)
	}

func _load_target_samples() -> Array:
	if not FileAccess.file_exists(_target_file):
		_fail("target file does not exist: %s" % _target_file)
		return []
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(_target_file))
	if not (parsed is Dictionary):
		_fail("target file is not a JSON object: %s" % _target_file)
		return []
	var raw_samples: Array = []
	if parsed.has("samples") and parsed["samples"] is Array:
		raw_samples = parsed["samples"]
	elif parsed.has("results") and parsed["results"] is Dictionary:
		var results: Dictionary = parsed["results"]
		var selected = results.get(_target_result, null)
		if not (selected is Dictionary):
			var names := results.keys()
			if not names.is_empty():
				selected = results[names[0]]
		if selected is Dictionary and selected.get("samples", null) is Array:
			raw_samples = selected["samples"]
	if raw_samples.is_empty():
		_fail("target file contains no samples or results.%s.samples" % _target_result)
		return []
	var explicit_s_flags := []
	for raw_value in raw_samples:
		if raw_value is Dictionary:
			var raw_s = raw_value.get("s", null)
			explicit_s_flags.append(raw_s is int or raw_s is float)
	if explicit_s_flags.is_empty():
		_fail("target samples contain no dictionaries")
		return []
	var has_explicit_s := bool(explicit_s_flags[0])
	for flag in explicit_s_flags:
		if bool(flag) != has_explicit_s:
			_fail("target samples must either all provide route s or all omit it")
			return []
	_unknown_s_mode = not has_explicit_s
	var samples := []
	var side_counts := {}
	for index in range(raw_samples.size()):
		var raw = raw_samples[index]
		if not (raw is Dictionary):
			continue
		var side := String(raw.get("side", "" )).to_lower()
		if side not in ["left", "right"]:
			_fail("target sample %d has invalid side: %s" % [index, side])
			continue
		var side_index := int(side_counts.get(side, 0))
		side_counts[side] = side_index + 1
		var target = raw.get("target", raw.get("target_px", null))
		var target_x := float(raw.get("target_x", 0.0))
		var target_y := float(raw.get("target_y", 0.0))
		if target is Array and target.size() >= 2:
			target_x = float(target[0])
			target_y = float(target[1])
		if target_x <= 0.0 or target_y <= 0.0:
			_fail("target sample %d has invalid target pixel: %.1f, %.1f" % [index, target_x, target_y])
			continue
		var holdout_default: bool = side_index % 4 == 3 and int(side_counts[side]) >= 4
		var holdout := bool(raw.get("holdout", holdout_default))
		if raw.has("fit") and not bool(raw["fit"]):
			holdout = true
		var sample := {
			"index": index,
			"side": side,
			"side_index": side_index,
			"target": Vector2(target_x, target_y),
			"holdout": holdout
		}
		if has_explicit_s:
			var sample_s := clampf(float(raw["s"]), 0.0, _route.length_m)
			var half_width := _route.road_width_at(sample_s) * 0.5
			var lateral := float(raw.get("u", half_width if side == "left" else -half_width))
			var ground_offset := float(raw.get("ground_offset_m", 0.06))
			var world := _route.pos_at(sample_s) + _route.left_at(sample_s) * lateral
			world.y = _route.ground_y(sample_s, lateral) + ground_offset
			sample["s"] = sample_s
			sample["u"] = lateral
			sample["world"] = world
		else:
			# Without a route distance the point is matched against the projected
			# edge polyline; assigning a guessed s here would bias the fit.
			sample["s"] = null
			sample["u"] = raw.get("u", null)
		samples.append(sample)
	if not side_counts.has("left") or not side_counts.has("right"):
		_fail("target samples must contain both left and right road edges")
	return samples

func _build_edge_curve(_samples: Array) -> Array:
	# The source points have no known route distance.  Build both authored road
	# edges densely from just ahead of the camera through the available 250 m
	# window, then match source pixels to this projected polyline.
	var start_s := minf(_route.length_m, _camera_s + 0.3)
	var end_s := minf(_route.length_m, _camera_s + 250.0)
	var curve := []
	var s := start_s
	while s <= end_s + 0.001:
		var half_width := _route.road_width_at(s) * 0.5
		for side in ["left", "right"]:
			var lateral := half_width if side == "left" else -half_width
			var world := _route.pos_at(s) + _route.left_at(s) * lateral
			world.y = _route.ground_y(s, lateral) + 0.06
			curve.append({"s": s, "side": side, "u": lateral, "world": world})
		s += EDGE_CURVE_STEP_M
	# Ensure a short route still has an exact endpoint for the reported curve.
	if curve.is_empty() or float(curve.back()["s"]) < end_s - 0.001:
		var half_width := _route.road_width_at(end_s) * 0.5
		for side in ["left", "right"]:
			var lateral := half_width if side == "left" else -half_width
			var world := _route.pos_at(end_s) + _route.left_at(end_s) * lateral
			world.y = _route.ground_y(end_s, lateral) + 0.06
			curve.append({"s": end_s, "side": side, "u": lateral, "world": world})
	return curve

func _run_grid(samples: Array, search: Dictionary, phase: String, free_height_fov: bool) -> Array:
	var results := []
	var heights := [float(search["primary_height_m"])]
	var fovs := [float(search["primary_fov_deg"])]
	if free_height_fov:
		heights = _float_range(float(search["height_min_m"]), float(search["height_max_m"]), float(search["height_step_m"]))
		fovs = _float_range(float(search["fov_min_deg"]), float(search["fov_max_deg"]), float(search["fov_step_deg"]))
	for pitch in _float_range(float(search["pitch_min_deg"]), float(search["pitch_max_deg"]), float(search["pitch_step_deg"])):
		for yaw in _float_range(float(search["yaw_min_deg"]), float(search["yaw_max_deg"]), float(search["yaw_step_deg"])):
			for lateral in _float_range(float(search["lateral_min_m"]), float(search["lateral_max_m"]), float(search["lateral_step_m"])):
				for height in heights:
					for fov in fovs:
						var params := {"pitch_deg": pitch, "yaw_deg": yaw, "lateral_m": lateral, "height_m": height, "fov_deg": fov}
						var candidate := _evaluate(samples, params, free_height_fov)
						candidate["phase"] = phase
						results.append(candidate)
	return results

func _run_refinement(samples: Array, coarse: Array, search: Dictionary, free_height_fov: bool) -> Array:
	var results := []
	var seed_count := mini(int(search["refine_seeds"]), coarse.size())
	for seed_index in range(seed_count):
		var seed: Dictionary = coarse[seed_index]
		var params: Dictionary = seed["params"]
		var heights := [float(search["primary_height_m"])]
		var fovs := [float(search["primary_fov_deg"])]
		if free_height_fov:
			heights = _float_range(maxf(float(search["height_min_m"]), float(params["height_m"]) - 0.1), minf(float(search["height_max_m"]), float(params["height_m"]) + 0.1), 0.025)
			fovs = _float_range(maxf(float(search["fov_min_deg"]), float(params["fov_deg"]) - 2.0), minf(float(search["fov_max_deg"]), float(params["fov_deg"]) + 2.0), 0.5)
		for pitch in _float_range(maxf(float(search["pitch_min_deg"]), float(params["pitch_deg"]) - 2.0), minf(float(search["pitch_max_deg"]), float(params["pitch_deg"]) + 2.0), 0.5):
			for yaw in _float_range(maxf(float(search["yaw_min_deg"]), float(params["yaw_deg"]) - 2.0), minf(float(search["yaw_max_deg"]), float(params["yaw_deg"]) + 2.0), 0.5):
				for lateral in _float_range(maxf(float(search["lateral_min_m"]), float(params["lateral_m"]) - 0.5), minf(float(search["lateral_max_m"]), float(params["lateral_m"]) + 0.5), 0.1):
					for height in heights:
						for fov in fovs:
							var refined_params := {"pitch_deg": pitch, "yaw_deg": yaw, "lateral_m": lateral, "height_m": height, "fov_deg": fov}
							var candidate := _evaluate(samples, refined_params, free_height_fov)
							candidate["phase"] = "refine"
							results.append(candidate)
	return results

func _evaluate(samples: Array, params: Dictionary, free_height_fov: bool) -> Dictionary:
	var errors := []
	if _unknown_s_mode:
		var projected_edges := _project_edge_polyline(params)
		for sample_value in samples:
			var sample: Dictionary = sample_value
			var matches: Array = projected_edges.get(String(sample["side"]), [])
			var match := _nearest_polyline_match(sample["target"], matches)
			errors.append(float(match["error_px"]))
		return _metrics_for_errors(samples, errors, params, free_height_fov)
	var transform := _camera_transform(params)
	var fov := float(params["fov_deg"])
	for sample_value in samples:
		var sample: Dictionary = sample_value
		var projection := _project_point(sample["world"], transform, fov)
		var error := 1000000.0
		if bool(projection["valid"]):
			var delta: Vector2 = projection["pixel"] - sample["target"]
			error = delta.length()
		errors.append(error)
	return _metrics_for_errors(samples, errors, params, free_height_fov)

func _metrics_for_errors(samples: Array, errors: Array, params: Dictionary, free_height_fov: bool) -> Dictionary:
	var fit_sum := 0.0
	var holdout_sum := 0.0
	var all_sum := 0.0
	var fit_count := 0
	var holdout_count := 0
	var left_sum := 0.0
	var left_count := 0
	var right_sum := 0.0
	var right_count := 0
	var fit_left_sum := 0.0
	var fit_left_count := 0
	var fit_right_sum := 0.0
	var fit_right_count := 0
	for index in range(samples.size()):
		var sample: Dictionary = samples[index]
		var error := float(errors[index])
		all_sum += error
		if String(sample["side"]) == "left":
			left_sum += error
			left_count += 1
		else:
			right_sum += error
			right_count += 1
		if bool(sample["holdout"]):
			holdout_sum += error
			holdout_count += 1
		else:
			fit_sum += error
			fit_count += 1
			if String(sample["side"]) == "left":
				fit_left_sum += error
				fit_left_count += 1
			else:
				fit_right_sum += error
				fit_right_count += 1
	var fit_left_mae := fit_left_sum / maxf(float(fit_left_count), 1.0)
	var fit_right_mae := fit_right_sum / maxf(float(fit_right_count), 1.0)
	var fit_mae := (fit_left_mae + fit_right_mae) * 0.5 if fit_left_count > 0 and fit_right_count > 0 else fit_sum / maxf(float(fit_count), 1.0)
	var holdout_mae: Variant = null
	if holdout_count > 0:
		holdout_mae = holdout_sum / float(holdout_count)
	var regularization_px := 0.0
	if free_height_fov:
		var height_delta := (float(params["height_m"]) - float(_search_cache["primary_height_m"])) / maxf(float(_search_cache["free_prior_height_scale_m"]), 0.001)
		var fov_delta := (float(params["fov_deg"]) - float(_search_cache["primary_fov_deg"])) / maxf(float(_search_cache["free_prior_fov_scale_deg"]), 0.001)
		regularization_px = float(_search_cache["free_prior_weight_px"]) * (height_delta * height_delta + fov_delta * fov_delta)
	var score := fit_mae + regularization_px
	return {
		"params": params.duplicate(),
		"score": score,
		"regularized_score": score,
		"regularization_px": regularization_px,
		"fit_mae": fit_mae,
		"holdout_mae": holdout_mae,
		"all_mae": all_sum / maxf(float(samples.size()), 1.0),
		"left_mae": left_sum / maxf(float(left_count), 1.0),
		"right_mae": right_sum / maxf(float(right_count), 1.0),
		"fit_left_mae": fit_left_mae,
		"fit_right_mae": fit_right_mae,
		"fit_count": fit_count,
		"holdout_count": holdout_count
	}

func _project_edge_polyline(params: Dictionary) -> Dictionary:
	var projected := {"left": [], "right": []}
	var transform := _camera_transform(params)
	var fov := float(params["fov_deg"])
	for curve_value in _edge_curve:
		var curve_point: Dictionary = curve_value
		var projection := _project_point(curve_point["world"], transform, fov)
		if not bool(projection["valid"]):
			continue
		var side := String(curve_point["side"])
		if not projected.has(side):
			projected[side] = []
		projected[side].append({
			"pixel": projection["pixel"],
			"s": curve_point["s"],
			"u": curve_point["u"]
		})
	return projected

func _nearest_polyline_match(target: Vector2, polyline: Array) -> Dictionary:
	var best_error := 1000000.0
	var best_pixel := Vector2(NAN, NAN)
	var best_s: Variant = null
	var best_segment := -1
	for index in range(maxi(polyline.size() - 1, 0)):
		var a: Vector2 = polyline[index]["pixel"]
		var b: Vector2 = polyline[index + 1]["pixel"]
		var ab := b - a
		var denominator := ab.length_squared()
		var t := 0.0
		if denominator > 0.000001:
			t = clampf((target - a).dot(ab) / denominator, 0.0, 1.0)
		var nearest := a + ab * t
		var error := target.distance_to(nearest)
		if error < best_error:
			best_error = error
			best_pixel = nearest
			best_s = lerpf(float(polyline[index]["s"]), float(polyline[index + 1]["s"]), t)
			best_segment = index
	return {"error_px": best_error, "pixel": best_pixel, "s": best_s, "segment_index": best_segment}

func _camera_transform(params: Dictionary) -> Transform3D:
	var lateral := float(params["lateral_m"])
	var position := _route.pos_at(_camera_s) + _route.left_at(_camera_s) * lateral
	position.y = _route.ground_y(_camera_s, lateral) + 0.02 + float(params["height_m"])
	var heading := _heading_at(_camera_s)
	var next_heading := _heading_at(minf(_camera_s + 12.0, _route.length_m))
	var turn := wrapf(next_heading - heading + PI, 0.0, TAU) - PI
	var roll := clampf(-turn * 2.2, deg_to_rad(-5.0), deg_to_rad(5.0))
	var rotation := Vector3(deg_to_rad(float(params["pitch_deg"])), heading + deg_to_rad(float(params["yaw_deg"])), roll)
	return Transform3D(Basis.from_euler(rotation), position)

func _heading_at(distance_m: float) -> float:
	var tangent := _route.tangent_at(distance_m)
	return atan2(-tangent.x, -tangent.z)

func _project_point(world: Vector3, camera_transform: Transform3D, fov_deg: float) -> Dictionary:
	var local := camera_transform.affine_inverse() * world
	var depth := -local.z
	if depth <= 0.001:
		return {"valid": false, "pixel": Vector2.ZERO, "depth": depth}
	var focal := CAPTURE_SIZE.y * 0.5 / tan(deg_to_rad(fov_deg) * 0.5)
	return {
		"valid": true,
		"pixel": Vector2(CAPTURE_SIZE.x * 0.5 + focal * local.x / depth, CAPTURE_SIZE.y * 0.5 - focal * local.y / depth),
		"depth": depth
	}

func _candidate_for_output(candidate: Dictionary) -> Dictionary:
	var params: Dictionary = candidate["params"]
	var output := {
		"phase": candidate.get("phase", "baseline"),
		"params": params.duplicate(),
		"score": candidate["score"],
		"regularized_score": candidate["regularized_score"],
		"regularization_px": candidate["regularization_px"],
		"fit_mae": candidate["fit_mae"],
		"holdout_mae": candidate["holdout_mae"],
		"all_mae": candidate["all_mae"],
		"left_mae": candidate["left_mae"],
		"right_mae": candidate["right_mae"],
		"fit_left_mae": candidate["fit_left_mae"],
		"fit_right_mae": candidate["fit_right_mae"],
		"fit_count": candidate["fit_count"],
		"holdout_count": candidate["holdout_count"]
	}
	var transform := _camera_transform(params)
	var basis := transform.basis
	output["camera"] = {
		"position": _vec3_array(transform.origin),
		"right": _vec3_array(basis.x),
		"up": _vec3_array(basis.y),
		"back": _vec3_array(basis.z),
		"forward": _vec3_array(-basis.z),
		"roll_deg": rad_to_deg(asin(clampf(basis.x.y, -1.0, 1.0)))
	}
	var projections := []
	if _unknown_s_mode:
		var projected_edges := _project_edge_polyline(params)
		for sample_value in _load_target_samples_for_projection():
			var sample: Dictionary = sample_value
			var target: Vector2 = sample["target"]
			var matches: Array = projected_edges.get(String(sample["side"]), [])
			var match := _nearest_polyline_match(target, matches)
			var projected: Vector2 = match["pixel"]
			var delta := projected - target
			projections.append({
				"index": sample["index"],
				"side": sample["side"],
				"s": null,
				"matched_s": match["s"],
				"segment_index": match["segment_index"],
				"target_px": [target.x, target.y],
				"projected_px": [projected.x, projected.y],
				"dx": delta.x,
				"dy": delta.y,
				"error_px": match["error_px"]
			})
	else:
		for sample_value in _load_target_samples_for_projection():
			var sample: Dictionary = sample_value
			var projection := _project_point(sample["world"], transform, float(params["fov_deg"]))
			var target: Vector2 = sample["target"]
			var projected: Vector2 = projection["pixel"] if bool(projection["valid"]) else Vector2(NAN, NAN)
			var delta := projected - target
			projections.append({
				"index": sample["index"],
				"side": sample["side"],
				"s": sample["s"],
				"target_px": [target.x, target.y],
				"projected_px": [projected.x, projected.y],
				"dx": delta.x,
				"dy": delta.y,
				"error_px": delta.length()
			})
	output["projections"] = projections
	return output

func _load_target_samples_for_projection() -> Array:
	# Reconstructing this list keeps output generation side-effect free while
	# preserving the same explicit route/world points used by _evaluate().
	return _samples_cache

func _samples_for_output(samples: Array) -> Array:
	var output := []
	for sample_value in samples:
		var sample: Dictionary = sample_value
		var target: Vector2 = sample["target"]
		output.append({
			"index": sample["index"],
			"side": sample["side"],
			"side_index": sample["side_index"],
			"s": sample["s"],
			"u": sample["u"],
			"target_px": [target.x, target.y],
			"holdout": sample["holdout"],
			"world": _vec3_array(sample["world"]) if sample.has("world") else null
		})
	return output

func _road_curve_for_output(_samples: Array) -> Array:
	var curve := []
	for curve_value in _edge_curve:
		var point: Dictionary = curve_value
		curve.append({"s": point["s"], "side": point["side"], "u": point["u"], "world": _vec3_array(point["world"])})
	return curve

func _vec3_array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func _float_range(minimum: float, maximum: float, step: float) -> Array:
	var values := []
	var safe_step := absf(step)
	if safe_step < 0.000001:
		safe_step = 1.0
	var value := minimum
	while value <= maximum + safe_step * 0.5:
		values.append(value)
		value += safe_step
	return values

func _candidate_sort(a: Dictionary, b: Dictionary) -> bool:
	return float(a["score"]) < float(b["score"])

func _candidate_key(candidate: Dictionary) -> String:
	var params: Dictionary = candidate["params"]
	return "%.3f/%.3f/%.3f/%.3f/%.3f" % [float(params["pitch_deg"]), float(params["yaw_deg"]), float(params["lateral_m"]), float(params["height_m"]), float(params["fov_deg"])]

func _format_metric(value: Variant) -> String:
	if value == null:
		return "n/a"
	return "%.2f" % float(value)

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES START CAMERA FIT: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES START CAMERA FIT PASS")
		quit(0)
	else:
		print("SAISIES START CAMERA FIT FAIL (%d errors)" % _errors.size())
		quit(1)
