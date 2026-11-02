class_name SaisiesGeoLandscape
extends Node3D

## North-up real DEM terrain for the independent Saisies geography scene.
## The mesh is one continuous grid. Road contact is supplied by
## SaisiesGeography.height_world() in the local 8--25 m seam only; there is no
## distant corridor flattening, face deletion, or separate mountain cap.

@export var route_path: NodePath
@export var build_grid_size := 0
@export var max_vertices := 700000
@export var route_sample_step_m := 20.0

const ROUTE_CLEARANCE_MARGIN_M := 0.12
const FINE_SUBDIVISIONS := 8
const ROAD_FACE_HASH_CELL_M := 64.0
const ROAD_FACE_INFLUENCE_M := 4.0
const S09_DETAIL_REFERENCE_STATION_M := 5431.282674

var geography
var route: Node
var landscape_ready := false

var _mesh_instance: MeshInstance3D
var _grid_size := 0
var _mesh_bounds := AABB()
var _build_attempts := 0
var _mesh_vertices := PackedVector3Array()
var _mesh_indices := PackedInt32Array()
var _mesh_triangle_cells: Dictionary = {}
var _coarse_triangle_starts := PackedInt32Array()
var _coarse_vertex_indices := PackedInt32Array()
var _refined_cells: Dictionary = {}
var _road_segments: Array = []
var _road_face_spatial_hash: Dictionary = {}

func _ready() -> void:
	call_deferred("_try_build")

func _try_build() -> void:
	if landscape_ready:
		return
	if route == null and not route_path.is_empty():
		route = get_node_or_null(route_path)
	if route == null:
		_build_attempts += 1
		if _build_attempts < 12:
			call_deferred("_try_build")
		else:
			push_error("SaisiesGeoLandscape requires a geographic route node")
		return
	if geography == null:
		var route_geography = route.get("geography")
		if route_geography != null and route_geography.has_method("world_from_uv"):
			geography = route_geography
	if geography == null:
		_build_attempts += 1
		if _build_attempts < 12:
			call_deferred("_try_build")
		else:
			push_error("SaisiesGeoLandscape route has no configured SaisiesGeography")
		return
	if not geography.configured:
		_build_attempts += 1
		if _build_attempts < 12:
			call_deferred("_try_build")
		else:
			push_error("SaisiesGeoLandscape route geography is not configured")
		return
	if route != null and route.has_method("route_ready") and not bool(route.call("route_ready")):
		_build_attempts += 1
		if _build_attempts < 8:
			call_deferred("_try_build")
		else:
			push_warning("SaisiesGeoLandscape route was not ready after deferred retries")
		return
	if not geography.has_route_samples() and route != null:
		_collect_route_samples()
	_build_mesh()
	landscape_ready = true
	set_meta("saisies_geo_landscape_vertex_count", _mesh_vertices.size())
	set_meta("saisies_geo_landscape_triangle_count", _mesh_indices.size() / 3)
	set_meta("saisies_geo_landscape_grid_size", _grid_size)
	set_meta("saisies_geo_landscape_refined_cell_count", _refined_cells.size())
	set_meta("saisies_geo_landscape_bounds", _mesh_bounds)
	set_meta("saisies_geo_datum_m", geography.datum_m)
	if geography.has_method("nearfield_patch_count"):
		set_meta("saisies_geo_landscape_nearfield_patch_count", geography.nearfield_patch_count())
		set_meta("saisies_geo_landscape_nearfield_patch_info", geography.nearfield_patch_info())

func _collect_route_samples() -> void:
	if route == null or not route.has_method("pos_at"):
		return
	var length_m := float(route.get("length_m"))
	if length_m <= 0.0:
		return
	var spacing := clampf(route_sample_step_m, 8.0, 40.0)
	var count := int(ceil(length_m / spacing)) + 1
	var points := PackedVector3Array()
	points.resize(count)
	for i in range(count):
		var s := minf(float(i) * spacing, length_m)
		if i == count - 1:
			s = length_m
		var point: Vector3 = route.call("pos_at", s)
		points[i] = point
	geography.set_route_samples(points, 25.0)

func _build_road_surface_cache() -> void:
	_road_segments.clear()
	_road_face_spatial_hash.clear()
	if route == null:
		return
	var asphalt := route.get_node_or_null("SaisiesAsphalt") as MeshInstance3D
	if asphalt == null or asphalt.mesh == null:
		return
	var faces: PackedVector3Array = asphalt.mesh.get_faces()
	var segment_count := faces.size() / 6
	for segment in range(segment_count):
		var start := segment * 6
		var points := [faces[start], faces[start + 1], faces[start + 2], faces[start + 3], faces[start + 4], faces[start + 5]]
		var min_x := INF
		var max_x := -INF
		var min_z := INF
		var max_z := -INF
		for point in points:
			min_x = minf(min_x, point.x)
			max_x = maxf(max_x, point.x)
			min_z = minf(min_z, point.z)
			max_z = maxf(max_z, point.z)
		var record := {"points": points}
		var record_index := _road_segments.size()
		_road_segments.append(record)
		var min_cell_x := floori(min_x / ROAD_FACE_HASH_CELL_M) - 1
		var max_cell_x := floori(max_x / ROAD_FACE_HASH_CELL_M) + 1
		var min_cell_z := floori(min_z / ROAD_FACE_HASH_CELL_M) - 1
		var max_cell_z := floori(max_z / ROAD_FACE_HASH_CELL_M) + 1
		for cell_x in range(min_cell_x, max_cell_x + 1):
			for cell_z in range(min_cell_z, max_cell_z + 1):
				var key := Vector2i(cell_x, cell_z)
				var bucket: Array = _road_face_spatial_hash.get(key, [])
				bucket.append(record_index)
				_road_face_spatial_hash[key] = bucket

func _road_surface_floor(xz: Vector2) -> float:
	if _road_segments.is_empty():
		return INF
	var cell_x := floori(xz.x / ROAD_FACE_HASH_CELL_M)
	var cell_z := floori(xz.y / ROAD_FACE_HASH_CELL_M)
	var candidates: Dictionary = {}
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var bucket: Array = _road_face_spatial_hash.get(Vector2i(cell_x + dx, cell_z + dz), [])
			for record_index in bucket:
				candidates[int(record_index)] = true
	var best_floor := INF
	for raw_index in candidates.keys():
		var points: Array = _road_segments[int(raw_index)]["points"]
		for triangle in range(2):
			var start := triangle * 3
			var a: Vector3 = points[start]
			var b: Vector3 = points[start + 1]
			var c: Vector3 = points[start + 2]
			var weights := _barycentric_xz(xz, a, b, c)
			var face_distance := _distance_to_triangle_xz(xz, a, b, c)
			if weights.x < -0.5 and face_distance > ROAD_FACE_INFLUENCE_M:
				continue
			# The complete asphalt face is the swept road surface.  Lowering
			# inside its projection to its lowest face endpoint prevents an
			# unmatched DEM triangle from bridging above a steep road quad.
			best_floor = minf(best_floor, minf(a.y, minf(b.y, c.y)))
	return best_floor

func _distance_to_triangle_xz(point: Vector2, a: Vector3, b: Vector3, c: Vector3) -> float:
	var weights := _barycentric_xz(point, a, b, c)
	if weights.x >= -0.5:
		return 0.0
	return minf(_distance_to_segment_xz(point, a, b), minf(_distance_to_segment_xz(point, b, c), _distance_to_segment_xz(point, c, a)))

func _distance_to_segment_xz(point: Vector2, a: Vector3, b: Vector3) -> float:
	var a_xz := Vector2(a.x, a.z)
	var ab := Vector2(b.x - a.x, b.z - a.z)
	var t := clampf((point - a_xz).dot(ab) / maxf(ab.length_squared(), 0.000001), 0.0, 1.0)
	return point.distance_to(a_xz.lerp(Vector2(b.x, b.z), t))

func _build_mesh() -> void:
	var build_started_usec := Time.get_ticks_usec()
	_build_road_surface_cache()
	_grid_size = geography.height_grid()
	if build_grid_size >= 2:
		_grid_size = mini(build_grid_size, geography.height_grid())
	_grid_size = clampi(_grid_size, 2, geography.height_grid())
	if _grid_size * _grid_size > max_vertices:
		push_warning("SaisiesGeoLandscape grid exceeds max_vertices; using DEM grid anyway for geographic fidelity")
	var vertex_count := _grid_size * _grid_size
	var coarse_vertices := PackedVector3Array()
	var coarse_uvs := PackedVector2Array()
	coarse_vertices.resize(vertex_count)
	coarse_uvs.resize(vertex_count)
	for row in range(_grid_size):
		var v := float(row) / float(_grid_size - 1)
		for column in range(_grid_size):
			var u := float(column) / float(_grid_size - 1)
			var index := row * _grid_size + column
			var uv := Vector2(u, v)
			coarse_vertices[index] = geography.world_from_uv(uv)
			coarse_uvs[index] = uv
	_refined_cells = _route_refined_cells()
	_mesh_triangle_cells.clear()
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var vertex_map: Dictionary = {}
	var cell_count := (_grid_size - 1) * (_grid_size - 1)
	_coarse_triangle_starts.resize(cell_count * 2)
	_coarse_vertex_indices.resize(vertex_count)
	for i in range(_coarse_triangle_starts.size()):
		_coarse_triangle_starts[i] = -1
	for i in range(_coarse_vertex_indices.size()):
		_coarse_vertex_indices[i] = -1
	for row in range(_grid_size - 1):
		for column in range(_grid_size - 1):
			var cell := Vector2i(column, row)
			if _refined_cells.has(cell):
				_append_refined_cell(cell, coarse_vertices, vertices, uvs, indices, vertex_map)
			else:
				_append_coarse_cell(cell, coarse_vertices, coarse_uvs, vertices, uvs, indices, vertex_map)
	for row in range(_grid_size):
		for column in range(_grid_size):
			var coarse_key := Vector2i(column * FINE_SUBDIVISIONS, row * FINE_SUBDIVISIONS)
			_coarse_vertex_indices[row * _grid_size + column] = int(vertex_map.get(coarse_key, -1))
	var normals := _normals_from_faces(vertices, indices)
	# The detail shader samples its normal map in world XZ, not the coarse
	# orthophoto UVs.  Build the tangent basis from that same mapping so the
	# bounded grass normal detail has a stable +world-X/+world-Z frame.
	var tangents := _tangents_from_world_xz(vertices, indices, normals)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "SaisiesGeoTerrain"
	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = _terrain_material()
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.extra_cull_margin = 30000.0
	add_child(_mesh_instance)
	_mesh_bounds = _mesh_instance.get_aabb()
	_mesh_vertices = vertices
	_mesh_indices = indices
	var rough_bytes := vertices.size() * 12 + uvs.size() * 8 + normals.size() * 12 + tangents.size() * 4 + indices.size() * 4
	var build_ms := float(Time.get_ticks_usec() - build_started_usec) / 1000.0
	set_meta("saisies_geo_landscape_build_ms", build_ms)
	set_meta("saisies_geo_landscape_rough_bytes", rough_bytes)
	print("geo mesh built grid=%d refined_cells=%d vertices=%d triangles=%d build_ms=%.1f rough_bytes=%d" % [_grid_size, _refined_cells.size(), vertices.size(), indices.size() / 3, build_ms, rough_bytes])

func _route_refined_cells() -> Dictionary:
	var cells: Dictionary = {}
	if route == null or not geography.has_route_samples() or not route.has_method("pos_at"):
		return cells
	var length_m := float(route.get("length_m"))
	var spacing := clampf(route_sample_step_m, 8.0, 40.0)
	var sample_count := int(ceil(length_m / spacing)) + 1
	for i in range(sample_count):
		var s := minf(float(i) * spacing, length_m)
		var point: Vector3 = route.call("pos_at", s)
		var uv: Vector2 = geography.uv_world(Vector2(point.x, point.z))
		if uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
			continue
		var column := clampi(int(floor(uv.x * float(_grid_size - 1))), 0, _grid_size - 2)
		var row := clampi(int(floor(uv.y * float(_grid_size - 1))), 0, _grid_size - 2)
		# Two-cell margin keeps the outer fine/coarse boundary at least one
		# coarse cell away from the road even when a route sample lands on a
		# coarse-cell corner.  Only the seam topology is refined; distant DEM
		# heights remain untouched.
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var cell_column := column + dx
				var cell_row := row + dy
				if cell_column >= 0 and cell_column < _grid_size - 1 and cell_row >= 0 and cell_row < _grid_size - 1:
					cells[Vector2i(cell_column, cell_row)] = true
	return cells

func _append_coarse_cell(cell: Vector2i, coarse_vertices: PackedVector3Array, coarse_uvs: PackedVector2Array, vertices: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array, vertex_map: Dictionary) -> void:
	var row := cell.y
	var column := cell.x
	var a := _mesh_vertex(Vector2i(column * FINE_SUBDIVISIONS, row * FINE_SUBDIVISIONS), coarse_vertices[row * _grid_size + column], coarse_uvs[row * _grid_size + column], vertices, uvs, vertex_map)
	var b := _mesh_vertex(Vector2i((column + 1) * FINE_SUBDIVISIONS, row * FINE_SUBDIVISIONS), coarse_vertices[row * _grid_size + column + 1], coarse_uvs[row * _grid_size + column + 1], vertices, uvs, vertex_map)
	var c := _mesh_vertex(Vector2i(column * FINE_SUBDIVISIONS, (row + 1) * FINE_SUBDIVISIONS), coarse_vertices[(row + 1) * _grid_size + column], coarse_uvs[(row + 1) * _grid_size + column], vertices, uvs, vertex_map)
	var d := _mesh_vertex(Vector2i((column + 1) * FINE_SUBDIVISIONS, (row + 1) * FINE_SUBDIVISIONS), coarse_vertices[(row + 1) * _grid_size + column + 1], coarse_uvs[(row + 1) * _grid_size + column + 1], vertices, uvs, vertex_map)
	var cell_index := row * (_grid_size - 1) + column
	_coarse_triangle_starts[cell_index * 2] = indices.size()
	_append_triangle(indices, a, b, c, cell, false)
	_coarse_triangle_starts[cell_index * 2 + 1] = indices.size()
	_append_triangle(indices, b, d, c, cell, false)

func _append_refined_cell(cell: Vector2i, coarse_vertices: PackedVector3Array, vertices: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array, vertex_map: Dictionary) -> void:
	var local: Array = []
	local.resize(FINE_SUBDIVISIONS + 1)
	for fy in range(FINE_SUBDIVISIONS + 1):
		local[fy] = []
		local[fy].resize(FINE_SUBDIVISIONS + 1)
		for fx in range(FINE_SUBDIVISIONS + 1):
			var global_key := Vector2i(cell.x * FINE_SUBDIVISIONS + fx, cell.y * FINE_SUBDIVISIONS + fy)
			var uv := Vector2(float(global_key.x) / float((_grid_size - 1) * FINE_SUBDIVISIONS), float(global_key.y) / float((_grid_size - 1) * FINE_SUBDIVISIONS))
			var position := _refined_vertex_position(cell, fx, fy, coarse_vertices, uv)
			local[fy][fx] = _mesh_vertex(global_key, position, uv, vertices, uvs, vertex_map)
	for fy in range(FINE_SUBDIVISIONS):
		for fx in range(FINE_SUBDIVISIONS):
			var a: int = local[fy][fx]
			var b: int = local[fy][fx + 1]
			var c: int = local[fy + 1][fx]
			var d: int = local[fy + 1][fx + 1]
			_append_triangle(indices, a, b, c, cell, true)
			_append_triangle(indices, b, d, c, cell, true)

func _refined_vertex_position(cell: Vector2i, fx: int, fy: int, coarse_vertices: PackedVector3Array, uv: Vector2) -> Vector3:
	var row := cell.y
	var column := cell.x
	var a := coarse_vertices[row * _grid_size + column]
	var b := coarse_vertices[row * _grid_size + column + 1]
	var c := coarse_vertices[(row + 1) * _grid_size + column]
	var d := coarse_vertices[(row + 1) * _grid_size + column + 1]
	# Interior fine cells share their boundary with another fine cell.  Use the
	# true road-aware height on those shared edges; outer boundaries retain the
	# coarse linear edge so adjacent coarse triangles remain watertight.
	if (fx == 0 or fx == FINE_SUBDIVISIONS or fy == 0 or fy == FINE_SUBDIVISIONS) and _boundary_has_fine_neighbors(cell, fx, fy):
		var boundary_position = geography.world_from_uv(uv)
		return _road_core_clearance(boundary_position)
	if fx == 0 and fy == 0:
		return a
	if fx == FINE_SUBDIVISIONS and fy == 0:
		return b
	if fx == 0 and fy == FINE_SUBDIVISIONS:
		return c
	if fx == FINE_SUBDIVISIONS and fy == FINE_SUBDIVISIONS:
		return d
	if fy == 0:
		return a.lerp(b, float(fx) / float(FINE_SUBDIVISIONS))
	if fy == FINE_SUBDIVISIONS:
		return c.lerp(d, float(fx) / float(FINE_SUBDIVISIONS))
	if fx == 0:
		return a.lerp(c, float(fy) / float(FINE_SUBDIVISIONS))
	if fx == FINE_SUBDIVISIONS:
		return b.lerp(d, float(fy) / float(FINE_SUBDIVISIONS))
	return _road_core_clearance(geography.world_from_uv(uv))

func _boundary_has_fine_neighbors(cell: Vector2i, fx: int, fy: int) -> bool:
	var neighbors: Array[Vector2i] = []
	if fx == 0:
		neighbors.append(Vector2i(cell.x - 1, cell.y))
	elif fx == FINE_SUBDIVISIONS:
		neighbors.append(Vector2i(cell.x + 1, cell.y))
	if fy == 0:
		neighbors.append(Vector2i(cell.x, cell.y - 1))
	elif fy == FINE_SUBDIVISIONS:
		neighbors.append(Vector2i(cell.x, cell.y + 1))
	for neighbor in neighbors:
		if neighbor.x < 0 or neighbor.y < 0 or neighbor.x >= _grid_size - 1 or neighbor.y >= _grid_size - 1:
			continue
		if not _refined_cells.has(neighbor):
			return false
	return true

func _road_core_clearance(position: Vector3) -> Vector3:
	var nearest: Dictionary = geography.nearest_route_world(Vector2(position.x, position.z))
	if float(nearest.get("distance_m", INF)) <= 8.0:
		# A fine triangle can straddle two nearby route samples at a bend or
		# endpoint.  Keep the ordinary nearest-route blend unchanged, but use the
		# lowest road level within this same 8 m core for mesh clearance so neither
		# branch is hidden by a shared terrain triangle.
		var clearance_y := float(nearest.get("clearance_road_y", nearest.get("road_y", position.y)))
		var face_floor := _road_surface_floor(Vector2(position.x, position.z))
		if is_finite(face_floor):
			clearance_y = minf(clearance_y, face_floor)
		position.y = minf(position.y, clearance_y - ROUTE_CLEARANCE_MARGIN_M)
	return position

func _mesh_vertex(key: Vector2i, position: Vector3, uv: Vector2, vertices: PackedVector3Array, uvs: PackedVector2Array, vertex_map: Dictionary) -> int:
	if vertex_map.has(key):
		return int(vertex_map[key])
	var index := vertices.size()
	vertices.append(position)
	uvs.append(uv)
	vertex_map[key] = index
	return index

func _append_triangle(indices: PackedInt32Array, a: int, b: int, c: int, cell: Vector2i, refined: bool) -> void:
	var start := indices.size()
	indices.append(a)
	indices.append(b)
	indices.append(c)
	if refined:
		var starts: Array = _mesh_triangle_cells.get(cell, [])
		starts.append(start)
		_mesh_triangle_cells[cell] = starts

func _normals_from_faces(vertices: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	for face_start in range(0, indices.size(), 3):
		var a := vertices[indices[face_start]]
		var b := vertices[indices[face_start + 1]]
		var c := vertices[indices[face_start + 2]]
		# Godot's front face is clockwise when viewed from outside.  Terrain
		# indices therefore wind down-facing while lighting normals must remain
		# +Y; negate the face cross product for the explicit normal stream.
		var normal := (c - a).cross(b - a)
		if normal.length_squared() > 0.000001:
			normal = normal.normalized()
			normals[indices[face_start]] += normal
			normals[indices[face_start + 1]] += normal
			normals[indices[face_start + 2]] += normal
	for i in range(normals.size()):
		if normals[i].length_squared() < 0.000001:
			normals[i] = Vector3.UP
		else:
			normals[i] = normals[i].normalized()
	return normals

func _tangents_from_world_xz(vertices: PackedVector3Array, indices: PackedInt32Array, normals: PackedVector3Array) -> PackedFloat32Array:
	var tangent_accum := PackedVector3Array()
	var bitangent_accum := PackedVector3Array()
	tangent_accum.resize(vertices.size())
	bitangent_accum.resize(vertices.size())
	for i in range(vertices.size()):
		tangent_accum[i] = Vector3.ZERO
		bitangent_accum[i] = Vector3.ZERO
	for face_start in range(0, indices.size(), 3):
		var ia := int(indices[face_start])
		var ib := int(indices[face_start + 1])
		var ic := int(indices[face_start + 2])
		var edge1 := vertices[ib] - vertices[ia]
		var edge2 := vertices[ic] - vertices[ia]
		# This is the shader's detail UV before its repeat scale.  Using the
		# normalized 0..1 terrain UV here makes an 8 m cell's determinant about
		# 1e-7 over this 24 km DEM, so nearly every useful triangle falls into
		# the fallback basis.  World XZ keeps the determinant well-conditioned
		# and matches texture(detail_albedo_tex, world_position.xz * scale).
		var uv1 := Vector2(vertices[ib].x - vertices[ia].x, vertices[ib].z - vertices[ia].z)
		var uv2 := Vector2(vertices[ic].x - vertices[ia].x, vertices[ic].z - vertices[ia].z)
		var determinant := uv1.x * uv2.y - uv2.x * uv1.y
		if absf(determinant) < 0.000000000001:
			continue
		var inverse := 1.0 / determinant
		var tangent := (edge1 * uv2.y - edge2 * uv1.y) * inverse
		var bitangent := (edge2 * uv1.x - edge1 * uv2.x) * inverse
		tangent_accum[ia] = tangent_accum[ia] + tangent
		tangent_accum[ib] = tangent_accum[ib] + tangent
		tangent_accum[ic] = tangent_accum[ic] + tangent
		bitangent_accum[ia] = bitangent_accum[ia] + bitangent
		bitangent_accum[ib] = bitangent_accum[ib] + bitangent
		bitangent_accum[ic] = bitangent_accum[ic] + bitangent
	var packed := PackedFloat32Array()
	packed.resize(vertices.size() * 4)
	for i in range(vertices.size()):
		var normal := normals[i].normalized()
		var tangent := tangent_accum[i] - normal * tangent_accum[i].dot(normal)
		if tangent.length_squared() < 0.000001:
			# Preserve the +world-X detail direction when it has a valid
			# projection; use +world-Z only for near-X-facing surfaces.
			var world_x := Vector3.RIGHT - normal * normal.dot(Vector3.RIGHT)
			var world_z := Vector3(0.0, 0.0, 1.0) - normal * normal.dot(Vector3(0.0, 0.0, 1.0))
			tangent = world_x if world_x.length_squared() > 0.000001 else world_z
		if tangent.length_squared() < 0.000001:
			tangent = Vector3.UP.cross(normal)
		tangent = tangent.normalized()
		var handedness := 1.0
		if bitangent_accum[i].length_squared() > 0.000001:
			if normal.cross(tangent).dot(bitangent_accum[i]) < 0.0:
				handedness = -1.0
		else:
			var expected_world_z := Vector3(0.0, 0.0, 1.0) - normal * normal.dot(Vector3(0.0, 0.0, 1.0))
			if expected_world_z.length_squared() > 0.000001 and normal.cross(tangent).dot(expected_world_z) < 0.0:
				handedness = -1.0
		packed[i * 4] = tangent.x
		packed[i * 4 + 1] = tangent.y
		packed[i * 4 + 2] = tangent.z
		packed[i * 4 + 3] = handedness
	return packed

func _terrain_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/saisies_geo_terrain_detail.gdshader") as Shader
	if material.shader == null:
		push_error("SaisiesGeoLandscape could not load bounded terrain detail shader")
		return material
	# Headless verification may run before the editor has imported a newly
	# downloaded JPEG.  Native/editor runs still bind the real albedo texture;
	# leaving the parameter unset keeps geometry verification deterministic.
	var albedo_path: String = geography.albedo_path()
	if ResourceLoader.exists(albedo_path):
		var albedo = load(albedo_path)
		if albedo != null:
			material.set_shader_parameter("albedo_tex", albedo)
	material.set_shader_parameter("haze_dist", 22000.0)
	material.set_shader_parameter("haze_max", 0.72)
	material.set_shader_parameter("brightness", 1.05)
	material.set_shader_parameter("detail_enabled", false)
	material.set_shader_parameter("detail_force", false)
	material.set_shader_parameter("detail_side_start_m", 6.0)
	material.set_shader_parameter("detail_side_full_m", 9.0)
	material.set_shader_parameter("detail_side_end_m", 100.0)
	material.set_shader_parameter("detail_side_fade_m", 32.0)
	material.set_shader_parameter("detail_along_full_m", 72.0)
	material.set_shader_parameter("detail_along_edge_m", 112.0)
	material.set_shader_parameter("detail_uv_scale", 0.24)
	material.set_shader_parameter("detail_shadow_green", Color(0.32, 0.35, 0.20, 1.0))
	material.set_shader_parameter("detail_sun_green", Color(0.54, 0.57, 0.34, 1.0))
	material.set_shader_parameter("detail_brightness", 0.93)
	var detail_albedo_path := "res://assets/textures/aerial_grass_rock_diff.jpg"
	var detail_normal_path := "res://assets/textures/aerial_grass_rock_nor.jpg"
	if ResourceLoader.exists(detail_albedo_path):
		var detail_albedo = load(detail_albedo_path)
		if detail_albedo != null:
			material.set_shader_parameter("detail_albedo_tex", detail_albedo)
	if ResourceLoader.exists(detail_normal_path):
		var detail_normal = load(detail_normal_path)
		if detail_normal != null:
			material.set_shader_parameter("detail_normal_tex", detail_normal)
	if route != null and route.has_method("pos_at") and route.has_method("left_at"):
		var anchor_s := S09_DETAIL_REFERENCE_STATION_M
		if route.has_method("distance_for_video_seconds"):
			anchor_s = float(route.call("distance_for_video_seconds", 330.0))
		var anchor: Vector3 = route.call("pos_at", anchor_s)
		var left: Vector3 = route.call("left_at", anchor_s)
		var forward := Vector3(-left.z, 0.0, left.x).normalized()
		var center_xz := Vector2(anchor.x, anchor.z)
		var forward_xz := Vector2(forward.x, forward.z)
		var left_xz := Vector2(left.x, left.z)
		if is_finite(center_xz.x) and is_finite(center_xz.y) and forward_xz.length_squared() > 0.99 and left_xz.length_squared() > 0.99:
			material.set_shader_parameter("detail_center_xz", center_xz)
			material.set_shader_parameter("detail_forward_xz", forward_xz)
			material.set_shader_parameter("detail_left_xz", left_xz)
			material.set_shader_parameter("detail_enabled", true)
			set_meta("saisies_geo_terrain_detail_center_xz", center_xz)
			set_meta("saisies_geo_terrain_detail_forward_xz", forward_xz)
			set_meta("saisies_geo_terrain_detail_left_xz", left_xz)
			set_meta("saisies_geo_terrain_detail_station_m", anchor_s)
	return material

func sample_height_world(xz: Vector2) -> float:
	return geography.height_world(xz)

func sample_raw_height_world(xz: Vector2) -> float:
	return geography.raw_height_world(xz)

func sample_raw_height_world_coarse(xz: Vector2) -> float:
	if geography.has_method("raw_height_world_coarse"):
		return geography.raw_height_world_coarse(xz)
	return geography.raw_height_world(xz)

func sample_mesh_triangle(xz: Vector2) -> Dictionary:
	if _mesh_vertices.is_empty() or _mesh_indices.is_empty() or _grid_size < 2:
		return {}
	var uv: Vector2 = geography.uv_world(xz)
	if uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
		return {}
	var column := clampi(int(floor(uv.x * float(_grid_size - 1))), 0, _grid_size - 2)
	var row := clampi(int(floor(uv.y * float(_grid_size - 1))), 0, _grid_size - 2)
	var starts: Array = []
	var refined_cell := Vector2i(column, row)
	if _mesh_triangle_cells.has(refined_cell):
		starts.append_array(_mesh_triangle_cells[refined_cell])
	else:
		var cell_index := row * (_grid_size - 1) + column
		if cell_index * 2 + 1 < _coarse_triangle_starts.size():
			starts.append(_coarse_triangle_starts[cell_index * 2])
			starts.append(_coarse_triangle_starts[cell_index * 2 + 1])
	for start_variant in starts:
		var start := int(start_variant)
		if start < 0 or start + 2 >= _mesh_indices.size():
			continue
		var ia := _mesh_indices[start]
		var ib := _mesh_indices[start + 1]
		var ic := _mesh_indices[start + 2]
		var a := _mesh_vertices[ia]
		var b := _mesh_vertices[ib]
		var c := _mesh_vertices[ic]
		var weights := _barycentric_xz(xz, a, b, c)
		if weights.x < -0.5:
			continue
		return {
			"height": a.y * weights.x + b.y * weights.y + c.y * weights.z,
			"triangle_start": start,
			"cell": refined_cell,
			"barycentric": weights,
			"a": a,
			"b": b,
			"c": c
		}
	# A query exactly on a coarse/refined cell boundary can land in its adjacent
	# cell after floating-point rounding; inspect the local 3x3 topological bin.
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var neighbor := Vector2i(column + dx, row + dy)
			if neighbor.x < 0 or neighbor.y < 0 or neighbor.x >= _grid_size - 1 or neighbor.y >= _grid_size - 1:
				continue
			var neighbor_starts: Array = []
			if _mesh_triangle_cells.has(neighbor):
				neighbor_starts.append_array(_mesh_triangle_cells[neighbor])
			else:
				var neighbor_index := neighbor.y * (_grid_size - 1) + neighbor.x
				neighbor_starts.append(_coarse_triangle_starts[neighbor_index * 2])
				neighbor_starts.append(_coarse_triangle_starts[neighbor_index * 2 + 1])
			for start_variant in neighbor_starts:
				var start := int(start_variant)
				if start < 0 or start + 2 >= _mesh_indices.size():
					continue
				var a := _mesh_vertices[_mesh_indices[start]]
				var b := _mesh_vertices[_mesh_indices[start + 1]]
				var c := _mesh_vertices[_mesh_indices[start + 2]]
				var weights := _barycentric_xz(xz, a, b, c)
				if weights.x >= -0.5:
					return {"height": a.y * weights.x + b.y * weights.y + c.y * weights.z, "triangle_start": start, "cell": neighbor, "barycentric": weights, "a": a, "b": b, "c": c}
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

func terrain_bounds() -> AABB:
	return _mesh_bounds
