extends Node3D

## Bounded S03 direction-sign replacement over the accepted R20 lift review.
##
## The geographic village keeps its authored sign anchors in the frozen world.
## This review hides only the old S03 road signs and adds two small, static 3D
## sign clusters.  Bases use the highest available baked/junction triangle at
## each authored route anchor; no route, camera, building, or terrain geometry
## is changed.

@export var lift_review_path: NodePath = NodePath("../LiftReview")
@export var world_path: NodePath = NodePath("../LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/World")
@export var s01_landscape_path: NodePath = NodePath("../LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/S01Landscape")
@export var junction_path: NodePath = NodePath("../LiftReview/GroundReview/CafeReview/S03Review/S03JunctionRefinement")
@export var chairlift_path: NodePath = NodePath("../LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/World/VillageS01S02/S03Chairlift")
@export var enable_refinement := true

const SOURCE_FRAME := "video/saisies_analysis/acceptance/S03_f001798.png"
const SOURCE_SHA256 := "184ee032aef47be5d52b5d5c6379300dc4dca85054ada0b93ef07ed8ca043e10"
const LEFT_SIGN_STATION_M := 990.0
const LEFT_SIGN_LATERAL_M := 32.0
const RIGHT_SIGN_STATION_M := 955.0
const RIGHT_SIGN_LATERAL_M := -27.0
const BASE_BURY_M := 0.06
const LEFT_POLE_HEIGHT_M := 3.45
const RIGHT_POLE_HEIGHT_M := 3.95
const LEFT_BOARD_COUNT := 5
const RIGHT_BOARD_COUNT := 2
const BOARD_DEPTH_M := 0.075
const BOARD_TIP_RATIO := 0.18

var _lift_review: Node
var _world: Node3D
var _landscape: Node
var _junction: Node
var _junction_pavement: MeshInstance3D
var _chairlift: Node3D
var _route: Node
var _camera: Camera3D
var _replacement: Node3D
var _built := false
var _attempts := 0
var _hidden_paths: Array[String] = []
var _contact_samples: Array[Dictionary] = []
var _base_world: Array[Vector3] = []
var _projection_records: Array[Dictionary] = []
var _board_records: Array[Dictionary] = []
var _post_material: StandardMaterial3D
var _frame_material: StandardMaterial3D
var _face_material: StandardMaterial3D
var _yellow_material: StandardMaterial3D
var _mark_material: StandardMaterial3D

func _ready() -> void:
	process_priority = -100
	if _has_command_line_flag("--s03-signs-off"):
		enable_refinement = false
	call_deferred("_try_build")

func _try_build() -> void:
	if _built:
		return
	_lift_review = get_node_or_null(lift_review_path)
	_world = get_node_or_null(world_path) as Node3D
	_landscape = get_node_or_null(s01_landscape_path)
	_junction = get_node_or_null(junction_path)
	_chairlift = get_node_or_null(chairlift_path) as Node3D
	_route = _world.get_node_or_null("Route") if _world != null else null
	var rig := _world.get_node_or_null("CameraRig") as Node3D if _world != null else null
	_camera = rig.get_node_or_null("Camera3D") as Camera3D if rig != null else null
	if _lift_review == null or _world == null or _landscape == null or _junction == null or _chairlift == null or _route == null:
		_retry("S03 signs dependencies are incomplete")
		return
	if not bool(_lift_review.get_meta("saisies_s03_lift_review_ready", false)):
		_retry("S03 signs are waiting for frame-wise R20 lift readiness")
		return
	if not _landscape.has_method("_sample_baked_ground"):
		_fail_and_hold("S03 signs require S01Landscape._sample_baked_ground")
		return
	_junction_pavement = _junction.find_child("S03JunctionPavement", true, false) as MeshInstance3D
	if not enable_refinement:
		_publish_disabled_state()
		_built = true
		return
	if not _build_candidate():
		_fail_and_hold("S03 signs could not build finite supported sign clusters")
		return
	_publish_ready_state()
	_built = true

func _build_candidate() -> bool:
	_hidden_paths.clear()
	_contact_samples.clear()
	_base_world.clear()
	_projection_records.clear()
	_board_records.clear()
	_hide_old_signs(_chairlift)
	if not _route.has_method("pos_at") or not _route.has_method("left_at") or not _route.has_method("tangent_at"):
		return false
	var left_contact := _sample_sign_contact(LEFT_SIGN_STATION_M, LEFT_SIGN_LATERAL_M)
	var right_contact := _sample_sign_contact(RIGHT_SIGN_STATION_M, RIGHT_SIGN_LATERAL_M)
	if not bool(left_contact.get("ok", false)) or not bool(right_contact.get("ok", false)):
		return false
	var left_base: Vector3 = left_contact["position"]
	var right_base: Vector3 = right_contact["position"]
	if not left_base.is_finite() or not right_base.is_finite():
		return false
	_base_world.append(left_base)
	_base_world.append(right_base)
	_contact_samples.append(left_contact)
	_contact_samples.append(right_contact)
	_replacement = Node3D.new()
	_replacement.name = "S03SignsRefinementCandidate"
	_replacement.set_meta("saisies_s03_signs_owner", "S03Chairlift/S03DirectionSign_* and S03RoadBoards")
	add_child(_replacement)
	_make_materials()
	var left_cluster := _build_cluster(_replacement, "S03SignsCluster_Left", left_base, LEFT_SIGN_STATION_M, LEFT_SIGN_LATERAL_M, LEFT_POLE_HEIGHT_M, LEFT_BOARD_COUNT, 1.75, 0.30, [1.0, -1.0, 1.0, -1.0, 1.0], false)
	var right_cluster := _build_cluster(_replacement, "S03SignsCluster_Right", right_base, RIGHT_SIGN_STATION_M, RIGHT_SIGN_LATERAL_M, RIGHT_POLE_HEIGHT_M, RIGHT_BOARD_COUNT, 3.85, 0.34, [-1.0, 1.0], true)
	if left_cluster == null or right_cluster == null:
		return false
	if _board_records.size() != LEFT_BOARD_COUNT + RIGHT_BOARD_COUNT + 1:
		return false
	return _all_geometry_finite()

func _build_cluster(parent: Node3D, cluster_name: String, base: Vector3, station: float, lateral: float, pole_height: float, board_count: int, board_length: float, board_height: float, directions: Array, right_cluster: bool) -> Node3D:
	var cluster := Node3D.new()
	cluster.name = cluster_name
	cluster.position = base - Vector3.UP * BASE_BURY_M
	cluster.set_meta("saisies_s03_signs_station_m", station)
	cluster.set_meta("saisies_s03_signs_lateral_m", lateral)
	cluster.set_meta("saisies_s03_signs_base_world", base)
	cluster.set_meta("saisies_s03_signs_base_burial_m", BASE_BURY_M)
	cluster.set_meta("saisies_s03_signs_ground_sample", _contact_samples[0 if not right_cluster else 1])
	parent.add_child(cluster)
	var pole := _add_cylinder(cluster, "Pole", 0.055 if not right_cluster else 0.06, pole_height, Vector3(0.0, pole_height * 0.5, 0.0), _post_material)
	pole.set_meta("saisies_s03_signs_world_upright", true)
	var left_axis := Vector3(_route.call("left_at", station))
	left_axis.y = 0.0
	if left_axis.length_squared() < 0.01:
		return null
	left_axis = left_axis.normalized()
	var board_basis := _basis_from_x_and_y(left_axis, Vector3.UP)
	var board_centers: Array[float] = []
	if right_cluster:
		board_centers = [2.55, 3.08]
	else:
		board_centers = [1.52, 1.91, 2.30, 2.69, 3.08]
	for index in board_count:
		var y := board_centers[index]
		var direction := float(directions[index])
		var material := _face_material
		var board := _add_arrow_board(cluster, "DirectionBoard_%02d" % index, board_length, board_height, board_basis, y, direction, material, _frame_material, index, right_cluster)
		if board == null:
			return null
		_board_records.append({
			"cluster": cluster_name,
			"name": board.name,
			"index": index,
			"station_m": station,
			"lateral_m": lateral,
			"center_world": board.global_position,
			"center_screen": _project_point(board.global_position),
			"height_m": y,
			"length_m": board_length,
			"direction_sign": direction,
		})
	if right_cluster:
		var marker_basis := _basis_from_x_and_y(left_axis, Vector3.UP)
		var marker := _add_arrow_board(cluster, "YellowRouteMarker", 1.15, 0.24, marker_basis, 3.62, -1.0, _yellow_material, _frame_material, board_count, true)
		if marker == null:
			return null
		_board_records.append({
			"cluster": cluster_name,
			"name": marker.name,
			"index": board_count,
			"kind": "yellow_route_marker",
			"station_m": station,
			"lateral_m": lateral,
			"center_world": marker.global_position,
			"center_screen": _project_point(marker.global_position),
		})
	_projection_records.append({
		"cluster": cluster_name,
		"base_world": base,
		"base_screen": _project_point(base),
		"pole_top_world": base + Vector3.UP * pole_height,
		"pole_top_screen": _project_point(base + Vector3.UP * pole_height),
	})
	return cluster

func _add_arrow_board(parent: Node3D, node_name: String, length: float, height: float, basis: Basis, y: float, direction: float, face_material: Material, frame_material: Material, index: int, right_cluster: bool) -> Node3D:
	var board := Node3D.new()
	board.name = node_name
	board.position = Vector3(0.0, y, 0.0)
	board.basis = basis if direction >= 0.0 else _basis_from_x_and_y(-basis.x, Vector3.UP)
	parent.add_child(board)
	var outer := MeshInstance3D.new()
	outer.name = "ArrowFrame"
	outer.mesh = _make_arrow_mesh(length, height, BOARD_DEPTH_M, BOARD_TIP_RATIO)
	outer.material_override = frame_material
	board.add_child(outer)
	var inner := MeshInstance3D.new()
	inner.name = "ArrowFace"
	inner.mesh = _make_arrow_mesh(length * 0.94, height * 0.84, BOARD_DEPTH_M * 0.64, BOARD_TIP_RATIO)
	inner.material_override = face_material
	var face_z_sign := -1.0 if direction >= 0.0 else 1.0
	inner.position = Vector3(0.0, 0.0, face_z_sign * BOARD_DEPTH_M * 0.56)
	board.add_child(inner)
	_add_marking_strips(board, length * 0.48, height, face_z_sign * BOARD_DEPTH_M * 0.91)
	board.set_meta("saisies_s03_signs_board_height_m", y)
	board.set_meta("saisies_s03_signs_board_length_m", length)
	board.set_meta("saisies_s03_signs_arrow_direction", direction)
	board.set_meta("saisies_s03_signs_board_index", index)
	board.set_meta("saisies_s03_signs_right_cluster", right_cluster)
	return board

func _add_marking_strips(parent: Node3D, strip_length: float, board_height: float, front_z: float) -> void:
	var strip_material := _mark_material
	for index in 2:
		var mesh := BoxMesh.new()
		mesh.size = Vector3(strip_length * (0.82 if index == 0 else 0.52), 0.022, 0.014)
		var strip := MeshInstance3D.new()
		strip.name = "TextHint_%02d" % index
		strip.mesh = mesh
		strip.material_override = strip_material
		strip.position = Vector3(-strip_length * 0.05, (0.055 if index == 0 else -0.045) * board_height / 0.30, front_z)
		parent.add_child(strip)

func _make_arrow_mesh(length: float, height: float, depth: float, tip_ratio: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_h := height * 0.5
	var half_l := length * 0.5
	var body_end := half_l - length * tip_ratio
	var front_z := -depth * 0.5
	var back_z := depth * 0.5
	var front: Array = [
		Vector3(-half_l, -half_h, front_z), Vector3(body_end, -half_h, front_z),
		Vector3(body_end, half_h, front_z), Vector3(-half_l, half_h, front_z),
		Vector3(half_l, 0.0, front_z)
	]
	var back: Array = [
		Vector3(-half_l, -half_h, back_z), Vector3(body_end, -half_h, back_z),
		Vector3(body_end, half_h, back_z), Vector3(-half_l, half_h, back_z),
		Vector3(half_l, 0.0, back_z)
	]
	# The outline runs lower-left -> lower-body -> tip -> upper-body -> upper-left.
	# Keeping that order avoids the crossed side faces that a rectangular loop
	# would make around the pointed end.
	_add_triangle(surface, front[0], front[1], front[4])
	_add_triangle(surface, front[0], front[4], front[2])
	_add_triangle(surface, front[0], front[2], front[3])
	_add_triangle(surface, back[4], back[1], back[0])
	_add_triangle(surface, back[2], back[4], back[0])
	_add_triangle(surface, back[3], back[2], back[0])
	var outline: Array[int] = [0, 1, 4, 2, 3]
	for index in outline.size():
		var current: int = outline[index]
		var next: int = outline[(index + 1) % outline.size()]
		_add_triangle(surface, front[current], back[current], back[next])
		_add_triangle(surface, front[current], back[next], front[next])
	surface.generate_normals()
	return surface.commit()

func _add_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	surface.add_vertex(a)
	surface.add_vertex(b)
	surface.add_vertex(c)

func _sample_sign_contact(station: float, lateral: float) -> Dictionary:
	var route_position := Vector3(_route.call("pos_at", station))
	var route_left := Vector3(_route.call("left_at", station))
	route_left.y = 0.0
	if route_left.length_squared() < 0.01 or not route_position.is_finite():
		return {"ok": false}
	var target := route_position + route_left.normalized() * lateral
	var candidates: Array[Dictionary] = []
	if _landscape.has_method("_sample_ground"):
		var overlay_variant: Variant = _landscape.call("_sample_ground", Vector2(target.x, target.z))
		if overlay_variant is Dictionary and overlay_variant.has("position") and overlay_variant["position"] is Vector3:
			var overlay: Dictionary = overlay_variant.duplicate(true)
			if (overlay["position"] as Vector3).is_finite():
				overlay["source"] = String(overlay.get("source", "visible_overlay_ground"))
				candidates.append(overlay)
	var baked_variant: Variant = _landscape.call("_sample_baked_ground", Vector2(target.x, target.z))
	if baked_variant is Dictionary and baked_variant.has("position") and baked_variant["position"] is Vector3:
		var baked: Dictionary = baked_variant.duplicate(true)
		if (baked["position"] as Vector3).is_finite():
			baked["source"] = String(baked.get("source", "baked_mesh_triangle"))
			candidates.append(baked)
	if _junction_pavement != null and _junction_pavement.mesh != null:
		var pavement := _sample_mesh_surface(_junction_pavement, Vector2(target.x, target.z))
		if not pavement.is_empty():
			candidates.append(pavement)
	if candidates.is_empty():
		var fallback := Vector3(_route.call("world_at", station, lateral, 0.0))
		if fallback.is_finite():
			candidates.append({"position": fallback, "source": "Route.world_at_fallback"})
	if candidates.is_empty():
		return {"ok": false}
	var chosen: Dictionary = candidates[0]
	for candidate in candidates:
		if float((candidate["position"] as Vector3).y) > float((chosen["position"] as Vector3).y):
			chosen = candidate
	var chosen_position: Vector3 = chosen["position"]
	chosen["ok"] = chosen_position.is_finite()
	chosen["station_m"] = station
	chosen["lateral_m"] = lateral
	chosen["requested_xz"] = Vector2(target.x, target.z)
	chosen["candidate_sources"] = PackedStringArray(candidates.map(func(item: Dictionary) -> String: return String(item.get("source", "unknown"))))
	return chosen

func _sample_mesh_surface(instance: MeshInstance3D, point: Vector2) -> Dictionary:
	var mesh := instance.mesh
	var best_y := -INF
	var best_triangle := -1
	var found := false
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var triangle_count := indices.size() / 3 if not indices.is_empty() else vertices.size() / 3
		for triangle in triangle_count:
			var i0 := indices[triangle * 3] if not indices.is_empty() else triangle * 3
			var i1 := indices[triangle * 3 + 1] if not indices.is_empty() else triangle * 3 + 1
			var i2 := indices[triangle * 3 + 2] if not indices.is_empty() else triangle * 3 + 2
			var a: Vector3 = instance.global_transform * vertices[i0]
			var b: Vector3 = instance.global_transform * vertices[i1]
			var c: Vector3 = instance.global_transform * vertices[i2]
			var height := _triangle_height(point, a, b, c)
			if is_finite(height) and (not found or height > best_y):
				found = true
				best_y = height
				best_triangle = triangle * 3
	if not found:
		return {}
	return {"position": Vector3(point.x, best_y, point.y), "source": "S03JunctionPavement.mesh_triangle", "triangle_start": best_triangle}

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

func _make_materials() -> void:
	_post_material = _new_material(Color(0.27, 0.29, 0.29, 1.0), 0.82, 0.35)
	_frame_material = _new_material(Color(0.25, 0.27, 0.27, 1.0), 0.82, 0.12)
	_face_material = _new_material(Color(0.73, 0.75, 0.74, 1.0), 0.86, 0.03)
	_yellow_material = _new_material(Color(0.68, 0.53, 0.13, 1.0), 0.8, 0.04)
	_mark_material = _new_material(Color(0.18, 0.20, 0.19, 1.0), 0.88, 0.02)

func _new_material(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _add_cylinder(parent: Node3D, node_name: String, radius: float, height: float, offset: Vector3, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 10
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = offset
	parent.add_child(instance)
	return instance

func _basis_from_x_and_y(x_axis: Vector3, y_axis: Vector3) -> Basis:
	var x := x_axis.normalized()
	var y := y_axis.normalized()
	var z := x.cross(y).normalized()
	if z.length_squared() < 0.01:
		z = Vector3.FORWARD
	y = z.cross(x).normalized()
	return Basis(x, y, z)

func _hide_old_signs(parent: Node) -> void:
	for child in parent.get_children():
		var node := child as Node
		if node == null:
			continue
		var child_name := String(node.name)
		if child_name.begins_with("S03DirectionSign_") or child_name == "S03RoadBoards" or child_name == "S03RoadDirectionBoards":
			_hide_visual_subtree(node)
		else:
			_hide_old_signs(node)

func _hide_visual_subtree(node: Node) -> void:
	var node_3d := node as Node3D
	if node_3d != null:
		node_3d.visible = false
		_hidden_paths.append(str(node.get_path()))
	for child in node.get_children():
		_hide_visual_subtree(child)

func _project_point(point: Vector3) -> Vector2:
	return _camera.unproject_position(point) if _camera != null and point.is_finite() else Vector2(-1.0, -1.0)

func _all_geometry_finite() -> bool:
	if _base_world.size() != 2 or _contact_samples.size() != 2:
		return false
	for base in _base_world:
		if not base.is_finite():
			return false
	for record in _contact_samples:
		if not bool(record.get("ok", false)) or not (record.get("position", Vector3.INF) as Vector3).is_finite():
			return false
	for record in _board_records:
		if not (record.get("center_world", Vector3.INF) as Vector3).is_finite():
			return false
		var screen: Vector2 = record.get("center_screen", Vector2(-1.0, -1.0))
		if not screen.is_finite():
			return false
	return true

func _publish_ready_state() -> void:
	set_meta("saisies_s03_signs_refinement_ready", true)
	set_meta("saisies_s03_signs_refinement_enabled", true)
	set_meta("saisies_s03_signs_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_signs_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_signs_hidden_old_paths", PackedStringArray(_hidden_paths))
	set_meta("saisies_s03_signs_replacement_path", str(_replacement.get_path()))
	set_meta("saisies_s03_signs_cluster_paths", PackedStringArray([str(_replacement.get_node("S03SignsCluster_Left").get_path()), str(_replacement.get_node("S03SignsCluster_Right").get_path())]))
	set_meta("saisies_s03_signs_base_world", _base_world)
	set_meta("saisies_s03_signs_contact_samples", _contact_samples)
	set_meta("saisies_s03_signs_ground_contact_method", "highest of S01Landscape._sample_baked_ground and S03JunctionPavement mesh triangle")
	set_meta("saisies_s03_signs_board_counts", {"left_direction_boards": LEFT_BOARD_COUNT, "right_direction_boards": RIGHT_BOARD_COUNT, "right_yellow_route_marker": 1, "total_boards": _board_records.size()})
	set_meta("saisies_s03_signs_board_records", _board_records)
	set_meta("saisies_s03_signs_projection_records", _projection_records)
	set_meta("saisies_s03_signs_base_burial_m", BASE_BURY_M)
	set_meta("saisies_s03_signs_left_anchor", {"station_m": LEFT_SIGN_STATION_M, "lateral_m": LEFT_SIGN_LATERAL_M})
	set_meta("saisies_s03_signs_right_anchor", {"station_m": RIGHT_SIGN_STATION_M, "lateral_m": RIGHT_SIGN_LATERAL_M})
	set_meta("saisies_s03_signs_poles_world_upright", true)
	_publish_parent_ready(true)

func _publish_disabled_state() -> void:
	set_meta("saisies_s03_signs_refinement_ready", true)
	set_meta("saisies_s03_signs_refinement_enabled", false)
	set_meta("saisies_s03_signs_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_signs_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_signs_hidden_old_paths", PackedStringArray())
	set_meta("saisies_s03_signs_board_counts", {"left_direction_boards": 0, "right_direction_boards": 0, "right_yellow_route_marker": 0, "total_boards": 0})
	set_meta("saisies_s03_signs_ground_contact_method", "disabled baseline")
	_publish_parent_ready(false)

func _publish_parent_ready(enabled: bool) -> void:
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s03_signs_review_ready", true)
		parent.set_meta("saisies_s03_signs_review_enabled", enabled)
		parent.set_meta("saisies_s03_signs_review_source_frame", SOURCE_FRAME)

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
	set_meta("saisies_s03_signs_refinement_ready", false)
	set_meta("saisies_s03_signs_refinement_error", message)
	_publish_parent_ready(false)
	push_error(message)

func _has_command_line_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()
