extends SceneTree

## Headless contract for optional 65x65 RGE nearfield patches.
##
## This verifier keeps the coarse DEM as an audit baseline, checks independent
## bilinear midpoints and the 64 m blend edge, then samples the built terrain
## against actual asphalt faces. It does not classify RGE as GPS or validate
## video-time station calibration.

const GeographyScript = preload("res://scripts/saisies_geography.gd")
const RouteScript = preload("res://scripts/saisies_geo_route.gd")
const LandscapeScript = preload("res://scripts/saisies_geo_landscape.gd")
const ROUTE_FILE := "res://data/saisies_geo_route.json"
const DEFAULT_PATCH_FILE := "res://data/saisies_geo_nearfield.json"
const FRAME := {
	"origin_lat": 45.7577436,
	"origin_lon": 6.5378919,
	"forward_east": 0.8666664347379797,
	"forward_north": -0.4988880544757101,
	"right_east": -0.4988880544757101,
	"right_north": -0.8666664347379797
}
const MAX_CLEARANCE_OVER_M := 0.005
const WORLD_HEIGHT_ROUNDTRIP_TOLERANCE_M := 0.1

var _errors: Array[String] = []
var _warnings: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var geography := GeographyScript.new()
	if not geography.configure(FRAME):
		_fail("coarse geography failed to configure: %s" % geography.nearfield_error)
	else:
		if "--rejection-only" in OS.get_cmdline_args():
			_verify_rejection_contract()
		else:
			_verify_patch_contract(geography)
			_verify_mapping_and_datum(geography)
			await _verify_actual_mesh_clearance(geography)
	if _errors.is_empty():
		print("SAISIES NEARFIELD REJECTION PASS" if "--rejection-only" in OS.get_cmdline_args() else "SAISIES NEARFIELD VERIFY PASS")
	else:
		print("SAISIES NEARFIELD VERIFY FAIL errors=%d" % _errors.size())
	for warning in _warnings:
		print("SAISIES NEARFIELD WARNING: " + warning)
	quit(0 if _errors.is_empty() else 1)

func _verify_rejection_contract() -> void:
	var missing_frame := FRAME.duplicate(true)
	missing_frame["nearfield_file"] = "/tmp/luna_saisies_r9_missing_nearfield.json"
	var missing_helper := GeographyScript.new()
	if missing_helper.configure(missing_frame):
		_fail("explicitly missing nearfield file was accepted")
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(DEFAULT_PATCH_FILE))
	if not (parsed is Dictionary) or not (parsed.get("patches", []) is Array) or parsed["patches"].is_empty():
		_fail("could not read positive nearfield metadata for rejection fixtures")
		return
	var bad_dimensions_path := "/tmp/luna_saisies_r9_bad_dimensions.json"
	var bad_dimensions: Dictionary = parsed.duplicate(true)
	var dimension_patch: Dictionary = bad_dimensions["patches"][0]
	dimension_patch["grid"] = 64
	var bad_dimensions_file := FileAccess.open(bad_dimensions_path, FileAccess.WRITE)
	if bad_dimensions_file == null:
		_fail("could not create invalid nearfield dimension fixture")
		return
	bad_dimensions_file.store_string(JSON.stringify(bad_dimensions))
	bad_dimensions_file.close()
	var bad_frame := FRAME.duplicate(true)
	bad_frame["nearfield_file"] = bad_dimensions_path
	var bad_helper := GeographyScript.new()
	if bad_helper.configure(bad_frame):
		_fail("invalid nearfield dimensions were accepted")
	DirAccess.remove_absolute(bad_dimensions_path)
	var bad_sha_path := "/tmp/luna_saisies_r9_bad_sha.json"
	var bad_sha: Dictionary = parsed.duplicate(true)
	var sha_patch: Dictionary = bad_sha["patches"][0]
	sha_patch["height_sha256"] = "0000000000000000000000000000000000000000000000000000000000000000"
	var bad_sha_file := FileAccess.open(bad_sha_path, FileAccess.WRITE)
	if bad_sha_file == null:
		_fail("could not create invalid nearfield SHA fixture")
		return
	bad_sha_file.store_string(JSON.stringify(bad_sha))
	bad_sha_file.close()
	var bad_sha_frame := FRAME.duplicate(true)
	bad_sha_frame["nearfield_file"] = bad_sha_path
	var bad_sha_helper := GeographyScript.new()
	if bad_sha_helper.configure(bad_sha_frame):
		_fail("invalid nearfield SHA was accepted")
	DirAccess.remove_absolute(bad_sha_path)

func _verify_patch_contract(geography) -> void:
	var patch_count := int(geography.nearfield_patch_count())
	if patch_count == 0:
		_warnings.append("optional nearfield file is absent; coarse-only audit completed")
		return
	var info: Array = geography.nearfield_patch_info()
	if info.size() != patch_count:
		_fail("nearfield patch info count %d differs from loaded count %d" % [info.size(), patch_count])
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(DEFAULT_PATCH_FILE))
	if not (parsed is Dictionary) or not (parsed.get("patches", []) is Array):
		_fail("loaded nearfield metadata cannot be independently read")
		return
	var patch_list: Array = parsed["patches"]
	if patch_list.size() != patch_count:
		_fail("metadata patch count differs from helper count")
	for index in range(mini(patch_list.size(), info.size())):
		var raw: Dictionary = patch_list[index]
		var patch_info: Dictionary = info[index]
		var origin := _raw_origin(raw)
		if not is_finite(origin.x) or not is_finite(origin.y):
			_fail("patch %d has a non-finite min_x/min_z origin" % index)
			continue
		var size_m := float(raw.get("max_x", NAN)) - float(raw.get("min_x", NAN))
		var spacing := float(raw.get("spacing_m", NAN))
		var grid := int(raw.get("grid", 0))
		var height_path := String(raw.get("height_file", ""))
		var bytes := FileAccess.get_file_as_bytes(_resource_path(height_path))
		if bytes.size() != grid * grid * 4:
			_fail("patch %s byte count %d differs from %d" % [String(patch_info.get("id", index)), bytes.size(), grid * grid * 4])
			continue
		var declared_sha := String(raw.get("height_sha256", "")).to_lower()
		if _sha256(bytes) != declared_sha:
			_fail("patch %s independent SHA-256 mismatch" % String(patch_info.get("id", index)))
		var heights := bytes.to_float32_array()
		if heights.size() != grid * grid:
			_fail("independent patch %d sample count mismatch" % index)
			continue
		var centre := origin + Vector2(size_m * 0.5, size_m * 0.5)
		var midpoint := origin + Vector2(spacing * 17.5, spacing * 29.25)
		for probe in [centre, midpoint]:
			var expected_asl := _bilinear(heights, grid, origin, spacing, probe)
			var actual_asl := float(geography.raw_height_asl_world(probe))
			if not is_finite(expected_asl) or not is_finite(actual_asl):
				_fail("patch %s produced a non-finite bilinear probe" % String(patch_info.get("id", index)))
				continue
			if absf(actual_asl - expected_asl) > 0.01:
				_fail("patch %s bilinear probe %s differs %.4f m" % [String(patch_info.get("id", index)), probe, actual_asl - expected_asl])
		var edge := origin + Vector2(0.0, size_m * 0.5)
		var coarse_edge := float(geography.raw_height_asl_world_coarse(edge))
		var actual_edge := float(geography.raw_height_asl_world(edge))
		if absf(actual_edge - coarse_edge) > 0.01:
			_fail("patch %s edge does not return to coarse DEM: %.4f m" % [String(patch_info.get("id", index)), actual_edge - coarse_edge])
		var inner_edge := origin + Vector2(float(patch_info.get("blend_margin_m", 64.0)), size_m * 0.5)
		var inner_expected := _bilinear(heights, grid, origin, spacing, inner_edge)
		var inner_actual := float(geography.raw_height_asl_world(inner_edge))
		if absf(inner_actual - inner_expected) > 0.01:
			_fail("patch %s blend reaches full patch value at margin: %.4f m" % [String(patch_info.get("id", index)), inner_actual - inner_expected])
		var before := origin + Vector2(-0.01, size_m * 0.5)
		var after := origin + Vector2(0.01, size_m * 0.5)
		var boundary_jump := absf(float(geography.raw_height_asl_world(after)) - float(geography.raw_height_asl_world(before)))
		if not is_finite(boundary_jump):
			_fail("patch %s blend edge is non-finite" % String(patch_info.get("id", index)))
		if boundary_jump > 0.25:
			_fail("patch %s blend edge has %.4f m discontinuity" % [String(patch_info.get("id", index)), boundary_jump])
		print("nearfield patch id=%s route_s=%.3f origin=%s grid=%d spacing=%.3f blend=%.3f centre_asl=%.3f" % [String(patch_info.get("id", index)), float(patch_info.get("route_s_m", NAN)), origin, grid, spacing, float(patch_info.get("blend_margin_m", NAN)), geography.raw_height_asl_world(centre)])

func _verify_mapping_and_datum(geography) -> void:
	var origin: Vector3 = geography.world_from_latlon(float(FRAME["origin_lat"]), float(FRAME["origin_lon"]))
	if Vector2(origin.x, origin.z).length() > 0.01:
		_fail("nearfield changed origin XY mapping: %s" % origin)
	var expected_datum := float(geography.raw_height_asl_world_coarse(Vector2.ZERO))
	if absf(float(geography.datum_m) - expected_datum) > 0.001:
		_fail("nearfield changed global datum: %.4f vs coarse %.4f" % [float(geography.datum_m), expected_datum])
	var north: Vector3 = geography.world_from_latlon(float(FRAME["origin_lat"]) + 0.001, float(FRAME["origin_lon"]))
	var east: Vector3 = geography.world_from_latlon(float(FRAME["origin_lat"]), float(FRAME["origin_lon"]) + 0.001)
	var north_back: Vector2 = geography.latlon_from_world(Vector2(north.x, north.z))
	var east_back: Vector2 = geography.latlon_from_world(Vector2(east.x, east.z))
	if north_back.distance_to(Vector2(float(FRAME["origin_lat"]) + 0.001, float(FRAME["origin_lon"]))) > 0.000001:
		_fail("north lat/lon endpoint roundtrip changed")
	if east_back.distance_to(Vector2(float(FRAME["origin_lat"]), float(FRAME["origin_lon"]) + 0.001)) > 0.000001:
		_fail("east lat/lon endpoint roundtrip changed")
	var bounds: Rect2 = geography.bounds_world()
	for patch_variant in geography.nearfield_patch_info():
		var patch: Dictionary = patch_variant
		var origin_world: Vector2 = patch["origin_world"]
		var size_m := float(patch["size_m"])
		var probes := [
			origin_world + Vector2(size_m * 0.5, size_m * 0.5),
			origin_world + Vector2(0.0, size_m * 0.5),
			origin_world - Vector2(128.0, 128.0)
		]
		for probe in probes:
			var latlon: Vector2 = geography.latlon_from_world(probe)
			var mapped: Vector3 = geography.world_from_latlon(latlon.x, latlon.y)
			var expected_y := float(geography.raw_height_world(probe))
			if not is_finite(mapped.y) or not is_finite(expected_y):
				_fail("world_from_latlon produced non-finite height for patch %s at %s" % [String(patch.get("id", "unknown")), probe])
			elif absf(mapped.y - expected_y) > WORLD_HEIGHT_ROUNDTRIP_TOLERANCE_M:
				_fail("world_from_latlon/raw_height_world mismatch for patch %s at %s: %.5f m" % [String(patch.get("id", "unknown")), probe, mapped.y - expected_y])
			elif absf(mapped.y - expected_y) > 0.001:
				print("nearfield world_from_latlon float32 roundtrip residual patch=%s probe=%s residual=%.5f m" % [String(patch.get("id", "unknown")), probe, mapped.y - expected_y])
		var outside := origin_world - Vector2(128.0, 128.0)
		if bounds.has_point(outside):
			var coarse := float(geography.raw_height_world_coarse(outside))
			var actual := float(geography.raw_height_world(outside))
			if not is_finite(coarse) or not is_finite(actual):
				_fail("outside-coarse probe is non-finite for patch %s" % String(patch.get("id", "unknown")))
			elif absf(actual - coarse) > 0.001:
				_fail("outside-coarse probe changed by %.4f m for patch %s" % [actual - coarse, String(patch.get("id", "unknown"))])

func _verify_actual_mesh_clearance(geography) -> void:
	var route := RouteScript.new()
	route.geo_route_file = ROUTE_FILE
	get_root().add_child(route)
	if not await _wait_for_route(route, 240):
		_fail("nearfield route did not become ready")
		return
	_print_patch_route_controls(route, geography)
	var landscape := LandscapeScript.new()
	landscape.route = route
	landscape.build_grid_size = 769
	landscape.route_sample_step_m = 20.0
	get_root().add_child(landscape)
	if not await _wait_for_property(landscape, "landscape_ready", true, 240):
		_fail("nearfield terrain did not become ready")
		return
	var asphalt := route.get_node_or_null("SaisiesAsphalt") as MeshInstance3D
	if asphalt == null or asphalt.mesh == null:
		_fail("nearfield clearance has no actual asphalt mesh")
		return
	var faces: PackedVector3Array = asphalt.mesh.get_faces()
	var segment_count := faces.size() / 6
	var checked := 0
	var missing := 0
	var over := 0
	var max_over := -INF
	var worst_s := 0.0
	var worst_u := 0.0
	var step := 10.0
	for i in range(int(ceil(float(route.get("length_m")) / step))):
		var s := minf(float(i) * step + 0.25, float(route.get("length_m")) - 0.001)
		var centre: Vector3 = route.call("pos_at", s)
		var left: Vector3 = route.call("left_at", s)
		var half := float(route.call("road_width_at", s)) * 0.5
		for u in [-half + 0.1, 0.0, half - 0.1]:
			var query := centre + left * float(u)
			var road_sample := _sample_road_face(Vector2(query.x, query.z), s, route, faces, segment_count)
			if road_sample.is_empty():
				missing += 1
				continue
			var terrain: Dictionary = landscape.sample_mesh_triangle(Vector2(query.x, query.z))
			if terrain.is_empty():
				_fail("actual terrain mesh missing at s=%.2f u=%.2f" % [s, u])
				continue
			var difference := float(terrain["height"]) - float(road_sample["height"])
			checked += 1
			if difference > max_over:
				max_over = difference
				worst_s = s
				worst_u = float(u)
			if difference > MAX_CLEARANCE_OVER_M:
				over += 1
	print("nearfield actual terrain-road clearance: checked=%d missing_road=%d over_%.3fm=%d max=%.3fm at s=%.2f u=%.2f patches=%d" % [checked, missing, MAX_CLEARANCE_OVER_M, over, max_over, worst_s, worst_u, geography.nearfield_patch_count()])
	if checked == 0:
		_fail("actual terrain-road clearance had no asphalt intersections")
	if over > 0:
		_fail("actual terrain covers road at %d samples; max=%.3f m" % [over, max_over])

func _print_patch_route_controls(route, geography) -> void:
	for patch_variant in geography.nearfield_patch_info():
		var patch: Dictionary = patch_variant
		var patch_id := String(patch.get("id", "unknown"))
		var origin: Vector2 = patch["origin_world"]
		var size_m := float(patch["size_m"])
		var centre := origin + Vector2(size_m * 0.5, size_m * 0.5)
		var centre_rge_asl := float(geography.raw_height_asl_world(centre))
		var centre_coarse_asl := float(geography.raw_height_asl_world_coarse(centre))
		var centre_s := clampf(float(patch.get("route_s_m", 0.0)), 0.0, float(route.get("length_m")))
		var route_centre: Vector3 = route.call("pos_at", centre_s)
		var road_asl := float(route_centre.y) + float(geography.datum_m)
		var road_rge_asl := float(geography.raw_height_asl_world(Vector2(route_centre.x, route_centre.z)))
		var residual_min := INF
		var residual_max := -INF
		var grade_min := INF
		var grade_max := -INF
		var sample_s := maxf(0.0, centre_s - size_m * 0.5)
		var end_s := minf(float(route.get("length_m")), centre_s + size_m * 0.5)
		while sample_s <= end_s + 0.001:
			var route_sample: Vector3 = route.call("pos_at", sample_s)
			var rge_asl := float(geography.raw_height_asl_world(Vector2(route_sample.x, route_sample.z)))
			var runtime_asl := float(route.call("elevation_at", sample_s))
			var residual := runtime_asl - rge_asl
			residual_min = minf(residual_min, residual)
			residual_max = maxf(residual_max, residual)
			var grade := float(route.call("grade_at", sample_s))
			grade_min = minf(grade_min, grade)
			grade_max = maxf(grade_max, grade)
			sample_s += 16.0
		print("nearfield route control id=%s center_s=%.2f core_rge_asl=%.3f core_coarse_asl=%.3f road_asl=%.3f road_minus_rge=%.3f road_minus_coarse=%.3f edge_grade_pct=%.3f..%.3f edge_runtime_minus_rge_m=%.3f..%.3f" % [patch_id, centre_s, centre_rge_asl, centre_coarse_asl, road_asl, road_asl - centre_rge_asl, road_asl - centre_coarse_asl, grade_min, grade_max, residual_min, residual_max])

func _sample_road_face(query: Vector2, s: float, route, faces: PackedVector3Array, segment_count: int) -> Dictionary:
	var spacing := maxf(float(route.get("sample_spacing_m")), 0.001)
	var segment := clampi(int(floor(s / spacing)), 0, segment_count - 1)
	for candidate in range(maxi(segment - 2, 0), mini(segment + 3, segment_count)):
		for triangle in range(2):
			var start := candidate * 6 + triangle * 3
			var a := faces[start]
			var b := faces[start + 1]
			var c := faces[start + 2]
			var weights := _barycentric_xz(query, a, b, c)
			if weights.x < -0.5:
				continue
			return {"height": a.y * weights.x + b.y * weights.y + c.y * weights.z}
	return {}

func _wait_for_route(route, frames: int) -> bool:
	for _index in range(frames):
		await process_frame
		if route.has_method("route_ready") and bool(route.call("route_ready")):
			return true
	return false

func _wait_for_property(node: Object, property_name: String, expected: bool, frames: int) -> bool:
	for _index in range(frames):
		await process_frame
		if node.get(property_name) == expected:
			return true
	return false

func _bilinear(heights: PackedFloat32Array, grid: int, origin: Vector2, spacing: float, xz: Vector2) -> float:
	var px := clampf((xz.x - origin.x) / spacing, 0.0, float(grid - 1))
	var pz := clampf((xz.y - origin.y) / spacing, 0.0, float(grid - 1))
	var x0 := clampi(int(floor(px)), 0, grid - 1)
	var z0 := clampi(int(floor(pz)), 0, grid - 1)
	var x1 := mini(x0 + 1, grid - 1)
	var z1 := mini(z0 + 1, grid - 1)
	var tx := px - float(x0)
	var tz := pz - float(z0)
	var north_left := lerpf(heights[z0 * grid + x0], heights[z0 * grid + x1], tx)
	var south_left := lerpf(heights[z1 * grid + x0], heights[z1 * grid + x1], tx)
	return lerpf(north_left, south_left, tz)

func _raw_origin(raw: Dictionary) -> Vector2:
	return Vector2(float(raw.get("min_x", NAN)), float(raw.get("min_z", NAN)))

func _resource_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("/"):
		return path
	return "res://" + path.trim_prefix("./")

func _barycentric_xz(point: Vector2, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 := Vector2(b.x - a.x, b.z - a.z)
	var v1 := Vector2(c.x - a.x, c.z - a.z)
	var v2 := point - Vector2(a.x, a.z)
	var denominator := v0.cross(v1)
	if absf(denominator) < 0.000001:
		return Vector3(-1.0, -1.0, -1.0)
	var weight_b := v2.cross(v1) / denominator
	var weight_c := v0.cross(v2) / denominator
	var weight_a := 1.0 - weight_b - weight_c
	if weight_a < -0.0001 or weight_b < -0.0001 or weight_c < -0.0001:
		return Vector3(-1.0, -1.0, -1.0)
	return Vector3(weight_a, weight_b, weight_c)

func _sha256(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	return hashing.finish().hex_encode()

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES NEARFIELD: " + message)
