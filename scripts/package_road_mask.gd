extends RefCounted
## Geometry-only overlap clipping for spatially streamed road surfaces.

static func triangle_xz_area2(triangle: Array) -> float:
	return (triangle[1].x - triangle[0].x) * (triangle[2].z - triangle[0].z) - (triangle[1].z - triangle[0].z) * (triangle[2].x - triangle[0].x)

static func polygon_xz_area2(polygon: Array) -> float:
	var area := 0.0
	if polygon.size() < 3: return 0.0
	var origin: Vector3 = polygon[0]
	for i in range(1, polygon.size() - 1):
		var a: Vector3 = polygon[i] - origin
		var b: Vector3 = polygon[i + 1] - origin
		area += a.x * b.z - b.x * a.z
	return area

static func _bounds_overlap_xz(a: Array, b: Array) -> bool:
	var a_min_x := minf(a[0].x, minf(a[1].x, a[2].x))
	var a_max_x := maxf(a[0].x, maxf(a[1].x, a[2].x))
	var a_min_z := minf(a[0].z, minf(a[1].z, a[2].z))
	var a_max_z := maxf(a[0].z, maxf(a[1].z, a[2].z))
	var b_min_x := minf(b[0].x, minf(b[1].x, b[2].x))
	var b_max_x := maxf(b[0].x, maxf(b[1].x, b[2].x))
	var b_min_z := minf(b[0].z, minf(b[1].z, b[2].z))
	var b_max_z := maxf(b[0].z, maxf(b[1].z, b[2].z))
	return a_min_x <= b_max_x and a_max_x >= b_min_x and a_min_z <= b_max_z and a_max_z >= b_min_z

static func _clip_side(polygon: Array, a: Vector3, b: Vector3, orientation: float, keep_inside: bool) -> Array:
	var output: Array = []
	if polygon.is_empty(): return output
	var previous: Vector3 = polygon[-1]
	var previous_side := orientation * ((b.x - a.x) * (previous.z - a.z) - (b.z - a.z) * (previous.x - a.x))
	var previous_kept := previous_side >= -1e-10 if keep_inside else previous_side <= 1e-10
	for current_value in polygon:
		var current: Vector3 = current_value
		var current_side := orientation * ((b.x - a.x) * (current.z - a.z) - (b.z - a.z) * (current.x - a.x))
		var current_kept := current_side >= -1e-10 if keep_inside else current_side <= 1e-10
		if current_kept != previous_kept:
			var denominator := previous_side - current_side
			if absf(denominator) > 1e-15:
				output.append(previous.lerp(current, clampf(previous_side / denominator, 0.0, 1.0)))
		if current_kept: output.append(current)
		previous = current
		previous_side = current_side
		previous_kept = current_kept
	return _clean_polygon(output)

static func _clean_polygon(polygon: Array) -> Array:
	var result: Array = []
	for point in polygon:
		if result.is_empty() or Vector2(point.x, point.z).distance_squared_to(Vector2(result[-1].x, result[-1].z)) > 1e-18:
			result.append(point)
	if result.size() > 1 and Vector2(result[0].x, result[0].z).distance_squared_to(Vector2(result[-1].x, result[-1].z)) <= 1e-18:
		result.pop_back()
	return result

static func _clip_convex(polygon: Array, cutter: Array) -> Array:
	var area := triangle_xz_area2(cutter)
	if absf(area) <= 1e-12: return []
	var orientation := 1.0 if area > 0.0 else -1.0
	var result := polygon.duplicate()
	for i in range(cutter.size()):
		result = _clip_side(result, cutter[i], cutter[(i + 1) % cutter.size()], orientation, true)
		if result.size() < 3: return []
	return result

static func _subtract_convex(subject: Array, cutter: Array) -> Array:
	# Partition the subject by each cutter edge. Outside pieces are retained; only the
	# polygon inside every edge is discarded. All resulting pieces remain convex.
	var area := polygon_xz_area2(cutter)
	if absf(area) <= 1e-12: return [subject]
	var orientation := 1.0 if area > 0.0 else -1.0
	var inside := subject.duplicate()
	var outside: Array = []
	for i in range(cutter.size()):
		if inside.size() < 3: break
		var a: Vector3 = cutter[i]
		var b: Vector3 = cutter[(i + 1) % cutter.size()]
		var rejected := _clip_side(inside, a, b, orientation, false)
		if rejected.size() >= 3 and absf(polygon_xz_area2(rejected)) > 1e-12:
			outside.append(rejected)
		inside = _clip_side(inside, a, b, orientation, true)
	return outside

static func _height_on_xz(point: Vector3, triangle: Array) -> float:
	var a: Vector3 = triangle[0]
	var b: Vector3 = triangle[1]
	var c: Vector3 = triangle[2]
	var denominator := triangle_xz_area2(triangle)
	if absf(denominator) <= 1e-12: return INF
	var w1 := ((point.x - a.x) * (c.z - a.z) - (point.z - a.z) * (c.x - a.x)) / denominator
	var w2 := ((b.x - a.x) * (point.z - a.z) - (b.z - a.z) * (point.x - a.x)) / denominator
	return a.y * (1.0 - w1 - w2) + b.y * w1 + c.y * w2

static func _clip_height_difference(polygon: Array, extra_triangle: Array, active_triangle: Array, limit: float, keep_below: bool) -> Array:
	var output: Array = []
	if polygon.is_empty(): return output
	var previous: Vector3 = polygon[-1]
	var previous_delta := previous.y - _height_on_xz(previous, active_triangle)
	var previous_value := previous_delta - limit if keep_below else -limit - previous_delta
	for point_value in polygon:
		var current: Vector3 = point_value
		var current_delta := current.y - _height_on_xz(current, active_triangle)
		var current_value := current_delta - limit if keep_below else -limit - current_delta
		var previous_kept := previous_value <= 1e-9
		var current_kept := current_value <= 1e-9
		if previous_kept != current_kept:
			var denominator := previous_value - current_value
			if absf(denominator) > 1e-15:
				output.append(previous.lerp(current, clampf(previous_value / denominator, 0.0, 1.0)))
		if current_kept: output.append(current)
		previous = current
		previous_value = current_value
	return _clean_polygon(output)

static func mask_triangle(extra_triangle: Array, active_triangles: Array, height_tolerance_m: float = 0.05) -> Array:
	if extra_triangle.size() != 3 or absf(triangle_xz_area2(extra_triangle)) <= 1e-12:
		return []
	var fragments: Array = [extra_triangle.duplicate()]
	for active_value in active_triangles:
		var active: Array = active_value
		if active.size() != 3 or absf(triangle_xz_area2(active)) <= 1e-12: continue
		if not _bounds_overlap_xz(extra_triangle, active): continue
		var next_fragments: Array = []
		for fragment_value in fragments:
			var fragment: Array = fragment_value
			var overlap := _clip_convex(fragment, active)
			if overlap.size() < 3:
				next_fragments.append(fragment)
				continue
			# Road heights are affine over each triangle. Retain only the part of this
			# overlap whose two source surfaces agree within the explicit height tolerance.
			var same_level := _clip_height_difference(overlap, extra_triangle, active, height_tolerance_m, true)
			same_level = _clip_height_difference(same_level, extra_triangle, active, height_tolerance_m, false)
			if same_level.size() < 3:
				next_fragments.append(fragment)
			else:
				next_fragments.append_array(_subtract_convex(fragment, same_level))
		fragments = next_fragments
		if fragments.is_empty(): break
	return fragments

static func barycentric_xz(point: Vector3, triangle: Array) -> Vector3:
	var a: Vector3 = triangle[0]
	var b: Vector3 = triangle[1]
	var c: Vector3 = triangle[2]
	var denominator := triangle_xz_area2(triangle)
	if absf(denominator) <= 1e-12: return Vector3.ZERO
	var wb := ((point.x - a.x) * (c.z - a.z) - (point.z - a.z) * (c.x - a.x)) / denominator
	var wc := ((b.x - a.x) * (point.z - a.z) - (b.z - a.z) * (point.x - a.x)) / denominator
	return Vector3(1.0 - wb - wc, wb, wc)

static func interpolate_attribute(value_a: Variant, value_b: Variant, value_c: Variant, weights: Vector3) -> Variant:
	if value_a is Vector3: return value_a * weights.x + value_b * weights.y + value_c * weights.z
	if value_a is Vector2: return value_a * weights.x + value_b * weights.y + value_c * weights.z
	if value_a is Color: return value_a * weights.x + value_b * weights.y + value_c * weights.z
	if value_a is Vector4: return value_a * weights.x + value_b * weights.y + value_c * weights.z
	return value_a

static func _append_vertex(output: Array, source: Array, source_indices: Array, triangle: Array, point: Vector3) -> void:
	var weights := barycentric_xz(point, triangle)
	for array_index in range(Mesh.ARRAY_MAX):
		if array_index == Mesh.ARRAY_VERTEX or array_index == Mesh.ARRAY_INDEX or source[array_index] == null: continue
		var values: Variant = source[array_index]
		if values is PackedVector3Array:
			var value: Vector3 = interpolate_attribute(values[source_indices[0]], values[source_indices[1]], values[source_indices[2]], weights)
			if array_index == Mesh.ARRAY_NORMAL and value.length_squared() > 1e-12: value = value.normalized()
			output[array_index].append(value)
		elif values is PackedVector2Array:
			output[array_index].append(interpolate_attribute(values[source_indices[0]], values[source_indices[1]], values[source_indices[2]], weights))
		elif values is PackedColorArray:
			output[array_index].append(interpolate_attribute(values[source_indices[0]], values[source_indices[1]], values[source_indices[2]], weights))
		elif values is PackedFloat32Array:
			var width: int = values.size() / maxi(source[Mesh.ARRAY_VERTEX].size(), 1)
			if array_index == Mesh.ARRAY_TANGENT and width == 4:
				var tangent := Vector3.ZERO
				var handedness := 0.0
				for vertex_i in range(3):
					var base: int = source_indices[vertex_i] * width
					var weight: float = weights[vertex_i]
					tangent += Vector3(values[base], values[base + 1], values[base + 2]) * weight
					handedness += values[base + 3] * weight
				if tangent.length_squared() > 1e-12: tangent = tangent.normalized()
				output[array_index].append_array(PackedFloat32Array([tangent.x, tangent.y, tangent.z, -1.0 if handedness < 0.0 else 1.0]))
			else:
				for component in range(width):
					var a: float = values[source_indices[0] * width + component]
					var b: float = values[source_indices[1] * width + component]
					var c: float = values[source_indices[2] * width + component]
					output[array_index].append(a * weights.x + b * weights.y + c * weights.z)
		elif values is PackedByteArray and values.is_empty():
			continue
		elif values is PackedInt32Array and values.is_empty():
			continue
		else:
			push_error("Road overlap clipping does not support vertex array %d of type %s" % [array_index, type_string(typeof(values))])
			return
	var source_vertices: PackedVector3Array = source[Mesh.ARRAY_VERTEX]
	output[Mesh.ARRAY_VERTEX].append(interpolate_attribute(source_vertices[source_indices[0]], source_vertices[source_indices[1]], source_vertices[source_indices[2]], weights))

static func _new_surface_arrays(source: Array) -> Array:
	var output: Array = []
	output.resize(Mesh.ARRAY_MAX)
	for i in range(Mesh.ARRAY_MAX):
		var value: Variant = source[i]
		if i == Mesh.ARRAY_VERTEX: output[i] = PackedVector3Array()
		elif i == Mesh.ARRAY_INDEX: output[i] = null
		elif value is PackedVector3Array: output[i] = PackedVector3Array()
		elif value is PackedVector2Array: output[i] = PackedVector2Array()
		elif value is PackedColorArray: output[i] = PackedColorArray()
		elif value is PackedFloat32Array: output[i] = PackedFloat32Array()
		elif value is PackedByteArray: output[i] = PackedByteArray()
		elif value is PackedInt32Array: output[i] = PackedInt32Array()
	return output

static func _emit_polygon(output: Array, source: Array, source_indices: Array, triangle: Array, polygon: Array) -> void:
	if polygon.size() < 3: return
	for i in range(1, polygon.size() - 1):
		var tri := [polygon[0], polygon[i], polygon[i + 1]]
		if absf(triangle_xz_area2(tri)) <= 1e-10: continue
		for point in tri: _append_vertex(output, source, source_indices, triangle, point)

static func clip_mesh_instance(source_instance: MeshInstance3D, active_source: Variant, height_tolerance_m: float = 0.05) -> ArrayMesh:
	if source_instance == null or source_instance.mesh == null: return null
	var source_mesh := source_instance.mesh
	var output_mesh := ArrayMesh.new()
	var local_to_world := source_instance.global_transform
	var changed := false
	for surface in range(source_mesh.get_surface_count()):
		if source_mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			push_error("Road overlap clipping requires triangle primitives")
			return null
		var source: Array = source_mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = source[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = PackedInt32Array() if source[Mesh.ARRAY_INDEX] == null else source[Mesh.ARRAY_INDEX]
		if vertices.is_empty(): continue
		for array_index in range(Mesh.ARRAY_MAX):
			var attribute: Variant = source[array_index]
			if attribute == null or (attribute is PackedByteArray and attribute.is_empty()) or (attribute is PackedInt32Array and attribute.is_empty()) or (attribute is PackedFloat32Array and attribute.is_empty()) or (attribute is PackedVector2Array and attribute.is_empty()) or (attribute is PackedVector3Array and attribute.is_empty()) or (attribute is PackedColorArray and attribute.is_empty()): continue
			if array_index in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_INDEX]: continue
			push_error("Road overlap clipping cannot interpolate nonempty mesh array %d" % array_index)
			return null
		var output := _new_surface_arrays(source)
		var tri_count := indices.size() / 3 if not indices.is_empty() else vertices.size() / 3
		for tri_index in range(tri_count):
			var ids: Array = []
			for j in range(3): ids.append(indices[tri_index * 3 + j] if not indices.is_empty() else tri_index * 3 + j)
			var world_triangle: Array = [local_to_world * vertices[ids[0]], local_to_world * vertices[ids[1]], local_to_world * vertices[ids[2]]]
			var world_candidates: Array = query_spatial_index(active_source, world_triangle) if active_source is Dictionary else active_source
			var origin: Vector3 = world_triangle[0]
			var triangle: Array = [Vector3.ZERO, world_triangle[1] - origin, world_triangle[2] - origin]
			var active_triangles: Array = []
			for candidate_value in world_candidates:
				var candidate: Array = candidate_value
				active_triangles.append([candidate[0] - origin, candidate[1] - origin, candidate[2] - origin])
			var pieces: Array = mask_triangle(triangle, active_triangles, height_tolerance_m)
			if pieces.size() != 1 or (not pieces.is_empty() and absf(polygon_xz_area2(pieces[0]) - triangle_xz_area2(triangle)) > 1e-8): changed = true
			for piece in pieces: _emit_polygon(output, source, ids, triangle, piece)
		if output[Mesh.ARRAY_VERTEX].is_empty():
			changed = true
			continue
		output_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, output)
		output_mesh.surface_set_material(output_mesh.get_surface_count() - 1, source_mesh.surface_get_material(surface))
	if not changed: return source_mesh as ArrayMesh
	return output_mesh

static func collect_world_triangles(root: Node) -> Array:
	var triangles: Array = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and node.mesh != null:
			for surface in range(node.mesh.get_surface_count()):
				if node.mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES: continue
				var arrays: Array = node.mesh.surface_get_arrays(surface)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var indices: PackedInt32Array = PackedInt32Array() if arrays[Mesh.ARRAY_INDEX] == null else arrays[Mesh.ARRAY_INDEX]
				var count := indices.size() if not indices.is_empty() else vertices.size()
				for i in range(0, count - 2, 3):
					var ia: int = indices[i] if not indices.is_empty() else i
					var ib: int = indices[i + 1] if not indices.is_empty() else i + 1
					var ic: int = indices[i + 2] if not indices.is_empty() else i + 2
					var tri: Array = [node.global_transform * vertices[ia], node.global_transform * vertices[ib], node.global_transform * vertices[ic]]
					if absf(triangle_xz_area2(tri)) > 1e-12: triangles.append(tri)
		for child in node.get_children(): stack.append(child)
	return triangles

static func build_spatial_index(triangles: Array, cell_size_m: float = 20.0) -> Dictionary:
	var cells := {}
	var bounds: Array = []
	var size := maxf(cell_size_m, 1.0)
	for i in range(triangles.size()):
		var triangle: Array = triangles[i]
		var min_x := minf(triangle[0].x, minf(triangle[1].x, triangle[2].x))
		var max_x := maxf(triangle[0].x, maxf(triangle[1].x, triangle[2].x))
		var min_z := minf(triangle[0].z, minf(triangle[1].z, triangle[2].z))
		var max_z := maxf(triangle[0].z, maxf(triangle[1].z, triangle[2].z))
		bounds.append(Vector4(min_x, min_z, max_x, max_z))
		for x in range(floori(min_x / size), floori(max_x / size) + 1):
			for z in range(floori(min_z / size), floori(max_z / size) + 1):
				var key := Vector2i(x, z)
				if not cells.has(key): cells[key] = []
				cells[key].append(i)
	return {"size": size, "cells": cells, "triangles": triangles, "bounds": bounds}

static func query_spatial_index(index: Dictionary, triangle: Array) -> Array:
	var size: float = index.size
	var min_x := minf(triangle[0].x, minf(triangle[1].x, triangle[2].x))
	var max_x := maxf(triangle[0].x, maxf(triangle[1].x, triangle[2].x))
	var min_z := minf(triangle[0].z, minf(triangle[1].z, triangle[2].z))
	var max_z := maxf(triangle[0].z, maxf(triangle[1].z, triangle[2].z))
	var seen := {}
	var result: Array = []
	for x in range(floori(min_x / size), floori(max_x / size) + 1):
		for z in range(floori(min_z / size), floori(max_z / size) + 1):
			for candidate in index.cells.get(Vector2i(x, z), []):
				if seen.has(candidate): continue
				seen[candidate] = true
				var candidate_bounds: Vector4 = index.bounds[candidate]
				if min_x <= candidate_bounds.z and max_x >= candidate_bounds.x and min_z <= candidate_bounds.w and max_z >= candidate_bounds.y:
					result.append(index.triangles[candidate])
	return result
