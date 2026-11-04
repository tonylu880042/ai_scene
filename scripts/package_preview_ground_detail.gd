extends RefCounted
## Configurable, preview-only ground detail placement against authored terrain faces.
const RoadMask = preload("res://scripts/package_road_mask.gd")
static var _road_index_cache: Dictionary = {}
static var _terrain_index_cache: Dictionary = {}

static func add_procedural_short_grass(parent: Node3D, package_dir: String, package_tiles: Array, route: RefCounted, tile_id: String, config: Dictionary) -> Dictionary:
	var tile_ids: Array = config.get("tile_ids", [])
	if not tile_ids.has(tile_id): return {"instances": 0, "reason": "tile_not_selected"}
	var from_s := float(config.get("from_s", 0.0))
	var to_s := float(config.get("to_s", 0.0))
	var u_start := float(config.get("inner_lateral_m", 2.4))
	var u_stop := float(config.get("outer_lateral_m", 7.5))
	var clearance := maxf(float(config.get("road_clearance_m", 0.3)), 0.3)
	var footprint_radius := maxf(float(config.get("footprint_radius_m", 0.045)), 0.0)
	var mesh := _short_grass_cluster_mesh()
	var local_mesh_radius := _mesh_horizontal_radius(mesh)
	var max_scale := maxf(float(config.get("min_scale", 0.8)), float(config.get("max_scale", 1.25)))
	var actual_world_footprint := local_mesh_radius * max_scale
	if footprint_radius + 0.000001 < actual_world_footprint:
		return {"instances": 0, "reason": "configured_footprint_smaller_than_scaled_mesh", "mesh_radius_local_m": local_mesh_radius, "max_scale": max_scale, "required_footprint_radius_m": actual_world_footprint, "configured_footprint_radius_m": footprint_radius}
	var roi := _roi_bounds(route, from_s, to_s, u_start, u_stop, clearance + footprint_radius)
	var audit_started_ms := Time.get_ticks_msec()
	var tile_audit := {"manifest_tiles_screened": package_tiles.size(), "terrain": [], "road": [], "terrain_load_failures": [], "road_load_failures": []}
	var terrain_key := "%s|terrain|%s" % [package_dir, JSON.stringify([from_s,to_s,u_start,u_stop])]
	var terrain_cache_hit := _terrain_index_cache.has(terrain_key)
	if terrain_cache_hit:
		tile_audit.terrain = _terrain_index_cache[terrain_key].tiles
	else:
		var ground := _collect_package_triangles(package_dir, package_tiles, "terrain", roi, true, tile_audit.terrain, tile_audit.terrain_load_failures)
		if not tile_audit.terrain_load_failures.is_empty(): return {"instances": 0, "reason": "terrain_audit_load_failure", "tiles_checked": tile_audit}
		if ground.is_empty(): return {"instances": 0, "reason": "no_supported_terrain_ground_surface", "tiles_checked": tile_audit}
		_terrain_index_cache[terrain_key] = {"index": RoadMask.build_spatial_index(ground, 5.0), "triangles": ground.size(), "tiles": tile_audit.terrain.duplicate()}
	var road_key := "%s|all_manifest_roads" % package_dir
	var road_cache_hit := _road_index_cache.has(road_key)
	if road_cache_hit:
		tile_audit.road = _road_index_cache[road_key].tiles
	else:
		var road_triangles := _collect_package_triangles(package_dir, package_tiles, "road", roi, false, tile_audit.road, tile_audit.road_load_failures)
		if not tile_audit.road_load_failures.is_empty() or tile_audit.road.size() != package_tiles.size():
			return {"instances": 0, "reason": "incomplete_all_package_road_audit", "manifest_tiles_expected": package_tiles.size(), "road_tiles_loaded": tile_audit.road.size(), "tiles_checked": tile_audit}
		_road_index_cache[road_key] = {"index": RoadMask.build_spatial_index(road_triangles, 5.0), "triangles": road_triangles.size(), "tiles": tile_audit.road.duplicate()}
	var roads: Dictionary = _road_index_cache[road_key].index
	var ground_index: Dictionary = _terrain_index_cache[terrain_key].index
	var audit_build_ms := Time.get_ticks_msec() - audit_started_ms
	var route_height_tolerance := maxf(float(config.get("max_route_height_delta_m", 2.0)), 0.0)
	var seed := int(config.get("seed", 20))
	var target_density := maxf(float(config.get("target_density_per_m2", 14.0)), 0.1)
	var min_spacing := maxf(float(config.get("minimum_spacing_m", 0.18)), 0.05)
	var area_estimate := (to_s - from_s) * (u_stop - u_start)
	var target_count := maxi(1, roundi(area_estimate * target_density))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var placements: Array[Transform3D] = []
	var placed_xz: Array[Vector2] = []
	var unsupported := 0
	var ambiguous_support := 0
	var route_height_rejected := 0
	var road_rejected := 0
	var spacing_rejected := 0
	var attempts := 0
	while placements.size() < target_count and attempts < target_count * 12:
		attempts += 1
		var station := rng.randf_range(from_s, to_s)
		var lateral := rng.randf_range(u_start, u_stop)
		var center: Vector3 = route.position_at(station)
		var before: Vector3 = route.position_at(maxf(0.0, station - 0.25))
		var after: Vector3 = route.position_at(minf(route.length, station + 0.25))
		var forward := Vector2(after.x - before.x, after.z - before.z).normalized()
		var left := Vector2(forward.y, -forward.x)
		var xz := Vector2(center.x, center.z) + left * lateral
		var too_close := false
		for previous in placed_xz:
			if xz.distance_squared_to(previous) < min_spacing * min_spacing:
				too_close = true
				break
		if too_close:
			spacing_rejected += 1
			continue
		var sample := Vector3(xz.x, center.y, xz.y)
		var support := _ground_support(sample, ground_index, float(config.get("support_height_tolerance_m", 0.06)))
		if bool(support.ambiguous):
			ambiguous_support += 1
			continue
		if not is_finite(float(support.y)):
			unsupported += 1
			continue
		sample.y = float(support.y)
		if absf(sample.y - center.y) > route_height_tolerance:
			route_height_rejected += 1
			continue
		if _road_distance_xz(sample, roads, clearance + footprint_radius) < clearance + footprint_radius:
			road_rejected += 1
			continue
		var yaw := rng.randf_range(0.0, TAU)
		var scale_value := rng.randf_range(float(config.get("min_scale", 0.8)), float(config.get("max_scale", 1.25)))
		var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale_value)
		placements.append(Transform3D(basis, sample + Vector3.UP * 0.004))
		placed_xz.append(xz)
	if placements.is_empty(): return {"instances": 0, "reason": "no_supported_clear_placements", "unsupported": unsupported, "ambiguous_support": ambiguous_support, "route_height_rejected": route_height_rejected, "road_rejected": road_rejected, "spacing_rejected": spacing_rejected, "tiles_checked": tile_audit}
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 0.95
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	var instance := MultiMeshInstance3D.new()
	instance.name = "ConfiguredShortGrassPreview_%s" % tile_id
	instance.multimesh = MultiMesh.new()
	instance.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	instance.multimesh.mesh = mesh
	instance.multimesh.instance_count = placements.size()
	for index in range(placements.size()): instance.multimesh.set_instance_transform(index, placements[index])
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)
	return {"instances": placements.size(), "target_instances": target_count, "attempts": attempts, "spacing_rejected": spacing_rejected, "unsupported": unsupported, "ambiguous_support": ambiguous_support, "route_height_rejected": route_height_rejected, "road_rejected": road_rejected, "terrain_triangles": _terrain_index_cache[terrain_key].triangles, "road_triangles": roads.triangles.size(), "tiles_checked": tile_audit, "clearance_m_including_footprint": clearance + footprint_radius, "footprint_radius_m": footprint_radius, "mesh_radius_local_m": local_mesh_radius, "max_scale": max_scale, "scaled_mesh_radius_m": actual_world_footprint, "target_density_per_m2": target_density, "minimum_spacing_m": min_spacing, "area_m2_estimate": area_estimate, "audit_build_ms": audit_build_ms, "road_cache_hit": road_cache_hit, "terrain_cache_hit": terrain_cache_hit}

static func _roi_bounds(route: RefCounted, from_s: float, to_s: float, u_start: float, u_stop: float, padding: float) -> Rect2:
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	var station := from_s
	while station <= to_s:
		var center: Vector3 = route.position_at(station)
		var before: Vector3 = route.position_at(maxf(0.0, station - 0.25))
		var after: Vector3 = route.position_at(minf(route.length, station + 0.25))
		var forward := Vector2(after.x - before.x, after.z - before.z).normalized()
		var left := Vector2(forward.y, -forward.x)
		for lateral in [u_start - padding, u_stop + padding]:
			var point := Vector2(center.x, center.z) + left * float(lateral)
			minimum.x = minf(minimum.x, point.x)
			minimum.y = minf(minimum.y, point.y)
			maximum.x = maxf(maximum.x, point.x)
			maximum.y = maxf(maximum.y, point.y)
		station += 1.0
	return Rect2(minimum, maximum - minimum)

static func _collect_package_triangles(package_dir: String, tiles: Array, layer: String, roi: Rect2, ground_only: bool, checked_tiles: Array, failed_tiles: Array) -> Array:
	var result: Array = []
	for tile in tiles:
		var bound: Dictionary = tile.get("bounds", {})
		if layer != "road" and (not bound.has("min") or not bound.has("max")):
			failed_tiles.append({"tile": String(tile.get("id", "unknown")), "error": "manifest_missing_bounds_for_terrain_filter"})
			continue
		var overlaps_roi := true
		if layer != "road":
			var minimum: Array = bound.min
			var maximum: Array = bound.max
			overlaps_roi = not (float(minimum[0]) > roi.end.x or float(maximum[0]) < roi.position.x or float(minimum[2]) > roi.end.y or float(maximum[2]) < roi.position.y)
		if not tile.get("files", {}).has(layer):
			if layer == "road" or overlaps_roi: failed_tiles.append({"tile": String(tile.get("id", "unknown")), "error": "manifest_missing_%s" % layer})
			continue
		if layer != "road" and not overlaps_roi: continue
		var path: String = package_dir.path_join(tile.files[layer])
		if not FileAccess.file_exists(path):
			failed_tiles.append({"tile": String(tile.get("id", "unknown")), "path": path, "error": "missing_file"})
			continue
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		var flags := GLTFDocument.IMPORT_FLAG_FORCE_DISABLE_MESH_COMPRESSION if layer == "road" or layer == "terrain" else 0
		var load_error := document.append_from_file(path, state, flags)
		if load_error != OK:
			failed_tiles.append({"tile": String(tile.get("id", "unknown")), "path": path, "error": load_error})
			continue
		var root: Node3D = document.generate_scene(state)
		var triangles := _collect_triangles(root, ground_only)
		result.append_array(triangles)
		checked_tiles.append(String(tile.id))
		root.free()
	return result

static func _mesh_horizontal_radius(mesh: ArrayMesh) -> float:
	var radius := 0.0
	for surface in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vertex in vertices: radius = maxf(radius, Vector2(vertex.x, vertex.z).length())
	return radius

static func _collect_triangles(root: Node, ground_only: bool) -> Array:
	var result: Array = []
	var stack: Array = [{"node": root, "transform": Transform3D.IDENTITY}]
	while not stack.is_empty():
		var entry: Dictionary = stack.pop_back()
		var node: Node = entry.node
		var parent_transform: Transform3D = entry.transform
		var local_transform: Transform3D = Transform3D.IDENTITY
		if node is Node3D: local_transform = (node as Node3D).transform
		var node_transform: Transform3D = parent_transform * local_transform
		if node is MeshInstance3D and node.mesh != null:
			for surface in range(node.mesh.get_surface_count()):
				var material: Material = node.mesh.surface_get_material(surface)
				if ground_only and (material == null or material.resource_name != "terrain_ground"): continue
				if node.mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES: continue
				var arrays: Array = node.mesh.surface_get_arrays(surface)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var indices: PackedInt32Array = PackedInt32Array() if arrays[Mesh.ARRAY_INDEX] == null else arrays[Mesh.ARRAY_INDEX]
				var count := indices.size() if not indices.is_empty() else vertices.size()
				for i in range(0, count - 2, 3):
					var ia: int = indices[i] if not indices.is_empty() else i
					var ib: int = indices[i + 1] if not indices.is_empty() else i + 1
					var ic: int = indices[i + 2] if not indices.is_empty() else i + 2
					var tri: Array = [node_transform * vertices[ia], node_transform * vertices[ib], node_transform * vertices[ic]]
					if RoadMask.triangle_xz_area2(tri) == 0.0: continue
					var ta: Vector3 = tri[0]
					var tb: Vector3 = tri[1]
					var tc: Vector3 = tri[2]
					var normal: Vector3 = (tb - ta).cross(tc - ta).normalized()
					if absf(normal.y) > 0.75: result.append(tri)
		for child in node.get_children(): stack.append({"node": child, "transform": node_transform})
	return result

static func _ground_support(point: Vector3, index: Dictionary, height_tolerance: float) -> Dictionary:
	var query := [point + Vector3(-0.01,0.0,-0.01), point + Vector3(0.01,0.0,-0.01), point + Vector3(0.0,0.0,0.01)]
	var heights: Array[float] = []
	for tri in RoadMask.query_spatial_index(index, query):
		var weights: Vector3 = RoadMask.barycentric_xz(point, tri)
		if minf(weights.x, minf(weights.y, weights.z)) < -1e-5: continue
		var ta: Vector3 = tri[0]
		var tb: Vector3 = tri[1]
		var tc: Vector3 = tri[2]
		var y: float = ta.y * weights.x + tb.y * weights.y + tc.y * weights.z
		heights.append(y)
	if heights.is_empty(): return {"y": -INF, "ambiguous": false, "hit_count": 0}
	var minimum := INF
	var maximum := -INF
	var total := 0.0
	for y in heights:
		minimum = minf(minimum, y)
		maximum = maxf(maximum, y)
		total += y
	return {"y": total / float(heights.size()), "ambiguous": maximum - minimum > height_tolerance, "hit_count": heights.size(), "height_span_m": maximum - minimum}

static func _road_distance_xz(point: Vector3, index: Dictionary, search_radius: float) -> float:
	var query := [point + Vector3(-search_radius,0.0,-search_radius), point + Vector3(search_radius,0.0,-search_radius), point + Vector3(0.0,0.0,search_radius)]
	var best := INF
	for tri in RoadMask.query_spatial_index(index, query):
		var weights: Vector3 = RoadMask.barycentric_xz(point, tri)
		if minf(weights.x, minf(weights.y, weights.z)) >= -1e-6: return 0.0
		for edge in range(3):
			var a: Vector3 = tri[edge]
			var b: Vector3 = tri[(edge + 1) % 3]
			var segment := Vector2(b.x - a.x, b.z - a.z)
			var t := clampf(Vector2(point.x - a.x, point.z - a.z).dot(segment) / maxf(segment.length_squared(), 1e-9), 0.0, 1.0)
			best = minf(best, Vector2(point.x - (a.x + segment.x * t), point.z - (a.z + segment.y * t)).length())
	return best

static func _hash01(seed: int, s: float, u: float) -> float:
	return fposmod(sin(s * 17.17 + u * 31.91 + float(seed) * 7.13) * 43758.5453, 1.0)

static func _short_grass_cluster_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var colors := [Color(0.14,0.25,0.07), Color(0.16,0.28,0.08), Color(0.13,0.23,0.06), Color(0.17,0.29,0.09), Color(0.15,0.26,0.07), Color(0.12,0.22,0.05), Color(0.16,0.275,0.08), Color(0.135,0.24,0.06), Color(0.15,0.255,0.065), Color(0.13,0.235,0.055), Color(0.17,0.28,0.085), Color(0.145,0.245,0.06)]
	var angles := [0.0, 0.48, 1.03, 1.61, 2.12, 2.73, 3.18, 3.71, 4.24, 4.72, 5.26, 5.74]
	var heights := [0.022,0.028,0.035,0.043,0.03,0.039,0.025,0.046,0.032,0.04,0.027,0.036]
	for blade in range(12):
		var angle: float = angles[blade]
		var direction := Vector3(cos(angle),0.0,sin(angle))
		var side := Vector3(-direction.z,0.0,direction.x)
		var height: float = heights[blade]
		var width := 0.022 + float(blade % 3) * 0.006
		var lean := direction * (0.014 + 0.007 * float(blade % 2))
		var base := direction * (0.008 * float(blade % 2))
		var points := [base - side * width * 0.5, base + side * width * 0.5, base + lean * 0.45 + Vector3.UP * height * 0.48 + side * width * 0.28, base + lean * 0.45 + Vector3.UP * height * 0.48 - side * width * 0.28, base + lean + Vector3.UP * height, base + lean + Vector3.UP * height]
		var indices := [0,1,2, 1,3,2, 2,3,4]
		for index in indices:
			st.set_color(colors[blade])
			st.set_normal(Vector3.UP)
			st.add_vertex(points[index])
			# Double-sided copy, so the narrow blade stays visible from both sides.
		for index in [0,2,1,1,2,3,2,4,3]:
			st.set_color(colors[blade])
			st.set_normal(Vector3.UP)
			st.add_vertex(points[index])
	return st.commit()

# Default preview grass: tufts sampled area-weighted on terrain_ground faces near the route, denser by the
# path, bucketed into cells that are distance-culled. Terrain starts at the P0 road edge; P2 context streets
# (roadside.glb, draped on the terrain) are excluded explicitly.
# ponytail: GDScript sampling on tile load (~10^4-10^5 tufts per tile); move to a GPU particle/compute field if streaming hitches.
const GRASS_CELL_M := 24.0
const GRASS_VISIBLE_M := 40.0
const GRASS_MAX_LATERAL_M := 26.0
const GRASS_NEAR_DENSITY := 28.0  # tufts / m2 within 4 m of the route
const GRASS_FAR_DENSITY := 4.0
static var _tuft_mesh: ArrayMesh
static var _tuft_material: StandardMaterial3D

static func add_terrain_grass(holder: Node3D, terrain_root: Node, route: RefCounted, from_s: float, to_s: float, seed: int, exclude_root: Node = null, density_factor: float = 1.0) -> int:
	var cells := sample_terrain_grass(terrain_root, route, from_s, to_s, seed, exclude_root, density_factor)
	var total := 0
	for key in cells.keys():
		var buffer: PackedFloat32Array = cells[key]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = _grass_tuft_mesh()
		multimesh.instance_count = buffer.size() / 12
		multimesh.buffer = buffer
		var instance := MultiMeshInstance3D.new()
		instance.name = "PreviewGrass_%d_%d" % [key.x, key.y]
		instance.multimesh = multimesh
		instance.material_override = _tuft_material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.visibility_range_end = GRASS_VISIBLE_M
		instance.visibility_range_end_margin = 10.0
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		holder.add_child(instance)
		total += buffer.size() / 12
	return total

## {Vector2i cell: PackedFloat32Array of 12-float MultiMesh transforms} in terrain_root space.
static func sample_terrain_grass(terrain_root: Node, route: RefCounted, from_s: float, to_s: float, seed: int, exclude_root: Node = null, density_factor: float = 1.0) -> Dictionary:
	var excluded := _xz_triangle_grid(exclude_root) if exclude_root != null else {}
	var route_cells := {}
	var s := maxf(0.0, from_s - GRASS_MAX_LATERAL_M - 10.0)
	while s <= minf(route.length, to_s + GRASS_MAX_LATERAL_M + 10.0):
		var p: Vector3 = route.position_at(s)
		var key := Vector2i(floori(p.x / GRASS_MAX_LATERAL_M), floori(p.z / GRASS_MAX_LATERAL_M))
		if not route_cells.has(key): route_cells[key] = PackedVector2Array()
		route_cells[key].append(Vector2(p.x, p.z))
		s += 2.0
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var cells := {}
	for mesh_instance in _mesh_instances(terrain_root):
		var to_root := _transform_to(mesh_instance, terrain_root)
		var mesh: Mesh = mesh_instance.mesh
		for surface in range(mesh.get_surface_count()):
			var material := mesh.surface_get_material(surface)
			if material == null or material.resource_name != "terrain_ground": continue
			var arrays := mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(vertices.size()))
			for t in range(0, indices.size() - 2, 3):
				var a: Vector3 = to_root * vertices[indices[t]]
				var b: Vector3 = to_root * vertices[indices[t + 1]]
				var c: Vector3 = to_root * vertices[indices[t + 2]]
				var normal := (b - a).cross(c - a)
				var area := normal.length() * 0.5
				if area < 1e-6 or absf(normal.normalized().y) < 0.6: continue  # skip slivers and steep banks
				var centroid := (a + b + c) / 3.0
				var distance := _nearest_route_distance(route_cells, Vector2(centroid.x, centroid.z))
				if distance > GRASS_MAX_LATERAL_M: continue
				var density := lerpf(GRASS_NEAR_DENSITY, GRASS_FAR_DENSITY, clampf((distance - 4.0) / (GRASS_MAX_LATERAL_M - 4.0), 0.0, 1.0))
				var expected := area * density * maxf(density_factor, 0.0)
				var count := int(expected) + (1 if rng.randf() < expected - floorf(expected) else 0)
				for k in range(count):
					var r1 := rng.randf()
					var r2 := rng.randf()
					if r1 + r2 > 1.0:
						r1 = 1.0 - r1
						r2 = 1.0 - r2
					var p := a + (b - a) * r1 + (c - a) * r2
					if not excluded.is_empty() and _in_xz_grid(excluded, Vector2(p.x, p.z)): continue
					var key := Vector2i(floori(p.x / GRASS_CELL_M), floori(p.z / GRASS_CELL_M))
					if not cells.has(key): cells[key] = PackedFloat32Array()
					var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(1.0, rng.randf_range(0.8, 1.25), 1.0) * rng.randf_range(0.9, 1.2))
					cells[key].append_array([basis.x.x, basis.y.x, basis.z.x, p.x, basis.x.y, basis.y.y, basis.z.y, p.y, basis.x.z, basis.y.z, basis.z.z, p.z])
	return cells

const EXCLUDE_CELL_M := 4.0

static func _xz_triangle_grid(root: Node) -> Dictionary:
	# {Vector2i cell: [PackedVector2Array triangle]} of every mesh triangle under root, in root space.
	var grid := {}
	for mesh_instance in _mesh_instances(root):
		var to_root := _transform_to(mesh_instance, root)
		var mesh: Mesh = mesh_instance.mesh
		for surface in range(mesh.get_surface_count()):
			var arrays := mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(vertices.size()))
			for t in range(0, indices.size() - 2, 3):
				var tri := PackedVector2Array()
				for k in range(3):
					var v: Vector3 = to_root * vertices[indices[t + k]]
					tri.append(Vector2(v.x, v.z))
				var lo := Vector2i(floori(minf(minf(tri[0].x, tri[1].x), tri[2].x) / EXCLUDE_CELL_M), floori(minf(minf(tri[0].y, tri[1].y), tri[2].y) / EXCLUDE_CELL_M))
				var hi := Vector2i(floori(maxf(maxf(tri[0].x, tri[1].x), tri[2].x) / EXCLUDE_CELL_M), floori(maxf(maxf(tri[0].y, tri[1].y), tri[2].y) / EXCLUDE_CELL_M))
				for gx in range(lo.x, hi.x + 1):
					for gz in range(lo.y, hi.y + 1):
						var key := Vector2i(gx, gz)
						if not grid.has(key): grid[key] = []
						grid[key].append(tri)
	return grid

static func _in_xz_grid(grid: Dictionary, p: Vector2) -> bool:
	for tri in grid.get(Vector2i(floori(p.x / EXCLUDE_CELL_M), floori(p.y / EXCLUDE_CELL_M)), []):
		if Geometry2D.point_is_inside_triangle(p, tri[0], tri[1], tri[2]): return true
	return false

static func _nearest_route_distance(route_cells: Dictionary, point: Vector2) -> float:
	var best := INF
	var cell := Vector2i(floori(point.x / GRASS_MAX_LATERAL_M), floori(point.y / GRASS_MAX_LATERAL_M))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for q in route_cells.get(cell + Vector2i(dx, dz), PackedVector2Array()):
				best = minf(best, point.distance_squared_to(q))
	return sqrt(best)

static func _mesh_instances(root: Node) -> Array:
	var found := []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and node.mesh != null: found.append(node)
		stack.append_array(node.get_children())
	return found

static func _transform_to(node: Node3D, root: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != root:
		if current is Node3D: result = (current as Node3D).transform * result
		current = current.get_parent()
	return result

static func _grass_tuft_mesh() -> ArrayMesh:
	if _tuft_mesh != null: return _tuft_mesh
	# Fourteen thin, double-sided blades 2.5-6 cm tall (mown lawn); terrain-coloured base to lighter, yellower tips (linear colours).
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for blade in range(14):
		var angle := float(blade) * 2.399
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var side := Vector3(-direction.z, 0.0, direction.x)
		var height := 0.025 + 0.035 * fmod(float(blade) * 0.618, 1.0)
		var width := 0.005 + 0.002 * float(blade % 3)
		var base := direction * (0.01 + 0.06 * fmod(float(blade) * 0.381, 1.0))
		var tip := base + direction * height * 0.3 + Vector3.UP * height
		var root_color := Color(0.09, 0.18, 0.04)
		var tip_color := Color(0.16, 0.30, 0.06).lerp(Color(0.26, 0.31, 0.09), fmod(float(blade) * 0.47, 1.0))
		var points := [base - side * width, base + side * width, tip]
		var colors := [root_color, root_color, tip_color]
		for order in [[0, 1, 2], [1, 0, 2]]:
			for i in order:
				st.set_color(colors[i])
				st.set_normal(Vector3.UP)
				st.add_vertex(points[i])
	_tuft_mesh = st.commit()
	_tuft_material = StandardMaterial3D.new()
	_tuft_material.vertex_color_use_as_albedo = true
	_tuft_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_tuft_material.roughness = 0.95
	_tuft_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return _tuft_mesh
