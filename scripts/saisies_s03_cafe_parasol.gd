extends Node3D

## One bounded S03 cafe-side parasol over the accepted R25 cafe-tree view.
## The inherited cafe, terrace, trees, route, terrain, camera, and forest remain
## owners of their geometry.  This node adds only one low orange-red parasol.

@export var right_forest_review_path: NodePath = NodePath("../CafeTreesReview/RightForestReview")
@export var world_path: NodePath = NodePath("../CafeTreesReview/RightForestReview/LeftForestReview/FlowersReview/SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/World")
@export var cafe_refinement_path: NodePath = NodePath("../CafeTreesReview/RightForestReview/LeftForestReview/FlowersReview/SignsReview/LiftReview/GroundReview/CafeReview/CafeRefinement")
@export var cafe_trees_path: NodePath = NodePath("../CafeTreesReview/CafeTreesRefinement")
@export var enable_refinement := true

const SOURCE_FRAME := "video/saisies_analysis/acceptance/S03_f001798.png"
const SOURCE_SHA256 := "184ee032aef47be5d52b5d5c6379300dc4dca85054ada0b93ef07ed8ca043e10"
const CAMERA_GATE_CENTER := Vector3(138.9204, -65.5922, -839.3978)
const CAMERA_GATE_FULL_M := 260.0
const CAMERA_GATE_END_M := 420.0
const FIXED_SCREEN_SIZE := Vector2(1920.0, 1080.0)
const CAFE_LOCAL_X := 4.05
const TERRACE_LOCAL_X := 0.0
const TERRACE_LOCAL_Z := 3.0
const PARASOL_HALF_DEPTH_M := 0.75
const PARASOL_HALF_WIDTH_M := 2.30
const PARASOL_EDGE_Y_M := 2.20
const PARASOL_CROWN_Y_M := 2.65
const PARASOL_BASE_RADIUS_M := 0.34
const PARASOL_BASE_HEIGHT_M := 0.12

var _right_forest_review: Node
var _world: Node3D
var _cafe_refinement: Node
var _cafe_trees: Node
var _terrace: MeshInstance3D
var _camera: Camera3D
var _replacement: Node3D
var _built := false
var _attempts := 0
var _lod_active := false
var _record: Dictionary = {}

func _ready() -> void:
	process_priority = -80
	if _has_command_line_flag("--s03-cafe-parasol-off"):
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
	_cafe_refinement = get_node_or_null(cafe_refinement_path)
	_cafe_trees = get_node_or_null(cafe_trees_path)
	if _right_forest_review == null or _world == null or _cafe_refinement == null or _cafe_trees == null:
		_retry("S03 cafe parasol dependencies are incomplete")
		return
	if not bool(_right_forest_review.get_meta("saisies_s03_right_forest_review_ready", false)):
		_retry("S03 cafe parasol is waiting for R24 right-forest readiness")
		return
	if not bool(_cafe_trees.get_meta("saisies_s03_cafe_trees_ready", false)):
		_retry("S03 cafe parasol is waiting for R25 cafe-tree readiness")
		return
	if not bool(_cafe_refinement.get_meta("saisies_s03_cafe_refinement_ready", false)):
		_retry("S03 cafe parasol is waiting for R18 cafe terrace readiness")
		return
	var rig := _world.get_node_or_null("CameraRig") as Node3D
	_camera = rig.get_node_or_null("Camera3D") as Camera3D if rig != null else null
	if _camera == null:
		_retry("S03 cafe parasol requires the inherited Camera3D")
		return
	_terrace = _cafe_refinement.get_node_or_null("S03CafeRefinementCandidate/S03CafeRefinementTerrace") as MeshInstance3D
	if _terrace == null or _terrace.mesh == null:
		_retry("S03 cafe parasol requires the actual R18 terrace mesh")
		return
	if not enable_refinement:
		_publish_disabled_state()
		_built = true
		return
	if not _build_candidate():
		_fail_and_hold("S03 cafe parasol could not establish exact terrace contact")
		return
	_built = true
	_update_lod_gate()
	_publish_ready_state()

func _build_candidate() -> bool:
	# Preserve the accepted cafe/terrace yaw.  Its basis is already upright;
	# re-deriving yaw here can mirror the front edge and push the canopy into the
	# cafe wall.
	var terrace_basis := _terrace.global_transform.basis
	var terrace_local_top := Vector3(TERRACE_LOCAL_X, _terrace.get_aabb().end.y, TERRACE_LOCAL_Z)
	var top_guess := _terrace.global_transform * terrace_local_top
	var sampled := _sample_terrace(Vector2(top_guess.x, top_guess.z))
	if sampled.is_empty():
		return false
	var base_world := Vector3(top_guess.x, float(sampled["position"].y), top_guess.z)
	var candidate := Node3D.new()
	candidate.name = "S03CafeParasolCandidate"
	candidate.set_meta("saisies_s03_cafe_parasol_owner", "one low orange-red terrace parasol")
	candidate.set_meta("saisies_s03_cafe_parasol_source_frame", SOURCE_FRAME)
	candidate.set_meta("saisies_s03_cafe_parasol_terrace_path", str(_terrace.get_path()))
	candidate.set_meta("saisies_s03_cafe_parasol_cafe_local", Vector3(CAFE_LOCAL_X, 0.0, TERRACE_LOCAL_Z))
	candidate.set_meta("saisies_s03_cafe_parasol_terrace_local", Vector3(TERRACE_LOCAL_X, _terrace.get_aabb().end.y, TERRACE_LOCAL_Z))
	add_child(candidate)
	candidate.global_transform = Transform3D(terrace_basis, base_world)
	_replacement = candidate

	var base := _make_cylinder("S03CafeParasolBase", PARASOL_BASE_RADIUS_M, PARASOL_BASE_HEIGHT_M, _base_material())
	base.position = Vector3(0.0, PARASOL_BASE_HEIGHT_M * 0.5, 0.0)
	base.set_meta("saisies_s03_cafe_parasol_support", "R18 S03CafeRefinementTerrace top surface")
	candidate.add_child(base)
	var pole := _make_cylinder("S03CafeParasolPole", 0.035, PARASOL_CROWN_Y_M, _pole_material())
	pole.position = Vector3(0.0, PARASOL_CROWN_Y_M * 0.5, 0.0)
	candidate.add_child(pole)
	var canopy := _build_canopy()
	if canopy == null:
		candidate.queue_free()
		_replacement = null
		return false
	canopy.name = "S03CafeParasolCanopy"
	candidate.add_child(canopy)
	var ribs := _build_ribs()
	ribs.name = "S03CafeParasolRibs"
	candidate.add_child(ribs)

	_record = {
		"name": "S03CafeParasol",
		"source": "S03_f001798 cafe right terrace orange-red parasol",
		"source_frame": SOURCE_FRAME,
		"source_sha256": SOURCE_SHA256,
		"terrace_path": str(_terrace.get_path()),
		"terrace_surface": int(sampled.get("surface", -1)),
		"terrace_triangle_start": int(sampled.get("triangle_start", -1)),
		"terrace_local": terrace_local_top,
		"cafe_local": Vector3(CAFE_LOCAL_X, 0.0, TERRACE_LOCAL_Z),
		"terrace_contact_world": base_world,
		"base_world": base_world,
		"canopy_top_world": candidate.global_transform * Vector3(0.0, PARASOL_CROWN_Y_M, 0.0),
		"canopy_edge_y_m": PARASOL_EDGE_Y_M,
		"canopy_crown_y_m": PARASOL_CROWN_Y_M,
		"canopy_depth_m": PARASOL_HALF_DEPTH_M * 2.0,
		"canopy_width_m": PARASOL_HALF_WIDTH_M * 2.0,
		"terrace_ground_source": String(sampled.get("source", "R18 terrace mesh triangle")),
		"terrace_contact_y_m": float(sampled["position"].y),
		"transform": candidate.global_transform,
		"height_m": PARASOL_CROWN_Y_M,
		"width_m": PARASOL_HALF_WIDTH_M * 2.0,
	}
	base.set_meta("saisies_s03_cafe_parasol_record", _record)
	pole.set_meta("saisies_s03_cafe_parasol_record", _record)
	canopy.set_meta("saisies_s03_cafe_parasol_record", _record)
	candidate.set_meta("saisies_s03_cafe_parasol_record", _record)
	return true

func _build_canopy() -> MeshInstance3D:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var center := Vector3(0.0, PARASOL_CROWN_Y_M, 0.0)
	for index in 8:
		var angle0 := TAU * float(index) / 8.0
		var angle1 := TAU * float(index + 1) / 8.0
		var a := Vector3(cos(angle0) * PARASOL_HALF_DEPTH_M, PARASOL_EDGE_Y_M, sin(angle0) * PARASOL_HALF_WIDTH_M)
		var b := Vector3(cos(angle1) * PARASOL_HALF_DEPTH_M, PARASOL_EDGE_Y_M, sin(angle1) * PARASOL_HALF_WIDTH_M)
		surface.add_vertex(center)
		surface.add_vertex(a)
		surface.add_vertex(b)
	var mesh := surface.commit()
	if mesh == null:
		return null
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _parasol_material()
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return instance

func _build_ribs() -> MeshInstance3D:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_LINES)
	var center := Vector3(0.0, PARASOL_CROWN_Y_M + 0.008, 0.0)
	for index in 8:
		var angle := TAU * float(index) / 8.0
		var edge := Vector3(cos(angle) * PARASOL_HALF_DEPTH_M, PARASOL_EDGE_Y_M + 0.012, sin(angle) * PARASOL_HALF_WIDTH_M)
		surface.add_vertex(center)
		surface.add_vertex(edge)
	var instance := MeshInstance3D.new()
	instance.mesh = surface.commit()
	instance.material_override = _pole_material()
	return instance

func _make_cylinder(node_name: String, radius: float, height: float, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 12
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return instance

func _sample_terrace(point: Vector2) -> Dictionary:
	if _terrace == null or _terrace.mesh == null:
		return {}
	var best_y := -INF
	var best_surface := -1
	var best_triangle := -1
	for surface_index in _terrace.mesh.get_surface_count():
		var arrays := _terrace.mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var triangle_count := indices.size() / 3 if not indices.is_empty() else vertices.size() / 3
		for triangle in triangle_count:
			var i0 := indices[triangle * 3] if not indices.is_empty() else triangle * 3
			var i1 := indices[triangle * 3 + 1] if not indices.is_empty() else triangle * 3 + 1
			var i2 := indices[triangle * 3 + 2] if not indices.is_empty() else triangle * 3 + 2
			var a: Vector3 = _terrace.global_transform * vertices[i0]
			var b: Vector3 = _terrace.global_transform * vertices[i1]
			var c: Vector3 = _terrace.global_transform * vertices[i2]
			var height := _triangle_height(point, a, b, c)
			if is_finite(height) and height > best_y:
				best_y = height
				best_surface = surface_index
				best_triangle = triangle * 3
	if best_surface < 0:
		return {}
	return {"position": Vector3(point.x, best_y, point.y), "source": "R18 S03CafeRefinementTerrace.mesh_triangle", "surface": best_surface, "triangle_start": best_triangle}

func _triangle_height(point: Vector2, a: Vector3, b: Vector3, c: Vector3) -> float:
	var denominator := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(denominator) < 0.000001:
		return NAN
	var wa := ((b.z - c.z) * (point.x - c.x) + (c.x - b.x) * (point.y - c.z)) / denominator
	var wb := ((c.z - a.z) * (point.x - c.x) + (a.x - c.x) * (point.y - c.z)) / denominator
	var wc := 1.0 - wa - wb
	if wa < -0.001 or wb < -0.001 or wc < -0.001:
		return NAN
	return a.y * wa + b.y * wb + c.y * wc

func _upright_basis(source: Basis) -> Basis:
	var forward := Vector3(-source.z.x, 0.0, -source.z.z)
	if forward.length_squared() < 0.000001:
		return Basis.IDENTITY
	return Basis(Vector3.UP, atan2(forward.x, -forward.z))

func _update_lod_gate() -> void:
	if _camera == null or _replacement == null:
		return
	var distance := _camera.global_position.distance_to(CAMERA_GATE_CENTER)
	_lod_active = distance <= CAMERA_GATE_END_M
	_replacement.visible = _lod_active
	set_meta("saisies_s03_cafe_parasol_lod_active", _lod_active)
	set_meta("saisies_s03_cafe_parasol_camera_gate_distance_m", distance)

func _publish_ready_state() -> void:
	set_meta("saisies_s03_cafe_parasol_ready", true)
	set_meta("saisies_s03_cafe_parasol_enabled", true)
	set_meta("saisies_s03_cafe_parasol_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_cafe_parasol_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_cafe_parasol_count", 1)
	set_meta("saisies_s03_cafe_parasol_record", _record)
	set_meta("saisies_s03_cafe_parasol_records", [_record])
	set_meta("saisies_s03_cafe_parasol_terrace_path", str(_terrace.get_path()))
	set_meta("saisies_s03_cafe_parasol_camera_gate", {"center": CAMERA_GATE_CENTER, "full_m": CAMERA_GATE_FULL_M, "end_m": CAMERA_GATE_END_M, "active": _lod_active})
	_publish_parent_ready(true)

func _publish_disabled_state() -> void:
	set_meta("saisies_s03_cafe_parasol_ready", true)
	set_meta("saisies_s03_cafe_parasol_enabled", false)
	set_meta("saisies_s03_cafe_parasol_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_cafe_parasol_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_cafe_parasol_count", 0)
	_publish_parent_ready(false)

func _publish_parent_ready(enabled: bool) -> void:
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s03_cafe_parasol_review_ready", true)
		parent.set_meta("saisies_s03_cafe_parasol_review_enabled", enabled)
	var current := get_tree().current_scene
	if current != null:
		current.set_meta("saisies_s03_cafe_parasol_review_ready", true)
		current.set_meta("saisies_s03_cafe_parasol_review_enabled", enabled)

func _parasol_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.55, 0.28, 0.19, 1.0)
	material.roughness = 0.82
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _pole_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.11, 0.095, 0.08, 1.0)
	material.roughness = 0.8
	return material

func _base_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.20, 0.18, 0.15, 1.0)
	material.roughness = 0.94
	return material

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
	set_meta("saisies_s03_cafe_parasol_ready", false)
	set_meta("saisies_s03_cafe_parasol_error", message)
	_publish_parent_ready(false)
	push_error(message)

func _has_command_line_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()
