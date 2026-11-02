extends Node3D

## Route-only S04 bend probe.
##
## This scene deliberately loads only SaisiesGeoRoute and a small grey road
## ribbon. It is a diagnostic instrument for separating route shape from
## camera/time/forest differences before any production scene is changed.

@export var route_path: NodePath = NodePath("Route")
@export var camera_path: NodePath = NodePath("CameraRig/Camera3D")
@export var diagnostic_from_m := 1000.0
@export var diagnostic_to_m := 2600.0
@export var sample_step_m := 10.0
@export var curvature_delta_m := 5.0
@export var road_from_m := 800.0
@export var road_to_m := 2800.0

const SOURCE_FRAME := "S04 route-only diagnostic; source sequence supplied by root"
const TURN_CURVATURE_THRESHOLD := 0.00045
const FIXED_FOV_DEG := 77.0

var _route: Node
var _camera: Camera3D
var _camera_rig: Node3D
var _station := 1826.88599
var _fov := FIXED_FOV_DEG
var _yaw_deg := 0.0
var _pitch_deg := -8.0
var _lateral := 0.0
var _camera_distance := 0.0
var _camera_height := 1.67
var _look_ahead := 30.0
var _step_override := 0.0
var _diagnostic_path := "/private/tmp/saisies_s04_route_diagnostic.json"
var _capture_path := ""
var _headless_check := false
var _quit_after_capture := false
var _candidate_file := "res://data/saisies_s04_bend_candidate.json"
var _requested_video_seconds := NAN
var _pose_mode := "station"
var _candidate_data: Dictionary = {}
var _candidate_anchors: Array = []
var _candidate_segment_speeds: Array[float] = []
var _ready_published := false

func _ready() -> void:
	_parse_args()
	call_deferred("_build_probe")

func _build_probe() -> void:
	_route = get_node_or_null(route_path)
	_camera = get_node_or_null(camera_path) as Camera3D
	if _camera_rig == null and _camera != null:
		_camera_rig = _camera.get_parent() as Node3D
	if _route == null or _camera == null or not _route.has_method("pos_at") or not _route.has_method("tangent_at") or not _route.has_method("left_at"):
		_retry("S04 bend probe requires GeoRoute and Camera3D")
		return
	if not bool(_route.get("geography_ready")):
		_retry("S04 bend probe is waiting for GeoRoute geography")
		return
	if not _load_candidate_data():
		return
	_resolve_video_station()
	_build_grey_road()
	_write_route_diagnostic()
	_apply_camera_pose()
	set_meta("saisies_s04_bend_probe_ready", true)
	set_meta("saisies_s04_bend_probe_route_only", true)
	set_meta("saisies_s04_bend_probe_station_range_m", Vector2(diagnostic_from_m, diagnostic_to_m))
	set_meta("saisies_s04_bend_probe_sample_step_m", _step_override if _step_override > 0.0 else sample_step_m)
	set_meta("saisies_s04_bend_probe_pose", {"mode": _pose_mode, "station_m": _station, "video_seconds": _video_seconds_or_null(), "fov_deg": _fov, "yaw_deg": _yaw_deg, "pitch_deg": _pitch_deg, "lateral_m": _lateral})
	set_meta("saisies_s04_bend_probe_pose_mode", _pose_mode)
	set_meta("saisies_s04_bend_probe_actual_station_m", _station)
	set_meta("saisies_s04_bend_probe_candidate_file", _candidate_file)
	set_meta("saisies_s04_bend_probe_candidate_status", String(_candidate_data.get("status", "")))
	set_meta("saisies_s04_bend_probe_candidate_visual_acceptance", bool(_candidate_data.get("visual_acceptance", false)))
	set_meta("saisies_s04_bend_probe_candidate_formal_integration_allowed", bool(_candidate_data.get("formal_integration_allowed", false)))
	set_meta("saisies_s04_bend_probe_candidate_unvalidated", bool(_candidate_data.get("not_validated", true)))
	set_meta("saisies_s04_bend_probe_candidate_anchor_count", _candidate_anchors.size())
	set_meta("saisies_s04_bend_probe_candidate_segment_speeds_mps", _candidate_segment_speeds)
	_ready_published = true
	print("S04 BEND PROBE READY mode=", _pose_mode, " station=", _station, " range=", diagnostic_from_m, "..", diagnostic_to_m, " step=", _step_override if _step_override > 0.0 else sample_step_m)
	if _headless_check:
		get_tree().quit(0)
		return
	if not _capture_path.is_empty():
		_capture_after_frames()

func _retry(message: String) -> void:
	var attempts := int(get_meta("saisies_s04_bend_probe_attempts", 0)) + 1
	set_meta("saisies_s04_bend_probe_attempts", attempts)
	if attempts < 240:
		call_deferred("_retry_next_frame")
		return
	set_meta("saisies_s04_bend_probe_error", message)
	push_error(message)

func _retry_next_frame() -> void:
	await get_tree().process_frame
	_build_probe()

func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--station="): _station = float(arg.substr(10))
		elif arg.begins_with("--fov="): _fov = float(arg.substr(6))
		elif arg.begins_with("--yaw="): _yaw_deg = float(arg.substr(6))
		elif arg.begins_with("--pitch="): _pitch_deg = float(arg.substr(8))
		elif arg.begins_with("--lateral="): _lateral = float(arg.substr(10))
		elif arg.begins_with("--distance="): _camera_distance = float(arg.substr(11))
		elif arg.begins_with("--height="): _camera_height = float(arg.substr(9))
		elif arg.begins_with("--look-ahead="): _look_ahead = float(arg.substr(13))
		elif arg.begins_with("--step="): _step_override = float(arg.substr(7))
		elif arg.begins_with("--diagnostic-out="): _diagnostic_path = arg.substr(17)
		elif arg.begins_with("--capture="): _capture_path = arg.substr(10)
		elif arg.begins_with("--video-seconds="): _requested_video_seconds = float(arg.substr(16))
		elif arg.begins_with("--candidate-file="): _candidate_file = arg.substr(17)
		elif arg == "--quit-after-capture": _quit_after_capture = true
		elif arg == "--headless-check": _headless_check = true

func _load_candidate_data() -> bool:
	var file := FileAccess.open(_candidate_file, FileAccess.READ)
	if file == null:
		return _candidate_error("S04 bend probe candidate file could not be opened: %s" % _candidate_file)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return _candidate_error("S04 bend probe candidate must be a JSON object")
	_candidate_data = parsed as Dictionary
	if String(_candidate_data.get("kind", "")) != "saisies_s04_bend_time_phase_candidate":
		return _candidate_error("S04 bend probe candidate kind is not diagnostic-only time phase data")
	if String(_candidate_data.get("status", "")) != "diagnostic_only":
		return _candidate_error("S04 bend probe candidate status must be diagnostic_only")
	if bool(_candidate_data.get("visual_acceptance", true)) or bool(_candidate_data.get("formal_integration_allowed", true)):
		return _candidate_error("S04 bend probe candidate is marked for integration or visual acceptance")
	if not bool(_candidate_data.get("not_validated", false)):
		return _candidate_error("S04 bend probe candidate must remain explicitly unvalidated")
	var anchors_variant: Variant = _candidate_data.get("anchors", [])
	if typeof(anchors_variant) != TYPE_ARRAY:
		return _candidate_error("S04 bend probe candidate anchors must be an array")
	_candidate_anchors = []
	_candidate_segment_speeds = []
	for raw_anchor in anchors_variant as Array:
		if typeof(raw_anchor) != TYPE_DICTIONARY:
			return _candidate_error("S04 bend probe candidate anchor is not an object")
		var anchor: Dictionary = raw_anchor as Dictionary
		var video_seconds_variant: Variant = anchor.get("video_seconds", NAN)
		var station_variant: Variant = anchor.get("station_m", NAN)
		if typeof(video_seconds_variant) not in [TYPE_INT, TYPE_FLOAT] or typeof(station_variant) not in [TYPE_INT, TYPE_FLOAT]:
			return _candidate_error("S04 bend probe candidate anchors require numeric video_seconds and station_m")
		var video_seconds := float(video_seconds_variant)
		var station := float(station_variant)
		if not is_finite(video_seconds) or not is_finite(station):
			return _candidate_error("S04 bend probe candidate anchors must be finite")
		_candidate_anchors.append({"video_seconds": video_seconds, "station_m": station})
	if _candidate_anchors.size() < 2:
		return _candidate_error("S04 bend probe candidate needs at least two anchors")
	var first: Dictionary = _candidate_anchors[0]
	var last: Dictionary = _candidate_anchors[_candidate_anchors.size() - 1]
	if absf(float(first["video_seconds"]) - 75.0) > 0.001 or absf(float(first["station_m"]) - 930.0) > 0.001:
		return _candidate_error("S04 bend probe candidate must preserve the 75s/930m endpoint")
	if absf(float(last["video_seconds"]) - 180.0) > 0.001 or absf(float(last["station_m"]) - 2800.0) > 0.001:
		return _candidate_error("S04 bend probe candidate must preserve the 180s/2800m endpoint")
	for index in range(1, _candidate_anchors.size()):
		var previous: Dictionary = _candidate_anchors[index - 1]
		var current: Dictionary = _candidate_anchors[index]
		var delta_seconds := float(current["video_seconds"]) - float(previous["video_seconds"])
		var delta_station := float(current["station_m"]) - float(previous["station_m"])
		if delta_seconds <= 0.0 or delta_station <= 0.0:
			return _candidate_error("S04 bend probe candidate anchors must be strictly monotonic")
		var speed := delta_station / delta_seconds
		if speed < 12.0 - 0.001 or speed > 28.0 + 0.001:
			return _candidate_error("S04 bend probe candidate segment speed is outside the diagnostic 12..28 m/s range")
		_candidate_segment_speeds.append(speed)
	set_meta("saisies_s04_bend_probe_candidate_valid", true)
	return true

func _candidate_error(message: String) -> bool:
	set_meta("saisies_s04_bend_probe_error", message)
	push_error(message)
	if _headless_check:
		get_tree().quit(1)
	return false

func _resolve_video_station() -> void:
	_pose_mode = "station"
	if not is_finite(_requested_video_seconds):
		return
	_pose_mode = "video_seconds_candidate"
	var requested := _requested_video_seconds
	var first: Dictionary = _candidate_anchors[0]
	var last: Dictionary = _candidate_anchors[_candidate_anchors.size() - 1]
	if requested <= float(first["video_seconds"]):
		_station = float(first["station_m"])
		return
	if requested >= float(last["video_seconds"]):
		_station = float(last["station_m"])
		return
	for index in range(1, _candidate_anchors.size()):
		var previous: Dictionary = _candidate_anchors[index - 1]
		var current: Dictionary = _candidate_anchors[index]
		if requested <= float(current["video_seconds"]):
			var span := float(current["video_seconds"]) - float(previous["video_seconds"])
			var ratio := (requested - float(previous["video_seconds"])) / span
			_station = lerpf(float(previous["station_m"]), float(current["station_m"]), ratio)
			return

func _video_seconds_or_null() -> Variant:
	if not is_finite(_requested_video_seconds):
		return null
	return _requested_video_seconds

func _build_grey_road() -> void:
	var road := _build_strip("BendProbeRoad", -1.0, 1.0, Color(0.32, 0.34, 0.34, 1.0), 0.02)
	if road != null:
		road.set_meta("saisies_s04_bend_probe_surface", "route centerline only")
	var left_shoulder := _build_strip("BendProbeLeftShoulder", -1.0, -1.7, Color(0.46, 0.47, 0.45, 1.0), 0.0)
	var right_shoulder := _build_strip("BendProbeRightShoulder", 1.0, 1.7, Color(0.46, 0.47, 0.45, 1.0), 0.0)
	if left_shoulder != null: left_shoulder.set_meta("saisies_s04_bend_probe_surface", "route shoulder grey")
	if right_shoulder != null: right_shoulder.set_meta("saisies_s04_bend_probe_surface", "route shoulder grey")

func _build_strip(node_name: String, inner_factor: float, outer_factor: float, color: Color, lift: float) -> MeshInstance3D:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := 5.0
	var s := road_from_m
	while s < road_to_m:
		var s1 := minf(s + step, road_to_m)
		var half0 := float(_route.call("road_width_at", s)) * 0.5
		var half1 := float(_route.call("road_width_at", s1)) * 0.5
		var p0 := Vector3(_route.call("pos_at", s))
		var p1 := Vector3(_route.call("pos_at", s1))
		var l0 := Vector3(_route.call("left_at", s))
		var l1 := Vector3(_route.call("left_at", s1))
		var a := p0 + l0 * half0 * inner_factor + Vector3.UP * lift
		var b := p0 + l0 * half0 * outer_factor + Vector3.UP * lift
		var c := p1 + l1 * half1 * outer_factor + Vector3.UP * lift
		var d := p1 + l1 * half1 * inner_factor + Vector3.UP * lift
		_add_quad(surface, a, b, c, d)
		s = s1
	surface.generate_normals()
	var mesh := surface.commit()
	if mesh == null:
		return null
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.96
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	instance.material_override = material
	add_child(instance)
	return instance

func _add_quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	surface.add_vertex(a)
	surface.add_vertex(b)
	surface.add_vertex(c)
	surface.add_vertex(a)
	surface.add_vertex(c)
	surface.add_vertex(d)

func _sample_record(station: float, delta: float) -> Dictionary:
	var position := Vector3(_route.call("pos_at", station))
	var tangent := Vector3(_route.call("tangent_at", station)).normalized()
	var left := Vector3(_route.call("left_at", station)).normalized()
	var future := Vector3(_route.call("tangent_at", minf(station + delta, diagnostic_to_m))).normalized()
	var future_dot_left := future.dot(left)
	var future_dot_tangent := future.dot(tangent)
	var signed_turn_rad := atan2(future_dot_left, future_dot_tangent)
	var curvature := signed_turn_rad / maxf(delta, 0.001)
	var radius := INF if absf(curvature) < 0.000001 else 1.0 / absf(curvature)
	var direction := "straight"
	if curvature > TURN_CURVATURE_THRESHOLD:
		direction = "left"
	elif curvature < -TURN_CURVATURE_THRESHOLD:
		direction = "right"
	return {
		"station_m": station,
		"position": _vec3_array(position),
		"tangent": _vec3_array(tangent),
		"left": _vec3_array(left),
		"future_tangent": _vec3_array(future),
		"future_tangent_dot_current_left": future_dot_left,
		"future_tangent_dot_current_tangent": future_dot_tangent,
		"signed_turn_rad_per_m": curvature,
		"signed_turn_deg_per_10m": rad_to_deg(curvature * 10.0),
		"radius_m": radius,
		"direction": direction,
		"heading_deg": rad_to_deg(atan2(tangent.x, -tangent.z)),
		"elevation_m": float(_route.call("elevation_at", station)) if _route.has_method("elevation_at") else position.y,
		"grade_pct": float(_route.call("grade_at", station)) if _route.has_method("grade_at") else 0.0,
		"road_width_m": float(_route.call("road_width_at", station)) if _route.has_method("road_width_at") else 6.4,
		"frame_tangent_left_dot": tangent.dot(left),
		"frame_tangent_cross_left_up_dot": tangent.cross(left).dot(Vector3.UP),
	}

func _write_route_diagnostic() -> void:
	var step := _step_override if _step_override > 0.0 else sample_step_m
	var records: Array = []
	var station := diagnostic_from_m
	var max_frame_error := 0.0
	var min_cross_up := INF
	while station <= diagnostic_to_m + 0.001:
		var record := _sample_record(minf(station, diagnostic_to_m), curvature_delta_m)
		records.append(record)
		max_frame_error = maxf(max_frame_error, absf(float(record["frame_tangent_left_dot"])))
		min_cross_up = minf(min_cross_up, float(record["frame_tangent_cross_left_up_dot"]))
		station += step
	var bends := _summarize_bends(records, step)
	var payload := {
		"schema_version": 1,
		"kind": "saisies_s04_route_only_bend_diagnostic",
		"source_frame": SOURCE_FRAME,
		"route_node": str(_route.get_path()),
		"route_file": String(_route.get("geo_route_file")),
		"station_range_m": [diagnostic_from_m, diagnostic_to_m],
		"sample_step_m": step,
		"curvature_delta_m": curvature_delta_m,
		"turn_threshold_rad_per_m": TURN_CURVATURE_THRESHOLD,
		"pose": {"mode": _pose_mode, "requested_video_seconds": _video_seconds_or_null(), "actual_station_m": _station, "fov_deg": _fov, "yaw_deg": _yaw_deg, "pitch_deg": _pitch_deg, "lateral_m": _lateral, "camera_distance_m": _camera_distance, "camera_height_m": _camera_height},
		"candidate": {"file": _candidate_file, "status": String(_candidate_data.get("status", "")), "visual_acceptance": bool(_candidate_data.get("visual_acceptance", false)), "formal_integration_allowed": bool(_candidate_data.get("formal_integration_allowed", false)), "not_validated": bool(_candidate_data.get("not_validated", true)), "anchor_count": _candidate_anchors.size(), "segment_speeds_mps": _candidate_segment_speeds},
		"frame_validation": {"max_abs_tangent_left_dot": max_frame_error, "min_tangent_cross_left_up_dot": min_cross_up, "future_tangent_dot_current_left_positive_is_left": true},
		"samples": records,
		"bends": bends,
		"turn_sequence": _turn_sequence(bends),
	}
	var output := _diagnostic_path
	if not output.begins_with("res://") and not output.begins_with("user://") and not output.begins_with("/"):
		output = "res://" + output
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		push_error("S04 bend probe could not write diagnostic: %s" % output)
		return
	file.store_string(JSON.stringify(payload, "  "))
	file.close()
	print("S04 route diagnostic written: ", output, " samples=", records.size(), " bends=", bends.size())
	for bend in bends:
		print("S04 bend ", bend["direction"], " ", bend["from_station_m"], "..", bend["to_station_m"], "m radius_min=", bend["minimum_radius_m"], " turn_deg=", bend["signed_turn_deg"])

func _summarize_bends(records: Array, step: float) -> Array:
	var result: Array = []
	var active: Dictionary = {}
	for record in records:
		var direction := String(record["direction"])
		if direction == "straight":
			if not active.is_empty():
				result.append(active)
				active = {}
			continue
		if active.is_empty() or String(active["direction"]) != direction:
			if not active.is_empty(): result.append(active)
			active = {"direction": direction, "from_station_m": float(record["station_m"]), "to_station_m": float(record["station_m"]), "minimum_radius_m": INF, "maximum_abs_curvature_rad_per_m": 0.0, "signed_turn_deg": 0.0, "sample_count": 0}
		active["to_station_m"] = float(record["station_m"])
		active["minimum_radius_m"] = minf(float(active["minimum_radius_m"]), float(record["radius_m"]))
		active["maximum_abs_curvature_rad_per_m"] = maxf(float(active["maximum_abs_curvature_rad_per_m"]), absf(float(record["signed_turn_rad_per_m"])))
		active["signed_turn_deg"] = float(active["signed_turn_deg"]) + rad_to_deg(float(record["signed_turn_rad_per_m"]) * step)
		active["sample_count"] = int(active["sample_count"]) + 1
	if not active.is_empty(): result.append(active)
	return result

func _turn_sequence(bends: Array) -> Array[String]:
	var result: Array[String] = []
	for bend in bends:
		result.append(String(bend["direction"]))
	return result

func _apply_camera_pose() -> void:
	if _camera == null or _route == null:
		return
	var center := Vector3(_route.call("pos_at", _station))
	var tangent := Vector3(_route.call("tangent_at", _station)).normalized()
	var left := Vector3(_route.call("left_at", _station)).normalized()
	var camera_position := center - tangent * _camera_distance + left * _lateral + Vector3.UP * _camera_height
	_camera.global_position = camera_position
	var yaw_basis := Basis(Vector3.UP, deg_to_rad(_yaw_deg))
	var view_direction := yaw_basis * tangent
	var pitch_offset := tan(deg_to_rad(_pitch_deg)) * _look_ahead
	_camera.look_at(camera_position + view_direction * _look_ahead + Vector3.UP * pitch_offset, Vector3.UP)
	_camera.fov = _fov
	_camera.current = true

func _capture_after_frames() -> void:
	for _frame in 4:
		await get_tree().process_frame
	RenderingServer.force_draw()
	var image := get_viewport().get_texture().get_image()
	if image == null:
		push_error("S04 bend probe capture has no viewport image")
		if _quit_after_capture:
			get_tree().quit(1)
		return
	var output := _capture_path
	if output.begins_with("res://"):
		output = ProjectSettings.globalize_path(output)
	var status := image.save_png(output)
	print("S04 bend probe capture: ", output, " ok=", status == OK)
	if _quit_after_capture:
		get_tree().quit(0 if status == OK else 1)

func _vec3_array(value: Vector3) -> Array[float]:
	return [value.x, value.y, value.z]
