extends SceneTree

## Headless contract checks for the independent geographic Saisies route.
## This verifies route/data geometry and DEM sampling without creating a scene
## capture or relying on metadata-only assertions.

const ROUTE_SCRIPT_PATH := "res://scripts/saisies_geo_route.gd"
const ROUTE_FILE := "res://data/saisies_geo_route.json"
const ACCEPTANCE_FRAMES_FILE := "res://data/saisies_acceptance_frames.json"
const MAX_SAMPLE_GAP_M := 12.0
const SAMPLE_STEP_M := 25.0

var _errors: Array[String] = []
var _route: SaisiesGeoRoute

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var route_script := load(ROUTE_SCRIPT_PATH)
	if route_script == null:
		_fail("could not load %s" % ROUTE_SCRIPT_PATH)
		_finish()
		return
	_route = route_script.new() as SaisiesGeoRoute
	_route.name = "SaisiesGeoRouteVerify"
	_route.geo_route_file = ROUTE_FILE
	get_root().add_child(_route)
	await process_frame
	await process_frame
	if not _route.route_ready():
		_fail("geographic route did not become ready")
		_finish()
		return
	if not _route.geography_ready or _route.geography == null or not _route.geography.configured:
		_fail("route did not use a configured shared SaisiesGeography helper")
	_verify_dataset_contract()
	_verify_route_samples()
	_verify_runtime_profile()
	_verify_geo_scene_anchors()
	_verify_route_api()
	_verify_connectors()
	if _errors.is_empty():
		print("SAISIES GEO ROUTE PASS length=%.3f samples=%d raw_grade=%.3f..%.3f%% runtime_grade=%.3f..%.3f%% residual_max=%.3fm residual_rms=%.3fm ascent=%.3fm/%.3fm worst_residual s=%.3fm lat=%.7f lon=%.7f raw_asl=%.3fm runtime_asl=%.3fm raw_grade=%.3f%% runtime_grade=%.3f%%" % [
			_route.length_m,
			_route.geo_points.size(),
			float(_route.get_meta("saisies_geo_route_profile_raw_grade_min_pct", NAN)),
			float(_route.get_meta("saisies_geo_route_profile_raw_grade_max_pct", NAN)),
			float(_route.get_meta("saisies_geo_route_profile_runtime_grade_min_pct", NAN)),
			float(_route.get_meta("saisies_geo_route_profile_runtime_grade_max_pct", NAN)),
			float(_route.get_meta("saisies_geo_route_profile_max_height_residual_m", NAN)),
			float(_route.get_meta("saisies_geo_route_profile_rms_height_residual_m", NAN)),
			float(_route.get_meta("saisies_geo_route_profile_raw_ascent_m", NAN)),
			float(_route.get_meta("saisies_geo_route_profile_runtime_ascent_m", NAN)),
			float(_route.get_meta("saisies_geo_route_profile_worst_residual_s_m", NAN)),
			float(_route.get_meta("saisies_geo_route_profile_worst_residual_lat", NAN)),
			float(_route.get_meta("saisies_geo_route_profile_worst_residual_lon", NAN)),
			float(_route.get_meta("saisies_geo_route_profile_worst_residual_raw_asl_m", NAN)),
			float(_route.get_meta("saisies_geo_route_profile_worst_residual_runtime_asl_m", NAN)),
			float(_route.get_meta("saisies_geo_route_profile_worst_residual_raw_grade_pct", NAN)),
			float(_route.get_meta("saisies_geo_route_profile_worst_residual_runtime_grade_pct", NAN))
		])
	else:
		print("SAISIES GEO ROUTE FAIL errors=%d" % _errors.size())
	_finish()

func _verify_dataset_contract() -> void:
	if not FileAccess.file_exists(ROUTE_FILE):
		_fail("missing route data: %s" % ROUTE_FILE)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(ROUTE_FILE))
	if not (parsed is Dictionary):
		_fail("route data is not a JSON object")
		return
	var data: Dictionary = parsed
	var points: Array = data.get("points", [])
	if points.size() < 2:
		_fail("route data has fewer than two centerline points")
	if not data.has("geography_frame"):
		_fail("route data is missing geography_frame")
	else:
		var frame: Dictionary = data["geography_frame"]
		for key in ["origin_lat", "origin_lon", "forward_east", "forward_north", "right_east", "right_north", "datum_m"]:
			if not frame.has(key) or not is_finite(float(frame[key])):
				_fail("frame field is not finite: %s" % key)
		var forward := Vector2(float(frame.get("forward_east", 0.0)), float(frame.get("forward_north", 0.0)))
		var right := Vector2(float(frame.get("right_east", 0.0)), float(frame.get("right_north", 0.0)))
		if absf(forward.length() - 1.0) > 0.01 or absf(right.length() - 1.0) > 0.01 or absf(forward.dot(right)) > 0.01:
			_fail("geographic frame is not an orthonormal ENU frame")
	if int(data.get("schema_version", 0)) < 1:
		_fail("unsupported route schema version")
	var source: Dictionary = data.get("source", {})
	var source_urls: Array = source.get("source_urls", data.get("source_urls", []))
	if source_urls.is_empty():
		_fail("geographic source URLs are missing")
	var input_sha256: Dictionary = source.get("input_sha256", data.get("input_sha256", {}))
	for key in ["candidate", "candidate_osm", "supplemental_osm", "dem_metadata", "dem_file", "base_route"]:
		var digest := String(input_sha256.get(key, ""))
		if digest.length() != 64 or digest.to_lower() != digest or not digest.is_valid_hex_number():
			_fail("missing/invalid input SHA256: %s" % key)
	if String(source.get("candidate", "")).begins_with("/") or String(source.get("candidate_osm", "")).begins_with("/") or String(source.get("supplemental_osm", "")).begins_with("/"):
		_fail("external analysis input is embedded as an absolute path")
	var connectors: Array = data.get("supplemental_connectors", [])
	var inserted := 0
	for connector in connectors:
		if connector is Dictionary and String(connector.get("status", "")) == "inserted":
			inserted += 1
			if String(connector.get("source", "")) not in ["osm_roundabout", "osm_shortest_road_path"]:
				_fail("inserted connector lacks OSM road provenance")
	if inserted < 1:
		_fail("no supplemental OSM connector was inserted")
	if not String(data.get("old_time_mapping", "")).to_lower().contains("estimated"):
		_fail("legacy time mapping is not labelled estimated")

func _verify_route_samples() -> void:
	var points: Array = _route.geo_points
	var previous_s := -1.0
	var previous_world := Vector3.ZERO
	for index in range(points.size()):
		var point: Dictionary = points[index]
		var s := float(point.get("s_m", NAN))
		var lat := float(point.get("lat", NAN))
		var lon := float(point.get("lon", NAN))
		var world := _route.world_from_latlon(lat, lon)
		var stored_world := Vector3(float(point.get("x_m", NAN)), float(point.get("height_m", NAN)), float(point.get("z_m", NAN)))
		if not is_finite(s) or not is_finite(lat) or not is_finite(lon) or not _finite_vec3(world) or not _finite_vec3(stored_world):
			_fail("non-finite centerline point at index %d" % index)
			continue
		if index > 0:
			var gap := world.distance_to(previous_world)
			if gap <= 0.01 or gap > MAX_SAMPLE_GAP_M:
				_fail("centerline sample gap %.3f m at index %d" % [gap, index])
			if s <= previous_s:
				_fail("centerline arc length is not strictly increasing at index %d" % index)
			# x_m/z_m are retained as builder diagnostics, while runtime route
			# samples come from the shared Web-Mercator helper.  They should remain
			# close enough to flag a frame/sign mistake without imposing a degree-
			# as-metre runtime transform.
			if index % 120 == 0 and Vector2(world.x, world.z).distance_to(Vector2(stored_world.x, stored_world.z)) > 15.0:
				_fail("builder/runtime world frame diverges at index %d" % index)
		previous_s = s
		previous_world = world
	if absf(previous_s - _route.length_m) > MAX_SAMPLE_GAP_M:
		_fail("dataset length %.3f differs from last point s %.3f" % [_route.length_m, previous_s])
	if not is_finite(_route.length_m) or _route.length_m < 14000.0 or _route.length_m > 16000.0:
		_fail("unexpected geographic route length %.3f" % _route.length_m)

func _verify_runtime_profile() -> void:
	var runtime_samples = _route._samples
	if not runtime_samples is Array or runtime_samples.size() < 2:
		_fail("runtime route profile has too few samples")
		return
	var min_grade := INF
	var max_grade := -INF
	var grade_sum := 0.0
	var ascent := 0.0
	var runtime_values := PackedFloat32Array()
	runtime_values.resize(runtime_samples.size())
	var horizontal_steps := PackedFloat32Array()
	horizontal_steps.resize(runtime_samples.size() - 1)
	for i in range(runtime_samples.size()):
		var sample: Vector3 = runtime_samples[i]
		runtime_values[i] = sample.y + _route.geo_datum_m
		if i >= runtime_samples.size() - 1:
			continue
		var next_sample: Vector3 = runtime_samples[i + 1]
		var ds := maxf(Vector2(next_sample.x - sample.x, next_sample.z - sample.z).length(), 0.001)
		horizontal_steps[i] = ds
		var delta := next_sample.y - sample.y
		var grade := delta / ds * 100.0
		min_grade = minf(min_grade, grade)
		max_grade = maxf(max_grade, grade)
		grade_sum += grade * grade
		ascent += maxf(delta, 0.0)
	if min_grade < -18.05 or max_grade > 3.05:
		_fail("runtime road geometry violates constrained grade: %.3f..%.3f%%" % [min_grade, max_grade])
	if max_grade - min_grade < 1.0:
		_fail("runtime road profile collapsed to a near-constant grade")
	var runtime_grade_rms := sqrt(grade_sum / float(maxi(runtime_samples.size() - 1, 1)))
	var raw_values := PackedFloat32Array()
	raw_values.resize(runtime_samples.size())
	var raw_points: Array = _route.geo_points
	var raw_index := 0
	var raw_grade_min := INF
	var raw_grade_max := -INF
	var raw_grade_sum := 0.0
	var raw_ascent := 0.0
	var raw_segment_count := 0
	for i in range(runtime_samples.size()):
		# Re-sample the actual raw DEM at the runtime sample's unchanged XY.
		# This avoids treating the denser JSON audit points as a second
		# interpolation grid and keeps the residual comparison source-driven.
		var runtime_sample: Vector3 = runtime_samples[i]
		raw_values[i] = _route.geography.raw_height_world(Vector2(runtime_sample.x, runtime_sample.z)) + _route.geo_datum_m
	for i in range(raw_values.size() - 1):
		var ds := maxf(float(horizontal_steps[i]), 0.001)
		var delta := float(raw_values[i + 1]) - float(raw_values[i])
		var grade := delta / ds * 100.0
		raw_grade_min = minf(raw_grade_min, grade)
		raw_grade_max = maxf(raw_grade_max, grade)
		raw_grade_sum += grade * grade
		raw_ascent += maxf(delta, 0.0)
		raw_segment_count += 1
	var max_residual := 0.0
	var residual_sum := 0.0
	for i in range(runtime_values.size()):
		var residual := float(runtime_values[i]) - float(raw_values[i])
		max_residual = maxf(max_residual, absf(residual))
		residual_sum += residual * residual
	var rms_residual := sqrt(residual_sum / float(maxi(runtime_values.size(), 1)))
	var raw_grade_rms := sqrt(raw_grade_sum / float(maxi(raw_segment_count, 1)))
	var meta_pairs := [
		["saisies_geo_route_profile_raw_grade_min_pct", raw_grade_min],
		["saisies_geo_route_profile_raw_grade_max_pct", raw_grade_max],
		["saisies_geo_route_profile_raw_grade_rms_pct", raw_grade_rms],
		["saisies_geo_route_profile_raw_ascent_m", raw_ascent],
		["saisies_geo_route_profile_runtime_grade_min_pct", min_grade],
		["saisies_geo_route_profile_runtime_grade_max_pct", max_grade],
		["saisies_geo_route_profile_runtime_grade_rms_pct", runtime_grade_rms],
		["saisies_geo_route_profile_runtime_ascent_m", ascent],
		["saisies_geo_route_profile_max_height_residual_m", max_residual],
		["saisies_geo_route_profile_rms_height_residual_m", rms_residual]
	]
	for pair in meta_pairs:
		var key := String(pair[0])
		var expected := float(pair[1])
		var actual := float(_route.get_meta(key, NAN))
		if not is_finite(actual) or absf(actual - expected) > 0.05:
			_fail("runtime profile audit metadata mismatch %s: %.4f vs %.4f" % [key, actual, expected])
	if _route.get_meta("saisies_geo_route_runtime_profile_estimated", false) != true:
		_fail("runtime route profile is missing estimated metadata")
	var filter_window := float(_route.get_meta("saisies_geo_route_runtime_profile_filter_window_m", NAN))
	if not is_finite(filter_window) or filter_window < 60.0 or filter_window > 100.0:
		_fail("runtime profile filter window is outside requested 60..100 m: %.3f" % filter_window)
	if absf(float(runtime_values[0]) - _route.start_elevation_m) > 0.02 or absf(float(runtime_values[runtime_values.size() - 1]) - _route.end_elevation_m) > 0.02:
		_fail("runtime road profile does not preserve endpoint ASL fields")
	# Check that the runtime geometry, not merely its grade metadata, is what
	# the shared geography helper uses for the road blend.
	for i in range(0, runtime_samples.size(), 100):
		var sample: Vector3 = runtime_samples[i]
		var nearest := _route.geography.nearest_route_world(Vector2(sample.x, sample.z))
		if not nearest is Dictionary or not nearest.has("road_y") or absf(float(nearest["road_y"]) - sample.y) > 0.03:
			_fail("geography route sample does not use runtime profile at index %d" % i)
	# Runtime profile must retain the geographic XY route.  Compare against the
	# same source lat/lon interpolation used by the route loader at sparse probes.
	raw_index = 0
	for i in range(0, runtime_samples.size(), 120):
		var target_s := minf(float(i) * _route.sample_spacing_m, _route.length_m)
		while raw_index + 1 < raw_points.size() and float(raw_points[raw_index + 1].get("s_m", INF)) < target_s:
			raw_index += 1
		var point_a: Dictionary = raw_points[raw_index]
		var point_b: Dictionary = raw_points[mini(raw_index + 1, raw_points.size() - 1)]
		var s_a := float(point_a.get("s_m", 0.0))
		var s_b := float(point_b.get("s_m", s_a))
		var t := clampf((target_s - s_a) / maxf(s_b - s_a, 0.000001), 0.0, 1.0)
		var latitude := lerpf(float(point_a.get("lat", 0.0)), float(point_b.get("lat", 0.0)), t)
		var longitude := lerpf(float(point_a.get("lon", 0.0)), float(point_b.get("lon", 0.0)), t)
		var geographic_xz := _route.world_from_latlon(latitude, longitude)
		var runtime_xz: Vector3 = runtime_samples[i]
		if Vector2(geographic_xz.x - runtime_xz.x, geographic_xz.z - runtime_xz.z).length() > 0.05:
			_fail("runtime road profile changed geographic XY at sample %d" % i)

func _verify_geo_scene_anchors() -> void:
	var map_path := "res://data/saisies_geo_scene_map.json"
	if not FileAccess.file_exists(map_path):
		_fail("missing geo-only scene map: %s" % map_path)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(map_path))
	if not (parsed is Dictionary):
		_fail("geo-only scene map is not a JSON object")
		return
	var data: Dictionary = parsed
	if data.get("estimated", false) != true or not String(data.get("note", "")).to_lower().contains("not gps"):
		_fail("geo-only scene map is missing estimated/non-GPS provenance")
	var expected := {"S01": 50.0, "S03": 930.0, "S05": 2800.0}
	for scene_id in expected.keys():
		var distance := float(_route.acceptance_distance(scene_id))
		if absf(distance - float(expected[scene_id])) > 0.05:
			_fail("geo anchor %s is %.3f m, expected %.3f m" % [scene_id, distance, float(expected[scene_id])])
	var continuous_samples := [0.0, 1.0, 74.9, 75.0, 75.1, 179.9, 180.0, 180.1, 920.067]
	var previous := -INF
	for video_seconds in continuous_samples:
		var distance := _route.distance_for_video_seconds(video_seconds)
		if not is_finite(distance) or distance < previous:
			_fail("geo checkpoint mapping is not continuous/monotonic near %.3f s" % video_seconds)
		previous = distance
	if absf(_route.distance_for_video_seconds(0.0)) > 0.05:
		_fail("geo route no longer preserves the zero-second origin")
	_verify_reference_scene_distances()
	var checkpoints: Array = _route._checkpoints
	var previous_s := -INF
	var previous_time := -INF
	for checkpoint in checkpoints:
		var current_s := float(checkpoint.get("distance_m", NAN))
		var current_time := float(checkpoint.get("video_seconds", NAN))
		if not is_finite(current_s) or not is_finite(current_time) or current_s < previous_s - 0.001 or current_time < previous_time - 0.001:
			_fail("geo checkpoint anchors are not sorted by time/distance")
		previous_s = current_s
		previous_time = current_time

func _verify_reference_scene_distances() -> void:
	## Compare every static acceptance id with the independently authored
	## reference-frame time.  This deliberately reads requested_seconds from
	## the acceptance manifest, rather than using geo-map anchor times as the
	## expected value, so a bad anchor cannot verify itself.
	if not FileAccess.file_exists(ACCEPTANCE_FRAMES_FILE):
		_fail("missing acceptance frame manifest: %s" % ACCEPTANCE_FRAMES_FILE)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(ACCEPTANCE_FRAMES_FILE))
	if not (parsed is Dictionary) or not (parsed.get("scenes", []) is Array):
		_fail("acceptance frame manifest is not a scene list")
		return
	var scenes: Array = parsed["scenes"]
	if scenes.size() != 18:
		_fail("acceptance frame manifest has %d scenes, expected 18" % scenes.size())
		return
	var seen := {}
	for item in scenes:
		if not (item is Dictionary):
			_fail("acceptance frame entry is not an object")
			continue
		var scene_id := String(item.get("scene_id", ""))
		var requested_seconds := float(item.get("requested_seconds", NAN))
		if scene_id.is_empty() or not is_finite(requested_seconds):
			_fail("acceptance frame entry is missing scene id/time")
			continue
		if seen.has(scene_id):
			_fail("acceptance frame manifest repeats %s" % scene_id)
		seen[scene_id] = true
		var expected_distance := _route.distance_for_video_seconds(requested_seconds)
		var acceptance_distance := _route.acceptance_distance(scene_id)
		if not is_finite(expected_distance) or not is_finite(acceptance_distance) or absf(acceptance_distance - expected_distance) > 0.05:
			_fail("static/normal distance mismatch %s at %.3f s: %.3f vs %.3f" % [scene_id, requested_seconds, acceptance_distance, expected_distance])

func _verify_route_api() -> void:
	var start := _route.pos_at(0.0)
	var first_tangent := _route.tangent_at(0.0)
	if start.length() > 0.01:
		_fail("route start is not at local origin: %s" % start)
	if first_tangent.dot(Vector3(0.0, 0.0, -1.0)) < 0.95:
		_fail("first geographic tangent is not local -Z: %s" % first_tangent)
	var frame := _route.frame()
	var start_geo := _route.world_from_latlon(float(frame["origin_lat"]), float(frame["origin_lon"]))
	if start_geo.length() > 0.1:
		_fail("world_from_latlon(origin) is not local origin: %s" % start_geo)
	var last_point: Dictionary = _route.geo_points.back()
	var end_geo := _route.world_from_latlon(float(last_point["lat"]), float(last_point["lon"]))
	var end_route := _route.pos_at(_route.length_m)
	if end_route.distance_to(end_geo) > 0.1:
		_fail("route endpoint does not reach final geographic point: %.3f m" % end_route.distance_to(end_geo))
	if _route.get_node_or_null("SaisiesGrassBanks") != null:
		_fail("geographic route created the base broad grass ribbon")
	if _route.get_node_or_null("SaisiesGeoGravelShoulders") == null:
		_fail("geographic route did not create its narrow shoulder seam")
	if _route.get_node_or_null("SaisiesRoadCollision") == null:
		_fail("geographic route road collision is missing")
	var north_probe := _route.world_from_latlon(float(frame["origin_lat"]) + 0.001, float(frame["origin_lon"]))
	var east_probe := _route.world_from_latlon(float(frame["origin_lat"]), float(frame["origin_lon"]) + 0.001)
	if Vector2(north_probe.x, north_probe.z).length() < 1.0 or Vector2(east_probe.x, east_probe.z).length() < 1.0:
		_fail("geographic north/east probes collapsed")
	var sample_s := 0.0
	var previous_api_pos := start
	while sample_s <= _route.length_m + 0.1:
		var pos := _route.pos_at(sample_s)
		var ground := _route.ground_y(sample_s, 0.0)
		var left_ground := _route.ground_y(sample_s, _route.road_width_at(sample_s) * 0.5 + 12.0)
		var right_ground := _route.ground_y(sample_s, -(_route.road_width_at(sample_s) * 0.5 + 12.0))
		var grade := _route.grade_at(sample_s)
		if not _finite_vec3(pos) or not is_finite(ground) or not is_finite(left_ground) or not is_finite(right_ground) or not is_finite(grade):
			_fail("non-finite route API sample at s=%.2f" % sample_s)
		if absf(grade) > 100.0:
			_fail("unreasonable grade %.3f at s=%.2f" % [grade, sample_s])
		if sample_s > 0.0 and pos.distance_to(previous_api_pos) > 40.0:
			_fail("route API has a giant world gap %.3f m at s=%.2f" % [pos.distance_to(previous_api_pos), sample_s])
		previous_api_pos = pos
		sample_s += SAMPLE_STEP_M
	# Exercise the inherited public anchors with the geographic checkpoint map.
	for scene_id in ["S01", "S03", "S05", "S08", "S09", "S18"]:
		var distance := _route.acceptance_distance(scene_id)
		if not is_finite(distance) or distance < 0.0 or distance > _route.length_m:
			_fail("invalid acceptance distance for %s: %.3f" % [scene_id, distance])

func _verify_connectors() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(ROUTE_FILE))
	if not (data is Dictionary):
		return
	var points: Array = data.get("points", [])
	var inserted_points := 0
	for point in points:
		if point is Dictionary and String(point.get("source", "")).begins_with("osm_"):
			inserted_points += 1
	if inserted_points < 2:
		_fail("expected roundabout connector points in centerline, found %d" % inserted_points)
	var connectors: Array = data.get("supplemental_connectors", [])
	for connector in connectors:
		if not (connector is Dictionary) or String(connector.get("status", "")) != "inserted":
			continue
		var path_nodes: Array = connector.get("path_nodes", [])
		if path_nodes.size() < 3:
			_fail("inserted connector has no intermediate OSM nodes")

func _finite_vec3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES GEO ROUTE: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES GEO ROUTE VERIFY PASS")
		quit(0)
	else:
		print("SAISIES GEO ROUTE VERIFY FAIL (%d errors)" % _errors.size())
		quit(1)
