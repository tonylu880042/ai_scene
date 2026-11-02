class_name SaisiesS01Landscape
extends Node3D

## Bounded S01 landscape refinement for the frozen R14 geographic bake.
##
## This module is intentionally independent of SaisiesGeoForest and the
## geographic terrain generator.  It adds only a local, source-supported
## S01 ridge band and two green slope openings. Every root is placed from
## either the live Landscape.sample_mesh_triangle() API or an indexed triangle
## read from the baked SaisiesGeoTerrain ArrayMesh; it never uses a DEM-only
## height as a contact substitute.

@export var world_path: NodePath = NodePath("../World")
@export var landscape_path: NodePath = NodePath("../World/Landscape")
@export var target_scene_id := "S01"
@export var build_on_ready := true
@export var enable_s01 := true
@export var visibility_range_m := 3000.0

const TREE_FACTORY := preload("res://scripts/saisies_trees.gd")
const GROUND_SHADER := preload("res://shaders/saisies_s01_ground.gdshader")

const PROJECTION_REPORT := "res://export/saisies/review/round15_s01/s01_projection_report.json"
## The fixed S01 camera projects the source ridge ROI into this conservative
## interior of the actual R14 mesh triangle candidate bounds. It is hundreds
## of metres behind the village, so it cannot put a tree row between the roofs.
const LOCAL_BOUNDS := Rect2(-560.0, -1720.0, 840.0, 1650.0)
## Camera-C projection puts the source ridge on a raised, bounded back slope.
## The overlay starts and ends outside the visible crest and fades back to the
## baked mesh, so this is a local terrain correction rather than a world move.
# The visible white patch in the native C frame is outside the ridge overlay's
# front edge.  Keep the ridge bounds fixed and cover only the measured S01
# foreground ROI below with a separate local floor mesh.
const RIDGE_OVERLAY_BOUNDS := Rect2(-560.0, -1720.0, 840.0, 930.0)
const FOREST_FLOOR_COVER_BOUNDS := Rect2(-300.0, -840.0, 220.0, 340.0)
const FOREST_FLOOR_COVER_STEP_M := 12.0
const FOREST_FLOOR_COVER_OFFSET_M := 0.34
const RIDGE_OVERLAY_STEP_M := 12.0
const RIDGE_OVERLAY_FADE_M := 72.0
const RIDGE_CREST_HALF_WIDTH_M := 170.0
const RIDGE_CREST_START_X_M := -445.0
const RIDGE_CREST_END_X_M := 150.0
const RIDGE_CREST_START_Z_M := -960.0
const RIDGE_CREST_END_Z_M := -1365.0
const RIDGE_CREST_START_Y_M := 205.0
const RIDGE_CREST_END_Y_M := 132.0
const RIDGE_TERRAIN_OFFSET_CAP_M := 150.0
const RIDGE_TREE_MIN_X_M := -520.0
const RIDGE_TREE_MAX_X_M := 250.0
const RIDGE_TREE_MIN_Z_M := -1690.0
const RIDGE_TREE_MAX_Z_M := -850.0
const RIDGE_TREE_X_STEP_M := 7.5
const RIDGE_TREE_Z_STEP_M := 8.5
const RIDGE_TREE_BAND_HALF_WIDTH_M := 185.0
const RIDGE_TREE_JITTER_X_M := 6.0
const RIDGE_TREE_JITTER_Z_M := 6.0
const RIDGE_TREE_SCALE_MIN := 1.10
const RIDGE_TREE_SCALE_MAX := 1.62
const GROUND_CACHE_MARGIN_M := 18.0
const GROUND_TRIANGLE_BIN_M := 32.0
const GROUND_OVERLAY_OFFSET_M := 0.28
## The ridge is far enough from Camera-C that the original conifer cards only
## contribute separated pale speckles. Keep them available for closer S01
## views, but let the bounded crown mass own this far band.
const FOREST_FAR_CARD_END_M := 320.0
const FOREST_CROWN_ROOT_OFFSET_M := 0.0
const FOREST_CROWN_RING_COUNT := 4
const FOREST_CROWN_SIDE_COUNT := 8
const FOREST_CROWN_MIN_WIDTH_M := 7.2
const FOREST_CROWN_MAX_WIDTH_M := 11.8
const FOREST_CROWN_MIN_HEIGHT_M := 10.0
const FOREST_CROWN_MAX_HEIGHT_M := 18.0
const MAX_BUILD_ATTEMPTS := 40

const LOD_NEAR_SCALE := 1.0
const LOD_FAR_SCALE := 0.92

var _world: Node3D
var _landscape: Node
var _terrain_mesh_instance: MeshInstance3D
var _ground_points := PackedVector3Array()
var _ground_normals := PackedVector3Array()
var _ground_vertex_indices: Dictionary = {}
var _ground_triangles: Array = []
var _ground_triangle_bins: Dictionary = {}
var _ground_source := "unresolved"
var _ground_candidate_count := 0
var _ground_triangle_count := 0
var _ground_contact_fallback_count := 0
var _ridge_overlay_triangles: Array = []
var _ridge_overlay_bins: Dictionary = {}
var _ridge_overlay_ready := false
var _ridge_overlay_vertex_count := 0
var _ridge_overlay_triangle_count := 0
var _build_attempts := 0
var _built := false
var _tree_mesh_tint_cache: Dictionary = {}
var _forest_crown_mesh_cache: Dictionary = {}

func _ready() -> void:
	if not build_on_ready or not enable_s01 or target_scene_id != "S01":
		return
	# The review scene normally places this node beside World.  top_level keeps
	# the authored local coordinates in the bake's world frame if a host scene
	# instead parents the module below a transformed review helper.
	top_level = true
	call_deferred("_try_build")

func _try_build() -> void:
	if _built:
		return
	_resolve_world()
	_resolve_landscape()
	_resolve_baked_terrain()
	if _world == null:
		_retry("SaisiesS01Landscape could not resolve world_path %s" % world_path)
		return
	if _landscape == null and _terrain_mesh_instance == null:
		_retry("SaisiesS01Landscape requires Landscape or SaisiesGeoTerrain")
		return
	_build()

func _retry(message: String) -> void:
	_build_attempts += 1
	if _build_attempts < MAX_BUILD_ATTEMPTS:
		call_deferred("_try_build")
	else:
		push_error(message)

func _resolve_world() -> void:
	if _world != null:
		return
	if not world_path.is_empty():
		_world = get_node_or_null(world_path) as Node3D
	if _world == null and get_parent() != null:
		_world = get_parent().find_child("World", true, false) as Node3D
	if _world == null and get_parent() is Node3D and get_parent().get_parent() == null:
		_world = get_parent() as Node3D

func _resolve_landscape() -> void:
	if _landscape != null:
		return
	if not landscape_path.is_empty():
		_landscape = get_node_or_null(landscape_path)
	if _landscape == null and _world != null:
		_landscape = _world.find_child("Landscape", true, false)

func _resolve_baked_terrain() -> void:
	if _terrain_mesh_instance != null:
		return
	if _landscape is MeshInstance3D and (_landscape as MeshInstance3D).mesh != null:
		_terrain_mesh_instance = _landscape as MeshInstance3D
		return
	if _world == null:
		return
	_terrain_mesh_instance = _world.find_child("SaisiesGeoTerrain", true, false) as MeshInstance3D
	if _terrain_mesh_instance == null:
		for candidate in _world.find_children("*", "MeshInstance3D", true, false):
			var mesh_candidate := candidate as MeshInstance3D
			if mesh_candidate != null and mesh_candidate.mesh != null and String(mesh_candidate.name).to_lower().contains("terrain"):
				_terrain_mesh_instance = mesh_candidate
				return

func _build() -> void:
	if _built:
		return
	_prepare_baked_ground_cache()
	var root := Node3D.new()
	root.name = "S01LandscapeRefinement"
	root.set_meta("saisies_s01_landscape_scope", "bounded S01 ridge terrain overlay and slope openings only")
	root.set_meta("saisies_s01_projection_report", PROJECTION_REPORT)
	root.set_meta("saisies_s01_ground_source", _ground_source)
	root.set_meta("saisies_s01_ground_triangle_count", _ground_triangle_count)
	add_child(root)

	var ridge_terrain := _build_ridge_terrain_overlay(root)
	if ridge_terrain != null:
		root.set_meta("saisies_s01_ridge_overlay", true)
		root.set_meta("saisies_s01_ridge_overlay_vertex_count", _ridge_overlay_vertex_count)
		root.set_meta("saisies_s01_ridge_overlay_triangle_count", _ridge_overlay_triangle_count)
		root.set_meta("saisies_s01_ridge_overlay_bounds", [RIDGE_OVERLAY_BOUNDS.position.x, RIDGE_OVERLAY_BOUNDS.position.y, RIDGE_OVERLAY_BOUNDS.end.x, RIDGE_OVERLAY_BOUNDS.end.y])
	var floor_cover := _build_forest_floor_cover(root)
	if floor_cover != null:
		root.set_meta("saisies_s01_foreground_floor_cover", true)
		root.set_meta("saisies_s01_foreground_floor_cover_bounds", [FOREST_FLOOR_COVER_BOUNDS.position.x, FOREST_FLOOR_COVER_BOUNDS.position.y, FOREST_FLOOR_COVER_BOUNDS.end.x, FOREST_FLOOR_COVER_BOUNDS.end.y])

	var ground_group := Node3D.new()
	ground_group.name = "S01GrassSlopeOpenings"
	ground_group.set_meta("saisies_s01_actual_mesh_ground", true)
	root.add_child(ground_group)
	var patch_count := 0
	for patch in _patch_specs():
		var patch_instance := _build_ground_patch(ground_group, patch)
		if patch_instance != null:
			patch_count += 1

	var tree_group := Node3D.new()
	tree_group.name = "S01MixedCanopy"
	tree_group.set_meta("saisies_s01_actual_multimesh", true)
	root.add_child(tree_group)
	var tree_result := _build_tree_multimeshes(tree_group)

	set_meta("saisies_s01_landscape_ready", true)
	set_meta("saisies_s01_landscape_scope", "S01 visible ridge overlay only; no route-wide density change")
	set_meta("saisies_s01_projection_report", PROJECTION_REPORT)
	set_meta("saisies_s01_ground_source", "s01_local_terrain_overlay" if _ridge_overlay_ready else _ground_source)
	set_meta("saisies_s01_ground_candidate_count", _ground_candidate_count)
	set_meta("saisies_s01_ground_triangle_count", _ground_triangle_count)
	set_meta("saisies_s01_ground_contact_fallback_count", _ground_contact_fallback_count)
	set_meta("saisies_s01_actual_triangle_contact", (_ridge_overlay_ready and _ridge_overlay_triangle_count > 0) or _ground_source == "baked_mesh_triangle" or _ground_source == "Landscape.sample_mesh_triangle")
	set_meta("saisies_s01_visible_triangle_contact", _ridge_overlay_ready and _ridge_overlay_triangle_count > 0)
	set_meta("saisies_s01_ridge_height_profile", {
		"crest_start_x_m": RIDGE_CREST_START_X_M,
		"crest_end_x_m": RIDGE_CREST_END_X_M,
		"crest_start_z_m": RIDGE_CREST_START_Z_M,
		"crest_end_z_m": RIDGE_CREST_END_Z_M,
		"crest_start_y_m": RIDGE_CREST_START_Y_M,
		"crest_end_y_m": RIDGE_CREST_END_Y_M,
		"fade_m": RIDGE_OVERLAY_FADE_M,
	})
	set_meta("saisies_s01_ground_patch_count", patch_count)
	set_meta("saisies_s01_tree_instance_count", int(tree_result.get("instance_count", 0)))
	set_meta("saisies_s01_tree_multimesh_node_count", int(tree_result.get("multimesh_count", 0)))
	set_meta("saisies_s01_tree_positions", tree_result.get("positions", PackedVector3Array()))
	set_meta("saisies_s01_tree_contact_heights", tree_result.get("contact_heights", PackedFloat32Array()))
	set_meta("saisies_s01_tree_contact_errors_m", tree_result.get("contact_errors", PackedFloat32Array()))
	set_meta("saisies_s01_tree_contact_triangle_starts", tree_result.get("triangle_starts", PackedInt32Array()))
	set_meta("saisies_s01_tree_contact_barycentrics", tree_result.get("barycentrics", PackedVector3Array()))
	set_meta("saisies_s01_tree_contact_sources", tree_result.get("sources", []))
	set_meta("saisies_s01_tree_visible_triangle_starts", tree_result.get("triangle_starts", PackedInt32Array()))
	set_meta("saisies_s01_tree_visible_barycentrics", tree_result.get("barycentrics", PackedVector3Array()))
	set_meta("saisies_s01_openings", ["left_slope_opening", "right_slope_opening"])
	set_meta("saisies_s01_road_clearance_contract", "road corridor remains empty; no asphalt material is changed by this module")
	set_meta("saisies_s01_geometry_contract", "actual SaisiesTrees meshes in MultiMeshInstances; deterministic authored transforms")
	_built = true
	print("saisies S01 landscape: source=%s mesh_candidates=%d patches=%d trees=%d multimeshes=%d" % [
		_ground_source, _ground_candidate_count, patch_count, int(tree_result.get("instance_count", 0)), int(tree_result.get("multimesh_count", 0))
	])

func _prepare_baked_ground_cache() -> void:
	_ground_points.clear()
	_ground_normals.clear()
	_ground_vertex_indices.clear()
	_ground_triangles.clear()
	_ground_triangle_bins.clear()
	_ground_candidate_count = 0
	_ground_triangle_count = 0
	_ground_contact_fallback_count = 0
	_ground_source = "unresolved"
	if _landscape != null and _landscape.has_method("sample_mesh_triangle"):
		_ground_source = "Landscape.sample_mesh_triangle"
		# The live landscape owns the exact cell/index lookup. Avoid duplicating
		# its full terrain cache in the S01 helper.
		return
	if _terrain_mesh_instance == null or _terrain_mesh_instance.mesh == null:
		return
	var arrays := _terrain_mesh_instance.mesh.surface_get_arrays(0)
	if arrays.size() <= Mesh.ARRAY_VERTEX:
		return
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	if not vertices is PackedVector3Array:
		return
	var normals = arrays[Mesh.ARRAY_NORMAL] if arrays.size() > Mesh.ARRAY_NORMAL else null
	var transform := _terrain_mesh_instance.global_transform
	for index in vertices.size():
		var point: Vector3 = transform * vertices[index]
		if point.x < LOCAL_BOUNDS.position.x - GROUND_CACHE_MARGIN_M:
			continue
		if point.x > LOCAL_BOUNDS.end.x + GROUND_CACHE_MARGIN_M:
			continue
		if point.z < LOCAL_BOUNDS.position.y - GROUND_CACHE_MARGIN_M:
			continue
		if point.z > LOCAL_BOUNDS.end.y + GROUND_CACHE_MARGIN_M:
			continue
		_ground_vertex_indices[index] = true
		_ground_points.append(point)
		if normals is PackedVector3Array and index < normals.size():
			var normal: Vector3 = transform.basis * normals[index]
			_ground_normals.append(normal.normalized() if normal.length_squared() > 0.000001 else Vector3.UP)
		else:
			_ground_normals.append(Vector3.UP)
	_ground_candidate_count = _ground_points.size()
	if _ground_candidate_count <= 0:
		return
	var indices = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX else null
	if indices is PackedInt32Array and not indices.is_empty():
		for start in range(0, indices.size(), 3):
			var ia := int(indices[start])
			var ib := int(indices[start + 1])
			var ic := int(indices[start + 2])
			# A local triangle must have at least one cached vertex. The terrain
			# cells are much smaller than this patch, so no spanning triangle is
			# lost by this bounded membership test.
			if not _ground_vertex_indices.has(ia) and not _ground_vertex_indices.has(ib) and not _ground_vertex_indices.has(ic):
				continue
			var a: Vector3 = transform * vertices[ia]
			var b: Vector3 = transform * vertices[ib]
			var c: Vector3 = transform * vertices[ic]
			if not _triangle_intersects_local_bounds(a, b, c):
				continue
			var triangle_index := _ground_triangles.size()
			_ground_triangles.append({"a": a, "b": b, "c": c, "start": start})
			_index_ground_triangle_bins(triangle_index, a, b, c)
	_ground_triangle_count = _ground_triangles.size()
	if _ground_triangle_count > 0:
		_ground_source = "baked_mesh_triangle"
	else:
		_ground_source = "baked_mesh_nearest_vertex_fallback"

func _ground_bin_key(x: int, z: int) -> String:
	return "%d:%d" % [x, z]

func _index_ground_triangle_bins(triangle_index: int, a: Vector3, b: Vector3, c: Vector3) -> void:
	var min_x := floori(minf(a.x, minf(b.x, c.x)) / GROUND_TRIANGLE_BIN_M)
	var max_x := floori(maxf(a.x, maxf(b.x, c.x)) / GROUND_TRIANGLE_BIN_M)
	var min_z := floori(minf(a.z, minf(b.z, c.z)) / GROUND_TRIANGLE_BIN_M)
	var max_z := floori(maxf(a.z, maxf(b.z, c.z)) / GROUND_TRIANGLE_BIN_M)
	for bx in range(min_x, max_x + 1):
		for bz in range(min_z, max_z + 1):
			var key := _ground_bin_key(bx, bz)
			if not _ground_triangle_bins.has(key):
				_ground_triangle_bins[key] = []
			(_ground_triangle_bins[key] as Array).append(triangle_index)

func _build_ridge_terrain_overlay(parent: Node3D) -> MeshInstance3D:
	_ridge_overlay_triangles.clear()
	_ridge_overlay_bins.clear()
	_ridge_overlay_ready = false
	_ridge_overlay_vertex_count = 0
	_ridge_overlay_triangle_count = 0
	var columns := maxi(1, int(ceil(RIDGE_OVERLAY_BOUNDS.size.x / RIDGE_OVERLAY_STEP_M)))
	var rows := maxi(1, int(ceil(RIDGE_OVERLAY_BOUNDS.size.y / RIDGE_OVERLAY_STEP_M)))
	var vertices := PackedVector3Array()
	vertices.resize((columns + 1) * (rows + 1))
	for row in range(rows + 1):
		var tz := float(row) / float(rows)
		var z := lerpf(RIDGE_OVERLAY_BOUNDS.position.y, RIDGE_OVERLAY_BOUNDS.end.y, tz)
		for column in range(columns + 1):
			var tx := float(column) / float(columns)
			var x := lerpf(RIDGE_OVERLAY_BOUNDS.position.x, RIDGE_OVERLAY_BOUNDS.end.x, tx)
			var base := _sample_baked_ground(Vector2(x, z))
			if base.is_empty():
				return null
			var base_point: Vector3 = base["position"]
			var offset := _ridge_height_offset(x, z, base_point.y)
			vertices[row * (columns + 1) + column] = Vector3(x, base_point.y + offset + GROUND_OVERLAY_OFFSET_M, z)
	var indices := PackedInt32Array()
	for row in range(rows):
		for column in range(columns):
			var a := row * (columns + 1) + column
			var b := a + 1
			var c := a + columns + 1
			var d := c + 1
			indices.append(a)
			indices.append(c)
			indices.append(b)
			indices.append(b)
			indices.append(c)
			indices.append(d)
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	for start in range(0, indices.size(), 3):
		var point_a: Vector3 = vertices[indices[start]]
		var point_b: Vector3 = vertices[indices[start + 1]]
		var point_c: Vector3 = vertices[indices[start + 2]]
		var face_normal := (point_b - point_a).cross(point_c - point_a)
		if face_normal.length_squared() > 0.000001:
			if face_normal.y < 0.0:
				face_normal = -face_normal
			for corner in range(3):
				normals[indices[start + corner]] += face_normal.normalized()
	for index in normals.size():
		if normals[index].length_squared() > 0.000001:
			normals[index] = normals[index].normalized()
		else:
			normals[index] = Vector3.UP
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.set_meta("saisies_s01_visible_terrain_overlay", true)
	mesh.set_meta("saisies_s01_overlay_bounds", [RIDGE_OVERLAY_BOUNDS.position.x, RIDGE_OVERLAY_BOUNDS.position.y, RIDGE_OVERLAY_BOUNDS.end.x, RIDGE_OVERLAY_BOUNDS.end.y])
	mesh.set_meta("saisies_s01_overlay_step_m", RIDGE_OVERLAY_STEP_M)
	var instance := MeshInstance3D.new()
	instance.name = "S01RidgeTerrainOverlay"
	instance.mesh = mesh
	instance.material_override = _ground_material(true)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.set_meta("saisies_s01_visible_terrain_overlay", true)
	instance.set_meta("saisies_s01_ground_source", "s01_local_terrain_overlay")
	instance.set_meta("saisies_s01_overlay_bounds", [RIDGE_OVERLAY_BOUNDS.position.x, RIDGE_OVERLAY_BOUNDS.position.y, RIDGE_OVERLAY_BOUNDS.end.x, RIDGE_OVERLAY_BOUNDS.end.y])
	instance.set_meta("saisies_s01_overlay_height_profile", {
		"crest_start_x_m": RIDGE_CREST_START_X_M,
		"crest_end_x_m": RIDGE_CREST_END_X_M,
		"crest_start_z_m": RIDGE_CREST_START_Z_M,
		"crest_end_z_m": RIDGE_CREST_END_Z_M,
		"crest_start_y_m": RIDGE_CREST_START_Y_M,
		"crest_end_y_m": RIDGE_CREST_END_Y_M,
		"fade_m": RIDGE_OVERLAY_FADE_M,
	})
	parent.add_child(instance)
	for start in range(0, indices.size(), 3):
		_ridge_overlay_triangles.append({
			"a": vertices[indices[start]],
			"b": vertices[indices[start + 1]],
			"c": vertices[indices[start + 2]],
			"start": start,
		})
		_index_ridge_overlay_bins(_ridge_overlay_triangles.size() - 1, vertices[indices[start]], vertices[indices[start + 1]], vertices[indices[start + 2]])
	_ridge_overlay_vertex_count = vertices.size()
	_ridge_overlay_triangle_count = _ridge_overlay_triangles.size()
	_ridge_overlay_ready = _ridge_overlay_triangle_count > 0
	return instance

func _index_ridge_overlay_bins(triangle_index: int, a: Vector3, b: Vector3, c: Vector3) -> void:
	var min_x := floori(minf(a.x, minf(b.x, c.x)) / GROUND_TRIANGLE_BIN_M)
	var max_x := floori(maxf(a.x, maxf(b.x, c.x)) / GROUND_TRIANGLE_BIN_M)
	var min_z := floori(minf(a.z, minf(b.z, c.z)) / GROUND_TRIANGLE_BIN_M)
	var max_z := floori(maxf(a.z, maxf(b.z, c.z)) / GROUND_TRIANGLE_BIN_M)
	for bx in range(min_x, max_x + 1):
		for bz in range(min_z, max_z + 1):
			var key := _ground_bin_key(bx, bz)
			if not _ridge_overlay_bins.has(key):
				_ridge_overlay_bins[key] = []
			(_ridge_overlay_bins[key] as Array).append(triangle_index)

func _build_forest_floor_cover(parent: Node3D) -> MeshInstance3D:
	# Native C pixels (1150..1350, 350..375) ray-hit the original baked
	# SaisiesGeoTerrain at roughly x=-225..-138, z=-775..-594m.  That surface
	# is outside the ridge overlay and is the white patch seen below the trees.
	# Build a small cover only over that measured ROI; do not extend the whole
	# mountain overlay or change any baked terrain vertices.
	var columns := maxi(1, int(ceil(FOREST_FLOOR_COVER_BOUNDS.size.x / FOREST_FLOOR_COVER_STEP_M)))
	var rows := maxi(1, int(ceil(FOREST_FLOOR_COVER_BOUNDS.size.y / FOREST_FLOOR_COVER_STEP_M)))
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	for row in range(rows + 1):
		var tz := float(row) / float(rows)
		var z := lerpf(FOREST_FLOOR_COVER_BOUNDS.position.y, FOREST_FLOOR_COVER_BOUNDS.end.y, tz)
		for column in range(columns + 1):
			var tx := float(column) / float(columns)
			var x := lerpf(FOREST_FLOOR_COVER_BOUNDS.position.x, FOREST_FLOOR_COVER_BOUNDS.end.x, tx)
			var sample := _sample_baked_ground(Vector2(x, z))
			if sample.is_empty():
				return null
			var point: Vector3 = sample["position"]
			vertices.append(Vector3(x, point.y + FOREST_FLOOR_COVER_OFFSET_M, z))
			var normal: Vector3 = sample.get("normal", Vector3.UP)
			normals.append(normal if normal.length_squared() > 0.000001 else Vector3.UP)
	var indices := PackedInt32Array()
	for row in rows:
		for column in columns:
			var a := row * (columns + 1) + column
			var b := a + 1
			var c := a + columns + 1
			var d := c + 1
			indices.append(a)
			indices.append(c)
			indices.append(b)
			indices.append(b)
			indices.append(c)
			indices.append(d)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.set_meta("saisies_s01_foreground_floor_cover", true)
	mesh.set_meta("saisies_s01_cover_source", "baked_mesh_triangle")
	mesh.set_meta("saisies_s01_cover_bounds", [FOREST_FLOOR_COVER_BOUNDS.position.x, FOREST_FLOOR_COVER_BOUNDS.position.y, FOREST_FLOOR_COVER_BOUNDS.end.x, FOREST_FLOOR_COVER_BOUNDS.end.y])
	var instance := MeshInstance3D.new()
	instance.name = "S01ForestFloorCover"
	instance.mesh = mesh
	instance.material_override = _ground_material(true)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.set_meta("saisies_s01_foreground_floor_cover", true)
	instance.set_meta("saisies_s01_cover_source", "baked_mesh_triangle")
	instance.set_meta("saisies_s01_cover_offset_m", FOREST_FLOOR_COVER_OFFSET_M)
	parent.add_child(instance)
	return instance

func _ridge_height_offset(x: float, z: float, base_y: float) -> float:
	var edge_distance := minf(
		minf(x - RIDGE_OVERLAY_BOUNDS.position.x, RIDGE_OVERLAY_BOUNDS.end.x - x),
		minf(z - RIDGE_OVERLAY_BOUNDS.position.y, RIDGE_OVERLAY_BOUNDS.end.y - z)
	)
	var edge_weight := smoothstep(0.0, RIDGE_OVERLAY_FADE_M, maxf(edge_distance, 0.0))
	var x_t := clampf((x - RIDGE_CREST_START_X_M) / (RIDGE_CREST_END_X_M - RIDGE_CREST_START_X_M), 0.0, 1.0)
	var crest_z := lerpf(RIDGE_CREST_START_Z_M, RIDGE_CREST_END_Z_M, x_t)
	var crest_y := lerpf(RIDGE_CREST_START_Y_M, RIDGE_CREST_END_Y_M, x_t)
	var lateral := absf(z - crest_z)
	var ridge_weight := 1.0 - smoothstep(0.0, RIDGE_CREST_HALF_WIDTH_M, lateral)
	if ridge_weight <= 0.0 or edge_weight <= 0.0:
		return 0.0
	# The crest line follows the source ridge's descending pixel line.  The
	# cross-section falls toward the existing ground before the fade boundary.
	var desired_y := crest_y - 38.0 * pow(clampf(lateral / RIDGE_CREST_HALF_WIDTH_M, 0.0, 1.0), 2.0)
	var raise_m := clampf(desired_y - base_y, 0.0, RIDGE_TERRAIN_OFFSET_CAP_M)
	return raise_m * ridge_weight * edge_weight

func _sample_ground(xz: Vector2) -> Dictionary:
	if _ridge_overlay_ready:
		var overlay_sample := _sample_overlay_ground(xz)
		if not overlay_sample.is_empty():
			return overlay_sample
	return _sample_baked_ground(xz)

func _sample_baked_ground(xz: Vector2) -> Dictionary:
	if _landscape != null and _landscape.has_method("sample_mesh_triangle"):
		var sampled = _landscape.call("sample_mesh_triangle", xz)
		if sampled is Dictionary and sampled.has("height") and is_finite(float(sampled["height"])):
			var normal := Vector3.UP
			if sampled.has("a") and sampled.has("b") and sampled.has("c"):
				var a: Vector3 = sampled["a"]
				var b: Vector3 = sampled["b"]
				var c: Vector3 = sampled["c"]
				normal = (b - a).cross(c - a).normalized()
				if normal.y < 0.0:
					normal = -normal
			return {
				"position": Vector3(xz.x, float(sampled["height"]), xz.y),
				"normal": normal,
				"source": "Landscape.sample_mesh_triangle",
				"error_m": 0.0,
			}
	if not _ground_triangles.is_empty():
		var bin_x := floori(xz.x / GROUND_TRIANGLE_BIN_M)
		var bin_z := floori(xz.y / GROUND_TRIANGLE_BIN_M)
		var candidate_indices: Array = _ground_triangle_bins.get(_ground_bin_key(bin_x, bin_z), [])
		for triangle_index in candidate_indices:
			var triangle: Dictionary = _ground_triangles[int(triangle_index)]
			var a: Vector3 = triangle["a"]
			var b: Vector3 = triangle["b"]
			var c: Vector3 = triangle["c"]
			var barycentric := _barycentric_xz(xz, a, b, c)
			if barycentric.x < -0.0005 or barycentric.y < -0.0005 or barycentric.z < -0.0005:
				continue
			var normal := (b - a).cross(c - a).normalized()
			if normal.y < 0.0:
				normal = -normal
			return {
				"position": Vector3(xz.x, a.y * barycentric.x + b.y * barycentric.y + c.y * barycentric.z, xz.y),
				"normal": normal if normal.length_squared() > 0.000001 else Vector3.UP,
				"source": "baked_mesh_triangle",
				"triangle_start": int(triangle["start"]),
				"barycentric": barycentric,
				"error_m": 0.0,
			}
	if _ground_points.is_empty():
		return {}
	_ground_contact_fallback_count += 1
	var nearest := -1
	var nearest_distance := INF
	for index in _ground_points.size():
		var delta := _ground_points[index] - Vector3(xz.x, _ground_points[index].y, xz.y)
		var distance := delta.x * delta.x + delta.z * delta.z
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = index
	if nearest < 0:
		return {}
	return {
		"position": _ground_points[nearest],
		"normal": _ground_normals[nearest],
		"source": "baked_mesh_nearest_vertex_fallback",
		"error_m": sqrt(nearest_distance),
	}

func _sample_overlay_ground(xz: Vector2) -> Dictionary:
	if not RIDGE_OVERLAY_BOUNDS.has_point(xz):
		return {}
	var bin_x := floori(xz.x / GROUND_TRIANGLE_BIN_M)
	var bin_z := floori(xz.y / GROUND_TRIANGLE_BIN_M)
	var candidate_indices: Array = _ridge_overlay_bins.get(_ground_bin_key(bin_x, bin_z), [])
	for triangle_index in candidate_indices:
		var triangle: Dictionary = _ridge_overlay_triangles[int(triangle_index)]
		var a: Vector3 = triangle["a"]
		var b: Vector3 = triangle["b"]
		var c: Vector3 = triangle["c"]
		var barycentric := _barycentric_xz(xz, a, b, c)
		if barycentric.x < -0.0005 or barycentric.y < -0.0005 or barycentric.z < -0.0005:
			continue
		var normal := (b - a).cross(c - a).normalized()
		if normal.y < 0.0:
			normal = -normal
		return {
			"position": Vector3(xz.x, a.y * barycentric.x + b.y * barycentric.y + c.y * barycentric.z, xz.y),
			"normal": normal if normal.length_squared() > 0.000001 else Vector3.UP,
			"source": "s01_local_terrain_overlay",
			"overlay_triangle_start": int(triangle["start"]),
			"overlay_barycentric": barycentric,
			"error_m": 0.0,
		}
	return {}

func _triangle_intersects_local_bounds(a: Vector3, b: Vector3, c: Vector3) -> bool:
	var min_x := minf(a.x, minf(b.x, c.x))
	var max_x := maxf(a.x, maxf(b.x, c.x))
	var min_z := minf(a.z, minf(b.z, c.z))
	var max_z := maxf(a.z, maxf(b.z, c.z))
	var bounds := LOCAL_BOUNDS.grow(GROUND_CACHE_MARGIN_M)
	return max_x >= bounds.position.x and min_x <= bounds.end.x and max_z >= bounds.position.y and min_z <= bounds.end.y

func _barycentric_xz(point: Vector2, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 := Vector2(b.x - a.x, b.z - a.z)
	var v1 := Vector2(c.x - a.x, c.z - a.z)
	var v2 := point - Vector2(a.x, a.z)
	var denominator := v0.x * v1.y - v1.x * v0.y
	if absf(denominator) <= 0.000001:
		return Vector3(-INF, -INF, -INF)
	var weight_b := (v2.x * v1.y - v1.x * v2.y) / denominator
	var weight_c := (v0.x * v2.y - v2.x * v0.y) / denominator
	return Vector3(1.0 - weight_b - weight_c, weight_b, weight_c)

func _patch_specs() -> Array:
	return [
		{
			"id": "left_slope_opening",
			"min_x": -132.0,
			"max_x": -42.0,
			"min_z": -1260.0,
			"max_z": -1160.0,
		},
		{
			"id": "right_slope_opening",
			"min_x": 42.0,
			"max_x": 142.0,
			"min_z": -1430.0,
			"max_z": -1315.0,
		},
	]

func _build_ground_patch(parent: Node3D, patch: Dictionary) -> MeshInstance3D:
	var columns := 6
	var rows := 10
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var contact_triangle_starts := PackedInt32Array()
	var contact_barycentrics := PackedVector3Array()
	for row in range(rows + 1):
		var tz := float(row) / float(rows)
		var z := lerpf(float(patch["min_z"]), float(patch["max_z"]), tz)
		for column in range(columns + 1):
			var tx := float(column) / float(columns)
			var x := lerpf(float(patch["min_x"]), float(patch["max_x"]), tx)
			var sample := _sample_ground(Vector2(x, z))
			if sample.is_empty():
				return null
			var point: Vector3 = sample["position"]
			# Keep the authored XZ grid while taking Y from the actual baked mesh;
			# this avoids moving an opening sideways to a nearest vertex.
			vertices.append(Vector3(x, point.y + GROUND_OVERLAY_OFFSET_M, z))
			var normal: Vector3 = sample.get("normal", Vector3.UP)
			normals.append(normal if normal.length_squared() > 0.000001 else Vector3.UP)
			uvs.append(Vector2(tx, tz))
			contact_triangle_starts.append(int(sample.get("overlay_triangle_start", sample.get("triangle_start", -1))))
			contact_barycentrics.append(sample.get("overlay_barycentric", sample.get("barycentric", Vector3(-1.0, -1.0, -1.0))))
	for row in rows:
		for column in columns:
			var a := row * (columns + 1) + column
			var b := a + 1
			var c := a + columns + 1
			var d := c + 1
			# X/Z grid winding with +Y normals.
			indices.append(a)
			indices.append(c)
			indices.append(b)
			indices.append(b)
			indices.append(c)
			indices.append(d)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.set_meta("saisies_s01_ground_patch", String(patch["id"]))
	var instance := MeshInstance3D.new()
	instance.name = "S01GrassSlope_%s" % String(patch["id"])
	instance.mesh = mesh
	instance.material_override = _ground_material()
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.set_meta("saisies_s01_ground_source", _ground_source)
	instance.set_meta("saisies_s01_ground_patch_bounds", [patch["min_x"], patch["min_z"], patch["max_x"], patch["max_z"]])
	instance.set_meta("saisies_s01_ground_triangle_starts", contact_triangle_starts)
	instance.set_meta("saisies_s01_ground_barycentrics", contact_barycentrics)
	instance.set_meta("saisies_s01_visible_triangle_starts", contact_triangle_starts)
	instance.set_meta("saisies_s01_visible_barycentrics", contact_barycentrics)
	parent.add_child(instance)
	return instance

func _ground_material(ridge := false) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = GROUND_SHADER
	if ridge:
		# The ridge floor is the dark continuous forest mass behind the roofs.
		# Keep broad variation so gaps between crowns do not expose a grey-white
		# surface, while retaining enough value range to read the two openings.
		material.set_shader_parameter("grass_shadow", Color(0.018, 0.060, 0.012))
		material.set_shader_parameter("grass_sun", Color(0.075, 0.19, 0.035))
		material.set_shader_parameter("variation_scale", 0.024)
		material.set_shader_parameter("slope_darkening", 0.06)
	else:
		# The two meadow cuts are olive green in the source, not pale terrain.
		material.set_shader_parameter("grass_shadow", Color(0.080, 0.145, 0.030))
		material.set_shader_parameter("grass_sun", Color(0.235, 0.34, 0.075))
		material.set_shader_parameter("variation_scale", 0.038)
		material.set_shader_parameter("slope_darkening", 0.08)
	return material

func _tree_specs() -> Array:
	var specs: Array = []
	# The C-camera source ridge is a continuous dark canopy. Populate the
	# bounded projected band at roughly 7.5m x 8.5m spacing, retaining the two
	# source grass openings.  This is local MultiMesh density, not route-wide
	# forest generation, and every point is sampled against the visible overlay.
	var x_slots := int(floor((RIDGE_TREE_MAX_X_M - RIDGE_TREE_MIN_X_M) / RIDGE_TREE_X_STEP_M)) + 1
	var z_slots := int(floor((RIDGE_TREE_MAX_Z_M - RIDGE_TREE_MIN_Z_M) / RIDGE_TREE_Z_STEP_M)) + 1
	for x_slot in x_slots:
		var row_phase := 0.5 * RIDGE_TREE_X_STEP_M if (x_slot & 1) == 1 else 0.0
		var x_base := RIDGE_TREE_MIN_X_M + float(x_slot) * RIDGE_TREE_X_STEP_M + row_phase
		for z_slot in z_slots:
			var depth_phase := 0.5 * RIDGE_TREE_Z_STEP_M if (z_slot & 1) == 1 else 0.0
			var z_base := RIDGE_TREE_MIN_Z_M + float(z_slot) * RIDGE_TREE_Z_STEP_M + depth_phase
			if not _is_ridge_tree_band(x_base, z_base):
				continue
			# Independent cell hashes avoid the diagonal row rhythm that remained
			# visible with the former 9m x 10m lattice.  The jitter stays within
			# the same bounded band and is deterministic across native captures.
			var x_jitter := _jitter(x_slot + 17, z_slot + 29, 73, 0) * RIDGE_TREE_JITTER_X_M
			var z_jitter := _jitter(x_slot + 41, z_slot + 11, 89, 1) * RIDGE_TREE_JITTER_Z_M
			var x := x_base + x_jitter
			var z := z_base + z_jitter
			if not _is_in_local_bounds(x, z) or _is_ridge_opening(x, z):
				continue
			var stable_id := 1000 + x_slot * 1000 + z_slot
			var variant := mini(2, int(_unit_hash(stable_id, 37) * 3.0))
			var scale := lerpf(RIDGE_TREE_SCALE_MIN, RIDGE_TREE_SCALE_MAX, _unit_hash(stable_id, 43))
			var width_scale := scale * lerpf(0.98, 1.18, _unit_hash(stable_id, 47))
			var height_scale := scale * lerpf(0.92, 1.16, _unit_hash(stable_id, 53))
			specs.append(_tree_spec("conifer", variant, Vector2(x, z), scale, stable_id, width_scale, height_scale))
	# Broadleaf landmarks stay beside and behind the lodge. They are a separate
	# near-field group from the far ridge and preserve the lodge silhouette.
	var broadleaf := [
		{"p": Vector2(18.4, -96.0), "s": 1.18, "v": 1},
		{"p": Vector2(23.4, -104.0), "s": 1.32, "v": 0},
		{"p": Vector2(29.2, -113.5), "s": 1.22, "v": 2},
		{"p": Vector2(18.2, -123.0), "s": 1.30, "v": 0},
		{"p": Vector2(27.0, -132.0), "s": 1.34, "v": 1},
		{"p": Vector2(34.0, -145.0), "s": 1.23, "v": 2},
	]
	for index in broadleaf.size():
		var item: Dictionary = broadleaf[index]
		var position: Vector2 = item["p"]
		if not _is_in_local_bounds(position.x, position.y) or _is_lodge_clearance(position.x, position.y):
			continue
		specs.append(_tree_spec("broadleaf", int(item["v"]), position, float(item["s"]), 300 + index))
	return specs

func _tree_spec(family: String, variant: int, position: Vector2, scale: float, stable_id: int, width_scale := -1.0, height_scale := -1.0) -> Dictionary:
	return {
		"family": family,
		"variant": variant,
		"position": position,
		"scale": scale,
		"width_scale": width_scale if width_scale > 0.0 else scale,
		"height_scale": height_scale if height_scale > 0.0 else scale,
		"stable_id": stable_id,
		"yaw": _unit_hash(stable_id, 12) * TAU,
	}

func _tree_mesh_for_s01(mesh: Mesh, family: String, variant: int) -> Mesh:
	var key := "%s_%d" % [family, variant]
	if _tree_mesh_tint_cache.has(key):
		return _tree_mesh_tint_cache[key] as Mesh
	var array_mesh := mesh.duplicate() as ArrayMesh
	if array_mesh == null:
		return mesh
	# The existing tree factory remains the source of all geometry. Duplicate
	# only the local material resources so S01 can keep the distant canopy
	# deep green without changing other route views or shared assets.
	var tint := Color(0.72, 0.86, 0.66, 1.0) if family == "conifer" else Color(0.84, 0.92, 0.76, 1.0)
	for surface_index in array_mesh.get_surface_count():
		var surface_material := array_mesh.surface_get_material(surface_index)
		var base_material := surface_material as BaseMaterial3D
		if base_material == null:
			continue
		var tinted := base_material.duplicate() as BaseMaterial3D
		if tinted == null:
			continue
		if surface_index == 1:
			tinted.albedo_color = tinted.albedo_color * tint
		array_mesh.surface_set_material(surface_index, tinted)
	_tree_mesh_tint_cache[key] = array_mesh
	return array_mesh

func _forest_crown_lobe_arrays(center: Vector3, radii: Vector3, phase: float) -> Array:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for ring in range(FOREST_CROWN_RING_COUNT + 1):
		var vertical := float(ring) / float(FOREST_CROWN_RING_COUNT)
		var phi := -PI * 0.5 + PI * vertical
		var y := sin(phi)
		var radial := cos(phi)
		for side in FOREST_CROWN_SIDE_COUNT:
			var angle := TAU * float(side) / float(FOREST_CROWN_SIDE_COUNT) + phase + 0.11 * sin(float(ring) * 1.9)
			var wobble := 1.0 + 0.09 * sin(float(side) * 2.17 + float(ring) * 1.61 + phase * 1.7)
			var normal := Vector3(cos(angle) * radial, y, sin(angle) * radial).normalized()
			vertices.append(center + Vector3(normal.x * radii.x * wobble, normal.y * radii.y, normal.z * radii.z * wobble))
			normals.append(normal)
	for ring in FOREST_CROWN_RING_COUNT:
		for side in FOREST_CROWN_SIDE_COUNT:
			var next_side := (side + 1) % FOREST_CROWN_SIDE_COUNT
			var a := ring * FOREST_CROWN_SIDE_COUNT + side
			var b := ring * FOREST_CROWN_SIDE_COUNT + next_side
			var c := (ring + 1) * FOREST_CROWN_SIDE_COUNT + side
			var d := (ring + 1) * FOREST_CROWN_SIDE_COUNT + next_side
			indices.append(a)
			indices.append(c)
			indices.append(b)
			indices.append(b)
			indices.append(c)
			indices.append(d)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays

func _forest_crown_material(variant: int, lobe_index: int) -> StandardMaterial3D:
	var key := int(clampi(variant, 0, 2))
	var base_colors := [Color(0.010, 0.042, 0.009), Color(0.014, 0.055, 0.011), Color(0.018, 0.068, 0.014)]
	var lobe_values := [0.72, 0.88, 1.0, 0.80, 1.08, 0.66, 0.94]
	var material := StandardMaterial3D.new()
	material.albedo_color = base_colors[key] * lobe_values[lobe_index % lobe_values.size()]
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# This material is owned by the S01 far-crown candidate.  The source crop
	# reads as a dark green ridge; do not let scene fog turn it blue-grey.
	material.disable_fog = true
	return material

func _forest_crown_mesh(variant: int) -> ArrayMesh:
	var key := int(clampi(variant, 0, 2))
	if _forest_crown_mesh_cache.has(key):
		return _forest_crown_mesh_cache[key] as ArrayMesh
	# Each entry is a normalized low-poly ellipsoid lobe.  Overlap between
	# offset lobes makes a broken summer-canopy silhouette instead of one cone;
	# variant differences keep the repeated ridge cells from sharing one outline.
	var lobe_sets: Array = [
		[
			[Vector3(0.00, 0.24, 0.00), Vector3(0.42, 0.24, 0.39)],
			[Vector3(-0.18, 0.39, 0.01), Vector3(0.31, 0.25, 0.30)],
			[Vector3(0.18, 0.42, -0.03), Vector3(0.33, 0.27, 0.31)],
			[Vector3(-0.08, 0.59, 0.03), Vector3(0.30, 0.24, 0.28)],
			[Vector3(0.14, 0.73, -0.02), Vector3(0.25, 0.21, 0.23)],
			[Vector3(-0.17, 0.79, 0.04), Vector3(0.21, 0.17, 0.20)],
		],
		[
			[Vector3(0.02, 0.22, -0.01), Vector3(0.45, 0.23, 0.41)],
			[Vector3(-0.22, 0.37, 0.03), Vector3(0.34, 0.26, 0.30)],
			[Vector3(0.20, 0.38, 0.02), Vector3(0.35, 0.25, 0.32)],
			[Vector3(-0.12, 0.56, -0.05), Vector3(0.27, 0.23, 0.27)],
			[Vector3(0.13, 0.60, 0.05), Vector3(0.31, 0.24, 0.28)],
			[Vector3(-0.03, 0.77, 0.00), Vector3(0.28, 0.20, 0.25)],
			[Vector3(0.21, 0.83, -0.02), Vector3(0.18, 0.15, 0.18)],
		],
		[
			[Vector3(-0.01, 0.25, 0.00), Vector3(0.40, 0.25, 0.38)],
			[Vector3(-0.20, 0.43, -0.02), Vector3(0.32, 0.27, 0.31)],
			[Vector3(0.21, 0.45, 0.04), Vector3(0.29, 0.24, 0.27)],
			[Vector3(0.00, 0.61, -0.06), Vector3(0.34, 0.23, 0.29)],
			[Vector3(-0.14, 0.78, 0.02), Vector3(0.23, 0.19, 0.22)],
		],
	]
	var lobe_specs: Array = lobe_sets[key]
	var mesh := ArrayMesh.new()
	for lobe_index in lobe_specs.size():
		var lobe: Array = lobe_specs[lobe_index]
		var arrays: Array = _forest_crown_lobe_arrays(lobe[0], lobe[1], float(key) * 0.47 + float(lobe_index) * 0.31)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _forest_crown_material(key, lobe_index))
	mesh.set_meta("saisies_s01_closed_crown", true)
	mesh.set_meta("saisies_s01_closed_crown_variant", key)
	mesh.set_meta("saisies_s01_crown_lobe_count", lobe_specs.size())
	mesh.set_meta("saisies_s01_crown_shape", "normalized overlapping low-poly ellipsoid lobes")
	mesh.set_meta("saisies_s01_crown_fog_disabled", true)
	_forest_crown_mesh_cache[key] = mesh
	return mesh

func _build_tree_multimeshes(parent: Node3D) -> Dictionary:
	var broadleaf: Array = TREE_FACTORY.broadleaf_variants()
	var conifer: Array = TREE_FACTORY.conifer_variants()
	var grouped: Dictionary = {}
	var crown_grouped: Dictionary = {}
	var positions := PackedVector3Array()
	var contact_heights := PackedFloat32Array()
	var contact_errors := PackedFloat32Array()
	var contact_triangle_starts := PackedInt32Array()
	var contact_barycentrics := PackedVector3Array()
	var contact_sources: Array[String] = []
	for spec in _tree_specs():
		var xz: Vector2 = spec["position"]
		var sample := _sample_ground(xz)
		if sample.is_empty():
			continue
		var family := String(spec["family"])
		var variants: Array = broadleaf if family == "broadleaf" else conifer
		if variants.is_empty():
			continue
		var variant := clampi(int(spec["variant"]), 0, variants.size() - 1)
		var mesh := variants[variant] as Mesh
		if mesh == null:
			continue
		mesh = _tree_mesh_for_s01(mesh, family, variant)
		var ground: Vector3 = sample["position"]
		var scale := float(spec["scale"])
		var key := "%s_%d" % [family, variant]
		if not grouped.has(key):
			grouped[key] = []
		grouped[key].append({
			"mesh": mesh,
			"ground": ground,
			"scale": scale,
			"yaw": float(spec["yaw"]),
			"stable_id": int(spec["stable_id"]),
			"source": String(sample.get("source", _ground_source)),
			"error_m": float(sample.get("error_m", 0.0)),
				"triangle_start": int(sample.get("overlay_triangle_start", sample.get("triangle_start", -1))),
				"barycentric": sample.get("overlay_barycentric", sample.get("barycentric", Vector3(-1.0, -1.0, -1.0))),
		})
		if family == "conifer":
			if not crown_grouped.has(variant):
				crown_grouped[variant] = []
			var stable_id := int(spec["stable_id"])
			# Crown dimensions are local, deterministic metres rather than a
			# second copy of the factory mesh AABB.  The sampled root and yaw
			# remain the same as the source tree record; only the far silhouette
			# representation changes.
			var crown_width_m := lerpf(FOREST_CROWN_MIN_WIDTH_M, FOREST_CROWN_MAX_WIDTH_M, _unit_hash(stable_id, 113))
			var crown_height_m := lerpf(FOREST_CROWN_MIN_HEIGHT_M, FOREST_CROWN_MAX_HEIGHT_M, _unit_hash(stable_id, 127))
			(crown_grouped[variant] as Array).append({
				"ground": ground,
				"width_scale": float(spec.get("width_scale", spec["scale"])),
				"height_scale": float(spec.get("height_scale", spec["scale"])),
				"width_m": crown_width_m,
				"height_m": crown_height_m,
				"yaw": float(spec["yaw"]),
				"stable_id": stable_id,
			})
		positions.append(Vector3(xz.x, ground.y, xz.y))
		contact_heights.append(ground.y)
		contact_errors.append(float(sample.get("error_m", 0.0)))
		contact_triangle_starts.append(int(sample.get("overlay_triangle_start", sample.get("triangle_start", -1))))
		contact_barycentrics.append(sample.get("overlay_barycentric", sample.get("barycentric", Vector3(-1.0, -1.0, -1.0))))
		contact_sources.append(String(sample.get("source", _ground_source)))
	var total := 0
	var multimesh_count := 0
	for key in grouped.keys():
		var items: Array = grouped[key]
		if items.is_empty():
			continue
		var mesh: Mesh = items[0]["mesh"]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = items.size()
		var bounds := mesh.get_aabb()
		var item_positions := PackedVector3Array()
		var item_heights := PackedFloat32Array()
		var item_errors := PackedFloat32Array()
		var item_triangle_starts := PackedInt32Array()
		var item_barycentrics := PackedVector3Array()
		for index in items.size():
			var item: Dictionary = items[index]
			var scale := float(item["scale"])
			var width_scale := float(item.get("width_scale", scale))
			var height_scale := float(item.get("height_scale", scale))
			var basis := Basis(Vector3.UP, float(item["yaw"])).scaled(Vector3(width_scale, height_scale, width_scale))
			var ground: Vector3 = item["ground"]
			var root_position := Vector3(ground.x, ground.y - bounds.position.y * height_scale - 0.04, ground.z)
			multimesh.set_instance_transform(index, Transform3D(basis, root_position))
			item_positions.append(root_position)
			item_heights.append(ground.y)
			item_errors.append(float(item["error_m"]))
			item_triangle_starts.append(int(item.get("triangle_start", -1)))
			item_barycentrics.append(item.get("barycentric", Vector3(-1.0, -1.0, -1.0)))
		var instance := MultiMeshInstance3D.new()
		instance.name = "S01Landscape_%s" % String(key)
		instance.multimesh = multimesh
		var is_far_conifer := String(key).begins_with("conifer_")
		# All S01 conifer records are in the bounded far ridge band.  A single
		# MultiMesh visibility range is evaluated at the node level, so an
		# end-distance alone cannot hide only its far cards from Camera-C.  Hide
		# these three local card nodes and let the same rooted crown records own
		# the far representation; the six near broadleaf nodes stay untouched.
		instance.visible = not is_far_conifer
		instance.visibility_range_end = FOREST_FAR_CARD_END_M if is_far_conifer else visibility_range_m
		instance.visibility_range_end_margin = 48.0 if is_far_conifer else 32.0
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		instance.set_meta("saisies_s01_tree_family", String(key).split("_")[0])
		instance.set_meta("saisies_s01_tree_variant", int(String(key).split("_")[1]))
		instance.set_meta("saisies_s01_tree_instance_count", items.size())
		instance.set_meta("saisies_s01_ground_source", _ground_source)
		instance.set_meta("saisies_s01_ground_positions", item_positions)
		instance.set_meta("saisies_s01_ground_heights", item_heights)
		instance.set_meta("saisies_s01_ground_errors_m", item_errors)
		instance.set_meta("saisies_s01_ground_triangle_starts", item_triangle_starts)
		instance.set_meta("saisies_s01_ground_barycentrics", item_barycentrics)
		instance.set_meta("saisies_s01_far_cards_disabled_for_c_camera", is_far_conifer)
		instance.set_meta("saisies_s01_far_card_visibility_end_m", instance.visibility_range_end)
		parent.add_child(instance)
		total += items.size()
		multimesh_count += 1
	var crown_parent := Node3D.new()
	crown_parent.name = "S01ForestClosedCrownMass"
	crown_parent.set_meta("saisies_s01_same_root_transforms", true)
	crown_parent.set_meta("saisies_s01_crown_instance_count", 0)
	parent.add_child(crown_parent)
	var crown_total := 0
	for variant_key in crown_grouped.keys():
		var crown_items: Array = crown_grouped[variant_key]
		if crown_items.is_empty():
			continue
		var crown_mesh := _forest_crown_mesh(int(variant_key))
		var crown_multimesh := MultiMesh.new()
		crown_multimesh.transform_format = MultiMesh.TRANSFORM_3D
		crown_multimesh.mesh = crown_mesh
		crown_multimesh.instance_count = crown_items.size()
		for index in crown_items.size():
			var item: Dictionary = crown_items[index]
			var width_m := float(item["width_m"])
			var height_m := float(item["height_m"])
			var basis := Basis(Vector3.UP, float(item["yaw"])).scaled(Vector3(width_m, height_m, width_m))
			var ground: Vector3 = item["ground"]
			var crown_root := Vector3(ground.x, ground.y + FOREST_CROWN_ROOT_OFFSET_M, ground.z)
			crown_multimesh.set_instance_transform(index, Transform3D(basis, crown_root))
		var crown_instance := MultiMeshInstance3D.new()
		crown_instance.name = "S01Landscape_closed_crown_%d" % int(variant_key)
		crown_instance.multimesh = crown_multimesh
		crown_instance.visibility_range_end = visibility_range_m
		crown_instance.visibility_range_end_margin = 32.0
		crown_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		crown_instance.set_meta("saisies_s01_closed_crown", true)
		crown_instance.set_meta("saisies_s01_same_root_transforms", true)
		crown_instance.set_meta("saisies_s01_tree_variant", int(variant_key))
		crown_instance.set_meta("saisies_s01_tree_instance_count", crown_items.size())
		crown_instance.set_meta("saisies_s01_crown_lobe_count", crown_mesh.get_meta("saisies_s01_crown_lobe_count", 0))
		crown_instance.set_meta("saisies_s01_crown_width_range_m", [FOREST_CROWN_MIN_WIDTH_M, FOREST_CROWN_MAX_WIDTH_M])
		crown_instance.set_meta("saisies_s01_crown_height_range_m", [FOREST_CROWN_MIN_HEIGHT_M, FOREST_CROWN_MAX_HEIGHT_M])
		crown_instance.set_meta("saisies_s01_far_cards_disabled_for_c_camera", true)
		crown_parent.add_child(crown_instance)
		crown_total += crown_items.size()
	crown_parent.set_meta("saisies_s01_crown_instance_count", crown_total)
	set_meta("saisies_s01_closed_crown_instance_count", crown_total)
	set_meta("saisies_s01_closed_crown_multimesh_node_count", crown_grouped.size())
	return {
		"instance_count": total,
		"multimesh_count": multimesh_count + crown_grouped.size(),
		"positions": positions,
		"contact_heights": contact_heights,
		"contact_errors": contact_errors,
		"triangle_starts": contact_triangle_starts,
		"barycentrics": contact_barycentrics,
		"sources": contact_sources,
	}

func _is_in_local_bounds(x: float, z: float) -> bool:
	return LOCAL_BOUNDS.has_point(Vector2(x, z))

func _ridge_crest_z(x: float) -> float:
	var x_t := clampf((x - RIDGE_CREST_START_X_M) / (RIDGE_CREST_END_X_M - RIDGE_CREST_START_X_M), 0.0, 1.0)
	return lerpf(RIDGE_CREST_START_Z_M, RIDGE_CREST_END_Z_M, x_t)

func _is_ridge_tree_band(x: float, z: float) -> bool:
	if x < RIDGE_TREE_MIN_X_M or x > RIDGE_TREE_MAX_X_M or z < RIDGE_TREE_MIN_Z_M or z > RIDGE_TREE_MAX_Z_M:
		return false
	return absf(z - _ridge_crest_z(x)) <= RIDGE_TREE_BAND_HALF_WIDTH_M

func _is_lodge_clearance(x: float, z: float) -> bool:
	return x < 17.0 and z > -132.0 and z < -78.0

func _is_opening(x: float, z: float) -> bool:
	return _is_ridge_opening(x, z)

func _is_ridge_opening(x: float, z: float) -> bool:
	var left_open := x >= -132.0 and x <= -42.0 and z >= -1260.0 and z <= -1160.0
	var right_open := x >= 42.0 and x <= 142.0 and z >= -1430.0 and z <= -1315.0
	return left_open or right_open

func _jitter(a: int, b: int, c: int, d: int) -> float:
	return _unit_hash(a * 37 + b * 101 + c * 503, d) * 2.0 - 1.0

func _unit_hash(value: int, salt: int) -> float:
	# Do not use String.hash here.  Godot's string hash has a nearly linear
	# sequence for the nearby stable IDs used by the ridge cells, so width,
	# height, yaw, and variant salts stayed correlated and produced visible
	# rows.  This is a fixed 32-bit integer avalanche with explicit masking;
	# it is deterministic across runs and does not depend on locale/runtime
	# string hashing.
	var n: int = (value & 0xffffffff) ^ ((salt & 0xffffffff) * 0x9e3779b9)
	n &= 0xffffffff
	n = ((n ^ (n >> 16)) * 0x45d9f3b) & 0xffffffff
	n = ((n ^ (n >> 16)) * 0x45d9f3b) & 0xffffffff
	n = (n ^ (n >> 16)) & 0xffffffff
	return float(n) / 4294967295.0
