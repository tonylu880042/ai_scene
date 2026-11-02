class_name SaisiesReleaseForest
extends Node3D

## Whole-route forest continuity overlay for the release candidate.
##
## The frozen R35 world already contains its authored forest.  This module
## adds only source-backed S05-S18 woodland gaps, keeping the meadow, farm and
## junction openings explicit in data.  Placement is route-relative, but all
## tree roots are fitted against the visible SaisiesGeoTerrain mesh.  No DEM
## height or unbounded route-wide deletion is used here.

const TREE_FACTORY := preload("res://scripts/saisies_trees.gd")

@export var world_path: NodePath
@export var landscape_path: NodePath
@export var route_path: NodePath
@export_file("*.json") var candidate_path := "res://data/saisies_release_forest.json"
@export var enable_refinement := true
@export var tree_chunk_size_m := 320.0
@export var terrain_bin_size_m := 32.0
@export var route_bin_size_m := 64.0

const RELEASE_STATUS := "root_selected_for_integrated_review"
const RELEASE_VISUAL_STATUS := "pending"
const FIRST_FOREST_VIDEO_S := 135.0
const LAST_FOREST_VIDEO_S := 920.067
const FIRST_FOREST_STATION_M := 1950.0
const MAX_TREE_INSTANCES := 6400
const MAX_ZONE_TARGET := 700
const MIN_ROUTE_CLEARANCE_M := 10.0
const MIN_TREE_SPACING_M := 5.5
const EXISTING_TREE_SPACING_M := 4.0
const CLUSTER_TARGET_SIZE := 24.0
const CLUSTER_STATION_JITTER_FRACTION := 0.42
const CLUSTER_LATERAL_JITTER_FRACTION := 0.35
const MIN_ACCEPTED_TARGET_RATIO := 0.70
const ROOT_BURY_MARGIN_M := 0.055
const ROOT_CONTACT_BAND_M := 0.04
const MAX_ROOT_GROUND_RANGE_M := 4.5
const MAX_ROOT_BURIAL_M := 1.65
const GROUND_CACHE_MARGIN_M := 90.0
const GROUND_SAMPLE_EPSILON := 0.0005
const MAX_ROOT_PROOF_SAMPLES := 128
const MAX_PATCH_RECORDS := 256
const SOURCE_SCENE_IDS := ["S04", "S05", "S06", "S07", "S08", "S09", "S10", "S11", "S12", "S13", "S14", "S15", "S16", "S17", "S18"]

var _world: Node3D
var _landscape: Node
var _terrain_sampler: Node
var _route: Node
var _terrain_mesh_instance: MeshInstance3D
var _camera: Camera3D
var _rig: Node3D
var _candidate: Dictionary = {}
var _zones: Array[Dictionary] = []
var _station_overrides: Array[Dictionary] = []
var _max_candidate_offset_m := 0.0
var _target_count := 0

var _replacement: Node3D
var _tree_meshes: Dictionary = {}
var _tree_contacts: Dictionary = {}
var _route_segments: Array[Dictionary] = []
var _route_bins: Dictionary = {}
var _ground_triangles: Array[Dictionary] = []
var _ground_bins: Dictionary = {}
var _ground_bounds := Rect2()
var _existing_tree_bins: Dictionary = {}
var _building_bounds: Array[AABB] = []
var _records: Array[Dictionary] = []
var _root_proof_samples: Array[Dictionary] = []
var _patch_records: Array[Dictionary] = []
var _replacement_groups := 0
var _tree_count := 0
var _broadleaf_count := 0
var _conifer_count := 0
var _terrain_scan_triangle_count := 0
var _terrain_cached_triangle_count := 0
var _terrain_sample_count := 0
var _terrain_direct_sampler_used := false
var _root_contact_count := 0
var _root_contact_miss_count := 0
var _root_max_positive_clearance_m := 0.0
var _root_max_burial_m := 0.0
var _existing_tree_scan_nodes := 0
var _existing_tree_points_scanned := 0
var _existing_tree_points_added := 0
var _candidate_reject_counts := {
	"ground": 0,
	"route": 0,
	"spacing": 0,
	"building": 0,
	"root": 0,
	"open_window": 0,
}
var _build_attempts := 0
var _built := false
var _candidate_built := false
var _off_requested := false

func _ready() -> void:
	process_priority = -190
	_off_requested = _has_flag("--saisies-release-forest-off")
	call_deferred("_try_build")

func _process(_delta: float) -> void:
	if not _built:
		return
	if not _candidate_built:
		if enable_refinement and not _off_requested:
			_built = false
			call_deferred("_try_build")
		return
	if _replacement != null:
		_replacement.visible = enable_refinement and not _off_requested
	set_meta("saisies_release_forest_enabled", enable_refinement and not _off_requested)

func _try_build() -> void:
	if _built:
		return
	if not _resolve_nodes():
		_retry("release forest dependencies are incomplete")
		return
	if not _route_ready():
		_retry("release forest is waiting for the shared route")
		return
	if not _load_candidate():
		_fail("release forest candidate data is invalid")
		return
	if _off_requested or not enable_refinement:
		_publish_disabled_state()
		_built = true
		_candidate_built = false
		return
	if not _terrain_ready():
		_retry("release forest is waiting for visible SaisiesGeoTerrain")
		return
	if not _build_candidate():
		_fail("release forest could not build a finite terrain-supported overlay")
		return
	_built = true
	_candidate_built = true
	_publish_ready_state()

func _resolve_nodes() -> bool:
	_world = get_node_or_null(world_path) as Node3D if not world_path.is_empty() else null
	if _world == null and get_parent() != null:
		_world = get_parent().get_node_or_null("World") as Node3D
	if _world == null:
		return false
	_route = get_node_or_null(route_path) if not route_path.is_empty() else null
	if _route == null:
		_route = _world.get_node_or_null("Route")
	_landscape = get_node_or_null(landscape_path) if not landscape_path.is_empty() else null
	if _landscape == null:
		_landscape = _world.get_node_or_null("Landscape")
	_terrain_mesh_instance = _world.find_child("SaisiesGeoTerrain", true, false) as MeshInstance3D
	if _terrain_mesh_instance == null and _landscape != null:
		_terrain_mesh_instance = _landscape.find_child("SaisiesGeoTerrain", true, false) as MeshInstance3D
	_terrain_sampler = _landscape if _landscape != null and _landscape.has_method("sample_mesh_triangle") else null
	if _terrain_sampler == null and _terrain_mesh_instance != null and _terrain_mesh_instance.get_parent() != null and _terrain_mesh_instance.get_parent().has_method("sample_mesh_triangle"):
		_terrain_sampler = _terrain_mesh_instance.get_parent()
	_rig = _world.get_node_or_null("CameraRig") as Node3D
	_camera = _rig.get_node_or_null("Camera3D") as Camera3D if _rig != null else null
	return _route != null and _terrain_mesh_instance != null

func _route_ready() -> bool:
	return _route != null and _route.has_method("route_ready") and bool(_route.call("route_ready")) and _route.has_method("pos_at") and _route.has_method("left_at") and _route.has_method("distance_for_video_seconds")

func _terrain_ready() -> bool:
	return _terrain_mesh_instance != null and _terrain_mesh_instance.mesh != null and _terrain_mesh_instance.mesh.get_surface_count() > 0

func _load_candidate() -> bool:
	if not _candidate.is_empty():
		return true
	if not FileAccess.file_exists(candidate_path):
		push_error("SaisiesReleaseForest candidate is missing: %s" % candidate_path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(candidate_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("SaisiesReleaseForest candidate is not a JSON object")
		return false
	_candidate = parsed as Dictionary
	if String(_candidate.get("status", "")) != RELEASE_STATUS or String(_candidate.get("visual_acceptance", "")) != RELEASE_VISUAL_STATUS:
		push_error("SaisiesReleaseForest candidate must remain review-pending")
		return false
	if bool(_candidate.get("gps_calibrated", true)) or bool(_candidate.get("formal_route_edit", true)):
		push_error("SaisiesReleaseForest candidate must remain visual-estimate-only")
		return false
	if String(_candidate.get("distribution_policy", "")) != "deterministic_clustered_stratified_jitter":
		push_error("SaisiesReleaseForest candidate must declare clustered deterministic distribution")
		return false
	if int(_candidate.get("cluster_target_size", 0)) != int(CLUSTER_TARGET_SIZE):
		push_error("SaisiesReleaseForest candidate cluster target does not match runtime policy")
		return false
	_station_overrides.clear()
	var raw_overrides: Variant = _candidate.get("source_station_overrides", [])
	if raw_overrides is Array:
		for raw_override in raw_overrides as Array:
			if raw_override is Dictionary:
				var override := (raw_override as Dictionary).duplicate(true)
				var video_s := float(override.get("video_seconds", NAN))
				var station := float(override.get("station_m", NAN))
				if is_finite(video_s) and is_finite(station):
					_station_overrides.append(override)
	_station_overrides.sort_custom(Callable(self, "_sort_station_override"))
	if _station_overrides.size() < 2:
		push_error("SaisiesReleaseForest candidate needs at least two station overrides")
		return false
	var previous_video := -INF
	var previous_station := -INF
	for override in _station_overrides:
		var override_video := float(override.get("video_seconds", NAN))
		var override_station := float(override.get("station_m", NAN))
		if override_video <= previous_video or override_station <= previous_station:
			push_error("SaisiesReleaseForest station overrides must be strictly increasing")
			return false
		previous_video = override_video
		previous_station = override_station
	var raw_zones: Variant = _candidate.get("zones", [])
	if not raw_zones is Array or (raw_zones as Array).is_empty():
		push_error("SaisiesReleaseForest candidate contains no zones")
		return false
	_zones.clear()
	_max_candidate_offset_m = 0.0
	for raw_zone in raw_zones as Array:
		if not raw_zone is Dictionary:
			return false
		var zone := (raw_zone as Dictionary).duplicate(true)
		var scene_id := String(zone.get("scene_id", ""))
		var from_s := float(zone.get("video_start_s", NAN))
		var to_s := float(zone.get("video_end_s", NAN))
		var side := float(zone.get("side_route_left_sign", NAN))
		var offset_min := float(zone.get("offset_min_m", NAN))
		var offset_max := float(zone.get("offset_max_m", NAN))
		var density := float(zone.get("density_per_100m", NAN))
		var broadleaf_probability := float(zone.get("broadleaf_probability", NAN))
		var width_min := float(zone.get("width_min", NAN))
		var width_max := float(zone.get("width_max", NAN))
		var height_min := float(zone.get("height_min_m", NAN))
		var height_max := float(zone.get("height_max_m", NAN))
		for value in [from_s, to_s, side, offset_min, offset_max, density, broadleaf_probability, width_min, width_max, height_min, height_max]:
			if not is_finite(value):
				return false
		if not SOURCE_SCENE_IDS.has(scene_id) or scene_id in ["S01", "S02", "S03"]:
			return false
		if from_s >= to_s or absf(side) < 0.5 or offset_min <= 0.0 or offset_min >= offset_max or density <= 0.0 or density > 80.0:
			return false
		if width_min <= 0.0 or width_min > width_max or height_min <= 0.0 or height_min > height_max:
			return false
		if broadleaf_probability < 0.0 or broadleaf_probability > 1.0:
			return false
		var openings: Variant = zone.get("open_windows_s", [])
		if not openings is Array:
			return false
		for raw_window in openings as Array:
			if not raw_window is Array or (raw_window as Array).size() < 2:
				return false
			var window_start := float((raw_window as Array)[0])
			var window_end := float((raw_window as Array)[1])
			if not is_finite(window_start) or not is_finite(window_end) or window_start >= window_end:
				return false
			if window_end < from_s or window_start > to_s:
				continue
		_max_candidate_offset_m = maxf(_max_candidate_offset_m, offset_max)
		_zones.append(zone)
	return _zones.size() > 0 and _zones.size() <= 64

func _build_candidate() -> bool:
	_clear_build_state()
	_tree_meshes = _load_tree_meshes()
	if _tree_meshes.is_empty():
		return false
	_prepare_route_cache()
	if _route_segments.is_empty():
		return false
	if not _derive_ground_bounds() or not _prepare_ground_cache():
		return false
	_collect_existing_tree_points()
	_collect_building_bounds()
	_replacement = Node3D.new()
	_replacement.name = "SaisiesReleaseForestOverlay"
	_replacement.set_meta("saisies_release_forest_owner", "S05-S18 source-backed mixed woodland overlay")
	_replacement.set_meta("saisies_release_forest_mesh_source", "res://scripts/saisies_trees.gd")
	add_child(_replacement)
	var grouped: Dictionary = {}
	for zone_index in _zones.size():
		_build_zone(_zones[zone_index], zone_index, grouped)
	if _tree_count <= 0 or grouped.is_empty():
		return false
	var minimum_target_count := maxi(1, int(ceil(float(_target_count) * MIN_ACCEPTED_TARGET_RATIO)))
	set_meta("saisies_release_forest_target_count", _target_count)
	set_meta("saisies_release_forest_minimum_target_count", minimum_target_count)
	set_meta("saisies_release_forest_acceptance_ratio", float(_tree_count) / float(maxi(_target_count, 1)))
	if not _build_multimeshes(grouped):
		return false
	return _all_finite()

func _clear_build_state() -> void:
	if _replacement != null and is_instance_valid(_replacement):
		_replacement.queue_free()
	_replacement = null
	_tree_count = 0
	_target_count = 0
	_broadleaf_count = 0
	_conifer_count = 0
	_replacement_groups = 0
	_terrain_scan_triangle_count = 0
	_terrain_cached_triangle_count = 0
	_terrain_sample_count = 0
	_root_contact_count = 0
	_root_contact_miss_count = 0
	_root_max_positive_clearance_m = 0.0
	_root_max_burial_m = 0.0
	_terrain_direct_sampler_used = false
	_existing_tree_scan_nodes = 0
	_existing_tree_points_scanned = 0
	_existing_tree_points_added = 0
	_records.clear()
	_root_proof_samples.clear()
	_patch_records.clear()
	_candidate_reject_counts = {"ground": 0, "route": 0, "spacing": 0, "building": 0, "root": 0, "open_window": 0}
	_ground_triangles.clear()
	_ground_bins.clear()
	_route_segments.clear()
	_route_bins.clear()
	_existing_tree_bins.clear()
	_building_bounds.clear()

func _load_tree_meshes() -> Dictionary:
	var result: Dictionary = {}
	_tree_contacts.clear()
	var broadleaf: Array = TREE_FACTORY.broadleaf_variants()
	var conifers: Array = TREE_FACTORY.conifer_variants()
	for index in mini(3, broadleaf.size()):
		var mesh := broadleaf[index] as Mesh
		if mesh != null:
			var key := "broadleaf_%d" % index
			result[key] = mesh
			_tree_contacts[key] = _build_root_contacts(mesh)
	for index in mini(3, conifers.size()):
		var mesh := conifers[index] as Mesh
		if mesh != null:
			var key := "conifer_%d" % index
			result[key] = mesh
			_tree_contacts[key] = _build_root_contacts(mesh)
	return result

func _build_root_contacts(mesh: Mesh) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if mesh == null or mesh.get_surface_count() <= 0:
		return points
	var arrays := mesh.surface_get_arrays(0)
	if arrays.size() <= Mesh.ARRAY_VERTEX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
		return points
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices := PackedInt32Array()
	if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
		indices = arrays[Mesh.ARRAY_INDEX]
	if indices.is_empty():
		indices.resize(vertices.size())
		for i in vertices.size():
			indices[i] = i
	var min_y := INF
	for raw_index in indices:
		var index := int(raw_index)
		if index >= 0 and index < vertices.size() and vertices[index].is_finite():
			min_y = minf(min_y, vertices[index].y)
	if not is_finite(min_y):
		return points
	var lowest: Array[Vector3] = []
	for raw_index in indices:
		var index := int(raw_index)
		if index >= 0 and index < vertices.size() and vertices[index].is_finite() and vertices[index].y <= min_y + ROOT_CONTACT_BAND_M:
			lowest.append(vertices[index])
	if lowest.is_empty():
		return points
	var min_x := 0
	var max_x := 0
	var min_z := 0
	var max_z := 0
	for i in lowest.size():
		if lowest[i].x < lowest[min_x].x: min_x = i
		if lowest[i].x > lowest[max_x].x: max_x = i
		if lowest[i].z < lowest[min_z].z: min_z = i
		if lowest[i].z > lowest[max_z].z: max_z = i
	for index in [min_x, max_x, min_z, max_z]:
		var point: Vector3 = lowest[int(index)]
		var duplicate := false
		for existing in points:
			if existing.distance_squared_to(point) < 0.000001:
				duplicate = true
				break
		if not duplicate:
			points.append(point)
	return points

func _prepare_route_cache() -> void:
	var length_m := float(_route.get("length_m"))
	var spacing := clampf(float(_route.get("sample_spacing_m")), 2.0, 20.0)
	var count := maxi(int(ceil(length_m / spacing)), 1)
	for index in count:
		var s0 := minf(float(index) * spacing, length_m)
		var s1 := minf(float(index + 1) * spacing, length_m)
		if s1 <= s0 + 0.0001:
			continue
		var a3 := Vector3(_route.call("pos_at", s0))
		var b3 := Vector3(_route.call("pos_at", s1))
		if not a3.is_finite() or not b3.is_finite():
			continue
		var a := Vector2(a3.x, a3.z)
		var b := Vector2(b3.x, b3.z)
		if a.distance_squared_to(b) <= 0.000001:
			continue
		var segment_index := _route_segments.size()
		_route_segments.append({"a": a, "b": b, "s0": s0, "s1": s1})
		var min_x := floori(minf(a.x, b.x) / route_bin_size_m)
		var max_x := floori(maxf(a.x, b.x) / route_bin_size_m)
		var min_z := floori(minf(a.y, b.y) / route_bin_size_m)
		var max_z := floori(maxf(a.y, b.y) / route_bin_size_m)
		for bin_x in range(min_x, max_x + 1):
			for bin_z in range(min_z, max_z + 1):
				var key := _bin_key(bin_x, bin_z)
				if not _route_bins.has(key):
					_route_bins[key] = []
				(_route_bins[key] as Array).append(segment_index)

func _derive_ground_bounds() -> bool:
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for zone in _zones:
		var s0 := _station_for_video_seconds(float(zone["video_start_s"]))
		var s1 := _station_for_video_seconds(float(zone["video_end_s"]))
		for step in 7:
			var station := lerpf(s0, s1, float(step) / 6.0)
			for offset in [float(zone["offset_min_m"]), float(zone["offset_max_m"]), (float(zone["offset_min_m"]) + float(zone["offset_max_m"])) * 0.5]:
				var p := _route_point(station, float(zone["side_route_left_sign"]) * offset)
				if not p.is_finite():
					continue
				min_x = minf(min_x, p.x)
				max_x = maxf(max_x, p.x)
				min_z = minf(min_z, p.z)
				max_z = maxf(max_z, p.z)
	if not is_finite(min_x) or not is_finite(max_x) or not is_finite(min_z) or not is_finite(max_z):
		return false
	_ground_bounds = Rect2(min_x, min_z, max_x - min_x, max_z - min_z).grow(GROUND_CACHE_MARGIN_M)
	return _ground_bounds.size.x > 0.0 and _ground_bounds.size.y > 0.0

func _prepare_ground_cache() -> bool:
	_ground_triangles.clear()
	_ground_bins.clear()
	if _terrain_sampler != null and _terrain_sampler.has_method("sample_mesh_triangle"):
		_terrain_direct_sampler_used = true
		return true
	var mesh := _terrain_mesh_instance.mesh
	var mesh_transform := _terrain_mesh_instance.global_transform
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var raw_indices: Variant = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX else null
		if raw_indices is PackedInt32Array and (raw_indices as PackedInt32Array).size() >= 3:
			var indices: PackedInt32Array = raw_indices
			for start in range(0, indices.size() - 2, 3):
				var ia := int(indices[start]); var ib := int(indices[start + 1]); var ic := int(indices[start + 2])
				if ia < 0 or ib < 0 or ic < 0 or ia >= vertices.size() or ib >= vertices.size() or ic >= vertices.size():
					continue
				var a := mesh_transform * vertices[ia]; var b := mesh_transform * vertices[ib]; var c := mesh_transform * vertices[ic]
				if _cache_ground_triangle(a, b, c, start, surface_index):
					_terrain_scan_triangle_count += 1
		else:
			for start in range(0, vertices.size() - 2, 3):
				var a := mesh_transform * vertices[start]; var b := mesh_transform * vertices[start + 1]; var c := mesh_transform * vertices[start + 2]
				if _cache_ground_triangle(a, b, c, start, surface_index):
					_terrain_scan_triangle_count += 1
	_terrain_cached_triangle_count = _ground_triangles.size()
	return _terrain_cached_triangle_count > 0

func _cache_ground_triangle(a: Vector3, b: Vector3, c: Vector3, start: int, surface_index: int) -> bool:
	if not a.is_finite() or not b.is_finite() or not c.is_finite():
		return false
	if not _triangle_intersects_bounds(a, b, c, _ground_bounds):
		return false
	var triangle_index := _ground_triangles.size()
	_ground_triangles.append({"a": a, "b": b, "c": c, "start": start, "surface": surface_index})
	var min_x := floori(minf(a.x, minf(b.x, c.x)) / terrain_bin_size_m)
	var max_x := floori(maxf(a.x, maxf(b.x, c.x)) / terrain_bin_size_m)
	var min_z := floori(minf(a.z, minf(b.z, c.z)) / terrain_bin_size_m)
	var max_z := floori(maxf(a.z, maxf(b.z, c.z)) / terrain_bin_size_m)
	for bin_x in range(min_x, max_x + 1):
		for bin_z in range(min_z, max_z + 1):
			var key := _bin_key(bin_x, bin_z)
			if not _ground_bins.has(key):
				_ground_bins[key] = []
			(_ground_bins[key] as Array).append(triangle_index)
	return true

func _build_zone(zone: Dictionary, zone_index: int, grouped: Dictionary) -> void:
	var s0 := maxf(FIRST_FOREST_STATION_M, _station_for_video_seconds(float(zone["video_start_s"])))
	var s1 := minf(float(_route.get("length_m")), _station_for_video_seconds(float(zone["video_end_s"])))
	if s1 <= s0 + 1.0:
		return
	var target := clampi(int(round((s1 - s0) * float(zone["density_per_100m"]) / 100.0)), 1, MAX_ZONE_TARGET)
	_target_count += target
	var accepted := 0
	var attempts := 0
	var baseline_attempt_limit := maxi(target * 5, 12)
	var attempt_limit := maxi(target * 7, 16)
	var side := float(zone["side_route_left_sign"])
	var offset_min := float(zone["offset_min_m"])
	var offset_max := float(zone["offset_max_m"])
	var cluster_count := maxi(1, int(ceil(float(target) / CLUSTER_TARGET_SIZE)))
	var active_station_windows := _active_station_windows(zone, s0, s1)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9137 + zone_index * 1000003
	var cluster_station_jitters := PackedFloat32Array()
	var cluster_offsets := PackedFloat32Array()
	for cluster_index in cluster_count:
		cluster_station_jitters.append(rng.randf())
		cluster_offsets.append(rng.randf())
	while attempts < attempt_limit and accepted < target and _tree_count < MAX_TREE_INSTANCES:
		var station_jitter_value := rng.randf()
		var lateral_jitter_value := rng.randf()
		var broadleaf_value := rng.randf()
		var variant_value := rng.randf()
		var width_value := rng.randf()
		var height_value := rng.randf()
		var yaw_value := rng.randf()
		var cluster_index := attempts % cluster_count
		var cluster_t := (float(cluster_index) + 0.5) / float(cluster_count)
		var cluster_span := (s1 - s0) / float(cluster_count)
		var cluster_station := lerpf(s0, s1, cluster_t)
		var cluster_jitter := cluster_span * CLUSTER_STATION_JITTER_FRACTION
		cluster_station += lerpf(-cluster_jitter, cluster_jitter, float(cluster_station_jitters[cluster_index]))
		var local_station_jitter := minf(18.0, cluster_span * 0.35)
		var retry_pressure := clampf(float(attempts - baseline_attempt_limit) / float(maxi(target * 2, 1)), 0.0, 1.0)
		var adaptive_station_jitter := lerpf(local_station_jitter, maxf(local_station_jitter, 30.0), retry_pressure)
		var station := cluster_station + lerpf(-adaptive_station_jitter, adaptive_station_jitter, station_jitter_value)
		station = clampf(station, s0, s1)
		if not _station_in_active_windows(station, active_station_windows):
			_candidate_reject_counts["open_window"] += 1
			attempts += 1
			continue
		var cluster_offset := lerpf(offset_min, offset_max, float(cluster_offsets[cluster_index]))
		var lateral_jitter := minf((offset_max - offset_min) * CLUSTER_LATERAL_JITTER_FRACTION, 18.0)
		var adaptive_lateral_jitter := lerpf(lateral_jitter, maxf(lateral_jitter, 30.0), retry_pressure)
		var lateral := side * clampf(cluster_offset + lerpf(-adaptive_lateral_jitter, adaptive_lateral_jitter, lateral_jitter_value), offset_min, offset_max)
		var route_point := _route_point(station, lateral)
		var xz := Vector2(route_point.x, route_point.z)
		var nearest := _nearest_route(xz)
		if not bool(nearest.get("valid", false)) or float(nearest.get("distance_m", INF)) < maxf(MIN_ROUTE_CLEARANCE_M, float(_route.call("road_width_at", station)) * 0.5 + 3.0):
			_candidate_reject_counts["route"] += 1
			attempts += 1
			continue
		var sample := _sample_ground(xz)
		if sample.is_empty():
			_candidate_reject_counts["ground"] += 1
			attempts += 1
			continue
		var ground: Vector3 = sample["position"]
		if not _is_clear_of_buildings(ground) or _is_too_close_to_existing(xz):
			_candidate_reject_counts["building"] += 1 if not _is_clear_of_buildings(ground) else 0
			_candidate_reject_counts["spacing"] += 1 if _is_too_close_to_existing(xz) else 0
			attempts += 1
			continue
		var broadleaf_probability := float(zone["broadleaf_probability"])
		var is_broadleaf := broadleaf_value < broadleaf_probability
		var family := "broadleaf" if is_broadleaf else "conifer"
		var family_count := 3
		var variant := clampi(int(floor(variant_value * float(family_count))), 0, family_count - 1)
		var key := "%s_%d" % [family, variant]
		var mesh := _tree_meshes.get(key) as Mesh
		var contacts: Array[Vector3] = _tree_contacts.get(key, [])
		if mesh == null or contacts.size() < 4:
			_candidate_reject_counts["root"] += 1
			attempts += 1
			continue
		var width := lerpf(float(zone["width_min"]), float(zone["width_max"]), width_value)
		var height := lerpf(float(zone["height_min_m"]), float(zone["height_max_m"]), height_value)
		var yaw := lerpf(-PI, PI, yaw_value)
		var basis := Basis(Vector3.UP, yaw).scaled(Vector3(width, height, width))
		var bounds := mesh.get_aabb()
		var root := Vector3(ground.x, ground.y - bounds.position.y * height, ground.z)
		var root_fit := _fit_root_contacts(contacts, basis, root, ground)
		if root_fit.is_empty() or not bool(root_fit.get("valid", false)):
			_candidate_reject_counts["root"] += 1
			attempts += 1
			continue
		root = root_fit["root_position"]
		var item := {
			"family": family,
			"variant": variant,
			"key": key,
			"station_m": station,
			"lateral_m": lateral,
			"ground": ground,
			"root_world": root,
			"width_scale": width,
			"height_scale": height,
			"yaw": yaw,
			"basis": basis,
			"source_zone": String(zone.get("id", "zone_%d" % zone_index)),
			"source_scene_id": String(zone.get("scene_id", "")),
			"ground_source": String(sample.get("source", "World/Landscape/SaisiesGeoTerrain indexed triangle")),
			"ground_triangle_start": int(sample.get("triangle_start", -1)),
			"ground_triangle_surface": int(sample.get("surface", -1)),
			"ground_triangle_barycentric": sample.get("barycentric", Vector3.ZERO),
			"ground_normal": sample.get("normal", Vector3.UP),
			"root_fit": root_fit,
		}
		if not grouped.has(key):
			grouped[key] = []
		(grouped[key] as Array).append(item)
		_add_existing_tree_point(xz)
		_tree_count += 1
		_broadleaf_count += 1 if is_broadleaf else 0
		_conifer_count += 0 if is_broadleaf else 1
		accepted += 1
		attempts += 1
	_patch_records.append({
			"id": String(zone.get("id", "zone_%d" % zone_index)),
			"scene_id": String(zone.get("scene_id", "")),
			"video_start_s": float(zone["video_start_s"]),
			"video_end_s": float(zone["video_end_s"]),
			"station_start_m": s0,
			"station_end_m": s1,
			"target_count": target,
			"accepted_count": accepted,
			"accepted_ratio": float(accepted) / float(maxi(target, 1)),
			"attempt_count": attempts,
			"cluster_count": cluster_count,
			"active_station_windows_m": active_station_windows,
			"side_route_left_sign": side,
			"offset_min_m": offset_min,
			"offset_max_m": offset_max,
		})

func _build_multimeshes(grouped: Dictionary) -> bool:
	for key_variant in grouped.keys():
		var key := String(key_variant)
		var items: Array = grouped[key]
		var mesh := _tree_meshes.get(key) as Mesh
		if mesh == null or items.is_empty():
			continue
		var chunks: Dictionary = {}
		for item in items:
			var root: Vector3 = item["root_world"]
			var cx := floori(root.x / tree_chunk_size_m)
			var cz := floori(root.z / tree_chunk_size_m)
			var chunk_key := "%d:%d" % [cx, cz]
			if not chunks.has(chunk_key):
				chunks[chunk_key] = {"cx": cx, "cz": cz, "items": []}
			(chunks[chunk_key]["items"] as Array).append(item)
		for chunk_key_variant in chunks.keys():
			var chunk: Dictionary = chunks[chunk_key_variant]
			var cx := int(chunk["cx"])
			var cz := int(chunk["cz"])
			var origin := Vector3((float(cx) + 0.5) * tree_chunk_size_m, 0.0, (float(cz) + 0.5) * tree_chunk_size_m)
			var chunk_items: Array = chunk["items"]
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.mesh = mesh
			multimesh.instance_count = chunk_items.size()
			var authored_positions := PackedVector3Array()
			var authored_stations := PackedFloat32Array()
			var authored_ground_positions := PackedVector3Array()
			var authored_scales := PackedVector3Array()
			var proof_records: Array[Dictionary] = []
			for index in chunk_items.size():
				var item: Dictionary = chunk_items[index]
				var root: Vector3 = item["root_world"]
				var basis: Basis = item["basis"]
				multimesh.set_instance_transform(index, Transform3D(basis, root - origin))
				authored_positions.append(root)
				authored_stations.append(float(item["station_m"]))
				authored_ground_positions.append(item["ground"])
				authored_scales.append(Vector3(float(item["width_scale"]), float(item["height_scale"]), float(item["width_scale"])))
				var fit: Dictionary = item["root_fit"]
				var proof := {
					"index": index,
					"root_world": root,
					"ground": item["ground"],
					"ground_source": item["ground_source"],
					"ground_triangle_start": item["ground_triangle_start"],
					"ground_triangle_surface": item["ground_triangle_surface"],
					"ground_triangle_barycentric": item["ground_triangle_barycentric"],
					"ground_normal": item["ground_normal"],
					"contact_count": int(fit.get("contact_count", 0)),
					"max_positive_clearance_m": float(fit.get("post_correction_max_positive_clearance_m", 0.0)),
					"max_burial_m": float(fit.get("max_burial_m", 0.0)),
					"contact_ground_sources": fit.get("ground_sources", []),
				}
				if proof_records.size() < 24:
					proof_records.append(proof)
				if _root_proof_samples.size() < MAX_ROOT_PROOF_SAMPLES:
					_root_proof_samples.append(proof)
			var instance := MultiMeshInstance3D.new()
			instance.name = "SaisiesReleaseForest_%s_%d_%d" % [key, cx, cz]
			instance.multimesh = multimesh
			instance.position = origin
			instance.visibility_range_end = 2300.0
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			instance.set_meta("saisies_release_forest_family", String(chunk_items[0]["family"]))
			instance.set_meta("saisies_release_forest_variant", int(chunk_items[0]["variant"]))
			instance.set_meta("saisies_release_forest_instance_count", chunk_items.size())
			instance.set_meta("saisies_release_forest_chunk_origin", origin)
			instance.set_meta("saisies_release_forest_authored_positions", authored_positions)
			instance.set_meta("saisies_release_forest_authored_stations", authored_stations)
			instance.set_meta("saisies_release_forest_authored_ground_positions", authored_ground_positions)
			instance.set_meta("saisies_release_forest_authored_scales", authored_scales)
			instance.set_meta("saisies_release_forest_root_proof_samples", proof_records)
			instance.set_meta("saisies_release_forest_ground_contract", "World/Landscape/SaisiesGeoTerrain transformed indexed triangle")
			instance.set_meta("saisies_release_forest_root_contract", "lowest indexed surface0 wood contact points, world-Y upright basis")
			_replacement.add_child(instance)
			_replacement_groups += 1
	return _replacement_groups > 0

func _fit_root_contacts(contacts: Array[Vector3], basis: Basis, root: Vector3, fallback_ground: Vector3) -> Dictionary:
	if contacts.size() < 4 or not root.is_finite() or not fallback_ground.is_finite():
		return {}
	var world_points := PackedVector3Array()
	var ground_heights := PackedFloat32Array()
	var ground_sources: Array[String] = []
	var triangle_starts := PackedInt32Array()
	var triangle_surfaces := PackedInt32Array()
	var barycentrics := PackedVector3Array()
	var min_ground := INF
	var max_ground := -INF
	var max_positive := 0.0
	for local_point in contacts:
		var world_point := root + basis * local_point
		var sample := _sample_ground(Vector2(world_point.x, world_point.z))
		if sample.is_empty():
			_root_contact_miss_count += 1
			return {}
		var ground_y := float((sample["position"] as Vector3).y)
		if not is_finite(ground_y):
			_root_contact_miss_count += 1
			return {}
		world_points.append(world_point)
		ground_heights.append(ground_y)
		ground_sources.append(String(sample.get("source", "World/Landscape/SaisiesGeoTerrain indexed triangle")))
		triangle_starts.append(int(sample.get("triangle_start", -1)))
		triangle_surfaces.append(int(sample.get("surface", -1)))
		barycentrics.append(sample.get("barycentric", Vector3.ZERO))
		min_ground = minf(min_ground, ground_y)
		max_ground = maxf(max_ground, ground_y)
		max_positive = maxf(max_positive, maxf(world_point.y - ground_y, 0.0))
	var ground_range := max_ground - min_ground
	if not is_finite(ground_range) or ground_range > MAX_ROOT_GROUND_RANGE_M:
		return {}
	var additional_bury := max_positive + ROOT_BURY_MARGIN_M if max_positive > 0.0 else ROOT_BURY_MARGIN_M
	var corrected_root := root - Vector3.UP * additional_bury
	var corrected_positive := 0.0
	var max_burial := 0.0
	for index in world_points.size():
		var corrected := world_points[index] - Vector3.UP * additional_bury
		var clearance := corrected.y - ground_heights[index]
		corrected_positive = maxf(corrected_positive, maxf(clearance, 0.0))
		max_burial = maxf(max_burial, maxf(-clearance, 0.0))
	if corrected_positive > 0.002 or max_burial > MAX_ROOT_BURIAL_M:
		return {}
	_root_max_positive_clearance_m = maxf(_root_max_positive_clearance_m, corrected_positive)
	_root_max_burial_m = maxf(_root_max_burial_m, max_burial)
	_root_contact_count += contacts.size()
	return {
		"valid": corrected_root.is_finite(),
		"root_position": corrected_root,
		"contact_count": contacts.size(),
		"ground_sources": ground_sources,
		"ground_heights": ground_heights,
		"triangle_starts": triangle_starts,
		"triangle_surfaces": triangle_surfaces,
		"barycentrics": barycentrics,
		"ground_range_m": ground_range,
		"initial_max_positive_clearance_m": max_positive,
		"post_correction_max_positive_clearance_m": corrected_positive,
		"max_burial_m": max_burial,
		"additional_bury_m": additional_bury,
	}

func _sample_ground(point: Vector2) -> Dictionary:
	_terrain_sample_count += 1
	if _terrain_direct_sampler_used and _terrain_sampler != null:
		var direct: Variant = _terrain_sampler.call("sample_mesh_triangle", point)
		if direct is Dictionary and direct.has("height") and direct.has("a") and direct.has("b") and direct.has("c"):
			var direct_a: Vector3 = direct["a"]
			var direct_b: Vector3 = direct["b"]
			var direct_c: Vector3 = direct["c"]
			var direct_normal := (direct_b - direct_a).cross(direct_c - direct_a)
			if direct_normal.length_squared() > 0.000001:
				direct_normal = direct_normal.normalized()
				if direct_normal.y < 0.0:
					direct_normal = -direct_normal
			else:
				direct_normal = Vector3.UP
			return {
				"position": Vector3(point.x, float(direct["height"]), point.y),
				"normal": direct_normal,
				"source": "World/Landscape/SaisiesGeoTerrain indexed triangle via Landscape.sample_mesh_triangle",
				"triangle_start": int(direct.get("triangle_start", -1)),
				"surface": 0,
				"barycentric": direct.get("barycentric", Vector3.ZERO),
			}
	var best_y := -INF
	var best: Dictionary = {}
	var bx := floori(point.x / terrain_bin_size_m)
	var bz := floori(point.y / terrain_bin_size_m)
	var seen: Dictionary = {}
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var bucket: Array = _ground_bins.get(_bin_key(bx + dx, bz + dz), [])
			for raw_index in bucket:
				var triangle_index := int(raw_index)
				if seen.has(triangle_index):
					continue
				seen[triangle_index] = true
				var triangle: Dictionary = _ground_triangles[triangle_index]
				var a: Vector3 = triangle["a"]; var b: Vector3 = triangle["b"]; var c: Vector3 = triangle["c"]
				var barycentric := _barycentric_xz(point, a, b, c)
				if barycentric.x < -GROUND_SAMPLE_EPSILON or barycentric.y < -GROUND_SAMPLE_EPSILON or barycentric.z < -GROUND_SAMPLE_EPSILON:
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
					"source": "World/Landscape/SaisiesGeoTerrain indexed triangle",
					"triangle_start": int(triangle["start"]),
					"surface": int(triangle["surface"]),
					"barycentric": barycentric,
				}
	return best

func _nearest_route(point: Vector2) -> Dictionary:
	var bx := floori(point.x / route_bin_size_m)
	var bz := floori(point.y / route_bin_size_m)
	var best_distance_squared := INF
	var best_station := NAN
	var best_point := Vector2.INF
	var seen: Dictionary = {}
	var radius := maxi(2, int(ceil((_max_candidate_offset_m + route_bin_size_m) / maxf(route_bin_size_m, 1.0))))
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			var bucket: Array = _route_bins.get(_bin_key(bx + dx, bz + dz), [])
			for raw_index in bucket:
				var index := int(raw_index)
				if seen.has(index):
					continue
				seen[index] = true
				var segment: Dictionary = _route_segments[index]
				var a: Vector2 = segment["a"]; var b: Vector2 = segment["b"]
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
				best_station = lerpf(float(segment["s0"]), float(segment["s1"]), t)
	if not is_finite(best_station) or not best_point.is_finite():
		return {"valid": false}
	var route_point := Vector3(_route.call("pos_at", best_station))
	var left := Vector3(_route.call("left_at", best_station)).normalized()
	var left_xz := Vector2(left.x, left.z).normalized()
	var delta := point - Vector2(route_point.x, route_point.z)
	return {
		"valid": route_point.is_finite() and left_xz.is_finite(),
		"station_m": best_station,
		"lateral_m": delta.dot(left_xz),
		"distance_m": sqrt(best_distance_squared),
		"nearest_point_xz": best_point,
	}

func _collect_existing_tree_points() -> void:
	_existing_tree_bins.clear()
	var root: Node = get_parent() if get_parent() != null else self
	var scan_bounds := _ground_bounds.grow(tree_chunk_size_m * 0.5)
	for child in root.find_children("*", "MultiMeshInstance3D", true, false):
		var instance := child as MultiMeshInstance3D
		if instance == null or instance == self or instance.multimesh == null:
			continue
		var node_name := String(instance.name).to_lower()
		var is_tree := node_name.contains("tree") or node_name.contains("forest") or instance.has_meta("forest_species")
		if not is_tree:
			continue
		_existing_tree_scan_nodes += 1
		var authored: Variant = instance.get_meta("forest_authored_positions", PackedVector3Array())
		var chunk_origin := instance.global_transform.origin
		var has_spatial_metadata := authored is PackedVector3Array and not (authored as PackedVector3Array).is_empty()
		if has_spatial_metadata and not scan_bounds.has_point(Vector2(chunk_origin.x, chunk_origin.z)):
			continue
		if has_spatial_metadata:
			for p in authored as PackedVector3Array:
				_existing_tree_points_scanned += 1
				if p.is_finite() and scan_bounds.has_point(Vector2(p.x, p.z)):
					_add_existing_tree_point(Vector2(p.x, p.z))
					_existing_tree_points_added += 1
			continue
		var transform := instance.global_transform
		for index in instance.multimesh.instance_count:
			_existing_tree_points_scanned += 1
			var p := transform * instance.multimesh.get_instance_transform(index).origin
			if p.is_finite() and scan_bounds.has_point(Vector2(p.x, p.z)):
				_add_existing_tree_point(Vector2(p.x, p.z))
				_existing_tree_points_added += 1

func _collect_building_bounds() -> void:
	var buildings := _world.get_node_or_null("Buildings")
	if buildings == null:
		return
	for child in buildings.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		_building_bounds.append(_world_aabb(mesh_instance))

func _is_clear_of_buildings(point: Vector3) -> bool:
	var xz := Vector2(point.x, point.z)
	for bounds in _building_bounds:
		var expanded := bounds.grow(4.0)
		if expanded.has_point(Vector3(point.x, bounds.position.y, point.z)) or (xz.x >= expanded.position.x and xz.x <= expanded.end.x and xz.y >= expanded.position.z and xz.y <= expanded.end.z):
			return false
	return true

func _world_aabb(instance: MeshInstance3D) -> AABB:
	var local := instance.get_aabb()
	var corners := [
		local.position,
		local.position + Vector3(local.size.x, 0.0, 0.0),
		local.position + Vector3(0.0, local.size.y, 0.0),
		local.position + Vector3(0.0, 0.0, local.size.z),
		local.end,
		local.position + Vector3(local.size.x, local.size.y, 0.0),
		local.position + Vector3(local.size.x, 0.0, local.size.z),
		local.position + Vector3(0.0, local.size.y, local.size.z),
	]
	var first: Vector3 = instance.global_transform * corners[0]
	var result := AABB(first, Vector3.ZERO)
	for corner in corners:
		result = result.expand(instance.global_transform * corner)
	return result

func _is_too_close_to_existing(point: Vector2) -> bool:
	var bx := floori(point.x / EXISTING_TREE_SPACING_M)
	var bz := floori(point.y / EXISTING_TREE_SPACING_M)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var bucket: Array = _existing_tree_bins.get(_bin_key(bx + dx, bz + dz), [])
			for existing in bucket:
				if point.distance_to(existing) < MIN_TREE_SPACING_M:
					return true
	return false

func _add_existing_tree_point(point: Vector2) -> void:
	var bx := floori(point.x / EXISTING_TREE_SPACING_M)
	var bz := floori(point.y / EXISTING_TREE_SPACING_M)
	var key := _bin_key(bx, bz)
	if not _existing_tree_bins.has(key):
		_existing_tree_bins[key] = []
	(_existing_tree_bins[key] as Array).append(point)

func _route_point(station: float, lateral: float) -> Vector3:
	var p := Vector3(_route.call("pos_at", station)) + Vector3(_route.call("left_at", station)).normalized() * lateral
	if _route.has_method("ground_y"):
		p.y = float(_route.call("ground_y", station, lateral))
	return p

func _station_for_video_seconds(video_seconds: float) -> float:
	var t := clampf(video_seconds, FIRST_FOREST_VIDEO_S, LAST_FOREST_VIDEO_S)
	if _station_overrides.size() >= 2:
		if t <= float(_station_overrides.front()["video_seconds"]):
			return float(_station_overrides.front()["station_m"])
		for index in range(_station_overrides.size() - 1):
			var a: Dictionary = _station_overrides[index]
			var b: Dictionary = _station_overrides[index + 1]
			var ta := float(a["video_seconds"]); var tb := float(b["video_seconds"])
			if t <= tb:
				return lerpf(float(a["station_m"]), float(b["station_m"]), clampf((t - ta) / maxf(tb - ta, 0.001), 0.0, 1.0))
		return float(_station_overrides.back()["station_m"])
	return clampf(float(_route.call("distance_for_video_seconds", t)), FIRST_FOREST_STATION_M, float(_route.get("length_m")))

func _in_open_window(zone: Dictionary, video_seconds: float) -> bool:
	for raw_window in zone.get("open_windows_s", []) as Array:
		if raw_window is Array and (raw_window as Array).size() >= 2:
			var start := float((raw_window as Array)[0]); var end := float((raw_window as Array)[1])
			if video_seconds >= start and video_seconds <= end:
				return true
	return false

func _active_station_windows(zone: Dictionary, station_start: float, station_end: float) -> Array:
	var active: Array = [[station_start, station_end]]
	for raw_window in zone.get("open_windows_s", []) as Array:
		if not raw_window is Array or (raw_window as Array).size() < 2:
			continue
		var open_start := clampf(_station_for_video_seconds(float((raw_window as Array)[0])), station_start, station_end)
		var open_end := clampf(_station_for_video_seconds(float((raw_window as Array)[1])), station_start, station_end)
		if open_end <= open_start:
			continue
		var remaining: Array = []
		for raw_interval in active:
			var interval := raw_interval as Array
			var interval_start := float(interval[0])
			var interval_end := float(interval[1])
			if open_end <= interval_start or open_start >= interval_end:
				remaining.append([interval_start, interval_end])
				continue
			if open_start > interval_start:
				remaining.append([interval_start, open_start])
			if open_end < interval_end:
				remaining.append([open_end, interval_end])
		active = remaining
	return active

func _station_in_active_windows(station: float, windows: Array) -> bool:
	for raw_window in windows:
		if not raw_window is Array or (raw_window as Array).size() < 2:
			continue
		var window := raw_window as Array
		if station >= float(window[0]) and station <= float(window[1]):
			return true
	return false

func _build_meta_source_frames() -> Array:
	var frames: Array = []
	for raw_view in _candidate.get("source_station_overrides", []) as Array:
		if raw_view is Dictionary:
			frames.append({"scene_id": String((raw_view as Dictionary).get("scene_id", "")), "video_seconds": float((raw_view as Dictionary).get("video_seconds", 0.0)), "station_m": float((raw_view as Dictionary).get("station_m", 0.0))})
	return frames

func _publish_ready_state() -> void:
	set_meta("saisies_release_forest_ready", true)
	set_meta("saisies_release_forest_status", RELEASE_STATUS)
	set_meta("saisies_release_forest_visual_acceptance", RELEASE_VISUAL_STATUS)
	set_meta("saisies_release_forest_enabled", true)
	set_meta("saisies_release_forest_count", _tree_count)
	set_meta("saisies_release_forest_tree_count", _tree_count)
	set_meta("saisies_release_forest_instance_count", _tree_count)
	set_meta("saisies_release_forest_target_count", _target_count)
	var minimum_target_count := maxi(1, int(ceil(float(_target_count) * MIN_ACCEPTED_TARGET_RATIO)))
	var density_contract := _tree_count >= minimum_target_count
	set_meta("saisies_release_forest_minimum_target_count", minimum_target_count)
	set_meta("saisies_release_forest_acceptance_ratio", float(_tree_count) / float(maxi(_target_count, 1)))
	set_meta("saisies_release_forest_density_contract", density_contract)
	set_meta("saisies_release_forest_generation_complete", true)
	set_meta("saisies_release_forest_broadleaf_count", _broadleaf_count)
	set_meta("saisies_release_forest_conifer_count", _conifer_count)
	set_meta("saisies_release_forest_group_count", _replacement_groups)
	set_meta("saisies_release_forest_patch_count", _patch_records.size())
	set_meta("saisies_release_forest_patches", _patch_records.slice(0, mini(_patch_records.size(), MAX_PATCH_RECORDS)))
	set_meta("saisies_release_forest_source_frames", _build_meta_source_frames())
	set_meta("saisies_release_forest_source_contract", "round36_release source manifest S04-S18; S05-S18 overlay, S01-S03 and R35 S04 preserved")
	set_meta("saisies_release_forest_actual_terrain", {
		"source": "World/Landscape/SaisiesGeoTerrain indexed triangle",
		"mesh_path": String(_terrain_mesh_instance.get_path()),
		"sampler_mode": "Landscape.sample_mesh_triangle" if _terrain_direct_sampler_used else "release spatial triangle bins",
		"mesh_triangle_count": int(_terrain_sampler.get_meta("saisies_geo_landscape_triangle_count", 0)) if _terrain_sampler != null else _terrain_cached_triangle_count,
		"scan_triangle_count": _terrain_scan_triangle_count,
		"cached_triangle_count": _terrain_cached_triangle_count,
		"spatial_bin_count": _ground_bins.size(),
		"sample_count": _terrain_sample_count,
		"direct_mesh_sampler_used": _terrain_direct_sampler_used,
		"direct_mesh_sampler": String(_terrain_sampler.get_path()) if _terrain_direct_sampler_used and _terrain_sampler != null else "",
		"dem_fallback_used": false,
	})
	set_meta("saisies_release_forest_root_contact_proof", {
		"contact_count": _root_contact_count,
		"contact_miss_count": _root_contact_miss_count,
		"sample_count": _root_proof_samples.size(),
		"max_positive_clearance_m": _root_max_positive_clearance_m,
		"max_burial_m": _root_max_burial_m,
		"source": "indexed surface0 wood points against visible terrain triangles",
		"world_y_upright": true,
		"distribution_policy": "deterministic_clustered_stratified_jitter",
		"accepted_tree_count": _tree_count,
		"max_candidate_offset_m": _max_candidate_offset_m,
		"samples": _root_proof_samples,
	})
	set_meta("saisies_release_forest_root_contacts", _root_proof_samples)
	set_meta("saisies_release_forest_root_contact_count", _root_contact_count)
	set_meta("saisies_release_forest_reject_counts", _candidate_reject_counts.duplicate(true))
	set_meta("saisies_release_forest_existing_tree_scan", {
		"tree_nodes_scanned": _existing_tree_scan_nodes,
		"points_scanned": _existing_tree_points_scanned,
		"points_added": _existing_tree_points_added,
		"bounds_source": "candidate ground bounds plus one tree chunk radius",
	})
	set_meta("saisies_release_forest_no_old_nodes_hidden", true)
	set_meta("saisies_release_forest_masked_old_instance_count", 0)
	set_meta("saisies_release_forest_distribution_policy", "deterministic_clustered_stratified_jitter")
	var build_diagnostic := "built_from_source_backed_S05-S18_zones; seeded_rng_cluster_candidates"
	if not density_contract:
		build_diagnostic = "underfilled candidate: accepted %d/%d, minimum %d" % [_tree_count, _target_count, minimum_target_count]
	set_meta("saisies_release_forest_build_diagnostic", build_diagnostic)

func _publish_disabled_state() -> void:
	set_meta("saisies_release_forest_ready", true)
	set_meta("saisies_release_forest_status", RELEASE_STATUS)
	set_meta("saisies_release_forest_visual_acceptance", RELEASE_VISUAL_STATUS)
	set_meta("saisies_release_forest_enabled", false)
	set_meta("saisies_release_forest_count", 0)
	set_meta("saisies_release_forest_tree_count", 0)
	set_meta("saisies_release_forest_instance_count", 0)
	set_meta("saisies_release_forest_target_count", 0)
	set_meta("saisies_release_forest_minimum_target_count", 0)
	set_meta("saisies_release_forest_acceptance_ratio", 0.0)
	set_meta("saisies_release_forest_density_contract", false)
	set_meta("saisies_release_forest_generation_complete", false)
	set_meta("saisies_release_forest_broadleaf_count", 0)
	set_meta("saisies_release_forest_conifer_count", 0)
	set_meta("saisies_release_forest_group_count", 0)
	set_meta("saisies_release_forest_patches", [])
	set_meta("saisies_release_forest_actual_terrain", {"source": "disabled", "dem_fallback_used": false})
	set_meta("saisies_release_forest_root_contact_proof", {"contact_count": 0, "contact_miss_count": 0, "samples": []})
	set_meta("saisies_release_forest_root_contacts", [])
	set_meta("saisies_release_forest_root_contact_count", 0)
	set_meta("saisies_release_forest_no_old_nodes_hidden", true)
	set_meta("saisies_release_forest_masked_old_instance_count", 0)
	set_meta("saisies_release_forest_distribution_policy", "deterministic_clustered_stratified_jitter")

func _all_finite() -> bool:
	if _replacement == null or not is_finite(float(_tree_count)):
		return false
	for child in _replacement.get_children():
		if child is MultiMeshInstance3D:
			var instance := child as MultiMeshInstance3D
			if instance.multimesh == null or instance.multimesh.mesh == null:
				return false
			for index in instance.multimesh.instance_count:
				if not instance.multimesh.get_instance_transform(index).is_finite():
					return false
	return true

func _triangle_intersects_bounds(a: Vector3, b: Vector3, c: Vector3, bounds: Rect2) -> bool:
	var min_x := minf(a.x, minf(b.x, c.x)); var max_x := maxf(a.x, maxf(b.x, c.x))
	var min_z := minf(a.z, minf(b.z, c.z)); var max_z := maxf(a.z, maxf(b.z, c.z))
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

func _bin_key(x: int, z: int) -> String:
	return "%d:%d" % [x, z]

func _hash01(value: int, salt: int) -> float:
	var hashed := hash("release_forest:%d:%d" % [value, salt]) & 0x7fffffff
	return float(hashed) / 2147483647.0

func _sort_station_override(a: Dictionary, b: Dictionary) -> bool:
	return float(a.get("video_seconds", 0.0)) < float(b.get("video_seconds", 0.0))

func _has_flag(flag: String) -> bool:
	for argument in OS.get_cmdline_user_args():
		if String(argument) == flag:
			return true
	return false

func _retry(message: String) -> void:
	_build_attempts += 1
	if _build_attempts < 240:
		call_deferred("_retry_next_frame")
		return
	_fail(message)

func _retry_next_frame() -> void:
	await get_tree().process_frame
	_try_build()

func _fail(message: String) -> void:
	set_meta("saisies_release_forest_ready", false)
	set_meta("saisies_release_forest_error", message)
	push_error(message)
