extends SceneTree

## Focused headless contract for the narrow geographic roadbed seam.
##
## The DEM terrain is checked separately by verify_saisies_geography.gd.  This
## verifier checks the actual roadbed ArrayMesh: every outer edge is grounded
## by Landscape.sample_mesh_triangle(), every inner edge is sunk below the
## route asphalt, and the two endpoint rows are continuous along both sides.

const ROUTE_SCRIPT_PATH := "res://scripts/saisies_geo_route.gd"
const ROUTE_FILE := "res://data/saisies_geo_route.json"
const LANDSCAPE_SCRIPT_PATH := "res://scripts/saisies_geo_landscape.gd"
const ROADBED_SCRIPT_PATH := "res://scripts/saisies_geo_roadbed.gd"
const EXPECTED_GRID := 769
const EPSILON_M := 0.01

var _errors: Array[String] = []
var _route
var _landscape
var _roadbed

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var route_script := load(ROUTE_SCRIPT_PATH) as Script
	var landscape_script := load(LANDSCAPE_SCRIPT_PATH) as Script
	var roadbed_script := load(ROADBED_SCRIPT_PATH) as Script
	if route_script == null or landscape_script == null or roadbed_script == null:
		_fail("could not load route, landscape, or roadbed scripts")
		_finish()
		return
	_route = route_script.new()
	_route.name = "SaisiesGeoRouteRoadbedVerify"
	_route.geo_route_file = ROUTE_FILE
	get_root().add_child(_route)
	if not await _wait_for_route(240):
		_fail("geographic route did not become ready")
		_finish()
		return
	_landscape = landscape_script.new()
	_landscape.name = "SaisiesGeoLandscapeRoadbedVerify"
	_landscape.route = _route
	_landscape.build_grid_size = EXPECTED_GRID
	_landscape.route_sample_step_m = 20.0
	get_root().add_child(_landscape)
	if not await _wait_for_property(_landscape, "landscape_ready", true, 240):
		_fail("geographic DEM landscape did not become ready")
		_finish()
		return
	_roadbed = roadbed_script.new()
	_roadbed.name = "SaisiesGeoRoadbedVerify"
	_roadbed.route = _route
	_roadbed.landscape = _landscape
	_roadbed.skirt_width_m = 4.0
	_roadbed.edge_offset_m = 0.05
	get_root().add_child(_roadbed)
	if not await _wait_for_property(_roadbed, "roadbed_ready", true, 120):
		_fail("roadbed did not become ready")
	else:
		_verify_mesh()
	if _errors.is_empty():
		print("SAISIES GEO ROADBED VERIFY PASS")
	else:
		print("SAISIES GEO ROADBED VERIFY FAIL errors=%d" % _errors.size())
	_finish()

func _wait_for_route(frames: int) -> bool:
	for _index in range(frames):
		await process_frame
		if _route != null and _route.has_method("route_ready") and bool(_route.call("route_ready")):
			return true
	return false

func _wait_for_property(node: Object, property_name: String, expected: bool, frames: int) -> bool:
	for _index in range(frames):
		await process_frame
		if node.get(property_name) == expected:
			return true
	return false

func _verify_mesh() -> void:
	if _roadbed == null or not bool(_roadbed.get_meta("saisies_geo_roadbed_ready", false)):
		_fail("roadbed ready metadata is missing")
		return
	var mesh_instance: MeshInstance3D = null
	for child in _roadbed.get_children():
		if child is MeshInstance3D and child.mesh != null:
			mesh_instance = child
			break
	if mesh_instance == null:
		_fail("roadbed mesh instance is missing")
		return
	var arrays := mesh_instance.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var strip_count := int(_roadbed.get_meta("saisies_geo_roadbed_strip_count", 0))
	if strip_count <= 0 or vertices.size() != strip_count * 4 or indices.size() != strip_count * 6:
		_fail("roadbed topology metadata mismatch strips=%d vertices=%d indices=%d" % [strip_count, vertices.size(), indices.size()])
		return
	if normals.size() != vertices.size() or uvs.size() != vertices.size():
		_fail("roadbed attributes do not match vertices")
	var front_faces := 0
	for face_start in range(0, indices.size(), 3):
		var a: Vector3 = vertices[indices[face_start]]
		var b: Vector3 = vertices[indices[face_start + 1]]
		var c: Vector3 = vertices[indices[face_start + 2]]
		if (b - a).cross(c - a).y < -0.001:
			front_faces += 1
	if front_faces != indices.size() / 3:
		_fail("roadbed front winding is %d/%d clockwise faces" % [front_faces, indices.size() / 3])
	var upward_normals := 0
	for normal in normals:
		if normal.y > 0.001:
			upward_normals += 1
	if upward_normals != normals.size():
		_fail("roadbed lighting normals are %d/%d upward" % [upward_normals, normals.size()])
	var outer_checks := 0
	var inner_checks := 0
	var continuity_checks := 0
	var max_outer_error := 0.0
	var max_inner_error := 0.0
	var max_inner_above_road := -INF
	var max_continuity_error := 0.0
	var min_gap := INF
	var max_gap := -INF
	var previous_inner: Dictionary = {}
	var previous_outer: Dictionary = {}
	for strip_index in range(strip_count):
		var base := strip_index * 4
		var inner0: Vector3 = vertices[base]
		var outer0: Vector3 = vertices[base + 1]
		var inner1: Vector3 = vertices[base + 2]
		var outer1: Vector3 = vertices[base + 3]
		var side := 1.0 if strip_index % 2 == 1 else -1.0
		var s0 := uvs[base].y / 0.04
		var s1 := uvs[base + 2].y / 0.04
		for sample in [{"inner": inner0, "outer": outer0, "s": s0}, {"inner": inner1, "outer": outer1, "s": s1}]:
			var inner: Vector3 = sample["inner"]
			var outer: Vector3 = sample["outer"]
			var s := clampf(float(sample["s"]), 0.0, float(_route.get("length_m")))
			var expected = _landscape.call("sample_mesh_triangle", Vector2(outer.x, outer.z))
			if not (expected is Dictionary) or not expected.has("height"):
				_fail("roadbed outer endpoint is outside actual landscape mesh at s=%.2f" % s)
			else:
				var outer_error := absf(outer.y - float(expected["height"]))
				max_outer_error = maxf(max_outer_error, outer_error)
				outer_checks += 1
			var centre: Vector3 = _route.call("pos_at", s)
			var left: Vector3 = _route.call("left_at", s)
			var half := float(_route.call("road_width_at", s)) * 0.5
			var expected_road := float(_route.call("_road_y", s, side * half))
			var inner_error := absf(inner.y - (expected_road - 0.03))
			max_inner_error = maxf(max_inner_error, inner_error)
			max_inner_above_road = maxf(max_inner_above_road, inner.y - expected_road)
			inner_checks += 1
			var lateral_error := absf((Vector2(inner.x - centre.x, inner.z - centre.z).dot(Vector2(left.x, left.z))) - side * (half + 0.05))
			if lateral_error > 0.05:
				_fail("roadbed inner endpoint left route edge by %.3f m at s=%.2f" % [lateral_error, s])
			var gap := expected_road - float(expected.get("height", outer.y)) if expected is Dictionary else expected_road - outer.y
			min_gap = minf(min_gap, gap)
			max_gap = maxf(max_gap, gap)
		var segment_index := int(floor(float(strip_index) / 2.0))
		var side_key := 1 if side > 0.0 else -1
		var key := "%d:%d" % [segment_index, side_key]
		var previous_key := "%d:%d" % [segment_index - 1, side_key]
		if previous_inner.has(previous_key):
			var continuity := maxf(inner0.distance_to(previous_inner[previous_key]), outer0.distance_to(previous_outer[previous_key]))
			max_continuity_error = maxf(max_continuity_error, continuity)
			continuity_checks += 1
		previous_inner[key] = inner1
		previous_outer[key] = outer1
	if max_outer_error > EPSILON_M:
		_fail("roadbed outer endpoints disagree with actual terrain by %.4f m" % max_outer_error)
	if max_inner_error > EPSILON_M:
		_fail("roadbed inner endpoints disagree with route asphalt by %.4f m" % max_inner_error)
	if max_inner_above_road > -0.02:
		_fail("roadbed inner edge is not below asphalt: max=%.4f m" % max_inner_above_road)
	if continuity_checks <= 0:
		_fail("roadbed continuity checks did not run")
	if max_continuity_error > EPSILON_M:
		_fail("roadbed has endpoint discontinuity %.4f m" % max_continuity_error)
	print("roadbed mesh: strips=%d triangles=%d front_faces=%d/%d upward_normals=%d/%d outer_checks=%d max_outer_error=%.4fm inner_checks=%d max_inner_error=%.4fm max_inner_above_road=%.4fm continuity_checks=%d max_continuity_error=%.4fm gap_range=%.3f..%.3fm" % [strip_count, indices.size() / 3, front_faces, indices.size() / 3, upward_normals, normals.size(), outer_checks, max_outer_error, inner_checks, max_inner_error, max_inner_above_road, continuity_checks, max_continuity_error, min_gap, max_gap])

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES GEO ROADBED: " + message)

func _finish() -> void:
	quit(0 if _errors.is_empty() else 1)
