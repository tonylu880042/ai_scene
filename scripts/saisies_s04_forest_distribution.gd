extends "res://scripts/saisies_s03_right_forest_refinement.gd"

## R33 S04 forest distribution over the frozen R32 guardrail review.
##
## This module adds only three conifer MultiMeshes in the route-relative
## 100..120 second woodland bands.  The inherited R24 helper remains the
## owner of transformed terrain sampling, tree mesh tinting, and surface-0
## root contact correction; no inherited forest or route node is hidden.

const R33_STATUS := "root_selected_for_integrated_review"
const R33_GATE_START_M := 1200.0
const R33_GATE_END_M := 2100.0
const R33_MAX_NEW_TREES := 1000
const R33_MIN_ACCEPT_RATIO := 0.50
const R33_POINT_SPACING_M := 5.5
const R33_ROUTE_CLEARANCE_MIN_M := 12.0
const R33_TREE_HEIGHT_MIN_M := 0.78
const R33_TREE_HEIGHT_MAX_M := 1.28
const R33_TREE_WIDTH_MIN_M := 0.78
const R33_TREE_WIDTH_MAX_M := 1.18
const R33_GROUND_BOUNDS_MARGIN_M := 48.0
const R33_CLUSTER_SIZE := 24
const R33_SOURCE_FRAMES := [
	"export/saisies/review/round31_s04_linked_bends/source_frames/source_105_frame02517.png",
	"export/saisies/review/round31_s04_linked_bends/source_frames/source_110_frame02637.png",
	"export/saisies/review/round31_s04_linked_bends/source_frames/source_115_frame02757.png",
	"export/saisies/review/round31_s04_linked_bends/source_frames/source_120_frame02877.png",
]

@export var guardrail_base_path: NodePath = NodePath("../GuardrailBase")
@export var candidate_path := "res://data/saisies_s04_forest_distribution.json"

var _guardrail_base: Node
var _rig: Node3D
var _candidate_payload: Dictionary = {}
var _zones: Array[Dictionary] = []
var _s04_route_segments: Array[Dictionary] = []
var _s04_zone_records: Array[Dictionary] = []
var _s04_rejection_counts := {"ground": 0, "route": 0, "building": 0, "spacing": 0, "contact": 0, "open_inner": 0}
var _off_requested := false
var _candidate_built := false
var _ready_published := false
var _s04_attempts := 0
var _s04_total_target := 0

func _ready() -> void:
	process_priority = -60
	_off_requested = _has_command_line_flag("--s04-forest-off")
	call_deferred("_try_build_s04")

func _process(_delta: float) -> void:
	if not _built:
		return
	if not _candidate_built:
		if enable_refinement and not _off_requested:
			_built = false
			_ready_published = false
			call_deferred("_try_build_s04")
		return
	_update_s04_lod_gate()

func _try_build_s04() -> void:
	if _built or _ready_published:
		return
	if not _resolve_s04_nodes():
		_retry_s04("S04 forest distribution dependencies are incomplete")
		return
	if not _guardrail_base_ready():
		_retry_s04("S04 forest distribution is waiting for R32 guardrail base readiness")
		return
	if not _load_s04_candidate():
		return
	if _off_requested or not enable_refinement:
		_publish_s04_disabled_state()
		_built = true
		_candidate_built = false
		return
	if not _build_s04_candidate():
		_fail_s04("S04 forest distribution could not build a finite supported patch")
		return
	_built = true
	_candidate_built = true
	_update_s04_lod_gate()
	_publish_s04_ready_state()

func _resolve_s04_nodes() -> bool:
	_guardrail_base = get_node_or_null(guardrail_base_path)
	_left_forest_review = get_node_or_null(left_forest_review_path)
	_flowers_review = get_node_or_null(flowers_review_path)
	_world = get_node_or_null(world_path) as Node3D
	_landscape = get_node_or_null(s01_landscape_path)
	_route = _world.get_node_or_null("Route") if _world != null else null
	_geography = _route.get("geography") as Object if _route != null else null
	_terrain_mesh_instance = _world.find_child("SaisiesGeoTerrain", true, false) as MeshInstance3D if _world != null else null
	_rig = _world.get_node_or_null("CameraRig") as Node3D if _world != null else null
	_camera = _rig.get_node_or_null("Camera3D") as Camera3D if _rig != null else null
	return _guardrail_base != null and _left_forest_review != null and _flowers_review != null and _world != null and _landscape != null and _route != null and _geography != null and _camera != null and _terrain_mesh_instance != null and _terrain_mesh_instance.mesh != null and _route.has_method("pos_at") and _route.has_method("left_at")

func _guardrail_base_ready() -> bool:
	return bool(_guardrail_base.get_meta("saisies_s04_bend_guardrail_review_ready", false))

func _load_s04_candidate() -> bool:
	if not _candidate_payload.is_empty():
		return true
	if not FileAccess.file_exists(candidate_path):
		push_error("S04 forest distribution candidate is missing: %s" % candidate_path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(candidate_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("S04 forest distribution candidate is not a JSON object")
		return false
	_candidate_payload = parsed as Dictionary
	if String(_candidate_payload.get("status", "")) != R33_STATUS or String(_candidate_payload.get("visual_acceptance", "")) != "pending":
		push_error("S04 forest distribution candidate must remain review-pending root selection")
		return false
	if bool(_candidate_payload.get("gps_calibrated", true)) or bool(_candidate_payload.get("formal_route_edit", true)):
		push_error("S04 forest distribution candidate must remain non-GPS and route-only")
		return false
	var raw_zones: Variant = _candidate_payload.get("zones", [])
	if not raw_zones is Array or (raw_zones as Array).is_empty():
		push_error("S04 forest distribution candidate has no zones")
		return false
	_zones.clear()
	_s04_total_target = 0
	for raw_zone in raw_zones as Array:
		if not raw_zone is Dictionary:
			return false
		var zone: Dictionary = raw_zone
		var station0 := float(zone.get("station_from_m", NAN))
		var station1 := float(zone.get("station_to_m", NAN))
		var side := float(zone.get("side_route_left_sign", NAN))
		var offset0 := float(zone.get("offset_min_m", NAN))
		var offset1 := float(zone.get("offset_max_m", NAN))
		var target := int(zone.get("target_count", 0))
		for value in [station0, station1, side, offset0, offset1]:
			if not is_finite(value):
				return false
		if station0 >= station1 or absf(side) < 0.5 or offset0 <= 0.0 or offset0 >= offset1 or target <= 0:
			return false
		if side > 0.0 and String(zone.get("id", "")).contains("inner"):
			return false
		_zones.append(zone)
		_s04_total_target += target
	if _s04_total_target <= 0 or _s04_total_target > R33_MAX_NEW_TREES:
		return false
	return true

func _build_s04_candidate() -> bool:
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
	_s04_zone_records.clear()
	_s04_rejection_counts = {"ground": 0, "route": 0, "building": 0, "spacing": 0, "contact": 0, "open_inner": 0}
	_replacement = Node3D.new()
	_replacement.name = "S04ForestDistributionCandidate"
	_replacement.set_meta("saisies_s04_forest_owner", "route-relative S04 100..120 second woodland patches")
	_replacement.set_meta("saisies_s04_forest_mesh_source", "res://scripts/saisies_trees.gd conifer_variants")
	add_child(_replacement)
	_tree_meshes = _load_s04_tree_meshes()
	if _tree_meshes.is_empty():
		return false
	_collect_building_bounds()
	if not _prepare_s04_route_segments():
		set_meta("saisies_s04_forest_build_diagnostic", "route XZ segment cache empty")
		return false
	_visible_ground_bounds = _derive_s04_ground_bounds()
	if _visible_ground_bounds.size.x <= 0.0 or _visible_ground_bounds.size.y <= 0.0 or not _prepare_visible_ground_cache():
		set_meta("saisies_s04_forest_build_diagnostic", "SaisiesGeoTerrain triangle cache empty in S04 patch bounds")
		return false
	var grouped: Dictionary = {}
	var occupied: Array[Vector2] = []
	var serial := 0
	for zone_index in _zones.size():
		var zone: Dictionary = _zones[zone_index]
		var zone_target := int(zone.get("target_count", 0))
		var accepted := 0
		var attempts := 0
		var max_attempts := zone_target * 18
		var station0 := float(zone["station_from_m"])
		var station1 := float(zone["station_to_m"])
		var side := float(zone["side_route_left_sign"])
		var offset0 := float(zone["offset_min_m"])
		var offset1 := float(zone["offset_max_m"])
		var cluster_count := maxi(1, ceili(float(zone_target) / float(R33_CLUSTER_SIZE)))
		while accepted < zone_target and attempts < max_attempts and serial < R33_MAX_NEW_TREES:
			var local_index := attempts
			var cluster_index := local_index % cluster_count
			var cell_id := 330000 + zone_index * 100000 + local_index
			var cluster_t := (float(cluster_index) + 0.5) / float(cluster_count)
			var cluster_station := lerpf(station0, station1, cluster_t)
			cluster_station += lerpf(-14.0, 14.0, _hash01(cell_id, 3))
			var station := clampf(cluster_station + lerpf(-12.0, 12.0, _hash01(cell_id, 5)), station0, station1)
			var cluster_offset := lerpf(offset0, offset1, _hash01(zone_index * 701 + cluster_index, 7))
			var offset := clampf(cluster_offset + lerpf(-9.0, 9.0, _hash01(cell_id, 11)), offset0, offset1)
			var route_point := _s04_route_point(station, side * offset)
			var point := Vector2(route_point.x, route_point.z)
			if not route_point.is_finite():
				attempts += 1
				continue
			var too_close := false
			for existing in occupied:
				if point.distance_to(existing) < R33_POINT_SPACING_M:
					too_close = true
					break
			if too_close:
				_s04_rejection_counts["spacing"] += 1
				attempts += 1
				continue
			var sample := _sample_ground(point)
			if sample.is_empty():
				_s04_rejection_counts["ground"] += 1
				attempts += 1
				continue
			var ground: Vector3 = sample["position"]
			var variant := int(floori(_hash01(cell_id, 17) * 3.0))
			var key := "conifer_%d" % variant
			var tree_mesh := _tree_meshes.get(key) as Mesh
			if tree_mesh == null:
				_s04_rejection_counts["contact"] += 1
				attempts += 1
				continue
			var width_scale := lerpf(R33_TREE_WIDTH_MIN_M, R33_TREE_WIDTH_MAX_M, _hash01(cell_id, 19))
			var height_scale := lerpf(R33_TREE_HEIGHT_MIN_M, R33_TREE_HEIGHT_MAX_M, _hash01(cell_id, 23))
			var yaw := lerpf(-PI, PI, _hash01(cell_id, 29))
			var nearest := _s04_nearest_route(point)
			if not bool(nearest.get("valid", false)) or float(nearest["distance_m"]) < maxf(R33_ROUTE_CLEARANCE_MIN_M, _tree_crown_radius(tree_mesh, width_scale) + 8.0):
				_s04_rejection_counts["route"] += 1
				attempts += 1
				continue
			if _s04_is_open_inner(nearest):
				_s04_rejection_counts["open_inner"] += 1
				attempts += 1
				continue
			if not _is_clear_of_buildings(ground):
				_s04_rejection_counts["building"] += 1
				attempts += 1
				continue
			var basis := Basis(Vector3.UP, yaw).scaled(Vector3(width_scale, height_scale, width_scale))
			var bounds := tree_mesh.get_aabb()
			var root_position := Vector3(ground.x, ground.y - bounds.position.y * height_scale - ROOT_BURY_M, ground.z)
			if not _surface_ground_range_ok(_tree_surface0_contact_points.get(key, []), basis, root_position):
				_s04_rejection_counts["contact"] += 1
				attempts += 1
				continue
			var projection := _fixed_screen_projection(ground)
			var source_record := {
				"path": "generated://S04ForestDistribution",
				"index": serial,
				"zone_id": String(zone.get("id", "zone_%d" % zone_index)),
				"assigned_station_m": station,
				"assigned_lateral_m": side * offset,
				"actual_nearest_station_m": nearest["station_m"],
				"actual_nearest_lateral_m": nearest["lateral_m"],
				"nearest_route_distance_m": nearest["distance_m"],
				"route_clearance_required_m": maxf(R33_ROUTE_CLEARANCE_MIN_M, _tree_crown_radius(tree_mesh, width_scale) + 8.0),
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
			(grouped[key] as Array).append({"family": "conifer", "variant": variant, "ground": ground, "width_scale": width_scale, "height_scale": height_scale, "yaw": yaw, "source_record": source_record})
			occupied.append(point)
			accepted += 1
			serial += 1
			attempts += 1
		_s04_zone_records.append({"id": String(zone.get("id", "zone_%d" % zone_index)), "station_from_m": station0, "station_to_m": station1, "side_route_left_sign": side, "offset_min_m": offset0, "offset_max_m": offset1, "target_count": zone_target, "accepted_count": accepted, "attempt_count": attempts})
	_new_count = serial
	_conifer_count = serial
	_broadleaf_count = 0
	if _new_count < maxi(300, int(round(float(_s04_total_target) * R33_MIN_ACCEPT_RATIO))) or grouped.is_empty():
		set_meta("saisies_s04_forest_build_diagnostic", "accepted=%d target=%d zones=%d" % [_new_count, _s04_total_target, _zones.size()])
		return false
	if not _build_replacement_multimeshes(grouped):
		return false
	for child in _replacement.get_children():
		if child is MultiMeshInstance3D:
			var instance := child as MultiMeshInstance3D
			instance.name = String(instance.name).replace("S03RightForest", "S04ForestDistribution")
			instance.set_meta("saisies_s04_forest_family", instance.get_meta("saisies_s03_right_forest_family", "conifer"))
	return _all_geometry_finite()

func _load_s04_tree_meshes() -> Dictionary:
	var result: Dictionary = {}
	_tree_surface0_contact_points.clear()
	var conifers: Array = TREE_FACTORY.conifer_variants()
	var tints := [Color(0.43, 0.65, 0.29, 1.0), Color(0.36, 0.58, 0.24, 1.0), Color(0.48, 0.69, 0.33, 1.0)]
	var dense := [Color(0.018, 0.060, 0.014, 1.0), Color(0.014, 0.050, 0.012, 1.0), Color(0.022, 0.070, 0.018, 1.0)]
	for index in mini(3, conifers.size()):
		var key := "conifer_%d" % index
		var mesh: Mesh = _tinted_local_mesh(conifers[index] as Mesh, Color(0.18, 0.16, 0.12, 1.0), tints[index], dense[index])
		if mesh == null:
			continue
		result[key] = mesh
		_tree_surface0_contact_points[key] = _build_surface0_contact_points(mesh)
	return result

func _derive_s04_ground_bounds() -> Rect2:
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for zone in _zones:
		var station0 := float(zone["station_from_m"])
		var station1 := float(zone["station_to_m"])
		var side := float(zone["side_route_left_sign"])
		var offset0 := float(zone["offset_min_m"])
		var offset1 := float(zone["offset_max_m"])
		for step in 9:
			var station := lerpf(station0, station1, float(step) / 8.0)
			for offset in [offset0, offset1, (offset0 + offset1) * 0.5]:
				var point := _s04_route_point(station, side * float(offset))
				if not point.is_finite():
					continue
				min_x = minf(min_x, point.x)
				max_x = maxf(max_x, point.x)
				min_z = minf(min_z, point.z)
				max_z = maxf(max_z, point.z)
	if not is_finite(min_x) or not is_finite(max_x) or not is_finite(min_z) or not is_finite(max_z):
		return Rect2()
	return Rect2(min_x, min_z, max_x - min_x, max_z - min_z).grow(R33_GROUND_BOUNDS_MARGIN_M)

func _s04_route_point(station: float, lateral: float) -> Vector3:
	var center := Vector3(_route.call("pos_at", station))
	var left := Vector3(_route.call("left_at", station)).normalized()
	var point := center + left * lateral
	if _route.has_method("ground_y"):
		point.y = float(_route.call("ground_y", station, lateral))
	return point

func _prepare_s04_route_segments() -> bool:
	_s04_route_segments.clear()
	if _route == null or not _route.has_method("pos_at"):
		return false
	var length_m := float(_route.get("length_m"))
	var spacing_m := clampf(float(_route.get("sample_spacing_m")), 2.0, 20.0)
	if not is_finite(length_m) or length_m <= 0.0:
		return false
	var count := maxi(int(ceil(length_m / spacing_m)), 1)
	for index in count:
		var s0 := minf(float(index) * spacing_m, length_m)
		var s1 := minf(float(index + 1) * spacing_m, length_m)
		if s1 <= s0 + 0.0001:
			continue
		var a3 := Vector3(_route.call("pos_at", s0))
		var b3 := Vector3(_route.call("pos_at", s1))
		var a := Vector2(a3.x, a3.z)
		var b := Vector2(b3.x, b3.z)
		if not a3.is_finite() or not b3.is_finite() or a.distance_squared_to(b) <= 0.000001:
			continue
		_s04_route_segments.append({"a": a, "b": b, "station0_m": s0, "station1_m": s1})
	return not _s04_route_segments.is_empty()

func _s04_nearest_route(point: Vector2) -> Dictionary:
	if _route == null or _s04_route_segments.is_empty():
		return {"valid": false}
	var best_distance_squared := INF
	var best_station := NAN
	var best_point := Vector2.INF
	for segment in _s04_route_segments:
		var a: Vector2 = segment["a"]
		var b: Vector2 = segment["b"]
		var ab := b - a
		var denominator := ab.length_squared()
		if denominator <= 0.000001:
			continue
		var t := clampf((point - a).dot(ab) / denominator, 0.0, 1.0)
		var closest := a + ab * t
		var distance_squared := point.distance_squared_to(closest)
		if distance_squared >= best_distance_squared:
			continue
		best_distance_squared = distance_squared
		best_point = closest
		best_station = lerpf(float(segment["station0_m"]), float(segment["station1_m"]), t)
	if not is_finite(best_station) or not best_point.is_finite():
		return {"valid": false}
	var route_point := Vector3(_route.call("pos_at", best_station))
	var left := Vector3(_route.call("left_at", best_station)).normalized()
	var delta := Vector2(point.x - route_point.x, point.y - route_point.z)
	var left_xz := Vector2(left.x, left.z).normalized()
	return {"valid": route_point.is_finite() and left_xz.is_finite(), "station_m": best_station, "lateral_m": delta.dot(left_xz), "distance_m": sqrt(best_distance_squared), "nearest_point_xz": best_point}

func _tree_crown_radius(mesh: Mesh, width_scale: float) -> float:
	if mesh == null:
		return 0.0
	var bounds := mesh.get_aabb()
	var x_radius := maxf(absf(bounds.position.x), absf(bounds.end.x))
	var z_radius := maxf(absf(bounds.position.z), absf(bounds.end.z))
	return maxf(x_radius, z_radius) * width_scale

func _s04_is_open_inner(nearest: Dictionary) -> bool:
	if not bool(nearest.get("valid", false)):
		return false
	var station := float(nearest.get("station_m", NAN))
	var lateral := float(nearest.get("lateral_m", NAN))
	return station >= 1575.0 and station <= 1685.0 and lateral < 0.0 and absf(lateral) < 80.0

func _update_s04_lod_gate() -> void:
	if _replacement == null or _camera == null:
		return
	var station := float(_rig.get("distance_m")) if _rig != null else NAN
	var active := enable_refinement and not _off_requested and is_finite(station) and station >= R33_GATE_START_M and station <= R33_GATE_END_M
	_lod_active = active
	_replacement.visible = active
	set_meta("saisies_s04_forest_lod_active", active)
	set_meta("saisies_s04_forest_camera_station_m", station)
	set_meta("saisies_s04_forest_lod_gate_station_m", Vector2(R33_GATE_START_M, R33_GATE_END_M))
	set_meta("saisies_s04_forest_enabled", enable_refinement and not _off_requested)

func _publish_s04_ready_state() -> void:
	_ready_published = true
	set_meta("saisies_s04_forest_ready", true)
	set_meta("saisies_s04_forest_enabled", true)
	set_meta("saisies_s04_forest_status", R33_STATUS)
	set_meta("saisies_s04_forest_visual_acceptance", "pending")
	set_meta("saisies_s04_forest_count", 1)
	set_meta("saisies_s04_forest_new_count", _new_count)
	set_meta("saisies_s04_forest_conifer_count", _conifer_count)
	set_meta("saisies_s04_forest_broadleaf_count", 0)
	set_meta("saisies_s04_forest_records", _replacement_records)
	set_meta("saisies_s04_forest_patches", _s04_zone_records)
	set_meta("saisies_s04_forest_root_contacts", _replacement_records)
	set_meta("saisies_s04_forest_root_contact_count", _replacement_records.size())
	set_meta("saisies_s04_forest_zone_ranges", _zones)
	set_meta("saisies_s04_forest_patch_reject_counts", _s04_rejection_counts)
	set_meta("saisies_s04_forest_lod_active", _lod_active)
	set_meta("saisies_s04_forest_lod_gate_station_m", Vector2(R33_GATE_START_M, R33_GATE_END_M))
	set_meta("saisies_s04_forest_ground_mesh_path", _visible_ground_mesh_path)
	set_meta("saisies_s04_forest_ground_mesh_scan_triangle_count", _visible_ground_scan_triangle_count)
	set_meta("saisies_s04_forest_ground_mesh_cached_triangle_count", _visible_ground_triangle_count)
	set_meta("saisies_s04_forest_ground_cache_bounds_xz", _visible_ground_bounds)
	set_meta("saisies_s04_forest_ground_source", "World/Landscape/SaisiesGeoTerrain transformed triangles; S01 visible overlay takes max")
	set_meta("saisies_s04_forest_ground_dem_fallback_used", false)
	set_meta("saisies_s04_forest_no_old_nodes_hidden", true)
	set_meta("saisies_s04_forest_geometry_contract", "three conifer MultiMeshes only; no route, terrain, camera, light, building, or inherited forest edits")
	_publish_s04_parent_ready(true)

func _publish_s04_disabled_state() -> void:
	_ready_published = true
	set_meta("saisies_s04_forest_ready", true)
	set_meta("saisies_s04_forest_enabled", false)
	set_meta("saisies_s04_forest_status", "disabled_baseline")
	set_meta("saisies_s04_forest_visual_acceptance", "pending")
	set_meta("saisies_s04_forest_count", 0)
	set_meta("saisies_s04_forest_new_count", 0)
	set_meta("saisies_s04_forest_conifer_count", 0)
	set_meta("saisies_s04_forest_broadleaf_count", 0)
	set_meta("saisies_s04_forest_records", [])
	set_meta("saisies_s04_forest_patches", [])
	set_meta("saisies_s04_forest_root_contacts", [])
	set_meta("saisies_s04_forest_root_contact_count", 0)
	set_meta("saisies_s04_forest_lod_active", false)
	_publish_s04_parent_ready(false)

func _publish_s04_parent_ready(enabled: bool) -> void:
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s04_forest_review_ready", true)
		parent.set_meta("saisies_s04_forest_review_enabled", enabled)
	var current := get_tree().current_scene
	if current != null:
		current.set_meta("saisies_s04_forest_review_ready", true)
		current.set_meta("saisies_s04_forest_review_enabled", enabled)

func _retry_s04(message: String) -> void:
	_s04_attempts += 1
	if _s04_attempts < 240:
		call_deferred("_retry_s04_next_frame")
		return
	set_meta("saisies_s04_forest_ready", false)
	set_meta("saisies_s04_forest_error", message)
	push_error(message)

func _retry_s04_next_frame() -> void:
	await get_tree().process_frame
	_try_build_s04()

func _fail_s04(message: String) -> void:
	set_meta("saisies_s04_forest_ready", false)
	set_meta("saisies_s04_forest_error", message)
	push_error(message)

