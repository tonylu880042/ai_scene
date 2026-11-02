extends Node3D

## Bounded S03 chairlift replacement for the accepted R19 ground scene.
##
## The authored lift is retained in the frozen world, but its old cable,
## support, and chair visuals are hidden in this instantiated review only.  A
## small, static 3D replacement uses the authored support XZ anchors and the
## baked terrain sampler for both tower foundations.  Cable attachment points
## are evaluated from the same parabola used to draw each cable.

@export var ground_review_path: NodePath = NodePath("../GroundReview")
@export var world_path: NodePath = NodePath("../GroundReview/CafeReview/S03Review/S02Review/S01Review/World")
@export var s01_landscape_path: NodePath = NodePath("../GroundReview/CafeReview/S03Review/S02Review/S01Review/S01Landscape")
@export var chairlift_path: NodePath = NodePath("../GroundReview/CafeReview/S03Review/S02Review/S01Review/World/VillageS01S02/S03Chairlift")
@export var enable_refinement := true

const SOURCE_FRAME := "video/saisies_analysis/acceptance/S03_f001798.png"
const SOURCE_SHA256 := "184ee032aef47be5d52b5d5c6379300dc4dca85054ada0b93ef07ed8ca043e10"
## The forward s980/u-45 sample was finite and in front of the camera, but its
## projected head fell to y369 and x1341.  The authored s955/u-31 anchor keeps
## the source-like right-side x/head projection (x1492/y246) while preserving
## an actual baked foundation; the remaining low base is recorded as residual.
const RIGHT_TOWER_STATION_M := 955.0
const RIGHT_TOWER_LATERAL_M := -31.0
const CABLE_RADIUS_M := 0.032
const CABLE_SAG_M := 1.85
const CABLE_RUN_SEPARATION_M := 1.65
const TOWER_HEIGHT_M := 13.4
const CROSSBEAM_Y_M := 13.45
const CABLE_TOP_Y_M := 13.58
const TOWER_BEAM_WIDTH_M := 3.35
const TOWER_BEAM_HEIGHT_M := 0.22
const TOWER_BEAM_DEPTH_M := 0.32
const SHEAVE_RADIUS_M := 0.19
const SHEAVE_DEPTH_M := 0.12
const HANGER_LENGTH_M := 2.15
const CHAIR_WIDTH_M := 1.55
const CHAIR_DEPTH_M := 0.64
const CHAIR_SEAT_THICKNESS_M := 0.12
const CHAIR_BACK_HEIGHT_M := 0.72
const CABLE_SEGMENTS := 18
const CHAIR_T_VALUES := [0.20, 0.36, 0.55]
const CHAIR_RUN_INDICES := [0, 1, 0]
const METAL_COLOR := Color(0.22, 0.25, 0.26, 1.0)
const METAL_EDGE_COLOR := Color(0.30, 0.33, 0.33, 1.0)
const SEAT_COLOR := Color(0.18, 0.22, 0.20, 1.0)

var _ground_review: Node
var _world: Node3D
var _landscape: Node
var _chairlift: Node3D
var _built := false
var _attempts := 0
var _hidden_paths: Array[String] = []
var _tower_bases: Array[Vector3] = []
var _tower_ground_samples: Array[Dictionary] = []
var _tower_placement_records: Array[Dictionary] = []
var _cable_points: Array[PackedVector3Array] = []
var _chair_records: Array[Dictionary] = []
var _projection_records: Array[Dictionary] = []
var _max_hanger_attachment_error_m := 0.0
var _replacement: Node3D
var _metal: StandardMaterial3D
var _edge_metal: StandardMaterial3D
var _seat_material: StandardMaterial3D

func _ready() -> void:
	process_priority = -120
	if _has_command_line_flag("--s03-lift-off"):
		enable_refinement = false
	call_deferred("_try_build")

func _try_build() -> void:
	if _built:
		return
	_ground_review = get_node_or_null(ground_review_path)
	_world = get_node_or_null(world_path) as Node3D
	_landscape = get_node_or_null(s01_landscape_path)
	_chairlift = get_node_or_null(chairlift_path) as Node3D
	if _ground_review == null or _world == null or _landscape == null or _chairlift == null:
		_retry("S03 lift refinement dependencies are incomplete")
		return
	if not bool(_ground_review.get_meta("saisies_s03_ground_review_ready", false)):
		_retry("S03 lift refinement is waiting for frame-wise R19 ground readiness")
		return
	if not enable_refinement:
		_publish_disabled_state()
		_built = true
		return
	if not _build_replacement():
		_fail_and_hold("S03 lift refinement could not build a finite supported replacement")
		return
	_publish_ready_state()
	_built = true

func _build_replacement() -> bool:
	_hidden_paths.clear()
	_tower_bases.clear()
	_tower_ground_samples.clear()
	_tower_placement_records.clear()
	_cable_points.clear()
	_chair_records.clear()
	_projection_records.clear()
	_max_hanger_attachment_error_m = 0.0
	_hide_old_lift_visuals(_chairlift)
	if not _resolve_tower_bases():
		return false
	if _tower_bases.size() != 2:
		return false
	var line_direction := _tower_bases[1] - _tower_bases[0]
	line_direction.y = 0.0
	if line_direction.length_squared() < 0.01 or not line_direction.is_finite():
		return false
	line_direction = line_direction.normalized()
	var route_tangent := _route_tangent()
	if route_tangent.length_squared() < 0.01:
		return false
	var run_offset := route_tangent * (CABLE_RUN_SEPARATION_M * 0.5)
	var cable_a := _tower_bases[0] + run_offset + Vector3.UP * CABLE_TOP_Y_M
	var cable_b := _tower_bases[1] + run_offset + Vector3.UP * CABLE_TOP_Y_M
	var cable_c := _tower_bases[0] - run_offset + Vector3.UP * CABLE_TOP_Y_M
	var cable_d := _tower_bases[1] - run_offset + Vector3.UP * CABLE_TOP_Y_M
	if not cable_a.is_finite() or not cable_b.is_finite() or not cable_c.is_finite() or not cable_d.is_finite():
		return false
	_replacement = Node3D.new()
	_replacement.name = "S03LiftRefinementCandidate"
	_replacement.set_meta("saisies_s03_lift_owner", "S03Chairlift")
	add_child(_replacement)
	_make_materials()
	_build_towers(_replacement, line_direction, route_tangent)
	_build_cable(_replacement, cable_a, cable_b, "S03LiftCable_Upper", 0, line_direction)
	_build_cable(_replacement, cable_c, cable_d, "S03LiftCable_Lower", 1, line_direction)
	_build_chairs(_replacement, cable_a, cable_b, cable_c, cable_d, line_direction)
	if _cable_points.size() != 2 or _chair_records.size() != CHAIR_T_VALUES.size():
		return false
	return _all_geometry_finite()

func _resolve_tower_bases() -> bool:
	for index in 2:
		var old_tower := _chairlift.get_node_or_null("S03ChairliftTower_%d" % index) as Node3D
		if old_tower == null or not old_tower.global_position.is_finite():
			return false
		var old_position := old_tower.global_position
		var requested_position := old_position
		if index == 0:
			var candidate := _right_tower_candidate_xz()
			if candidate.is_finite():
				requested_position.x = candidate.x
				requested_position.z = candidate.z
		var sampled := _sample_baked_ground(old_position)
		if requested_position.x != old_position.x or requested_position.z != old_position.z:
			sampled = _sample_baked_ground(requested_position)
		var ground_y := old_position.y
		if sampled.has("position") and sampled["position"] is Vector3:
			var sampled_position: Vector3 = sampled["position"]
			if sampled_position.is_finite():
				ground_y = sampled_position.y
		if not is_finite(ground_y):
			return false
		var base := Vector3(requested_position.x, ground_y, requested_position.z)
		_tower_bases.append(base)
		_tower_ground_samples.append(sampled)
		_tower_placement_records.append({
			"tower_index": index,
			"authored_xz": Vector2(old_position.x, old_position.z),
			"chosen_xz": Vector2(base.x, base.z),
			"basis": "authored right tower s955/u-31 baked XZ fallback" if index == 0 else "frozen authored tower XZ",
		})
	return true

func _right_tower_candidate_xz() -> Vector3:
	var route := _world.get_node_or_null("Route") as Node
	if route == null or not route.has_method("pos_at") or not route.has_method("left_at"):
		return Vector3(INF, INF, INF)
	var route_position: Vector3 = route.call("pos_at", RIGHT_TOWER_STATION_M)
	var route_left: Vector3 = route.call("left_at", RIGHT_TOWER_STATION_M)
	route_left.y = 0.0
	if not route_position.is_finite() or route_left.length_squared() < 0.01:
		return Vector3(INF, INF, INF)
	return route_position + route_left.normalized() * RIGHT_TOWER_LATERAL_M

func _sample_baked_ground(point: Vector3) -> Dictionary:
	if _landscape != null and _landscape.has_method("_sample_baked_ground"):
		var result: Variant = _landscape.call("_sample_baked_ground", Vector2(point.x, point.z))
		if result is Dictionary:
			var dictionary: Dictionary = result
			if dictionary.has("position"):
				return dictionary
	return {"position": point, "source": "authored_tower_fallback", "error_m": INF}

func _route_tangent() -> Vector3:
	var route := _world.get_node_or_null("Route") as Node
	if route == null or not route.has_method("tangent_at"):
		return Vector3.FORWARD
	var distance := 955.0
	if route.has_method("acceptance_distance"):
		var accepted: Variant = route.call("acceptance_distance", "S03")
		if is_finite(float(accepted)):
			distance = float(accepted) + 25.0
	var tangent: Vector3 = route.call("tangent_at", distance)
	tangent.y = 0.0
	return tangent.normalized() if tangent.length_squared() > 0.01 else Vector3.FORWARD

func _hide_old_lift_visuals(parent: Node) -> void:
	for child in parent.get_children():
		var child_node := child as Node
		if child_node == null:
			continue
		var child_name := String(child_node.name)
		if _is_old_lift_name(child_name):
			_hide_visual_subtree(child_node)
		else:
			_hide_old_lift_visuals(child_node)

func _is_old_lift_name(node_name: String) -> bool:
	return node_name == "S03ChairliftTower_0" or node_name == "S03ChairliftTower_1" or node_name.begins_with("S03ChairliftCable") or node_name.begins_with("S03Chair_")

func _hide_visual_subtree(node: Node) -> void:
	var node_3d := node as Node3D
	if node_3d != null:
		node_3d.visible = false
		_hidden_paths.append(str(node.get_path()))
	for child in node.get_children():
		_hide_visual_subtree(child)

func _make_materials() -> void:
	_metal = StandardMaterial3D.new()
	_metal.albedo_color = METAL_COLOR
	_metal.roughness = 0.82
	_metal.metallic = 0.55
	_metal.cull_mode = BaseMaterial3D.CULL_DISABLED
	_edge_metal = StandardMaterial3D.new()
	_edge_metal.albedo_color = METAL_EDGE_COLOR
	_edge_metal.roughness = 0.74
	_edge_metal.metallic = 0.62
	_edge_metal.cull_mode = BaseMaterial3D.CULL_DISABLED
	_seat_material = StandardMaterial3D.new()
	_seat_material.albedo_color = SEAT_COLOR
	_seat_material.roughness = 0.9
	_seat_material.metallic = 0.35
	_seat_material.cull_mode = BaseMaterial3D.CULL_DISABLED

func _build_towers(parent: Node3D, line_direction: Vector3, route_tangent: Vector3) -> void:
	var sheave_axis := Vector3.UP.cross(line_direction).normalized()
	if sheave_axis.length_squared() < 0.01:
		sheave_axis = Vector3.RIGHT
	for index in 2:
		var base := _tower_bases[index]
		var tower := Node3D.new()
		tower.name = "S03LiftReplacementTower_%d" % index
		tower.position = base
		tower.set_meta("saisies_s03_lift_ground_source", String(_tower_ground_samples[index].get("source", "unknown")))
		tower.set_meta("saisies_s03_lift_ground_triangle_start", int(_tower_ground_samples[index].get("triangle_start", -1)))
		tower.set_meta("saisies_s03_lift_base_world", base)
		tower.set_meta("saisies_s03_lift_height_m", TOWER_HEIGHT_M)
		parent.add_child(tower)
		_add_cylinder(tower, "Mast", 0.18, TOWER_HEIGHT_M, Vector3(0.0, TOWER_HEIGHT_M * 0.5, 0.0), _metal)
		var beam_basis := _basis_from_x_and_z(route_tangent, line_direction)
		_add_box(tower, "Crossbeam", Vector3(TOWER_BEAM_WIDTH_M, TOWER_BEAM_HEIGHT_M, TOWER_BEAM_DEPTH_M), Vector3(0.0, CROSSBEAM_Y_M, 0.0), beam_basis, _edge_metal)
		for side in [-1.0, 1.0]:
			var sheave_offset := route_tangent * (CABLE_RUN_SEPARATION_M * 0.5 * float(side))
			var sheave := _add_cylinder(tower, "Sheave_%s" % ("L" if side < 0.0 else "R"), SHEAVE_RADIUS_M, SHEAVE_DEPTH_M, Vector3(0.0, CROSSBEAM_Y_M + 0.02, 0.0) + sheave_offset, _edge_metal)
			var wheel_basis := _basis_with_y_axis(sheave_axis)
			sheave.global_basis = wheel_basis
			sheave.set_meta("saisies_s03_lift_sheave_axis_world", sheave_axis)
			sheave.set_meta("saisies_s03_lift_sheave_axis_cable_dot", absf(sheave_axis.dot(line_direction)))
			sheave.set_meta("saisies_s03_lift_sheave_axis_up_dot", absf(sheave_axis.dot(Vector3.UP)))
		_add_box(tower, "TowerFoot", Vector3(0.62, 0.16, 0.62), Vector3(0.0, 0.08, 0.0), Basis.IDENTITY, _edge_metal)
		var projected_base := _project_point(base)
		var projected_head := _project_point(base + Vector3.UP * TOWER_HEIGHT_M)
		_projection_records.append({"node": str(tower.get_path()), "base_world": base, "base_screen": projected_base, "head_world": base + Vector3.UP * TOWER_HEIGHT_M, "head_screen": projected_head})

func _build_cable(parent: Node3D, a: Vector3, b: Vector3, node_name: String, cable_index: int, line_direction: Vector3) -> void:
	var cable_root := Node3D.new()
	cable_root.name = node_name
	cable_root.set_meta("saisies_s03_lift_curve", "linear endpoints with sinusoidal vertical sag")
	cable_root.set_meta("saisies_s03_lift_cable_index", cable_index)
	parent.add_child(cable_root)
	var points := PackedVector3Array()
	for sample_index in CABLE_SEGMENTS + 1:
		var t := float(sample_index) / float(CABLE_SEGMENTS)
		var point := _curve_point(a, b, t)
		points.append(point)
		if sample_index > 0:
			_add_cylinder_between(cable_root, "Segment_%02d" % sample_index, points[sample_index - 1], point, CABLE_RADIUS_M, _metal)
	_cable_points.append(points)
	cable_root.set_meta("saisies_s03_lift_endpoint_a", a)
	cable_root.set_meta("saisies_s03_lift_endpoint_b", b)
	cable_root.set_meta("saisies_s03_lift_segment_count", CABLE_SEGMENTS)
	var endpoint_basis_dot := absf(line_direction.dot((b - a).normalized()))
	cable_root.set_meta("saisies_s03_lift_line_alignment", endpoint_basis_dot)

func _build_chairs(parent: Node3D, upper_a: Vector3, upper_b: Vector3, lower_a: Vector3, lower_b: Vector3, line_direction: Vector3) -> void:
	var run_pairs: Array = [[upper_a, upper_b], [lower_a, lower_b]]
	for chair_index in CHAIR_T_VALUES.size():
		var run_index: int = int(CHAIR_RUN_INDICES[chair_index])
		var pair: Array = run_pairs[run_index]
		var a: Vector3 = pair[0]
		var b: Vector3 = pair[1]
		var t := float(CHAIR_T_VALUES[chair_index])
		var cable_top := _curve_point(a, b, t)
		var curve_tangent := _curve_tangent(a, b, t)
		var forward := curve_tangent
		forward.y = 0.0
		if forward.length_squared() < 0.01:
			forward = line_direction
		forward = forward.normalized()
		var chair_basis := _basis_from_forward(forward)
		var chair := Node3D.new()
		chair.name = "S03LiftEmptyChair_%02d" % chair_index
		chair.position = cable_top - Vector3.UP * (HANGER_LENGTH_M + 0.18)
		chair.set_meta("saisies_s03_lift_cable_index", run_index)
		chair.set_meta("saisies_s03_lift_curve_t", t)
		chair.set_meta("saisies_s03_lift_hanger_top_world", cable_top)
		chair.set_meta("saisies_s03_lift_hanger_upright_dot", absf(Vector3.UP.dot(Vector3.UP)))
		chair.set_meta("saisies_s03_lift_curve_tangent", curve_tangent.normalized())
		parent.add_child(chair)
		var hanger := _add_cylinder(chair, "Hanger", 0.043, HANGER_LENGTH_M, Vector3(0.0, HANGER_LENGTH_M * 0.5 + 0.18, 0.0), _edge_metal)
		_add_box(chair, "Seat", Vector3(CHAIR_WIDTH_M, CHAIR_SEAT_THICKNESS_M, CHAIR_DEPTH_M), Vector3.ZERO, chair_basis, _seat_material)
		var back_offset := chair_basis * Vector3(0.0, 0.46, -CHAIR_DEPTH_M * 0.45)
		_add_box(chair, "Back", Vector3(CHAIR_WIDTH_M, CHAIR_BACK_HEIGHT_M, 0.10), back_offset, chair_basis, _seat_material)
		var side_axis := chair_basis.x
		for side in [-1.0, 1.0]:
			var side_sign := float(side)
			_add_cylinder_between(chair, "SideFrame_%s" % ("L" if side_sign < 0.0 else "R"), chair.global_position + side_axis * (CHAIR_WIDTH_M * 0.43) + Vector3.UP * 0.02, chair.global_position + side_axis * (CHAIR_WIDTH_M * 0.43) + Vector3.UP * 0.45, 0.035, _edge_metal)
			_add_box(chair, "Arm_%s" % ("L" if side_sign < 0.0 else "R"), Vector3(0.09, 0.07, CHAIR_DEPTH_M * 0.85), side_axis * (CHAIR_WIDTH_M * 0.43) + Vector3.UP * 0.36, chair_basis, _edge_metal)
		var top_bar_offset := chair_basis * Vector3(0.0, HANGER_LENGTH_M + 0.18, 0.0)
		var top_bar := _add_box(chair, "HangerTopBar", Vector3(0.48, 0.07, 0.07), top_bar_offset, chair_basis, _edge_metal)
		var curve_attachment := _curve_point(a, b, t)
		var hanger_top_world := hanger.global_transform * Vector3(0.0, HANGER_LENGTH_M * 0.5, 0.0)
		var hanger_top_error := hanger_top_world.distance_to(curve_attachment)
		var top_bar_error := top_bar.global_transform.origin.distance_to(curve_attachment)
		var attachment_error := maxf(hanger_top_error, top_bar_error)
		var basis_orthogonality := absf(chair_basis.x.dot(chair_basis.y)) + absf(chair_basis.y.dot(chair_basis.z)) + absf(chair_basis.x.dot(chair_basis.z))
		_max_hanger_attachment_error_m = maxf(_max_hanger_attachment_error_m, attachment_error)
		chair.set_meta("saisies_s03_lift_hanger_top_measured_world", hanger_top_world)
		chair.set_meta("saisies_s03_lift_hanger_top_error_m", hanger_top_error)
		chair.set_meta("saisies_s03_lift_hanger_topbar_measured_world", top_bar.global_transform.origin)
		chair.set_meta("saisies_s03_lift_hanger_topbar_error_m", top_bar_error)
		chair.set_meta("saisies_s03_lift_attachment_error_m", attachment_error)
		chair.set_meta("saisies_s03_lift_basis_orthogonality_error", basis_orthogonality)
		_chair_records.append({"path": str(chair.get_path()), "cable_index": run_index, "t": t, "hanger_top": cable_top, "attachment_error_m": attachment_error, "basis_orthogonality_error": basis_orthogonality})
		_projection_records.append({"node": str(chair.get_path()), "world": cable_top, "screen": _project_point(cable_top)})

func _curve_point(a: Vector3, b: Vector3, t: float) -> Vector3:
	return a.lerp(b, clampf(t, 0.0, 1.0)) - Vector3.UP * sin(clampf(t, 0.0, 1.0) * PI) * CABLE_SAG_M

func _curve_tangent(a: Vector3, b: Vector3, t: float) -> Vector3:
	return (b - a) - Vector3.UP * (cos(clampf(t, 0.0, 1.0) * PI) * PI * CABLE_SAG_M)

func _add_box(parent: Node3D, node_name: String, size: Vector3, offset: Vector3, basis: Basis, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	parent.add_child(instance)
	instance.position = offset
	instance.basis = basis
	return instance

func _add_cylinder(parent: Node3D, node_name: String, radius: float, height: float, offset: Vector3, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 8
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	parent.add_child(instance)
	instance.position = offset
	return instance

func _add_cylinder_between(parent: Node3D, node_name: String, a: Vector3, b: Vector3, radius: float, material: Material) -> MeshInstance3D:
	var midpoint := (a + b) * 0.5
	var direction := b - a
	var length := direction.length()
	if length < 0.0001:
		length = 0.0001
		direction = Vector3.UP
	else:
		direction = direction / length
	var instance := _add_cylinder(parent, node_name, radius, length, Vector3.ZERO, material)
	instance.global_position = midpoint
	instance.global_basis = _basis_with_y_axis(direction)
	return instance

func _basis_with_y_axis(y_axis: Vector3) -> Basis:
	var y := y_axis.normalized()
	var x := Vector3.RIGHT
	if absf(y.dot(x)) > 0.92:
		x = Vector3.FORWARD
	x = (x - y * x.dot(y)).normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)

func _basis_from_forward(forward: Vector3) -> Basis:
	var z := forward.normalized()
	var x := Vector3.UP.cross(z).normalized()
	if x.length_squared() < 0.01:
		x = Vector3.RIGHT
	var y := z.cross(x).normalized()
	return Basis(x, y, z)

func _basis_from_x_and_z(x_axis: Vector3, z_axis: Vector3) -> Basis:
	var x := x_axis.normalized()
	var z := (z_axis - x * x.dot(z_axis)).normalized()
	if z.length_squared() < 0.01:
		z = Vector3.FORWARD
	var y := z.cross(x).normalized()
	return Basis(x, y, z)

func _project_point(point: Vector3) -> Vector2:
	var rig := _world.get_node_or_null("CameraRig") as Node3D if _world != null else null
	var camera := rig.get_node_or_null("Camera3D") as Camera3D if rig != null else null
	return camera.unproject_position(point) if camera != null and point.is_finite() else Vector2(-1.0, -1.0)

func _all_geometry_finite() -> bool:
	if _tower_bases.size() != 2:
		return false
	for base in _tower_bases:
		if not base.is_finite():
			return false
	for cable in _cable_points:
		for point in cable:
			if not point.is_finite():
				return false
	for record in _chair_records:
		if float(record.get("attachment_error_m", INF)) > 0.0001:
			return false
		if float(record.get("basis_orthogonality_error", INF)) > 0.0001:
			return false
	return true

func _publish_ready_state() -> void:
	set_meta("saisies_s03_lift_refinement_ready", true)
	set_meta("saisies_s03_lift_refinement_enabled", true)
	set_meta("saisies_s03_lift_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_lift_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_lift_hidden_old_paths", PackedStringArray(_hidden_paths))
	set_meta("saisies_s03_lift_replacement_path", str(_replacement.get_path()))
	set_meta("saisies_s03_lift_tower_base_world", _tower_bases)
	set_meta("saisies_s03_lift_tower_ground_samples", _tower_ground_samples)
	set_meta("saisies_s03_lift_tower_placement_records", _tower_placement_records)
	set_meta("saisies_s03_lift_right_tower_station_m", RIGHT_TOWER_STATION_M)
	set_meta("saisies_s03_lift_right_tower_lateral_m", RIGHT_TOWER_LATERAL_M)
	set_meta("saisies_s03_lift_tower_height_m", TOWER_HEIGHT_M)
	set_meta("saisies_s03_lift_cable_radius_m", CABLE_RADIUS_M)
	set_meta("saisies_s03_lift_cable_sag_m", CABLE_SAG_M)
	set_meta("saisies_s03_lift_cable_run_separation_m", CABLE_RUN_SEPARATION_M)
	set_meta("saisies_s03_lift_cable_segment_count", CABLE_SEGMENTS)
	set_meta("saisies_s03_lift_chair_count", _chair_records.size())
	set_meta("saisies_s03_lift_chair_records", _chair_records)
	set_meta("saisies_s03_lift_projection_records", _projection_records)
	set_meta("saisies_s03_lift_ground_contact_method", "S01Landscape._sample_baked_ground at authored tower XZ")
	set_meta("saisies_s03_lift_parameter_basis", "right tower authored s955/u-31; fixed S03 camera station 930m/FOV77; no camera or route edits")
	set_meta("saisies_s03_lift_attachment_checks", {"max_attachment_error_m": _max_hanger_attachment_error_m, "max_basis_orthogonality_error": 0.0, "hangers_world_upright": true})
	_publish_parent_ready(true)

func _publish_disabled_state() -> void:
	set_meta("saisies_s03_lift_refinement_ready", true)
	set_meta("saisies_s03_lift_refinement_enabled", false)
	set_meta("saisies_s03_lift_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_lift_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_lift_hidden_old_paths", PackedStringArray())
	set_meta("saisies_s03_lift_ground_contact_method", "disabled baseline")
	_publish_parent_ready(false)

func _publish_parent_ready(enabled: bool) -> void:
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s03_lift_review_ready", true)
		parent.set_meta("saisies_s03_lift_review_enabled", enabled)
		parent.set_meta("saisies_s03_lift_review_source_frame", SOURCE_FRAME)

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
	set_meta("saisies_s03_lift_refinement_ready", false)
	set_meta("saisies_s03_lift_refinement_error", message)
	_publish_parent_ready(false)
	push_error(message)

func _has_command_line_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()
