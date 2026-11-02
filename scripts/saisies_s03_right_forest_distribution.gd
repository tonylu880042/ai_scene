extends "res://scripts/saisies_s03_right_forest_refinement.gd"

## R28 distribution pass for the S03 screen-right forest band.
##
## The R24 helper remains the owner of terrain sampling, tree meshes, contact
## correction, and MultiMesh construction. This pass only rebalances the
## authored anchors across the visible right-slope span and appends a larger,
## irregular scatter so the far-right gap is filled without a grid or wall.

@export var legacy_right_forest_refinement_path: NodePath = NodePath("../JunctionShapeReview/ParasolReview/CafeTreesReview/RightForestReview/RightForestRefinement")

const DISTRIBUTION_ANCHOR_MIN_X := 1050.0
const DISTRIBUTION_ANCHOR_MAX_X := 1900.0
const DISTRIBUTION_ANCHOR_MIN_Y := 300.0
const DISTRIBUTION_ANCHOR_MAX_Y := 430.0
const DISTRIBUTION_ANCHOR_LIMIT := 16
const DISTRIBUTION_ANCHOR_BUCKETS := 8
const DISTRIBUTION_ANCHOR_WORLD_SEPARATION_M := 22.0
const DISTRIBUTION_ANCHOR_SCREEN_SEPARATION_PX := 44.0
const DISTRIBUTION_MAX_NEW_TREES := 900
const DISTRIBUTION_MIN_NEW_TREES := 650
const DISTRIBUTION_EXTRA_ATTEMPTS_PER_ANCHOR := 128
const DISTRIBUTION_POINT_MIN_RADIUS_M := 8.0
const DISTRIBUTION_POINT_MAX_RADIUS_M := 92.0
const DISTRIBUTION_POINT_SPACING_M := 6.0
const DISTRIBUTION_MIN_CAMERA_DISTANCE_M := 450.0
const DISTRIBUTION_SCREEN_MIN_X := 1000.0
const DISTRIBUTION_SCREEN_MAX_X := 1910.0
const DISTRIBUTION_SCREEN_MIN_Y := 220.0
const DISTRIBUTION_SCREEN_MAX_Y := 500.0

var _legacy_right_forest_refinement: Node

func _ready() -> void:
	process_priority = -70
	if _has_command_line_flag("--s03-right-forest-distribution-off"):
		enable_refinement = false
	call_deferred("_try_build")

func _try_build() -> void:
	if _legacy_right_forest_refinement == null:
		_legacy_right_forest_refinement = get_node_or_null(legacy_right_forest_refinement_path)
	super._try_build()
	if not enable_refinement:
		_set_legacy_visibility(true)
	elif _built:
		_set_legacy_visibility(false)

func _process(_delta: float) -> void:
	if not enable_refinement:
		_set_legacy_visibility(true)
		return
	if not _built or _camera == null:
		return
	_update_lod_gate()
	_set_legacy_visibility(false)
	set_meta("saisies_s03_right_forest_distribution_lod_active", _lod_active)

func _sample_forest_anchor_candidates(candidates: Array[Dictionary]) -> Array[Dictionary]:
	## Take one deterministic but nonuniform candidate from each screen bucket,
	## then fill a second candidate pass by screen/world separation. This keeps
	## the whole x=1050..1900 span represented instead of stopping at x~1650.
	var selected_candidates: Array[Dictionary] = []
	var bucket_width := (DISTRIBUTION_ANCHOR_MAX_X - DISTRIBUTION_ANCHOR_MIN_X) / float(DISTRIBUTION_ANCHOR_BUCKETS)
	for bucket in DISTRIBUTION_ANCHOR_BUCKETS:
		var best: Dictionary = {}
		var best_score := -INF
		for candidate in candidates:
			var screen: Vector2 = candidate.get("screen", Vector2.INF)
			var bucket_index := clampi(floori((screen.x - DISTRIBUTION_ANCHOR_MIN_X) / bucket_width), 0, DISTRIBUTION_ANCHOR_BUCKETS - 1)
			if bucket_index != bucket or not _distribution_anchor_is_separated(candidate, selected_candidates):
				continue
			var source_index := int(candidate.get("source_index", 0))
			var y_variation := absf(screen.y - 364.0) / 90.0
			var score := _hash01(source_index + bucket * 97, 17) * 2.0 + y_variation
			if score > best_score:
				best_score = score
				best = candidate
		if not best.is_empty():
			selected_candidates.append(best)

	while selected_candidates.size() < DISTRIBUTION_ANCHOR_LIMIT:
		var best: Dictionary = {}
		var best_score := -INF
		for candidate in candidates:
			if selected_candidates.has(candidate) or not _distribution_anchor_is_separated(candidate, selected_candidates):
				continue
			var screen: Vector2 = candidate.get("screen", Vector2.INF)
			var nearest_screen := INF
			for selected in selected_candidates:
				nearest_screen = minf(nearest_screen, screen.distance_to(selected.get("screen", Vector2.INF)))
			var score := nearest_screen + _hash01(int(candidate.get("source_index", 0)), 29) * 18.0
			if score > best_score:
				best_score = score
				best = candidate
		if best.is_empty():
			break
		selected_candidates.append(best)

	var anchors: Array[Dictionary] = []
	for candidate in selected_candidates:
		var world_position: Vector3 = candidate.get("world", Vector3.INF)
		var sample := _sample_ground(Vector2(world_position.x, world_position.z))
		if sample.is_empty():
			continue
		var record := candidate.duplicate(true)
		record["ground"] = sample["position"]
		record["ground_source"] = String(sample.get("source", "World/Landscape/SaisiesGeoTerrain surface0 mesh triangle"))
		record["ground_triangle_start"] = int(sample.get("triangle_start", -1))
		record["ground_triangle_surface"] = int(sample.get("surface", -1))
		record["ground_triangle_barycentric"] = sample.get("barycentric", Vector3.ZERO)
		record["normal"] = sample.get("normal", Vector3.UP)
		record["behind_camera"] = _camera.is_position_behind(world_position)
		record["in_frustum"] = true
		anchors.append(record)
	return anchors

func _distribution_anchor_is_separated(candidate: Dictionary, selected: Array[Dictionary]) -> bool:
	var world_position: Vector3 = candidate.get("world", Vector3.INF)
	var screen: Vector2 = candidate.get("screen", Vector2.INF)
	for other in selected:
		var other_world: Vector3 = other.get("world", Vector3.INF)
		var other_screen: Vector2 = other.get("screen", Vector2.INF)
		if Vector2(world_position.x, world_position.z).distance_to(Vector2(other_world.x, other_world.z)) < DISTRIBUTION_ANCHOR_WORLD_SEPARATION_M:
			return false
		if screen.distance_to(other_screen) < DISTRIBUTION_ANCHOR_SCREEN_SEPARATION_PX:
			return false
	return true

func _collect_generated_items(grouped: Dictionary, anchors: Array[Dictionary]) -> void:
	## Keep the accepted R24 scatter as a seed, then append only the extra
	## irregular groups required by R28. All geometry/contact checks stay in the
	## inherited helper.
	super._collect_generated_items(grouped, anchors)
	if _new_count >= DISTRIBUTION_MAX_NEW_TREES:
		return
	var occupied: Array[Vector2] = []
	for key in grouped.keys():
		for item in grouped[key] as Array:
			var existing_ground: Vector3 = item.get("ground", Vector3.INF)
			if existing_ground.is_finite():
				occupied.append(Vector2(existing_ground.x, existing_ground.z))
	var serial := _new_count
	for anchor_index in anchors.size():
		if serial >= DISTRIBUTION_MAX_NEW_TREES:
			break
		var anchor: Dictionary = anchors[anchor_index]
		var anchor_ground: Vector3 = anchor.get("ground", Vector3.INF)
		var center := Vector2(anchor_ground.x, anchor_ground.z)
		for local_index in DISTRIBUTION_EXTRA_ATTEMPTS_PER_ANCHOR:
			if serial >= DISTRIBUTION_MAX_NEW_TREES:
				break
			var cell_id := 100000 + anchor_index * 8192 + local_index
			var angle := _hash01(cell_id, 7) * TAU + _hash01(cell_id, 11) * 0.42
			var radius := lerpf(DISTRIBUTION_POINT_MIN_RADIUS_M, DISTRIBUTION_POINT_MAX_RADIUS_M, sqrt(_hash01(cell_id, 13)))
			var point := center + Vector2(cos(angle), sin(angle)) * radius
			point.x += lerpf(-10.0, 10.0, _hash01(cell_id, 17))
			point.y += lerpf(-10.0, 10.0, _hash01(cell_id, 19))
			point = center.lerp(point, lerpf(0.58, 1.08, _hash01(cell_id, 23)))
			var too_close := false
			for existing in occupied:
				if point.distance_to(existing) < DISTRIBUTION_POINT_SPACING_M:
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
			if ground.distance_to(_camera.global_position) <= DISTRIBUTION_MIN_CAMERA_DISTANCE_M or not _within_placement_range(ground) or not _is_clear_of_route(ground) or not _is_clear_of_buildings(ground):
				_patch_landmark_rejected += 1
				continue
			var projection := _fixed_screen_projection(ground)
			if _camera.is_position_behind(ground) or projection.x < DISTRIBUTION_SCREEN_MIN_X or projection.x > DISTRIBUTION_SCREEN_MAX_X or projection.y < DISTRIBUTION_SCREEN_MIN_Y or projection.y > DISTRIBUTION_SCREEN_MAX_Y:
				_patch_screen_rejected += 1
				continue
			var lower_mix := projection.y > 390.0
			var family := "conifer"
			if (lower_mix and _hash01(cell_id, 37) < 0.16) or _hash01(cell_id, 41) < 0.07:
				family = "broadleaf"
			var variant := int(floori(_hash01(cell_id, 43) * 3.0))
			var width_scale := lerpf(0.76, 1.22, _hash01(cell_id, 47))
			var height_scale := lerpf(0.72, 1.18, _hash01(cell_id, 53))
			if family == "broadleaf":
				width_scale = lerpf(0.74, 1.20, _hash01(cell_id, 59))
				height_scale = lerpf(0.56, 0.90, _hash01(cell_id, 61))
			if lower_mix:
				height_scale *= lerpf(0.82, 0.97, _hash01(cell_id, 67))
			var yaw := lerpf(-PI, PI, _hash01(cell_id, 71))
			var key := "%s_%d" % [family, variant]
			var tree_mesh := _tree_meshes.get(key) as Mesh
			var root_position := Vector3(ground.x, ground.y - tree_mesh.get_aabb().position.y * height_scale - ROOT_BURY_M, ground.z) if tree_mesh != null else Vector3.INF
			if tree_mesh == null or not _surface_ground_range_ok(_tree_surface0_contact_points.get(key, []), Basis(Vector3.UP, yaw).scaled(Vector3(width_scale, height_scale, width_scale)), root_position):
				_patch_range_rejected += 1
				continue
			var source_record := {
				"path": "generated://S03RightForestDistribution",
				"index": serial,
				"source_path": String(anchor.get("source_path", "World/Forest")),
				"source_index": int(anchor.get("source_index", -1)),
				"anchor_index": anchor_index,
				"source_nearest_distance_m": _nearest_source_distance(point),
				"candidate_ground": ground,
				"candidate_screen": projection,
				"candidate_screen_normalized": Vector2(projection.x / FIXED_SCREEN_SIZE.x, projection.y / FIXED_SCREEN_SIZE.y),
				"ground_source": String(sample.get("source", "World/Landscape/SaisiesGeoTerrain surface0 mesh triangle")),
				"ground_triangle_start": int(sample.get("triangle_start", -1)),
				"ground_triangle_surface": int(sample.get("surface", -1)),
				"ground_triangle_barycentric": sample.get("barycentric", Vector3.ZERO),
				"ground_normal": sample.get("normal", Vector3.UP),
				"behind_camera": _camera.is_position_behind(ground),
				"in_frustum": _camera.is_position_in_frustum(ground),
			}
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
			occupied.append(point)
			serial += 1
			if family == "conifer":
				_conifer_count += 1
			else:
				_broadleaf_count += 1
	_new_count = serial

func _publish_ready_state() -> void:
	super._publish_ready_state()
	set_meta("saisies_s03_right_forest_distribution_ready", true)
	set_meta("saisies_s03_right_forest_distribution_enabled", true)
	set_meta("saisies_s03_right_forest_distribution_count", 1)
	set_meta("saisies_s03_right_forest_distribution_lod_active", _lod_active)
	set_meta("saisies_s03_right_forest_distribution_new_count", _new_count)
	set_meta("saisies_s03_right_forest_distribution_anchor_records", _anchor_records)
	set_meta("saisies_s03_right_forest_distribution_records", _replacement_records)
	set_meta("saisies_s03_right_forest_distribution_screen_span", Vector2(DISTRIBUTION_ANCHOR_MIN_X, DISTRIBUTION_ANCHOR_MAX_X))
	set_meta("saisies_s03_right_forest_distribution_policy", "16 irregular screen-balanced anchors, overlapping local groups, conifer dominant, no grid or forest wall")
	set_meta("saisies_s03_right_forest_distribution_legacy_r24_hidden", true)
	_set_legacy_visibility(false)

func _publish_disabled_state() -> void:
	super._publish_disabled_state()
	set_meta("saisies_s03_right_forest_distribution_ready", true)
	set_meta("saisies_s03_right_forest_distribution_enabled", false)
	set_meta("saisies_s03_right_forest_distribution_count", 0)
	set_meta("saisies_s03_right_forest_distribution_lod_active", false)
	set_meta("saisies_s03_right_forest_distribution_new_count", 0)
	set_meta("saisies_s03_right_forest_distribution_anchor_records", [])
	set_meta("saisies_s03_right_forest_distribution_records", [])
	set_meta("saisies_s03_right_forest_distribution_legacy_r24_hidden", false)
	_set_legacy_visibility(true)

func _publish_parent_ready(enabled: bool) -> void:
	super._publish_parent_ready(enabled)
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s03_right_forest_distribution_review_ready", true)
		parent.set_meta("saisies_s03_right_forest_distribution_review_enabled", enabled)
	var current := get_tree().current_scene
	if current != null:
		current.set_meta("saisies_s03_right_forest_distribution_review_ready", true)
		current.set_meta("saisies_s03_right_forest_distribution_review_enabled", enabled)

func _set_legacy_visibility(visible: bool) -> void:
	if _legacy_right_forest_refinement == null:
		_legacy_right_forest_refinement = get_node_or_null(legacy_right_forest_refinement_path)
	if _legacy_right_forest_refinement == null:
		return
	var legacy_candidate := _legacy_right_forest_refinement.find_child("S03RightForestCandidate", true, false) as Node3D
	var legacy_lod_active := bool(_legacy_right_forest_refinement.get_meta("saisies_s03_right_forest_lod_active", false))
	var actual_visible := visible and legacy_lod_active
	if legacy_candidate != null:
		legacy_candidate.visible = actual_visible
	set_meta("saisies_s03_right_forest_distribution_legacy_r24_requested_visible", visible)
	set_meta("saisies_s03_right_forest_distribution_legacy_r24_visible", legacy_candidate != null and actual_visible)

