extends Node3D

## Material-only S03 slope correction over the accepted R18 cafe review.
##
## The baked terrain, S01 overlays, route, camera, and buildings stay in the
## inherited scene.  This module replaces only instantiated material_override
## values, using a soft S03/camera mask so accepted S01 views are untouched.

@export var cafe_review_path: NodePath = NodePath("../CafeReview")
@export var world_path: NodePath = NodePath("../CafeReview/S03Review/S02Review/S01Review/World")
@export var s01_landscape_path: NodePath = NodePath("../CafeReview/S03Review/S02Review/S01Review/S01Landscape")
@export var enable_refinement := true

const SOURCE_FRAME := "video/saisies_analysis/acceptance/S03_f001798.png"
const SOURCE_SHA256 := "184ee032aef47be5d52b5d5c6379300dc4dca85054ada0b93ef07ed8ca043e10"
const S03_STATION_M := 930.0
const REGION_ALONG_M := 900.0
const REGION_SIDE_M := 700.0
const REGION_FADE_M := 140.0
const CAMERA_RADIUS_M := 340.0
const CAMERA_FADE_M := 100.0
const HEIGHT_FULL_M := 300.0
const HEIGHT_FADE_M := 450.0
const GROUND_SHADER := preload("res://shaders/saisies_s03_ground.gdshader")

var _built := false
var _attempts := 0
var _region_center_xz := Vector2.ZERO
var _region_forward_xz := Vector2(0.0, -1.0)
var _region_left_xz := Vector2(1.0, 0.0)
var _camera_center_world := Vector3.ZERO
var _world: Node3D
var _landscape: Node
var _terrain: MeshInstance3D
var _affected_nodes: Array[MeshInstance3D] = []

func _ready() -> void:
	process_priority = -70
	if _has_command_line_flag("--s03-ground-off"):
		enable_refinement = false
	call_deferred("_try_build")

func _try_build() -> void:
	if _built:
		return
	var cafe := get_node_or_null(cafe_review_path)
	_world = get_node_or_null(world_path) as Node3D
	_landscape = get_node_or_null(s01_landscape_path)
	if cafe == null or _world == null or _landscape == null:
		_retry("S03 ground refinement dependencies are incomplete")
		return
	if not bool(cafe.get_meta("saisies_s03_cafe_review_ready", false)):
		_retry("S03 ground refinement is waiting for the accepted R18 cafe module")
		return
	if not enable_refinement:
		_publish_disabled_state()
		_built = true
		return
	_terrain = _world.find_child("SaisiesGeoTerrain", true, false) as MeshInstance3D
	var route := _world.get_node_or_null("Route") as Node
	var camera_rig := _world.get_node_or_null("CameraRig") as Node3D
	var camera := camera_rig.get_node_or_null("Camera3D") as Camera3D if camera_rig != null else null
	var overlay_root := _landscape.find_child("S01LandscapeRefinement", true, false)
	if _terrain == null or route == null or overlay_root == null or not route.has_method("pos_at") or not route.has_method("left_at"):
		_fail_and_hold("S03 ground refinement could not resolve terrain, route, or S01 overlays")
		return
	if not _set_region(route, camera):
		_fail_and_hold("S03 ground refinement could not establish its fixed S03 mask")
		return
	var geometry_before := _snapshot_all_geometry(overlay_root)
	var overlay_count := _override_s01_overlays(overlay_root)
	if overlay_count <= 0:
		_fail_and_hold("S03 ground refinement found no accepted S01 ground overlays")
		return
	if not _override_geo_terrain():
		_fail_and_hold("S03 ground refinement could not preserve the geo terrain albedo")
		return
	var geometry_after := _snapshot_all_geometry(overlay_root)
	var unchanged := _geometry_snapshots_match(geometry_before, geometry_after)
	if not unchanged:
		_fail_and_hold("S03 ground material pass changed a mesh signature")
		return
	var region_bounds := _region_bounds_xz()
	set_meta("saisies_s03_ground_refinement_ready", true)
	set_meta("saisies_s03_ground_refinement_enabled", true)
	set_meta("saisies_s03_ground_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_ground_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_ground_source_hashes_unchanged", true)
	set_meta("saisies_s03_ground_affected_nodes", PackedStringArray(_affected_paths()))
	set_meta("saisies_s03_ground_region_bounds_xz", region_bounds)
	set_meta("saisies_s03_ground_region_center_xz", _region_center_xz)
	set_meta("saisies_s03_ground_region_forward_xz", _region_forward_xz)
	set_meta("saisies_s03_ground_region_left_xz", _region_left_xz)
	set_meta("saisies_s03_ground_region_along_m", REGION_ALONG_M)
	set_meta("saisies_s03_ground_region_side_m", REGION_SIDE_M)
	set_meta("saisies_s03_ground_region_fade_m", REGION_FADE_M)
	set_meta("saisies_s03_ground_camera_center_world", _camera_center_world)
	set_meta("saisies_s03_ground_camera_radius_m", CAMERA_RADIUS_M)
	set_meta("saisies_s03_ground_camera_fade_m", CAMERA_FADE_M)
	set_meta("saisies_s03_ground_height_full_m", HEIGHT_FULL_M)
	set_meta("saisies_s03_ground_height_fade_m", HEIGHT_FADE_M)
	set_meta("saisies_s03_ground_overlay_strength", 0.95)
	set_meta("saisies_s03_ground_emission_strength", 0.12)
	set_meta("saisies_s03_ground_geometry_unchanged", true)
	set_meta("saisies_s03_ground_geometry_before", geometry_before)
	set_meta("saisies_s03_ground_geometry_after", geometry_after)
	set_meta("saisies_s03_ground_material_mode", "bounded smooth S03 grass mask over S01 overlays and SaisiesGeoTerrain")
	_publish_parent_ready()
	_built = true

func _set_region(route: Node, camera: Camera3D) -> bool:
	var station := S03_STATION_M
	if route.has_method("acceptance_distance"):
		var accepted = route.call("acceptance_distance", "S03")
		if is_finite(float(accepted)):
			station = float(accepted)
	var route_position := Vector3(route.call("pos_at", station))
	var left := Vector3(route.call("left_at", station))
	if not route_position.is_finite() or left.length_squared() < 0.5:
		return false
	left.y = 0.0
	left = left.normalized()
	var forward := Vector3(-left.z, 0.0, left.x).normalized()
	if forward.length_squared() < 0.5:
		return false
	_region_center_xz = Vector2(route_position.x, route_position.z)
	_region_forward_xz = Vector2(forward.x, forward.z).normalized()
	_region_left_xz = Vector2(left.x, left.z).normalized()
	_camera_center_world = camera.global_position if camera != null else route_position
	return _camera_center_world.is_finite()

func _override_s01_overlays(overlay_root: Node) -> int:
	var count := 0
	for candidate in overlay_root.find_children("*", "MeshInstance3D", true, false):
		var instance := candidate as MeshInstance3D
		if instance == null or instance.mesh == null:
			continue
		var name := String(instance.name)
		var ridge := name == "S01RidgeTerrainOverlay" or name == "S01ForestFloorCover"
		var slope := name.begins_with("S01GrassSlope_")
		if not ridge and not slope:
			continue
		var old_material := instance.material_override
		var material := _new_material(false, ridge)
		if not _attach_next_pass(instance, material):
			_fail_and_hold("S03 ground could not attach a local pass to %s" % name)
			return 0
		instance.set_meta("saisies_s03_ground_material_override", true)
		instance.set_meta("saisies_s03_ground_previous_material", str(old_material.resource_path) if old_material != null else "")
		instance.set_meta("saisies_s03_ground_shader", "res://shaders/saisies_s03_ground.gdshader")
		_affected_nodes.append(instance)
		count += 1
	return count

func _override_geo_terrain() -> bool:
	if _terrain == null or _terrain.mesh == null:
		return false
	var old_material := _terrain.material_override
	var material := _new_material(true, false)
	if not _attach_next_pass(_terrain, material):
		return false
	_terrain.set_meta("saisies_s03_ground_material_override", true)
	_terrain.set_meta("saisies_s03_ground_previous_shader", str((old_material as ShaderMaterial).shader.resource_path) if old_material is ShaderMaterial and (old_material as ShaderMaterial).shader != null else "")
	_terrain.set_meta("saisies_s03_ground_shader", "res://shaders/saisies_s03_ground.gdshader")
	_affected_nodes.append(_terrain)
	return true

func _attach_next_pass(instance: MeshInstance3D, pass_material: ShaderMaterial) -> bool:
	var base_material := instance.material_override
	if base_material == null:
		instance.material_override = pass_material
		return true
	var copy := base_material.duplicate() as Material
	if copy == null:
		return false
	copy.next_pass = pass_material
	instance.material_override = copy
	return true

func _new_material(terrain_mode: bool, ridge: bool) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = GROUND_SHADER
	material.set_shader_parameter("terrain_mode", terrain_mode)
	material.set_shader_parameter("overlay_pass", true)
	material.set_shader_parameter("overlay_strength", 0.95)
	material.set_shader_parameter("mask_enabled", true)
	material.set_shader_parameter("region_center_xz", _region_center_xz)
	material.set_shader_parameter("region_forward_xz", _region_forward_xz)
	material.set_shader_parameter("region_left_xz", _region_left_xz)
	material.set_shader_parameter("region_along_m", REGION_ALONG_M)
	material.set_shader_parameter("region_side_m", REGION_SIDE_M)
	material.set_shader_parameter("region_fade_m", REGION_FADE_M)
	material.set_shader_parameter("camera_center_world", _camera_center_world)
	material.set_shader_parameter("camera_radius_m", CAMERA_RADIUS_M)
	material.set_shader_parameter("camera_fade_m", CAMERA_FADE_M)
	material.set_shader_parameter("variation_scale", 0.008)
	material.set_shader_parameter("fine_scale", 0.040)
	material.set_shader_parameter("slope_darkening", 0.08)
	material.set_shader_parameter("grass_shadow", Color(0.10, 0.15, 0.065, 1.0))
	material.set_shader_parameter("grass_mid", Color(0.22, 0.29, 0.135, 1.0))
	material.set_shader_parameter("grass_sun", Color(0.32, 0.39, 0.20, 1.0))
	material.set_shader_parameter("height_full_m", HEIGHT_FULL_M)
	material.set_shader_parameter("height_fade_m", HEIGHT_FADE_M)
	material.set_shader_parameter("overlay_strength", 0.95)
	material.set_shader_parameter("ground_emission_strength", 0.12)
	return material

func _snapshot_all_geometry(overlay_root: Node) -> Dictionary:
	var snapshot: Dictionary = {}
	for instance in _geometry_targets(overlay_root):
		snapshot[str(instance.get_path())] = _geometry_signature(instance)
	if _terrain != null:
		snapshot[str(_terrain.get_path())] = _geometry_signature(_terrain)
	return snapshot

func _geometry_targets(overlay_root: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for candidate in overlay_root.find_children("*", "MeshInstance3D", true, false):
		var instance := candidate as MeshInstance3D
		if instance == null or instance.mesh == null:
			continue
		var name := String(instance.name)
		if name == "S01RidgeTerrainOverlay" or name == "S01ForestFloorCover" or name.begins_with("S01GrassSlope_"):
			result.append(instance)
	return result

func _geometry_signature(instance: MeshInstance3D) -> Dictionary:
	var vertices := PackedInt32Array()
	var indices := PackedInt32Array()
	var mesh := instance.mesh
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var surface_vertices = arrays[Mesh.ARRAY_VERTEX] if arrays.size() > Mesh.ARRAY_VERTEX else null
		var surface_indices = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX else null
		vertices.append(surface_vertices.size() if surface_vertices != null else -1)
		indices.append(surface_indices.size() if surface_indices != null else -1)
	return {
		"vertex_counts": vertices,
		"index_counts": indices,
		"aabb": _aabb_values(instance.get_aabb()),
		"global_transform": _transform_values(instance.global_transform),
	}

func _geometry_snapshots_match(before: Dictionary, after: Dictionary) -> bool:
	if before.size() != after.size():
		return false
	for key in before.keys():
		if not after.has(key):
			return false
		var a: Dictionary = before[key]
		var b: Dictionary = after[key]
		if a.get("vertex_counts", PackedInt32Array()) != b.get("vertex_counts", PackedInt32Array()):
			return false
		if a.get("index_counts", PackedInt32Array()) != b.get("index_counts", PackedInt32Array()):
			return false
		if a.get("aabb", []) != b.get("aabb", []) or a.get("global_transform", []) != b.get("global_transform", []):
			return false
	return true

func _aabb_values(aabb: AABB) -> Array[float]:
	return [aabb.position.x, aabb.position.y, aabb.position.z, aabb.size.x, aabb.size.y, aabb.size.z]

func _transform_values(transform: Transform3D) -> Array[float]:
	return [
		transform.basis.x.x, transform.basis.x.y, transform.basis.x.z,
		transform.basis.y.x, transform.basis.y.y, transform.basis.y.z,
		transform.basis.z.x, transform.basis.z.y, transform.basis.z.z,
		transform.origin.x, transform.origin.y, transform.origin.z,
	]

func _region_bounds_xz() -> Array[float]:
	var along := REGION_ALONG_M + REGION_FADE_M
	var side := REGION_SIDE_M + REGION_FADE_M
	var corners := [
		_region_center_xz + _region_forward_xz * along + _region_left_xz * side,
		_region_center_xz + _region_forward_xz * along - _region_left_xz * side,
		_region_center_xz - _region_forward_xz * along + _region_left_xz * side,
		_region_center_xz - _region_forward_xz * along - _region_left_xz * side,
	]
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for corner in corners:
		var point: Vector2 = corner
		min_x = minf(min_x, point.x)
		min_z = minf(min_z, point.y)
		max_x = maxf(max_x, point.x)
		max_z = maxf(max_z, point.y)
	return [min_x, min_z, max_x, max_z]

func _affected_paths() -> Array[String]:
	var paths: Array[String] = []
	for node in _affected_nodes:
		paths.append(str(node.get_path()))
	return paths

func _publish_disabled_state() -> void:
	set_meta("saisies_s03_ground_refinement_ready", true)
	set_meta("saisies_s03_ground_refinement_enabled", false)
	set_meta("saisies_s03_ground_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_ground_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_ground_source_hashes_unchanged", true)
	_publish_parent_ready()

func _publish_parent_ready() -> void:
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s03_ground_review_ready", true)
		parent.set_meta("saisies_s03_ground_review_enabled", enable_refinement)
		parent.set_meta("saisies_s03_ground_review_source_frame", SOURCE_FRAME)

func _retry(message: String) -> void:
	_attempts += 1
	if _attempts < 240:
		call_deferred("_retry_next_frame")
	else:
		_fail_and_hold(message)

func _retry_next_frame() -> void:
	await get_tree().process_frame
	_try_build()

func _fail_and_hold(message: String) -> void:
	set_meta("saisies_s03_ground_refinement_ready", false)
	set_meta("saisies_s03_ground_refinement_error", message)
	push_error(message)

func _has_command_line_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()
