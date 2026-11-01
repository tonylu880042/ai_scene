extends SceneTree
## Same-level extra road pieces are clipped; independent vertical levels remain.
const RoadMask = preload("res://scripts/package_road_mask.gd")

var failures := 0

func _init() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _area2(poly: Array) -> float:
	var area := 0.0
	for i in range(poly.size()):
		var a: Vector3 = poly[i]
		var b: Vector3 = poly[(i + 1) % poly.size()]
		area += a.x * b.z - b.x * a.z
	return absf(area)

func _stable_area2(poly: Array) -> float:
	if poly.size() < 3: return 0.0
	var origin: Vector3 = poly[0]
	var area := 0.0
	for i in range(1, poly.size() - 1):
		var a: Vector3 = poly[i] - origin
		var b: Vector3 = poly[i + 1] - origin
		area += a.x * b.z - b.x * a.z
	return absf(area)


func _run() -> void:
	var extra := [Vector3(0, 0, 0), Vector3(4, 4, 0), Vector3(0, 0, 4)]
	var active := [Vector3(0, 0, 0), Vector3(2, 2, 0), Vector3(0, 0, 2)]
	var fragments: Array = RoadMask.mask_triangle(extra, [active])
	var area2 := 0.0
	for fragment in fragments: area2 += _area2(fragment)
	_check(absf(area2 - 12.0) < 1e-7, "Partial same-level overlap must remove only the 2 m² covered footprint")
	_check(fragments.size() >= 1, "Uncovered extra road area must remain")
	var offset := Vector3(436.5, 3.14, 2713.0)
	var translated_extra: Array = []
	var translated_active: Array = []
	for point in extra: translated_extra.append(point + offset)
	for point in active: translated_active.append(point + offset)
	var translated_fragments: Array = RoadMask.mask_triangle(translated_extra, [translated_active])
	var translated_area2 := 0.0
	for fragment in translated_fragments: translated_area2 += _stable_area2(fragment)
	_check(absf(translated_area2 - area2) < 1e-4, "Clipping area must be translation invariant at S20 world coordinates")
	var skew_offset := Vector3(436.6890, 3.1398, 2713.0389)
	var skew_extra: Array = [Vector3(0.137, 0.2, 0.271), Vector3(3.789, 1.2, 0.619), Vector3(0.393, 0.4, 4.134)]
	var skew_active: Array = [Vector3(0.401, 0.1, 0.731), Vector3(2.214, 1.1, 0.843), Vector3(0.492, 0.3, 2.668)]
	var skew_world_extra: Array = []
	var skew_world_active: Array = []
	for point in skew_extra: skew_world_extra.append(point + skew_offset)
	for point in skew_active: skew_world_active.append(point + skew_offset)
	var skew_origin: Vector3 = skew_world_extra[0]
	var skew_relative_extra: Array = []
	var skew_relative_active: Array = []
	for point in skew_world_extra: skew_relative_extra.append(point - skew_origin)
	for point in skew_world_active: skew_relative_active.append(point - skew_origin)
	var skew_reference: Array = RoadMask.mask_triangle(skew_relative_extra, [skew_relative_active])
	var skew_reference_area := 0.0
	for piece in skew_reference: skew_reference_area += _stable_area2(piece)
	var skew_source_arrays: Array = []
	skew_source_arrays.resize(Mesh.ARRAY_MAX)
	skew_source_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(skew_extra)
	skew_source_arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN])
	skew_source_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var skew_source_mesh := ArrayMesh.new()
	skew_source_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, skew_source_arrays)
	var skew_active_arrays: Array = []
	skew_active_arrays.resize(Mesh.ARRAY_MAX)
	skew_active_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(skew_active)
	var skew_active_mesh := ArrayMesh.new()
	skew_active_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, skew_active_arrays)
	var skew_parent := Node3D.new()
	skew_parent.position = skew_offset
	root.add_child(skew_parent)
	var skew_source_instance := MeshInstance3D.new()
	skew_source_instance.mesh = skew_source_mesh
	skew_parent.add_child(skew_source_instance)
	var skew_active_instance := MeshInstance3D.new()
	skew_active_instance.mesh = skew_active_mesh
	skew_parent.add_child(skew_active_instance)
	var skew_index: Dictionary = RoadMask.build_spatial_index(RoadMask.collect_world_triangles(skew_active_instance))
	var skew_clipped: ArrayMesh = RoadMask.clip_mesh_instance(skew_source_instance, skew_index)
	var skew_arrays: Array = skew_clipped.surface_get_arrays(0)
	var skew_vertices: PackedVector3Array = skew_arrays[Mesh.ARRAY_VERTEX]
	var skew_candidate_area := 0.0
	for i in range(0, skew_vertices.size(), 3):
		skew_candidate_area += _stable_area2([skew_vertices[i], skew_vertices[i + 1], skew_vertices[i + 2]])
	_check(absf(skew_candidate_area - skew_reference_area) < 5e-4, "Large-coordinate mesh clipping must preserve area within the expected translated-float32 bound, got %s vs %s" % [str(skew_candidate_area), str(skew_reference_area)])
	_check(skew_arrays[Mesh.ARRAY_TEX_UV].size() == skew_vertices.size(), "Large-coordinate clipping must retain interpolated UV arrays")
	skew_parent.free()
	var high_crossing := [Vector3(0, 3, 0), Vector3(2, 5, 0), Vector3(0, 3, 2)]
	var ownership_035 := RoadMask.mask_triangle(high_crossing, [active], 0.35)
	_check(ownership_035.size() == 1 and absf(_stable_area2(ownership_035[0]) - 4.0) < 1e-7, "0.35 m display ownership tolerance must retain a 3 m separated road")
	var boundary: Vector3 = fragments[0][0]
	var weights: Vector3 = RoadMask.barycentric_xz(boundary, extra)
	var uv: Vector2 = RoadMask.interpolate_attribute(Vector2(0, 0), Vector2(4, 0), Vector2(0, 4), weights)
	_check(absf(uv.x - boundary.x) < 1e-7 and absf(uv.y - boundary.z) < 1e-7, "New clipped vertices must interpolate source UV attributes")
	var elevated := [Vector3(0, 3, 0), Vector3(2, 5, 0), Vector3(0, 3, 2)]
	var elevated_fragments: Array = RoadMask.mask_triangle(elevated, [active])
	var elevated_area2 := 0.0
	for fragment in elevated_fragments: elevated_area2 += _area2(fragment)
	_check(absf(elevated_area2 - 4.0) < 1e-7, "Different-height crossing road must survive the active footprint")
	var different_triangulation := [
		[Vector3(0, 0, 0), Vector3(2, 0, 0), Vector3(0, 0, 2)],
		[Vector3(2, 0, 0), Vector3(2, 0, 2), Vector3(0, 0, 2)]]
	var triangulation_fragments: Array = RoadMask.mask_triangle([Vector3(0, 0, 0), Vector3(4, 0, 0), Vector3(0, 0, 4)], different_triangulation)
	var triangulation_area2 := 0.0
	for fragment in triangulation_fragments: triangulation_area2 += _stable_area2(fragment)
	_check(absf(triangulation_area2 - 8.0) < 1e-6, "Partial ownership must work across a differently triangulated active square; area2=%s" % str(triangulation_area2))
	var crossing := [Vector3(0, -1, 0), Vector3(4, 7, 0), Vector3(0, -1, 4)]
	var crossing_fragments: Array = RoadMask.mask_triangle(crossing, [active])
	var crossing_area2 := 0.0
	for fragment in crossing_fragments: crossing_area2 += _area2(fragment)
	_check(crossing_area2 < 16.0 and crossing_area2 > 12.0, "Sloped height crossing must mask only the narrow same-level band")
	var no_mask: Array = RoadMask.mask_triangle(extra, [])
	_check(no_mask.size() == 1 and absf(_area2(no_mask[0]) - 16.0) < 1e-7, "No active road means unchanged source triangle")
	var source_mesh := ArrayMesh.new()
	var source_arrays: Array = []
	source_arrays.resize(Mesh.ARRAY_MAX)
	source_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(extra)
	source_arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	source_arrays[Mesh.ARRAY_TANGENT] = PackedFloat32Array([1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1])
	source_arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2(4, 0), Vector2(0, 4)])
	source_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	source_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, source_arrays)
	var authored := StandardMaterial3D.new()
	authored.albedo_color = Color.DARK_RED
	source_mesh.surface_set_material(0, authored)
	source_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, source_arrays)
	var second_material := StandardMaterial3D.new()
	second_material.albedo_color = Color.DARK_BLUE
	source_mesh.surface_set_material(1, second_material)
	var active_mesh := ArrayMesh.new()
	var active_arrays: Array = []
	active_arrays.resize(Mesh.ARRAY_MAX)
	active_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(active)
	active_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, active_arrays)
	var active_material := StandardMaterial3D.new()
	active_material.albedo_color = Color.BLUE
	active_mesh.surface_set_material(0, active_material)
	var active_instance := MeshInstance3D.new()
	active_instance.mesh = active_mesh
	root.add_child(active_instance)
	var instance := MeshInstance3D.new()
	instance.mesh = source_mesh
	root.add_child(instance)
	var active_tris: Array = RoadMask.collect_world_triangles(active_instance)
	var active_index: Dictionary = RoadMask.build_spatial_index(active_tris)
	var clipped: ArrayMesh = RoadMask.clip_mesh_instance(instance, active_index)
	_check(clipped != null and clipped.get_surface_count() == 2, "Mesh clipping must retain both material surfaces")
	_check(clipped.surface_get_material(0) == authored, "Clipped road must preserve its authored material resource")
	_check(clipped.surface_get_material(1) == second_material, "Surface material mapping must survive clipping")
	_check(active_instance.mesh == active_mesh and active_mesh.surface_get_material(0) == active_material, "Active conflicting-material road must remain untouched")
	_check(RoadMask.query_spatial_index(active_index, extra).size() == 1, "Spatial index returns nearby active triangles")
	_check(RoadMask.query_spatial_index(active_index, [Vector3(100, 0, 100), Vector3(104, 0, 100), Vector3(100, 0, 104)]).is_empty(), "Spatial index avoids distant all-pairs candidates")
	var same_cell_disjoint := [Vector3(10, 0, 10), Vector3(11, 0, 10), Vector3(10, 0, 11)]
	var edge_touching := [Vector3(4, 0, 0), Vector3(5, 0, 0), Vector3(4, 0, 2)]
	var same_cell_index: Dictionary = RoadMask.build_spatial_index([same_cell_disjoint, edge_touching], 20.0)
	var same_cell_result: Array = RoadMask.query_spatial_index(same_cell_index, extra)
	_check(same_cell_result.size() == 1 and same_cell_result[0][0] == edge_touching[0], "Same-cell query must filter disjoint bounds but retain a touching boundary candidate")
	var touching_direct: Array = RoadMask.mask_triangle(extra, [edge_touching])
	var touching_indexed: Array = RoadMask.mask_triangle(extra, same_cell_result)
	var touching_direct_area := 0.0
	var touching_indexed_area := 0.0
	for piece in touching_direct: touching_direct_area += _stable_area2(piece)
	for piece in touching_indexed: touching_indexed_area += _stable_area2(piece)
	_check(absf(touching_direct_area - touching_indexed_area) < 1e-7 and absf(touching_indexed_area - 16.0) < 1e-7, "Exact AABB boundary contact must not change direct/indexed geometry")
	var negative_extra := [Vector3(-21, 0, -19), Vector3(-17, 0, -19), Vector3(-21, 0, -15)]
	var negative_active := [Vector3(-21, 0, -19), Vector3(-19, 0, -19), Vector3(-21, 0, -17)]
	var negative_index: Dictionary = RoadMask.build_spatial_index([negative_active], 20.0)
	var indexed_negative: Array = RoadMask.mask_triangle(negative_extra, RoadMask.query_spatial_index(negative_index, negative_extra))
	var direct_negative: Array = RoadMask.mask_triangle(negative_extra, [negative_active])
	var indexed_negative_area := 0.0
	var direct_negative_area := 0.0
	for piece in indexed_negative: indexed_negative_area += _area2(piece)
	for piece in direct_negative: direct_negative_area += _area2(piece)
	_check(absf(indexed_negative_area - direct_negative_area) < 1e-7, "Spatial-index masking matches direct masking across negative cell boundaries")
	var clipped_arrays: Array = clipped.surface_get_arrays(0)
	_check(clipped_arrays[Mesh.ARRAY_VERTEX].size() > 3 and clipped_arrays[Mesh.ARRAY_TEX_UV].size() == clipped_arrays[Mesh.ARRAY_VERTEX].size(), "Generated mesh vertices must retain matching interpolated UV attributes")
	_check(clipped_arrays[Mesh.ARRAY_NORMAL].size() == clipped_arrays[Mesh.ARRAY_VERTEX].size() and clipped_arrays[Mesh.ARRAY_TANGENT].size() == clipped_arrays[Mesh.ARRAY_VERTEX].size() * 4, "Indexed source normal/tangent attributes must be preserved")
	var clipped_area2 := 0.0
	for i in range(0, clipped_arrays[Mesh.ARRAY_VERTEX].size(), 3):
		var clipped_tri := [clipped_arrays[Mesh.ARRAY_VERTEX][i], clipped_arrays[Mesh.ARRAY_VERTEX][i + 1], clipped_arrays[Mesh.ARRAY_VERTEX][i + 2]]
		clipped_area2 += absf(RoadMask.triangle_xz_area2(clipped_tri))
	_check(absf(clipped_area2 - 12.0) < 1e-6, "Clipped MeshInstance surface must preserve the uncovered area")
	_check(RoadMask.clip_mesh_instance(instance, []) == source_mesh, "Each remask must begin from the unchanged original mesh")
	var fully_masked: ArrayMesh = RoadMask.clip_mesh_instance(instance, [extra])
	_check(fully_masked.get_surface_count() == 0, "Fully covered extra road must not emit empty material surfaces")
	instance.free()
	active_instance.free()
	var shifted_parent := Node3D.new()
	shifted_parent.position = Vector3(10, 0, 5)
	root.add_child(shifted_parent)
	var shifted_instance := MeshInstance3D.new()
	shifted_instance.mesh = source_mesh
	shifted_parent.add_child(shifted_instance)
	var shifted_active: Array = []
	for p in active: shifted_active.append(p + Vector3(10, 0, 5))
	var shifted_clip: ArrayMesh = RoadMask.clip_mesh_instance(shifted_instance, [shifted_active])
	_check(shifted_clip.get_surface_count() == 2, "Clipping must use the full parent world transform")
	var shifted_positions: PackedVector3Array = shifted_clip.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var local_coordinates_valid := true
	for p in shifted_positions:
		local_coordinates_valid = local_coordinates_valid and p.x >= -1e-7 and p.x <= 4.0000001 and p.z >= -1e-7 and p.z <= 4.0000001
	_check(local_coordinates_valid, "Clipped vertices must be returned in original mesh-local coordinates")
	_check(RoadMask.collect_world_triangles(shifted_parent).size() == 2, "World triangle collection must include parent transforms")
	shifted_parent.free()
	if failures == 0: print("PACKAGE_ROAD_MASK_TEST_OK")
	quit(1 if failures else 0)
