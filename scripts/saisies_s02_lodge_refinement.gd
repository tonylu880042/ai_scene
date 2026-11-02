extends Node3D

## Bounded S02 review refinement for the right-hand Intersection_Lodge.
##
## The S01 review scene remains the complete world and still owns the camera,
## route, and terrain. This module changes one instanced lodge in that review
## world only. The position/scale values are source-view visual estimates, not
## a route or GPS correction. The authored lodge children stay in the tree but
## are hidden; a local duplicate subtree carries the one bounded candidate so
## the frozen world is never edited or deleted. Its foundation is resized after
## the candidate transform and sampled against S01Landscape's baked mesh
## triangle lookup so the elevated visual body remains supported by real 3D
## ground.

@export var world_path: NodePath = NodePath("../S01Review/World")
@export var s01_architecture_path: NodePath = NodePath("../S01Review/S01Architecture")
@export var s01_landscape_path: NodePath = NodePath("../S01Review/S01Landscape")
@export var s01_camera_controller_path: NodePath = NodePath("../S01Review/S01CameraController")
@export var enable_refinement := true

const SOURCE_FRAME := "video/saisies_analysis/acceptance/S02_f000719.png"
const SOURCE_SHA256 := "3c692e306cd0ebcb6eb677f7b18678f8379e6c8bbdfdab782a2f32dd8fc3c958"
const TARGET_NODE_PATH := "VillageS01S02/S01S02Buildings/Intersection_Lodge"
const LOCAL_OFFSET_X_M := 12.0
const LOCAL_OFFSET_Y_M := -6.20
const LOCAL_OFFSET_Z_M := -15.0
const HORIZONTAL_SCALE := 0.60
const VERTICAL_SCALE := 2.80
const ROOF_RISE_SCALE := 0.25
const OPENING_HEIGHT_SCALE := 0.55
const FOUNDATION_BURY_M := 0.10
const S01_VISIBLE_DETAIL_PATH := "VillageS01S02/S01S02Buildings/Right_Alpine_Lodge"
const S01_VISIBLE_DETAIL_META := "saisies_s01_lodge_visible_face_detail"

var _world: Node3D
var _lodge: Node3D
var _refinement: Node3D
var _landscape_sampler: Node
var _attempts := 0
var _built := false

func _ready() -> void:
	if _has_command_line_flag("--s02-lodge-off"):
		enable_refinement = false
	call_deferred("_try_build")

func _try_build() -> void:
	if _built:
		return
	_world = get_node_or_null(world_path) as Node3D
	_lodge = _world.get_node_or_null(TARGET_NODE_PATH) as Node3D if _world != null else null
	var architecture := get_node_or_null(s01_architecture_path) as Node
	_landscape_sampler = get_node_or_null(s01_landscape_path) as Node
	var camera_controller := get_node_or_null(s01_camera_controller_path) as Node
	if _world == null or architecture == null or _landscape_sampler == null or camera_controller == null:
		_retry("S02 lodge review dependencies are not present")
		return
	if _lodge == null:
		_fail_and_hold("S02 Intersection_Lodge owner is missing at %s" % TARGET_NODE_PATH)
		return
	if not bool(architecture.get_meta("saisies_s01_architecture_ready", false)):
		_retry("S02 lodge review is waiting for S01Architecture")
		return
	if not bool(_landscape_sampler.get_meta("saisies_s01_landscape_ready", false)) or not bool(_landscape_sampler.get_meta("saisies_s01_actual_triangle_contact", false)):
		_retry("S02 lodge review is waiting for S01 baked terrain sampler")
		return
	if not _landscape_sampler.has_method("_sample_baked_ground"):
		_fail_and_hold("S02 lodge review requires S01Landscape._sample_baked_ground")
		return
	if not bool(camera_controller.get_meta("saisies_s01_camera_controller_ready", false)):
		_retry("S02 lodge review is waiting for S01CameraController")
		return
	if not _s01_visible_lodge_detail_ready():
		_retry("S02 lodge review is waiting for S01 visible lodge detail")
		return
	if not enable_refinement:
		_publish_disabled_state()
		_built = true
		return
	if bool(_lodge.get_meta("saisies_s02_review_refinement_applied", false)):
		_publish_ready_state()
		_built = true
		return
	if _apply_candidate():
		_publish_ready_state()
		_built = true
	else:
		_fail_and_hold("S02 Intersection_Lodge candidate could not establish actual mesh contact")

func _retry(message: String) -> void:
	_attempts += 1
	if _attempts < 180:
		call_deferred("_try_build")
	else:
		_fail_and_hold(message)

func _apply_candidate() -> bool:
	if _lodge == null:
		return false
	_refinement = Node3D.new()
	_refinement.name = "S02IntersectionLodgeRefinement"
	_refinement.position = Vector3(LOCAL_OFFSET_X_M, LOCAL_OFFSET_Y_M, LOCAL_OFFSET_Z_M)
	_refinement.scale = Vector3(HORIZONTAL_SCALE, VERTICAL_SCALE, HORIZONTAL_SCALE)
	_refinement.set_meta("saisies_s02_review_local_candidate", true)
	_refinement.set_meta("saisies_s02_review_source_frame", SOURCE_FRAME)
	_refinement.set_meta("saisies_s02_review_source_sha256", SOURCE_SHA256)
	_lodge.add_child(_refinement)

	var source_child_count := 0
	var duplicate_visual_count := 0
	for child in _lodge.get_children():
		if child == _refinement:
			continue
		source_child_count += 1
		var copy := child.duplicate()
		if copy == null:
			_continue_candidate_cleanup()
			return false
		_refinement.add_child(copy)
		_set_visible_recursive(copy, true)
		duplicate_visual_count += _count_visual_instances(copy)
	_apply_final_proportions(_refinement)
	var hidden_visuals: Array[VisualInstance3D] = []
	_hide_visible_recursive(_lodge, hidden_visuals, _refinement)
	_lodge.set_meta("saisies_s02_review_original_child_count", source_child_count)
	_lodge.set_meta("saisies_s02_review_hidden_visual_count", hidden_visuals.size())
	_lodge.set_meta("saisies_s02_review_duplicate_visual_count", duplicate_visual_count)

	var foundation := _refinement.get_node_or_null("GeoVillageFoundation") as MeshInstance3D
	var body := _refinement.get_node_or_null("IntersectionLodgeCreamBase") as MeshInstance3D
	if foundation == null or body == null or foundation.mesh == null or not (foundation.mesh is BoxMesh) or body.mesh == null:
		_restore_hidden_visuals(hidden_visuals)
		_continue_candidate_cleanup()
		return false

	var contact := _fit_foundation_to_baked_mesh(foundation, body)
	if not bool(contact.get("ok", false)):
		_restore_hidden_visuals(hidden_visuals)
		_continue_candidate_cleanup()
		return false

	_lodge.set_meta("saisies_s02_review_refinement_applied", true)
	_lodge.set_meta("saisies_s02_review_refinement_owner", "Intersection_Lodge")
	_lodge.set_meta("saisies_s02_review_refinement_node_path", str(_refinement.get_path()))
	_lodge.set_meta("saisies_s02_review_source_frame", SOURCE_FRAME)
	_lodge.set_meta("saisies_s02_review_source_sha256", SOURCE_SHA256)
	_lodge.set_meta("saisies_s02_review_transform_basis", "bounded S02 source-view estimate; not GPS")
	_lodge.set_meta("saisies_s02_review_offset_local_xz_m", Vector2(LOCAL_OFFSET_X_M, LOCAL_OFFSET_Z_M))
	_lodge.set_meta("saisies_s02_review_offset_world_xz_m", Vector2(LOCAL_OFFSET_X_M, LOCAL_OFFSET_Z_M))
	_lodge.set_meta("saisies_s02_review_offset_local_xyz_m", Vector3(LOCAL_OFFSET_X_M, LOCAL_OFFSET_Y_M, LOCAL_OFFSET_Z_M))
	_lodge.set_meta("saisies_s02_review_scale_xyz", Vector3(HORIZONTAL_SCALE, VERTICAL_SCALE, HORIZONTAL_SCALE))
	_lodge.set_meta("saisies_s02_review_roof_rise_scale", ROOF_RISE_SCALE)
	_lodge.set_meta("saisies_s02_review_opening_height_scale", OPENING_HEIGHT_SCALE)
	_lodge.set_meta("saisies_s02_review_visible_owner_path", str(_lodge.get_path()))
	_lodge.set_meta("saisies_s02_review_hidden_old_geometry", true)
	_lodge.set_meta("saisies_s02_review_contact_source", "S01Landscape._sample_baked_ground actual mesh triangles")
	_lodge.set_meta("saisies_s02_review_contact_samples", contact["samples"])
	_lodge.set_meta("saisies_s02_review_ground_y_range", Vector2(contact["min_ground_y"], contact["max_ground_y"]))
	_lodge.set_meta("saisies_s02_review_foundation_bottom_world_y", contact["foundation_bottom_world_y"])
	_lodge.set_meta("saisies_s02_review_foundation_top_world_y", contact["foundation_top_world_y"])
	return true

func _apply_final_proportions(root: Node3D) -> void:
	var eave := root.get_node_or_null("IntersectionLodgeWhiteEave_02") as Node3D
	if eave == null:
		return
	var eave_y := eave.position.y
	var door := root.get_node_or_null("IntersectionLodgeFrontDoor") as Node3D
	var door_y := door.position.y if door != null else 0.0
	_adjust_roof_recursive(root, eave_y)
	_adjust_openings_recursive(root, door_y)

func _adjust_roof_recursive(node: Node, eave_y: float) -> void:
	for child in node.get_children():
		var child_name := String(child.name)
		if child is Node3D and (child_name == "RoofSlopeNegX" or child_name == "RoofSlopePosX" or child_name == "RoofRidgeCap"):
			var roof := child as Node3D
			roof.position.y = eave_y + (roof.position.y - eave_y) * ROOF_RISE_SCALE
			if child_name == "RoofSlopeNegX" or child_name == "RoofSlopePosX":
				roof.rotation.z *= ROOF_RISE_SCALE
		elif child is Node3D and (child_name == "SealedGableEndNeg" or child_name == "SealedGableEndPos"):
			var gable := child as Node3D
			gable.position.y = eave_y + (gable.position.y - eave_y) * ROOF_RISE_SCALE
			gable.scale.y *= ROOF_RISE_SCALE
		_adjust_roof_recursive(child, eave_y)

func _adjust_openings_recursive(node: Node, door_y: float) -> void:
	for child in node.get_children():
		if child is Node3D:
			var child_name := String(child.name)
			var opening := child as Node3D
			if child_name.contains("Window") and not child_name.contains("Sill"):
				opening.scale.y *= OPENING_HEIGHT_SCALE
			elif child_name == "IntersectionLodgeFrontDoor" or child_name.begins_with("IntersectionLodgeDoorJamb") or child_name == "IntersectionLodgeDoorLintel" or child_name == "IntersectionLodgeDoorHandle":
				opening.position.y = door_y + (opening.position.y - door_y) * OPENING_HEIGHT_SCALE
				opening.scale.y *= OPENING_HEIGHT_SCALE
		_adjust_openings_recursive(child, door_y)

func _s01_visible_lodge_detail_ready() -> bool:
	if _world == null:
		return false
	var s01_lodge := _world.get_node_or_null(S01_VISIBLE_DETAIL_PATH) as Node
	return s01_lodge != null and not String(s01_lodge.get_meta(S01_VISIBLE_DETAIL_META, "")).is_empty()

func _hide_visible_recursive(node: Node, hidden: Array[VisualInstance3D], skip: Node) -> void:
	for child in node.get_children():
		if child == skip:
			continue
		if child is VisualInstance3D:
			var visual := child as VisualInstance3D
			if visual.visible:
				visual.visible = false
				hidden.append(visual)
		_hide_visible_recursive(child, hidden, skip)

func _restore_hidden_visuals(hidden: Array[VisualInstance3D]) -> void:
	for visual in hidden:
		if is_instance_valid(visual):
			visual.visible = true

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

func _continue_candidate_cleanup() -> void:
	if _refinement != null and is_instance_valid(_refinement):
		_refinement.free()
	_refinement = null

func _fit_foundation_to_baked_mesh(foundation: MeshInstance3D, body: MeshInstance3D) -> Dictionary:
	var source_box := foundation.mesh as BoxMesh
	var local_aabb := foundation.get_aabb()
	var half_x := local_aabb.size.x * 0.5
	var half_z := local_aabb.size.z * 0.5
	var points := [
		Vector3(-half_x, local_aabb.position.y, -half_z),
		Vector3(half_x, local_aabb.position.y, -half_z),
		Vector3(half_x, local_aabb.position.y, half_z),
		Vector3(-half_x, local_aabb.position.y, half_z),
		Vector3(0.0, local_aabb.position.y, -half_z),
		Vector3(half_x, local_aabb.position.y, 0.0),
		Vector3(0.0, local_aabb.position.y, half_z),
		Vector3(-half_x, local_aabb.position.y, 0.0)
	]
	var records: Array[Dictionary] = []
	var min_ground_y := INF
	var max_ground_y := -INF
	for local_point in points:
		var world_point: Vector3 = foundation.global_transform * local_point
		var sampled = _landscape_sampler.call("_sample_baked_ground", Vector2(world_point.x, world_point.z))
		if not (sampled is Dictionary) or not sampled.has("position"):
			return {"ok": false}
		var ground_point: Vector3 = sampled["position"]
		if not is_finite(ground_point.y):
			return {"ok": false}
		min_ground_y = minf(min_ground_y, ground_point.y)
		max_ground_y = maxf(max_ground_y, ground_point.y)
		records.append({
			"world_xz": Vector2(world_point.x, world_point.z),
			"ground_y": ground_point.y,
			"triangle_start": int(sampled.get("triangle_start", -1)),
			"source": String(sampled.get("source", "baked_mesh_triangle")),
		})
	if records.size() < 4 or not is_finite(min_ground_y) or not is_finite(max_ground_y):
		return {"ok": false}

	var body_bounds := _world_aabb(body)
	var foundation_bottom_world_y := min_ground_y - FOUNDATION_BURY_M
	var foundation_top_world_y := body_bounds.position.y - 0.03
	if not is_finite(body_bounds.position.y) or foundation_top_world_y <= foundation_bottom_world_y + 0.05:
		return {"ok": false}
	var world_y_per_local := foundation.global_transform.basis.y.length()
	if not is_finite(world_y_per_local) or world_y_per_local <= 0.0001:
		return {"ok": false}
	var foundation_copy := source_box.duplicate() as BoxMesh
	foundation_copy.size = Vector3(source_box.size.x, (foundation_top_world_y - foundation_bottom_world_y) / world_y_per_local, source_box.size.z)
	foundation.mesh = foundation_copy
	var current_center_world_y := foundation.global_position.y
	var desired_center_world_y := (foundation_bottom_world_y + foundation_top_world_y) * 0.5
	foundation.position.y += (desired_center_world_y - current_center_world_y) / world_y_per_local
	return {
		"ok": true,
		"samples": records,
		"min_ground_y": min_ground_y,
		"max_ground_y": max_ground_y,
		"foundation_bottom_world_y": foundation_bottom_world_y,
		"foundation_top_world_y": foundation_top_world_y,
	}

func _world_aabb(mesh_instance: MeshInstance3D) -> AABB:
	var local := mesh_instance.get_aabb()
	var result := AABB()
	var initialized := false
	for ix in range(2):
		for iy in range(2):
			for iz in range(2):
				var point: Vector3 = mesh_instance.global_transform * (local.position + Vector3(local.size.x * float(ix), local.size.y * float(iy), local.size.z * float(iz)))
				if not initialized:
					result = AABB(point, Vector3.ZERO)
					initialized = true
				else:
					result = result.expand(point)
	return result

func _publish_ready_state() -> void:
	set_meta("saisies_s02_lodge_refinement_ready", true)
	set_meta("saisies_s02_lodge_refinement_enabled", enable_refinement)
	set_meta("saisies_s02_lodge_refinement_source_frame", SOURCE_FRAME)

func _publish_disabled_state() -> void:
	set_meta("saisies_s02_lodge_refinement_ready", true)
	set_meta("saisies_s02_lodge_refinement_enabled", false)
	set_meta("saisies_s02_lodge_refinement_status", "baseline_off_no_geometry_change")

func _fail_and_hold(message: String) -> void:
	set_meta("saisies_s02_lodge_refinement_ready", false)
	set_meta("saisies_s02_lodge_refinement_error", message)
	push_error(message)

func _has_command_line_flag(flag: String) -> bool:
	for raw_arg in OS.get_cmdline_user_args():
		if String(raw_arg) == flag:
			return true
	return false
