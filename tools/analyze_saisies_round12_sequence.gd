extends SceneTree

## Route-only S09 continuous-sequence diagnostic for R12.
##
## The three station tracks are visual, speed-prior probes.  They deliberately
## do not rewrite the geo scene map, camera pose file, route data, or scenery.
## The route is built through the same SaisiesGeoRoute API used by the native
## capture, while the road and all scenery meshes are omitted.

const ROUTE_SCRIPT_PATH := "res://scripts/saisies_geo_route.gd"
const ROUTE_FILE := "res://data/saisies_geo_route.json"
const DEFAULT_OUTPUT_DIR := "res://export/saisies/review/round12_analysis"
const R11_SOURCE_MANIFEST := "res://export/saisies/review/round11_analysis/s09_source/source_manifest.json"
const R11_TIMING_AUDIT := "res://export/saisies/review/round11_analysis/timing_audit/timing_audit.json"
const R11_T334_PROBE := "res://export/saisies/review/round11_analysis/timing_audit/t334_position_probe.json"
const DOC_R12 := "res://docs/saisies_revision_round12.md"
const DOC_R11 := "res://docs/saisies_revision_round11.md"

const CAPTURE_SIZE := Vector2i(1920, 1080)
const FOV_DEG := 78.0
const CAMERA_HEIGHT_M := 1.65
const CAMERA_LATERAL_M := -2.0
const CAMERA_PITCH_DEG := -8.0
const CAMERA_YAW_DEG := -4.0
const ROLL_TURN_LOOKAHEAD_M := 12.0
const LOCAL_PROFILE_STEP_M := 2
const LOCAL_PROFILE_MAX_OFFSET_M := 100
const PROJECTION_OFFSETS_M := [3.0, 6.0, 12.0, 20.0, 40.0, 60.0, 80.0, 100.0]
const TIMES_S := [326.0, 330.0, 334.0, 338.0, 342.0, 346.0]
const CENTER_STATIONS_M := [5274.916403, 5352.116403, 5427.116403, 5497.116403, 5550.449736, 5587.116403]
const CANDIDATE_OFFSETS_M := {"A_center": 0.0, "B_minus25m": -25.0, "C_plus25m": 25.0}
const CANDIDATE_IDS := ["A_center", "B_minus25m", "C_plus25m"]
const T326_BACKWARD_EXTENSION_M := 77.2

class RouteOnly extends SaisiesGeoRoute:
	func _ready() -> void:
		# The analysis needs route samples only.  Native capture owns the road mesh.
		pass

var _route: SaisiesGeoRoute
var _output_dir := DEFAULT_OUTPUT_DIR
var _route_file := ROUTE_FILE
var _errors: Array[String] = []
var _source_manifest: Dictionary = {}
var _timing_audit: Dictionary = {}
var _t334_probe: Dictionary = {}

func _initialize() -> void:
	_parse_args()
	call_deferred("_run")

func _run() -> void:
	if not _load_route():
		_finish()
		return
	_load_source_inputs()
	if not _errors.is_empty():
		_finish()
		return
	var output := _build_output()
	_write_json(_output_dir.path_join("round12_sequence_analysis.json"), output)
	_write_markdown(_output_dir.path_join("round12_sequence_analysis.md"), output)
	_print_summary(output)
	_finish()

func _parse_args() -> void:
	for arg in _all_cmdline_args():
		var value := String(arg)
		if value.begins_with("--output-dir="):
			_output_dir = value.substr("--output-dir=".length())
		elif value.begins_with("--route-file="):
			_route_file = value.substr("--route-file=".length())

func _all_cmdline_args() -> PackedStringArray:
	var args := PackedStringArray()
	args.append_array(OS.get_cmdline_args())
	args.append_array(OS.get_cmdline_user_args())
	return args

func _load_route() -> bool:
	if not FileAccess.file_exists(_global_path(_route_file)):
		_fail("route file is missing: %s" % _route_file)
		return false
	if load(ROUTE_SCRIPT_PATH) == null:
		_fail("route script could not load: %s" % ROUTE_SCRIPT_PATH)
		return false
	var route := RouteOnly.new()
	route.name = "SaisiesRound12SequenceRoute"
	route.route_file = _route_file
	route.geo_route_file = _route_file
	# Match the production geographic route loader/sample path without entering
	# SaisiesGeoRoute._ready(), which would create road geometry for this probe.
	route._load_route_data()
	route._build_samples()
	route._build_curve()
	_route = route
	get_root().add_child(route)
	if not _route.geography_ready or _route._samples.size() < 2:
		_fail("route-only geographic samples did not become ready")
		return false
	print("round12 route ready length=%.3f sample_spacing=%.6f datum=%.6f" % [_route.length_m, _route.sample_spacing_m, float(_route.frame().get("datum_m", 0.0))])
	return true

func _load_source_inputs() -> void:
	_source_manifest = _load_json_input(R11_SOURCE_MANIFEST)
	_timing_audit = _load_json_input(R11_TIMING_AUDIT)
	_t334_probe = _load_json_input(R11_T334_PROBE)

func _load_json_input(path: String) -> Dictionary:
	var global_path := _global_path(path)
	if not FileAccess.file_exists(global_path):
		_fail("analysis input is missing: %s" % path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(global_path))
	if not (parsed is Dictionary):
		_fail("analysis input is not a JSON object: %s" % path)
		return {}
	return parsed.duplicate(true)

func _build_output() -> Dictionary:
	var candidates: Array = []
	for candidate_id in CANDIDATE_IDS:
		candidates.append(_build_candidate(String(candidate_id), float(CANDIDATE_OFFSETS_M[candidate_id])))
	var center_times: Array = []
	for index in TIMES_S.size():
		center_times.append({
			"time_s": TIMES_S[index],
			"requested_center_station_m": CENTER_STATIONS_M[index],
			"source_330_backward_extension_m": T326_BACKWARD_EXTENSION_M if index == 0 else null
		})
	var source_manifest_path := R11_SOURCE_MANIFEST
	var timing_path := R11_TIMING_AUDIT
	var t334_path := R11_T334_PROBE
	return {
		"schema_version": 1,
		"id": "saisies_round12_s09_sequence_candidates",
		"status": "diagnostic_only_ready_hold",
		"scope": "route-only-native-gray-probe",
		"estimated": true,
		"visual_acceptance": "pending root native GPU review",
		"note": "A/B/C are coherent speed-prior visual probes, not telemetry calibration, GPS, source pixel registration, or production anchors. Source physical stations remain unknown.",
		"production_change": {
			"route_map_changed": false,
			"camera_pose_data_changed": false,
			"terrain_changed": false,
			"forest_changed": false,
			"full_scene_loaded": false,
			"gpu_render_requested": false
		},
		"route": {
			"script": ROUTE_SCRIPT_PATH,
			"file": _route_file,
			"length_m": _route.length_m,
			"sample_spacing_m": _route.sample_spacing_m,
			"geography_frame": _route.frame(),
			"api_methods": ["pos_at", "tangent_at", "left_at", "ground_y", "road_width_at", "grade_at"],
			"world_convention": "local +X is ENU right, local -Z is route forward; positive heading delta is left"
		},
		"camera_probe": {
			"resolution_px": [CAPTURE_SIZE.x, CAPTURE_SIZE.y],
			"fov_deg": FOV_DEG,
			"height_m": CAMERA_HEIGHT_M,
			"lateral_m": CAMERA_LATERAL_M,
			"pitch_deg": CAMERA_PITCH_DEG,
			"yaw_deg": CAMERA_YAW_DEG,
			"roll_rule": "clampf(-turn_delta_deg(heading(s), heading(s+12m))*2.2, -5, +5)",
			"projection_rule": "pinhole depth=-camera_local.z; focal_y=(height_px/2)/tan(FOV/2); px=cx+focal_y*x/depth; py=cy-focal_y*y/depth",
			"temporary_pose_override": "capture sets an in-memory S09 pose to lateral=-2m, pitch=-8deg, yaw=-4deg; no global pose file is changed"
		},
		"time_station_table": center_times,
		"candidates": candidates,
		"r11_inputs": {
			"source_manifest": _input_record(source_manifest_path, _source_manifest),
			"timing_audit_corrected": _input_record(timing_path, _timing_audit),
			"t334_position_probe_corrected": _input_record(t334_path, _t334_probe),
			"source_manifest_sha256_expected": "f246369f5a62610f7a0b683dd0e1ff99433370d4c23b6c399716b77fd6cf8805",
			"source_manifest_sha256_actual": _sha256_file(source_manifest_path),
			"timing_audit_sha256_actual": _sha256_file(timing_path),
			"t334_position_probe_sha256_actual": _sha256_file(t334_path),
			"round11_docs": [DOC_R11, DOC_R12],
			"corrected_t334_context": _corrected_t334_context()
		},
		"source_references": _source_references(),
		"commands": {
			"analysis": "godot --headless --path . --script res://tools/analyze_saisies_round12_sequence.gd -- --output-dir=res://export/saisies/review/round12_analysis",
			"native_capture": "godot --path . --script res://tools/capture_saisies_round12_sequence.gd -- --output-dir=res://export/saisies/review/round12_analysis/native_sequence"
		},
		"generated_by": "tools/analyze_saisies_round12_sequence.gd"
	}

func _build_candidate(candidate_id: String, offset_m: float) -> Dictionary:
	var sequence: Array = []
	for index in TIMES_S.size():
		var requested := float(CENTER_STATIONS_M[index]) + offset_m
		var actual := clampf(requested, 0.0, _route.length_m)
		sequence.append(_station_detail(candidate_id, TIMES_S[index], requested, actual, offset_m))
	var intervals: Array = []
	for index in range(1, sequence.size()):
		var before: Dictionary = sequence[index - 1]
		var after: Dictionary = sequence[index]
		var dt := float(after["time_s"]) - float(before["time_s"])
		var ds := float(after["actual_station_m"]) - float(before["actual_station_m"])
		intervals.append({
			"from_time_s": before["time_s"],
			"to_time_s": after["time_s"],
			"distance_delta_m": ds,
			"time_delta_s": dt,
			"implied_speed_kmh": ds / maxf(dt, 0.001) * 3.6
		})
	var monotonic := true
	for index in range(1, sequence.size()):
		if float(sequence[index]["actual_station_m"]) <= float(sequence[index - 1]["actual_station_m"]):
			monotonic = false
	return {
		"id": candidate_id,
		"offset_from_center_m": offset_m,
		"station_role": "visual speed-prior sequence probe",
		"station_source": "R12 requested candidate; not source-registered",
		"monotonic": monotonic,
		"sequence": sequence,
		"intervals": intervals,
		"interval_speed_note": "Implied speeds are a plausibility prior only; do not use them to recalibrate route timing."
	}

func _station_detail(candidate_id: String, time_s: float, requested_station: float, actual_station: float, candidate_offset: float) -> Dictionary:
	var center: Vector3 = _route.pos_at(actual_station)
	var tangent: Vector3 = _route.tangent_at(actual_station)
	var left: Vector3 = _route.left_at(actual_station)
	var heading_deg := _heading_deg_from_tangent(tangent)
	var heading_plus12_deg := _heading_deg(actual_station + ROLL_TURN_LOOKAHEAD_M)
	var turn_plus12_deg := _angle_delta_deg(heading_deg, heading_plus12_deg)
	var roll_deg := clampf(-turn_plus12_deg * 2.2, -5.0, 5.0)
	var camera_position := center + left * CAMERA_LATERAL_M
	camera_position.y = _route.ground_y(actual_station, CAMERA_LATERAL_M) + 0.02 + CAMERA_HEIGHT_M
	var camera_heading_deg := heading_deg + CAMERA_YAW_DEG
	var camera_transform := Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(CAMERA_PITCH_DEG), deg_to_rad(camera_heading_deg), deg_to_rad(roll_deg))),
		camera_position
	)
	var forward := (-camera_transform.basis.z).normalized()
	return {
		"candidate_id": candidate_id,
		"time_s": time_s,
		"requested_station_m": requested_station,
		"actual_station_m": actual_station,
		"station_clamped": absf(actual_station - requested_station) > 0.0001,
		"candidate_offset_m": candidate_offset,
		"center_xyz": _vector_for(center),
		"camera_position_xyz": _vector_for(camera_position),
		"tangent_xyz": _vector_for(tangent),
		"left_xyz": _vector_for(left),
		"heading_deg": heading_deg,
		"heading_plus12_deg": heading_plus12_deg,
		"turn_plus12_deg": turn_plus12_deg,
		"roll_deg": roll_deg,
		"camera_heading_deg": camera_heading_deg,
		"camera_forward_xyz": _vector_for(forward),
		"road_width_m": _route.road_width_at(actual_station),
		"grade_pct": _route.grade_at(actual_station),
		"road_asl_m": center.y + float(_route.frame().get("datum_m", 0.0)),
		"local_2m_accumulating_angle_profile": _local_angle_profile(actual_station, heading_deg),
		"projected_centerline": _project_centerline(actual_station, camera_transform)
	}

func _local_angle_profile(base_station: float, base_heading_deg: float) -> Array:
	var result: Array = []
	var previous_heading := base_heading_deg
	var accumulated_delta := 0.0
	for offset_i in range(0, LOCAL_PROFILE_MAX_OFFSET_M + 1, LOCAL_PROFILE_STEP_M):
		var offset := float(offset_i)
		var station := clampf(base_station + offset, 0.0, _route.length_m)
		var heading := _heading_deg(station)
		var delta := 0.0 if offset_i == 0 else _angle_delta_deg(previous_heading, heading)
		if offset_i > 0:
			accumulated_delta += delta
		result.append({
			"offset_m": offset,
			"station_m": station,
			"heading_deg": heading,
			"delta_from_previous_2m_deg": delta,
			"accumulated_delta_deg": accumulated_delta,
			"direct_delta_from_base_deg": _angle_delta_deg(base_heading_deg, heading),
			"tangent_xyz": _vector_for(_route.tangent_at(station))
		})
		previous_heading = heading
	return result

func _project_centerline(base_station: float, camera_transform: Transform3D) -> Array:
	var result: Array = []
	var inverse := camera_transform.affine_inverse()
	var focal := float(CAPTURE_SIZE.y) * 0.5 / tan(deg_to_rad(FOV_DEG) * 0.5)
	for offset_value in PROJECTION_OFFSETS_M:
		var offset := float(offset_value)
		var station := clampf(base_station + offset, 0.0, _route.length_m)
		var world: Vector3 = _route.pos_at(station)
		var local: Vector3 = inverse * world
		var depth := -local.z
		var valid := depth > 0.0001 and is_finite(depth)
		var projection: Dictionary = {
			"offset_m": offset,
			"station_m": station,
			"world_xyz": _vector_for(world),
			"camera_local_xyz": _vector_for(local),
			"depth_m": depth,
			"valid_front": valid,
			"norm_x": null,
			"norm_y": null,
			"pixel": null
		}
		if valid:
			var norm_x := local.x / depth
			var norm_y := local.y / depth
			projection["norm_x"] = norm_x
			projection["norm_y"] = norm_y
			projection["pixel"] = [float(CAPTURE_SIZE.x) * 0.5 + focal * norm_x, float(CAPTURE_SIZE.y) * 0.5 - focal * norm_y]
		result.append(projection)
	return result

func _source_references() -> Array:
	var result: Array = []
	for item in _source_manifest.get("frames", []):
		if not (item is Dictionary):
			continue
		var frame: Dictionary = item
		result.append({
			"requested_time_s": frame.get("requested_time_s", null),
			"frame_index": frame.get("frame_index", frame.get("frame_index_zero_based", null)),
			"actual_pts": frame.get("actual_pts", frame.get("decoded_pts", null)),
			"actual_pts_time_s": frame.get("actual_pts_time_s", frame.get("decoded_pts_time_s", null)),
			"time_base": frame.get("time_base", "1/24000"),
			"width": frame.get("width", frame.get("decoded_width", null)),
			"height": frame.get("height", frame.get("decoded_height", null)),
			"raw_reference_path": frame.get("file", null),
			"raw_reference_sha256": frame.get("sha256", null)
		})
	return result

func _input_record(path: String, payload: Dictionary) -> Dictionary:
	return {
		"path": path,
		"sha256": _sha256_file(path),
		"schema_version": payload.get("schema_version", null),
		"status": payload.get("status", null)
	}

func _corrected_t334_context() -> Dictionary:
	var runtime: Dictionary = _t334_probe.get("runtime_route", {})
	var audit_route: Dictionary = _timing_audit.get("route_sequence_5200_5700m", {})
	var unwrapped: Dictionary = audit_route.get("unwrapped_heading_audit", {})
	var station_pair: Dictionary = _t334_probe.get("station_pair_probe", {})
	return {
		"t334_base_station_m": runtime.get("base_station_m", null),
		"t334_base_heading_deg": runtime.get("base_heading_deg", null),
		"t334_local_heading_delta_deg": runtime.get("heading_plus12_delta_deg", null),
		"t334_angle_wrap_crossing": unwrapped.get("crossed_180_deg", null),
		"t334_unwrapped_heading_conclusion": unwrapped.get("conclusion", null),
		"t334_station_pair_proposal": station_pair.get("proposal", null),
		"warning": "The corrected R11 audit says the near-field T334 left bend and the farther return-leg raw sign are different semantics; 5605..5618 m are not adopted as a source338 true-left registration."
	}

func _heading_deg(station: float) -> float:
	return _heading_deg_from_tangent(_route.tangent_at(clampf(station, 0.0, _route.length_m)))

func _heading_deg_from_tangent(tangent: Vector3) -> float:
	return rad_to_deg(atan2(-tangent.x, -tangent.z))

func _angle_delta_deg(from_heading: float, to_heading: float) -> float:
	return rad_to_deg(wrapf(deg_to_rad(to_heading - from_heading) + PI, 0.0, TAU) - PI)

func _vector_for(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}

func _write_markdown(path: String, output: Dictionary) -> void:
	var lines := PackedStringArray()
	lines.append("# Saisies R12 S09 continuous sequence candidates")
	lines.append("")
	lines.append("Status: READY/HOLD for root native GPU review. A/B/C are route-only speed-prior visual probes; no candidate is a calibrated source station or production anchor.")
	lines.append("")
	lines.append("Fixed native probe: 1920x1080, FOV %.1f°, height %.2f m, lateral %.2f m, pitch %.1f°, yaw %.1f°. Roll follows the actual route heading change over the next 12 m." % [FOV_DEG, CAMERA_HEIGHT_M, CAMERA_LATERAL_M, CAMERA_PITCH_DEG, CAMERA_YAW_DEG])
	lines.append("")
	lines.append("The 326 s center station extends the 330 s candidate backward by %.1f m to %.6f m. The remaining center stations are the requested [5352.116403, 5427.116403, 5497.116403, 5550.449736, 5587.116403] m." % [T326_BACKWARD_EXTENSION_M, CENTER_STATIONS_M[0]])
	lines.append("")
	lines.append("## Candidate station and speed tracks")
	lines.append("")
	lines.append("| candidate | offset m | stations at 326/330/334/338/342/346 m | implied interval km/h (326–330, 330–334, 334–338, 338–342, 342–346) | monotonic |")
	lines.append("|---|---:|---|---|---|")
	for candidate in output["candidates"]:
		var stations := PackedStringArray()
		for item in candidate["sequence"]:
			stations.append("%.3f" % float(item["actual_station_m"]))
		var speeds := PackedStringArray()
		for interval in candidate["intervals"]:
			speeds.append("%.1f" % float(interval["implied_speed_kmh"]))
		lines.append("| %s | %.1f | %s | %s | %s |" % [String(candidate["id"]), float(candidate["offset_from_center_m"]), ", ".join(stations), ", ".join(speeds), str(candidate["monotonic"])])
	lines.append("")
	lines.append("## Actual route heading, camera forward, roll and centerline projection")
	lines.append("")
	lines.append("The JSON records the complete 2 m accumulating heading profile and camera-space projection at +3/+6/+12/+20/+40/+60/+80/+100 m. `px@...` below is the horizontal centerline pixel only; depth and vertical pixel are retained in JSON.")
	lines.append("")
	lines.append("| candidate | time s | actual station m | route heading° | turn +12° | roll° | camera forward xyz | px@3/6/12/20/40/60/80/100 |")
	lines.append("|---|---:|---:|---:|---:|---:|---|---|")
	for candidate in output["candidates"]:
		for item in candidate["sequence"]:
			var pixels := PackedStringArray()
			for projection in item["projected_centerline"]:
				var pixel = projection.get("pixel", null)
				pixels.append("n/a" if pixel == null else "%.1f" % float(pixel[0]))
			var forward: Dictionary = item["camera_forward_xyz"]
			lines.append("| %s | %.0f | %.3f | %.3f | %.3f | %.3f | (%.3f, %.3f, %.3f) | %s |" % [String(candidate["id"]), float(item["time_s"]), float(item["actual_station_m"]), float(item["heading_deg"]), float(item["turn_plus12_deg"]), float(item["roll_deg"]), float(forward["x"]), float(forward["y"]), float(forward["z"]), ", ".join(pixels)])
	lines.append("")
	lines.append("## R11 source evidence")
	lines.append("")
	lines.append("Raw source paths, PTS values, dimensions and SHA256 values are copied into `source_references` in the JSON from `%s`. Related corrected R11 inputs are recorded with their hashes." % R11_SOURCE_MANIFEST)
	lines.append("")
	lines.append("| requested s | frame | actual PTS | PTS s | SHA256 | raw path |")
	lines.append("|---:|---:|---:|---:|---|---|")
	for reference in output["source_references"]:
		lines.append("| %.3f | %s | %s | %s | `%s` | `%s` |" % [float(reference.get("requested_time_s", 0.0)), str(reference.get("frame_index", "")), str(reference.get("actual_pts", "")), str(reference.get("actual_pts_time_s", "")), str(reference.get("raw_reference_sha256", "")), str(reference.get("raw_reference_path", ""))])
	lines.append("")
	lines.append("## Native capture")
	lines.append("")
	lines.append("Run on the native GPU after freezing this tool pair:")
	lines.append("")
	lines.append("`%s`" % output["commands"]["native_capture"])
	lines.append("")
	lines.append("The capture removes every top-level child before scene readiness except `Route`, `CameraRig`, `WorldEnvironment`, and `Sun`; `Route` creates the road. It sets an in-memory S09 pose override and writes A_T326…A_T346, B_T326…B_T346, and C_T326…C_T346 PNGs plus a capture manifest.")
	lines.append("")
	lines.append("Generated by `tools/analyze_saisies_round12_sequence.gd`; production route/map/camera/terrain/forest files were not modified.")
	_write_text(path, "\n".join(lines) + "\n")

func _print_summary(output: Dictionary) -> void:
	for candidate in output["candidates"]:
		var first: Dictionary = candidate["sequence"].front()
		var last: Dictionary = candidate["sequence"].back()
		print("round12 %s stations=%.3f..%.3f heading326=%.3f heading346=%.3f monotonic=%s" % [String(candidate["id"]), float(first["actual_station_m"]), float(last["actual_station_m"]), float(first["heading_deg"]), float(last["heading_deg"]), str(candidate["monotonic"])])
	print("round12 outputs json=%s markdown=%s" % [_output_dir.path_join("round12_sequence_analysis.json"), _output_dir.path_join("round12_sequence_analysis.md")])

func _sha256_file(path: String) -> String:
	var file := FileAccess.open(_global_path(path), FileAccess.READ)
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

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES R12 SEQUENCE: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES R12 SEQUENCE READY/HOLD")
		quit(0)
	else:
		for error in _errors:
			print("SAISIES R12 SEQUENCE ERROR: " + error)
		quit(1)
