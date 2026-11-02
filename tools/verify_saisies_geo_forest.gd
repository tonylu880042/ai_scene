extends SceneTree

## Headless contract checks for the geographic OSM forest staging module.
##
## The check builds the same route-backed module used by the staging scene and
## inspects every authoritative authored transform. Polygon containment,
## full-route road distance, building clearance, and DEM grounding are checked
## from runtime geometry. On native rendering, --gpu-readback additionally
## compares MultiMesh position/basis buffers with those authored transforms.

const ROUTE_SCRIPT_PATH := "res://scripts/saisies_geo_route.gd"
const ROUTE_FILE := "res://data/saisies_geo_route.json"
const FOREST_SCRIPT_PATH := "res://scripts/saisies_geo_forest.gd"
const FOREST_FILE := "res://data/saisies_geo_forest.json"
const BUILDINGS_FILE := "res://data/saisies_geo_buildings.json"
const ROUTE_SAMPLE_STEP_M := 8.0
const ROUTE_HASH_CELL_M := 128.0
const GROUND_TOLERANCE_M := 0.08
const ROAD_TOLERANCE_M := 0.35
const BUILDING_TOLERANCE_M := 0.08
const NEAR_ROAD_RANGE_M := 100.0
const QUALITY_STATION_WINDOW_S_M := 180.0
const QUALITY_STATION_LATERAL_M := 120.0
const ROOT_BURY_MARGIN_M := 0.06
const ROOT_MAX_BURIAL_M := 0.85
const ROOT_FAR_MAX_BURIAL_M := 1.20
const S09_MASK_START_VIDEO_SECONDS := 318.0
const S09_MASK_CENTER_VIDEO_SECONDS := 330.0
const S09_MASK_END_VIDEO_SECONDS := 344.0
const S09_RIGHT_START_VIDEO_SECONDS := 328.0
const S09_RIGHT_END_VIDEO_SECONDS := 336.0
const S09_RIGHT_MAX_ROAD_DISTANCE_M := 120.0
const S09_CANONICAL_STATION_DISTANCE_M := 5431.282674
const S09_VIDEO_RIGHT_MIN_U_M := -35.0
const S09_VIDEO_RIGHT_MAX_U_M := -7.0
const S09_VIDEO_RIGHT_SOURCE_CONTRACT := "VIDEO_S09_RIGHT_BAND_328_336"
const S09_VIDEO_RIGHT_SOURCE_REFERENCE := "S09 canonical station 5431.282674m; source frames 330/334; export/saisies/review/round11_analysis/s09_source/source_contact.jpg + source_manifest.json; contact_sha256=8e1f3c0d51a7fb46a1ce59b93f92f7840f07665b4522e3b07edd66ef27c6c016; manifest_sha256=f246369f5a62610f7a0b683dd0e1ff99433370d4c23b6c399716b77fd6cf8805"
const S09_MASK_MAX_LATERAL_M := 35.0
const S09_MASK_LONGITUDINAL_FADE_M := 60.0
const S09_MASK_LATERAL_FADE_M := 8.0
const S13_CLIFF_START_VIDEO_SECONDS := 627.5
const S13_CLIFF_END_VIDEO_SECONDS := 632.5
const S13_CLIFF_MAX_LATERAL_M := 30.0
const S13_CLIFF_LONGITUDINAL_FADE_M := 35.0
const QUALITY_STATIONS := {
	"S08": 315.0,
	"S13": 630.0,
}

var _errors: Array[String] = []
var _error_count := 0
var _forest_polygons: Array = []
var _building_polygons: Array = []
var _route_samples: Array = []
var _route_segment_spatial_hash: Dictionary = {}
var _route: Node3D
var _geography: Object
var _landscape: Node3D
var _with_landscape := false
var _gpu_readback := false
var _check_only := false

func _initialize() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	_check_only = "--check-only" in args
	_with_landscape = "--with-landscape" in args
	_gpu_readback = "--gpu-readback" in args or not DisplayServer.get_name().to_lower().contains("headless")
	if _check_only:
		call_deferred("_check_scripts_only")
		return
	call_deferred("_run")

func _check_scripts_only() -> void:
	var forest_script := load(FOREST_SCRIPT_PATH) as Script
	var route_script := load(ROUTE_SCRIPT_PATH) as Script
	if forest_script == null or route_script == null:
		_fail("--check-only could not parse route/forest scripts")
	else:
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(FOREST_FILE)) if FileAccess.file_exists(FOREST_FILE) else null
		if not (parsed is Dictionary):
			_fail("--check-only forest data is missing or invalid")
		else:
			_verify_data(parsed)
	print("saisies geo forest check-only: scripts=%s data=%s" % ["ok" if forest_script != null and route_script != null else "fail", "ok" if _error_count == 0 else "fail"])
	_finish()

func _run() -> void:
	if not FileAccess.file_exists(FOREST_FILE):
		_fail("forest data is missing: %s" % FOREST_FILE)
		_finish()
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(FOREST_FILE))
	if not (parsed is Dictionary):
		_fail("forest data is not a JSON object")
		_finish()
		return
	var payload: Dictionary = parsed
	_verify_data(payload)
	var route_script := load(ROUTE_SCRIPT_PATH) as Script
	var forest_script := load(FOREST_SCRIPT_PATH) as Script
	if route_script == null or forest_script == null:
		_fail("route or forest script could not be loaded")
		_finish()
		return
	var holder := Node3D.new()
	holder.name = "SaisiesGeoForestVerification"
	get_root().add_child(holder)
	_route = route_script.new() as Node3D
	_route.name = "Route"
	_route.set("geo_route_file", ROUTE_FILE)
	holder.add_child(_route)
	await process_frame
	await process_frame
	if not bool(_route.call("route_ready")):
		_fail("geographic route did not become ready")
	else:
		if not _route_has_property(_route, "geography"):
			_fail("geographic route does not expose route.geography")
		else:
			_geography = _route.get("geography") as Object
			if _geography == null or not _geography.has_method("world_from_latlon") or not _geography.has_method("height_world"):
				_fail("route geography helpers are unavailable")
			else:
				if _with_landscape:
					await _add_landscape(holder)
					if _landscape == null or not bool(_landscape.get("landscape_ready")) or int(_landscape.get_meta("saisies_geo_landscape_grid_size", 0)) != 769:
						_fail("--with-landscape did not produce a ready 769 grid")
				_build_runtime_polygons(payload)
				_build_route_samples()
				_load_building_runtime_polygons()
				var forest := forest_script.new() as Node3D
				forest.name = "SaisiesGeoForest"
				forest.set("route_path", NodePath("../Route"))
				if _with_landscape:
					forest.set("landscape_path", NodePath("../Landscape"))
				holder.add_child(forest)
				for _attempt in range(240):
					if bool(forest.get("forest_ready")):
						break
					await process_frame
				if not bool(forest.get("forest_ready")):
					_fail("geo forest module did not build against route.geography")
				else:
					_verify_runtime(forest, payload)
				forest.queue_free()
		holder.queue_free()
	_finish()

func _add_landscape(holder: Node3D) -> void:
	var landscape_script := load("res://scripts/saisies_geo_landscape.gd") as Script
	if landscape_script == null:
		_fail("could not load geographic landscape script")
		return
	_landscape = landscape_script.new() as Node3D
	_landscape.name = "Landscape"
	_landscape.set("route_path", NodePath("../Route"))
	_landscape.set("build_grid_size", 769)
	holder.add_child(_landscape)
	for _attempt in range(240):
		if bool(_landscape.get("landscape_ready")):
			return
		await process_frame

func _verify_data(payload: Dictionary) -> void:
	var source: Dictionary = payload.get("source", {})
	if String(source.get("url", "")).is_empty():
		_fail("OSM source URL is missing")
	if not String(source.get("license", "")).contains("ODbL"):
		_fail("OSM source license is not recorded as ODbL")
	var snapshot_hash := String(source.get("snapshot_file_sha256", ""))
	if snapshot_hash.length() != 64 or not snapshot_hash.is_valid_hex_number():
		_fail("OSM snapshot SHA256 is missing or invalid")
	var selection: Dictionary = payload.get("selection", {})
	var route_end := float(selection.get("runtime_route_end_m", 0.0))
	if not is_finite(route_end) or route_end < 14000.0:
		_fail("forest selection does not record the complete route end: %.3f" % route_end)
	var max_road := float(selection.get("runtime_road_distance_m", 0.0))
	if absf(max_road - 600.0) > 0.1:
		_fail("forest selection road band is not 600 m: %.3f" % max_road)
	var spacing: Array = selection.get("tree_grid_spacing_m", [])
	if spacing.size() != 2 or float(spacing[0]) < 18.0 or float(spacing[1]) > 25.0:
		_fail("tree grid spacing contract is missing")
	var stats: Dictionary = payload.get("stats", {})
	var features: Array = payload.get("features", [])
	if int(stats.get("selected_features", -1)) != features.size() or features.is_empty():
		_fail("selected forest feature count does not match data")
	var support: Dictionary = payload.get("forest_support", {})
	if not String(support.get("multipolygon_support", "")).contains("outer/inner"):
		_fail("multipolygon outer/inner support is not documented")
	var expanded: Array = selection.get("expanded_bbox_world_xz", [])
	if expanded.size() != 4:
		_fail("expanded route bbox is missing")
	var seen_ids := {}
	for item in features:
		if not (item is Dictionary):
			_fail("forest feature is not an object")
			continue
		var feature: Dictionary = item
		var feature_id := String(feature.get("id", ""))
		if feature_id.is_empty() or seen_ids.has(feature_id):
			_fail("forest feature id is missing or duplicated: %s" % feature_id)
		seen_ids[feature_id] = true
		var osm_id := int(feature.get("osm_id", -1))
		if osm_id <= 0:
			_fail("forest feature OSM id is invalid: %s" % feature_id)
		var tags: Dictionary = feature.get("tags", {})
		if tags.get("landuse", "") != "forest" and tags.get("natural", "") != "wood":
			_fail("unsupported forest tag was accepted: %s" % feature_id)
		var feature_hash := String(feature.get("source_hash", ""))
		if feature_hash.length() != 64 or not feature_hash.is_valid_hex_number():
			_fail("forest feature source hash is invalid: %s" % feature_id)
		var world_bbox: Array = feature.get("world_bbox_xz", [])
		if world_bbox.size() != 4:
			_fail("forest feature world bbox is missing: %s" % feature_id)
		elif float(world_bbox[0]) < float(expanded[0]) - 0.5 or float(world_bbox[1]) < float(expanded[1]) - 0.5 or float(world_bbox[2]) > float(expanded[2]) + 0.5 or float(world_bbox[3]) > float(expanded[3]) + 0.5:
			_fail("forest feature exceeds expanded route bbox: %s" % feature_id)
		var outer_count := 0
		var inner_count := 0
		for ring_item in feature.get("rings", []):
			if not (ring_item is Dictionary):
				_fail("forest ring is not an object: %s" % feature_id)
				continue
			var ring: Dictionary = ring_item
			var coordinates: Array = ring.get("coordinates", [])
			if coordinates.size() < 4 or not _closed_lonlat(coordinates):
				_fail("forest ring is not closed: %s" % feature_id)
			for coordinate_item in coordinates:
				if not (coordinate_item is Array) or coordinate_item.size() < 2:
					_fail("forest ring coordinate is malformed: %s" % feature_id)
					continue
				var coordinate: Array = coordinate_item
				if not is_finite(float(coordinate[0])) or not is_finite(float(coordinate[1])):
					_fail("forest ring coordinate is non-finite: %s" % feature_id)
			if String(ring.get("role", "outer")) == "inner":
				inner_count += 1
			else:
				outer_count += 1
		if outer_count < 1:
			_fail("forest feature has no outer ring: %s" % feature_id)
		# A valid relation may have inner members clipped completely outside the
		# expanded runtime bbox; the feature still records explicit ring roles
		# whenever an inner survives clipping.
	print("saisies geo forest data: features=%d multipolygon=%s full_route_end=%.1f road_band=%.1f" % [features.size(), String(support.get("multipolygon_support", "")).contains("outer/inner"), route_end, max_road])

func _build_runtime_polygons(payload: Dictionary) -> void:
	_forest_polygons.clear()
	for feature_item in payload.get("features", []):
		if not (feature_item is Dictionary):
			continue
		var feature: Dictionary = feature_item
		var outers: Array = []
		var holes: Array = []
		for ring_item in feature.get("rings", []):
			if not (ring_item is Dictionary):
				continue
			var ring: Dictionary = ring_item
			var world_ring := _world_ring(ring.get("coordinates", []))
			if world_ring.size() < 4:
				continue
			if String(ring.get("role", "outer")) == "inner":
				holes.append(world_ring)
			else:
				outers.append(world_ring)
		if not outers.is_empty():
			_forest_polygons.append({"outers": outers, "holes": holes})

func _load_building_runtime_polygons() -> void:
	_building_polygons.clear()
	if not FileAccess.file_exists(BUILDINGS_FILE):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(BUILDINGS_FILE))
	if not (parsed is Dictionary):
		return
	for feature_item in parsed.get("buildings", []):
		if not (feature_item is Dictionary):
			continue
		for ring_item in feature_item.get("rings", []):
			if not (ring_item is Dictionary) or String(ring_item.get("role", "outer")) != "outer":
				continue
			var world_ring := _world_ring(ring_item.get("coordinates", []))
			if world_ring.size() >= 4:
				_building_polygons.append(world_ring)

func _build_route_samples() -> void:
	_route_samples.clear()
	_route_segment_spatial_hash.clear()
	var length_m := float(_route.get("length_m"))
	var count := maxi(int(ceil(length_m / ROUTE_SAMPLE_STEP_M)), 1)
	for index in range(count + 1):
		var s := minf(float(index) * ROUTE_SAMPLE_STEP_M, length_m)
		var point: Vector3 = _route.call("pos_at", s)
		_route_samples.append({"s": s, "xz": Vector2(point.x, point.z)})
	_build_route_segment_spatial_hash()

func _build_route_segment_spatial_hash() -> void:
	if _route_samples.size() < 2:
		return
	for segment_index in range(_route_samples.size() - 1):
		var first: Dictionary = _route_samples[segment_index]
		var second: Dictionary = _route_samples[segment_index + 1]
		var a: Vector2 = first["xz"]
		var b: Vector2 = second["xz"]
		var min_cell_x := floori(minf(a.x, b.x) / ROUTE_HASH_CELL_M) - 1
		var max_cell_x := floori(maxf(a.x, b.x) / ROUTE_HASH_CELL_M) + 1
		var min_cell_z := floori(minf(a.y, b.y) / ROUTE_HASH_CELL_M) - 1
		var max_cell_z := floori(maxf(a.y, b.y) / ROUTE_HASH_CELL_M) + 1
		for cell_x in range(min_cell_x, max_cell_x + 1):
			for cell_z in range(min_cell_z, max_cell_z + 1):
				var key := Vector2i(cell_x, cell_z)
				var bucket: Array = _route_segment_spatial_hash.get(key, [])
				bucket.append(segment_index)
				_route_segment_spatial_hash[key] = bucket

func _verify_runtime(forest: Node3D, payload: Dictionary) -> void:
	var tree_count := int(forest.get_meta("saisies_geo_forest_tree_instance_count", -1))
	var candidate_count := int(forest.get_meta("saisies_geo_forest_tree_candidate_count", -1))
	var chunk_count := int(forest.get_meta("saisies_geo_forest_chunk_count", -1))
	var polygon_count := int(forest.get_meta("saisies_geo_forest_polygon_count", -1))
	var route_end := float(forest.get_meta("saisies_geo_forest_route_end_m", NAN))
	var max_road := float(forest.get_meta("saisies_geo_forest_max_road_distance_m", NAN))
	var visibility := float(forest.get_meta("saisies_geo_forest_visibility_range_m", NAN))
	var chunk_size := float(forest.get_meta("saisies_geo_forest_chunk_size_m", NAN))
	var near_count := int(forest.get_meta("saisies_geo_forest_near_tree_count", -1))
	var far_count := int(forest.get_meta("saisies_geo_forest_far_tree_count", -1))
	var near_range := float(forest.get_meta("saisies_geo_forest_near_road_range_m", NAN))
	var road_margin := float(forest.get_meta("saisies_geo_forest_road_clearance_margin_m", NAN))
	var video_contract := String(forest.get_meta("saisies_geo_forest_s09_video_right_contract", ""))
	var video_reference := String(forest.get_meta("saisies_geo_forest_s09_video_right_source_reference", ""))
	var canonical_station_s := float(forest.get_meta("saisies_geo_forest_s09_canonical_station_distance_m", NAN))
	if video_contract != S09_VIDEO_RIGHT_SOURCE_CONTRACT:
		_fail("S09 video right source contract is missing or changed: %s" % video_contract)
	if video_reference != S09_VIDEO_RIGHT_SOURCE_REFERENCE:
		_fail("S09 video right source reference is missing or changed")
	if not is_finite(canonical_station_s) or absf(canonical_station_s - S09_CANONICAL_STATION_DISTANCE_M) > 0.01:
		_fail("S09 canonical station metadata changed: %.6f" % canonical_station_s)
	var canonical_route_s := _quality_station_distance(S09_MASK_CENTER_VIDEO_SECONDS)
	if not is_finite(canonical_route_s) or absf(canonical_route_s - S09_CANONICAL_STATION_DISTANCE_M) > 0.01:
		_fail("S09 canonical route station changed: %.6f" % canonical_route_s)
	var source_contact_path := "res://export/saisies/review/round11_analysis/s09_source/source_contact.jpg"
	var source_manifest_path := "res://export/saisies/review/round11_analysis/s09_source/source_manifest.json"
	if not FileAccess.file_exists(source_contact_path) or not FileAccess.file_exists(source_manifest_path):
		_fail("S09 source proof export is missing")
	else:
		if _sha256_file(source_contact_path) != "8e1f3c0d51a7fb46a1ce59b93f92f7840f07665b4522e3b07edd66ef27c6c016":
			_fail("S09 source contact reference hash changed")
		if _sha256_file(source_manifest_path) != "f246369f5a62610f7a0b683dd0e1ff99433370d4c23b6c399716b77fd6cf8805":
			_fail("S09 source manifest reference hash changed")
	if tree_count <= 0 or tree_count > 20000:
		_fail("runtime tree count is outside 1..20000: %d" % tree_count)
	if candidate_count < tree_count:
		_fail("runtime candidate count is below emitted tree count")
	if near_count < 0 or far_count < 0 or near_count + far_count != tree_count:
		_fail("runtime near/far populations do not sum to tree count: %d/%d/%d" % [near_count, far_count, tree_count])
	if not is_finite(near_range) or absf(near_range - NEAR_ROAD_RANGE_M) > 0.5:
		_fail("runtime near-road range is not the bounded 100 m contract: %.2f" % near_range)
	if not is_finite(road_margin) or road_margin < 2.0 or road_margin > 3.0:
		_fail("runtime asphalt-edge margin is outside 2..3 m: %.2f" % road_margin)
	if chunk_count <= 0 or polygon_count <= 0:
		_fail("runtime forest has no chunks or accepted polygons")
	if absf(route_end - float(_route.get("length_m"))) > 1.0:
		_fail("runtime forest does not cover complete route: %.2f vs %.2f" % [route_end, float(_route.get("length_m"))])
	if absf(max_road - 600.0) > 0.1 or visibility < 1900.0 or chunk_size < 240.0 or chunk_size > 272.0:
		_fail("runtime forest spatial contract is invalid")
	var ground_source := String(forest.get_meta("saisies_geo_forest_ground_source", ""))
	if ground_source != "route.geography.height_world" and ground_source != "landscape.sample_mesh_triangle":
		_fail("runtime forest ground source is not explicit: %s" % ground_source)
	if not String(forest.get_meta("saisies_geo_forest_authored_transform_contract", "")).contains("root offsets"):
		_fail("runtime forest does not expose authoritative authored transforms for headless validation")
	if not String(forest.get_meta("saisies_geo_forest_root_footprint_contract", "")).contains("indexed near-mesh low-Y root points"):
		_fail("runtime forest does not expose the indexed root footprint contract")
	var root_full_fit_count := int(forest.get_meta("saisies_geo_forest_root_full_fit_count", -1))
	var root_far_fit_count := int(forest.get_meta("saisies_geo_forest_root_far_fit_count", -1))
	var root_steep_skipped := int(forest.get_meta("saisies_geo_forest_root_steep_skipped", -1))
	if root_full_fit_count < 0 or root_far_fit_count < 0 or root_steep_skipped < 0:
		_fail("runtime forest root fitting counters are missing")
	var bins := PackedInt32Array()
	bins.resize(12)
	for index in bins.size():
		bins[index] = 0
	var checked := 0
	var records: Array = []
	var root_full_checked := 0
	var root_far_checked := 0
	var video_exception_count := 0
	var video_exception_outside_osm_count := 0
	var video_exception_records: Array = []
	for child in forest.get_children():
		var instance := child as MultiMeshInstance3D
		if instance == null:
			continue
		var multimesh := instance.multimesh
		if multimesh == null or multimesh.mesh == null or multimesh.instance_count <= 0:
			_fail("runtime forest chunk has no valid MultiMesh: %s" % instance.name)
			continue
		var authored_positions = instance.get_meta("forest_authored_positions", PackedVector3Array())
		if not (authored_positions is PackedVector3Array) or authored_positions.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks authoritative authored positions: %s" % instance.name)
			continue
		var authored_local_transforms = instance.get_meta("forest_authored_local_transforms", [])
		if not (authored_local_transforms is Array) or authored_local_transforms.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks authoritative authored bases: %s" % instance.name)
			continue
		var authored_canopy_radii = instance.get_meta("forest_authored_canopy_radii", PackedFloat32Array())
		var authored_near_flags = instance.get_meta("forest_authored_near_flags", PackedByteArray())
		var authored_quality_stations = instance.get_meta("forest_authored_quality_stations", [])
		var authored_scales = instance.get_meta("forest_authored_scales", PackedVector3Array())
		var authored_candidate_positions = instance.get_meta("forest_authored_candidate_positions", PackedVector3Array())
		var authored_root_y_offsets = instance.get_meta("forest_authored_root_y_offsets", PackedFloat32Array())
		var authored_root_burial_min = instance.get_meta("forest_authored_root_burial_min", PackedFloat32Array())
		var authored_root_burial_max = instance.get_meta("forest_authored_root_burial_max", PackedFloat32Array())
		var authored_root_contact_counts = instance.get_meta("forest_authored_root_contact_counts", PackedByteArray())
		var authored_root_full_flags = instance.get_meta("forest_authored_root_full_flags", PackedByteArray())
		var authored_source_contracts = instance.get_meta("forest_authored_source_contracts", [])
		var authored_source_references = instance.get_meta("forest_authored_source_references", [])
		var authored_video_exception_flags = instance.get_meta("forest_authored_video_exception_flags", PackedByteArray())
		if not (authored_canopy_radii is PackedFloat32Array) or authored_canopy_radii.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks authoritative canopy radii: %s" % instance.name)
			continue
		if not (authored_near_flags is PackedByteArray) or authored_near_flags.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks authoritative near/far flags: %s" % instance.name)
			continue
		if not (authored_quality_stations is Array) or authored_quality_stations.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks authoritative station labels: %s" % instance.name)
			continue
		if not (authored_scales is PackedVector3Array) or authored_scales.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks authoritative scales: %s" % instance.name)
			continue
		if not (authored_candidate_positions is PackedVector3Array) or authored_candidate_positions.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks candidate ground positions: %s" % instance.name)
			continue
		if not (authored_root_y_offsets is PackedFloat32Array) or authored_root_y_offsets.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks root y offsets: %s" % instance.name)
			continue
		if not (authored_root_burial_min is PackedFloat32Array) or authored_root_burial_min.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks root burial minima: %s" % instance.name)
			continue
		if not (authored_root_burial_max is PackedFloat32Array) or authored_root_burial_max.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks root burial maxima: %s" % instance.name)
			continue
		if not (authored_root_contact_counts is PackedByteArray) or authored_root_contact_counts.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks root contact counts: %s" % instance.name)
			continue
		if not (authored_root_full_flags is PackedByteArray) or authored_root_full_flags.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks root footprint flags: %s" % instance.name)
			continue
		if not (authored_source_contracts is Array) or authored_source_contracts.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks source contracts: %s" % instance.name)
			continue
		if not (authored_source_references is Array) or authored_source_references.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks source references: %s" % instance.name)
			continue
		if not (authored_video_exception_flags is PackedByteArray) or authored_video_exception_flags.size() != multimesh.instance_count:
			_fail("runtime forest chunk lacks video exception flags: %s" % instance.name)
			continue
		if not String(instance.get_meta("forest_root_position_contract", "")).contains("terrain-fitted y offset"):
			_fail("runtime forest chunk lacks root position offset contract: %s" % instance.name)
			continue
		var root_points = multimesh.mesh.get_meta("saisies_root_footprint_points", PackedVector3Array())
		if not (root_points is PackedVector3Array) or root_points.size() < 1 or root_points.size() > 12 or not bool(multimesh.mesh.get_meta("saisies_root_footprint_indexed", false)):
			_fail("tree mesh lacks indexed root footprint points: %s" % instance.name)
			continue
		var root_source_surfaces = multimesh.mesh.get_meta("saisies_root_footprint_source_surfaces", [])
		if not (root_source_surfaces is Array) or root_source_surfaces.is_empty() or root_source_surfaces.has(1):
			_fail("tree mesh root footprint surface contract is invalid: %s" % instance.name)
			continue
		var budget = multimesh.mesh.get_meta("saisies_triangle_budget", {})
		if not (budget is Dictionary):
			_fail("tree mesh lacks LOD triangle budget: %s" % instance.name)
		else:
			var near := int(budget.get("near", 0))
			var mid := int(budget.get("mid", 0))
			var far := int(budget.get("far", 0))
			if near <= mid or mid <= far or near > 30000:
				_fail("tree LOD budget is invalid for %s: %d/%d/%d" % [instance.name, near, mid, far])
		for index in multimesh.instance_count:
			# Godot's headless Dummy renderer may expose zeroed MultiMesh GPU
			# buffers.  The authored world positions are retained by the module and
			# are authoritative for this CPU geometry contract; root performs native
			# GPU transform readback separately.
			var world: Vector3 = authored_positions[index]
			var expected_local = authored_local_transforms[index]
			if not (expected_local is Transform3D):
				_fail("tree authored basis is malformed: %s[%d]" % [instance.name, index])
				continue
			elif _gpu_readback and not _transform_close(expected_local, multimesh.get_instance_transform(index)):
				_fail("native GPU transform differs from authored basis: %s[%d]" % [instance.name, index])
			if not _finite_vec3(world):
				_fail("tree instance has non-finite transform: %s[%d]" % [instance.name, index])
				continue
			var nearest := _nearest_route(Vector2(world.x, world.z))
			if nearest.is_empty():
				_fail("tree instance has no route projection: %s[%d]" % [instance.name, index])
				continue
			var distance := float(nearest["distance_m"])
			var s := float(nearest["s"])
			var asphalt_half := float(_route.call("road_width_at", s)) * 0.5 if _route.has_method("road_width_at") else 3.2
			var required_clearance := asphalt_half + road_margin
			if distance < required_clearance - ROAD_TOLERANCE_M or distance > 600.0 + ROAD_TOLERANCE_M or s < -0.1 or s > float(_route.get("length_m")) + 0.1:
				_fail("tree is outside route band: %s[%d] s=%.2f d=%.2f" % [instance.name, index, s, distance])
			var bin_index := clampi(int(floor(s / maxf(float(_route.get("length_m")), 1.0) * 12.0)), 0, 11)
			bins[bin_index] += 1
			var candidate_position: Vector3 = authored_candidate_positions[index]
			var candidate_ground := _ground_height(Vector2(candidate_position.x, candidate_position.z))
			if not _finite_vec3(candidate_position) or not is_finite(candidate_ground) or absf(candidate_position.y - candidate_ground) > GROUND_TOLERANCE_M:
				_fail("tree candidate ground is invalid: %s[%d] y=%.3f sampled=%.3f" % [instance.name, index, candidate_position.y, candidate_ground])
			var root_y_offset := float(authored_root_y_offsets[index])
			if not is_finite(root_y_offset) or absf((world.y - candidate_position.y) - root_y_offset) > 0.03:
				_fail("tree root position offset is not authoritative: %s[%d] offset=%.3f metadata=%.3f" % [instance.name, index, world.y - candidate_position.y, root_y_offset])
			var full_root := int(authored_root_full_flags[index]) > 0
			var expected_burial_min := float(authored_root_burial_min[index])
			var expected_burial_max := float(authored_root_burial_max[index])
			var expected_contacts := int(authored_root_contact_counts[index])
			if not is_finite(expected_burial_min) or not is_finite(expected_burial_max) or expected_contacts <= 0:
				_fail("tree root footprint metadata is invalid: %s[%d]" % [instance.name, index])
			var world_root_transform := Transform3D(expected_local.basis, world)
			var actual_burial_min := INF
			var actual_burial_max := -INF
			var actual_contacts := 0
			for local_root_point in root_points:
				var root_world: Vector3 = world_root_transform * local_root_point
				var root_ground := _ground_height(Vector2(root_world.x, root_world.z))
				if not _finite_vec3(root_world) or not is_finite(root_ground):
					_fail("tree indexed root footprint sample is non-finite: %s[%d]" % [instance.name, index])
					continue
				var burial := root_ground - root_world.y
				actual_burial_min = minf(actual_burial_min, burial)
				actual_burial_max = maxf(actual_burial_max, burial)
				if burial >= ROOT_BURY_MARGIN_M - 0.03:
					actual_contacts += 1
			if not is_finite(actual_burial_min) or not is_finite(actual_burial_max):
				_fail("tree indexed root footprint has no finite contacts: %s[%d]" % [instance.name, index])
			else:
				var allowed_max := ROOT_MAX_BURIAL_M if full_root else ROOT_FAR_MAX_BURIAL_M
				var min_allowed := ROOT_BURY_MARGIN_M - 0.03 if full_root else -0.04
				if actual_burial_min < min_allowed or actual_burial_max > allowed_max + 0.06:
					_fail("tree indexed root footprint burial is invalid: %s[%d] min=%.3f max=%.3f full=%s" % [instance.name, index, actual_burial_min, actual_burial_max, full_root])
				if absf(expected_burial_min - actual_burial_min) > 0.12 or absf(expected_burial_max - actual_burial_max) > 0.12:
					_fail("tree indexed root footprint metadata differs from sampled ground: %s[%d] metadata=%.3f..%.3f actual=%.3f..%.3f" % [instance.name, index, expected_burial_min, expected_burial_max, actual_burial_min, actual_burial_max])
				if full_root:
					root_full_checked += 1
					if expected_contacts != root_points.size() or actual_contacts < root_points.size():
						_fail("near tree root footprint is incomplete: %s[%d] contacts=%d/%d" % [instance.name, index, actual_contacts, root_points.size()])
				else:
					root_far_checked += 1
			var source_contract := String(authored_source_contracts[index])
			var source_reference := String(authored_source_references[index])
			var video_exception := int(authored_video_exception_flags[index]) > 0
			var inside_osm_forest := _inside_any_forest(Vector2(world.x, world.z))
			var in_video_band := _is_s09_video_right_band(s, float(nearest.get("u", 0.0)))
			if video_exception:
				video_exception_count += 1
				if source_contract != S09_VIDEO_RIGHT_SOURCE_CONTRACT or source_reference != S09_VIDEO_RIGHT_SOURCE_REFERENCE:
					_fail("S09 video exception provenance is invalid: %s[%d]" % [instance.name, index])
				if not in_video_band:
					_fail("video exception is outside bounded S09 right band: %s[%d] s=%.2f u=%.2f" % [instance.name, index, s, float(nearest.get("u", 0.0))])
				if not inside_osm_forest:
					video_exception_outside_osm_count += 1
				video_exception_records.append({
					"s": s,
					"u": float(nearest.get("u", 0.0)),
					"position": [world.x, world.y, world.z],
					"root_burial_min": actual_burial_min,
					"root_burial_max": actual_burial_max,
				})
			elif source_contract != "OSM_FOREST_POLYGON":
				_fail("non-video tree has an unexpected source contract: %s[%d] %s" % [instance.name, index, source_contract])
			elif not inside_osm_forest:
				_fail("tree is outside its accepted forest polygons: %s[%d]" % [instance.name, index])
			if _near_building(Vector2(world.x, world.z)):
				_fail("tree violates building clearance: %s[%d]" % [instance.name, index])
			var canopy_radius := float(authored_canopy_radii[index])
			if not is_finite(canopy_radius) or canopy_radius < 1.5 or canopy_radius > 20.0:
				_fail("tree canopy radius is invalid: %s[%d] radius=%.2f" % [instance.name, index, canopy_radius])
			var authored_scale: Vector3 = authored_scales[index]
			if not _finite_vec3(authored_scale) or authored_scale.x <= 0.0 or authored_scale.y <= 0.0 or authored_scale.z <= 0.0:
				_fail("tree authored scale is invalid: %s[%d]" % [instance.name, index])
			records.append({
				"position": world,
				"candidate_position": candidate_position,
				"s": s,
				"distance_m": distance,
				"u": float(nearest.get("u", 0.0)),
				"canopy_radius": canopy_radius,
				"near": int(authored_near_flags[index]) > 0,
				"station": String(authored_quality_stations[index]),
				"family": _family_from_chunk(instance.name),
				"root_full": full_root,
				"root_burial_min": actual_burial_min,
				"root_burial_max": actual_burial_max,
				"video_exception": video_exception,
				"source_contract": source_contract,
			})
			checked += 1
	if checked != tree_count:
		_fail("runtime MultiMesh instance total %d differs from metadata %d" % [checked, tree_count])
	var video_diagnostics = forest.get_meta("saisies_geo_forest_s09_video_right_diagnostics", {})
	if not (video_diagnostics is Dictionary):
		_fail("S09 video right diagnostics are missing")
	else:
		if int(video_diagnostics.get("emitted", -1)) != video_exception_count:
			_fail("S09 video diagnostic emitted count differs from authored exceptions: %d/%d" % [int(video_diagnostics.get("emitted", -1)), video_exception_count])
		print("saisies geo forest S09 video right: exceptions=%d outside_osm=%d diagnostics=%s" % [video_exception_count, video_exception_outside_osm_count, video_diagnostics])
	var populated_bins := 0
	for count in bins:
		if count > 0:
			populated_bins += 1
	if populated_bins < 8:
		_fail("trees are concentrated in only %d/12 route bins; full-route scatter is required" % populated_bins)
	_verify_population_split(records, near_count, far_count)
	_verify_non_row_scatter(records, forest)
	_verify_quality_stations(records)
	_verify_local_masks(records, forest)
	if root_full_checked != near_count or root_far_checked != far_count:
		_fail("root footprint tier checks do not match authored populations: %d/%d full, %d/%d far" % [root_full_checked, near_count, root_far_checked, far_count])
	print("saisies geo forest roots: full_checked=%d far_checked=%d metadata_skipped=%d" % [root_full_checked, root_far_checked, root_steep_skipped])
	print("saisies geo forest runtime: checked=%d candidates=%d trees=%d near=%d far=%d chunks=%d bins=%d ground=%s gpu_readback=%s" % [checked, candidate_count, tree_count, near_count, far_count, chunk_count, populated_bins, ground_source, _gpu_readback])

func _verify_population_split(records: Array, expected_near: int, expected_far: int) -> void:
	var actual_near := 0
	var actual_far := 0
	for record in records:
		if bool(record.get("near", false)):
			actual_near += 1
		else:
			actual_far += 1
	if actual_near != expected_near or actual_far != expected_far:
		_fail("near/far authored flags do not match metadata: %d/%d vs %d/%d" % [actual_near, actual_far, expected_near, expected_far])
	if actual_near <= 0 or actual_far <= 0:
		_fail("forest population lacks both near and far tiers: %d/%d" % [actual_near, actual_far])

func _verify_non_row_scatter(records: Array, forest: Node3D) -> void:
	var jitter_std := float(forest.get_meta("saisies_geo_forest_scatter_jitter_std_m", NAN))
	if not is_finite(jitter_std) or jitter_std < 1.6:
		_fail("forest candidate jitter is too regular for woodland scatter: %.3f m" % jitter_std)
	var grid_spacing := float(forest.get_meta("saisies_geo_forest_grid_spacing_m", 12.0))
	var modulo_x: Array[float] = []
	var modulo_z: Array[float] = []
	for record in records:
		var position: Vector3 = record["position"]
		modulo_x.append(fposmod(position.x, maxf(grid_spacing, 1.0)))
		modulo_z.append(fposmod(position.z, maxf(grid_spacing, 1.0)))
	var modulo_std := sqrt((_scalar_stddev(modulo_x) * _scalar_stddev(modulo_x) + _scalar_stddev(modulo_z) * _scalar_stddev(modulo_z)) * 0.5)
	if not is_finite(modulo_std) or modulo_std < 1.2:
		_fail("forest authored modulo distribution is too row-like: std=%.3f m" % modulo_std)
	var spatial: Dictionary = {}
	const CELL_M := 24.0
	for record in records:
		var position: Vector3 = record["position"]
		var cell := Vector2i(floori(position.x / CELL_M), floori(position.z / CELL_M))
		var bucket: Array = spatial.get(cell, [])
		bucket.append(position)
		spatial[cell] = bucket
	var nearest_distances: Array[float] = []
	for record in records:
		var position: Vector3 = record["position"]
		var cell := Vector2i(floori(position.x / CELL_M), floori(position.z / CELL_M))
		var nearest := INF
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				for other in spatial.get(Vector2i(cell.x + dx, cell.y + dz), []):
					var other_position: Vector3 = other
					var distance := Vector2(position.x, position.z).distance_to(Vector2(other_position.x, other_position.z))
					if distance > 0.001:
						nearest = minf(nearest, distance)
		if is_finite(nearest):
			nearest_distances.append(nearest)
	if nearest_distances.size() < 12:
		_fail("forest scatter has too few neighbour samples for anti-row check")
		return
	var mean := 0.0
	for distance in nearest_distances:
		mean += distance
	mean /= float(nearest_distances.size())
	var variance := 0.0
	for distance in nearest_distances:
		variance += (distance - mean) * (distance - mean)
	var coefficient := sqrt(variance / float(nearest_distances.size())) / maxf(mean, 0.001)
	if mean < 5.0 or coefficient < 0.02:
		_fail("forest scatter neighbour distances are too regular: mean=%.2f cv=%.3f" % [mean, coefficient])
	print("saisies geo forest scatter: jitter_std=%.2f m modulo_std=%.2f m nearest_mean=%.2f m nearest_cv=%.3f" % [jitter_std, modulo_std, mean, coefficient])

func _scalar_stddev(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var mean := 0.0
	for value in values:
		mean += value
	mean /= float(values.size())
	var variance := 0.0
	for value in values:
		variance += (value - mean) * (value - mean)
	return sqrt(variance / float(values.size()))

func _verify_quality_stations(records: Array) -> void:
	for station_id in QUALITY_STATIONS.keys():
		var center_s := _quality_station_distance(float(QUALITY_STATIONS[station_id]))
		var count := 0
		var broadleaf := 0
		var canopy_area := 0.0
		for record in records:
			if absf(float(record["s"]) - center_s) > QUALITY_STATION_WINDOW_S_M:
				continue
			if float(record["distance_m"]) > QUALITY_STATION_LATERAL_M:
				continue
			count += 1
			if String(record.get("family", "")) == "broadleaf":
				broadleaf += 1
			var radius := float(record["canopy_radius"])
			canopy_area += PI * radius * radius
		var broadleaf_ratio := float(broadleaf) / float(maxi(count, 1))
		var shadow_proxy := clampf(canopy_area / (360.0 * 240.0), 0.0, 1.0)
		if count < 24:
			_fail("%s near-road canopy has too few local trees: %d" % [station_id, count])
		if broadleaf_ratio < 0.45:
			_fail("%s near-road canopy is too conifer-heavy: broadleaf=%.3f count=%d" % [station_id, broadleaf_ratio, count])
		if shadow_proxy < 0.006:
			_fail("%s canopy projection shading proxy is too low: %.4f" % [station_id, shadow_proxy])
		print("saisies geo forest station %s: s=%.1f local_trees=%d broadleaf=%.3f shadow_proxy=%.4f" % [station_id, center_s, count, broadleaf_ratio, shadow_proxy])

func _verify_local_masks(records: Array, forest: Node3D) -> void:
	var s09_start := _quality_station_distance(S09_MASK_START_VIDEO_SECONDS)
	var s09_end := _quality_station_distance(S09_MASK_END_VIDEO_SECONDS)
	var s09_right_start := _quality_station_distance(S09_RIGHT_START_VIDEO_SECONDS)
	var s09_right_end := _quality_station_distance(S09_RIGHT_END_VIDEO_SECONDS)
	var s09_fade := S09_MASK_LONGITUDINAL_FADE_M
	var s09_forbidden := 0
	var s09_outer := 0
	var s09_right := 0
	var s09_right_broadleaf := 0
	var s09_right_canopy_area := 0.0
	for record in records:
		var s := float(record["s"])
		var u := float(record.get("u", 0.0))
		var distance := float(record["distance_m"])
		var road_half := float(_route.call("road_width_at", s)) * 0.5 if _route.has_method("road_width_at") else 3.2
		if s >= s09_start + s09_fade and s <= s09_end - s09_fade and distance <= S09_MASK_MAX_LATERAL_M:
			if u > road_half + 0.45 and u <= S09_MASK_MAX_LATERAL_M - S09_MASK_LATERAL_FADE_M:
				s09_forbidden += 1
			elif u > S09_MASK_MAX_LATERAL_M:
				s09_outer += 1
		if s >= s09_start and s <= s09_end and u > S09_MASK_MAX_LATERAL_M:
			s09_outer += 1
		if s >= s09_right_start and s <= s09_right_end and distance <= S09_RIGHT_MAX_ROAD_DISTANCE_M and u < -road_half - 0.45:
			s09_right += 1
			if String(record.get("family", "")) == "broadleaf":
				s09_right_broadleaf += 1
			var right_radius := maxf(float(record.get("canopy_radius", 1.5)), 1.5)
			s09_right_canopy_area += PI * right_radius * right_radius
	if s09_forbidden > 0:
		_fail("S09 left open-grass mask emitted %d trees in its interior forbidden band" % s09_forbidden)
	if s09_outer <= 0 or s09_right <= 0:
		_fail("S09 mask removed all boundary/right context trees: outer=%d right=%d" % [s09_outer, s09_right])
	var s09_right_ratio := float(s09_right_broadleaf) / float(maxi(s09_right, 1))
	var s09_right_shadow := clampf(s09_right_canopy_area / (300.0 * 240.0), 0.0, 1.0)
	if s09_right < 12:
		_fail("S09 right roadside woodland remains too sparse in the interior: %d trees" % s09_right)
	if s09_right_ratio < 0.65:
		_fail("S09 right roadside woodland is too conifer-heavy: broadleaf=%.3f count=%d" % [s09_right_ratio, s09_right])
	if s09_right_shadow < 0.005:
		_fail("S09 right roadside canopy projection is too low: %.4f" % s09_right_shadow)
	var s13_start := _quality_station_distance(S13_CLIFF_START_VIDEO_SECONDS)
	var s13_end := _quality_station_distance(S13_CLIFF_END_VIDEO_SECONDS)
	var s13_fade := S13_CLIFF_LONGITUDINAL_FADE_M
	var s13_forbidden := 0
	var s13_right := 0
	for record in records:
		var s := float(record["s"])
		if s < s13_start + s13_fade or s > s13_end - s13_fade:
			continue
		var u := float(record.get("u", 0.0))
		var road_half := float(_route.call("road_width_at", s)) * 0.5 if _route.has_method("road_width_at") else 3.2
		if u >= road_half + 0.45 and u <= S13_CLIFF_MAX_LATERAL_M - 3.0:
			s13_forbidden += 1
		if u < -road_half - 0.45 and float(record["distance_m"]) <= 120.0:
			s13_right += 1
	if s13_forbidden > 0:
		_fail("S13 left cliff exclusion emitted %d trees in its interior forbidden band" % s13_forbidden)
	if s13_right <= 0:
		_fail("S13 cliff exclusion removed all right-side local forest context")
	var s09_removed := int(forest.get_meta("saisies_geo_forest_s09_mask_removed", -1))
	var s13_removed := int(forest.get_meta("saisies_geo_forest_s13_cliff_removed", -1))
	if s09_removed < 0 or s13_removed < 0:
		_fail("local forest mask counters are missing")
	var s09_diag = forest.get_meta("saisies_geo_forest_s09_right_diagnostics", {})
	if not (s09_diag is Dictionary):
		_fail("S09 right candidate diagnostics are missing")
	else:
		print("saisies geo forest S09 right: trees=%d broadleaf=%.3f canopy_shadow=%.4f diagnostics=%s" % [s09_right, s09_right_ratio, s09_right_shadow, s09_diag])
	print("saisies geo forest masks: S09 removed=%d forbidden=%d outer=%d right=%d; S13 removed=%d forbidden=%d right=%d" % [s09_removed, s09_forbidden, s09_outer, s09_right, s13_removed, s13_forbidden, s13_right])

func _quality_station_distance(video_seconds: float) -> float:
	if _route != null and _route.has_method("distance_for_video_seconds"):
		return float(_route.call("distance_for_video_seconds", video_seconds))
	return lerpf(0.0, float(_route.get("length_m")), video_seconds / 920.0)

func _is_s09_video_right_band(s: float, u: float) -> bool:
	var start_s := _quality_station_distance(S09_RIGHT_START_VIDEO_SECONDS)
	var end_s := _quality_station_distance(S09_RIGHT_END_VIDEO_SECONDS)
	return s >= start_s - 0.25 and s <= end_s + 0.25 and u >= S09_VIDEO_RIGHT_MIN_U_M - 0.25 and u <= S09_VIDEO_RIGHT_MAX_U_M + 0.25

func _family_from_chunk(node_name: String) -> String:
	if node_name.contains("broadleaf"):
		return "broadleaf"
	if node_name.contains("conifer"):
		return "conifer"
	return "unknown"

func _ground_height(xz: Vector2) -> float:
	if _with_landscape and _landscape != null and _landscape.has_method("sample_mesh_triangle"):
		var sampled = _landscape.call("sample_mesh_triangle", xz)
		if sampled is Dictionary and sampled.has("height"):
			return float(sampled["height"])
		return NAN
	return float(_geography.call("height_world", xz))

func _transform_close(expected: Transform3D, actual: Transform3D) -> bool:
	if expected.origin.distance_to(actual.origin) > 0.01:
		return false
	for axis in range(3):
		if expected.basis[axis].distance_to(actual.basis[axis]) > 0.01:
			return false
	return true

func _inside_any_forest(point: Vector2) -> bool:
	for polygon in _forest_polygons:
		for outer in polygon["outers"]:
			if not _ring_bounds(outer).has_point(point):
				continue
			if _point_in_polygon(point, outer):
				var inside_hole := false
				for hole in polygon["holes"]:
					if _ring_bounds(hole).has_point(point) and _point_in_polygon(point, hole):
						inside_hole = true
						break
				if not inside_hole:
					return true
	return false

func _near_building(point: Vector2) -> bool:
	for building in _building_polygons:
		if not _ring_bounds(building).grow(4.0 + BUILDING_TOLERANCE_M).has_point(point):
			continue
		if _point_in_polygon(point, building) or _distance_to_ring(point, building) < 4.0 - BUILDING_TOLERANCE_M:
			return true
	return false

func _world_ring(raw_coordinates: Variant) -> PackedVector2Array:
	var points := PackedVector2Array()
	if not (raw_coordinates is Array):
		return points
	for coordinate_item in raw_coordinates:
		if not (coordinate_item is Array) or coordinate_item.size() < 2:
			return PackedVector2Array()
		var coordinate: Array = coordinate_item
		var value = _geography.call("world_from_latlon", float(coordinate[1]), float(coordinate[0]))
		if not (value is Vector3) or not _finite_vec3(value):
			return PackedVector2Array()
		points.append(Vector2(value.x, value.z))
	return points

func _nearest_route(point: Vector2) -> Dictionary:
	var best_s := INF
	var best_distance := INF
	var best_nearest := Vector2.ZERO
	var candidates: Dictionary = {}
	var center_cell := Vector2i(floori(point.x / ROUTE_HASH_CELL_M), floori(point.y / ROUTE_HASH_CELL_M))
	var search_cells := maxi(1, ceili((600.0 + ROUTE_HASH_CELL_M) / ROUTE_HASH_CELL_M))
	for dx in range(-search_cells, search_cells + 1):
		for dz in range(-search_cells, search_cells + 1):
			var bucket: Array = _route_segment_spatial_hash.get(Vector2i(center_cell.x + dx, center_cell.y + dz), [])
			for segment_index in bucket:
				candidates[int(segment_index)] = true
	for raw_index in candidates.keys():
		var index := int(raw_index)
		var first: Dictionary = _route_samples[index]
		var second: Dictionary = _route_samples[index + 1]
		var a: Vector2 = first["xz"]
		var b: Vector2 = second["xz"]
		var ab := b - a
		var t := clampf((point - a).dot(ab) / maxf(ab.length_squared(), 0.000001), 0.0, 1.0)
		var nearest := a.lerp(b, t)
		var distance := point.distance_to(nearest)
		if distance < best_distance:
			best_distance = distance
			best_s = lerpf(float(first["s"]), float(second["s"]), t)
			best_nearest = nearest
	if not is_finite(best_s):
		return {}
	var left: Vector3 = _route.call("left_at", best_s) if _route != null and _route.has_method("left_at") else Vector3(0.0, 0.0, 1.0)
	var left_xz := Vector2(left.x, left.z).normalized()
	var lateral := (point - best_nearest).dot(left_xz) if left_xz.length_squared() > 0.000001 else 0.0
	return {"s": best_s, "distance_m": best_distance, "u": lateral, "nearest_xz": best_nearest}

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
	for index in range(ring.size() - 1):
		var a := ring[index]
		var b := ring[index + 1]
		var ab := b - a
		var t := clampf((point - a).dot(ab) / maxf(ab.length_squared(), 0.000001), 0.0, 1.0)
		best = minf(best, point.distance_to(a + ab * t))
	return best

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

func _closed_lonlat(coordinates: Array) -> bool:
	if coordinates.size() < 4 or not (coordinates[0] is Array) or not (coordinates.back() is Array):
		return false
	var first: Array = coordinates[0]
	var last: Array = coordinates.back()
	return first.size() >= 2 and last.size() >= 2 and absf(float(first[0]) - float(last[0])) < 0.000001 and absf(float(first[1]) - float(last[1])) < 0.000001

func _route_has_property(node: Node, property_name: String) -> bool:
	for property in node.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false

func _finite_vec3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_buffer(file.get_length()))
	return context.finish().hex_encode()

func _fail(message: String) -> void:
	_error_count += 1
	if _errors.size() < 40:
		_errors.append(message)
		push_error("SAISIES GEO FOREST VERIFY: " + message)

func _finish() -> void:
	if _error_count > 0:
		print("SAISIES GEO FOREST VERIFY FAIL (%d errors; first %d shown)" % [_error_count, _errors.size()])
		quit(1)
	else:
		print("SAISIES GEO FOREST VERIFY PASS")
		quit(0)
