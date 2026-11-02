class_name SaisiesCamera
extends Node3D

## Invisible route camera used for environment review. It keeps the scene free of
## a rider model while retaining deterministic --start-km and capture checkpoints.

@export var route_path: NodePath
@export var start_distance_m := 0.0
@export var cruise_speed_mps := 17.0
@export var camera_height := 1.65
@export var auto_advance := true

const ACCEPTANCE_SCENE_IDS := [
	"S01", "S02", "S03", "S04", "S05", "S06", "S07", "S08", "S09",
	"S10", "S11", "S12", "S13", "S14", "S15", "S16", "S17", "S18"
]
const DEFAULT_ACCEPTANCE_PITCH_DEG := -8.0

var route: SaisiesRoute
var distance_m := 0.0
var _camera: Camera3D
var _previous_heading := 0.0
var _requested_scene_id := ""
var _acceptance_cache_ready := false
var _acceptance_distances := PackedFloat32Array()
var _acceptance_pitches := PackedFloat32Array()
var _acceptance_yaws := PackedFloat32Array()
var _acceptance_laterals := PackedFloat32Array()
var _acceptance_pose_by_id: Dictionary = {}
var _acceptance_lateral_by_id: Dictionary = {}
var _scene_lateral_cache_ready := false

func _ready() -> void:
	route = get_node_or_null(route_path) as SaisiesRoute
	distance_m = start_distance_m
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--start-km="):
			distance_m = float(arg.substr(11)) * 1000.0
		elif arg.begins_with("--start-m="):
			distance_m = float(arg.substr(10))
		elif arg.begins_with("--scene-id="):
			_requested_scene_id = arg.substr(11).to_upper()
	_camera = get_node_or_null("Camera3D") as Camera3D
	if _camera:
		_camera.current = true
		_camera.position = Vector3(0.0, camera_height, 0.0)
	if route:
		if not _requested_scene_id.is_empty() and route.has_method("acceptance_distance"):
			distance_m = float(route.call("acceptance_distance", _requested_scene_id))
			auto_advance = false
		distance_m = clampf(distance_m, 0.0, route.length_m)
		_cache_acceptance_poses()
		_previous_heading = _heading_at(distance_m)
		_place()
		if not _requested_scene_id.is_empty():
			apply_acceptance_pose(_requested_scene_id)

func _process(delta: float) -> void:
	if route == null:
		return
	if auto_advance and distance_m < route.length_m:
		distance_m = minf(distance_m + cruise_speed_mps * delta, route.length_m)
	_place()

func _heading_at(s: float) -> float:
	var tangent := route.tangent_at(s)
	return atan2(-tangent.x, -tangent.z)

func _place() -> void:
	var tangent := route.tangent_at(distance_m)
	var lateral := _lateral_for_distance(distance_m)
	if not _requested_scene_id.is_empty():
		lateral = float(_acceptance_lateral_by_id.get(_requested_scene_id, lateral))
	global_position = route.pos_at(distance_m) + route.left_at(distance_m) * lateral
	global_position.y = route.ground_y(distance_m, lateral) + 0.02
	var heading := _heading_at(distance_m)
	var next_heading := _heading_at(minf(distance_m + 12.0, route.length_m))
	var turn := wrapf(next_heading - heading + PI, 0.0, TAU) - PI
	# Source-view poses are estimated visual offsets, not camera calibration or GPS.
	# Cache them once so normal traversal and fixed captures share the same authored
	# pitch/yaw without reading scene_map on every frame.
	var pose := _pose_for_distance(distance_m)
	if not _requested_scene_id.is_empty():
		pose = _acceptance_pose_by_id.get(_requested_scene_id, pose)
	rotation = Vector3(pose.x, heading + pose.y, clampf(-turn * 2.2, deg_to_rad(-5.0), deg_to_rad(5.0)))
	_previous_heading = heading

func _cache_acceptance_poses() -> void:
	if _acceptance_cache_ready or route == null:
		return
	_acceptance_cache_ready = true
	if not route.has_method("acceptance_distance") or not route.has_method("acceptance_pose"):
		return
	_load_scene_lateral_cache()
	var anchors: Array[Dictionary] = []
	for scene_id in ACCEPTANCE_SCENE_IDS:
		var pose: Dictionary = route.call("acceptance_pose", scene_id)
		anchors.append({
			"scene_id": scene_id,
			"distance_m": float(route.call("acceptance_distance", scene_id)),
			"pitch_deg": float(pose.get("pitch_deg", DEFAULT_ACCEPTANCE_PITCH_DEG)),
			"yaw_deg": float(pose.get("yaw_deg", 0.0)),
			"lateral_m": float(_acceptance_lateral_by_id.get(scene_id, 0.0))
		})
	anchors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance_m"]) < float(b["distance_m"])
	)
	for anchor in anchors:
		var scene_id := String(anchor["scene_id"])
		var pose := Vector2(
			deg_to_rad(float(anchor["pitch_deg"])),
			deg_to_rad(float(anchor["yaw_deg"]))
		)
		_acceptance_distances.append(float(anchor["distance_m"]))
		_acceptance_pitches.append(pose.x)
		_acceptance_yaws.append(pose.y)
		_acceptance_laterals.append(float(anchor["lateral_m"]))
		_acceptance_pose_by_id[scene_id] = pose
		_acceptance_lateral_by_id[scene_id] = float(anchor["lateral_m"])

func _load_scene_lateral_cache() -> void:
	if _scene_lateral_cache_ready:
		return
	_scene_lateral_cache_ready = true
	var scene_map_file := "res://data/saisies_scene_map.json"
	if not FileAccess.file_exists(scene_map_file):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(scene_map_file))
	if not (parsed is Dictionary):
		return
	for item in parsed.get("scenes", []):
		if item is Dictionary and item.has("acceptance_lateral_m"):
			_acceptance_lateral_by_id[String(item.get("scene_id", ""))] = float(item.get("acceptance_lateral_m", 0.0))

func _pose_for_distance(distance: float) -> Vector2:
	if _acceptance_distances.is_empty():
		return Vector2(deg_to_rad(DEFAULT_ACCEPTANCE_PITCH_DEG), 0.0)
	if distance <= _acceptance_distances[0]:
		return Vector2(_acceptance_pitches[0], _acceptance_yaws[0])
	for i in range(_acceptance_distances.size() - 1):
		var next_distance := _acceptance_distances[i + 1]
		if distance <= next_distance:
			var span := maxf(next_distance - _acceptance_distances[i], 0.001)
			var weight := clampf((distance - _acceptance_distances[i]) / span, 0.0, 1.0)
			return Vector2(
				lerpf(_acceptance_pitches[i], _acceptance_pitches[i + 1], weight),
				lerp_angle(_acceptance_yaws[i], _acceptance_yaws[i + 1], weight)
			)
	var last := _acceptance_distances.size() - 1
	return Vector2(_acceptance_pitches[last], _acceptance_yaws[last])

func _lateral_for_distance(distance: float) -> float:
	if _acceptance_laterals.is_empty():
		return 0.0
	if distance <= _acceptance_distances[0]:
		return _acceptance_laterals[0]
	for i in range(_acceptance_laterals.size() - 1):
		var next_distance := _acceptance_distances[i + 1]
		if distance <= next_distance:
			var span := maxf(next_distance - _acceptance_distances[i], 0.001)
			var weight := clampf((distance - _acceptance_distances[i]) / span, 0.0, 1.0)
			return lerpf(_acceptance_laterals[i], _acceptance_laterals[i + 1], weight)
	var last := _acceptance_laterals.size() - 1
	return _acceptance_laterals[last]

func reset_to_distance(s: float) -> void:
	distance_m = clampf(s, 0.0, route.length_m if route else s)
	_place()

func apply_acceptance_pose(scene_id: String) -> void:
	## Small camera pose offsets reproduce the source camera's head turn while
	## keeping the route tangent and physical road pitch authoritative.
	_requested_scene_id = scene_id.to_upper()
	if route != null:
		_cache_acceptance_poses()
		_place()
