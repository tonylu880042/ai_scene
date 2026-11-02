extends Node3D

## Bounded S03 right-side planter replacement over the accepted R21 signs view.
##
## Only the three authored S03RightFlowerbox nodes are hidden in this review.
## Seven small planters follow the accepted screen-right junction rail, with each box
## fitted against the highest visible baked/overlay/pavement surface at its four
## corners.  The route, rail, camera, buildings, signs, lift, and terrain stay
## owned by the inherited scene.

@export var signs_review_path: NodePath = NodePath("../SignsReview")
@export var world_path: NodePath = NodePath("../SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/World")
@export var s01_landscape_path: NodePath = NodePath("../SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/S01Landscape")
@export var junction_path: NodePath = NodePath("../SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S03JunctionRefinement")
@export var chairlift_path: NodePath = NodePath("../SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/World/VillageS01S02/S03Chairlift")
@export var enable_refinement := true

const SOURCE_FRAME := "video/saisies_analysis/acceptance/S03_f001798.png"
const SOURCE_SHA256 := "184ee032aef47be5d52b5d5c6379300dc4dca85054ada0b93ef07ed8ca043e10"
const PLANTER_STATIONS := [954.0, 956.0, 958.0, 960.0, 962.0, 964.0, 966.0]
const RAIL_SIDE := -1.0
const RAIL_NODE_NAME := "S03JunctionLeftEdgeRail"
const RAIL_OUTWARD_OFFSET_M := 0.35
const PLANTER_INSET_FROM_RAIL_M := 1.50
const BASE_BURY_M := 0.04
const BODY_LENGTH_M := 1.45
const BODY_DEPTH_M := 0.58
const BODY_HEIGHT_M := 0.58
const BODY_BOTTOM_CLEARANCE_M := 0.02
const SOIL_HEIGHT_M := 0.07
const FLOWER_TOP_M := 0.98
const FLOWERS_PER_PLANTER := 24

var _signs_review: Node
var _world: Node3D
var _landscape: Node
var _junction: Node
var _junction_pavement: MeshInstance3D
var _chairlift: Node3D
var _route: Node
var _camera: Camera3D
var _rail_root: Node3D
var _replacement: Node3D
var _built := false
var _attempts := 0
var _hidden_paths: Array[String] = []
var _contact_records: Array[Dictionary] = []
var _projection_records: Array[Dictionary] = []
var _rail_records: Array[Dictionary] = []
var _wood_material: StandardMaterial3D
var _soil_material: StandardMaterial3D
var _leaf_material: StandardMaterial3D
var _pink_material: StandardMaterial3D
var _magenta_material: StandardMaterial3D
var _pale_flower_material: StandardMaterial3D
var _leaf_mesh: SphereMesh
var _flower_mesh: SphereMesh
var _droop_mesh: SphereMesh

func _ready() -> void:
	process_priority = -80
	if _has_command_line_flag("--s03-flowers-off"):
		enable_refinement = false
	call_deferred("_try_build")

func _try_build() -> void:
	if _built:
		return
	_signs_review = get_node_or_null(signs_review_path)
	_world = get_node_or_null(world_path) as Node3D
	_landscape = get_node_or_null(s01_landscape_path)
	_junction = get_node_or_null(junction_path)
	_chairlift = get_node_or_null(chairlift_path) as Node3D
	_route = _world.get_node_or_null("Route") if _world != null else null
	var rig := _world.get_node_or_null("CameraRig") as Node3D if _world != null else null
	_camera = rig.get_node_or_null("Camera3D") as Camera3D if rig != null else null
	if _signs_review == null or _world == null or _landscape == null or _junction == null or _chairlift == null or _route == null or _camera == null:
		_retry("S03 flowers dependencies are incomplete")
		return
	if not bool(_signs_review.get_meta("saisies_s03_signs_review_ready", false)):
		_retry("S03 flowers are waiting for frame-wise R21 signs readiness")
		return
	if not _landscape.has_method("_sample_baked_ground"):
		_fail_and_hold("S03 flowers require S01Landscape._sample_baked_ground")
		return
	if not _junction.has_method("_edge_half_width"):
		_fail_and_hold("S03 flowers require the accepted junction rail geometry")
		return
	_junction_pavement = _junction.find_child("S03JunctionPavement", true, false) as MeshInstance3D
	_rail_root = _junction.find_child(RAIL_NODE_NAME, true, false) as Node3D
	if _rail_root == null:
		_fail_and_hold("S03 flowers could not resolve the right junction rail")
		return
	if not enable_refinement:
		_publish_disabled_state()
		_built = true
		return
	if not _build_candidate():
		_fail_and_hold("S03 flowers could not build finite supported planters")
		return
	_publish_ready_state()
	_built = true

func _build_candidate() -> bool:
	_hidden_paths.clear()
	_contact_records.clear()
	_projection_records.clear()
	_rail_records.clear()
	_hide_old_flowerboxes(_chairlift)
	_replacement = Node3D.new()
	_replacement.name = "S03FlowersRefinementCandidate"
	_replacement.set_meta("saisies_s03_flowers_owner", "S03Chairlift/S03RightFlowerbox_00..02")
	add_child(_replacement)
	_make_materials()
	var planter_index := 0
	for station_variant in PLANTER_STATIONS:
		var station := float(station_variant)
		var planter := _build_planter(_replacement, planter_index, station)
		if planter == null:
			return false
		planter_index += 1
	if planter_index != PLANTER_STATIONS.size() or _contact_records.size() != PLANTER_STATIONS.size():
		return false
	return _all_geometry_finite()

func _build_planter(parent: Node3D, index: int, station: float) -> Node3D:
	var tangent := Vector3(_route.call("tangent_at", station))
	var left := Vector3(_route.call("left_at", station))
	tangent.y = 0.0
	left.y = 0.0
	if tangent.length_squared() < 0.01 or left.length_squared() < 0.01:
		return null
	tangent = tangent.normalized()
	left = left.normalized()
	var half_width := float(_junction.call("_edge_half_width", station))
	var rail_lateral := half_width * RAIL_SIDE + RAIL_OUTWARD_OFFSET_M * RAIL_SIDE
	var planter_lateral := rail_lateral - PLANTER_INSET_FROM_RAIL_M * RAIL_SIDE
	var route_position := Vector3(_route.call("pos_at", station))
	var center_xz := route_position + left * planter_lateral
	var corner_samples: Array[Dictionary] = []
	var max_ground_y := -INF
	var half_length := BODY_LENGTH_M * 0.5
	var half_depth := BODY_DEPTH_M * 0.5
	for along_sign in [-1.0, 1.0]:
		for side_sign in [-1.0, 1.0]:
			var corner_xz := center_xz + tangent * (half_length * float(along_sign)) + left * (half_depth * float(side_sign))
			var sampled := _sample_visible_ground(Vector2(corner_xz.x, corner_xz.z))
			if not bool(sampled.get("ok", false)):
				return null
			corner_samples.append(sampled)
			max_ground_y = maxf(max_ground_y, float((sampled["position"] as Vector3).y))
	if not is_finite(max_ground_y):
		return null
	var center_sample := _sample_visible_ground(Vector2(center_xz.x, center_xz.z))
	if not bool(center_sample.get("ok", false)):
		return null
	var base_world := Vector3(center_xz.x, max_ground_y, center_xz.z)
	var planter := Node3D.new()
	planter.name = "S03FlowerPlanter_%02d" % index
	planter.position = base_world - Vector3.UP * BASE_BURY_M
	planter.basis = _basis_from_tangent(tangent)
	planter.set_meta("saisies_s03_flowers_station_m", station)
	planter.set_meta("saisies_s03_flowers_lateral_m", planter_lateral)
	planter.set_meta("saisies_s03_flowers_rail_lateral_m", rail_lateral)
	planter.set_meta("saisies_s03_flowers_base_world", base_world)
	planter.set_meta("saisies_s03_flowers_box_dimensions_m", Vector3(BODY_LENGTH_M, BODY_HEIGHT_M, BODY_DEPTH_M))
	planter.set_meta("saisies_s03_flowers_count", FLOWERS_PER_PLANTER)
	planter.set_meta("saisies_s03_flowers_corner_samples", corner_samples)
	planter.set_meta("saisies_s03_flowers_center_sample", center_sample)
	parent.add_child(planter)
	var box := _add_box(planter, "BoxBody", Vector3(BODY_LENGTH_M, BODY_HEIGHT_M, BODY_DEPTH_M), Vector3(0.0, BASE_BURY_M + BODY_BOTTOM_CLEARANCE_M + BODY_HEIGHT_M * 0.5, 0.0), _wood_material)
	box.set_meta("saisies_s03_flowers_box_body", true)
	box.set_meta("saisies_s03_flowers_corner_max_ground_y", max_ground_y)
	var body_bottom_y := planter.global_position.y + BASE_BURY_M + BODY_BOTTOM_CLEARANCE_M
	_add_support_feet(planter, corner_samples, body_bottom_y)
	var soil_y := BASE_BURY_M + BODY_BOTTOM_CLEARANCE_M + BODY_HEIGHT_M + SOIL_HEIGHT_M * 0.5
	_add_box(planter, "Soil", Vector3(BODY_LENGTH_M * 0.91, SOIL_HEIGHT_M, BODY_DEPTH_M * 0.80), Vector3(0.0, soil_y, 0.0), _soil_material)
	_build_flower_cluster(planter, index)
	var rail_record := _nearest_rail_post(base_world, station)
	var minimum_clearance := INF
	for sample in corner_samples:
		minimum_clearance = minf(minimum_clearance, body_bottom_y - float((sample["position"] as Vector3).y))
	var record := {
		"index": index,
		"station_m": station,
		"planter_lateral_m": planter_lateral,
		"rail_lateral_m": rail_lateral,
		"base_world": base_world,
		"box_dimensions_m": Vector3(BODY_LENGTH_M, BODY_HEIGHT_M, BODY_DEPTH_M),
		"corner_samples": corner_samples,
		"center_sample": center_sample,
		"max_ground_y": max_ground_y,
		"box_bottom_world_y": body_bottom_y,
		"minimum_corner_clearance_m": minimum_clearance,
		"rail_post": rail_record,
	}
	_contact_records.append(record)
	_projection_records.append({
		"node": str(planter.get_path()),
		"station_m": station,
		"base_world": base_world,
		"base_screen": _project_point(base_world),
		"box_center_world": planter.global_transform * Vector3(0.0, BASE_BURY_M + BODY_BOTTOM_CLEARANCE_M + BODY_HEIGHT_M * 0.5, 0.0),
		"box_center_screen": _project_point(planter.global_transform * Vector3(0.0, BASE_BURY_M + BODY_BOTTOM_CLEARANCE_M + BODY_HEIGHT_M * 0.5, 0.0)),
		"flower_top_world": planter.global_transform * Vector3(0.0, FLOWER_TOP_M, 0.0),
		"flower_top_screen": _project_point(planter.global_transform * Vector3(0.0, FLOWER_TOP_M, 0.0)),
		"base_behind_camera": _camera.is_position_behind(base_world),
		"flower_top_behind_camera": _camera.is_position_behind(planter.global_transform * Vector3(0.0, FLOWER_TOP_M, 0.0)),
	})
	return planter

func _add_support_feet(planter: Node3D, corner_samples: Array[Dictionary], body_bottom_y: float) -> void:
	for corner_index in corner_samples.size():
		var sample := corner_samples[corner_index]
		var sample_position: Vector3 = sample["position"]
		var foot_bottom_y := sample_position.y - 0.02
		var foot_height := maxf(body_bottom_y - foot_bottom_y, 0.025)
		var foot_local_y := (foot_bottom_y + body_bottom_y) * 0.5 - planter.global_position.y
		# The authored corner order is in route tangent/left space, while the
		# planter basis uses tangent and tangent.cross(UP).  Convert the sampled
		# world XZ directly so a support can never swap the two side corners.
		var foot_xz := planter.global_transform.affine_inverse() * Vector3(sample_position.x, planter.global_position.y, sample_position.z)
		var foot := _add_box(planter, "SupportFoot_%02d" % corner_index, Vector3(0.16, foot_height, 0.16), Vector3(foot_xz.x, foot_local_y, foot_xz.z), _wood_material)
		foot.set_meta("saisies_s03_flowers_support_ground_y", sample_position.y)
		foot.set_meta("saisies_s03_flowers_support_top_y", body_bottom_y)
		foot.set_meta("saisies_s03_flowers_support_world_xz", Vector2(sample_position.x, sample_position.z))

func _build_flower_cluster(planter: Node3D, index: int) -> void:
	var leaf_positions := [
		Vector3(-0.46, 0.67, -0.10), Vector3(-0.12, 0.73, 0.13), Vector3(0.22, 0.68, -0.08),
		Vector3(0.48, 0.64, 0.10), Vector3(-0.30, 0.61, 0.20)
	]
	for leaf_index in leaf_positions.size():
		var leaf := MeshInstance3D.new()
		leaf.name = "LeafMass_%02d" % leaf_index
		leaf.mesh = _leaf_mesh
		leaf.material_override = _leaf_material
		leaf.position = leaf_positions[leaf_index]
		leaf.scale = Vector3(0.72, 0.52, 0.62)
		planter.add_child(leaf)
	var small_leaf_positions := [
		Vector3(-0.55, 0.60, 0.12), Vector3(0.10, 0.62, -0.22), Vector3(0.55, 0.58, -0.12)
	]
	for leaf_index in small_leaf_positions.size():
		var small_leaf := MeshInstance3D.new()
		small_leaf.name = "LeafFill_%02d" % leaf_index
		small_leaf.mesh = _leaf_mesh
		small_leaf.material_override = _leaf_material
		small_leaf.position = small_leaf_positions[leaf_index]
		small_leaf.scale = Vector3(0.48, 0.34, 0.44)
		planter.add_child(small_leaf)
	var flower_groups := [
		Vector3(-0.46, 0.78, -0.11), Vector3(-0.23, 0.84, 0.08), Vector3(0.02, 0.80, -0.02),
		Vector3(0.26, 0.86, 0.11), Vector3(0.49, 0.76, -0.07), Vector3(-0.05, 0.89, 0.20)
	]
	var flower_index := 0
	for group_index in flower_groups.size():
		var group_center: Vector3 = flower_groups[group_index]
		for group_flower_index in 4:
			var variant := (index * 7 + group_index * 3 + group_flower_index) % 5
			var phase := float(index * 17 + group_index * 29 + group_flower_index * 47) * 0.37
			var radial := 0.034 + float(variant % 3) * 0.011
			var flower := MeshInstance3D.new()
			flower.name = "Flower_%02d" % flower_index
			flower.mesh = _flower_mesh
			flower.material_override = _pale_flower_material if variant == 4 else (_magenta_material if variant % 3 == 0 else _pink_material)
			flower.position = group_center + Vector3(cos(phase) * radial, -0.012 + float((variant % 3) - 1) * 0.012, sin(phase) * radial)
			var scale_factor := 0.78 + float((variant + group_index) % 4) * 0.08
			flower.scale = Vector3.ONE * scale_factor
			planter.add_child(flower)
			flower_index += 1
	for drop_index in 2:
		var drop := MeshInstance3D.new()
		drop.name = "HangingLeaf_%02d" % drop_index
		drop.mesh = _droop_mesh
		drop.material_override = _leaf_material
		drop.position = Vector3(-0.42 + float(drop_index) * 0.74, 0.55, -0.27 if drop_index == 0 else 0.27)
		drop.scale = Vector3(0.70, 1.0, 0.70)
		planter.add_child(drop)

func _sample_visible_ground(point: Vector2) -> Dictionary:
	var candidates: Array[Dictionary] = []
	if _landscape.has_method("_sample_ground"):
		var visible_variant: Variant = _landscape.call("_sample_ground", point)
		if visible_variant is Dictionary and visible_variant.has("position") and visible_variant["position"] is Vector3:
			var visible: Dictionary = visible_variant.duplicate(true)
			if (visible["position"] as Vector3).is_finite():
				visible["source"] = String(visible.get("source", "visible_overlay_ground"))
				candidates.append(visible)
	var baked_variant: Variant = _landscape.call("_sample_baked_ground", point)
	if baked_variant is Dictionary and baked_variant.has("position") and baked_variant["position"] is Vector3:
		var baked: Dictionary = baked_variant.duplicate(true)
		if (baked["position"] as Vector3).is_finite():
			baked["source"] = String(baked.get("source", "baked_mesh_triangle"))
			candidates.append(baked)
	if _junction_pavement != null and _junction_pavement.mesh != null:
		var pavement := _sample_mesh_surface(_junction_pavement, point)
		if not pavement.is_empty():
			candidates.append(pavement)
	if candidates.is_empty():
		return {"ok": false}
	var chosen: Dictionary = candidates[0]
	for candidate in candidates:
		if float((candidate["position"] as Vector3).y) > float((chosen["position"] as Vector3).y):
			chosen = candidate
	var chosen_position: Vector3 = chosen["position"]
	chosen["ok"] = chosen_position.is_finite()
	var sources := PackedStringArray()
	for candidate in candidates:
		sources.append(String(candidate.get("source", "unknown")))
	chosen["candidate_sources"] = sources
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

func _nearest_rail_post(point: Vector3, station: float) -> Dictionary:
	var best_path := ""
	var best_world := Vector3.INF
	var best_distance := INF
	if _rail_root != null:
		for post in _rail_root.find_children("Post_*", "MeshInstance3D", true, false):
			var node := post as MeshInstance3D
			if node == null:
				continue
			var distance := Vector2(node.global_position.x - point.x, node.global_position.z - point.z).length()
			if distance < best_distance:
				best_distance = distance
				best_path = str(node.get_path())
				best_world = node.global_position
	return {"path": best_path, "world": best_world, "xz_error_m": best_distance, "rail_reference": str(_rail_root.get_path()) + "/Post_*", "station_m": station}

func _make_materials() -> void:
	_wood_material = _new_material(Color(0.18, 0.095, 0.045, 1.0), 0.92, 0.0)
	_soil_material = _new_material(Color(0.09, 0.055, 0.028, 1.0), 1.0, 0.0)
	_leaf_material = _new_material(Color(0.12, 0.27, 0.06, 1.0), 0.92, 0.0)
	_pink_material = _new_material(Color(0.72, 0.10, 0.30, 1.0), 0.86, 0.0)
	_magenta_material = _new_material(Color(0.48, 0.035, 0.21, 1.0), 0.88, 0.0)
	_pale_flower_material = _new_material(Color(0.89, 0.44, 0.53, 1.0), 0.9, 0.0)
	_leaf_mesh = _sphere_mesh(0.34, 0.40)
	_flower_mesh = _sphere_mesh(0.055, 0.10)
	_droop_mesh = _sphere_mesh(0.12, 0.46)

func _new_material(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _sphere_mesh(radius: float, height: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.radial_segments = 6
	mesh.rings = 3
	return mesh

func _add_box(parent: Node3D, node_name: String, size: Vector3, offset: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = offset
	parent.add_child(instance)
	return instance

func _basis_from_tangent(tangent: Vector3) -> Basis:
	var x := tangent.normalized()
	var y := Vector3.UP
	var z := x.cross(y).normalized()
	if z.length_squared() < 0.01:
		z = Vector3.FORWARD
	return Basis(x, y, z)

func _hide_old_flowerboxes(parent: Node) -> void:
	for child in parent.get_children():
		var node := child as Node
		if node == null:
			continue
		if String(node.name).begins_with("S03RightFlowerbox_"):
			_hide_visual_subtree(node)
		else:
			_hide_old_flowerboxes(node)

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
	if _contact_records.size() != PLANTER_STATIONS.size() or _projection_records.size() != PLANTER_STATIONS.size():
		return false
	for record in _contact_records:
		if not (record.get("base_world", Vector3.INF) as Vector3).is_finite():
			return false
		if not is_finite(float(record.get("max_ground_y", NAN))):
			return false
		if float(record.get("minimum_corner_clearance_m", -INF)) < -0.001:
			return false
	for record in _projection_records:
		if not (record.get("base_world", Vector3.INF) as Vector3).is_finite():
			return false
		if not (record.get("flower_top_screen", Vector2(-1.0, -1.0)) as Vector2).is_finite():
			return false
		if bool(record.get("base_behind_camera", true)) or bool(record.get("flower_top_behind_camera", true)):
			return false
	return true

func _publish_ready_state() -> void:
	set_meta("saisies_s03_flowers_refinement_ready", true)
	set_meta("saisies_s03_flowers_refinement_enabled", true)
	set_meta("saisies_s03_flowers_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_flowers_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_flowers_hidden_old_paths", PackedStringArray(_hidden_paths))
	set_meta("saisies_s03_flowers_replacement_path", str(_replacement.get_path()))
	set_meta("saisies_s03_flowers_planter_count", _contact_records.size())
	set_meta("saisies_s03_flowers_count_per_planter", FLOWERS_PER_PLANTER)
	set_meta("saisies_s03_flowers_total_count", _contact_records.size() * FLOWERS_PER_PLANTER)
	set_meta("saisies_s03_flowers_planter_paths", PackedStringArray(_planter_paths()))
	set_meta("saisies_s03_flowers_contact_records", _contact_records)
	set_meta("saisies_s03_flowers_projection_records", _projection_records)
	set_meta("saisies_s03_flowers_ground_contact_method", "highest S01Landscape._sample_ground/_sample_baked_ground/S03JunctionPavement triangle at four BoxBody corners")
	set_meta("saisies_s03_flowers_box_dimensions_m", Vector3(BODY_LENGTH_M, BODY_HEIGHT_M, BODY_DEPTH_M))
	set_meta("saisies_s03_flowers_base_bury_m", BASE_BURY_M)
	set_meta("saisies_s03_flowers_support_method", "four compact wood feet extend from each sampled corner to the horizontal BoxBody bottom")
	set_meta("saisies_s03_flowers_rail_reference_path", str(_rail_root.get_path()))
	set_meta("saisies_s03_flowers_rail_side", RAIL_SIDE)
	set_meta("saisies_s03_flowers_rail_inset_m", PLANTER_INSET_FROM_RAIL_M)
	set_meta("saisies_s03_flowers_shared_mesh_mode", "low-face shared SphereMesh flower/leaf clusters")
	_publish_parent_ready(true)

func _planter_paths() -> Array[String]:
	var paths: Array[String] = []
	if _replacement == null:
		return paths
	for child in _replacement.get_children():
		paths.append(str(child.get_path()))
	return paths

func _publish_disabled_state() -> void:
	set_meta("saisies_s03_flowers_refinement_ready", true)
	set_meta("saisies_s03_flowers_refinement_enabled", false)
	set_meta("saisies_s03_flowers_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_flowers_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_flowers_hidden_old_paths", PackedStringArray())
	set_meta("saisies_s03_flowers_planter_count", 0)
	set_meta("saisies_s03_flowers_ground_contact_method", "disabled baseline")
	_publish_parent_ready(false)

func _publish_parent_ready(enabled: bool) -> void:
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s03_flowers_review_ready", true)
		parent.set_meta("saisies_s03_flowers_review_enabled", enabled)
		parent.set_meta("saisies_s03_flowers_review_source_frame", SOURCE_FRAME)

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
	set_meta("saisies_s03_flowers_refinement_ready", false)
	set_meta("saisies_s03_flowers_refinement_error", message)
	_publish_parent_ready(false)
	push_error(message)

func _has_command_line_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()
