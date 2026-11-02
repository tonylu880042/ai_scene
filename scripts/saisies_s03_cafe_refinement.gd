extends Node3D

## One bounded S03 cafe correction over the accepted R17 junction review.
##
## The authored cafe remains in the frozen world but is hidden in this
## instantiated review only.  A single duplicate is placed on the left bank
## of the junction, with a small sampled terrace.  The route, camera, baked
## landscape, and junction module remain owned by the accepted scenes.

@export var s03_review_path: NodePath = NodePath("../S03Review")
@export var world_path: NodePath = NodePath("../S03Review/S02Review/S01Review/World")
@export var s01_landscape_path: NodePath = NodePath("../S03Review/S02Review/S01Review/S01Landscape")
@export var junction_path: NodePath = NodePath("../S03Review/S03JunctionRefinement")
@export var enable_refinement := true

const SOURCE_FRAME := "video/saisies_analysis/acceptance/S03_f001798.png"
const SOURCE_SHA256 := "184ee032aef47be5d52b5d5c6379300dc4dca85054ada0b93ef07ed8ca043e10"
# Keep the source-side footprint in front of the apartments.  The cafe is
# lifted against the accepted junction pavement instead of being repositioned
# behind the apartment mass.
const CAFE_STATION_M := 970.0
const CAFE_LATERAL_M := 12.0
const FLOOR_CLEARANCE_M := 0.12
const TERRACE_CLEARANCE_M := 0.06
const TERRACE_THICKNESS_M := 0.12
const ENTRY_STEP_DROP_M := 0.15
const FOUNDATION_BURY_M := 0.08
const TARGET_NODE_PATH := "VillageS01S02/S03Chairlift/S03LeftLiftLodge"
const TERRACE_NODE_PATH := "VillageS01S02/S03Chairlift/S03CafeFrontTerrace"

var _s03_review: Node
var _world: Node3D
var _landscape: Node
var _route: Node
var _lodge: Node3D
var _old_terrace: MeshInstance3D
var _junction: Node
var _junction_pavement: MeshInstance3D
var _attempts := 0
var _built := false
var _refinement: Node3D
var _contact_samples: Array[Dictionary] = []
var _actual_junction_contacts := 0

func _ready() -> void:
	process_priority = -80
	if _has_command_line_flag("--s03-cafe-off"):
		enable_refinement = false
	call_deferred("_try_build")

func _try_build() -> void:
	if _built:
		return
	_s03_review = get_node_or_null(s03_review_path)
	_world = get_node_or_null(world_path) as Node3D
	_landscape = get_node_or_null(s01_landscape_path)
	_junction = get_node_or_null(junction_path)
	_route = _world.get_node_or_null("Route") as Node if _world != null else null
	_lodge = _world.get_node_or_null(TARGET_NODE_PATH) as Node3D if _world != null else null
	_old_terrace = _world.get_node_or_null(TERRACE_NODE_PATH) as MeshInstance3D if _world != null else null
	if _s03_review == null or _world == null or _landscape == null or _route == null or _lodge == null or _old_terrace == null or _junction == null:
		_retry("S03 cafe refinement dependencies are incomplete")
		return
	if not bool(_s03_review.get_meta("saisies_s03_review_ready", false)):
		_retry("S03 cafe refinement is waiting for the fixed S03 pose")
		return
	if not bool(_landscape.get_meta("saisies_s01_landscape_ready", false)) or not bool(_landscape.get_meta("saisies_s01_actual_triangle_contact", false)):
		_retry("S03 cafe refinement is waiting for the baked landscape sampler")
		return
	if not _landscape.has_method("_sample_baked_ground"):
		_fail_and_hold("S03 cafe refinement requires S01Landscape._sample_baked_ground")
		return
	if not bool(_junction.get_meta("saisies_s03_junction_refinement_ready", false)):
		_retry("S03 cafe refinement is waiting for the junction geometry")
		return
	if not enable_refinement:
		_publish_disabled_state()
		_built = true
		return
	if _apply_candidate():
		_publish_ready_state()
		_built = true
	else:
		_fail_and_hold("S03 cafe candidate could not establish sampled ground contact")

func _retry(message: String) -> void:
	_attempts += 1
	if _attempts < 240:
		# Waiting one actual frame is required; repeated deferred calls can all
		# run before the S03 controller and junction have settled.
		call_deferred("_retry_next_frame")
	else:
		_fail_and_hold(message)

func _retry_next_frame() -> void:
	await get_tree().process_frame
	_try_build()

func _apply_candidate() -> bool:
	var candidate := Node3D.new()
	candidate.name = "S03CafeRefinementCandidate"
	candidate.set_meta("saisies_s03_cafe_candidate", true)
	candidate.set_meta("saisies_s03_cafe_station_m", CAFE_STATION_M)
	candidate.set_meta("saisies_s03_cafe_lateral_m", CAFE_LATERAL_M)
	candidate.set_meta("saisies_s03_cafe_source_frame", SOURCE_FRAME)
	candidate.set_meta("saisies_s03_cafe_source_sha256", SOURCE_SHA256)
	# Keep the candidate below the owned module so review harnesses can inspect
	# the visible body without treating it as an unrelated world edit.
	add_child(candidate)
	_refinement = candidate

	if not _route.has_method("pos_at") or not _route.has_method("left_at"):
		_continue_candidate_cleanup()
		return false
	var route_pos := Vector3(_route.call("pos_at", CAFE_STATION_M))
	var route_left := Vector3(_route.call("left_at", CAFE_STATION_M))
	var target_xz := route_pos + route_left * CAFE_LATERAL_M
	var source_transform := _lodge.global_transform
	source_transform.origin = Vector3(target_xz.x, source_transform.origin.y, target_xz.z)
	candidate.global_transform = source_transform

	var duplicate_visual_count := 0
	var source_child_count := 0
	for child in _lodge.get_children():
		source_child_count += 1
		var copy := child.duplicate()
		if copy == null:
			_continue_candidate_cleanup()
			return false
		candidate.add_child(copy)
		_set_visible_recursive(copy, true)
		duplicate_visual_count += _count_visual_instances(copy)
	if duplicate_visual_count == 0:
		_continue_candidate_cleanup()
		return false

	var pavement := _junction.find_child("S03JunctionPavement", true, false) as MeshInstance3D
	_junction_pavement = pavement
	_contact_samples.clear()
	_actual_junction_contacts = 0
	var foundation := candidate.get_node_or_null("GeoVillageFoundation") as MeshInstance3D
	var body := candidate.get_node_or_null("S03CafeLowBody") as MeshInstance3D
	if foundation == null or body == null or foundation.mesh == null or body.mesh == null:
		_continue_candidate_cleanup()
		return false

	var contact := _fit_candidate_to_ground(candidate, foundation, body)
	if not bool(contact.get("ok", false)):
		_continue_candidate_cleanup()
		return false
	var terrace := _build_terrace(candidate, body, contact)
	if terrace == null:
		_continue_candidate_cleanup()
		return false

	_hide_visible_recursive(_lodge)
	_old_terrace.visible = false
	_lodge.set_meta("saisies_s03_cafe_original_hidden", true)
	_lodge.set_meta("saisies_s03_cafe_candidate_path", str(candidate.get_path()))
	_lodge.set_meta("saisies_s03_cafe_duplicate_visual_count", duplicate_visual_count)
	_lodge.set_meta("saisies_s03_cafe_source_child_count", source_child_count)
	candidate.set_meta("saisies_s03_cafe_floor_clearance_m", FLOOR_CLEARANCE_M)
	candidate.set_meta("saisies_s03_cafe_ground_contact_source", "junction pavement triangles with S01Landscape baked fallback")
	candidate.set_meta("saisies_s03_cafe_actual_junction_contact_count", _actual_junction_contacts)
	candidate.set_meta("saisies_s03_cafe_contact_samples", _contact_samples)
	candidate.set_meta("saisies_s03_cafe_max_ground_y", float(contact.get("max_ground_y", NAN)))
	candidate.set_meta("saisies_s03_cafe_entry_ground_y", float(contact.get("entry_ground_y", NAN)))
	candidate.set_meta("saisies_s03_cafe_body_bottom_world_y", _world_aabb(body).position.y)
	candidate.set_meta("saisies_s03_cafe_foundation_bottom_world_y", float(contact.get("foundation_bottom_world_y", NAN)))
	candidate.set_meta("saisies_s03_cafe_foundation_top_world_y", float(contact.get("foundation_top_world_y", NAN)))
	candidate.set_meta("saisies_s03_cafe_terrace_path", str(terrace.get_path()))
	set_meta("saisies_s03_cafe_refinement_applied", true)
	set_meta("saisies_s03_cafe_refinement_owner", TARGET_NODE_PATH)
	set_meta("saisies_s03_cafe_refinement_node_path", str(candidate.get_path()))
	set_meta("saisies_s03_cafe_refinement_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_cafe_refinement_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_cafe_refinement_station_m", CAFE_STATION_M)
	set_meta("saisies_s03_cafe_refinement_lateral_m", CAFE_LATERAL_M)
	set_meta("saisies_s03_cafe_refinement_actual_junction_contact_count", _actual_junction_contacts)
	set_meta("saisies_s03_cafe_refinement_contact_samples", _contact_samples)
	set_meta("saisies_s03_cafe_refinement_entry_ground_y", float(contact.get("entry_ground_y", NAN)))
	set_meta("saisies_s03_cafe_refinement_body_bottom_world_y", _world_aabb(body).position.y)
	return true

func _fit_candidate_to_ground(candidate: Node3D, foundation: MeshInstance3D, body: MeshInstance3D) -> Dictionary:
	var source_aabb := foundation.mesh.get_aabb()
	var half_x := source_aabb.size.x * 0.5
	var half_z := source_aabb.size.z * 0.5
	var local_points := [
		Vector3(-half_x, 0.0, -half_z), Vector3(half_x, 0.0, -half_z),
		Vector3(half_x, 0.0, half_z), Vector3(-half_x, 0.0, half_z),
		Vector3(0.0, 0.0, -half_z), Vector3(half_x, 0.0, 0.0),
		Vector3(0.0, 0.0, half_z), Vector3(-half_x, 0.0, 0.0)
	]
	var samples: Array[Dictionary] = []
	var max_ground_y := -INF
	var entry_ground_y := -INF
	var min_ground_y := INF
	for local_point in local_points:
		var world_point: Vector3 = foundation.global_transform * local_point
		var sampled := _sample_ground(Vector2(world_point.x, world_point.z))
		if not sampled.has("position"):
			return {"ok": false}
		var ground := Vector3(sampled["position"])
		if not is_finite(ground.y):
			return {"ok": false}
		max_ground_y = maxf(max_ground_y, ground.y)
		min_ground_y = minf(min_ground_y, ground.y)
		if local_point.x >= half_x * 0.9:
			entry_ground_y = maxf(entry_ground_y, ground.y)
		samples.append({
			"world_xz": Vector2(world_point.x, world_point.z),
			"ground_y": ground.y,
			"source": String(sampled.get("source", "baked_mesh_triangle")),
			"triangle_start": int(sampled.get("triangle_start", -1)),
		})
	if samples.size() < 4 or not is_finite(min_ground_y) or not is_finite(max_ground_y) or not is_finite(entry_ground_y):
		return {"ok": false}
	var body_bounds := _world_aabb(body)
	if not is_finite(body_bounds.position.y):
		return {"ok": false}
	# The accepted junction mesh is the visible plaza under this source-side
	# footprint.  Use its highest sampled triangle so every body corner clears
	# the road/apron, while the foundation extends down to the lowest baked or
	# pavement sample and stays mostly buried.
	var desired_floor := max_ground_y + FLOOR_CLEARANCE_M
	candidate.global_position.y += desired_floor - body_bounds.position.y
	var body_floor_world_y := _world_aabb(body).position.y
	var source_box := foundation.mesh as BoxMesh
	if source_box == null:
		return {"ok": false}
	var foundation_bottom_world_y := min_ground_y - FOUNDATION_BURY_M
	var foundation_top_world_y := body_floor_world_y + 0.02
	if foundation_top_world_y <= foundation_bottom_world_y + 0.05:
		return {"ok": false}
	var world_y_per_local := foundation.global_transform.basis.y.length()
	if not is_finite(world_y_per_local) or world_y_per_local <= 0.0001:
		return {"ok": false}
	var foundation_copy := source_box.duplicate() as BoxMesh
	foundation_copy.size = Vector3(source_box.size.x, (foundation_top_world_y - foundation_bottom_world_y) / world_y_per_local, source_box.size.z)
	foundation.mesh = foundation_copy
	var desired_foundation_center := (foundation_bottom_world_y + foundation_top_world_y) * 0.5
	foundation.position.y += (desired_foundation_center - foundation.global_position.y) / world_y_per_local
	_contact_samples = samples
	return {
		"ok": true,
		"max_ground_y": max_ground_y,
		"entry_ground_y": entry_ground_y,
		"min_ground_y": min_ground_y,
		"body_bottom_world_y": body_floor_world_y,
		"foundation_bottom_world_y": foundation_bottom_world_y,
		"foundation_top_world_y": foundation_top_world_y,
		"samples": samples,
	}

func _build_terrace(candidate: Node3D, body: MeshInstance3D, contact: Dictionary) -> MeshInstance3D:
	# Keep the entrance landing flat at the cafe floor.  A closed masonry skirt
	# carries it down to the four visible pavement samples instead of leaving a
	# thin slab floating over the plaza.
	var body_floor_world_y := _world_aabb(body).position.y
	var half_width := 5.36
	var landing_x0 := 3.20
	var landing_x1 := 4.90
	var landing_top_world_y := body_floor_world_y - TERRACE_CLEARANCE_M
	var landing := _box_part(candidate, "S03CafeRefinementTerrace", Vector3(landing_x1 - landing_x0, TERRACE_THICKNESS_M, half_width * 2.0), Vector3((landing_x0 + landing_x1) * 0.5, landing_top_world_y - TERRACE_THICKNESS_M * 0.5, 0.0))
	if landing == null:
		return null
	var landing_corners := [
		Vector3(landing_x0, 0.0, -half_width), Vector3(landing_x0, 0.0, half_width),
		Vector3(landing_x1, 0.0, half_width), Vector3(landing_x1, 0.0, -half_width)
	]
	var ground_points: Array[Vector3] = []
	var actual_corner_contacts := 0
	for local_corner in landing_corners:
		var world_corner: Vector3 = candidate.global_transform * local_corner
		var sampled := _sample_ground(Vector2(world_corner.x, world_corner.z))
		if not sampled.has("position"):
			landing.queue_free()
			return null
		ground_points.append(Vector3(sampled["position"]))
		if String(sampled.get("source", "")) == "S03JunctionPavement.mesh_triangle":
			actual_corner_contacts += 1
	var skirt := _build_landing_skirt(candidate, landing_corners, ground_points, landing_top_world_y - TERRACE_THICKNESS_M)
	if skirt == null:
		landing.queue_free()
		return null
	landing.set_meta("saisies_s03_cafe_terrace_ground_source", "four S03JunctionPavement mesh triangles")
	landing.set_meta("saisies_s03_cafe_terrace_clearance_m", TERRACE_CLEARANCE_M)
	landing.set_meta("saisies_s03_cafe_terrace_skirt_path", str(skirt.get_path()))
	landing.set_meta("saisies_s03_cafe_terrace_actual_corner_contact_count", actual_corner_contacts)

	# A compact, centered stair flight brings the door to the plaza.  Its run is
	# finite and each solid riser reaches the sampled pavement height.
	var stair_start_x := landing_x1
	var stair_run_m := 0.30
	var stair_width_m := 2.00
	var stair_count := 12
	var end_world: Vector3 = candidate.global_transform * Vector3(stair_start_x + stair_run_m * stair_count, 0.0, 0.0)
	var end_sample := _sample_ground(Vector2(end_world.x, end_world.z))
	if not end_sample.has("position"):
		landing.queue_free()
		skirt.queue_free()
		return null
	var end_ground_y := Vector3(end_sample["position"]).y
	var total_drop := landing_top_world_y - end_ground_y
	if not is_finite(total_drop) or total_drop <= 0.05:
		total_drop = ENTRY_STEP_DROP_M
	var actual_rise := total_drop / float(stair_count)
	for index in stair_count:
		var tread_top := landing_top_world_y - actual_rise * float(index + 1)
		var tread_bottom := end_ground_y - 0.04
		var height := maxf(tread_top - tread_bottom, TERRACE_THICKNESS_M)
		var step := _box_part(candidate, "S03CafeRefinementEntryStep_%02d" % index, Vector3(stair_run_m + 0.02, height, stair_width_m), Vector3(stair_start_x + stair_run_m * (float(index) + 0.5), (tread_top + tread_bottom) * 0.5, 0.0))
		step.set_meta("saisies_s03_cafe_step_drop_m", actual_rise)
		step.set_meta("saisies_s03_cafe_step_ground_source", String(end_sample.get("source", "baked_mesh_triangle")))
		step.set_meta("saisies_s03_cafe_step_end_ground_y", end_ground_y)
	set_meta("saisies_s03_cafe_refinement_landing_actual_corner_contact_count", actual_corner_contacts)
	set_meta("saisies_s03_cafe_refinement_stair_count", stair_count)
	set_meta("saisies_s03_cafe_refinement_stair_rise_m", actual_rise)
	set_meta("saisies_s03_cafe_refinement_stair_end_ground_y", end_ground_y)
	return landing

func _build_landing_skirt(candidate: Node3D, landing_corners: Array, ground_points: Array[Vector3], top_world_y: float) -> MeshInstance3D:
	if ground_points.size() != 4:
		return null
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top_points: Array[Vector3] = []
	var bottom_points: Array[Vector3] = []
	var inverse := candidate.global_transform.affine_inverse()
	for index in landing_corners.size():
		var local_corner: Vector3 = landing_corners[index]
		var top_world: Vector3 = candidate.global_transform * local_corner
		top_world.y = top_world_y
		top_points.append(inverse * top_world)
		var ground := ground_points[index]
		bottom_points.append(inverse * Vector3(ground.x, ground.y - 0.03, ground.z))
	for index in 4:
		var next := (index + 1) % 4
		_add_quad(surface, top_points[index], top_points[next], bottom_points[next], bottom_points[index])
	_add_quad(surface, bottom_points[3], bottom_points[2], bottom_points[1], bottom_points[0])
	_add_quad(surface, top_points[0], top_points[1], top_points[2], top_points[3])
	surface.generate_normals()
	var skirt := MeshInstance3D.new()
	skirt.name = "S03CafeRefinementTerraceSkirt"
	skirt.mesh = surface.commit()
	skirt.material_override = _terrace_material()
	skirt.set_meta("saisies_s03_cafe_skirt_ground_source", "four S03JunctionPavement mesh triangles")
	skirt.set_meta("saisies_s03_cafe_skirt_closed", true)
	skirt.set_meta("saisies_s03_cafe_skirt_corner_count", 4)
	candidate.add_child(skirt)
	return skirt

func _box_part(parent: Node3D, node_name: String, size: Vector3, local_position: Vector3) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = _terrace_material()
	# x/z are cafe-local coordinates; only the supplied y is world-height.
	instance.position = Vector3(local_position.x, local_position.y - parent.global_position.y, local_position.z)
	parent.add_child(instance)
	return instance

func _sample_ground(point: Vector2) -> Dictionary:
	if _junction_pavement != null and _junction_pavement.mesh != null:
		var sampled := _sample_mesh_surface(_junction_pavement, point)
		if not sampled.is_empty():
			_actual_junction_contacts += 1
			return sampled
	var baked = _landscape.call("_sample_baked_ground", point)
	if baked is Dictionary and baked.has("position"):
		var result: Dictionary = baked.duplicate(true)
		result["source"] = String(result.get("source", "baked_mesh_triangle"))
		return result
	return {}

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

func _terrace_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.42, 0.43, 0.41, 1.0)
	material.roughness = 0.92
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _add_quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	surface.set_uv(Vector2(0.0, 0.0))
	surface.add_vertex(a)
	surface.set_uv(Vector2(1.0, 0.0))
	surface.add_vertex(b)
	surface.set_uv(Vector2(1.0, 1.0))
	surface.add_vertex(c)
	surface.set_uv(Vector2(0.0, 1.0))
	surface.add_vertex(a)
	surface.add_vertex(c)
	surface.add_vertex(d)

func _hide_visible_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is VisualInstance3D:
			(child as VisualInstance3D).visible = false
		_hide_visible_recursive(child)

func _set_visible_recursive(node: Node, visible: bool) -> void:
	if node is VisualInstance3D:
		(node as VisualInstance3D).visible = visible
	for child in node.get_children():
		_set_visible_recursive(child, visible)

func _count_visual_instances(node: Node) -> int:
	var count := 1 if node is VisualInstance3D else 0
	for child in node.get_children():
		count += _count_visual_instances(child)
	return count

func _world_aabb(instance: MeshInstance3D) -> AABB:
	var local := instance.get_aabb()
	var corners := [
		Vector3(local.position.x, local.position.y, local.position.z),
		Vector3(local.end.x, local.position.y, local.position.z),
		Vector3(local.position.x, local.end.y, local.position.z),
		Vector3(local.position.x, local.position.y, local.end.z),
		Vector3(local.end.x, local.end.y, local.position.z),
		Vector3(local.end.x, local.position.y, local.end.z),
		Vector3(local.position.x, local.end.y, local.end.z),
		Vector3(local.end.x, local.end.y, local.end.z)
	]
	var result := AABB()
	for index in corners.size():
		var point: Vector3 = instance.global_transform * corners[index]
		if index == 0:
			result = AABB(point, Vector3.ZERO)
		else:
			result = result.expand(point)
	return result

func _continue_candidate_cleanup() -> void:
	if _refinement != null and is_instance_valid(_refinement):
		_refinement.queue_free()
	_refinement = null

func _publish_disabled_state() -> void:
	set_meta("saisies_s03_cafe_refinement_ready", true)
	set_meta("saisies_s03_cafe_refinement_enabled", false)
	set_meta("saisies_s03_cafe_refinement_source_frame", SOURCE_FRAME)
	_publish_parent_ready()

func _publish_ready_state() -> void:
	set_meta("saisies_s03_cafe_refinement_ready", true)
	set_meta("saisies_s03_cafe_refinement_enabled", true)
	_publish_parent_ready()

func _publish_parent_ready() -> void:
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s03_cafe_review_ready", true)
		parent.set_meta("saisies_s03_cafe_review_enabled", enable_refinement)
		parent.set_meta("saisies_s03_cafe_review_source_frame", SOURCE_FRAME)

func _fail_and_hold(message: String) -> void:
	set_meta("saisies_s03_cafe_refinement_ready", false)
	set_meta("saisies_s03_cafe_refinement_error", message)
	push_error(message)

func _has_command_line_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()
