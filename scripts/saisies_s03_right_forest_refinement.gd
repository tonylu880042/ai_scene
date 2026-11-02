extends Node3D

## Bounded S03 screen-right woodland band over the fixed R23 left-forest review.
##
## The inherited World/Forest remains intact.  This module only adds a finite
## local treefactory MultiMesh population on the camera-facing right slope,
## using the visible SaisiesGeoTerrain triangle mesh and a distant-forest camera gate.

const TREE_FACTORY := preload("res://scripts/saisies_trees.gd")

@export var left_forest_review_path: NodePath = NodePath("../LeftForestReview")
@export var flowers_review_path: NodePath = NodePath("../LeftForestReview/FlowersReview")
@export var world_path: NodePath = NodePath("../LeftForestReview/FlowersReview/SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/World")
@export var s01_landscape_path: NodePath = NodePath("../LeftForestReview/FlowersReview/SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/S01Landscape")
@export var enable_refinement := true

const SOURCE_FRAME := "video/saisies_analysis/acceptance/S03_f001798.png"
const SOURCE_SHA256 := "184ee032aef47be5d52b5d5c6379300dc4dca85054ada0b93ef07ed8ca043e10"
const CAMERA_GATE_CENTER := Vector3(138.9204, -65.5922, -839.3978)
const CAMERA_GATE_FULL_M := 260.0
const CAMERA_GATE_END_M := 420.0
const PLACEMENT_RANGE_END_M := 2500.0
const ROOT_BURY_M := 0.04
const SURFACE0_BAND_M := 0.035
const MAX_NEW_TREES := 500
const MIN_NEW_TREES := 300
const ANCHOR_SCREEN_MIN_X := 1050.0
const ANCHOR_SCREEN_MAX_X := 1900.0
const ANCHOR_SCREEN_MIN_Y := 300.0
const ANCHOR_SCREEN_MAX_Y := 430.0
const ANCHOR_MIN_DISTANCE_M := 450.0
const ANCHOR_MIN_SEPARATION_M := 35.0
const PATCH_MIN_RADIUS_M := 18.0
const PATCH_MAX_RADIUS_M := 66.0
const MAX_SURFACE_GROUND_RANGE_M := 3.0
const FIXED_SCREEN_SIZE := Vector2(1920.0, 1080.0)
const CLOSE_FOV_DEG := 52.0
const ANCHOR_LIMIT := 12
const FALLBACK_WORLD_BOUNDS := Rect2(285.0, -1080.0, 300.0, 300.0)
const VISIBLE_GROUND_CACHE_MARGIN_M := 40.0
const VISIBLE_GROUND_BIN_M := 32.0
const CLOSE_CAMERA_WORLD := Vector3(138.9204, -65.5922, -839.3978)
const CLOSE_TARGET_WORLD := Vector3(560.0, -80.0, -1130.0)

var _left_forest_review: Node
var _flowers_review: Node
var _world: Node3D
var _landscape: Node
var _route: Node
var _geography: Object
var _camera: Camera3D
var _terrain_mesh_instance: MeshInstance3D
var _replacement: Node3D
var _built := false
var _attempts := 0
var _lod_active := false
var _new_count := 0
var _conifer_count := 0
var _broadleaf_count := 0
var _surface0_contact_correction_count := 0
var _surface0_max_positive_clearance_m := 0.0
var _surface0_max_burial_m := 0.0
var _tree_meshes: Dictionary = {}
var _tree_surface0_contact_points: Dictionary = {}
var _replacement_records: Array[Dictionary] = []
var _projection_records: Array[Dictionary] = []
var _anchor_records: Array[Dictionary] = []
var _source_points: Array[Vector2] = []
var _building_bounds: Array[AABB] = []
var _roi_bounds := FALLBACK_WORLD_BOUNDS
var _visible_ground_triangles: Array[Dictionary] = []
var _visible_ground_triangle_bins: Dictionary = {}
var _visible_ground_scan_triangle_count := 0
var _visible_ground_triangle_count := 0
var _visible_ground_sample_count := 0
var _visible_ground_bounds := FALLBACK_WORLD_BOUNDS.grow(VISIBLE_GROUND_CACHE_MARGIN_M)
var _visible_ground_mesh_path := ""
var _close_camera_world := CLOSE_CAMERA_WORLD
var _close_target_world := CLOSE_TARGET_WORLD
var _patch_ground_rejected := 0
var _patch_landmark_rejected := 0
var _patch_screen_rejected := 0
var _patch_edge_rejected := 0
var _patch_range_rejected := 0
var _patch_spacing_rejected := 0

func _ready() -> void:
	process_priority = -84
	if _has_command_line_flag("--s03-right-forest-off"):
		enable_refinement = false
	call_deferred("_try_build")

func _process(_delta: float) -> void:
	if not _built or _camera == null:
		return
	_update_lod_gate()

func _try_build() -> void:
	if _built:
		return
	_left_forest_review = get_node_or_null(left_forest_review_path)
	_flowers_review = get_node_or_null(flowers_review_path)
	_world = get_node_or_null(world_path) as Node3D
	_landscape = get_node_or_null(s01_landscape_path)
	if _left_forest_review == null or _flowers_review == null or _world == null or _landscape == null:
		_retry("S03 right forest dependencies are incomplete")
		return
	if not bool(_left_forest_review.get_meta("saisies_s03_forest_review_ready", false)):
		_retry("S03 right forest is waiting for R23 left-forest readiness")
		return
	_route = _world.get_node_or_null("Route")
	_geography = _route.get("geography") as Object if _route != null else null
	_terrain_mesh_instance = _world.find_child("SaisiesGeoTerrain", true, false) as MeshInstance3D
	var rig: Node3D = _world.get_node_or_null("CameraRig") as Node3D
	_camera = rig.get_node_or_null("Camera3D") as Camera3D if rig != null else null
	if _route == null or _geography == null or not _geography.has_method("height_world") or _camera == null or _terrain_mesh_instance == null or _terrain_mesh_instance.mesh == null:
		_retry("S03 right forest requires World/Route geography, visible SaisiesGeoTerrain and Camera3D")
		return
	if not bool(_route.get("geography_ready")):
		_retry("S03 right forest is waiting for geographic route readiness")
		return
	if not enable_refinement:
		_publish_disabled_state()
		_built = true
		return
	if not _build_candidate():
		_fail_and_hold("S03 right forest could not build a finite supported band")
		return
	_built = true
	_update_lod_gate()
	_publish_ready_state()

func _build_candidate() -> bool:
	_new_count = 0
	_conifer_count = 0
	_broadleaf_count = 0
	_surface0_contact_correction_count = 0
	_surface0_max_positive_clearance_m = 0.0
	_surface0_max_burial_m = 0.0
	_replacement_records.clear()
	_projection_records.clear()
	_anchor_records.clear()
	_source_points.clear()
	_building_bounds.clear()
	_tree_surface0_contact_points.clear()
	_patch_ground_rejected = 0
	_patch_landmark_rejected = 0
	_patch_screen_rejected = 0
	_patch_edge_rejected = 0
	_patch_range_rejected = 0
	_patch_spacing_rejected = 0
	_replacement = Node3D.new()
	_replacement.name = "S03RightForestCandidate"
	_replacement.set_meta("saisies_s03_right_forest_owner", "local screen-right S03 slope band")
	_replacement.set_meta("saisies_s03_right_forest_mesh_source", "res://scripts/saisies_trees.gd")
	add_child(_replacement)
	_tree_meshes = _load_tree_meshes()
	if _tree_meshes.is_empty():
		set_meta("saisies_s03_right_forest_build_diagnostic", "tree meshes empty")
		return false
	_collect_building_bounds()
	var anchor_candidates := _collect_forest_anchor_candidates()
	set_meta("saisies_s03_right_forest_authored_anchor_candidate_count", anchor_candidates.size())
	if anchor_candidates.size() < 8:
		set_meta("saisies_s03_right_forest_build_diagnostic", "authored right-slope anchors=%d" % anchor_candidates.size())
		return false
	_visible_ground_bounds = _derive_anchor_ground_bounds(anchor_candidates)
	if not _prepare_visible_ground_cache():
		set_meta("saisies_s03_right_forest_build_diagnostic", "visible SaisiesGeoTerrain triangle cache empty")
		return false
	var anchors := _sample_forest_anchor_candidates(anchor_candidates)
	set_meta("saisies_s03_right_forest_authored_anchor_records", anchors)
	if anchors.size() < 8:
		set_meta("saisies_s03_right_forest_build_diagnostic", "sampled authored right-slope anchors=%d" % anchors.size())
		return false
	_anchor_records = anchors
	_roi_bounds = _derive_roi_bounds(anchors)
	_close_camera_world = _camera.global_position if _camera != null and _camera.global_position.is_finite() else CLOSE_CAMERA_WORLD
	_close_target_world = _anchor_centroid(anchors) + Vector3.UP * 5.0
	var grouped: Dictionary = {}
	_collect_generated_items(grouped, anchors)
	set_meta("saisies_s03_right_forest_patch_reject_counts", {"ground": _patch_ground_rejected, "landmark": _patch_landmark_rejected, "screen": _patch_screen_rejected, "edge": _patch_edge_rejected, "ground_range": _patch_range_rejected, "spacing": _patch_spacing_rejected})
	if _new_count < MIN_NEW_TREES or grouped.is_empty():
		set_meta("saisies_s03_right_forest_build_diagnostic", "generated=%d groups=%d bounds=%s" % [_new_count, grouped.size(), str(_roi_bounds)])
		return false
	if not _build_replacement_multimeshes(grouped):
		set_meta("saisies_s03_right_forest_build_diagnostic", "multimesh build failed generated=%d records=%d" % [_new_count, _replacement_records.size()])
		return false
	return _all_geometry_finite()

func _collect_forest_anchor_candidates() -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	var forest := _world.get_node_or_null("Forest") as Node
	if forest == null or _camera == null:
		return candidates
	for child in forest.get_children():
		if not child is MultiMeshInstance3D:
			continue
		var node := child as MultiMeshInstance3D
		var raw_positions: Variant = node.get_meta("forest_authored_positions", PackedVector3Array())
		if not raw_positions is PackedVector3Array:
			continue
		var positions: PackedVector3Array = raw_positions
		for source_index in positions.size():
			var world_position: Vector3 = positions[source_index]
			if not world_position.is_finite() or _camera.is_position_behind(world_position):
				continue
			var screen := _fixed_screen_projection(world_position)
			var distance := world_position.distance_to(_camera.global_position)
			if screen.x < ANCHOR_SCREEN_MIN_X or screen.x > ANCHOR_SCREEN_MAX_X or screen.y < ANCHOR_SCREEN_MIN_Y or screen.y > ANCHOR_SCREEN_MAX_Y:
				continue
			if distance <= ANCHOR_MIN_DISTANCE_M:
				continue
			candidates.append({
				"source": "authored World/Forest tree anchor",
				"source_path": str(node.get_path()),
				"source_index": source_index,
				"world": world_position,
				"screen": screen,
				"screen_normalized": Vector2(screen.x / FIXED_SCREEN_SIZE.x, screen.y / FIXED_SCREEN_SIZE.y),
				"distance_to_camera_m": distance,
				"forest_species": String(node.get_meta("forest_species", "")),
			})
	candidates.sort_custom(Callable(self, "_sort_anchor_candidates"))
	return candidates

func _sort_anchor_candidates(a: Dictionary, b: Dictionary) -> bool:
	var a_screen: Vector2 = a.get("screen", Vector2.INF)
	var b_screen: Vector2 = b.get("screen", Vector2.INF)
	if not is_equal_approx(a_screen.x, b_screen.x):
		return a_screen.x < b_screen.x
	if not is_equal_approx(a_screen.y, b_screen.y):
		return a_screen.y < b_screen.y
	return int(a.get("source_index", 0)) < int(b.get("source_index", 0))

func _derive_anchor_ground_bounds(candidates: Array[Dictionary]) -> Rect2:
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for candidate in candidates:
		var world_position: Vector3 = candidate.get("world", Vector3.INF)
		min_x = minf(min_x, world_position.x)
		max_x = maxf(max_x, world_position.x)
		min_z = minf(min_z, world_position.z)
		max_z = maxf(max_z, world_position.z)
	if not is_finite(min_x) or not is_finite(max_x) or not is_finite(min_z) or not is_finite(max_z):
		return FALLBACK_WORLD_BOUNDS.grow(VISIBLE_GROUND_CACHE_MARGIN_M)
	return Rect2(min_x - 96.0, min_z - 96.0, max_x - min_x + 192.0, max_z - min_z + 192.0)

func _sample_forest_anchor_candidates(candidates: Array[Dictionary]) -> Array[Dictionary]:
	var selected_candidates: Array[Dictionary] = []
	for candidate in candidates:
		var world_position: Vector3 = candidate["world"]
		var screen: Vector2 = candidate["screen"]
		var separated := true
		for selected in selected_candidates:
			var selected_world: Vector3 = selected["world"]
			var selected_screen: Vector2 = selected["screen"]
			if Vector2(world_position.x, world_position.z).distance_to(Vector2(selected_world.x, selected_world.z)) < ANCHOR_MIN_SEPARATION_M or screen.distance_to(selected_screen) < 72.0:
				separated = false
				break
		if separated:
			selected_candidates.append(candidate)
		if selected_candidates.size() >= ANCHOR_LIMIT:
			break
	if selected_candidates.size() < 8:
		for candidate in candidates:
			if selected_candidates.has(candidate):
				continue
			selected_candidates.append(candidate)
			if selected_candidates.size() >= ANCHOR_LIMIT:
				break
	var anchors: Array[Dictionary] = []
	for candidate in selected_candidates:
		var world_position: Vector3 = candidate["world"]
		var sample := _sample_ground(Vector2(world_position.x, world_position.z))
		if sample.is_empty():
			continue
		var ground: Vector3 = sample["position"]
		var record := candidate.duplicate(true)
		record["ground"] = ground
		record["ground_source"] = String(sample.get("source", "World/Landscape/SaisiesGeoTerrain surface0 mesh triangle"))
		record["ground_triangle_start"] = int(sample.get("triangle_start", -1))
		record["ground_triangle_surface"] = int(sample.get("surface", -1))
		record["ground_triangle_barycentric"] = sample.get("barycentric", Vector3.ZERO)
		record["normal"] = sample.get("normal", Vector3.UP)
		record["behind_camera"] = _camera.is_position_behind(world_position)
		record["in_frustum"] = true
		anchors.append(record)
		if anchors.size() >= ANCHOR_LIMIT:
			break
	return anchors

func _anchor_centroid(anchors: Array[Dictionary]) -> Vector3:
	if anchors.is_empty():
		return CLOSE_TARGET_WORLD
	var total := Vector3.ZERO
	for anchor in anchors:
		total += anchor.get("world", CLOSE_TARGET_WORLD)
	return total / float(anchors.size())

func _anchor_projection_bounds(anchors: Array[Dictionary]) -> Rect2:
	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF
	for anchor in anchors:
		var screen: Vector2 = anchor.get("screen", Vector2.INF)
		min_x = minf(min_x, screen.x)
		min_y = minf(min_y, screen.y)
		max_x = maxf(max_x, screen.x)
		max_y = maxf(max_y, screen.y)
	if not is_finite(min_x) or not is_finite(min_y) or not is_finite(max_x) or not is_finite(max_y):
		return Rect2()
	return Rect2(min_x, min_y, max_x - min_x, max_y - min_y)

func _derive_roi_bounds(anchors: Array[Dictionary]) -> Rect2:
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for anchor in anchors:
		var ground: Vector3 = anchor["ground"]
		min_x = minf(min_x, ground.x)
		max_x = maxf(max_x, ground.x)
		min_z = minf(min_z, ground.z)
		max_z = maxf(max_z, ground.z)
	if not is_finite(min_x) or not is_finite(max_x) or not is_finite(min_z) or not is_finite(max_z):
		return FALLBACK_WORLD_BOUNDS
	return Rect2(min_x - 78.0, min_z - 82.0, max_x - min_x + 156.0, max_z - min_z + 164.0)

func _collect_generated_items(grouped: Dictionary, anchors: Array[Dictionary]) -> void:
	## Keep an authored-world reference list for local continuity and to avoid
	## turning meadow openings into a uniform filled rectangle.  These are only
	## read; no inherited MultiMesh is hidden or rewritten.
	var forest := _world.get_node_or_null("Forest") as Node
	if forest != null:
		for child in forest.get_children():
			if not child is MultiMeshInstance3D:
				continue
			var node := child as MultiMeshInstance3D
			var positions := node.get_meta("forest_authored_positions", PackedVector3Array()) as PackedVector3Array
			for position in positions:
				if position.is_finite():
					_source_points.append(Vector2(position.x, position.z))

	var serial := 0
	var accepted_points: Array[Vector2] = []
	for anchor_index in anchors.size():
		var anchor: Dictionary = anchors[anchor_index]
		var anchor_world: Vector3 = anchor["world"]
		var center := Vector2(anchor_world.x, anchor_world.z)
		var patch_count := 52
		for local_index in patch_count:
			if serial >= MAX_NEW_TREES:
				break
			var cell_id := anchor_index * 8192 + local_index
			var angle := _hash01(cell_id, 7) * TAU + _hash01(cell_id, 11) * 0.34
			var radius := lerpf(PATCH_MIN_RADIUS_M, PATCH_MAX_RADIUS_M, sqrt(_hash01(cell_id, 13)))
			var point := center + Vector2(cos(angle), sin(angle)) * radius
			point.x += lerpf(-8.0, 8.0, _hash01(cell_id, 17))
			point.y += lerpf(-9.0, 9.0, _hash01(cell_id, 19))
			point.x = lerpf(center.x, point.x, lerpf(0.76, 1.18, _hash01(cell_id, 23)))
			point.y = lerpf(center.y, point.y, lerpf(0.72, 1.22, _hash01(cell_id, 29)))
			var too_close := false
			for existing in accepted_points:
				if point.distance_to(existing) < 8.0:
					too_close = true
					break
			if too_close:
				_patch_spacing_rejected += 1
				continue
			var sample := _sample_ground(point)
			if sample.is_empty():
				_patch_ground_rejected += 1
				continue
			var ground: Vector3 = sample["position"]
			if not _within_placement_range(ground) or not _is_clear_of_route(ground) or not _is_clear_of_buildings(ground):
				_patch_landmark_rejected += 1
				continue
			var projection := _fixed_screen_projection(ground)
			var normalized := Vector2(projection.x / FIXED_SCREEN_SIZE.x, projection.y / FIXED_SCREEN_SIZE.y)
			if _camera.is_position_behind(ground) or projection.x < 960.0 or projection.x > 1910.0 or projection.y < 220.0 or projection.y > 500.0:
				_patch_screen_rejected += 1
				continue
			var nearest_source := _nearest_source_distance(point)
			## A soft radial edge mask leaves open gaps between irregular patches.
			if radius > 54.0 and _hash01(cell_id, 31) < 0.24:
				_patch_edge_rejected += 1
				continue
			var lower_mix := projection.y > 390.0
			var family := "conifer"
			if lower_mix and _hash01(cell_id, 37) < 0.20:
				family = "broadleaf"
			elif _hash01(cell_id, 41) < 0.10:
				family = "broadleaf"
			var variant := int(floori(_hash01(cell_id, 43) * 3.0))
			var width_scale := lerpf(0.78, 1.14, _hash01(cell_id, 47))
			var height_scale := lerpf(0.72, 1.12, _hash01(cell_id, 53))
			if family == "broadleaf":
				width_scale = lerpf(0.72, 1.18, _hash01(cell_id, 59))
				height_scale = lerpf(0.55, 0.88, _hash01(cell_id, 61))
			if lower_mix:
				height_scale *= lerpf(0.82, 0.96, _hash01(cell_id, 67))
			var yaw := lerpf(-PI, PI, _hash01(cell_id, 71))
			var tree_mesh := _tree_meshes.get("%s_%d" % [family, variant]) as Mesh
			if tree_mesh == null or not _surface_ground_range_ok(_tree_surface0_contact_points.get("%s_%d" % [family, variant], []), Basis(Vector3.UP, yaw).scaled(Vector3(width_scale, height_scale, width_scale)), Vector3(ground.x, ground.y - tree_mesh.get_aabb().position.y * height_scale - ROOT_BURY_M, ground.z)):
				_patch_range_rejected += 1
				continue
			var source_record := {
				"path": "generated://S03RightForestBand",
				"index": serial,
				"source_path": String(anchor.get("source_path", "World/Forest")),
				"source_index": int(anchor.get("source_index", -1)),
				"anchor_index": anchor_index,
				"source_nearest_distance_m": nearest_source,
				"candidate_ground": ground,
				"candidate_screen": projection,
				"candidate_screen_normalized": normalized,
				"ground_source": String(sample.get("source", "World/Landscape/SaisiesGeoTerrain surface0 mesh triangle")),
				"ground_triangle_start": int(sample.get("triangle_start", -1)),
				"ground_triangle_surface": int(sample.get("surface", -1)),
				"ground_triangle_barycentric": sample.get("barycentric", Vector3.ZERO),
				"ground_normal": sample.get("normal", Vector3.UP),
				"behind_camera": _camera.is_position_behind(ground),
				"in_frustum": _camera.is_position_in_frustum(ground),
			}
			var key := "%s_%d" % [family, variant]
			if not grouped.has(key):
				grouped[key] = []
			(grouped[key] as Array).append({
				"family": family,
				"variant": variant,
				"ground": ground,
				"width_scale": width_scale,
				"height_scale": height_scale,
				"yaw": yaw,
				"source_record": source_record,
			})
			accepted_points.append(point)
			serial += 1
		if serial >= MAX_NEW_TREES:
			break
	_new_count = serial
	for key in grouped.keys():
		for item in grouped[key]:
			if String(item["family"]) == "conifer":
				_conifer_count += 1
			else:
				_broadleaf_count += 1

func _surface_ground_range_ok(local_points: Array, basis: Basis, root_position: Vector3) -> bool:
	if local_points.size() != 4 or not root_position.is_finite():
		return false
	var min_ground := INF
	var max_ground := -INF
	for local_point_value in local_points:
		var local_point: Vector3 = local_point_value
		var world_point := root_position + basis * local_point
		if not world_point.is_finite():
			return false
		var sample := _sample_ground(Vector2(world_point.x, world_point.z))
		if sample.is_empty():
			return false
		var ground_position: Vector3 = sample["position"]
		if not ground_position.is_finite():
			return false
		min_ground = minf(min_ground, ground_position.y)
		max_ground = maxf(max_ground, ground_position.y)
	return is_finite(min_ground) and is_finite(max_ground) and max_ground - min_ground <= MAX_SURFACE_GROUND_RANGE_M

func _build_replacement_multimeshes(grouped: Dictionary) -> bool:
	for key in grouped.keys():
		var items: Array = grouped[key]
		var mesh := _tree_meshes.get(String(key)) as Mesh
		if mesh == null or items.is_empty():
			continue
		var contacts: Array[Vector3] = _tree_surface0_contact_points.get(String(key), [])
		if contacts.size() != 4:
			return false
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = items.size()
		var bounds := mesh.get_aabb()
		var records: Array[Dictionary] = []
		for index in items.size():
			var item: Dictionary = items[index]
			var width_scale := float(item["width_scale"])
			var height_scale := float(item["height_scale"])
			var basis := Basis(Vector3.UP, float(item["yaw"])).scaled(Vector3(width_scale, height_scale, width_scale))
			var ground: Vector3 = item["ground"]
			var root_position := Vector3(ground.x, ground.y - bounds.position.y * height_scale - ROOT_BURY_M, ground.z)
			var contact := _correct_tree_root_for_surface_contacts(contacts, basis, root_position, ground)
			if not bool(contact.get("valid", false)):
				return false
			root_position = contact["root_position"]
			var transform := Transform3D(basis, root_position)
			multimesh.set_instance_transform(index, transform)
			var initial_clearance := float(contact.get("initial_max_positive_clearance_m", 0.0))
			var additional_bury := float(contact.get("additional_bury_m", 0.0))
			var deep_burial := float(contact.get("deep_burial_m", 0.0))
			_surface0_contact_correction_count += 1 if additional_bury > 0.0 else 0
			_surface0_max_positive_clearance_m = maxf(_surface0_max_positive_clearance_m, initial_clearance)
			_surface0_max_burial_m = maxf(_surface0_max_burial_m, deep_burial)
			var source_record: Dictionary = item["source_record"]
			var record := {
				"path": String(source_record.get("path", "generated://S03RightForestBand")),
				## `index` is the local GPU/MultiMesh instance index. Keep the
				## deterministic scatter serial separately so native probes can
				## address the transform without reconstructing the grouping.
				"index": index,
				"candidate_index": int(source_record.get("index", index)),
				"family": String(item["family"]),
				"variant": int(item["variant"]),
				"transform": transform,
				"root_world": root_position,
				"ground": ground,
				"sampled_ground_y": ground.y,
				"ground_source": String(source_record.get("ground_source", "World/Landscape/SaisiesGeoTerrain surface0 mesh triangle")),
				"ground_triangle_start": int(source_record.get("ground_triangle_start", -1)),
				"ground_triangle_surface": int(source_record.get("ground_triangle_surface", -1)),
				"ground_triangle_barycentric": source_record.get("ground_triangle_barycentric", Vector3.ZERO),
				"ground_normal": source_record.get("ground_normal", Vector3.UP),
				"mesh_aabb": bounds,
				"mesh_bottom_world_y": root_position.y + bounds.position.y * height_scale,
				"ground_contact_error_m": root_position.y + bounds.position.y * height_scale - ground.y,
				"surface0_contact_points_local": contacts,
				"surface0_contact_points_world": contact["corrected_world_points"],
				"surface0_contact_ground_heights": contact["ground_heights"],
				"surface0_contact_ground_sources": contact["ground_sources"],
				"surface0_contact_triangle_starts": contact["ground_triangle_starts"],
				"surface0_contact_triangle_surfaces": contact["ground_triangle_surfaces"],
				"surface0_contact_barycentrics": contact["ground_barycentrics"],
				"surface0_contact_ground_range_m": contact.get("ground_range_m", 0.0),
				"surface0_initial_max_positive_clearance_m": contact["initial_max_positive_clearance_m"],
				"surface0_post_correction_max_positive_clearance_m": contact["post_correction_max_positive_clearance_m"],
				"surface0_initial_max_burial_m": contact["initial_max_burial_m"],
				"surface0_additional_bury_m": contact["additional_bury_m"],
				"surface0_deep_burial_m": contact["deep_burial_m"],
				"normal_source": "World/Landscape/SaisiesGeoTerrain transformed triangle",
				"source_path": String(source_record.get("source_path", "")),
				"source_index": int(source_record.get("source_index", -1)),
				"behind_camera": bool(source_record.get("behind_camera", false)),
				"in_frustum": bool(source_record.get("in_frustum", true)),
			}
			records.append(record)
			_replacement_records.append(record)
			var top_world := root_position + Vector3.UP * maxf(2.0, bounds.size.y * height_scale)
			_projection_records.append({
				"path": str(_replacement.get_path()),
				"family": String(item["family"]),
				"index": index,
				"root_world": root_position,
				"root_screen": _camera.unproject_position(root_position),
				"root_screen_fixed": _fixed_screen_projection(root_position),
				"top_world": top_world,
				"top_screen": _camera.unproject_position(top_world),
				"top_screen_fixed": _fixed_screen_projection(top_world),
				"behind_camera": _camera.is_position_behind(root_position),
				"in_frustum": _camera.is_position_in_frustum(root_position),
			})
		var instance := MultiMeshInstance3D.new()
		instance.name = "S03RightForest_%s" % String(key)
		instance.multimesh = multimesh
		instance.visibility_range_end = 0.0
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		instance.set_meta("saisies_s03_right_forest_family", String(items[0]["family"]))
		instance.set_meta("saisies_s03_right_forest_variant", int(items[0]["variant"]))
		instance.set_meta("saisies_s03_right_forest_instance_count", items.size())
		instance.set_meta("saisies_s03_right_forest_mesh_aabb", bounds)
		instance.set_meta("saisies_s03_right_forest_instance_records", records)
		instance.set_meta("saisies_s03_right_forest_surface0_contact_points_local", contacts)
		instance.set_meta("saisies_s03_right_forest_surface0_contact_band_m", SURFACE0_BAND_M)
		instance.set_meta("saisies_s03_right_forest_surface0_contact_contract", "indexed surface0 used vertices within min_y+0.035, four XZ extremes, visible SaisiesGeoTerrain triangle samples after full instance basis")
		_replacement.add_child(instance)
		for record in records:
			record["path"] = str(instance.get_path())
			record["replacement_path"] = str(instance.get_path())
	return true

func _load_tree_meshes() -> Dictionary:
	var result: Dictionary = {}
	var conifers: Array = TREE_FACTORY.conifer_variants()
	var broadleaf: Array = TREE_FACTORY.broadleaf_variants()
	var conifer_tints := [Color(0.43, 0.65, 0.29, 1.0), Color(0.36, 0.58, 0.24, 1.0), Color(0.48, 0.69, 0.33, 1.0)]
	var conifer_dense := [Color(0.018, 0.060, 0.014, 1.0), Color(0.014, 0.050, 0.012, 1.0), Color(0.022, 0.070, 0.018, 1.0)]
	var broadleaf_tints := [Color(0.50, 0.70, 0.30, 1.0), Color(0.58, 0.75, 0.37, 1.0), Color(0.44, 0.64, 0.25, 1.0)]
	for index in mini(3, conifers.size()):
		var key := "conifer_%d" % index
		var mesh: Mesh = _tinted_local_mesh(conifers[index] as Mesh, Color(0.18, 0.16, 0.12, 1.0), conifer_tints[index], conifer_dense[index])
		if mesh == null:
			continue
		result[key] = mesh
		_tree_surface0_contact_points[key] = _build_surface0_contact_points(mesh)
	for index in mini(3, broadleaf.size()):
		var key := "broadleaf_%d" % index
		var mesh: Mesh = _tinted_local_mesh(broadleaf[index] as Mesh, Color(0.20, 0.17, 0.12, 1.0), broadleaf_tints[index], Color(0.045, 0.11, 0.025, 1.0))
		if mesh == null:
			continue
		result[key] = mesh
		_tree_surface0_contact_points[key] = _build_surface0_contact_points(mesh)
	return result

func _tinted_local_mesh(source_mesh: Mesh, bark_tint: Color, foliage_tint: Color, dense_color: Color) -> Mesh:
	if source_mesh == null:
		return null
	var copy := source_mesh.duplicate() as ArrayMesh
	if copy == null:
		return source_mesh
	for surface_idx in copy.get_surface_count():
		var material := copy.surface_get_material(surface_idx)
		if not material is StandardMaterial3D:
			continue
		var local_material := (material as StandardMaterial3D).duplicate() as StandardMaterial3D
		local_material.disable_fog = true
		local_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		local_material.roughness = 0.96
		if surface_idx == 0:
			local_material.albedo_color = bark_tint
		elif surface_idx == 1:
			local_material.albedo_color = local_material.albedo_color * foliage_tint
			local_material.emission_enabled = true
			local_material.emission = Color(0.008, 0.026, 0.004, 1.0)
			local_material.emission_energy_multiplier = 0.28
			local_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			local_material.alpha_scissor_threshold = maxf(local_material.alpha_scissor_threshold, 0.24)
		elif surface_idx == 2:
			local_material.albedo_color = dense_color if local_material.albedo_texture == null else bark_tint
			local_material.emission_enabled = true
			local_material.emission = Color(0.006, 0.020, 0.003, 1.0)
			local_material.emission_energy_multiplier = 0.22
		copy.surface_set_material(surface_idx, local_material)
	return copy

func _build_surface0_contact_points(mesh: Mesh) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if mesh == null or mesh.get_surface_count() <= 0:
		return points
	var arrays: Array = mesh.surface_get_arrays(0)
	if arrays.is_empty() or arrays.size() <= Mesh.ARRAY_VERTEX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
		return points
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var used_indices := PackedInt32Array()
	if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
		used_indices = arrays[Mesh.ARRAY_INDEX]
	if used_indices.is_empty():
		used_indices.resize(vertices.size())
		for index in vertices.size():
			used_indices[index] = index
	var min_y := INF
	for index in used_indices:
		if index >= 0 and index < vertices.size() and vertices[index].is_finite():
			min_y = minf(min_y, vertices[index].y)
	if not is_finite(min_y):
		return points
	var lowest: Array[Vector3] = []
	for index in used_indices:
		if index >= 0 and index < vertices.size() and vertices[index].is_finite() and vertices[index].y <= min_y + SURFACE0_BAND_M:
			lowest.append(vertices[index])
	if lowest.is_empty():
		return points
	var min_x := 0
	var max_x := 0
	var min_z := 0
	var max_z := 0
	for index in lowest.size():
		if lowest[index].x < lowest[min_x].x: min_x = index
		if lowest[index].x > lowest[max_x].x: max_x = index
		if lowest[index].z < lowest[min_z].z: min_z = index
		if lowest[index].z > lowest[max_z].z: max_z = index
	for extreme in [min_x, max_x, min_z, max_z]:
		var point: Vector3 = lowest[int(extreme)]
		var duplicate := false
		for existing in points:
			if existing.distance_squared_to(point) <= 0.000001:
				duplicate = true
				break
		if not duplicate:
			points.append(point)
	for point in lowest:
		if points.size() >= 4:
			break
		var duplicate := false
		for existing in points:
			if existing.distance_squared_to(point) <= 0.000001:
				duplicate = true
				break
		if not duplicate:
			points.append(point)
	return points

func _correct_tree_root_for_surface_contacts(local_points: Array[Vector3], basis: Basis, root_position: Vector3, fallback_ground: Vector3) -> Dictionary:
	if local_points.size() != 4 or not root_position.is_finite() or not fallback_ground.is_finite():
		return {"valid": false}
	var initial_world_points := PackedVector3Array()
	var corrected_world_points := PackedVector3Array()
	var ground_heights := PackedFloat32Array()
	var ground_sources: Array[String] = []
	var ground_triangle_starts := PackedInt32Array()
	var ground_triangle_surfaces := PackedInt32Array()
	var ground_barycentrics := PackedVector3Array()
	var min_ground := INF
	var max_ground := -INF
	var max_positive_clearance := 0.0
	var initial_max_burial := 0.0
	for local_point in local_points:
		var world_point := root_position + basis * local_point
		if not world_point.is_finite():
			return {"valid": false}
		var sample := _sample_ground(Vector2(world_point.x, world_point.z))
		var ground_y := fallback_ground.y
		var source := "fallback_instance_ground"
		var triangle_start := -1
		var triangle_surface := -1
		var barycentric := Vector3.ZERO
		if not sample.is_empty():
			var sample_position: Vector3 = sample["position"]
			if sample_position.is_finite():
				ground_y = sample_position.y
				source = String(sample.get("source", "World/Landscape/SaisiesGeoTerrain surface0 mesh triangle"))
				triangle_start = int(sample.get("triangle_start", -1))
				triangle_surface = int(sample.get("surface", -1))
				barycentric = sample.get("barycentric", Vector3.ZERO)
		var clearance := world_point.y - ground_y
		max_positive_clearance = maxf(max_positive_clearance, maxf(clearance, 0.0))
		initial_max_burial = maxf(initial_max_burial, maxf(-clearance, 0.0))
		initial_world_points.append(world_point)
		ground_heights.append(ground_y)
		ground_sources.append(source)
		ground_triangle_starts.append(triangle_start)
		ground_triangle_surfaces.append(triangle_surface)
		ground_barycentrics.append(barycentric)
		min_ground = minf(min_ground, ground_y)
		max_ground = maxf(max_ground, ground_y)
	if not is_finite(min_ground) or not is_finite(max_ground) or max_ground - min_ground > MAX_SURFACE_GROUND_RANGE_M:
		return {"valid": false, "ground_range_rejected": true, "ground_range_m": max_ground - min_ground}
	var additional_bury := max_positive_clearance + ROOT_BURY_M if max_positive_clearance > 0.0 else 0.0
	var corrected_root := root_position - Vector3.UP * additional_bury
	var corrected_max_positive := 0.0
	var corrected_max_burial := 0.0
	for index in initial_world_points.size():
		var corrected_point: Vector3 = initial_world_points[index] - Vector3.UP * additional_bury
		var clearance := corrected_point.y - ground_heights[index]
		corrected_max_positive = maxf(corrected_max_positive, maxf(clearance, 0.0))
		corrected_max_burial = maxf(corrected_max_burial, maxf(-clearance, 0.0))
		corrected_world_points.append(corrected_point)
	return {
		"valid": corrected_root.is_finite() and corrected_max_positive <= 0.001,
		"root_position": corrected_root,
		"initial_world_points": initial_world_points,
		"corrected_world_points": corrected_world_points,
		"ground_heights": ground_heights,
		"ground_sources": ground_sources,
		"ground_triangle_starts": ground_triangle_starts,
		"ground_triangle_surfaces": ground_triangle_surfaces,
		"ground_barycentrics": ground_barycentrics,
		"ground_range_m": max_ground - min_ground,
		"initial_max_positive_clearance_m": max_positive_clearance,
		"post_correction_max_positive_clearance_m": corrected_max_positive,
		"initial_max_burial_m": initial_max_burial,
		"deep_burial_m": corrected_max_burial,
		"additional_bury_m": additional_bury,
	}

func _sample_ground(point: Vector2) -> Dictionary:
	_visible_ground_sample_count += 1
	var visible := _sample_visible_ground(point)
	var overlay := _sample_s01_overlay_ground(point)
	if visible.is_empty():
		return overlay
	if overlay.is_empty():
		return visible
	var visible_position: Vector3 = visible["position"]
	var overlay_position: Vector3 = overlay["position"]
	return overlay if overlay_position.y > visible_position.y else visible

func _prepare_visible_ground_cache() -> bool:
	_visible_ground_triangles.clear()
	_visible_ground_triangle_bins.clear()
	_visible_ground_scan_triangle_count = 0
	_visible_ground_triangle_count = 0
	_visible_ground_sample_count = 0
	if _visible_ground_bounds.size.x <= 0.0 or _visible_ground_bounds.size.y <= 0.0:
		_visible_ground_bounds = FALLBACK_WORLD_BOUNDS.grow(VISIBLE_GROUND_CACHE_MARGIN_M)
	_visible_ground_mesh_path = ""
	if _terrain_mesh_instance == null or _terrain_mesh_instance.mesh == null:
		return false
	var mesh := _terrain_mesh_instance.mesh
	var transform := _terrain_mesh_instance.global_transform
	_visible_ground_mesh_path = str(_terrain_mesh_instance.get_path())
	for surface_index in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var raw_vertices: Variant = arrays[Mesh.ARRAY_VERTEX]
		if not raw_vertices is PackedVector3Array:
			continue
		var vertices: PackedVector3Array = raw_vertices
		if vertices.size() < 3:
			continue
		var raw_indices: Variant = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX else null
		if raw_indices is PackedInt32Array and (raw_indices as PackedInt32Array).size() >= 3:
			var indices: PackedInt32Array = raw_indices
			for start in range(0, indices.size() - 2, 3):
				var ia := int(indices[start])
				var ib := int(indices[start + 1])
				var ic := int(indices[start + 2])
				if ia < 0 or ib < 0 or ic < 0 or ia >= vertices.size() or ib >= vertices.size() or ic >= vertices.size():
					continue
				var a := transform * vertices[ia]
				var b := transform * vertices[ib]
				var c := transform * vertices[ic]
				if not a.is_finite() or not b.is_finite() or not c.is_finite():
					continue
				_visible_ground_scan_triangle_count += 1
				if not _triangle_intersects_bounds(a, b, c, _visible_ground_bounds):
					continue
				var triangle_index := _visible_ground_triangles.size()
				_visible_ground_triangles.append({"a": a, "b": b, "c": c, "start": start, "surface": surface_index})
				_index_visible_ground_triangle_bins(triangle_index, a, b, c)
		else:
			for start in range(0, vertices.size() - 2, 3):
				var a := transform * vertices[start]
				var b := transform * vertices[start + 1]
				var c := transform * vertices[start + 2]
				if not a.is_finite() or not b.is_finite() or not c.is_finite():
					continue
				_visible_ground_scan_triangle_count += 1
				if not _triangle_intersects_bounds(a, b, c, _visible_ground_bounds):
					continue
				var triangle_index := _visible_ground_triangles.size()
				_visible_ground_triangles.append({"a": a, "b": b, "c": c, "start": start, "surface": surface_index})
				_index_visible_ground_triangle_bins(triangle_index, a, b, c)
	_visible_ground_triangle_count = _visible_ground_triangles.size()
	return _visible_ground_triangle_count > 0

func _visible_ground_bin_key(x: int, z: int) -> String:
	return "%d:%d" % [x, z]

func _index_visible_ground_triangle_bins(triangle_index: int, a: Vector3, b: Vector3, c: Vector3) -> void:
	var min_x := floori(minf(a.x, minf(b.x, c.x)) / VISIBLE_GROUND_BIN_M)
	var max_x := floori(maxf(a.x, maxf(b.x, c.x)) / VISIBLE_GROUND_BIN_M)
	var min_z := floori(minf(a.z, minf(b.z, c.z)) / VISIBLE_GROUND_BIN_M)
	var max_z := floori(maxf(a.z, maxf(b.z, c.z)) / VISIBLE_GROUND_BIN_M)
	for bin_x in range(min_x, max_x + 1):
		for bin_z in range(min_z, max_z + 1):
			var key := _visible_ground_bin_key(bin_x, bin_z)
			if not _visible_ground_triangle_bins.has(key):
				_visible_ground_triangle_bins[key] = []
			(_visible_ground_triangle_bins[key] as Array).append(triangle_index)

func _sample_visible_ground(point: Vector2) -> Dictionary:
	if _visible_ground_triangles.is_empty() or not _visible_ground_bounds.grow(0.001).has_point(Vector2(point.x, point.y)):
		return {}
	var bin_x := floori(point.x / VISIBLE_GROUND_BIN_M)
	var bin_z := floori(point.y / VISIBLE_GROUND_BIN_M)
	var seen: Dictionary = {}
	var best_y := -INF
	var best: Dictionary = {}
	for offset_x in range(-1, 2):
		for offset_z in range(-1, 2):
			var bucket: Array = _visible_ground_triangle_bins.get(_visible_ground_bin_key(bin_x + offset_x, bin_z + offset_z), [])
			for raw_index in bucket:
				var triangle_index := int(raw_index)
				if seen.has(triangle_index):
					continue
				seen[triangle_index] = true
				var triangle: Dictionary = _visible_ground_triangles[triangle_index]
				var a: Vector3 = triangle["a"]
				var b: Vector3 = triangle["b"]
				var c: Vector3 = triangle["c"]
				var barycentric := _barycentric_xz(point, a, b, c)
				if barycentric.x < -0.0005 or barycentric.y < -0.0005 or barycentric.z < -0.0005:
					continue
				var height := a.y * barycentric.x + b.y * barycentric.y + c.y * barycentric.z
				if not is_finite(height) or height <= best_y:
					continue
				var normal := (b - a).cross(c - a)
				if normal.length_squared() > 0.000001:
					normal = normal.normalized()
					if normal.y < 0.0:
						normal = -normal
				else:
					normal = Vector3.UP
				best_y = height
				best = {
					"position": Vector3(point.x, height, point.y),
					"normal": normal,
					"source": "World/Landscape/SaisiesGeoTerrain surface%d mesh triangle" % int(triangle["surface"]),
					"triangle_start": int(triangle["start"]),
					"surface": int(triangle["surface"]),
					"barycentric": barycentric,
					"triangle_a": a,
					"triangle_b": b,
					"triangle_c": c,
				}
	return best

func _sample_s01_overlay_ground(point: Vector2) -> Dictionary:
	if _landscape == null or not _landscape.has_method("_sample_ground"):
		return {}
	var raw: Variant = _landscape.call("_sample_ground", point)
	if not raw is Dictionary or not raw.has("position"):
		return {}
	var sampled: Dictionary = raw
	var sampled_position: Vector3 = sampled["position"]
	if not sampled_position.is_finite():
		return {}
	var source := String(sampled.get("source", ""))
	if source != "s01_local_terrain_overlay" and source != "Landscape.sample_mesh_triangle":
		return {}
	var result := sampled.duplicate(true)
	result["triangle_start"] = int(result.get("overlay_triangle_start", result.get("triangle_start", -1)))
	result["surface"] = int(result.get("surface", -1))
	result["barycentric"] = result.get("overlay_barycentric", result.get("barycentric", Vector3.ZERO))
	result["source"] = "S01Landscape visible overlay triangle" if source == "s01_local_terrain_overlay" else source
	return result

func _triangle_intersects_bounds(a: Vector3, b: Vector3, c: Vector3, bounds: Rect2) -> bool:
	var min_x := minf(a.x, minf(b.x, c.x))
	var max_x := maxf(a.x, maxf(b.x, c.x))
	var min_z := minf(a.z, minf(b.z, c.z))
	var max_z := maxf(a.z, maxf(b.z, c.z))
	return max_x >= bounds.position.x and min_x <= bounds.end.x and max_z >= bounds.position.y and min_z <= bounds.end.y

func _barycentric_xz(point: Vector2, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 := Vector2(b.x - a.x, b.z - a.z)
	var v1 := Vector2(c.x - a.x, c.z - a.z)
	var v2 := point - Vector2(a.x, a.z)
	var denominator := v0.x * v1.y - v1.x * v0.y
	if absf(denominator) <= 0.000001:
		return Vector3(-INF, -INF, -INF)
	var weight_b := (v2.x * v1.y - v1.x * v2.y) / denominator
	var weight_c := (v0.x * v2.y - v2.x * v0.y) / denominator
	return Vector3(1.0 - weight_b - weight_c, weight_b, weight_c)

func _collect_building_bounds() -> void:
	var buildings := _world.get_node_or_null("Buildings")
	if buildings == null:
		return
	for candidate in buildings.find_children("*", "MeshInstance3D", true, false):
		var instance := candidate as MeshInstance3D
		if instance == null or instance.mesh == null:
			continue
		var local := instance.get_aabb()
		var world_bounds := _transform_aabb(instance.global_transform, local)
		if world_bounds.size.x <= 120.0 and world_bounds.size.z <= 120.0 and world_bounds.size.y <= 80.0:
			_building_bounds.append(world_bounds)

func _is_clear_of_buildings(point: Vector3) -> bool:
	for bounds in _building_bounds:
		var dx := maxf(maxf(bounds.position.x - point.x, 0.0), point.x - bounds.end.x)
		var dz := maxf(maxf(bounds.position.z - point.z, 0.0), point.z - bounds.end.z)
		if Vector2(dx, dz).length() < 18.0:
			return false
	return true

func _is_clear_of_route(point: Vector3) -> bool:
	if _route == null or not _route.has_method("distance_for_position") or not _route.has_method("pos_at"):
		return true
	var station := float(_route.call("distance_for_position", point))
	if not is_finite(station):
		return true
	var route_position := Vector3(_route.call("pos_at", station))
	return Vector2(point.x - route_position.x, point.z - route_position.z).length() >= 38.0

func _nearest_source_distance(point: Vector2) -> float:
	if _source_points.is_empty():
		return 0.0
	var nearest := INF
	for source in _source_points:
		nearest = minf(nearest, point.distance_to(source))
	return nearest

func _within_camera_gate(point: Vector3) -> bool:
	return point.distance_to(CAMERA_GATE_CENTER) <= CAMERA_GATE_END_M

func _within_placement_range(point: Vector3) -> bool:
	return point.distance_to(CAMERA_GATE_CENTER) <= PLACEMENT_RANGE_END_M

func _update_lod_gate() -> void:
	if _camera == null or _replacement == null:
		return
	var distance := _camera.global_position.distance_to(CAMERA_GATE_CENTER)
	var active := _within_camera_gate(_camera.global_position)
	if active != _lod_active:
		_lod_active = active
		_replacement.visible = active
	set_meta("saisies_s03_right_forest_lod_active", active)
	set_meta("saisies_s03_right_forest_camera_gate_distance_m", distance)

func _all_geometry_finite() -> bool:
	if _new_count < MIN_NEW_TREES or _replacement_records.size() != _new_count:
		return false
	for record in _replacement_records:
		var root_world: Vector3 = record.get("root_world", Vector3.INF)
		var transform: Transform3D = record.get("transform", Transform3D())
		if not root_world.is_finite() or not transform.is_finite():
			return false
		if not is_finite(float(record.get("sampled_ground_y", NAN))):
			return false
		var ground_source := String(record.get("ground_source", ""))
		if not ground_source.contains("SaisiesGeoTerrain") and not ground_source.contains("visible overlay"):
			return false
		if float(record.get("ground_contact_error_m", INF)) > ROOT_BURY_M + 0.001:
			return false
		if float(record.get("surface0_post_correction_max_positive_clearance_m", INF)) > 0.001:
			return false
	return true

func _publish_ready_state() -> void:
	set_meta("saisies_s03_right_forest_refinement_ready", true)
	set_meta("saisies_s03_right_forest_refinement_enabled", true)
	set_meta("saisies_s03_right_forest_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_right_forest_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_right_forest_candidate_path", str(_replacement.get_path()))
	set_meta("saisies_s03_right_forest_instance_records", _replacement_records)
	set_meta("saisies_s03_right_forest_ground_records", _replacement_records)
	set_meta("saisies_s03_right_forest_projection_records", _projection_records)
	set_meta("saisies_s03_right_forest_roi_anchor_records", _anchor_records)
	set_meta("saisies_s03_right_forest_authored_anchor_count", _anchor_records.size())
	set_meta("saisies_s03_right_forest_authored_anchor_projection_bounds", _anchor_projection_bounds(_anchor_records))
	set_meta("saisies_s03_right_forest_roi_bounds_xz", _roi_bounds)
	set_meta("saisies_s03_right_forest_new_count", _new_count)
	set_meta("saisies_s03_right_forest_conifer_count", _conifer_count)
	set_meta("saisies_s03_right_forest_broadleaf_count", _broadleaf_count)
	set_meta("saisies_s03_right_forest_counts", {"new": _new_count, "conifer": _conifer_count, "broadleaf": _broadleaf_count, "surface0_contact_corrections": _surface0_contact_correction_count})
	set_meta("saisies_s03_right_forest_surface0_contact_correction_count", _surface0_contact_correction_count)
	set_meta("saisies_s03_right_forest_surface0_max_positive_clearance_m", _surface0_max_positive_clearance_m)
	set_meta("saisies_s03_right_forest_surface0_max_burial_m", _surface0_max_burial_m)
	set_meta("saisies_s03_right_forest_surface0_contact_contract", "indexed surface0 used vertices within min_y+0.035; four XZ extremes per mesh; visible SaisiesGeoTerrain triangle samples after full instance basis; only positive clearance moves roots downward")
	set_meta("saisies_s03_right_forest_ground_source", "World/Landscape/SaisiesGeoTerrain transformed ArrayMesh triangles; S01 visible overlay takes max")
	set_meta("saisies_s03_right_forest_ground_mesh_path", _visible_ground_mesh_path)
	set_meta("saisies_s03_right_forest_ground_mesh_scan_triangle_count", _visible_ground_scan_triangle_count)
	set_meta("saisies_s03_right_forest_ground_mesh_cached_triangle_count", _visible_ground_triangle_count)
	set_meta("saisies_s03_right_forest_ground_mesh_cache_bounds_xz", _visible_ground_bounds)
	set_meta("saisies_s03_right_forest_ground_sample_count", _visible_ground_sample_count)
	set_meta("saisies_s03_right_forest_ground_dem_fallback_used", false)
	set_meta("saisies_s03_right_forest_ground_dem_role", "readiness/contrast only; never used as candidate or contact ground")
	set_meta("saisies_s03_right_forest_patch_reject_counts", {"ground": _patch_ground_rejected, "landmark": _patch_landmark_rejected, "screen": _patch_screen_rejected, "edge": _patch_edge_rejected, "ground_range": _patch_range_rejected, "spacing": _patch_spacing_rejected})
	set_meta("saisies_s03_right_forest_screen_roi", Rect2(ANCHOR_SCREEN_MIN_X, ANCHOR_SCREEN_MIN_Y, ANCHOR_SCREEN_MAX_X - ANCHOR_SCREEN_MIN_X, ANCHOR_SCREEN_MAX_Y - ANCHOR_SCREEN_MIN_Y))
	set_meta("saisies_s03_right_forest_close_camera", _close_camera_world)
	set_meta("saisies_s03_right_forest_close_target", _close_target_world)
	set_meta("saisies_s03_right_forest_close_fov_deg", CLOSE_FOV_DEG)
	set_meta("saisies_s03_right_forest_lod_gate", {"center": CAMERA_GATE_CENTER, "full_m": CAMERA_GATE_FULL_M, "end_m": CAMERA_GATE_END_M, "active": _lod_active})
	set_meta("saisies_s03_right_forest_no_old_nodes_hidden", true)
	set_meta("saisies_s03_right_forest_geometry_contract", "local shared treefactory MultiMesh additions only; no terrain, camera, light, building, route, or inherited forest edits")
	_publish_parent_ready(true)

func _publish_disabled_state() -> void:
	set_meta("saisies_s03_right_forest_refinement_ready", true)
	set_meta("saisies_s03_right_forest_refinement_enabled", false)
	set_meta("saisies_s03_right_forest_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_right_forest_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_right_forest_new_count", 0)
	set_meta("saisies_s03_right_forest_close_camera", _camera.global_position if _camera != null else CLOSE_CAMERA_WORLD)
	set_meta("saisies_s03_right_forest_close_target", CLOSE_TARGET_WORLD)
	set_meta("saisies_s03_right_forest_close_fov_deg", CLOSE_FOV_DEG)
	set_meta("saisies_s03_right_forest_ground_source", "disabled baseline")
	_publish_parent_ready(false)

func _publish_parent_ready(enabled: bool) -> void:
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s03_right_forest_review_ready", true)
		parent.set_meta("saisies_s03_right_forest_review_enabled", enabled)
		parent.set_meta("saisies_s03_right_forest_review_source_frame", SOURCE_FRAME)
	var current := get_tree().current_scene
	if current != null:
		current.set_meta("saisies_s03_right_forest_review_ready", true)
		current.set_meta("saisies_s03_right_forest_review_enabled", enabled)

func _transform_aabb(transform: Transform3D, bounds: AABB) -> AABB:
	var result := AABB(transform * bounds.position, Vector3.ZERO)
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			for z in [bounds.position.z, bounds.end.z]:
				result = result.expand(transform * Vector3(x, y, z))
	return result

func _fixed_screen_projection(point: Vector3) -> Vector2:
	if _camera == null or not point.is_finite():
		return Vector2(INF, INF)
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		viewport_size = FIXED_SCREEN_SIZE
	var projected := _camera.unproject_position(point)
	return Vector2(projected.x / viewport_size.x * FIXED_SCREEN_SIZE.x, projected.y / viewport_size.y * FIXED_SCREEN_SIZE.y)

func _hash01(value: int, salt: int) -> float:
	var noise := sin(float(value) * 12.9898 + float(salt) * 78.233) * 43758.5453
	return noise - floor(noise)

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
	set_meta("saisies_s03_right_forest_refinement_ready", false)
	set_meta("saisies_s03_right_forest_refinement_error", message)
	_publish_parent_ready(false)
	push_error(message)

func _has_command_line_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()
