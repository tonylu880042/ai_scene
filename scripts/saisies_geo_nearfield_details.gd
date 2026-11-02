class_name SaisiesGeoNearfieldDetails
extends Node3D

## Closed, local S13 rock cut and bounded S09 low stone wall for the
## geographic staging scene.
##
## The visible wall is limited to the short 627.5--632.5 s source interval.
## Its road toe and its uphill back/top contacts are sampled from the actual
## rendered landscape mesh, so this detail cannot silently use a coarse DEM or
## a guessed route elevation.

@export var route_path: NodePath
@export var landscape_path: NodePath
@export var start_video_seconds := 627.5
@export var end_video_seconds := 632.5
@export var sample_spacing_m := 0.5
@export var s09_start_video_seconds := 328.0
@export var s09_end_video_seconds := 336.0
@export var s09_sample_spacing_m := 1.25

const FRONT_MIN_CLEARANCE_M := 0.45
const EMBED_DEPTH_M := 0.10
const END_TAPER_M := 8.0
const MIN_HEIGHT_M := 5.0
const MAX_HEIGHT_M := 10.0
const MAX_TRIANGLES := 12000
const S09_MAX_TRIANGLES := 10000
const S09_REFERENCE_STATION_M := 5431.282674
const S09_FRONT_CLEARANCE_M := 1.05
const S09_EMBED_DEPTH_M := 0.15
const S09_END_TAPER_M := 12.0
const S09_MIN_HEIGHT_M := 0.95
const S09_MAX_HEIGHT_M := 1.60
const S09_BANK_OFFSET_M := 0.025
const S09_BANK_EDGE_MIN_WIDTH_M := 3.5
const S09_BANK_EDGE_MAX_WIDTH_M := 9.6
const LAYER_T := [0.0, 0.12, 0.27, 0.44, 0.63, 0.82, 1.0]

var route: Node
var landscape: Node
var details_ready := false
var _build_attempts := 0
var _s0 := 0.0
var _s1 := 0.0
var _s09_s0 := 0.0
var _s09_s1 := 0.0
var _mesh_instance: MeshInstance3D
var _s09_wall_instance: MeshInstance3D
var _s09_bank_instance: MeshInstance3D
var _mesh_vertices := PackedVector3Array()
var _mesh_normals := PackedVector3Array()
var _mesh_uvs := PackedVector2Array()
var _mesh_indices := PackedInt32Array()
var _base_contact_records: Array = []
var _height_records: Array = []
var _front_lateral_records: Array = []
var _s09_vertices := PackedVector3Array()
var _s09_normals := PackedVector3Array()
var _s09_uvs := PackedVector2Array()
var _s09_indices := PackedInt32Array()
var _s09_bank_vertices := PackedVector3Array()
var _s09_bank_normals := PackedVector3Array()
var _s09_bank_tangents := PackedFloat32Array()
var _s09_bank_uvs := PackedVector2Array()
var _s09_bank_indices := PackedInt32Array()
var _s09_base_contact_records: Array = []
var _s09_height_records: Array = []
var _s09_front_lateral_records: Array = []
var _s09_bank_contact_records: Array = []

func _ready() -> void:
	call_deferred("_try_build")

func _try_build() -> void:
	if details_ready:
		return
	_resolve_route()
	_resolve_landscape()
	if route == null or not route.has_method("route_ready") or not bool(route.call("route_ready")):
		_retry_or_fail("SaisiesGeoNearfieldDetails requires a ready route")
		return
	if landscape == null or not landscape.has_method("sample_mesh_triangle"):
		_retry_or_fail("SaisiesGeoNearfieldDetails requires landscape.sample_mesh_triangle")
		return
	if landscape.get("landscape_ready") != true:
		_retry_or_fail("SaisiesGeoNearfieldDetails requires a ready landscape mesh")
		return
	_build()

func _retry_or_fail(message: String) -> void:
	_build_attempts += 1
	if _build_attempts < 48:
		call_deferred("_try_build")
	else:
		push_error(message)

func _resolve_route() -> void:
	if route != null:
		return
	if not route_path.is_empty():
		route = get_node_or_null(route_path)
	if route == null and get_parent() != null:
		route = get_parent().get_node_or_null("Route")

func _resolve_landscape() -> void:
	if landscape != null:
		return
	if not landscape_path.is_empty():
		landscape = get_node_or_null(landscape_path)
	if landscape == null and get_parent() != null:
		landscape = get_parent().get_node_or_null("Landscape")

func _build() -> void:
	_s0 = clampf(float(route.call("distance_for_video_seconds", start_video_seconds)), 0.0, float(route.get("length_m")))
	_s1 = clampf(float(route.call("distance_for_video_seconds", end_video_seconds)), 0.0, float(route.get("length_m")))
	if _s1 < _s0:
		var swap_s := _s0
		_s0 = _s1
		_s1 = swap_s
	if _s1 <= _s0 + 10.0:
		push_error("SaisiesGeoNearfieldDetails S13 interval is too short")
		return
	var spacing := clampf(sample_spacing_m, 0.5, 5.0)
	var sample_count := maxi(int(ceil((_s1 - _s0) / spacing)), 2)
	var columns: Array = []
	for i in range(sample_count + 1):
		var s := lerpf(_s0, _s1, float(i) / float(sample_count))
		var column := _make_column(s)
		if column.is_empty():
			push_error("SaisiesGeoNearfieldDetails could not sample uphill landscape at s=%.3f" % s)
			return
		columns.append(column)
	var min_back_top_u := INF
	var max_back_top_u := -INF
	var min_back_top_ground := INF
	var max_back_top_ground := -INF
	for column in columns:
		min_back_top_u = minf(min_back_top_u, float(column["back_top_u"]))
		max_back_top_u = maxf(max_back_top_u, float(column["back_top_u"]))
		min_back_top_ground = minf(min_back_top_ground, float(column["back_top_ground"]))
		max_back_top_ground = maxf(max_back_top_ground, float(column["back_top_ground"]))
	_build_surface(columns)
	if _mesh_indices.size() / 3 > MAX_TRIANGLES:
		push_error("SaisiesGeoNearfieldDetails triangle budget exceeded: %d" % (_mesh_indices.size() / 3))
		return
	if _mesh_vertices.is_empty() or _mesh_indices.is_empty():
		push_error("SaisiesGeoNearfieldDetails produced an empty mesh")
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _mesh_vertices
	arrays[Mesh.ARRAY_NORMAL] = _mesh_normals
	arrays[Mesh.ARRAY_TEX_UV] = _mesh_uvs
	arrays[Mesh.ARRAY_INDEX] = _mesh_indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := _rock_material()
	mesh.surface_set_material(0, material)
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "SaisiesGeoNearfieldS13RockWall"
	_mesh_instance.mesh = mesh
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_mesh_instance.extra_cull_margin = 80.0
	add_child(_mesh_instance)
	if not _build_s09_geometry():
		push_error("SaisiesGeoNearfieldDetails could not build S09 low stone wall")
		return
	details_ready = true
	set_meta("saisies_geo_nearfield_details_ready", true)
	set_meta("saisies_geo_nearfield_details_s0_m", _s0)
	set_meta("saisies_geo_nearfield_details_s1_m", _s1)
	set_meta("saisies_geo_nearfield_details_triangle_count", _mesh_indices.size() / 3)
	set_meta("saisies_geo_nearfield_details_vertex_count", _mesh_vertices.size())
	set_meta("saisies_geo_nearfield_details_base_contact_records", _base_contact_records)
	set_meta("saisies_geo_nearfield_details_height_records", _height_records)
	set_meta("saisies_geo_nearfield_details_front_lateral_records", _front_lateral_records)
	set_meta("saisies_geo_nearfield_details_back_top_u_range", Vector2(min_back_top_u, max_back_top_u))
	set_meta("saisies_geo_nearfield_details_back_top_ground_range", Vector2(min_back_top_ground, max_back_top_ground))
	set_meta("saisies_geo_nearfield_s09_ready", true)
	set_meta("saisies_geo_nearfield_s09_s0_m", _s09_s0)
	set_meta("saisies_geo_nearfield_s09_s1_m", _s09_s1)
	set_meta("saisies_geo_nearfield_s09_triangle_count", _s09_indices.size() / 3)
	set_meta("saisies_geo_nearfield_s09_bank_triangle_count", _s09_bank_indices.size() / 3)
	set_meta("saisies_geo_nearfield_s09_vertex_count", _s09_vertices.size())
	set_meta("saisies_geo_nearfield_s09_bank_vertex_count", _s09_bank_vertices.size())
	set_meta("saisies_geo_nearfield_s09_base_contact_records", _s09_base_contact_records)
	set_meta("saisies_geo_nearfield_s09_height_records", _s09_height_records)
	set_meta("saisies_geo_nearfield_s09_front_lateral_records", _s09_front_lateral_records)
	set_meta("saisies_geo_nearfield_s09_bank_contact_records", _s09_bank_contact_records)
	print("geo nearfield details built s=%.2f..%.2f vertices=%d triangles=%d base_contacts=%d" % [_s0, _s1, _mesh_vertices.size(), _mesh_indices.size() / 3, _base_contact_records.size()])
	print("geo nearfield uphill back_top_u=%.2f..%.2f ground=%.2f..%.2f" % [min_back_top_u, max_back_top_u, min_back_top_ground, max_back_top_ground])
	print("geo nearfield S09 low wall built s=%.2f..%.2f wall_vertices=%d wall_triangles=%d bank_vertices=%d bank_triangles=%d base_contacts=%d" % [_s09_s0, _s09_s1, _s09_vertices.size(), _s09_indices.size() / 3, _s09_bank_vertices.size(), _s09_bank_indices.size() / 3, _s09_base_contact_records.size()])

func _build_s09_geometry() -> bool:
	_s09_s0 = clampf(float(route.call("distance_for_video_seconds", s09_start_video_seconds)), 0.0, float(route.get("length_m")))
	_s09_s1 = clampf(float(route.call("distance_for_video_seconds", s09_end_video_seconds)), 0.0, float(route.get("length_m")))
	if _s09_s1 < _s09_s0:
		var swap_s := _s09_s0
		_s09_s0 = _s09_s1
		_s09_s1 = swap_s
	if _s09_s1 <= _s09_s0 + 20.0:
		push_error("SaisiesGeoNearfieldDetails S09 interval is too short")
		return false
	var source_station := float(route.call("distance_for_video_seconds", 330.0))
	if absf(source_station - S09_REFERENCE_STATION_M) > 8.0:
		push_error("SaisiesGeoNearfieldDetails S09 station drift %.3f vs frozen %.3f" % [source_station, S09_REFERENCE_STATION_M])
		return false
	var spacing := clampf(s09_sample_spacing_m, 0.75, 3.0)
	var sample_count := maxi(int(ceil((_s09_s1 - _s09_s0) / spacing)), 2)
	var columns: Array = []
	for i in range(sample_count + 1):
		var s := lerpf(_s09_s0, _s09_s1, float(i) / float(sample_count))
		var column := _make_s09_column(s)
		if column.is_empty():
			push_error("SaisiesGeoNearfieldDetails could not sample S09 bank at s=%.3f" % s)
			return false
		columns.append(column)

	# Reuse the proven watertight column surface builder while isolating all
	# S09 arrays and UV time bounds from the S13 rock-cut state.
	var saved_s0 := _s0
	var saved_s1 := _s1
	var saved_vertices := _mesh_vertices
	var saved_normals := _mesh_normals
	var saved_uvs := _mesh_uvs
	var saved_indices := _mesh_indices
	var saved_contacts := _base_contact_records
	var saved_heights := _height_records
	var saved_relief := _front_lateral_records
	_s0 = _s09_s0
	_s1 = _s09_s1
	_build_surface(columns)
	_s09_vertices = _mesh_vertices
	_s09_normals = _mesh_normals
	_s09_uvs = _mesh_uvs
	_s09_indices = _mesh_indices
	_s09_base_contact_records = _base_contact_records.duplicate(true)
	_s09_height_records = _height_records.duplicate(true)
	_s09_front_lateral_records = _front_lateral_records.duplicate(true)
	_build_s09_bank_surface(columns)
	_mesh_vertices = saved_vertices
	_mesh_normals = saved_normals
	_mesh_uvs = saved_uvs
	_mesh_indices = saved_indices
	_base_contact_records = saved_contacts
	_height_records = saved_heights
	_front_lateral_records = saved_relief
	_s0 = saved_s0
	_s1 = saved_s1

	if _s09_indices.is_empty() or _s09_bank_indices.is_empty() or _s09_base_contact_records.is_empty():
		return false
	if _s09_indices.size() / 3 + _s09_bank_indices.size() / 3 > S09_MAX_TRIANGLES:
		push_error("SaisiesGeoNearfieldDetails S09 triangle budget exceeded: wall=%d bank=%d" % [_s09_indices.size() / 3, _s09_bank_indices.size() / 3])
		return false

	var wall_arrays := []
	wall_arrays.resize(Mesh.ARRAY_MAX)
	wall_arrays[Mesh.ARRAY_VERTEX] = _s09_vertices
	wall_arrays[Mesh.ARRAY_NORMAL] = _s09_normals
	wall_arrays[Mesh.ARRAY_TEX_UV] = _s09_uvs
	wall_arrays[Mesh.ARRAY_INDEX] = _s09_indices
	var wall_mesh := ArrayMesh.new()
	wall_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, wall_arrays)
	wall_mesh.surface_set_material(0, _s09_wall_material())
	_s09_wall_instance = MeshInstance3D.new()
	_s09_wall_instance.name = "SaisiesGeoNearfieldS09LowStoneWall"
	_s09_wall_instance.mesh = wall_mesh
	_s09_wall_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_s09_wall_instance.extra_cull_margin = 80.0
	add_child(_s09_wall_instance)

	var bank_arrays := []
	bank_arrays.resize(Mesh.ARRAY_MAX)
	bank_arrays[Mesh.ARRAY_VERTEX] = _s09_bank_vertices
	bank_arrays[Mesh.ARRAY_NORMAL] = _s09_bank_normals
	# The bank uses the same world-XZ detail UV as the terrain shader.  Keep
	# its tangent frame tied to that mapping rather than the wall-course UVs.
	_s09_bank_tangents = _tangents_from_world_xz(_s09_bank_vertices, _s09_bank_indices, _s09_bank_normals)
	bank_arrays[Mesh.ARRAY_TANGENT] = _s09_bank_tangents
	bank_arrays[Mesh.ARRAY_TEX_UV] = _s09_bank_uvs
	bank_arrays[Mesh.ARRAY_INDEX] = _s09_bank_indices
	var bank_mesh := ArrayMesh.new()
	bank_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, bank_arrays)
	bank_mesh.surface_set_material(0, _s09_bank_material())
	_s09_bank_instance = MeshInstance3D.new()
	_s09_bank_instance.name = "SaisiesGeoNearfieldS09GrassBank"
	_s09_bank_instance.mesh = bank_mesh
	_s09_bank_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_s09_bank_instance.extra_cull_margin = 80.0
	add_child(_s09_bank_instance)
	return true

func _make_s09_column(s: float) -> Dictionary:
	var route_position: Vector3 = route.call("pos_at", s)
	var left: Vector3 = route.call("left_at", s)
	var half := float(route.call("road_width_at", s)) * 0.5
	var taper := _s09_taper(s)
	var block_phase := floorf((s - _s09_s0) / 2.15)
	var broad_variation := 0.5 + 0.5 * sin(block_phase * 1.71 + 0.35)
	var base_u := half + S09_FRONT_CLEARANCE_M + 0.10 + 0.10 * broad_variation
	var base_xz := Vector2(route_position.x, route_position.z) + Vector2(left.x, left.z) * base_u
	var base_ground := _actual_ground(base_xz)
	if not is_finite(base_ground):
		return {}
	var base_y := base_ground - S09_EMBED_DEPTH_M
	var full_height := clampf(1.24 + 0.16 * sin(block_phase * 1.31 + 0.7) + 0.10 * cos(block_phase * 0.73 - 0.4), S09_MIN_HEIGHT_M, S09_MAX_HEIGHT_M)
	var height := full_height * taper
	var front: Array = []
	var front_us: Array = []
	var previous_u := base_u
	for layer_index in range(LAYER_T.size()):
		var layer_t := float(LAYER_T[layer_index])
		var course_wave := 0.035 * sin(block_phase * 2.17 + float(layer_index) * 1.41)
		var course_ledge := 0.035 * cos(block_phase * 1.23 - float(layer_index) * 0.87)
		var u := base_u if layer_index == 0 else base_u + 0.10 + 0.07 * broad_variation + course_wave + 0.025 * float(layer_index % 2)
		if layer_index > 0:
			u = maxf(u, previous_u - 0.08)
		var xz := base_xz if layer_index == 0 else Vector2(route_position.x, route_position.z) + Vector2(left.x, left.z) * u
		var y_jitter := 0.018 * sin(block_phase * 1.47 + float(layer_index) * 2.23) if layer_index > 0 else 0.0
		var point := Vector3(xz.x, base_y + height * layer_t + course_ledge * taper + y_jitter * taper, xz.y)
		front.append(point)
		front_us.append(u)
		previous_u = u
	var back_u := base_u + 0.62 + 0.06 * broad_variation
	var back_xz := Vector2(route_position.x, route_position.z) + Vector2(left.x, left.z) * back_u
	var back_ground := _actual_ground(back_xz)
	if not is_finite(back_ground):
		return {}
	var back_lower := Vector3(back_xz.x, back_ground - S09_EMBED_DEPTH_M, back_xz.y)
	var back_top := Vector3(back_xz.x, front[LAYER_T.size() - 1].y + 0.015, back_xz.y)
	# The old implementation independently searched a 1 m grid for every
	# column.  That made the uphill edge jump sideways whenever the DEM had a
	# small local step, leaving a visibly detached grass platform.  Keep the
	# edge in one smooth route-local control curve and sample the actual mesh at
	# that point instead.
	var outer := _s09_smooth_bank_contact(route_position, left, half, s, taper)
	if outer.is_empty():
		return {}
	var outer_u := float(outer["u"])
	var outer_ground := float(outer["ground"])
	var shoulder1_u := lerpf(back_u, outer_u, 0.30)
	var shoulder2_u := lerpf(back_u, outer_u, 0.68)
	var shoulder1_xz := Vector2(route_position.x, route_position.z) + Vector2(left.x, left.z) * shoulder1_u
	var shoulder2_xz := Vector2(route_position.x, route_position.z) + Vector2(left.x, left.z) * shoulder2_u
	var shoulder1_ground := _actual_ground(shoulder1_xz)
	var shoulder2_ground := _actual_ground(shoulder2_xz)
	if not is_finite(shoulder1_ground) or not is_finite(shoulder2_ground):
		return {}
	var bank_inner := back_top + Vector3.UP * S09_BANK_OFFSET_M
	var inner_y := bank_inner.y
	var outer_y := outer_ground + S09_BANK_OFFSET_M
	# Follow the actual terrain whenever it rises above the nominal slope.
	# This prevents a second floating shelf while keeping the wall-to-ground
	# transition continuous through two broad, low-frequency shoulders.
	var shoulder1_y := maxf(shoulder1_ground + S09_BANK_OFFSET_M, lerpf(inner_y, outer_y, 0.30))
	var shoulder2_y := maxf(shoulder2_ground + S09_BANK_OFFSET_M, lerpf(inner_y, outer_y, 0.68))
	var bank_shoulder1 := Vector3(shoulder1_xz.x, shoulder1_y, shoulder1_xz.y)
	var bank_shoulder2 := Vector3(shoulder2_xz.x, shoulder2_y, shoulder2_xz.y)
	var bank_outer := Vector3(route_position.x + left.x * outer_u, outer_ground + S09_BANK_OFFSET_M, route_position.z + left.z * outer_u)
	return {
		"s": s,
		"half": half,
		"left": left,
		"base_u": base_u,
		"front": front,
		"front_us": front_us,
		"back_lower": back_lower,
		"back_top": back_top,
		"back_lower_u": back_u,
		"back_top_u": back_u,
		"back_lower_ground": back_ground,
		"back_top_ground": back_top.y,
		"height": height,
		"core_height": full_height,
		"bank_points": [bank_inner, bank_shoulder1, bank_shoulder2, bank_outer],
		"bank_outer_u": outer_u,
		"bank_outer_ground": outer_ground
	}

func _s09_smooth_bank_contact(route_position: Vector3, left: Vector3, half: float, s: float, taper: float) -> Dictionary:
	var span := maxf(_s09_s1 - _s09_s0, 0.001)
	var t := clampf((s - _s09_s0) / span, 0.0, 1.0)
	# A low-frequency width curve keeps the edge irregular enough to read as
	# natural ground without allowing per-column DEM noise to form zigzags.
	var centre_width := 8.85 + 0.55 * sin(t * PI * 1.35 + 0.25) + 0.25 * cos(t * PI * 2.10 - 0.40)
	centre_width = clampf(centre_width, S09_BANK_EDGE_MAX_WIDTH_M - 1.0, S09_BANK_EDGE_MAX_WIDTH_M)
	var width := lerpf(S09_BANK_EDGE_MIN_WIDTH_M, centre_width, clampf(taper, 0.0, 1.0))
	var edge_origin_u := half + S09_FRONT_CLEARANCE_M + 0.55
	var outer_u := edge_origin_u + width
	var xz := Vector2(route_position.x, route_position.z) + Vector2(left.x, left.z) * outer_u
	var ground := _actual_ground(xz)
	if not is_finite(ground):
		return {}
	return {"u": outer_u, "ground": ground}

func _s09_taper(s: float) -> float:
	var enter := smoothstep(_s09_s0, _s09_s0 + S09_END_TAPER_M, s)
	var leave := 1.0 - smoothstep(_s09_s1 - S09_END_TAPER_M, _s09_s1, s)
	return lerpf(0.18, 1.0, clampf(minf(enter, leave), 0.0, 1.0))

func _build_s09_bank_surface(columns: Array) -> void:
	_s09_bank_vertices = PackedVector3Array()
	_s09_bank_normals = PackedVector3Array()
	_s09_bank_tangents = PackedFloat32Array()
	_s09_bank_uvs = PackedVector2Array()
	_s09_bank_indices = PackedInt32Array()
	_s09_bank_contact_records = []
	for column in columns:
		var outer_index := _s09_bank_vertices.size() + 3
		_s09_bank_contact_records.append({"s": float(column["s"]), "vertex_index": outer_index, "u": float(column["bank_outer_u"]), "ground": float(column["bank_outer_ground"])})
		for point in column["bank_points"]:
			_s09_bank_vertices.append(point)
			_s09_bank_normals.append(Vector3.UP)
			_s09_bank_uvs.append(Vector2((float(column["s"]) - _s09_s0) * 0.16, point.y * 0.12))
	for i in range(columns.size() - 1):
		var a: Array = columns[i]["bank_points"]
		var b: Array = columns[i + 1]["bank_points"]
		for strip in range(a.size() - 1):
			var base_index := i * a.size()
			var next_index := (i + 1) * a.size()
			_s09_add_bank_triangle(base_index + strip, next_index + strip, next_index + strip + 1, Vector3.UP)
			_s09_add_bank_triangle(base_index + strip, next_index + strip + 1, base_index + strip + 1, Vector3.UP)

func _s09_add_bank_triangle(index_a: int, index_b: int, index_c: int, desired: Vector3) -> void:
	var a := _s09_bank_vertices[index_a]
	var b := _s09_bank_vertices[index_b]
	var c := _s09_bank_vertices[index_c]
	var normal := (c - a).cross(b - a)
	if normal.length_squared() < 0.000001:
		return
	if desired.length_squared() > 0.000001 and normal.dot(desired) < 0.0:
		var swap_index := index_b
		index_b = index_c
		index_c = swap_index
	_s09_bank_indices.append(index_a)
	_s09_bank_indices.append(index_b)
	_s09_bank_indices.append(index_c)
	var face_normal := (_s09_bank_vertices[index_c] - _s09_bank_vertices[index_a]).cross(_s09_bank_vertices[index_b] - _s09_bank_vertices[index_a]).normalized()
	_s09_bank_normals[index_a] = face_normal
	_s09_bank_normals[index_b] = face_normal
	_s09_bank_normals[index_c] = face_normal

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
		# Match texture(detail_albedo_tex, world_position.xz * scale) in the
		# bounded terrain detail shader.  The old normalized course UVs made
		# small triangles numerically degenerate and forced a generic basis.
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

func _make_column(s: float) -> Dictionary:
	var route_position: Vector3 = route.call("pos_at", s)
	var left: Vector3 = route.call("left_at", s)
	var half := float(route.call("road_width_at", s)) * 0.5
	var taper := _taper(s)
	var ridge := 0.5 + 0.5 * sin(s * 0.71 + 0.35 * sin(s * 0.13 + 0.4))
	var notch := 0.5 + 0.5 * cos(s * 0.37 + 1.1 * sin(s * 0.19))
	var base_u := half + FRONT_MIN_CLEARANCE_M + 0.11 + 0.24 * ridge
	var base_xz := Vector2(route_position.x, route_position.z) + Vector2(left.x, left.z) * base_u
	var base_ground := _actual_ground(base_xz)
	if not is_finite(base_ground):
		return {}
	var base_y := base_ground - EMBED_DEPTH_M
	var core_height := clampf(7.35 + 1.45 * sin(s * 0.31 + 0.8) + 0.85 * cos(s * 0.17 - 0.2), MIN_HEIGHT_M + 0.25, MAX_HEIGHT_M - 0.35)
	var height := core_height * taper
	var relief := _strata_relief(s)
	var profile := [
		0.0,
		0.18 + 0.20 * ridge,
		0.30 + 0.42 * notch,
		0.38 + 0.24 * ridge,
		0.46 + 0.30 * notch,
		0.52 + 0.18 * ridge,
		0.48 + 0.22 * notch
	]
	var lateral_weights := [0.0, 0.34, 0.68, 1.0, 0.88, 0.64, 0.38]
	var ledge_weights := [0.0, 0.35, -0.65, 0.95, -0.72, 0.40, 0.0]
	var front: Array = []
	var front_us: Array = []
	var previous_u := base_u
	for layer_index in range(LAYER_T.size()):
		var relief_u: float = (2.15 * float(relief["rib"]) + 1.10 * float(relief["notch"]) + 0.65 * float(relief["strata"])) * float(lateral_weights[layer_index]) * taper
		var u := base_u + maxf(0.12, float(profile[layer_index]) + relief_u) * taper
		if layer_index > 0:
			u = maxf(u, previous_u - 0.25)
		var xz := base_xz if layer_index == 0 else Vector2(route_position.x, route_position.z) + Vector2(left.x, left.z) * u
		var ledge_y: float = (0.55 * float(relief["rib"]) + 0.30 * float(relief["notch"]) + 0.20 * float(relief["strata"])) * float(ledge_weights[layer_index]) * taper
		var point := Vector3(xz.x, base_y + height * float(LAYER_T[layer_index]) + ledge_y, xz.y)
		front.append(point)
		front_us.append(u)
		previous_u = u
	var uphill := _find_uphill_connection(route_position, left, base_u, base_ground, height)
	if uphill.is_empty():
		return {}
	var back_lower_u := float(uphill["lower_u"])
	var back_top_u := float(uphill["top_u"])
	var back_lower_ground := float(uphill["lower_ground"])
	var back_top_ground := float(uphill["top_ground"])
	var back_lower_xz := Vector2(route_position.x, route_position.z) + Vector2(left.x, left.z) * back_lower_u
	var back_top_xz := Vector2(route_position.x, route_position.z) + Vector2(left.x, left.z) * back_top_u
	var back_lower := Vector3(back_lower_xz.x, back_lower_ground - EMBED_DEPTH_M, back_lower_xz.y)
	var back_top := Vector3(back_top_xz.x, back_top_ground + 0.02, back_top_xz.y)
	return {
		"s": s,
		"half": half,
		"left": left,
		"base_u": base_u,
		"front": front,
		"front_us": front_us,
		"back_lower": back_lower,
		"back_top": back_top,
		"back_lower_u": back_lower_u,
		"back_top_u": back_top_u,
		"back_lower_ground": back_lower_ground,
		"back_top_ground": back_top_ground,
		"height": height,
		"core_height": core_height
	}

func _strata_relief(s: float) -> Dictionary:
	# Broad, deterministic rib centers make the wall read as fractured strata.
	# The piecewise strata term creates a few geological ledges rather than a
	# high-frequency sinusoidal scallop pattern.
	var span := maxf(_s1 - _s0, 0.001)
	var t := clampf((s - _s0) / span, 0.0, 1.0)
	var rib_centers := [0.08, 0.25, 0.44, 0.66, 0.87]
	var rib_signs := [1.0, -0.82, 0.94, -0.72, 0.86]
	var rib := 0.0
	for i in range(rib_centers.size()):
		var width := 0.055 + 0.012 * float(i % 2)
		var envelope := clampf(1.0 - absf(t - float(rib_centers[i])) / width, 0.0, 1.0)
		rib += float(rib_signs[i]) * envelope * envelope
	var notch_centers := [0.17, 0.37, 0.57, 0.79]
	var notch := 0.0
	for i in range(notch_centers.size()):
		var width := 0.038 + 0.008 * float(i % 2)
		var envelope := clampf(1.0 - absf(t - float(notch_centers[i])) / width, 0.0, 1.0)
		notch -= envelope * envelope
	var block := floorf((s - _s0) / 6.5)
	var strata := 0.56 * sin(block * 2.37 + 0.4) + 0.32 * cos(block * 1.11 - 0.7)
	return {"rib": clampf(rib, -1.0, 1.0), "notch": clampf(notch, -1.0, 0.0), "strata": clampf(strata, -1.0, 1.0)}

func _find_uphill_connection(route_position: Vector3, left: Vector3, base_u: float, base_ground: float, height: float) -> Dictionary:
	# The first few metres are the road's clearance core.  Search well beyond it
	# for a real DEM contact close to the front crown instead of making a short
	# vertical roof that falls back to road level.
	var target_ground := base_ground + maxf(height, 1.0) * 0.86
	var minimum_ground := base_ground + maxf(height, 1.0) * 0.58
	var start_u := base_u + 10.0
	var end_u := base_u + 36.0
	var best := {}
	var best_score := INF
	var highest := {}
	var highest_ground := -INF
	var u := start_u
	while u <= end_u + 0.001:
		var xz := Vector2(route_position.x, route_position.z) + Vector2(left.x, left.z) * u
		var ground := _actual_ground(xz)
		if is_finite(ground):
			if ground > highest_ground:
				highest_ground = ground
				highest = {"top_u": u, "top_ground": ground}
			if ground >= minimum_ground:
				var score := absf(ground - target_ground) + absf(u - (base_u + 21.0)) * 0.025
				if score < best_score:
					best_score = score
					best = {"top_u": u, "top_ground": ground}
			u += 1.0
	if best.is_empty():
		best = highest
	if best.is_empty():
		return {}
	var top_u := float(best["top_u"])
	var top_ground := float(best["top_ground"])
	var lower_u := maxf(base_u + 8.0, top_u - 4.0)
	var lower_xz := Vector2(route_position.x, route_position.z) + Vector2(left.x, left.z) * lower_u
	var lower_ground := _actual_ground(lower_xz)
	if not is_finite(lower_ground):
		return {}
	return {
		"lower_u": lower_u,
		"lower_ground": lower_ground,
		"top_u": top_u,
		"top_ground": top_ground
	}

func _taper(s: float) -> float:
	var enter := smoothstep(_s0, _s0 + END_TAPER_M, s)
	var leave := 1.0 - smoothstep(_s1 - END_TAPER_M, _s1, s)
	return lerpf(0.08, 1.0, clampf(minf(enter, leave), 0.0, 1.0))

func _actual_ground(xz: Vector2) -> float:
	var sample: Dictionary = landscape.call("sample_mesh_triangle", xz)
	if sample.is_empty() or not sample.has("height"):
		return NAN
	var height := float(sample["height"])
	return height if is_finite(height) else NAN

func _build_surface(columns: Array) -> void:
	_mesh_vertices = PackedVector3Array()
	_mesh_normals = PackedVector3Array()
	_mesh_uvs = PackedVector2Array()
	_mesh_indices = PackedInt32Array()
	_base_contact_records = []
	_height_records = []
	_front_lateral_records = []
	var base_indices: Array[int] = []
	var top_indices: Array[int] = []
	var back_lower_indices: Array[int] = []
	var back_top_indices: Array[int] = []
	base_indices.resize(columns.size())
	top_indices.resize(columns.size())
	back_lower_indices.resize(columns.size())
	back_top_indices.resize(columns.size())
	for i in range(columns.size()):
		base_indices[i] = -1
		top_indices[i] = -1
		back_lower_indices[i] = -1
		back_top_indices[i] = -1
	for i in range(columns.size() - 1):
		var a: Dictionary = columns[i]
		var b: Dictionary = columns[i + 1]
		var front_desired: Vector3 = -((a["left"] + b["left"]) * 0.5).normalized()
		if front_desired.length_squared() < 0.000001:
			front_desired = -a["left"]
		for layer_index in range(LAYER_T.size() - 1):
			var front_start := _add_quad_oriented(a["front"][layer_index], b["front"][layer_index], b["front"][layer_index + 1], a["front"][layer_index + 1], _uv(a, layer_index), _uv(b, layer_index), _uv(b, layer_index + 1), _uv(a, layer_index + 1), front_desired)
			if front_start < 0:
				return
		var top_start := _add_quad_oriented(a["front"][LAYER_T.size() - 1], b["front"][LAYER_T.size() - 1], b["back_top"], a["back_top"], _uv(a, LAYER_T.size() - 1), _uv(b, LAYER_T.size() - 1), _uv_point(b["s"], b["back_top"], b["base_u"]), _uv_point(a["s"], a["back_top"], a["base_u"]), Vector3.UP)
		if top_start < 0:
			return
		var back_desired: Vector3 = ((a["left"] + b["left"]) * 0.5).normalized()
		var back_start := _add_quad_oriented(a["back_lower"], a["back_top"], b["back_top"], b["back_lower"], _uv_point(a["s"], a["back_lower"], a["base_u"]), _uv_point(a["s"], a["back_top"], a["base_u"]), _uv_point(b["s"], b["back_top"], b["base_u"]), _uv_point(b["s"], b["back_lower"], b["base_u"]), back_desired)
		if back_start < 0:
			return
		var bottom_start := _add_quad_oriented(a["front"][0], a["back_lower"], b["back_lower"], b["front"][0], _uv(a, 0), _uv_point(a["s"], a["back_lower"], a["base_u"]), _uv_point(b["s"], b["back_lower"], b["base_u"]), _uv(b, 0), Vector3.DOWN)
		if bottom_start < 0:
			return
	# Orientation correction can swap the second/third vertex of a triangle.
	# Resolve metadata by actual point positions after all surfaces are emitted,
	# rather than assuming a returned triangle offset is a particular corner.
	for i in range(columns.size()):
		base_indices[i] = _find_mesh_vertex(columns[i]["front"][0])
		top_indices[i] = _find_mesh_vertex(columns[i]["front"][LAYER_T.size() - 1])
		back_lower_indices[i] = _find_mesh_vertex(columns[i]["back_lower"])
		back_top_indices[i] = _find_mesh_vertex(columns[i]["back_top"])
	for i in range(columns.size()):
		if base_indices[i] < 0 or top_indices[i] < 0 or back_lower_indices[i] < 0 or back_top_indices[i] < 0:
			push_error("SaisiesGeoNearfieldDetails missing mesh index for column %d" % i)
			return
		var base_vertex: Vector3 = _mesh_vertices[base_indices[i]]
		var top_vertex: Vector3 = _mesh_vertices[top_indices[i]]
		var back_vertex: Vector3 = _mesh_vertices[back_lower_indices[i]]
		_base_contact_records.append({"kind": "front", "s": float(columns[i]["s"]), "vertex_index": base_indices[i], "u": float(columns[i]["base_u"])})
		_base_contact_records.append({"kind": "back", "s": float(columns[i]["s"]), "vertex_index": back_lower_indices[i], "u": float(columns[i]["back_lower_u"])})
		_height_records.append({"s": float(columns[i]["s"]), "base_vertex_index": base_indices[i], "top_vertex_index": top_indices[i], "height_m": top_vertex.y - base_vertex.y})
		for layer_index in range(LAYER_T.size()):
			_front_lateral_records.append({"s": float(columns[i]["s"]), "u": float(columns[i]["front_us"][layer_index]), "layer": layer_index, "vertex_index": _find_mesh_vertex(columns[i]["front"][layer_index])})
		if not (is_finite(base_vertex.y) and is_finite(top_vertex.y) and is_finite(back_vertex.y)):
			push_error("SaisiesGeoNearfieldDetails non-finite contact vertex at column %d" % i)
			return
	# Explicitly close both irregular end profiles.  Every front layer is in the
	# cap boundary; this prevents a two-triangle shortcut from leaving a crack
	# beside a protruding middle rib.
	_add_end_cap(columns[0], true)
	_add_end_cap(columns[columns.size() - 1], false)

func _find_mesh_vertex(point: Vector3) -> int:
	for i in range(_mesh_vertices.size()):
		if _mesh_vertices[i].distance_squared_to(point) < 0.0000001:
			return i
	return -1

func _add_end_cap(column: Dictionary, at_start: bool) -> void:
	var boundary: Array = []
	var boundary_uv: Array = []
	for layer_index in range(LAYER_T.size()):
		boundary.append(column["front"][layer_index])
		boundary_uv.append(_uv(column, layer_index))
	boundary.append(column["back_top"])
	boundary_uv.append(_uv_point(column["s"], column["back_top"], column["base_u"]))
	boundary.append(column["back_lower"])
	boundary_uv.append(_uv_point(column["s"], column["back_lower"], column["base_u"]))
	var centroid := Vector3.ZERO
	var centroid_uv := Vector2.ZERO
	for point in boundary:
		centroid += point
	for uv_value in boundary_uv:
		centroid_uv += uv_value
	centroid /= float(boundary.size())
	centroid_uv /= float(boundary_uv.size())
	var tangent: Vector3 = route.call("tangent_at", float(column["s"]))
	var desired := tangent if not at_start else -tangent
	for i in range(boundary.size()):
		var j := (i + 1) % boundary.size()
		_add_triangle_oriented(centroid, boundary[i], boundary[j], centroid_uv, boundary_uv[i], boundary_uv[j], desired)

func _add_quad_oriented(a: Vector3, b: Vector3, c: Vector3, d: Vector3, uv_a: Vector2, uv_b: Vector2, uv_c: Vector2, uv_d: Vector2, desired: Vector3) -> int:
	var start := _add_triangle_oriented(a, b, c, uv_a, uv_b, uv_c, desired)
	if start < 0:
		return -1
	if _add_triangle_oriented(a, c, d, uv_a, uv_c, uv_d, desired) < 0:
		return -1
	return start

func _add_triangle_oriented(a: Vector3, b: Vector3, c: Vector3, uv_a: Vector2, uv_b: Vector2, uv_c: Vector2, desired: Vector3) -> int:
	var face_normal := (c - a).cross(b - a)
	if face_normal.length_squared() < 0.000001:
		return -1
	if desired.length_squared() > 0.000001 and face_normal.dot(desired) < 0.0:
		return _add_triangle(a, c, b, uv_a, uv_c, uv_b)
	return _add_triangle(a, b, c, uv_a, uv_b, uv_c)

func _add_triangle(a: Vector3, b: Vector3, c: Vector3, uv_a: Vector2, uv_b: Vector2, uv_c: Vector2) -> int:
	var face_normal := (c - a).cross(b - a)
	if face_normal.length_squared() < 0.000001:
		return -1
	face_normal = face_normal.normalized()
	var start := _mesh_vertices.size()
	_mesh_vertices.append(a)
	_mesh_vertices.append(b)
	_mesh_vertices.append(c)
	_mesh_normals.append(face_normal)
	_mesh_normals.append(face_normal)
	_mesh_normals.append(face_normal)
	_mesh_uvs.append(uv_a)
	_mesh_uvs.append(uv_b)
	_mesh_uvs.append(uv_c)
	_mesh_indices.append(start)
	_mesh_indices.append(start + 1)
	_mesh_indices.append(start + 2)
	return start

func _uv(column: Dictionary, layer_index: int) -> Vector2:
	var point: Vector3 = column["front"][layer_index]
	return _uv_point(float(column["s"]), point, float(column["base_u"]))

func _uv_point(s: float, point: Vector3, base_u: float) -> Vector2:
	return Vector2((s - _s0) * 0.24, (point.y - 900.0) * 0.20 + base_u * 0.12)

func _rock_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = load("res://assets/textures/rock_boulder_dry_diff.jpg")
	material.normal_enabled = true
	material.normal_texture = load("res://assets/textures/rock_boulder_dry_nor.jpg")
	material.roughness_texture = load("res://assets/textures/rock_boulder_dry_rough.jpg")
	material.albedo_color = Color(0.34, 0.35, 0.33, 1.0)
	material.normal_scale = 1.25
	material.roughness = 0.96
	material.metallic = 0.0
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * 0.65
	material.uv1_triplanar_sharpness = 3.0
	material.cull_mode = BaseMaterial3D.CULL_BACK
	return material

func _s09_wall_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = load("res://assets/textures/old_stone_wall_diff.jpg")
	material.normal_enabled = true
	material.normal_texture = load("res://assets/textures/old_stone_wall_nor.jpg")
	material.roughness_texture = load("res://assets/textures/old_stone_wall_rough.jpg")
	material.albedo_color = Color(0.68, 0.70, 0.67, 1.0)
	material.normal_scale = 1.15
	material.roughness = 0.94
	material.metallic = 0.0
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * 0.78
	material.uv1_triplanar_sharpness = 3.0
	material.cull_mode = BaseMaterial3D.CULL_BACK
	return material

func _s09_bank_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/saisies_geo_terrain_detail.gdshader") as Shader
	material.set_shader_parameter("albedo_tex", load("res://assets/textures/aerial_grass_rock_diff.jpg"))
	material.set_shader_parameter("detail_albedo_tex", load("res://assets/textures/aerial_grass_rock_diff.jpg"))
	material.set_shader_parameter("detail_normal_tex", load("res://assets/textures/aerial_grass_rock_nor.jpg"))
	material.set_shader_parameter("detail_enabled", true)
	material.set_shader_parameter("detail_force", true)
	material.set_shader_parameter("haze_max", 0.0)
	material.set_shader_parameter("brightness", 1.0)
	material.set_shader_parameter("detail_uv_scale", 0.24)
	material.set_shader_parameter("detail_shadow_green", Color(0.32, 0.35, 0.20, 1.0))
	material.set_shader_parameter("detail_sun_green", Color(0.54, 0.57, 0.34, 1.0))
	material.set_shader_parameter("detail_brightness", 0.93)
	return material

func mesh_vertices() -> PackedVector3Array:
	return _mesh_vertices

func mesh_normals() -> PackedVector3Array:
	return _mesh_normals

func mesh_uvs() -> PackedVector2Array:
	return _mesh_uvs

func mesh_indices() -> PackedInt32Array:
	return _mesh_indices

func base_contact_records() -> Array:
	return _base_contact_records.duplicate(true)

func height_records() -> Array:
	return _height_records.duplicate(true)

func front_lateral_records() -> Array:
	return _front_lateral_records.duplicate(true)

func s09_mesh_vertices() -> PackedVector3Array:
	return _s09_vertices

func s09_mesh_normals() -> PackedVector3Array:
	return _s09_normals

func s09_mesh_uvs() -> PackedVector2Array:
	return _s09_uvs

func s09_mesh_indices() -> PackedInt32Array:
	return _s09_indices

func s09_bank_vertices() -> PackedVector3Array:
	return _s09_bank_vertices

func s09_bank_normals() -> PackedVector3Array:
	return _s09_bank_normals

func s09_bank_tangents() -> PackedFloat32Array:
	return _s09_bank_tangents

func s09_bank_uvs() -> PackedVector2Array:
	return _s09_bank_uvs

func s09_bank_indices() -> PackedInt32Array:
	return _s09_bank_indices

func s09_base_contact_records() -> Array:
	return _s09_base_contact_records.duplicate(true)

func s09_height_records() -> Array:
	return _s09_height_records.duplicate(true)

func s09_front_lateral_records() -> Array:
	return _s09_front_lateral_records.duplicate(true)

func s09_bank_contact_records() -> Array:
	return _s09_bank_contact_records.duplicate(true)

func s09_route_window() -> Vector2:
	return Vector2(_s09_s0, _s09_s1)

func route_window() -> Vector2:
	return Vector2(_s0, _s1)
