extends SceneTree

const GeographyScript = preload("res://scripts/saisies_geography.gd")
const GeoLandscapeScript = preload("res://scripts/saisies_geo_landscape.gd")

## Headless contract and geometry verification for the independent geography
## staging scene. This does not compare rendered pixels; root owns native GPU
## captures and visual acceptance.

const GEO_SCENE := "res://scenes/MainScene_saisies_geo.tscn"
const FRAME := {
	"origin_lat": 45.72,
	"origin_lon": 6.57,
	"forward_east": 0.0,
	"forward_north": 1.0,
	"right_east": 1.0,
	"right_north": 0.0
}

var _errors: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var geography = GeographyScript.new()
	# This verifier intentionally exercises an independent coarse frame.  The
	# production nearfield contract is tied to the canonical route datum, so a
	# coarse-only audit must opt out explicitly rather than weakening that check.
	if not geography.configure(FRAME, false):
		_fail("geography configure failed")
	else:
		_verify_geography(geography)
		_verify_local_road_blend(geography)
	await _verify_scene_and_mesh()
	if _errors.is_empty():
		print("SAISIES GEOGRAPHY VERIFY PASS")
		quit(0)
	else:
		print("SAISIES GEOGRAPHY VERIFY FAIL (%d errors)" % _errors.size())
		quit(1)

func _verify_geography(geography) -> void:
	var grid = geography.height_grid()
	if grid != 769:
		_fail("DEM grid is %d, expected 769" % grid)
	if geography.map_size_m() < 23900.0 or geography.map_size_m() > 24100.0:
		_fail("DEM nominal size is %.2f m" % geography.map_size_m())
	var centre = geography.world_from_latlon(45.72, 6.57)
	if Vector2(centre.x, centre.z).length() > 0.01 or absf(centre.y) > 0.01:
		_fail("centre origin does not map to world zero: %s" % centre)
	var north = geography.world_from_latlon(45.73, 6.57)
	var east = geography.world_from_latlon(45.72, 6.58)
	if north.z >= centre.z:
		_fail("north latitude does not map forward (negative world Z): centre=%s north=%s" % [centre, north])
	if east.x <= centre.x:
		_fail("east longitude does not map right (positive world X): centre=%s east=%s" % [centre, east])
	var centre_roundtrip = geography.latlon_from_world(Vector2.ZERO)
	if centre_roundtrip.distance_to(Vector2(45.72, 6.57)) > 0.000001:
		_fail("centre lat/lon roundtrip is %s" % centre_roundtrip)
	var centre_uv = geography.uv_world(Vector2.ZERO)
	if centre_uv.distance_to(Vector2(0.5, 0.5)) > 0.00001:
		_fail("centre UV is %s, expected 0.5/0.5" % centre_uv)
	var bounds = geography.metadata.get("bounds_wgs84", {})
	var corners := [
		Vector2(float(bounds["north"]), float(bounds["west"])),
		Vector2(float(bounds["north"]), float(bounds["east"])),
		Vector2(float(bounds["south"]), float(bounds["west"])),
		Vector2(float(bounds["south"]), float(bounds["east"]))
	]
	for corner in corners:
		var world = geography.world_from_latlon(corner.x, corner.y)
		var back = geography.latlon_from_world(Vector2(world.x, world.z))
		if back.distance_to(corner) > 0.000001:
			_fail("corner roundtrip %.8f %.8f -> %s" % [corner.x, corner.y, back])
	var min_height := INF
	var max_height := -INF
	for uv in [Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(0.5, 0.5)]:
		var world = geography.world_from_uv(uv)
		if not is_finite(world.y):
			_fail("non-finite DEM height at UV %s" % uv)
		var sampled_back = geography.raw_height_world(Vector2(world.x, world.z))
		if absf(sampled_back - world.y) > 0.01:
			_fail("world/UV height orientation mismatch at %s: %.3f vs %.3f" % [uv, sampled_back, world.y])
		min_height = minf(min_height, world.y)
		max_height = maxf(max_height, world.y)
	var expected_range = float(geography.metadata["height"]["max_m"]) - float(geography.metadata["height"]["min_m"])
	if max_height - min_height < 0.1 or expected_range < 100.0:
		_fail("DEM height range is too small: %.2f / metadata %.2f" % [max_height - min_height, expected_range])
	print("geography frame origin=(%.7f,%.7f) datum=%.3f grid=%d map=%.1fm uv_center=%s height_sample_range=%.1f" % [
		geography.origin_lat, geography.origin_lon, geography.datum_m, grid, geography.map_size_m(), centre_uv, max_height - min_height])

func _verify_local_road_blend(geography) -> void:
	var points := PackedVector3Array()
	for i in range(5):
		var z := -120.0 + float(i) * 60.0
		var xz := Vector2(0.0, z)
		var road_y = geography.raw_height_world(xz) + 3.0
		points.append(Vector3(xz.x, road_y, xz.y))
	geography.set_route_samples(points, 25.0)
	var on_road = geography.height_world(Vector2.ZERO)
	if absf(on_road - points[2].y) > 0.02:
		_fail("road blend does not meet centerline: %.3f vs %.3f" % [on_road, points[2].y])
	var outside = geography.height_world(Vector2(200.0, 0.0))
	var raw_outside = geography.raw_height_world(Vector2(200.0, 0.0))
	if absf(outside - raw_outside) > 0.001:
		_fail("height_world changes terrain outside local road seam: %.3f vs %.3f" % [outside, raw_outside])
	var seam = geography.height_world(Vector2(15.0, 0.0))
	if absf(seam - raw_outside) < 0.0001 and absf(geography.raw_height_world(Vector2(15.0, 0.0)) - raw_outside) < 0.0001:
		_fail("road seam sample did not exercise local blend")
	print("local road blend: center=%.3f seam15=%.3f raw_outside=%.3f" % [on_road, seam, raw_outside])

func _verify_scene_and_mesh() -> void:
	var packed := load(GEO_SCENE) as PackedScene
	if packed == null:
		_fail("geographic scene could not be loaded")
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	await process_frame
	var route := scene.get_node_or_null("Route")
	var landscape = scene.get_node_or_null("Landscape")
	var camera_rig = scene.get_node_or_null("CameraRig")
	if route == null:
		_fail("Route node is missing")
	if landscape == null:
		_fail("Landscape node is missing")
	if camera_rig == null:
		_fail("CameraRig node is missing")
	if landscape == null or not landscape.landscape_ready:
		_fail("Landscape did not become ready")
	else:
		_verify_mesh(landscape)
		if route != null and route.has_method("route_ready") and bool(route.call("route_ready")):
			_verify_road_clearance(route, landscape)
	if route != null and route.has_method("route_ready") and not bool(route.call("route_ready")):
		_fail("Route did not become ready")
	if route != null and route.has_method("route_ready") and bool(route.call("route_ready")):
		print("geo scene route ready length=%.1f" % float(route.get("length_m")))
	scene.queue_free()

func _verify_mesh(landscape) -> void:
	var node := landscape.get_node_or_null("SaisiesGeoTerrain") as MeshInstance3D
	if node == null or node.mesh == null:
		_fail("SaisiesGeoTerrain mesh is missing")
		return
	var arrays := node.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var expected_vertices := 769 * 769
	var expected_triangles := 768 * 768 * 2
	if vertices.size() < expected_vertices:
		_fail("terrain has %d vertices, below base grid %d" % [vertices.size(), expected_vertices])
	if indices.size() / 3 < expected_triangles:
		_fail("terrain has %d triangles, below base grid %d" % [indices.size() / 3, expected_triangles])
	if normals.size() != vertices.size() or uvs.size() != vertices.size():
		_fail("terrain attribute counts do not match vertices")
	var upward := 0
	var uv_min := Vector2(INF, INF)
	var uv_max := Vector2(-INF, -INF)
	for i in range(vertices.size()):
		if normals[i].y > 0.001:
			upward += 1
		uv_min.x = minf(uv_min.x, uvs[i].x)
		uv_min.y = minf(uv_min.y, uvs[i].y)
		uv_max.x = maxf(uv_max.x, uvs[i].x)
		uv_max.y = maxf(uv_max.y, uvs[i].y)
	if upward != normals.size():
		_fail("terrain has %d/%d upward normals" % [upward, normals.size()])
	if uv_min.x < -0.00001 or uv_min.y < -0.00001 or uv_max.x > 1.00001 or uv_max.y > 1.00001:
		_fail("terrain UVs leave [0,1]: %s..%s" % [uv_min, uv_max])
	var front_faces := 0
	for face_start in range(0, indices.size(), 3):
		var a := vertices[indices[face_start]]
		var b := vertices[indices[face_start + 1]]
		var c := vertices[indices[face_start + 2]]
		if (b - a).cross(c - a).y < -0.001:
			front_faces += 1
	if front_faces != indices.size() / 3:
		_fail("terrain has %d/%d clockwise front faces" % [front_faces, indices.size() / 3])
	var bounds = landscape.terrain_bounds()
	if bounds.size.x < 20000.0 or bounds.size.z < 20000.0:
		_fail("terrain bounds are too small: %s" % bounds)
	var old_caps = landscape.find_children("SaisiesStatic*")
	if not old_caps.is_empty():
		_fail("geo landscape contains old static cap nodes: %s" % old_caps)
	print("geo mesh: base_grid=%d refined_cells=%d vertices=%d triangles=%d bounds=%s front_faces=%d/%d lighting_normals=%d/%d uv=%s..%s build_ms=%.1f rough_bytes=%d" % [
		int(landscape.get_meta("saisies_geo_landscape_grid_size", 0)),
		int(landscape.get_meta("saisies_geo_landscape_refined_cell_count", 0)),
		vertices.size(), indices.size() / 3, bounds, front_faces, indices.size() / 3, upward, normals.size(), uv_min, uv_max,
		float(landscape.get_meta("saisies_geo_landscape_build_ms", -1.0)),
		int(landscape.get_meta("saisies_geo_landscape_rough_bytes", 0))])

func _verify_road_clearance(route, landscape) -> void:
	if not route.has_method("pos_at") or not route.has_method("left_at"):
		_fail("Route has no centerline API for terrain clearance")
		return
	if not landscape.has_method("sample_mesh_triangle"):
		_fail("Landscape lacks actual mesh triangle sampler for road clearance")
		return
	var asphalt := route.get_node_or_null("SaisiesAsphalt") as MeshInstance3D
	if asphalt == null or asphalt.mesh == null:
		_fail("Route asphalt mesh is missing for actual road clearance")
		return
	var road_faces: PackedVector3Array = asphalt.mesh.get_faces()
	var road_segment_count := road_faces.size() / 6
	if road_segment_count < 2:
		_fail("Route asphalt mesh has too few segments: %d" % road_segment_count)
		return
	var length_m := float(route.get("length_m"))
	var sample_step_m := 2.5
	var sample_count := maxi(int(ceil((length_m - 0.25) / sample_step_m)), 1)
	var checked_count := 0
	var missing_road_count := 0
	var missing_terrain_count := 0
	var over_count := 0
	var max_over := -INF
	var worst_s := 0.0
	var worst_u := 0.0
	var worst_query := Vector2.ZERO
	var worst_road_y := 0.0
	var worst_triangle := -1
	var worst_cell := Vector2i.ZERO
	for i in range(sample_count):
		var s := minf(0.25 + float(i) * sample_step_m, length_m - 0.001)
		var centre: Vector3 = route.call("pos_at", s)
		var left: Vector3 = route.call("left_at", s)
		var half_width := float(route.call("road_width_at", s)) * 0.5
		for u in [-half_width + 0.1, -half_width * 0.5, 0.0, half_width * 0.5, half_width - 0.1]:
			var query := centre + left * float(u)
			var road_sample := _sample_road_triangle(Vector2(query.x, query.z), s, route, road_faces, road_segment_count)
			if road_sample.is_empty():
				missing_road_count += 1
				continue
			var road_y := float(road_sample.get("height", NAN))
			var mesh_sample: Dictionary = landscape.sample_mesh_triangle(Vector2(query.x, query.z))
			if mesh_sample.is_empty():
				missing_terrain_count += 1
				continue
			var terrain_y := float(mesh_sample.get("height", NAN))
			if not is_finite(terrain_y):
				missing_terrain_count += 1
				continue
			checked_count += 1
			var over := terrain_y - road_y
			if over > max_over:
				max_over = over
				worst_s = s
				worst_u = float(u)
				worst_query = Vector2(query.x, query.z)
				worst_road_y = road_y
				worst_triangle = int(mesh_sample.get("triangle_start", -1))
				worst_cell = mesh_sample.get("cell", Vector2i.ZERO)
			if over > -0.005:
				over_count += 1
	print("road clearance actual mesh: samples=%d checked=%d missing_road=%d missing_terrain=%d over_minus_0.005m=%d max_terrain_minus_road=%.3fm at s=%.2f u=%.2f" % [sample_count * 5, checked_count, missing_road_count, missing_terrain_count, over_count, max_over, worst_s, worst_u])
	if over_count > 0:
		var worst_sample: Dictionary = landscape.sample_mesh_triangle(worst_query)
		var a: Vector3 = worst_sample.get("a", Vector3.ZERO)
		var b: Vector3 = worst_sample.get("b", Vector3.ZERO)
		var c: Vector3 = worst_sample.get("c", Vector3.ZERO)
		var road_detail := _sample_road_triangle(worst_query, worst_s, route, road_faces, road_segment_count)
		print("road clearance detail query=(%.2f,%.2f) road_y=%.2f road_segment=%d terrain_triangle_start=%d coarse_cell=%s bary=%s terrain_a=%s terrain_b=%s terrain_c=%s asphalt_a=%s asphalt_b=%s asphalt_c=%s" % [worst_query.x, worst_query.y, worst_road_y, int(road_detail.get("segment", -1)), worst_triangle, worst_cell, worst_sample.get("barycentric", Vector3.ZERO), a, b, c, road_detail.get("a", Vector3.ZERO), road_detail.get("b", Vector3.ZERO), road_detail.get("c", Vector3.ZERO)])
	if checked_count == 0:
		_fail("road clearance samples did not intersect actual asphalt triangles")
		return
	if missing_terrain_count > 0:
		_fail("actual road samples are outside the DEM mesh at %d points" % missing_terrain_count)
	if over_count > 0:
		_fail("terrain covers actual road at %d samples; max terrain-road=%.3fm at s=%.2f u=%.2f" % [over_count, max_over, worst_s, worst_u])

func _sample_road_triangle(query: Vector2, s: float, route, road_faces: PackedVector3Array, segment_count: int) -> Dictionary:
	var spacing := maxf(float(route.get("sample_spacing_m")), 0.001)
	var segment := clampi(int(floor(s / spacing)), 0, segment_count - 1)
	for candidate in range(maxi(segment - 2, 0), mini(segment + 3, segment_count)):
		for triangle in range(2):
			var start := candidate * 6 + triangle * 3
			var a := road_faces[start]
			var b := road_faces[start + 1]
			var c := road_faces[start + 2]
			var weights := _barycentric_xz(query, a, b, c)
			if weights.x < -0.5:
				continue
			return {
				"height": a.y * weights.x + b.y * weights.y + c.y * weights.z,
				"segment": candidate,
				"triangle": triangle,
				"barycentric": weights,
				"a": a,
				"b": b,
				"c": c
			}
	return {}

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

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES GEOGRAPHY: " + message)
