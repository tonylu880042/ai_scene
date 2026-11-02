class_name SaisiesGeoRoadbed
extends Node3D

## Narrow continuous soil/gravel shoulders between the geographic asphalt edge
## and the rendered DEM.  This is a local roadbed seam, not a second terrain
## surface: every outer vertex is sampled from SaisiesGeoLandscape's actual
## triangle mesh.

@export var route_path: NodePath
@export var landscape_path: NodePath
@export var skirt_width_m := 4.0
@export var edge_offset_m := 0.05

const ROADBED_SINK_M := 0.03

var route: Node
var landscape: Node
var roadbed_ready := false
var _build_attempts := 0

func _ready() -> void:
	call_deferred("_try_build")

func _try_build() -> void:
	if roadbed_ready:
		return
	_resolve_route()
	_resolve_landscape()
	if route == null or not route.has_method("route_ready") or not bool(route.call("route_ready")):
		_build_attempts += 1
		if _build_attempts < 48:
			call_deferred("_try_build")
		else:
			push_error("SaisiesGeoRoadbed requires a ready geographic route")
		return
	if landscape == null or not landscape.has_method("sample_mesh_triangle"):
		_build_attempts += 1
		if _build_attempts < 48:
			call_deferred("_try_build")
		else:
			push_error("SaisiesGeoRoadbed requires Landscape.sample_mesh_triangle")
		return
	if not _landscape_ready():
		_build_attempts += 1
		if _build_attempts < 48:
			call_deferred("_try_build")
		else:
			push_error("SaisiesGeoRoadbed requires a ready geographic landscape")
		return
	_build()

func _resolve_route() -> void:
	if route != null:
		return
	if route_path != NodePath():
		route = get_node_or_null(route_path)
	if route == null and get_parent() != null:
		route = get_parent().get_node_or_null("Route")

func _resolve_landscape() -> void:
	if landscape != null:
		return
	if landscape_path != NodePath():
		landscape = get_node_or_null(landscape_path)
	if landscape == null and get_parent() != null:
		landscape = get_parent().get_node_or_null("Landscape")

func _landscape_ready() -> bool:
	if landscape == null:
		return false
	for item in landscape.get_property_list():
		if String(item.get("name", "")) == "landscape_ready":
			return bool(landscape.get("landscape_ready"))
	return false

func _build() -> void:
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var length_m := float(route.get("length_m"))
	var spacing := maxf(float(route.get("sample_spacing_m")), 0.25)
	var segment_count := maxi(int(ceil(length_m / spacing)), 1)
	var missing_outer := 0
	var strip_count := 0
	var max_gap := -INF
	var min_gap := INF
	for index in range(segment_count):
		var s0 := minf(float(index) * spacing, length_m)
		var s1 := minf(float(index + 1) * spacing, length_m)
		if s1 <= s0 + 0.001:
			continue
		for side_variant in [-1.0, 1.0]:
			var side: float = float(side_variant)
			var edge0 := _edge_sample(s0, side)
			var edge1 := _edge_sample(s1, side)
			if edge0.is_empty() or edge1.is_empty():
				missing_outer += 1
				continue
			var inner0: Vector3 = edge0["inner"]
			var outer0: Vector3 = edge0["outer"]
			var inner1: Vector3 = edge1["inner"]
			var outer1: Vector3 = edge1["outer"]
			max_gap = maxf(max_gap, float(edge0["gap"]))
			max_gap = maxf(max_gap, float(edge1["gap"]))
			min_gap = minf(min_gap, float(edge0["gap"]))
			min_gap = minf(min_gap, float(edge1["gap"]))
			_append_strip_quad(vertices, uvs, indices, inner0, outer0, inner1, outer1, side, s0, s1)
			strip_count += 1
	if missing_outer > 0:
		push_error("SaisiesGeoRoadbed could not sample %d outer segment endpoints" % missing_outer)
		return
	if strip_count == 0:
		push_error("SaisiesGeoRoadbed built no strips")
		return
	var normals := _normals_from_faces(vertices, indices)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.name = "SaisiesGeoRoadbedMesh"
	instance.mesh = mesh
	instance.material_override = _roadbed_material()
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	instance.extra_cull_margin = 100.0
	add_child(instance)
	set_meta("saisies_geo_roadbed_ready", true)
	set_meta("saisies_geo_roadbed_strip_count", strip_count)
	set_meta("saisies_geo_roadbed_vertex_count", vertices.size())
	set_meta("saisies_geo_roadbed_triangle_count", indices.size() / 3)
	set_meta("saisies_geo_roadbed_skirt_width_m", skirt_width_m)
	set_meta("saisies_geo_roadbed_max_gap_m", max_gap)
	set_meta("saisies_geo_roadbed_min_gap_m", min_gap)
	set_meta("saisies_geo_roadbed_ground_source", "landscape.sample_mesh_triangle")
	roadbed_ready = true
	print("saisies geo roadbed: strips=%d vertices=%d triangles=%d max_gap=%.3fm min_gap=%.3fm" % [strip_count, vertices.size(), indices.size() / 3, max_gap, min_gap])

func _edge_sample(s: float, side: float) -> Dictionary:
	var centre: Vector3 = route.call("pos_at", s)
	var left: Vector3 = route.call("left_at", s)
	var half := float(route.call("road_width_at", s)) * 0.5
	var inner_u := side * (half + edge_offset_m)
	var outer_u := side * (half + maxf(skirt_width_m, 0.5))
	var inner_xz := centre + left * inner_u
	var outer_xz := centre + left * outer_u
	var sampled = landscape.call("sample_mesh_triangle", Vector2(outer_xz.x, outer_xz.z))
	if not (sampled is Dictionary) or not sampled.has("height") or not is_finite(float(sampled["height"])):
		return {}
	var road_y := float(route.call("_road_y", s, side * half))
	var outer_y := float(sampled["height"])
	return {
		"inner": Vector3(inner_xz.x, road_y - ROADBED_SINK_M, inner_xz.z),
		"outer": Vector3(outer_xz.x, outer_y, outer_xz.z),
		"gap": road_y - outer_y
	}

func _append_strip_quad(vertices: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array, inner0: Vector3, outer0: Vector3, inner1: Vector3, outer1: Vector3, side: float, s0: float, s1: float) -> void:
	var base := vertices.size()
	vertices.append(inner0)
	vertices.append(outer0)
	vertices.append(inner1)
	vertices.append(outer1)
	uvs.append(Vector2(0.0, s0 * 0.04))
	uvs.append(Vector2(1.0, s0 * 0.04))
	uvs.append(Vector2(0.0, s1 * 0.04))
	uvs.append(Vector2(1.0, s1 * 0.04))
	# Both triangles use Godot's clockwise front winding when viewed from
	# above.  The side-dependent order keeps their lighting normals +Y.
	if side > 0.0:
		indices.append(base); indices.append(base + 3); indices.append(base + 2)
		indices.append(base); indices.append(base + 1); indices.append(base + 3)
	else:
		indices.append(base); indices.append(base + 3); indices.append(base + 1)
		indices.append(base); indices.append(base + 2); indices.append(base + 3)

func _normals_from_faces(vertices: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	for face_start in range(0, indices.size(), 3):
		var a := vertices[indices[face_start]]
		var b := vertices[indices[face_start + 1]]
		var c := vertices[indices[face_start + 2]]
		var normal := (c - a).cross(b - a)
		if normal.length_squared() > 0.000001:
			normal = normal.normalized()
			normals[indices[face_start]] += normal
			normals[indices[face_start + 1]] += normal
			normals[indices[face_start + 2]] += normal
	for index in range(normals.size()):
		if normals[index].length_squared() < 0.000001:
			normals[index] = Vector3.UP
		else:
			normals[index] = normals[index].normalized()
	return normals

func _roadbed_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.34, 0.36, 0.30, 1.0)
	material.roughness = 0.96
	material.metallic = 0.0
	return material
