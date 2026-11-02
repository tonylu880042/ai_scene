class_name SaisiesGeoRoute
extends SaisiesRoute

## Geographic Saisies route backed by the cached D218B centerline and DEM.
##
## The dataset keeps lat/lon and real accumulated arc length for auditability,
## while the inherited route API remains in local Godot metres.  The geographic
## frame follows the shared contract: local +X is ENU right, local -Z is ENU
## forward, and local Y is raw DEM height minus the recorded datum.  Legacy
## video-time checkpoints are retained as estimated proportional mappings.

@export_file("*.json") var geo_route_file := "res://data/saisies_geo_route.json"
const GeographyScript = preload("res://scripts/saisies_geography.gd")
const GEO_SCENE_MAP_FILE := "res://data/saisies_geo_scene_map.json"

var geography: SaisiesGeography = GeographyScript.new()
var geography_frame: Dictionary = {}
var geography_ready := false
var geo_points: Array = []
var geo_data: Dictionary = {}
var geo_datum_m := 0.0
var _runtime_sample_count := 0
var _geo_scene_anchors: Dictionary = {}
const GEO_SHOULDER_WIDTH_M := 0.28
## The DEM is retained as the source/audit surface, but its cell-to-cell
## longitudinal noise is too steep for a drivable road.  This profile is an
## estimated roadbed elevation: an 80 m box filter followed by a constrained
## projection.  It preserves the geographic XY/arc length and endpoint ASL,
## while keeping the actual runtime road geometry inside a plausible grade.
const RUNTIME_PROFILE_FILTER_WINDOW_M := 80.0
const RUNTIME_PROFILE_MIN_GRADE_PCT := -18.0
const RUNTIME_PROFILE_MAX_GRADE_PCT := 3.0
const RUNTIME_PROFILE_PROJECTION_PASSES := 24
var _raw_profile_asl := PackedFloat32Array()
var _runtime_profile_asl := PackedFloat32Array()

func _load_route_data() -> void:
	# The base loader still normalises sections/checkpoints/landmarks and keeps
	# all inherited public route fields.  The geographic loader then adds the
	# centerline/frame metadata without touching v2 data.
	route_file = geo_route_file
	geo_route_file = route_file
	super._load_route_data()
	geo_data = {}
	if FileAccess.file_exists(geo_route_file):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(geo_route_file))
		if parsed is Dictionary:
			geo_data = parsed
	geography_frame = geo_data.get("geography_frame", {}).duplicate(true)
	geo_datum_m = float(geography_frame.get("datum_m", 0.0))
	geo_points = geo_data.get("points", []).duplicate(true)
	if geo_points.size() < 2:
		push_error("SaisiesGeoRoute needs at least two geographic points")
		return
	# Ensure these inherited defaults follow the geographic dataset even when a
	# future base loader changes its fallback values.
	length_m = maxf(float(geo_data.get("length_m", geo_data.get("estimated_length_m", length_m))), 100.0)
	start_elevation_m = float(geo_data.get("start_elevation_m", start_elevation_m))
	end_elevation_m = float(geo_data.get("end_elevation_m", end_elevation_m))
	road_width_m = clampf(float(geo_data.get("road_width_m", road_width_m)), 4.0, 12.0)
	sample_spacing_m = clampf(float(geo_data.get("sample_spacing_m", sample_spacing_m)), 2.0, 20.0)
	_runtime_sample_count = maxi(int(ceil(length_m / maxf(sample_spacing_m, 0.001))), 1) + 1
	# SaisiesRoute's inherited mesh/index builders use a fixed sample spacing.
	# Make the final interval exact while retaining the requested ~10 m density,
	# so the real geographic endpoint is reachable without a hidden tail gap.
	sample_spacing_m = length_m / float(maxi(_runtime_sample_count - 1, 1))
	geography_ready = geography.configure(geography_frame)
	if not geography_ready:
		push_error("SaisiesGeoRoute geography helper failed to configure")
		return
	geo_datum_m = geography.datum_m
	_load_geo_scene_anchors()
	_apply_geo_scene_anchors()

func _build_samples() -> void:
	_samples.clear()
	if not geography_ready:
		push_error("SaisiesGeoRoute cannot build samples without configured geography")
		return
	var n := _runtime_sample_count
	var transformed: Array[Vector3] = []
	var source_index := 0
	for sample_index in range(n):
		var target_s := minf(float(sample_index) * sample_spacing_m, length_m)
		while source_index + 1 < geo_points.size() and float(geo_points[source_index + 1].get("s_m", INF)) < target_s:
			source_index += 1
		var source_a: Dictionary = geo_points[source_index]
		var source_b: Dictionary = geo_points[mini(source_index + 1, geo_points.size() - 1)]
		var source_s0 := float(source_a.get("s_m", 0.0))
		var source_s1 := float(source_b.get("s_m", source_s0))
		var source_t := clampf((target_s - source_s0) / maxf(source_s1 - source_s0, 0.000001), 0.0, 1.0)
		var latitude := lerpf(float(source_a["lat"]), float(source_b["lat"]), source_t)
		var longitude := lerpf(float(source_a["lon"]), float(source_b["lon"]), source_t)
		transformed.append(geography.world_from_latlon(latitude, longitude))
	var raw_profile := PackedFloat32Array()
	raw_profile.resize(n)
	var horizontal_steps := PackedFloat32Array()
	horizontal_steps.resize(maxi(n - 1, 0))
	for i in range(n):
		raw_profile[i] = transformed[i].y + geo_datum_m
		if i < n - 1:
			var a_xz := Vector2(transformed[i].x, transformed[i].z)
			var b_xz := Vector2(transformed[i + 1].x, transformed[i + 1].z)
			horizontal_steps[i] = maxf(a_xz.distance_to(b_xz), 0.001)
	# Keep the dataset's explicit endpoint ASL fields as runtime constraints.
	# They are normally identical to the DEM samples at the geographic origin
	# and end, but using the fields makes the endpoint contract explicit.
	if n > 0:
		raw_profile[0] = start_elevation_m
		raw_profile[n - 1] = end_elevation_m
	var runtime_profile := _estimate_runtime_profile(raw_profile, horizontal_steps)
	_raw_profile_asl = raw_profile.duplicate()
	_runtime_profile_asl = runtime_profile.duplicate()
	_headings.resize(n)
	_elevations.resize(n)
	_grades.resize(n)
	for i in range(n):
		var world := transformed[i]
		world.y = runtime_profile[i] - geo_datum_m
		_samples.append(world)
		_elevations[i] = runtime_profile[i]
		var a := world if i == 0 else transformed[maxi(i - 1, 0)]
		var b := world if i == n - 1 else transformed[mini(i + 1, n - 1)]
		var delta := Vector2(b.x - a.x, b.z - a.z)
		if delta.length_squared() <= 0.000001:
			_headings[i] = _headings[i - 1] if i > 0 else 0.0
		else:
			_headings[i] = atan2(delta.x, -delta.y)
	for i in range(n):
		if i == 0:
			_grades[i] = _grade_between(0, 1)
		elif i == n - 1:
			_grades[i] = _grade_between(n - 2, n - 1)
		else:
			_grades[i] = _grade_between(i - 1, i + 1)
	_record_runtime_profile_audit(raw_profile, runtime_profile, horizontal_steps)
	_configure_geography_route_samples()

func _estimate_runtime_profile(raw_profile: PackedFloat32Array, horizontal_steps: PackedFloat32Array) -> PackedFloat32Array:
	var count := raw_profile.size()
	var result := PackedFloat32Array()
	result.resize(count)
	if count == 0:
		return result
	if count == 1:
		result[0] = raw_profile[0]
		return result
	var radius := maxi(int(round(RUNTIME_PROFILE_FILTER_WINDOW_M / maxf(sample_spacing_m, 0.001))), 1)
	for i in range(count):
		var from_index := maxi(i - radius, 0)
		var to_index := mini(i + radius, count - 1)
		var total := 0.0
		for j in range(from_index, to_index + 1):
			total += raw_profile[j]
		result[i] = total / float(to_index - from_index + 1)
	result[0] = raw_profile[0]
	result[count - 1] = raw_profile[count - 1]
	# Alternating forward/backward projection is a small bounded least-change
	# estimate.  It constrains actual height deltas, rather than merely clamping
	# the displayed grade values, and converges because endpoint ASL is feasible.
	for _pass in range(RUNTIME_PROFILE_PROJECTION_PASSES):
		result[0] = raw_profile[0]
		for i in range(1, count):
			var ds := maxf(float(horizontal_steps[i - 1]), 0.001)
			var lower := result[i - 1] + RUNTIME_PROFILE_MIN_GRADE_PCT * ds * 0.01
			var upper := result[i - 1] + RUNTIME_PROFILE_MAX_GRADE_PCT * ds * 0.01
			result[i] = clampf(result[i], lower, upper)
		result[count - 1] = raw_profile[count - 1]
		for i in range(count - 2, -1, -1):
			var ds := maxf(float(horizontal_steps[i]), 0.001)
			var lower := result[i + 1] - RUNTIME_PROFILE_MAX_GRADE_PCT * ds * 0.01
			var upper := result[i + 1] - RUNTIME_PROFILE_MIN_GRADE_PCT * ds * 0.01
			result[i] = clampf(result[i], lower, upper)
		result[0] = raw_profile[0]
	return result

func _record_runtime_profile_audit(raw_profile: PackedFloat32Array, runtime_profile: PackedFloat32Array, horizontal_steps: PackedFloat32Array) -> void:
	var raw_stats := _profile_stats(raw_profile, horizontal_steps)
	var runtime_stats := _profile_stats(runtime_profile, horizontal_steps)
	var max_residual := 0.0
	var residual_sum := 0.0
	var max_residual_index := 0
	for i in range(mini(raw_profile.size(), runtime_profile.size())):
		var residual := float(runtime_profile[i]) - float(raw_profile[i])
		if absf(residual) > max_residual:
			max_residual = absf(residual)
			max_residual_index = i
		residual_sum += residual * residual
	var rms_residual := sqrt(residual_sum / float(maxi(raw_profile.size(), 1)))
	var worst_s := minf(float(max_residual_index) * sample_spacing_m, length_m)
	var worst_latlon := _geo_latlon_at_distance(worst_s)
	var worst_raw_grade := _profile_grade_at(raw_profile, horizontal_steps, max_residual_index)
	var worst_runtime_grade := _profile_grade_at(runtime_profile, horizontal_steps, max_residual_index)
	set_meta("saisies_geo_route_runtime_profile_estimated", true)
	set_meta("saisies_geo_route_runtime_profile_note", "DEM-guided 80 m smoothed/constrained roadbed estimate; not GPS or camera calibration.")
	set_meta("saisies_geo_route_runtime_profile_filter_window_m", RUNTIME_PROFILE_FILTER_WINDOW_M)
	set_meta("saisies_geo_route_runtime_profile_min_grade_pct", RUNTIME_PROFILE_MIN_GRADE_PCT)
	set_meta("saisies_geo_route_runtime_profile_max_grade_pct", RUNTIME_PROFILE_MAX_GRADE_PCT)
	set_meta("saisies_geo_route_profile_raw_grade_min_pct", raw_stats["grade_min_pct"])
	set_meta("saisies_geo_route_profile_raw_grade_max_pct", raw_stats["grade_max_pct"])
	set_meta("saisies_geo_route_profile_raw_grade_rms_pct", raw_stats["grade_rms_pct"])
	set_meta("saisies_geo_route_profile_raw_height_min_asl_m", raw_stats["height_min_asl_m"])
	set_meta("saisies_geo_route_profile_raw_height_max_asl_m", raw_stats["height_max_asl_m"])
	set_meta("saisies_geo_route_profile_raw_ascent_m", raw_stats["ascent_m"])
	set_meta("saisies_geo_route_profile_runtime_grade_min_pct", runtime_stats["grade_min_pct"])
	set_meta("saisies_geo_route_profile_runtime_grade_max_pct", runtime_stats["grade_max_pct"])
	set_meta("saisies_geo_route_profile_runtime_grade_rms_pct", runtime_stats["grade_rms_pct"])
	set_meta("saisies_geo_route_profile_runtime_height_min_asl_m", runtime_stats["height_min_asl_m"])
	set_meta("saisies_geo_route_profile_runtime_height_max_asl_m", runtime_stats["height_max_asl_m"])
	set_meta("saisies_geo_route_profile_runtime_ascent_m", runtime_stats["ascent_m"])
	set_meta("saisies_geo_route_profile_max_height_residual_m", max_residual)
	set_meta("saisies_geo_route_profile_rms_height_residual_m", rms_residual)
	set_meta("saisies_geo_route_profile_worst_residual_s_m", worst_s)
	set_meta("saisies_geo_route_profile_worst_residual_lat", worst_latlon.x)
	set_meta("saisies_geo_route_profile_worst_residual_lon", worst_latlon.y)
	set_meta("saisies_geo_route_profile_worst_residual_raw_asl_m", float(raw_profile[max_residual_index]) if not raw_profile.is_empty() else NAN)
	set_meta("saisies_geo_route_profile_worst_residual_runtime_asl_m", float(runtime_profile[max_residual_index]) if not runtime_profile.is_empty() else NAN)
	set_meta("saisies_geo_route_profile_worst_residual_raw_grade_pct", worst_raw_grade)
	set_meta("saisies_geo_route_profile_worst_residual_runtime_grade_pct", worst_runtime_grade)
	set_meta("saisies_geo_route_profile_sample_count", runtime_profile.size())
	set_meta("saisies_geo_route_profile_endpoint_start_asl_m", float(runtime_profile[0]) if not runtime_profile.is_empty() else NAN)
	set_meta("saisies_geo_route_profile_endpoint_end_asl_m", float(runtime_profile[runtime_profile.size() - 1]) if not runtime_profile.is_empty() else NAN)

func _profile_stats(profile: PackedFloat32Array, horizontal_steps: PackedFloat32Array) -> Dictionary:
	if profile.is_empty():
		return {"grade_min_pct": NAN, "grade_max_pct": NAN, "grade_rms_pct": NAN, "height_min_asl_m": NAN, "height_max_asl_m": NAN, "ascent_m": NAN}
	var min_grade := INF
	var max_grade := -INF
	var grade_sum := 0.0
	var ascent := 0.0
	var segment_count := 0
	for i in range(profile.size() - 1):
		var ds := maxf(float(horizontal_steps[i]), 0.001)
		var delta := float(profile[i + 1]) - float(profile[i])
		var grade := delta / ds * 100.0
		min_grade = minf(min_grade, grade)
		max_grade = maxf(max_grade, grade)
		grade_sum += grade * grade
		ascent += maxf(delta, 0.0)
		segment_count += 1
	var min_height := INF
	var max_height := -INF
	for value in profile:
		min_height = minf(min_height, float(value))
		max_height = maxf(max_height, float(value))
	return {
		"grade_min_pct": min_grade,
		"grade_max_pct": max_grade,
		"grade_rms_pct": sqrt(grade_sum / float(maxi(segment_count, 1))),
		"height_min_asl_m": min_height,
		"height_max_asl_m": max_height,
		"ascent_m": ascent
	}

func _profile_grade_at(profile: PackedFloat32Array, horizontal_steps: PackedFloat32Array, index: int) -> float:
	if profile.size() < 2 or horizontal_steps.is_empty():
		return NAN
	var segment := clampi(index, 0, profile.size() - 2)
	return (float(profile[segment + 1]) - float(profile[segment])) / maxf(float(horizontal_steps[segment]), 0.001) * 100.0

func _geo_latlon_at_distance(distance_m: float) -> Vector2:
	if geo_points.is_empty():
		return Vector2(NAN, NAN)
	var clamped := clampf(distance_m, 0.0, length_m)
	var index := 0
	while index + 1 < geo_points.size() and float(geo_points[index + 1].get("s_m", INF)) < clamped:
		index += 1
	var a: Dictionary = geo_points[index]
	var b: Dictionary = geo_points[mini(index + 1, geo_points.size() - 1)]
	var s0 := float(a.get("s_m", 0.0))
	var s1 := float(b.get("s_m", s0))
	var t := clampf((clamped - s0) / maxf(s1 - s0, 0.000001), 0.0, 1.0)
	return Vector2(
		lerpf(float(a.get("lat", NAN)), float(b.get("lat", NAN)), t),
		lerpf(float(a.get("lon", NAN)), float(b.get("lon", NAN)), t)
	)

func _load_geo_scene_anchors() -> void:
	_geo_scene_anchors.clear()
	if not FileAccess.file_exists(GEO_SCENE_MAP_FILE):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(GEO_SCENE_MAP_FILE))
	if not (parsed is Dictionary):
		push_warning("SaisiesGeoRoute geo scene map is not a JSON object")
		return
	for item in parsed.get("scenes", []):
		if not (item is Dictionary):
			continue
		var scene_id := String(item.get("scene_id", ""))
		if scene_id.is_empty():
			continue
		_geo_scene_anchors[scene_id] = item.duplicate(true)
	set_meta("saisies_geo_scene_map_file", GEO_SCENE_MAP_FILE)
	set_meta("saisies_geo_scene_map_estimated", true)
	set_meta("saisies_geo_scene_map_anchor_count", _geo_scene_anchors.size())

func _apply_geo_scene_anchors() -> void:
	if _geo_scene_anchors.is_empty() or _checkpoints.is_empty():
		return
	var anchors: Array = []
	for scene_id in _geo_scene_anchors.keys():
		var item: Dictionary = _geo_scene_anchors[scene_id]
		if not item.has("video_seconds") or not item.has("distance_m"):
			continue
		var video_seconds := float(item["video_seconds"])
		var distance_m := clampf(float(item["distance_m"]), 0.0, length_m)
		var elevation_m := _checkpoint_elevation_at(distance_for_video_seconds(video_seconds))
		var heading_rad := _heading_at(distance_for_video_seconds(video_seconds))
		anchors.append({
			"distance_m": distance_m,
			"video_seconds": video_seconds,
			"elevation_m": elevation_m,
			"heading_deg": rad_to_deg(heading_rad),
			"estimated": true,
			"mapping": String(item.get("distance_source", "estimated geographic visual landmark inference; not GPS"))
		})
	for anchor in anchors:
		var replaced := false
		for index in range(_checkpoints.size()):
			if absf(float(_checkpoints[index].get("video_seconds", -INF)) - float(anchor["video_seconds"])) < 0.001:
				_checkpoints[index] = anchor
				replaced = true
				break
		if not replaced:
			_checkpoints.append(anchor)
	_checkpoints.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("video_seconds", 0.0)) < float(b.get("video_seconds", 0.0)))

func acceptance_distance(scene_id: String) -> float:
	## Geo-only visual landmark anchors share the same checkpoint interpolation
	## as normal video-time mapping; v2 scene data and poses stay untouched.
	if _geo_scene_anchors.has(scene_id):
		var anchor: Dictionary = _geo_scene_anchors[scene_id]
		if anchor.has("distance_m"):
			return clampf(float(anchor["distance_m"]), 0.0, length_m)
		if anchor.has("video_seconds"):
			return distance_for_video_seconds(float(anchor["video_seconds"]))
	return super.acceptance_distance(scene_id)

func _grade_between(a: int, b: int) -> float:
	var pa: Vector3 = _samples[a]
	var pb: Vector3 = _samples[b]
	var horizontal := Vector2(pb.x - pa.x, pb.z - pa.z).length()
	if horizontal <= 0.001:
		return 0.0
	return (pb.y - pa.y) / horizontal * 100.0

func _configure_geography_route_samples() -> void:
	if not geography_ready:
		return
	var samples := PackedVector3Array()
	for point in _samples:
		samples.append(point)
	geography.set_route_samples(samples, road_width_m * 0.5)

func frame() -> Dictionary:
	return geography_frame.duplicate(true)

func world_from_latlon(latitude: float, longitude: float) -> Vector3:
	return geography.world_from_latlon(latitude, longitude)

func raw_height_world(xz: Vector2) -> float:
	return geography.raw_height_world(xz)

func height_world(xz: Vector2) -> float:
	return geography.height_world(xz)

func ground_y(s: float, u: float) -> float:
	var point := pos_at(s) + left_at(s) * u
	if absf(u) <= road_width_at(s) * 0.5:
		return _road_y(s, u)
	return height_world(Vector2(point.x, point.z))

func _terrain_point(s: float, u: float) -> Vector3:
	var point := _road_point(s, u)
	point.y = height_world(Vector2(point.x, point.z))
	return point

func _build_terrain() -> void:
	## GeoLandscape owns the full DEM terrain.  Keep only a narrow gravel seam
	## beside the road; inheriting SaisiesRoute's broad route-space grass ribbon
	## would overlay the geographic DEM across bends and hairpins.
	var shoulder_st := SurfaceTool.new()
	shoulder_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(_samples.size() - 1):
		var s0 := minf(float(i) * sample_spacing_m, length_m)
		var s1 := minf(float(i + 1) * sample_spacing_m, length_m)
		var half0 := road_width_at(s0) * 0.5
		var half1 := road_width_at(s1) * 0.5
		for side in [-1.0, 1.0]:
			var in0: float = side * (half0 + 0.03)
			var out0: float = side * (half0 + GEO_SHOULDER_WIDTH_M)
			var in1: float = side * (half1 + 0.03)
			var out1: float = side * (half1 + GEO_SHOULDER_WIDTH_M)
			if side < 0.0:
				_add_quad(shoulder_st, _road_point(s0, out0), _road_point(s0, in0), _road_point(s1, in1), _road_point(s1, out1), Vector2(0.0, s0 * 0.12), Vector2(1.0, s1 * 0.12))
			else:
				_add_quad(shoulder_st, _road_point(s0, in0), _road_point(s0, out0), _road_point(s1, out1), _road_point(s1, in1), Vector2(0.0, s0 * 0.12), Vector2(1.0, s1 * 0.12))
	shoulder_st.generate_normals()
	_shoulder_mesh = MeshInstance3D.new()
	_shoulder_mesh.name = "SaisiesGeoGravelShoulders"
	_shoulder_mesh.mesh = shoulder_st.commit()
	_shoulder_mesh.material_override = _shoulder_material()
	add_child(_shoulder_mesh)
	_terrain_mesh = null
