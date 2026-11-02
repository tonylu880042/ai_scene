class_name SaisiesGeoForest
extends Node3D

## OSM forest-polygon staging for the independent geographic Saisies scene.
##
## The OSM data describes land-cover polygons, not measured individual trees.
## Trees are therefore an estimated deterministic scatter inside the polygons.
## The runtime owns the whole route and keeps trees inside the OSM forest
## polygons.  Near the actual asphalt edge it uses an irregular woodland
## scatter for the first ~100 m; farther trees are a deliberately lighter
## background population.  S08/S13 are small, evidence-backed density slices,
## not a route-wide visual override.

@export_file("*.json") var forest_file := "res://data/saisies_geo_forest.json"
@export_file("*.json") var buildings_file := "res://data/saisies_geo_buildings.json"
@export var route_path: NodePath
@export var landscape_path: NodePath
@export var runtime_route_end_m := 0.0
@export var forest_search_margin_m := 620.0
@export var grid_spacing_m := 12.0
## Extra distance from the asphalt edge. The trunk exclusion is computed as
## route.road_width_at(s) * 0.5 + this value, so crowns may overhang the road.
@export var road_clearance_m := 2.5
@export var near_road_range_m := 100.0
@export var near_density_probability := 0.86
@export var far_density_probability := 0.18
@export var quality_density_multiplier := 1.18
@export var poisson_min_separation_m := 7.5
@export var max_road_distance_m := 600.0
@export var building_clearance_m := 4.0
@export var chunk_size_m := 256.0
@export var visibility_range_m := 2000.0
@export var max_tree_instances := 12000
@export var random_seed := 8207

const ROUTE_HASH_CELL_M := 128.0
const POISSON_HASH_CELL_M := 8.0
const QUALITY_STATION_PADDING_M := 220.0
const S09_MASK_START_VIDEO_SECONDS := 318.0
const S09_MASK_CENTER_VIDEO_SECONDS := 330.0
const S09_MASK_END_VIDEO_SECONDS := 344.0
const S09_RIGHT_START_VIDEO_SECONDS := 328.0
const S09_RIGHT_END_VIDEO_SECONDS := 336.0
const S09_MASK_MAX_LATERAL_M := 35.0
const S09_MASK_LATERAL_FADE_M := 8.0
const S09_MASK_LONGITUDINAL_FADE_M := 60.0
const S09_RIGHT_MAX_ROAD_DISTANCE_M := 120.0
const S09_RIGHT_VARIATION_RADIUS_M := 9.0
const S09_RIGHT_VARIATION_COUNT := 5
const S09_CANONICAL_STATION_DISTANCE_M := 5431.282674
const S09_VIDEO_RIGHT_MIN_U_M := -35.0
const S09_VIDEO_RIGHT_MAX_U_M := -7.0
const S09_VIDEO_RIGHT_SAMPLES := 7
const S09_VIDEO_RIGHT_U_LAYERS := 4
const S09_VIDEO_RIGHT_SOURCE_CONTRACT := "VIDEO_S09_RIGHT_BAND_328_336"
const S09_VIDEO_RIGHT_SOURCE_REFERENCE := "S09 canonical station 5431.282674m; source frames 330/334; export/saisies/review/round11_analysis/s09_source/source_contact.jpg + source_manifest.json; contact_sha256=8e1f3c0d51a7fb46a1ce59b93f92f7840f07665b4522e3b07edd66ef27c6c016; manifest_sha256=f246369f5a62610f7a0b683dd0e1ff99433370d4c23b6c399716b77fd6cf8805"
const S13_CLIFF_START_VIDEO_SECONDS := 627.5
const S13_CLIFF_END_VIDEO_SECONDS := 632.5
const S13_CLIFF_MAX_LATERAL_M := 30.0
const S13_CLIFF_LATERAL_FADE_M := 3.0
const S13_CLIFF_LONGITUDINAL_FADE_M := 35.0
const ROOT_BURY_MARGIN_M := 0.06
const ROOT_LOW_BAND_M := 0.30
const ROOT_FOOTPRINT_POINT_LIMIT := 12
const ROOT_MAX_BURIAL_M := 0.85
const ROOT_FAR_MAX_BURIAL_M := 1.20
const QUALITY_STATIONS := [
	{"id": "S08", "video_seconds": 315.0, "note": "S08 dense roadside broadleaf canopy and wall-side woodland"},
	{"id": "S13", "video_seconds": 630.0, "note": "S13 dense right-side broadleaf canopy with conifer exit"},
]

var route: SaisiesRoute
var geography: Object
var landscape: Node
var forest_ready := false
var geometry_errors := 0
var skipped_candidates := 0
var _broadleaf: Array = []
var _conifer: Array = []
var _forest_polygons: Array = []
var _building_polygons: Array = []
var _route_samples: Array = []
var _occupied_cells: Dictionary = {}
var _route_segment_spatial_hash: Dictionary = {}
var _route_candidate_cache: Dictionary = {}
var _tree_items: Dictionary = {}
var _chunk_count := 0
var _tree_candidate_count := 0
var _tree_candidate_near_count := 0
var _tree_candidate_far_count := 0
var _tree_near_count := 0
var _tree_far_count := 0
var _tree_quality_counts: Dictionary = {}
var _route_hash_cell_count := 0
var _scatter_jitter_values: Array[Vector2] = []
var _root_footprints: Dictionary = {}
var _root_steep_skipped := 0
var _root_full_fit_count := 0
var _root_far_fit_count := 0
var _s09_mask_removed := 0
var _s13_cliff_removed := 0
var _s09_right_diagnostics: Dictionary = {}
var _s09_video_right_diagnostics: Dictionary = {}

func _ready() -> void:
	route = get_node_or_null(route_path) as SaisiesRoute
	if route == null and get_parent() != null:
		route = get_parent().get_node_or_null("Route") as SaisiesRoute
	_resolve_landscape()
	if route == null or not route.route_ready() or not _landscape_ready_if_requested():
		call_deferred("_try_build")
		return
	_build()

func _try_build() -> void:
	if forest_ready:
		return
	if route == null:
		route = get_node_or_null(route_path) as SaisiesRoute
	_resolve_landscape()
	if route != null and route.route_ready() and _landscape_ready_if_requested():
		_build()
	else:
		call_deferred("_try_build")

func _build() -> void:
	if forest_ready or route == null:
		return
	if not _landscape_ready_if_requested():
		return
	if not _route_has_property("geography"):
		push_warning("SaisiesGeoForest HOLD: route.geography is not exposed")
		return
	geography = route.get("geography") as Object
	if geography == null or not geography.has_method("world_from_latlon") or not geography.has_method("height_world"):
		push_warning("SaisiesGeoForest HOLD: route.geography lacks geographic helpers")
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(forest_file)) if FileAccess.file_exists(forest_file) else null
	if not (parsed is Dictionary):
		push_error("SaisiesGeoForest: forest data is missing or invalid")
		return
	var payload: Dictionary = parsed
	var features: Array = payload.get("features", [])
	if features.is_empty():
		push_error("SaisiesGeoForest: forest data has no accepted polygons")
		return
	if not _load_tree_factory():
		push_error("SaisiesGeoForest: SaisiesTrees variants are unavailable")
		return
	_build_route_samples()
	_build_forest_polygons(features)
	_load_building_polygons()
	_scatter_trees()
	_spawn_tree_chunks()
	set_meta("saisies_geo_forest_ready", true)
	set_meta("saisies_geo_forest_data", forest_file)
	set_meta("saisies_geo_forest_polygon_count", _forest_polygons.size())
	set_meta("saisies_geo_forest_building_polygon_count", _building_polygons.size())
	set_meta("saisies_geo_forest_tree_instance_count", _tree_instance_count())
	set_meta("saisies_geo_forest_chunk_count", _chunk_count)
	set_meta("saisies_geo_forest_skipped_candidates", skipped_candidates)
	set_meta("saisies_geo_forest_geometry_errors", geometry_errors)
	set_meta("saisies_geo_forest_route_end_m", _effective_route_end_m())
	set_meta("saisies_geo_forest_max_road_distance_m", max_road_distance_m)
	set_meta("saisies_geo_forest_grid_spacing_m", grid_spacing_m)
	set_meta("saisies_geo_forest_near_road_range_m", near_road_range_m)
	set_meta("saisies_geo_forest_near_tree_count", _tree_near_count)
	set_meta("saisies_geo_forest_far_tree_count", _tree_far_count)
	set_meta("saisies_geo_forest_candidate_near_count", _tree_candidate_near_count)
	set_meta("saisies_geo_forest_candidate_far_count", _tree_candidate_far_count)
	set_meta("saisies_geo_forest_quality_station_counts", _tree_quality_counts.duplicate(true))
	set_meta("saisies_geo_forest_quality_station_contract", "S08/S13 local video-supported woodland density slices; not a route-wide override")
	set_meta("saisies_geo_forest_road_clearance_margin_m", clampf(road_clearance_m, 2.0, 3.0))
	set_meta("saisies_geo_forest_route_hash_cell_m", ROUTE_HASH_CELL_M)
	set_meta("saisies_geo_forest_route_hash_cells", _route_hash_cell_count)
	set_meta("saisies_geo_forest_poisson_min_separation_m", poisson_min_separation_m)
	set_meta("saisies_geo_forest_scatter_jitter_std_m", _scatter_jitter_std())
	set_meta("saisies_geo_forest_scatter_contract", "deterministic jittered candidates with spatial-hash Poisson separation")
	set_meta("saisies_geo_forest_canopy_projection_proxy", _quality_canopy_projection_proxy())
	set_meta("saisies_geo_forest_species_estimated", true)
	set_meta("saisies_geo_forest_visibility_range_m", visibility_range_m)
	set_meta("saisies_geo_forest_chunk_size_m", chunk_size_m)
	set_meta("saisies_geo_forest_tree_candidate_count", _tree_candidate_count)
	set_meta("saisies_geo_forest_ground_source", "landscape.sample_mesh_triangle" if _has_landscape_sampler() else "route.geography.height_world")
	set_meta("saisies_geo_forest_landscape_grounding", _has_landscape_sampler())
	set_meta("saisies_geo_forest_authored_transform_contract", "authored positions and root offsets are retained per instance on each chunk; native GPU readback is a separate check")
	set_meta("saisies_geo_forest_root_footprint_contract", "indexed near-mesh low-Y root points are transformed, sampled against terrain, and buried by a small margin; origin y may be offset below the candidate ground")
	set_meta("saisies_geo_forest_root_full_fit_count", _root_full_fit_count)
	set_meta("saisies_geo_forest_root_far_fit_count", _root_far_fit_count)
	set_meta("saisies_geo_forest_root_steep_skipped", _root_steep_skipped)
	set_meta("saisies_geo_forest_root_max_burial_m", ROOT_MAX_BURIAL_M)
	set_meta("saisies_geo_forest_root_bury_margin_m", ROOT_BURY_MARGIN_M)
	set_meta("saisies_geo_forest_s09_mask_removed", _s09_mask_removed)
	set_meta("saisies_geo_forest_s09_mask_contract", "S09 requested_seconds 330; left +u road-edge woodland mask 318..344s with 60m longitudinal and 8m lateral fades")
	set_meta("saisies_geo_forest_s09_right_diagnostics", _s09_right_diagnostics.duplicate(true))
	set_meta("saisies_geo_forest_s09_right_contract", "bounded 328..336s right-side broadleaf candidates; actual indexed root footprint, asphalt/building/forest checks, no left-grass override")
	set_meta("saisies_geo_forest_s09_video_right_diagnostics", _s09_video_right_diagnostics.duplicate(true))
	set_meta("saisies_geo_forest_s09_video_right_contract", S09_VIDEO_RIGHT_SOURCE_CONTRACT)
	set_meta("saisies_geo_forest_s09_video_right_source_reference", S09_VIDEO_RIGHT_SOURCE_REFERENCE)
	set_meta("saisies_geo_forest_s09_canonical_station_distance_m", S09_CANONICAL_STATION_DISTANCE_M)
	set_meta("saisies_geo_forest_s13_cliff_removed", _s13_cliff_removed)
	set_meta("saisies_geo_forest_s13_cliff_contract", "S13 requested_seconds 630; left +u roadhalf+0.45..30m cliff exclusion 627.5..632.5s with smooth fades")
	set_meta("saisies_geo_forest_lod_triangle_budgets", _lod_budget_summary())
	set_meta("saisies_geo_forest_mesh_bounds", _tree_mesh_bounds_summary())
	forest_ready = true
	print("saisies geo forest: polygons=%d buildings=%d trees=%d near=%d far=%d candidates=%d/%d chunks=%d stations=%s skipped=%d geometry_errors=%d" % [
		_forest_polygons.size(), _building_polygons.size(), _tree_instance_count(), _tree_near_count, _tree_far_count,
		_tree_candidate_near_count, _tree_candidate_far_count, _chunk_count, str(_tree_quality_counts), skipped_candidates, geometry_errors
	])
	print("saisies geo forest roots: full=%d far=%d steep_skipped=%d s09_mask_removed=%d s13_cliff_removed=%d" % [_root_full_fit_count, _root_far_fit_count, _root_steep_skipped, _s09_mask_removed, _s13_cliff_removed])
	print("saisies geo forest S09 video right: %s" % str(_s09_video_right_diagnostics))
	print("saisies geo forest mesh bounds: %s" % str(_tree_mesh_bounds_summary()))

func _route_has_property(property_name: String) -> bool:
	for property in route.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false

func _resolve_landscape() -> void:
	if landscape != null:
		return
	if landscape_path != NodePath():
		landscape = get_node_or_null(landscape_path)
	if landscape == null and landscape_path == NodePath() and get_parent() != null:
		landscape = get_parent().get_node_or_null("Landscape")

func _landscape_requested() -> bool:
	return landscape_path != NodePath()

func _landscape_ready_if_requested() -> bool:
	if not _landscape_requested():
		return true
	_resolve_landscape()
	if landscape == null or not landscape.has_method("sample_mesh_triangle"):
		return false
	for property in landscape.get_property_list():
		if String(property.get("name", "")) == "landscape_ready":
			return bool(landscape.get("landscape_ready"))
	return false

func _has_landscape_sampler() -> bool:
	return landscape != null and landscape.has_method("sample_mesh_triangle")

func _effective_route_end_m() -> float:
	if route == null:
		return maxf(runtime_route_end_m, 0.0)
	if runtime_route_end_m <= 0.0:
		return route.length_m
	return minf(runtime_route_end_m, route.length_m)

func _ground_height(xz: Vector2) -> float:
	if _landscape_requested():
		if not _has_landscape_sampler():
			return NAN
		var sampled = landscape.call("sample_mesh_triangle", xz)
		if sampled is Dictionary and sampled.has("height"):
			var value := float(sampled["height"])
			if is_finite(value):
				return value
		return NAN
	var fallback := float(geography.call("height_world", xz))
	return fallback

func _load_tree_factory() -> bool:
	var factory_script := load("res://scripts/saisies_trees.gd") as Script
	if factory_script == null:
		return false
	var broad = factory_script.call("broadleaf_variants")
	var conifers = factory_script.call("conifer_variants")
	_broadleaf = broad if broad is Array else []
	_conifer = conifers if conifers is Array else []
	_prepare_root_footprints()
	return not _broadleaf.is_empty() and not _conifer.is_empty()

func _prepare_root_footprints() -> void:
	_root_footprints.clear()
	for family in ["broadleaf", "conifer"]:
		var variants: Array = _broadleaf if family == "broadleaf" else _conifer
		for variant_index in variants.size():
			var mesh := variants[variant_index] as Mesh
			if mesh == null:
				continue
			var candidates: Array = []
			var min_y := INF
			var source_surfaces: Array[int] = []
			for surface_index in mesh.get_surface_count():
				# SaisiesTrees keeps the indexed woody trunk on surface 0 and,
				# for scanned broadleaf variants, woody limbs on surface 2.  Surface
				# 1 is the alpha foliage/card stream; its low vertices are not roots.
				if surface_index == 1:
					continue
				var arrays: Array = mesh.surface_get_arrays(surface_index)
				if arrays.size() <= Mesh.ARRAY_VERTEX:
					continue
				var vertices = arrays[Mesh.ARRAY_VERTEX]
				if not (vertices is PackedVector3Array) or vertices.is_empty():
					continue
				if not source_surfaces.has(surface_index):
					source_surfaces.append(surface_index)
				var indices = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX else null
				var used: Dictionary = {}
				if indices is PackedInt32Array and not indices.is_empty():
					for raw_index in indices:
						var index := int(raw_index)
						if index >= 0 and index < vertices.size():
							used[index] = true
				else:
					for index in vertices.size():
						used[index] = true
				for raw_index in used.keys():
					var point: Vector3 = vertices[int(raw_index)]
					if not _finite_vector(point):
						continue
					min_y = minf(min_y, point.y)
					candidates.append({"point": point, "y": point.y})
			if candidates.is_empty() or not is_finite(min_y):
				geometry_errors += 1
				continue
			var low_candidates: Array = []
			for candidate in candidates:
				if float(candidate["y"]) <= min_y + ROOT_LOW_BAND_M:
					low_candidates.append(candidate)
			if low_candidates.is_empty():
				low_candidates = candidates.duplicate()
			low_candidates.sort_custom(Callable(self, "_sort_root_point_candidates"))
			var selected := PackedVector3Array()
			var remaining: Array = low_candidates.duplicate()
			while selected.size() < ROOT_FOOTPRINT_POINT_LIMIT and not remaining.is_empty():
				var best_index := 0
				if not selected.is_empty():
					var best_score := -INF
					for candidate_index in remaining.size():
						var candidate_point: Vector3 = remaining[candidate_index]["point"]
						var nearest_horizontal := INF
						for selected_point in selected:
							nearest_horizontal = minf(nearest_horizontal, Vector2(candidate_point.x, candidate_point.z).distance_to(Vector2(selected_point.x, selected_point.z)))
						var height_penalty := maxf(float(remaining[candidate_index]["y"]) - min_y, 0.0) * 0.35
						var score := nearest_horizontal - height_penalty
						if score > best_score:
							best_score = score
							best_index = candidate_index
				var chosen: Dictionary = remaining[best_index]
				selected.append(chosen["point"])
				remaining.remove_at(best_index)
			var cache_key := "%s_%02d" % [family, variant_index]
			_root_footprints[mesh.get_instance_id()] = selected
			mesh.set_meta("saisies_root_footprint_points", selected)
			mesh.set_meta("saisies_root_footprint_indexed", true)
			mesh.set_meta("saisies_root_footprint_source_surfaces", source_surfaces)
			mesh.set_meta("saisies_root_footprint_min_y", min_y)
			mesh.set_meta("saisies_root_footprint_point_count", selected.size())
			mesh.set_meta("saisies_root_footprint_cache_key", cache_key)
			var footprint_radius := 0.0
			for selected_point in selected:
				footprint_radius = maxf(footprint_radius, Vector2(selected_point.x, selected_point.z).length())
			print("saisies geo forest root footprint %s: indexed_low_points=%d min_y=%.3f radius=%.3f" % [cache_key, selected.size(), min_y, footprint_radius])

func _sort_root_point_candidates(a: Dictionary, b: Dictionary) -> bool:
	return float(a.get("y", INF)) < float(b.get("y", INF))

func _build_route_samples() -> void:
	_route_samples.clear()
	_route_segment_spatial_hash.clear()
	_route_hash_cell_count = 0
	var end_s := clampf(_effective_route_end_m(), 1.0, route.length_m)
	var sample_step := 8.0
	var count := maxi(int(ceil(end_s / sample_step)), 1)
	for index in range(count + 1):
		var s := minf(float(index) * sample_step, end_s)
		var point := route.pos_at(s)
		_route_samples.append({"s": s, "xz": Vector2(point.x, point.z)})
	if _route_samples.is_empty():
		geometry_errors += 1
	_build_route_segment_spatial_hash()

func _build_route_segment_spatial_hash() -> void:
	_route_segment_spatial_hash.clear()
	_route_candidate_cache.clear()
	if _route_samples.size() < 2:
		return
	for segment_index in range(_route_samples.size() - 1):
		var first: Dictionary = _route_samples[segment_index]
		var second: Dictionary = _route_samples[segment_index + 1]
		var a: Vector2 = first["xz"]
		var b: Vector2 = second["xz"]
		var min_x := minf(a.x, b.x)
		var max_x := maxf(a.x, b.x)
		var min_z := minf(a.y, b.y)
		var max_z := maxf(a.y, b.y)
		var min_cell_x := floori(min_x / ROUTE_HASH_CELL_M) - 1
		var max_cell_x := floori(max_x / ROUTE_HASH_CELL_M) + 1
		var min_cell_z := floori(min_z / ROUTE_HASH_CELL_M) - 1
		var max_cell_z := floori(max_z / ROUTE_HASH_CELL_M) + 1
		for cell_x in range(min_cell_x, max_cell_x + 1):
			for cell_z in range(min_cell_z, max_cell_z + 1):
				var key := Vector2i(cell_x, cell_z)
				var bucket: Array = _route_segment_spatial_hash.get(key, [])
				bucket.append(segment_index)
				_route_segment_spatial_hash[key] = bucket
	_route_hash_cell_count = _route_segment_spatial_hash.size()

func _build_forest_polygons(features: Array) -> void:
	_forest_polygons.clear()
	var route_bounds := _route_search_bounds()
	for feature_item in features:
		if not (feature_item is Dictionary):
			geometry_errors += 1
			continue
		var feature: Dictionary = feature_item
		var outers: Array = []
		var holes: Array = []
		for ring_item in feature.get("rings", []):
			if not (ring_item is Dictionary):
				geometry_errors += 1
				continue
			var ring: Dictionary = ring_item
			var points := _world_ring(ring.get("coordinates", []))
			if points.size() < 4:
				geometry_errors += 1
				continue
			if String(ring.get("role", "outer")) == "inner":
				holes.append(points)
			else:
				outers.append(points)
		if outers.is_empty():
			geometry_errors += 1
			continue
		var selected_outers: Array = []
		for outer in outers:
			if _ring_bounds(outer).intersects(route_bounds):
				selected_outers.append(outer)
		if selected_outers.is_empty():
			continue
		_forest_polygons.append({
			"id": String(feature.get("id", "unknown")),
			"osm_id": int(feature.get("osm_id", -1)),
			"leaf_type": String(feature.get("leaf_type", "unknown")),
			"tags": feature.get("tags", {}),
			"outers": selected_outers,
			"holes": holes,
			"source_hash": String(feature.get("source_hash", "")),
		})

func _load_building_polygons() -> void:
	_building_polygons.clear()
	if not FileAccess.file_exists(buildings_file):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(buildings_file))
	if not (parsed is Dictionary):
		geometry_errors += 1
		return
	for feature_item in parsed.get("buildings", []):
		if not (feature_item is Dictionary):
			continue
		var feature: Dictionary = feature_item
		for ring_item in feature.get("rings", []):
			if not (ring_item is Dictionary) or String(ring_item.get("role", "outer")) != "outer":
				continue
			var points := _world_ring(ring_item.get("coordinates", []))
			if points.size() >= 4:
				_building_polygons.append(points)

func _world_ring(raw_coordinates: Variant) -> PackedVector2Array:
	var points := PackedVector2Array()
	if not (raw_coordinates is Array):
		return points
	for coordinate_item in raw_coordinates:
		if not (coordinate_item is Array) or coordinate_item.size() < 2:
			return PackedVector2Array()
		var coordinate: Array = coordinate_item
		var value = geography.call("world_from_latlon", float(coordinate[1]), float(coordinate[0]))
		if not (value is Vector3) or not _finite_vector(value):
			return PackedVector2Array()
		points.append(Vector2(value.x, value.z))
	return points

func _route_search_bounds() -> Rect2:
	if _route_samples.is_empty():
		return Rect2()
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for item in _route_samples:
		var point: Vector2 = item["xz"]
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
		min_z = minf(min_z, point.y)
		max_z = maxf(max_z, point.y)
	var margin := maxf(forest_search_margin_m, max_road_distance_m + 20.0)
	return Rect2(Vector2(min_x - margin, min_z - margin), Vector2(max_x - min_x + margin * 2.0, max_z - min_z + margin * 2.0))

func _ring_bounds(points: PackedVector2Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var min_x := points[0].x
	var max_x := points[0].x
	var min_z := points[0].y
	var max_z := points[0].y
	for point in points:
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
		min_z = minf(min_z, point.y)
		max_z = maxf(max_z, point.y)
	return Rect2(Vector2(min_x, min_z), Vector2(max_x - min_x, max_z - min_z))

func _scatter_trees() -> void:
	_tree_items.clear()
	_occupied_cells.clear()
	_scatter_jitter_values.clear()
	_tree_candidate_count = 0
	_tree_candidate_near_count = 0
	_tree_candidate_far_count = 0
	_tree_near_count = 0
	_tree_far_count = 0
	_tree_quality_counts.clear()
	_root_steep_skipped = 0
	_root_full_fit_count = 0
	_root_far_fit_count = 0
	_s09_mask_removed = 0
	_s13_cliff_removed = 0
	_s09_right_diagnostics = {
		"seen": 0,
		"policy_accept": 0,
		"policy_reject": 0,
		"poisson_reject": 0,
		"root_reject": 0,
		"geometry_reject": 0,
		"other_reject": 0,
		"emitted": 0,
	}
	_s09_video_right_diagnostics = {
		"contract": S09_VIDEO_RIGHT_SOURCE_CONTRACT,
		"source_reference": S09_VIDEO_RIGHT_SOURCE_REFERENCE,
		"canonical_station_s_m": S09_CANONICAL_STATION_DISTANCE_M,
		"generated": 0,
		"policy_accept": 0,
		"policy_reject": 0,
		"poisson_reject": 0,
		"root_reject": 0,
		"geometry_reject": 0,
		"other_reject": 0,
		"emitted": 0,
		"records": [],
	}
	var spacing := clampf(grid_spacing_m, 10.0, 16.0)
	var search_bounds := _route_search_bounds()
	for polygon_index in _forest_polygons.size():
		var polygon: Dictionary = _forest_polygons[polygon_index]
		var outer_index := 0
		for outer in polygon["outers"]:
			var bounds := _ring_bounds(outer)
			if not bounds.intersects(search_bounds):
				outer_index += 1
				continue
			var start_x := floorf(maxf(bounds.position.x, search_bounds.position.x) / spacing) * spacing
			var end_x := ceilf(minf(bounds.end.x, search_bounds.end.x) / spacing) * spacing
			var base_start_z := floorf(maxf(bounds.position.y, search_bounds.position.y) / spacing) * spacing
			var end_z := ceilf(minf(bounds.end.y, search_bounds.end.y) / spacing) * spacing
			var ix := int(start_x / spacing)
			while start_x <= end_x and ix < int(end_x / spacing) + 2:
				var cursor_z := base_start_z
				var iz := int(cursor_z / spacing)
				while cursor_z <= end_z and iz < int(end_z / spacing) + 2:
					# Use nearly the full cell width.  The Poisson hash below removes
					# collisions, while this amplitude prevents visible grid rows.
					var jitter_x := (_hash01(polygon_index, outer_index, ix, iz) - 0.5) * minf(spacing * 0.90, 9.0)
					var jitter_z := (_hash01(polygon_index + 17, outer_index, ix, iz) - 0.5) * minf(spacing * 0.90, 9.0)
					var candidate := Vector2(start_x + jitter_x, cursor_z + jitter_z)
					var base_nearest := _nearest_route(candidate)
					var candidate_variations := _quality_candidate_variations(candidate, base_nearest)
					for variation_index in candidate_variations.size():
						var candidate_point: Vector2 = candidate_variations[variation_index]
						if not _point_in_polygon(candidate_point, outer) or not _inside_no_hole(candidate_point, polygon["holes"]):
							continue
						var nearest := base_nearest if variation_index == 0 else _nearest_route(candidate_point)
						var candidate_ix := ix * 7 + variation_index * 101
						var candidate_iz := iz * 7 + variation_index * 53
						var s09_right_local := _is_s09_right_target(nearest)
						if s09_right_local:
							_s09_right_diagnostics["seen"] = int(_s09_right_diagnostics.get("seen", 0)) + 1
						var policy := _candidate_policy(candidate_point, nearest, polygon_index, outer_index, candidate_ix, candidate_iz)
						if policy.is_empty():
							if s09_right_local:
								_s09_right_diagnostics["policy_reject"] = int(_s09_right_diagnostics.get("policy_reject", 0)) + 1
							continue
						if s09_right_local:
							_s09_right_diagnostics["policy_accept"] = int(_s09_right_diagnostics.get("policy_accept", 0)) + 1
						if not _can_place(candidate_point, float(policy["separation_m"])):
							if s09_right_local:
								_s09_right_diagnostics["poisson_reject"] = int(_s09_right_diagnostics.get("poisson_reject", 0)) + 1
							continue
						var root_reject_before := _root_steep_skipped
						var geometry_reject_before := geometry_errors
						if _add_tree_item(candidate_point, polygon, polygon_index, candidate_ix, candidate_iz, nearest, policy):
							_occupy_candidate(candidate_point)
							var candidate_offset := candidate_point - candidate
							_scatter_jitter_values.append(Vector2(jitter_x, jitter_z) + candidate_offset)
							if s09_right_local:
								_s09_right_diagnostics["emitted"] = int(_s09_right_diagnostics.get("emitted", 0)) + 1
						else:
							if s09_right_local:
								if _root_steep_skipped > root_reject_before:
									_s09_right_diagnostics["root_reject"] = int(_s09_right_diagnostics.get("root_reject", 0)) + 1
								elif geometry_errors > geometry_reject_before:
									_s09_right_diagnostics["geometry_reject"] = int(_s09_right_diagnostics.get("geometry_reject", 0)) + 1
								else:
									_s09_right_diagnostics["other_reject"] = int(_s09_right_diagnostics.get("other_reject", 0)) + 1
					iz += 1
					cursor_z += spacing
				ix += 1
				start_x += spacing
			outer_index += 1
	_scatter_s09_video_right_candidates()
	_limit_tree_items()

func _scatter_s09_video_right_candidates() -> void:
	if route == null or not route.has_method("pos_at") or not route.has_method("left_at"):
		return
	var start_s := _quality_station_distance(S09_RIGHT_START_VIDEO_SECONDS)
	var end_s := _quality_station_distance(S09_RIGHT_END_VIDEO_SECONDS)
	if not is_finite(start_s) or not is_finite(end_s) or end_s <= start_s:
		return
	var s_step := (end_s - start_s) / float(S09_VIDEO_RIGHT_SAMPLES)
	var u_step := (S09_VIDEO_RIGHT_MAX_U_M - S09_VIDEO_RIGHT_MIN_U_M) / float(S09_VIDEO_RIGHT_U_LAYERS)
	var video_polygon := {
		"id": "video:S09_RIGHT_BAND_328_336",
		"leaf_type": "broadleaf",
	}
	for s_index in S09_VIDEO_RIGHT_SAMPLES:
		for u_index in S09_VIDEO_RIGHT_U_LAYERS:
			var s_seed := s_index * 31 + u_index * 17 + 1901
			var u_seed := s_index * 47 + u_index * 13 + 2903
			var s_jitter := (_hash01(s_seed, u_seed, 1, random_seed) - 0.5) * minf(s_step * 0.55, 7.0)
			var u_jitter := (_hash01(s_seed, u_seed, 2, random_seed) - 0.5) * minf(absf(u_step) * 0.55, 3.0)
			var candidate_s := clampf(start_s + (float(s_index) + 0.5) * s_step + s_jitter, start_s + 0.25, end_s - 0.25)
			var candidate_u := clampf(S09_VIDEO_RIGHT_MIN_U_M + (float(u_index) + 0.5) * u_step + u_jitter, S09_VIDEO_RIGHT_MIN_U_M, S09_VIDEO_RIGHT_MAX_U_M)
			var route_point: Vector3 = route.pos_at(candidate_s) + route.left_at(candidate_s) * candidate_u
			var candidate := Vector2(route_point.x, route_point.z)
			var nearest := _nearest_route(candidate)
			var record := {
				"status": "generated",
				"s_seed": candidate_s,
				"u_seed": candidate_u,
				"s": float(nearest.get("s", candidate_s)),
				"u": float(nearest.get("u", candidate_u)),
				"candidate_xz": [candidate.x, candidate.y],
				"source_contract": S09_VIDEO_RIGHT_SOURCE_CONTRACT,
				"source_reference": S09_VIDEO_RIGHT_SOURCE_REFERENCE,
			}
			_s09_video_right_diagnostics["generated"] = int(_s09_video_right_diagnostics.get("generated", 0)) + 1
			var policy := _video_s09_right_policy(candidate, nearest, s_index, u_index)
			if policy.has("_rejected"):
				record["status"] = String(policy["_rejected"])
				_s09_video_right_diagnostics["policy_reject"] = int(_s09_video_right_diagnostics.get("policy_reject", 0)) + 1
				_append_s09_video_diagnostic(record)
				continue
			_s09_video_right_diagnostics["policy_accept"] = int(_s09_video_right_diagnostics.get("policy_accept", 0)) + 1
			policy["_diagnostic"] = record
			if not _can_place(candidate, float(policy["separation_m"])):
				record["status"] = "poisson_reject"
				_s09_video_right_diagnostics["poisson_reject"] = int(_s09_video_right_diagnostics.get("poisson_reject", 0)) + 1
				_append_s09_video_diagnostic(record)
				continue
			var root_reject_before := _root_steep_skipped
			var geometry_reject_before := geometry_errors
			if _add_tree_item(candidate, video_polygon, -1, s_index, u_index, nearest, policy):
				_occupy_candidate(candidate)
				_scatter_jitter_values.append(Vector2(s_jitter, u_jitter))
				_s09_video_right_diagnostics["emitted"] = int(_s09_video_right_diagnostics.get("emitted", 0)) + 1
			else:
				if _root_steep_skipped > root_reject_before:
					record["status"] = "root_reject"
					_s09_video_right_diagnostics["root_reject"] = int(_s09_video_right_diagnostics.get("root_reject", 0)) + 1
				elif geometry_errors > geometry_reject_before:
					record["status"] = "geometry_reject"
					_s09_video_right_diagnostics["geometry_reject"] = int(_s09_video_right_diagnostics.get("geometry_reject", 0)) + 1
				else:
					record["status"] = "other_reject"
					_s09_video_right_diagnostics["other_reject"] = int(_s09_video_right_diagnostics.get("other_reject", 0)) + 1
			_append_s09_video_diagnostic(record)

func _video_s09_right_policy(candidate: Vector2, nearest: Dictionary, s_index: int, u_index: int) -> Dictionary:
	if nearest.is_empty():
		return {"_rejected": "no_route"}
	var s := float(nearest.get("s", NAN))
	var u := float(nearest.get("u", NAN))
	var distance := float(nearest.get("distance_m", INF))
	var start_s := _quality_station_distance(S09_RIGHT_START_VIDEO_SECONDS)
	var end_s := _quality_station_distance(S09_RIGHT_END_VIDEO_SECONDS)
	if not is_finite(s) or not is_finite(u) or not is_finite(distance):
		return {"_rejected": "nonfinite_route_projection"}
	if s < start_s or s > end_s or u < S09_VIDEO_RIGHT_MIN_U_M or u > S09_VIDEO_RIGHT_MAX_U_M:
		return {"_rejected": "outside_video_band"}
	var road_clearance := _road_trunk_clearance(s)
	if distance < road_clearance or distance > S09_RIGHT_MAX_ROAD_DISTANCE_M:
		return {"_rejected": "road_band"}
	for building in _building_polygons:
		var bounds := _ring_bounds(building).grow(building_clearance_m)
		if not bounds.has_point(candidate):
			continue
		if _point_in_polygon(candidate, building) or _distance_to_ring(candidate, building) < building_clearance_m:
			return {"_rejected": "building_clearance"}
	return {
		"near": distance <= near_road_range_m,
		"quality_station": "S09_VIDEO_RIGHT",
		"separation_m": minf(maxf(poisson_min_separation_m * 0.75, 5.5), 6.5),
		"mask_id": "S09_VIDEO_RIGHT_SOURCE_BAND",
		"s09_right_local": true,
		"video_exception": true,
		"source_contract": S09_VIDEO_RIGHT_SOURCE_CONTRACT,
		"source_reference": S09_VIDEO_RIGHT_SOURCE_REFERENCE,
		"s09_video_index": s_index * S09_VIDEO_RIGHT_U_LAYERS + u_index,
	}

func _append_s09_video_diagnostic(record: Dictionary) -> void:
	var records: Array = _s09_video_right_diagnostics.get("records", [])
	records.append(record.duplicate(true))
	_s09_video_right_diagnostics["records"] = records

func _quality_candidate_variations(candidate: Vector2, nearest: Dictionary) -> Array:
	var variations: Array = [candidate]
	if nearest.is_empty() or route == null or not route.has_method("tangent_at") or not route.has_method("left_at"):
		return variations
	var s := float(nearest.get("s", NAN))
	var s09_right_local := _is_s09_right_target(nearest)
	var center_s := _quality_station_distance(315.0)
	var s08_local := is_finite(s) and absf(s - center_s) <= 210.0 and float(nearest.get("distance_m", INF)) <= 150.0
	if not s09_right_local and not s08_local:
		return variations
	# S08's source canopy is pressed to the road.  Add a bounded local
	# sub-grid around existing forest candidates so the root-footprint rejection
	# does not leave a sparse gap; all points still pass OSM, road, building,
	# Poisson, and terrain checks below.
	var tangent := route.tangent_at(s)
	var left := route.left_at(s)
	var tangent_xz := Vector2(tangent.x, tangent.z).normalized()
	var left_xz := Vector2(left.x, left.z).normalized()
	if tangent_xz.length_squared() <= 0.000001 or left_xz.length_squared() <= 0.000001:
		return variations
	if s08_local:
		var local_step := 7.0
		variations.append(candidate + tangent_xz * local_step)
		variations.append(candidate - tangent_xz * local_step)
		variations.append(candidate + left_xz * local_step)
		variations.append(candidate - left_xz * local_step)
	if s09_right_local:
		# The right guardrail is backed by layered woodland.  Use a small radial
		# fan around real forest candidates, rather than a second world grid; every
		# point still goes through the polygon, road, building, Poisson, and root
		# checks below.  The varying phase avoids visible rows along the bend.
		var phase := _hash01(floori(candidate.x * 0.1), floori(candidate.y * 0.1), 7701, random_seed) * TAU
		for offset_index in S09_RIGHT_VARIATION_COUNT:
			var angle := phase + float(offset_index) * TAU / float(S09_RIGHT_VARIATION_COUNT)
			var offset := tangent_xz * cos(angle) * S09_RIGHT_VARIATION_RADIUS_M + left_xz * sin(angle) * S09_RIGHT_VARIATION_RADIUS_M
			variations.append(candidate + offset)
	return variations

func _limit_tree_items() -> void:
	var all_items: Array = []
	for key in _tree_items.keys():
		for item in _tree_items[key]:
			all_items.append(item)
	_tree_candidate_count = all_items.size()
	for item in all_items:
		if String(item.get("tier", "far")) == "near":
			_tree_candidate_near_count += 1
		else:
			_tree_candidate_far_count += 1
	if max_tree_instances <= 0 or all_items.size() <= max_tree_instances:
		_recount_tree_population(all_items)
		return
	var required: Array = []
	var remainder: Array = []
	for item in all_items:
		if not String(item.get("quality_station", "")).is_empty():
			required.append(item)
		else:
			remainder.append(item)
	var limit := mini(max_tree_instances, all_items.size())
	if required.size() > limit:
		required.sort_custom(Callable(self, "_sort_tree_items_by_s"))
		required = _spread_items(required, limit)
		limit = required.size()
	var remaining_budget := maxi(limit - required.size(), 0)
	remainder.sort_custom(Callable(self, "_sort_tree_items_by_s"))
	var selected: Array = required.duplicate()
	if remaining_budget > 0:
		selected.append_array(_spread_items(remainder, remaining_budget))
	var limited: Dictionary = {}
	for item in selected:
		var key := String(item.get("key", ""))
		if not limited.has(key):
			limited[key] = []
		limited[key].append(item)
	_tree_items = limited
	_recount_tree_population(selected)

func _spread_items(items: Array, budget: int) -> Array:
	if budget <= 0 or items.is_empty():
		return []
	if items.size() <= budget:
		return items.duplicate()
	var result: Array = []
	for index in range(budget):
		var source_index := int(floor(float(index) * float(items.size() - 1) / float(maxi(budget - 1, 1))))
		result.append(items[source_index])
	return result

func _recount_tree_population(items: Array) -> void:
	_tree_near_count = 0
	_tree_far_count = 0
	_tree_quality_counts.clear()
	for item in items:
		if String(item.get("tier", "far")) == "near":
			_tree_near_count += 1
		else:
			_tree_far_count += 1
		var station_id := String(item.get("quality_station", ""))
		if not station_id.is_empty():
			_tree_quality_counts[station_id] = int(_tree_quality_counts.get(station_id, 0)) + 1

func _sort_tree_items_by_s(a: Dictionary, b: Dictionary) -> bool:
	return float(a.get("s", INF)) < float(b.get("s", INF))

func _add_tree_item(candidate: Vector2, polygon: Dictionary, polygon_index: int, ix: int, iz: int, nearest: Dictionary, policy: Dictionary) -> bool:
	var diagnostic: Dictionary = policy.get("_diagnostic", {}) if policy.get("_diagnostic", {}) is Dictionary else {}
	var leaf_type := String(polygon.get("leaf_type", "unknown")).to_lower()
	var conifer_probability := 0.50
	if leaf_type.contains("broad"):
		conifer_probability = 0.18
	elif leaf_type.contains("needle"):
		conifer_probability = 0.82
	elif leaf_type.contains("mixed"):
		conifer_probability = 0.46
	if bool(policy.get("near", false)):
		conifer_probability = lerpf(conifer_probability, 0.28, 0.35)
	if not String(policy.get("quality_station", "")).is_empty():
		# The acceptance frames show broadleaf canopy pressed to both S08/S13
		# road edges.  Root fitting rejects more wide-root broadleaf candidates on
		# steep samples than narrow conifers, so keep the local evidence slice
		# broadleaf-heavy before that geometry filter rather than letting it drift
		# conifer-heavy after filtering.
		conifer_probability = minf(conifer_probability, 0.04)
	var s09_right_local := bool(policy.get("s09_right_local", false))
	if s09_right_local:
		# Keep this bounded right-side evidence slice broadleaf-only.  Smaller
		# scales let the existing indexed root points fit the local slope without
		# loosening the terrain contact contract.
		conifer_probability = 0.0
	var random_value := _hash01(polygon_index + 101, ix, iz, random_seed)
	var is_conifer := not s09_right_local and random_value < conifer_probability
	var variants: Array = _conifer if is_conifer else _broadleaf
	var variant := int(floor(_hash01(polygon_index + 211, ix, iz, random_seed) * float(variants.size())))
	variant = clampi(variant, 0, variants.size() - 1)
	var family := "conifer" if is_conifer else "broadleaf"
	var key := "%s_%02d" % [family, variant]
	var height := _ground_height(candidate)
	if not diagnostic.is_empty():
		diagnostic["candidate_ground"] = height
	if not is_finite(float(height)):
		if not diagnostic.is_empty():
			diagnostic["status"] = "geometry_reject"
		geometry_errors += 1
		return false
	var scale_min := 0.70
	var scale_max := 1.18
	if bool(policy.get("near", false)):
		scale_min = 0.76
		scale_max = 1.34
	if not String(policy.get("quality_station", "")).is_empty():
		scale_min = 0.72
		scale_max = 1.48
	if s09_right_local:
		scale_min = 0.44
		scale_max = 0.76
	var scale := lerpf(scale_min, scale_max, _hash01(polygon_index + 307, ix, iz, random_seed))
	if is_conifer:
		scale *= lerpf(0.94, 1.12, _hash01(polygon_index + 401, ix, iz, random_seed))
	var crown_width := lerpf(0.96, 1.24, _hash01(polygon_index + 607, ix, iz, random_seed))
	var crown_height := lerpf(0.92, 1.16, _hash01(polygon_index + 701, ix, iz, random_seed))
	var scale_vector := Vector3(scale * crown_width, scale * crown_height, scale * crown_width)
	var source_mesh := variants[variant] as Mesh
	var source_bounds := source_mesh.get_aabb() if source_mesh != null else AABB(Vector3.ZERO, Vector3.ONE)
	var canopy_radius := maxf(maxf(source_bounds.size.x, source_bounds.size.z) * scale * crown_width * 0.5, 1.5)
	var yaw := _hash01(polygon_index + 509, ix, iz, random_seed) * TAU
	var root_fit := _fit_root_footprint(candidate, height, source_mesh, scale_vector, yaw, bool(policy.get("near", false)))
	if not diagnostic.is_empty():
		diagnostic["root_fit"] = root_fit.duplicate(true)
	if root_fit.is_empty() or not bool(root_fit.get("valid", false)):
		if not diagnostic.is_empty():
			diagnostic["status"] = "root_reject"
		_root_steep_skipped += 1
		skipped_candidates += 1
		return false
	if bool(root_fit.get("full_footprint", false)):
		_root_full_fit_count += 1
	else:
		_root_far_fit_count += 1
	if not _tree_items.has(key):
		_tree_items[key] = []
	_tree_items[key].append({
		"key": key,
		"position": Vector3(candidate.x, float(root_fit["position_y"]), candidate.y),
		"candidate_position": Vector3(candidate.x, float(height), candidate.y),
		"scale": scale,
		"scale_vector": scale_vector,
		"canopy_radius": canopy_radius,
		"yaw": yaw,
		"s": nearest["s"],
		"road_distance": nearest["distance_m"],
		"u": float(nearest.get("u", 0.0)),
		"tier": "near" if bool(policy.get("near", false)) else "far",
		"quality_station": String(policy.get("quality_station", "")),
		"family": family,
		"root_height": float(height),
		"root_y_offset": float(root_fit["position_y"]) - float(height),
		"root_burial_min": float(root_fit["burial_min"]),
		"root_burial_max": float(root_fit["burial_max"]),
		"root_contact_count": int(root_fit["contact_count"]),
		"root_full_footprint": bool(root_fit["full_footprint"]),
		"mask_id": String(policy.get("mask_id", "")),
		"polygon_id": String(polygon.get("id", "unknown")),
		"video_exception": bool(policy.get("video_exception", false)),
		"source_contract": String(policy.get("source_contract", "OSM_FOREST_POLYGON")),
		"source_reference": String(policy.get("source_reference", "")),
	})
	if not diagnostic.is_empty():
		diagnostic["status"] = "emitted"
		diagnostic["position"] = [candidate.x, float(root_fit["position_y"]), candidate.y]
		diagnostic["root_burial_min"] = float(root_fit["burial_min"])
		diagnostic["root_burial_max"] = float(root_fit["burial_max"])
	return true

func _fit_root_footprint(candidate: Vector2, candidate_ground: float, mesh: Mesh, scale_vector: Vector3, yaw: float, full_footprint: bool) -> Dictionary:
	if mesh == null or not is_finite(candidate_ground):
		return {}
	var local_points: PackedVector3Array = _root_footprints.get(mesh.get_instance_id(), PackedVector3Array())
	if local_points.is_empty():
		return {}
	var basis := Basis(Vector3.UP, yaw).scaled(scale_vector)
	var transformed_points: Array = []
	for local_point in local_points:
		var offset: Vector3 = basis * local_point
		if not _finite_vector(offset):
			continue
		transformed_points.append(offset)
	if transformed_points.is_empty():
		return {}
	# Cache one actual terrain sample per transformed indexed point.  Near trees
	# use the complete contact set; far trees keep the same conservative set but
	# avoid the stricter spread check, so no repeated triangle queries are needed.
	var samples: Array = []
	var required_y := candidate_ground - ROOT_BURY_MARGIN_M
	for offset in transformed_points:
		var point_offset: Vector3 = offset
		var point_ground := _ground_height(candidate + Vector2(point_offset.x, point_offset.z))
		if not is_finite(point_ground):
			return {}
		samples.append({"offset": point_offset, "ground": point_ground})
		required_y = minf(required_y, point_ground - point_offset.y - ROOT_BURY_MARGIN_M)
	var position_y := required_y
	var burial_min := INF
	var burial_max := -INF
	for sample in samples:
		var point_offset: Vector3 = sample["offset"]
		var burial := float(sample["ground"]) - (position_y + point_offset.y)
		burial_min = minf(burial_min, burial)
		burial_max = maxf(burial_max, burial)
	var allowed_max := ROOT_MAX_BURIAL_M if full_footprint else ROOT_FAR_MAX_BURIAL_M
	if burial_min < ROOT_BURY_MARGIN_M - 0.01 or burial_max > allowed_max or (full_footprint and burial_max - burial_min > ROOT_MAX_BURIAL_M):
		return {
			"valid": false,
			"position_y": position_y,
			"burial_min": burial_min,
			"burial_max": burial_max,
			"contact_count": transformed_points.size(),
			"full_footprint": full_footprint,
		}
	return {
		"valid": true,
		"position_y": position_y,
		"burial_min": burial_min,
		"burial_max": burial_max,
		"contact_count": transformed_points.size(),
		"full_footprint": full_footprint,
	}

func _candidate_policy(candidate: Vector2, nearest: Dictionary, polygon_index: int, outer_index: int, ix: int, iz: int) -> Dictionary:
	if nearest.is_empty() or float(nearest["s"]) > _effective_route_end_m() + 0.01:
		return {}
	var distance := float(nearest["distance_m"])
	var road_clearance := _road_trunk_clearance(float(nearest["s"]))
	if distance < road_clearance or distance > max_road_distance_m + 0.01:
		return {}
	for building in _building_polygons:
		var bounds := _ring_bounds(building).grow(building_clearance_m)
		if not bounds.has_point(candidate):
			continue
		if _point_in_polygon(candidate, building) or _distance_to_ring(candidate, building) < building_clearance_m:
			return {}
	var local_mask := _local_mask(nearest, polygon_index, outer_index, ix, iz)
	if local_mask.is_empty():
		return {}
	var station_id := _quality_station_id(float(nearest["s"]))
	var s09_right_local := _is_s09_right_target(nearest)
	var is_near := distance <= near_road_range_m
	var density := near_density_probability if is_near else far_density_probability
	if not station_id.is_empty():
		density = minf(1.0, density * quality_density_multiplier)
	if s09_right_local:
		# The bounded right-side interval is an evidence-backed local fill.  It
		# still uses forest/road/building/Poisson/root checks, but does not lose
		# valid candidates to the route-wide density lottery.
		density = 1.0
	var acceptance_hash := _hash01(polygon_index + 601, outer_index + 17, ix, iz + random_seed)
	if acceptance_hash > clampf(density, 0.0, 1.0):
		return {}
	var separation := maxf(poisson_min_separation_m, 6.5) if is_near else maxf(poisson_min_separation_m * 1.9, 14.0)
	if not station_id.is_empty() and is_near:
		# S08/S13 are bounded evidence slices where the source canopy reaches
		# the roadside.  A modest local Poisson reduction restores overlap after
		# terrain-fit rejects, without changing the route-wide woodland spacing.
		separation *= 0.70
	if s09_right_local:
		# A local overlap allowance creates a layered roadside woodland while
		# retaining a real Poisson floor and all road/building/root constraints.
		separation = minf(separation, maxf(poisson_min_separation_m * 0.75, 5.5))
	return {
		"near": is_near,
		"quality_station": station_id,
		"separation_m": separation,
		"mask_id": String(local_mask.get("id", "")),
		"s09_right_local": s09_right_local,
	}

func _is_s09_right_target(nearest: Dictionary) -> bool:
	if nearest.is_empty():
		return false
	var s := float(nearest.get("s", NAN))
	var u := float(nearest.get("u", NAN))
	var distance := float(nearest.get("distance_m", INF))
	if not is_finite(s) or not is_finite(u) or not is_finite(distance):
		return false
	var s09_start := _quality_station_distance(S09_RIGHT_START_VIDEO_SECONDS)
	var s09_end := _quality_station_distance(S09_RIGHT_END_VIDEO_SECONDS)
	return s >= s09_start and s <= s09_end and u < -_road_trunk_clearance(s) and distance <= S09_RIGHT_MAX_ROAD_DISTANCE_M

func _local_mask(nearest: Dictionary, polygon_index: int, outer_index: int, ix: int, iz: int) -> Dictionary:
	var s := float(nearest.get("s", NAN))
	var u := float(nearest.get("u", 0.0))
	var distance := float(nearest.get("distance_m", INF))
	if not is_finite(s) or not is_finite(u) or not is_finite(distance):
		return {}
	var keep_probability := 1.0
	var mask_id := ""
	var s09_start := _quality_station_distance(S09_MASK_START_VIDEO_SECONDS)
	var s09_end := _quality_station_distance(S09_MASK_END_VIDEO_SECONDS)
	if u > 0.0 and u <= S09_MASK_MAX_LATERAL_M and distance <= S09_MASK_MAX_LATERAL_M and s >= s09_start - S09_MASK_LONGITUDINAL_FADE_M and s <= s09_end + S09_MASK_LONGITUDINAL_FADE_M:
		var start_fade := _smooth01(clampf((s - s09_start) / S09_MASK_LONGITUDINAL_FADE_M, 0.0, 1.0))
		var end_fade := _smooth01(clampf((s09_end - s) / S09_MASK_LONGITUDINAL_FADE_M, 0.0, 1.0))
		var time_remove := minf(start_fade, end_fade)
		var side_remove := 1.0 - _smooth01(clampf((u - (S09_MASK_MAX_LATERAL_M - S09_MASK_LATERAL_FADE_M)) / S09_MASK_LATERAL_FADE_M, 0.0, 1.0))
		var remove_strength := clampf(time_remove * side_remove, 0.0, 1.0)
		if remove_strength > 0.0:
			mask_id = "S09_LEFT_OPEN_GRASS"
			keep_probability = 1.0 - remove_strength
	var s13_start := _quality_station_distance(S13_CLIFF_START_VIDEO_SECONDS)
	var s13_end := _quality_station_distance(S13_CLIFF_END_VIDEO_SECONDS)
	var s13_road_half := _road_trunk_clearance(s) - clampf(road_clearance_m, 2.0, 3.0)
	if u >= s13_road_half + 0.45 and u <= S13_CLIFF_MAX_LATERAL_M and s >= s13_start - S13_CLIFF_LONGITUDINAL_FADE_M and s <= s13_end + S13_CLIFF_LONGITUDINAL_FADE_M:
		var start_fade := _smooth01(clampf((s - s13_start) / S13_CLIFF_LONGITUDINAL_FADE_M, 0.0, 1.0))
		var end_fade := _smooth01(clampf((s13_end - s) / S13_CLIFF_LONGITUDINAL_FADE_M, 0.0, 1.0))
		var time_remove := minf(start_fade, end_fade)
		var side_remove := 1.0 - _smooth01(clampf((u - (S13_CLIFF_MAX_LATERAL_M - S13_CLIFF_LATERAL_FADE_M)) / S13_CLIFF_LATERAL_FADE_M, 0.0, 1.0))
		var remove_strength := clampf(time_remove * side_remove, 0.0, 1.0)
		if remove_strength > 0.0:
			mask_id = "S13_LEFT_CLIFF"
			keep_probability = minf(keep_probability, 1.0 - remove_strength)
	if keep_probability <= 0.0:
		if mask_id == "S09_LEFT_OPEN_GRASS":
			_s09_mask_removed += 1
		elif mask_id == "S13_LEFT_CLIFF":
			_s13_cliff_removed += 1
		return {}
	var acceptance_hash := _hash01(polygon_index + 991, outer_index + 43, ix, iz + random_seed)
	if acceptance_hash > keep_probability:
		if mask_id == "S09_LEFT_OPEN_GRASS":
			_s09_mask_removed += 1
		elif mask_id == "S13_LEFT_CLIFF":
			_s13_cliff_removed += 1
		return {}
	return {"id": mask_id, "keep_probability": keep_probability}

func _smooth01(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func _road_trunk_clearance(s: float) -> float:
	var asphalt_half := 3.2
	if route != null and route.has_method("road_width_at"):
		asphalt_half = float(route.call("road_width_at", s)) * 0.5
	return asphalt_half + clampf(road_clearance_m, 2.0, 3.0)

func _quality_station_id(s: float) -> String:
	for station in QUALITY_STATIONS:
		var center_s := _quality_station_distance(float(station.get("video_seconds", 0.0)))
		if absf(s - center_s) <= QUALITY_STATION_PADDING_M:
			return String(station.get("id", ""))
	return ""

func _quality_station_distance(video_seconds: float) -> float:
	if route != null and route.has_method("distance_for_video_seconds"):
		return float(route.call("distance_for_video_seconds", video_seconds))
	return lerpf(0.0, _effective_route_end_m(), video_seconds / 920.0)

func _can_place(candidate: Vector2, separation: float) -> bool:
	var cell := Vector2i(floori(candidate.x / POISSON_HASH_CELL_M), floori(candidate.y / POISSON_HASH_CELL_M))
	var radius_cells := maxi(1, ceili(separation / POISSON_HASH_CELL_M))
	for dx in range(-radius_cells, radius_cells + 1):
		for dz in range(-radius_cells, radius_cells + 1):
			var bucket: Array = _occupied_cells.get(Vector2i(cell.x + dx, cell.y + dz), [])
			for existing in bucket:
				if candidate.distance_to(existing as Vector2) < separation:
					return false
	return true

func _occupy_candidate(candidate: Vector2) -> void:
	var cell := Vector2i(floori(candidate.x / POISSON_HASH_CELL_M), floori(candidate.y / POISSON_HASH_CELL_M))
	var bucket: Array = _occupied_cells.get(cell, [])
	bucket.append(candidate)
	_occupied_cells[cell] = bucket

func _nearest_route(candidate: Vector2) -> Dictionary:
	var best_s := INF
	var best_distance := INF
	var best_nearest := Vector2.ZERO
	var center_cell := Vector2i(floori(candidate.x / ROUTE_HASH_CELL_M), floori(candidate.y / ROUTE_HASH_CELL_M))
	var search_cells := maxi(1, ceili((max_road_distance_m + ROUTE_HASH_CELL_M) / ROUTE_HASH_CELL_M))
	var candidate_indices: Array = []
	if _route_candidate_cache.has(center_cell):
		candidate_indices = _route_candidate_cache[center_cell] as Array
	else:
		var candidates: Dictionary = {}
		for dx in range(-search_cells, search_cells + 1):
			for dz in range(-search_cells, search_cells + 1):
				var bucket: Array = _route_segment_spatial_hash.get(Vector2i(center_cell.x + dx, center_cell.y + dz), [])
				for segment_index in bucket:
					candidates[int(segment_index)] = true
		candidate_indices = candidates.keys()
		_route_candidate_cache[center_cell] = candidate_indices
	for raw_index in candidate_indices:
		var index := int(raw_index)
		var first: Dictionary = _route_samples[index]
		var second: Dictionary = _route_samples[index + 1]
		var a: Vector2 = first["xz"]
		var b: Vector2 = second["xz"]
		var ab := b - a
		var t := clampf((candidate - a).dot(ab) / maxf(ab.length_squared(), 0.000001), 0.0, 1.0)
		var nearest := a.lerp(b, t)
		var distance := candidate.distance_to(nearest)
		if distance < best_distance:
			best_distance = distance
			best_s = lerpf(float(first["s"]), float(second["s"]), t)
			best_nearest = nearest
	if not is_finite(best_s):
		return {}
	var left: Vector3 = route.left_at(best_s) if route != null and route.has_method("left_at") else Vector3(0.0, 0.0, 1.0)
	var left_xz := Vector2(left.x, left.z).normalized()
	var lateral := (candidate - best_nearest).dot(left_xz) if left_xz.length_squared() > 0.000001 else 0.0
	return {"s": best_s, "distance_m": best_distance, "u": lateral, "nearest_xz": best_nearest}

func _inside_no_hole(candidate: Vector2, holes: Array) -> bool:
	for hole in holes:
		if _point_in_polygon(candidate, hole):
			return false
	return true

func _point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	if polygon.size() < 4:
		return false
	var inside := false
	var j := polygon.size() - 1
	for i in polygon.size():
		var a := polygon[i]
		var b := polygon[j]
		var delta_y := b.y - a.y
		if absf(delta_y) > 0.000001 and ((a.y > point.y) != (b.y > point.y)) and point.x < (b.x - a.x) * (point.y - a.y) / delta_y + a.x:
			inside = not inside
		j = i
	return inside

func _distance_to_ring(point: Vector2, ring: PackedVector2Array) -> float:
	var best := INF
	for i in range(ring.size() - 1):
		var a := ring[i]
		var b := ring[i + 1]
		var ab := b - a
		var t := clampf((point - a).dot(ab) / maxf(ab.length_squared(), 0.000001), 0.0, 1.0)
		best = minf(best, point.distance_to(a + ab * t))
	return best

func _hash01(a: int, b: int, c: int, d: int = 0) -> float:
	var value := hash("%d:%d:%d:%d" % [a, b, c, d]) & 0x7fffffff
	return float(value) / 2147483647.0

func _spawn_tree_chunks() -> void:
	_chunk_count = 0
	for key in _tree_items.keys():
		var family_key := String(key)
		var parts := family_key.split("_")
		if parts.size() != 2:
			continue
		var family := parts[0]
		var variant := clampi(int(parts[1]), 0, (_conifer.size() if family == "conifer" else _broadleaf.size()) - 1)
		var mesh: Mesh = (_conifer[variant] if family == "conifer" else _broadleaf[variant]) as Mesh
		if mesh == null:
			geometry_errors += 1
			continue
		var chunks: Dictionary = {}
		for item in _tree_items[key]:
			var position: Vector3 = item["position"]
			var cx := floori(position.x / chunk_size_m)
			var cz := floori(position.z / chunk_size_m)
			var chunk_key := Vector2i(cx, cz)
			if not chunks.has(chunk_key):
				chunks[chunk_key] = []
			chunks[chunk_key].append(item)
		for chunk_key in chunks.keys():
			var origin := Vector3((float(chunk_key.x) + 0.5) * chunk_size_m, 0.0, (float(chunk_key.y) + 0.5) * chunk_size_m)
			var items: Array = chunks[chunk_key]
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.mesh = mesh
			multimesh.instance_count = items.size()
			var authored_positions := PackedVector3Array()
			var authored_s := PackedFloat32Array()
			var authored_scales := PackedVector3Array()
			var authored_canopy_radii := PackedFloat32Array()
			var authored_near_flags := PackedByteArray()
			var authored_candidate_positions := PackedVector3Array()
			var authored_root_y_offsets := PackedFloat32Array()
			var authored_root_burial_min := PackedFloat32Array()
			var authored_root_burial_max := PackedFloat32Array()
			var authored_root_contact_counts := PackedByteArray()
			var authored_root_full_flags := PackedByteArray()
			var authored_quality_stations: Array[String] = []
			var authored_source_contracts: Array[String] = []
			var authored_source_references: Array[String] = []
			var authored_video_exception_flags := PackedByteArray()
			var authored_local_transforms: Array = []
			for index in multimesh.instance_count:
				var item: Dictionary = items[index]
				authored_positions.append(item["position"])
				authored_s.append(float(item["s"]))
				var scale_vector: Vector3 = item.get("scale_vector", Vector3.ONE * float(item.get("scale", 1.0)))
				authored_scales.append(scale_vector)
				authored_canopy_radii.append(float(item.get("canopy_radius", 1.5)))
				authored_near_flags.append(1 if String(item.get("tier", "far")) == "near" else 0)
				authored_candidate_positions.append(item.get("candidate_position", item["position"]))
				authored_root_y_offsets.append(float(item.get("root_y_offset", 0.0)))
				authored_root_burial_min.append(float(item.get("root_burial_min", 0.0)))
				authored_root_burial_max.append(float(item.get("root_burial_max", 0.0)))
				authored_root_contact_counts.append(clampi(int(item.get("root_contact_count", 0)), 0, 255))
				authored_root_full_flags.append(1 if bool(item.get("root_full_footprint", false)) else 0)
				authored_quality_stations.append(String(item.get("quality_station", "")))
				authored_source_contracts.append(String(item.get("source_contract", "OSM_FOREST_POLYGON")))
				authored_source_references.append(String(item.get("source_reference", "")))
				authored_video_exception_flags.append(1 if bool(item.get("video_exception", false)) else 0)
				var basis := Basis(Vector3.UP, float(item["yaw"])).scaled(scale_vector)
				var local_transform := Transform3D(basis, item["position"] - origin)
				authored_local_transforms.append(local_transform)
				multimesh.set_instance_transform(index, local_transform)
			var instance := MultiMeshInstance3D.new()
			instance.name = "SaisiesGeoForest_%s_%d_%d" % [family_key, chunk_key.x, chunk_key.y]
			instance.multimesh = multimesh
			instance.position = origin
			instance.visibility_range_end = visibility_range_m
			instance.set_meta("forest_species", family_key)
			instance.set_meta("forest_chunk_size_m", chunk_size_m)
			instance.set_meta("forest_instance_count", items.size())
			instance.set_meta("forest_authored_positions", authored_positions)
			instance.set_meta("forest_authored_s", authored_s)
			instance.set_meta("forest_authored_scales", authored_scales)
			instance.set_meta("forest_authored_canopy_radii", authored_canopy_radii)
			instance.set_meta("forest_authored_near_flags", authored_near_flags)
			instance.set_meta("forest_authored_candidate_positions", authored_candidate_positions)
			instance.set_meta("forest_authored_root_y_offsets", authored_root_y_offsets)
			instance.set_meta("forest_authored_root_burial_min", authored_root_burial_min)
			instance.set_meta("forest_authored_root_burial_max", authored_root_burial_max)
			instance.set_meta("forest_authored_root_contact_counts", authored_root_contact_counts)
			instance.set_meta("forest_authored_root_full_flags", authored_root_full_flags)
			instance.set_meta("forest_authored_source_contracts", authored_source_contracts)
			instance.set_meta("forest_authored_source_references", authored_source_references)
			instance.set_meta("forest_authored_video_exception_flags", authored_video_exception_flags)
			instance.set_meta("forest_root_position_contract", "world origin includes terrain-fitted y offset; low-Y indexed root footprint points are the contact authority")
			instance.set_meta("forest_authored_quality_stations", authored_quality_stations)
			instance.set_meta("forest_authored_local_transforms", authored_local_transforms)
			add_child(instance)
			_chunk_count += 1

func _tree_instance_count() -> int:
	var count := 0
	for items in _tree_items.values():
		count += items.size()
	return count

func _lod_budget_summary() -> Dictionary:
	var summary := {}
	for mesh in _broadleaf + _conifer:
		if mesh == null:
			continue
		var budget = mesh.get_meta("saisies_triangle_budget", {})
		if budget is Dictionary:
			summary[str(mesh.get_instance_id())] = budget.duplicate(true)
	return summary

func _tree_mesh_bounds_summary() -> Dictionary:
	var summary := {}
	for family in ["broadleaf", "conifer"]:
		var variants: Array = _broadleaf if family == "broadleaf" else _conifer
		for index in variants.size():
			var mesh := variants[index] as Mesh
			if mesh == null:
				continue
			var bounds := mesh.get_aabb()
			var budget = mesh.get_meta("saisies_triangle_budget", {})
			summary["%s_%02d" % [family, index]] = {
				"size_xz_m": [bounds.size.x, bounds.size.z],
				"height_m": bounds.size.y,
				"triangle_budget": budget.duplicate(true) if budget is Dictionary else {},
			}
	return summary

func _scatter_jitter_std() -> float:
	if _scatter_jitter_values.is_empty():
		return 0.0
	var mean := Vector2.ZERO
	for value in _scatter_jitter_values:
		mean += value
	mean /= float(_scatter_jitter_values.size())
	var variance := 0.0
	for value in _scatter_jitter_values:
		var delta: Vector2 = value - mean
		variance += delta.length_squared()
	return sqrt(variance / float(_scatter_jitter_values.size()) * 0.5)

func _quality_canopy_projection_proxy() -> Dictionary:
	var result: Dictionary = {}
	for station in QUALITY_STATIONS:
		var station_id := String(station.get("id", ""))
		result[station_id] = {
			"s_m": _quality_station_distance(float(station.get("video_seconds", 0.0))),
			"trees": 0,
			"broadleaf": 0,
			"canopy_area_m2": 0.0,
			"shadow_proxy": 0.0,
		}
	for key in _tree_items.keys():
		for item in _tree_items[key]:
			var item_s := float(item.get("s", NAN))
			var item_distance := float(item.get("road_distance", INF))
			if not is_finite(item_s) or not is_finite(item_distance) or item_distance > 120.0:
				continue
			for station in QUALITY_STATIONS:
				var station_id := String(station.get("id", ""))
				var station_s := _quality_station_distance(float(station.get("video_seconds", 0.0)))
				if absf(item_s - station_s) > 180.0:
					continue
				var row: Dictionary = result[station_id]
				row["trees"] = int(row["trees"]) + 1
				if String(item.get("family", "")) == "broadleaf":
					row["broadleaf"] = int(row["broadleaf"]) + 1
				var radius := maxf(float(item.get("canopy_radius", 1.5)), 1.5)
				row["canopy_area_m2"] = float(row["canopy_area_m2"]) + PI * radius * radius
				result[station_id] = row
	for station_id in result.keys():
		var row: Dictionary = result[station_id]
		row["shadow_proxy"] = clampf(float(row["canopy_area_m2"]) / (360.0 * 240.0), 0.0, 1.0)
		result[station_id] = row
	return result

func _finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
