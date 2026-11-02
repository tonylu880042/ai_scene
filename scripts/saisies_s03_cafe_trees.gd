extends Node3D

## Two bounded S03 cafe-side conifers over the accepted R24 right-forest view.
## The inherited route, cafe, terrain, camera, and R24 forest remain owners of
## their geometry.  This node adds only two locally tinted tree instances.

const FOREST_HELPER := preload("res://scripts/saisies_s03_forest_refinement.gd")

@export var right_forest_review_path: NodePath = NodePath("../RightForestReview")
@export var world_path: NodePath = NodePath("../RightForestReview/LeftForestReview/FlowersReview/SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/World")
@export var s01_landscape_path: NodePath = NodePath("../RightForestReview/LeftForestReview/FlowersReview/SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/S01Landscape")
@export var enable_refinement := true

const SOURCE_FRAME := "video/saisies_analysis/acceptance/S03_f001798.png"
const SOURCE_SHA256 := "184ee032aef47be5d52b5d5c6379300dc4dca85054ada0b93ef07ed8ca043e10"
const CAMERA_GATE_CENTER := Vector3(138.9204, -65.5922, -839.3978)
const CAMERA_GATE_FULL_M := 260.0
const CAMERA_GATE_END_M := 420.0
const CAFE_STATION_M := 970.0
const CAFE_LATERAL_M := 12.0
const ROOT_BURY_M := 0.04
const MAX_GROUND_RANGE_M := 3.0
const FIXED_SCREEN_SIZE := Vector2(1920.0, 1080.0)
const CLOSE_FOV_DEG := 58.0
const CAFE_FOOTPRINT_XZ := Rect2(151.8, -882.8, 13.7, 13.7)
const FIXED_A_XZ := Vector2(172.0, -902.0)
const FIXED_B_XZ := Vector2(179.50764465332, -872.002807617188)

var _right_forest_review: Node
var _world: Node3D
var _landscape: Node
var _route: Node
var _camera: Camera3D
var _replacement: Node3D
var _built := false
var _attempts := 0
var _lod_active := false
var _records: Array[Dictionary] = []
var _candidate_records: Array[Dictionary] = []
var _close_camera_world := CAMERA_GATE_CENTER
var _close_target_world := Vector3(158.0, -20.0, -895.0)

func _ready() -> void:
	process_priority = -80
	if _has_command_line_flag("--s03-cafe-trees-off"):
		enable_refinement = false
	call_deferred("_try_build")

func _process(_delta: float) -> void:
	if _built:
		_update_lod_gate()

func _try_build() -> void:
	if _built:
		return
	_right_forest_review = get_node_or_null(right_forest_review_path)
	_world = get_node_or_null(world_path) as Node3D
	_landscape = get_node_or_null(s01_landscape_path)
	if _right_forest_review == null or _world == null or _landscape == null:
		_retry("S03 cafe trees dependencies are incomplete")
		return
	if not bool(_right_forest_review.get_meta("saisies_s03_right_forest_review_ready", false)):
		_retry("S03 cafe trees are waiting for R24 right-forest readiness")
		return
	var rig := _world.get_node_or_null("CameraRig") as Node3D
	_camera = rig.get_node_or_null("Camera3D") as Camera3D if rig != null else null
	_route = _world.get_node_or_null("Route") as Node
	if _camera == null or _route == null or not _route.has_method("pos_at") or not _route.has_method("left_at"):
		_retry("S03 cafe trees require Route and Camera3D")
		return
	_close_camera_world = _camera.global_position if _camera.global_position.is_finite() else CAMERA_GATE_CENTER
	if not enable_refinement:
		_publish_disabled_state()
		_built = true
		return
	if not _build_candidate():
		_fail_and_hold("S03 cafe trees could not establish two supported cafe-side conifers")
		return
	_built = true
	_update_lod_gate()
	_publish_ready_state()

func _build_candidate() -> bool:
	_records.clear()
	_candidate_records.clear()
	var helper := FOREST_HELPER.new()
	helper.set("_world", _world)
	helper.set("_landscape", _landscape)
	var loaded: Variant = helper.call("_load_tree_meshes")
	var contacts: Dictionary = {}
	if loaded is Dictionary:
		for key in ["conifer_1", "conifer_0"]:
			var mesh: Mesh = loaded.get(key) as Mesh
			if mesh == null:
				helper.free()
				return false
			var points: Variant = helper.call("_build_surface0_contact_points", mesh)
			if not points is Array or points.size() < 4:
				helper.free()
				return false
			contacts[key] = points
	else:
		helper.free()
		return false
	var meshes: Dictionary = loaded
	helper.free()
	var pair := _select_candidate_pair()
	if pair.is_empty():
		return false
	_candidate_records.clear()
	var diagnostics: Variant = pair.get("diagnostics", [])
	if diagnostics is Array:
		for raw_diagnostic in diagnostics:
			if raw_diagnostic is Dictionary:
				var diagnostic_record: Dictionary = raw_diagnostic
				_candidate_records.append(diagnostic_record)
	var candidate := Node3D.new()
	candidate.name = "S03CafeTreesCandidate"
	candidate.set_meta("saisies_s03_cafe_trees_owner", "two cafe-side conifers")
	candidate.set_meta("saisies_s03_cafe_trees_source_frame", SOURCE_FRAME)
	candidate.set_meta("saisies_s03_cafe_trees_station_m", CAFE_STATION_M)
	_replacement = candidate
	add_child(_replacement)
	var specs: Array = pair["specs"]
	var keys := ["conifer_1", "conifer_0"]
	var names := ["S03CafeConifer_A", "S03CafeConifer_B"]
	var widths := [0.72, 1.02]
	var heights := [0.72, 1.02]
	var yaws := [0.22, -0.31]
	for index in 2:
		var spec: Dictionary = specs[index]
		var ground: Vector3 = spec["ground"]
		var mesh := meshes[keys[index]] as Mesh
		var contact_points: Array[Vector3] = contacts[keys[index]]
		var bounds := mesh.get_aabb()
		var width_scale := float(widths[index])
		var height_scale := float(heights[index])
		var basis := Basis(Vector3.UP, float(yaws[index])).scaled(Vector3(width_scale, height_scale, width_scale))
		var root_position := Vector3(ground.x, ground.y - bounds.position.y * height_scale - ROOT_BURY_M, ground.z)
		var fit := _fit_root(contact_points, basis, root_position)
		if not bool(fit.get("valid", false)):
			_replacement.queue_free()
			_replacement = null
			return false
		root_position = fit["root_position"]
		var instance := MeshInstance3D.new()
		instance.name = names[index]
		instance.mesh = mesh
		instance.transform = Transform3D(basis, root_position)
		instance.visibility_range_end = 0.0
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_replacement.add_child(instance)
		var record := {
			"index": index,
			"name": names[index],
			"source": "fixed cafe-side XZ candidate",
			"source_frame": SOURCE_FRAME,
			"station_m": float(spec["station"]),
			"lateral_m": float(spec["lateral"]),
			"ground": ground,
			"ground_source": String(spec["ground_source"]),
			"ground_triangle_start": int(spec.get("triangle_start", -1)),
			"root_world": root_position,
			"transform": instance.global_transform,
			"world_transform": instance.global_transform,
			"path": str(instance.get_path()),
			"base": Vector3(ground.x, ground.y, ground.z),
			"height_scale": height_scale,
			"width_scale": width_scale,
			"mesh_aabb": bounds,
			"surface0_contact_points_local": contact_points,
			"rootfit": fit,
			"screen_base": _fixed_screen_projection(root_position),
			"screen_top": _fixed_screen_projection(root_position + basis * Vector3(0.0, bounds.size.y, 0.0)),
		}
		instance.set_meta("saisies_s03_cafe_tree_record", record)
		instance.set_meta("saisies_s03_cafe_trees_ground_source", String(spec["ground_source"]))
		instance.set_meta("saisies_s03_cafe_trees_rootfit", fit)
		_records.append(record)
		_close_target_world = _close_target_world.lerp(root_position + Vector3.UP * 7.0, 0.5)
	if _records.size() != 2:
		return false
	candidate.set_meta("saisies_s03_cafe_trees_instance_records", _records)
	return true

func _select_candidate_pair() -> Dictionary:
	var fixed_points := [FIXED_A_XZ, FIXED_B_XZ]
	var specs: Array[Dictionary] = []
	for raw_point in fixed_points:
		var xz: Vector2 = raw_point
		if not _clear_of_cafe(xz):
			return {}
		var sample := _sample_actual_ground(xz)
		if sample.is_empty():
			return {}
		var ground: Vector3 = sample["position"]
		var screen := _fixed_screen_projection(ground + Vector3.UP * 0.5)
		if _camera.is_position_behind(ground) or not screen.is_finite():
			return {}
		specs.append({
			"station": CAFE_STATION_M,
			"lateral": 0.0,
			"fixed_xz": xz,
			"xz": xz,
			"ground": ground,
			"ground_source": String(sample.get("source", "")),
			"triangle_start": int(sample.get("triangle_start", sample.get("overlay_triangle_start", -1))),
			"screen": screen,
		})
	return {"pair_index": -1, "specs": specs, "diagnostics": [{"fixed": true, "specs": specs.duplicate(true)}]}

func _route_xz(station: float, lateral: float) -> Vector2:
	var route_point := Vector3(_route.call("pos_at", station))
	var left := Vector3(_route.call("left_at", station))
	var point := route_point + left * lateral
	return Vector2(point.x, point.z)

func _clear_of_cafe(xz: Vector2) -> bool:
	return not CAFE_FOOTPRINT_XZ.grow(1.4).has_point(xz)

func _sample_actual_ground(xz: Vector2) -> Dictionary:
	var samples: Array[Dictionary] = []
	for method_name in ["_sample_ground", "_sample_baked_ground"]:
		if not _landscape.has_method(method_name):
			continue
		var value: Variant = _landscape.call(method_name, xz)
		if not value is Dictionary or not value.has("position"):
			continue
		var sample: Dictionary = value
		var point: Vector3 = sample["position"]
		var source := String(sample.get("source", ""))
		if not point.is_finite() or source.contains("nearest_vertex_fallback"):
			continue
		if absf(point.x - xz.x) > 0.01 or absf(point.z - xz.y) > 0.01:
			continue
		samples.append(sample.duplicate(true))
	if samples.is_empty():
		return {}
	var chosen: Dictionary = samples[0]
	for sample in samples:
		if float((sample["position"] as Vector3).y) > float((chosen["position"] as Vector3).y):
			chosen = sample
	return chosen

func _fit_root(local_points: Array[Vector3], basis: Basis, root_position: Vector3) -> Dictionary:
	var ground_heights := PackedFloat32Array()
	var ground_sources: Array[String] = []
	var world_points := PackedVector3Array()
	var max_clearance := 0.0
	var min_ground := INF
	var max_ground := -INF
	for local_point in local_points:
		var world_point := root_position + basis * local_point
		var sample := _sample_actual_ground(Vector2(world_point.x, world_point.z))
		if sample.is_empty():
			return {"valid": false}
		var ground: Vector3 = sample["position"]
		var clearance := world_point.y - ground.y
		max_clearance = maxf(max_clearance, maxf(clearance, 0.0))
		min_ground = minf(min_ground, ground.y)
		max_ground = maxf(max_ground, ground.y)
		world_points.append(world_point)
		ground_heights.append(ground.y)
		ground_sources.append(String(sample.get("source", "")))
	if max_ground - min_ground > MAX_GROUND_RANGE_M:
		return {"valid": false, "ground_range_m": max_ground - min_ground}
	var additional_bury := max_clearance + ROOT_BURY_M if max_clearance > 0.0 else 0.0
	var corrected_root := root_position - Vector3.UP * additional_bury
	var corrected_clearance := 0.0
	var max_burial := 0.0
	var corrected_world_points := PackedVector3Array()
	for index in world_points.size():
		var corrected_point: Vector3 = world_points[index] - Vector3.UP * additional_bury
		var clearance := corrected_point.y - ground_heights[index]
		corrected_clearance = maxf(corrected_clearance, maxf(clearance, 0.0))
		max_burial = maxf(max_burial, maxf(-clearance, 0.0))
		corrected_world_points.append(corrected_point)
	return {
		"valid": corrected_root.is_finite() and corrected_clearance <= 0.001,
		"root_position": corrected_root,
		"initial_world_points": world_points,
		"corrected_world_points": corrected_world_points,
		"ground_heights": ground_heights,
		"ground_sources": ground_sources,
		"ground_range_m": max_ground - min_ground,
		"initial_max_positive_clearance_m": max_clearance,
		"post_correction_max_positive_clearance_m": corrected_clearance,
		"additional_bury_m": additional_bury,
		"deep_burial_m": max_burial,
	}

func _fixed_screen_projection(point: Vector3) -> Vector2:
	if _camera == null or not point.is_finite():
		return Vector2(INF, INF)
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		viewport_size = FIXED_SCREEN_SIZE
	var projected := _camera.unproject_position(point)
	return Vector2(projected.x / viewport_size.x * FIXED_SCREEN_SIZE.x, projected.y / viewport_size.y * FIXED_SCREEN_SIZE.y)

func _update_lod_gate() -> void:
	if _camera == null or _replacement == null:
		return
	var distance := _camera.global_position.distance_to(CAMERA_GATE_CENTER)
	_lod_active = distance <= CAMERA_GATE_END_M
	_replacement.visible = _lod_active
	set_meta("saisies_s03_cafe_trees_lod_active", _lod_active)
	set_meta("saisies_s03_cafe_trees_camera_gate_distance_m", distance)

func _publish_ready_state() -> void:
	set_meta("saisies_s03_cafe_trees_ready", true)
	set_meta("saisies_s03_cafe_trees_enabled", true)
	set_meta("saisies_s03_cafe_trees_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_cafe_trees_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_cafe_trees_count", _records.size())
	set_meta("saisies_s03_cafe_trees_instance_records", _records)
	set_meta("saisies_s03_cafe_trees_projection_records", _records)
	set_meta("saisies_s03_cafe_trees_candidate_records", _candidate_records)
	set_meta("saisies_s03_cafe_trees_replacement_path", str(_replacement.get_path()))
	set_meta("saisies_s03_cafe_trees_close_camera", _close_camera_world)
	set_meta("saisies_s03_cafe_trees_close_target", _close_target_world)
	set_meta("saisies_s03_cafe_trees_close_fov_deg", CLOSE_FOV_DEG)
	set_meta("saisies_s03_cafe_trees_camera_gate", {"center": CAMERA_GATE_CENTER, "full_m": CAMERA_GATE_FULL_M, "end_m": CAMERA_GATE_END_M, "active": _lod_active})
	set_meta("saisies_s03_cafe_trees_gate", {"center": CAMERA_GATE_CENTER, "full_m": CAMERA_GATE_FULL_M, "end_m": CAMERA_GATE_END_M, "active": _lod_active})
	set_meta("saisies_s03_cafe_trees_ground_contact_method", "S01Landscape actual overlay/baked triangle; nearest-vertex fallback rejected")
	set_meta("saisies_s03_cafe_trees_geometry_contract", "two local MeshInstance3D conifers; no terrain, camera, route, building, or inherited forest edits")
	_publish_parent_ready(true)

func _publish_disabled_state() -> void:
	set_meta("saisies_s03_cafe_trees_ready", true)
	set_meta("saisies_s03_cafe_trees_enabled", false)
	set_meta("saisies_s03_cafe_trees_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_cafe_trees_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_cafe_trees_count", 0)
	set_meta("saisies_s03_cafe_trees_ground_contact_method", "disabled baseline")
	_publish_parent_ready(false)

func _publish_parent_ready(enabled: bool) -> void:
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s03_cafe_trees_review_ready", true)
		parent.set_meta("saisies_s03_cafe_trees_review_enabled", enabled)
	var current := get_tree().current_scene
	if current != null:
		current.set_meta("saisies_s03_cafe_trees_review_ready", true)
		current.set_meta("saisies_s03_cafe_trees_review_enabled", enabled)

func _retry(message: String) -> void:
	_attempts += 1
	if _attempts < 240:
		call_deferred("_retry_next_frame")
	else:
		_fail_and_hold(message)

func _retry_next_frame() -> void:
	await get_tree().process_frame
	_try_build()

func _fail_and_hold(message: String) -> void:
	set_meta("saisies_s03_cafe_trees_ready", false)
	set_meta("saisies_s03_cafe_trees_error", message)
	_publish_parent_ready(false)
	push_error(message)

func _has_command_line_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()
