extends Node3D

## Bounded S03 junction pavement rebuild over the accepted R26 parasol review.
##
## R17's apron samples are too sparse for the visible banked terrain and can
## sit below the S01 overlay. This node keeps the route and camera untouched,
## keeps the authored R17 mesh available for cafe contacts, and adds a fine
## local pavement surface from the visible actual ground/road helpers. The
## replacement is limited to the old apron plus a short taper back to the road.

@export var parasol_review_path: NodePath = NodePath("../ParasolReview")
@export var world_path: NodePath = NodePath("../ParasolReview/CafeTreesReview/RightForestReview/LeftForestReview/FlowersReview/SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/World")
@export var s01_landscape_path: NodePath = NodePath("../ParasolReview/CafeTreesReview/RightForestReview/LeftForestReview/FlowersReview/SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/S01Landscape")
@export var junction_path: NodePath = NodePath("../ParasolReview/CafeTreesReview/RightForestReview/LeftForestReview/FlowersReview/SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S03JunctionRefinement")
@export var enable_refinement := true

const SOURCE_FRAME := "video/saisies_analysis/acceptance/S03_f001798.png"
const SOURCE_SHA256 := "184ee032aef47be5d52b5d5c6379300dc4dca85054ada0b93ef07ed8ca043e10"
const CAMERA_GATE_CENTER := Vector3(138.9204, -65.5922, -839.3978)
const CAMERA_GATE_END_M := 420.0
const PATCH_FROM_M := 885.0
const PATCH_TO_M := 1060.0
const OLD_APRON_TO_M := 1005.0
const SAMPLE_STEP_M := 3.0
const CROSS_SECTION_SAMPLES := 21
const TAPER_END_EXTRA_M := 0.25
const PATCH_LIFT_M := 0.075
const MAX_SAMPLE_STEP_Y_M := 3.0
const TERRACE_PROTECT_MARGIN_M := 0.32

var _parasol_review: Node
var _world: Node3D
var _landscape: Node
var _junction: Node
var _route: Node
var _camera: Camera3D
var _junction_pavement: MeshInstance3D
var _old_center_overlay: MeshInstance3D
var _terrace: MeshInstance3D
var _replacement: Node3D
var _built := false
var _attempts := 0
var _lod_active := false
var _vertex_contact_records: Array = []
var _shape_record: Dictionary = {}
var _asphalt: StandardMaterial3D
var _protected_terrace_aabb := AABB()
var _protected_quad_count := 0

func _ready() -> void:
	process_priority = -70
	if _has_command_line_flag("--s03-junction-shape-off"):
		enable_refinement = false
	call_deferred("_try_build")

func _process(_delta: float) -> void:
	if _built:
		_update_lod_gate()

func _try_build() -> void:
	if _built:
		return
	_parasol_review = get_node_or_null(parasol_review_path)
	_world = get_node_or_null(world_path) as Node3D
	_landscape = get_node_or_null(s01_landscape_path)
	_junction = get_node_or_null(junction_path)
	_route = _world.get_node_or_null("Route") if _world != null else null
	if _parasol_review == null or _world == null or _landscape == null or _junction == null or _route == null:
		_retry("S03 junction shape dependencies are incomplete")
		return
	if not bool(_parasol_review.get_meta("saisies_s03_cafe_parasol_review_ready", false)):
		_retry("S03 junction shape is waiting for the accepted R26 review")
		return
	if not bool(_landscape.get_meta("saisies_s01_landscape_ready", false)) or not _landscape.has_method("_sample_baked_ground") or not _landscape.has_method("_sample_overlay_ground"):
		_retry("S03 junction shape requires visible S01 ground sampling")
		return
	if not _route.has_method("pos_at") or not _route.has_method("left_at") or not _route.has_method("_road_point") or not _route.has_method("road_width_at"):
		_fail_and_hold("S03 junction shape requires the shared route surface helpers")
		return
	if not _junction.has_method("_edge_half_width") or not bool(_junction.get_meta("saisies_s03_junction_refinement_ready", false)):
		_retry("S03 junction shape is waiting for R17 junction readiness")
		return
	_junction_pavement = _junction.find_child("S03JunctionPavement", true, false) as MeshInstance3D
	_old_center_overlay = _junction.find_child("S03JunctionCenterAsphaltOverlay", true, false) as MeshInstance3D
	# CafeRefinement is a sibling of the nested World, so resolve the terrace
	# from the R26 review root rather than from World.find_child().
	_terrace = _parasol_review.find_child("S03CafeRefinementTerrace", true, false) as MeshInstance3D
	if _terrace != null and _terrace.mesh != null:
		_protected_terrace_aabb = _world_aabb(_terrace)
	var rig := _world.get_node_or_null("CameraRig") as Node3D
	_camera = rig.get_node_or_null("Camera3D") as Camera3D if rig != null else null
	if _camera == null:
		_retry("S03 junction shape requires the inherited Camera3D")
		return
	if not enable_refinement:
		_publish_disabled_state()
		_built = true
		return
	if not _build_candidate():
		_fail_and_hold("S03 junction shape could not establish continuous actual-surface contacts")
		return
	_built = true
	_update_lod_gate()
	_publish_ready_state()

func _build_candidate() -> bool:
	_vertex_contact_records.clear()
	_protected_quad_count = 0
	var candidate := Node3D.new()
	candidate.name = "S03JunctionShapeCandidate"
	candidate.set_meta("saisies_s03_junction_shape_owner", "fine local S03 junction pavement and road taper")
	candidate.set_meta("saisies_s03_junction_shape_source_frame", SOURCE_FRAME)
	candidate.set_meta("saisies_s03_junction_shape_source_sha256", SOURCE_SHA256)
	candidate.set_meta("saisies_s03_junction_shape_surface_policy", "highest matching visible actual surface; no nearest-vertex fallback")
	candidate.set_meta("saisies_s03_junction_shape_station_range_m", Vector2(PATCH_FROM_M, PATCH_TO_M))
	add_child(candidate)
	var pavement := _build_pavement_patch(candidate)
	if pavement == null or _vertex_contact_records.size() < 64:
		candidate.queue_free()
		return false
	# The old R17 pavement remains in the scene for CafeRefinement's authored
	# contact contract. Only its center overlay is replaced; the fine patch is
	# lifted above the old apron and therefore owns the visible surface.
	if _old_center_overlay != null:
		_old_center_overlay.visible = false
	_shape_record = {
		"name": "S03JunctionShape",
		"source_frame": SOURCE_FRAME,
		"source_sha256": SOURCE_SHA256,
		"station_range_m": Vector2(PATCH_FROM_M, PATCH_TO_M),
		"old_apron_range_m": Vector2(PATCH_FROM_M, OLD_APRON_TO_M),
		"sample_step_m": SAMPLE_STEP_M,
		"cross_section_samples": CROSS_SECTION_SAMPLES,
		"taper_end_extra_m": TAPER_END_EXTRA_M,
		"vertex_contact_records": _vertex_contact_records,
		"pavement_path": str(pavement.get_path()),
		"pavement_vertex_count": _mesh_vertex_count(pavement.mesh),
		"protected_terrace_quad_count": _protected_quad_count,
		"route_center_unchanged": true,
		"camera_unchanged": true,
	}
	candidate.set_meta("saisies_s03_junction_shape_record", _shape_record)
	candidate.set_meta("saisies_s03_junction_shape_vertex_contact_records", _vertex_contact_records)
	candidate.set_meta("saisies_s03_junction_shape_pavement", true)
	candidate.set_meta("saisies_s03_junction_shape_old_r17_pavement_preserved", true)
	candidate.set_meta("saisies_s03_junction_shape_old_center_overlay_hidden", _old_center_overlay != null)
	_replacement = candidate
	set_meta("saisies_s03_junction_shape_applied", true)
	set_meta("saisies_s03_junction_shape_record", _shape_record)
	set_meta("saisies_s03_junction_shape_vertex_contact_records", _vertex_contact_records)
	set_meta("saisies_s03_junction_shape_actual_triangle_contact_count", _vertex_contact_records.size())
	return true

func _build_pavement_patch(parent: Node3D) -> MeshInstance3D:
	var stations := _station_list()
	var rows: Array = []
	for station in stations:
		var target_half := _target_half_width(station)
		var current_half := _current_boundary_half_width(station)
		var points: Array = []
		for column in CROSS_SECTION_SAMPLES:
			var ratio := float(column) / float(CROSS_SECTION_SAMPLES - 1)
			var lateral := lerpf(-target_half, target_half, ratio)
			var sampled := _sample_actual_surface(station, lateral, PATCH_LIFT_M)
			if sampled.is_empty():
				return null
			points.append(sampled)
		rows.append({
			"station_m": station,
			"current_half_width_m": current_half,
			"target_half_width_m": target_half,
			"points": points,
		})

	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var vertex_count := 0
	for station_index in range(stations.size() - 1):
		var row0: Dictionary = rows[station_index]
		var row1: Dictionary = rows[station_index + 1]
		var p0: Array = row0["points"]
		var p1: Array = row1["points"]
		for column in range(CROSS_SECTION_SAMPLES - 1):
			var a: Dictionary = p0[column]
			var b: Dictionary = p0[column + 1]
			var c: Dictionary = p1[column + 1]
			var d: Dictionary = p1[column]
			if _quad_protected(a, b, c, d):
				_protected_quad_count += 1
				continue
			if not _continuous_samples(a, b, c, d):
				return null
			_add_quad(surface, a["position"], b["position"], c["position"], d["position"])
			vertex_count += 6
			_record_vertex(a, row0)
			_record_vertex(b, row0)
			_record_vertex(c, row1)
			_record_vertex(d, row1)
	surface.generate_normals()
	var mesh := surface.commit()
	if mesh == null or vertex_count < 64:
		return null
	var instance := MeshInstance3D.new()
	instance.name = "S03JunctionShapePavement"
	instance.mesh = mesh
	instance.material_override = _junction_asphalt_material()
	instance.set_meta("saisies_s03_junction_shape_ground_source", "visible actual S01 overlay/baked/route surfaces")
	instance.set_meta("saisies_s03_junction_shape_vertex_count", vertex_count)
	instance.set_meta("saisies_s03_junction_shape_station_range_m", Vector2(PATCH_FROM_M, PATCH_TO_M))
	instance.set_meta("saisies_s03_junction_shape_old_r17_pavement_preserved", true)
	parent.add_child(instance)
	return instance

func _sample_actual_surface(station: float, lateral: float, lift: float) -> Dictionary:
	var base := Vector3(_route.call("pos_at", station))
	var left := Vector3(_route.call("left_at", station))
	left.y = 0.0
	if left.length_squared() < 0.0001 or not base.is_finite():
		return {}
	left = left.normalized()
	var target := base + left * lateral
	var xz := Vector2(target.x, target.z)
	var protected := _point_in_terrace_footprint(target)
	var candidates: Array = []
	var sources: Array[String] = []
	if protected and _junction_pavement != null and _junction_pavement.mesh != null:
		# Keep the authored terrace/stair support below the fine surface. These
		# cells are left to the preserved R17 mesh rather than raised into cafe.
		var old_surface := _sample_mesh_surface(_junction_pavement, xz)
		_add_surface_candidate(candidates, sources, old_surface, "S03JunctionPavement.mesh_triangle", target)
	else:
		# Keep the two visible S01 layers independent and select the higher
		# matching triangle. The route's DEM-style terrain helper is not a baked
		# mesh contact, so it is deliberately excluded here.
		var baked_variant: Variant = _landscape.call("_sample_baked_ground", xz)
		_add_surface_candidate(candidates, sources, baked_variant, "S01Landscape._sample_baked_ground", target)
		var overlay_variant: Variant = _landscape.call("_sample_overlay_ground", xz)
		_add_surface_candidate(candidates, sources, overlay_variant, "S01Landscape._sample_overlay_ground", target)
		var road_half := float(_route.call("road_width_at", station)) * 0.5
		if absf(lateral) <= road_half + 0.05:
			var route_road: Variant = _route.call("_road_point", station, lateral, 0.0)
			_add_surface_candidate(candidates, sources, route_road, "Route._road_point_surface", target)
	if candidates.is_empty():
		return {}
	var chosen: Dictionary = candidates[0]
	for candidate in candidates:
		if float((candidate["position"] as Vector3).y) > float((chosen["position"] as Vector3).y):
			chosen = candidate
	var ground: Vector3 = chosen["position"]
	return {
		"position": Vector3(target.x, ground.y + lift, target.z),
		"ground": Vector3(target.x, ground.y, target.z),
		"station_m": station,
		"lateral_m": lateral,
		"source": String(chosen.get("source", "unknown")),
		"triangle_start": int(chosen.get("triangle_start", -1)),
		"candidate_sources": PackedStringArray(sources),
		"protected": protected,
	}

func _add_surface_candidate(candidates: Array, sources: Array[String], value: Variant, fallback_source: String, target: Vector3) -> void:
	var position := Vector3.ZERO
	var source := fallback_source
	var triangle_start := -1
	if value is Vector3:
		position = value
	elif value is Dictionary and value.has("position") and value["position"] is Vector3:
		position = value["position"]
		source = String(value.get("source", fallback_source))
		triangle_start = int(value.get("triangle_start", value.get("overlay_triangle_start", -1)))
	else:
		return
	if not position.is_finite() or absf(position.x - target.x) > 0.08 or absf(position.z - target.z) > 0.08:
		return
	if source.to_lower().contains("fallback") or source.to_lower().contains("nearest"):
		return
	sources.append(source)
	candidates.append({"position": position, "source": source, "triangle_start": triangle_start})

func _sample_mesh_surface(instance: MeshInstance3D, point: Vector2) -> Dictionary:
	var mesh := instance.mesh
	var found := false
	var best_y := -INF
	var best_triangle := -1
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var triangle_count := indices.size() / 3 if not indices.is_empty() else vertices.size() / 3
		for triangle in triangle_count:
			var i0 := indices[triangle * 3] if not indices.is_empty() else triangle * 3
			var i1 := indices[triangle * 3 + 1] if not indices.is_empty() else triangle * 3 + 1
			var i2 := indices[triangle * 3 + 2] if not indices.is_empty() else triangle * 3 + 2
			var a: Vector3 = instance.global_transform * vertices[i0]
			var b: Vector3 = instance.global_transform * vertices[i1]
			var c: Vector3 = instance.global_transform * vertices[i2]
			var height := _triangle_height(point, a, b, c)
			if is_finite(height) and (not found or height > best_y):
				found = true
				best_y = height
				best_triangle = triangle * 3
	if not found:
		return {}
	return {"position": Vector3(point.x, best_y, point.y), "source": "S03JunctionPavement.mesh_triangle", "triangle_start": best_triangle}

func _triangle_height(point: Vector2, a: Vector3, b: Vector3, c: Vector3) -> float:
	var denominator := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(denominator) < 0.000001:
		return NAN
	var wa := ((b.z - c.z) * (point.x - c.x) + (c.x - b.x) * (point.y - c.z)) / denominator
	var wb := ((c.z - a.z) * (point.x - c.x) + (a.x - c.x) * (point.y - c.z)) / denominator
	var wc := 1.0 - wa - wb
	if wa < -0.001 or wb < -0.001 or wc < -0.001:
		return NAN
	return a.y * wa + b.y * wb + c.y * wc

func _continuous_samples(a: Dictionary, b: Dictionary, c: Dictionary, d: Dictionary) -> bool:
	var points: Array = [a["ground"], b["ground"], c["ground"], d["ground"]]
	for i in points.size():
		if not (points[i] as Vector3).is_finite():
			return false
		if i > 0 and absf((points[i] as Vector3).y - (points[i - 1] as Vector3).y) > MAX_SAMPLE_STEP_Y_M:
			return false
	return true

func _quad_protected(a: Dictionary, b: Dictionary, c: Dictionary, d: Dictionary) -> bool:
	return bool(a.get("protected", false)) or bool(b.get("protected", false)) or bool(c.get("protected", false)) or bool(d.get("protected", false))

func _record_vertex(sample: Dictionary, row: Dictionary) -> void:
	_vertex_contact_records.append({
		"station_m": float(sample["station_m"]),
		"lateral_m": float(sample["lateral_m"]),
		"current_half_width_m": float(row["current_half_width_m"]),
		"target_half_width_m": float(row["target_half_width_m"]),
		"world": sample["position"],
		"ground": sample["ground"],
		"source": String(sample["source"]),
		"triangle_start": int(sample.get("triangle_start", -1)),
		"candidate_sources": sample.get("candidate_sources", PackedStringArray()),
		"protected_terrace": bool(sample.get("protected", false)),
	})

func _current_boundary_half_width(station: float) -> float:
	if station <= OLD_APRON_TO_M:
		return float(_junction.call("_edge_half_width", station))
	return float(_route.call("road_width_at", station)) * 0.5

func _target_half_width(station: float) -> float:
	if station <= OLD_APRON_TO_M:
		return float(_junction.call("_edge_half_width", station))
	var t := clampf((station - OLD_APRON_TO_M) / (PATCH_TO_M - OLD_APRON_TO_M), 0.0, 1.0)
	var road_half := float(_route.call("road_width_at", station)) * 0.5 + TAPER_END_EXTRA_M
	return lerpf(float(_junction.call("_edge_half_width", OLD_APRON_TO_M)), road_half, smoothstep(0.0, 1.0, t))

func _station_list() -> Array[float]:
	var stations: Array[float] = []
	var station := PATCH_FROM_M
	while station < PATCH_TO_M:
		stations.append(station)
		station += SAMPLE_STEP_M
	stations.append(PATCH_TO_M)
	return stations

func _point_in_terrace_footprint(point: Vector3) -> bool:
	if _terrace == null or _terrace.mesh == null:
		return false
	return point.x >= _protected_terrace_aabb.position.x - TERRACE_PROTECT_MARGIN_M and point.x <= _protected_terrace_aabb.end.x + TERRACE_PROTECT_MARGIN_M and point.z >= _protected_terrace_aabb.position.z - TERRACE_PROTECT_MARGIN_M and point.z <= _protected_terrace_aabb.end.z + TERRACE_PROTECT_MARGIN_M

func _world_aabb(instance: MeshInstance3D) -> AABB:
	var local := instance.get_aabb()
	var corners: Array[Vector3] = [
		local.position,
		Vector3(local.end.x, local.position.y, local.position.z),
		Vector3(local.position.x, local.end.y, local.position.z),
		Vector3(local.position.x, local.position.y, local.end.z),
		Vector3(local.end.x, local.end.y, local.position.z),
		Vector3(local.end.x, local.position.y, local.end.z),
		Vector3(local.position.x, local.end.y, local.end.z),
		local.end,
	]
	var result := AABB(instance.global_transform * corners[0], Vector3.ZERO)
	for corner in corners.slice(1):
		result = result.expand(instance.global_transform * corner)
	return result

func _add_quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	if (b - a).cross(c - a).y < -0.0001:
		surface.add_vertex(a)
		surface.add_vertex(c)
		surface.add_vertex(b)
		surface.add_vertex(a)
		surface.add_vertex(d)
		surface.add_vertex(c)
		return
	surface.add_vertex(a)
	surface.add_vertex(b)
	surface.add_vertex(c)
	surface.add_vertex(a)
	surface.add_vertex(c)
	surface.add_vertex(d)

func _junction_asphalt_material() -> StandardMaterial3D:
	_asphalt = StandardMaterial3D.new()
	_asphalt.albedo_texture = load("res://assets/textures/asphalt_02_diff.jpg")
	_asphalt.normal_enabled = true
	_asphalt.normal_texture = load("res://assets/textures/asphalt_02_nor.jpg")
	_asphalt.albedo_color = Color(0.78, 0.78, 0.78, 1.0)
	_asphalt.roughness = 0.94
	_asphalt.cull_mode = BaseMaterial3D.CULL_DISABLED
	_asphalt.uv1_triplanar = true
	_asphalt.uv1_world_triplanar = true
	_asphalt.uv1_scale = Vector3.ONE * 0.32
	return _asphalt

func _mesh_vertex_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var count := 0
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
			count += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return count

func _update_lod_gate() -> void:
	if _camera == null or _replacement == null:
		return
	var distance := _camera.global_position.distance_to(CAMERA_GATE_CENTER)
	_lod_active = distance <= CAMERA_GATE_END_M
	_replacement.visible = _lod_active
	set_meta("saisies_s03_junction_shape_lod_active", _lod_active)
	set_meta("saisies_s03_junction_shape_camera_gate_distance_m", distance)

func _publish_ready_state() -> void:
	set_meta("saisies_s03_junction_shape_ready", true)
	set_meta("saisies_s03_junction_shape_enabled", true)
	set_meta("saisies_s03_junction_shape_count", 1)
	set_meta("saisies_s03_junction_shape_lod_active", _lod_active)
	set_meta("saisies_s03_junction_shape_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_junction_shape_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_junction_shape_station_range_m", Vector2(PATCH_FROM_M, PATCH_TO_M))
	set_meta("saisies_s03_junction_shape_vertex_contact_records", _vertex_contact_records)
	set_meta("saisies_s03_junction_shape_record", _shape_record)
	_publish_parent_ready(true)

func _publish_disabled_state() -> void:
	set_meta("saisies_s03_junction_shape_ready", true)
	set_meta("saisies_s03_junction_shape_enabled", false)
	set_meta("saisies_s03_junction_shape_count", 0)
	set_meta("saisies_s03_junction_shape_lod_active", false)
	set_meta("saisies_s03_junction_shape_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_junction_shape_station_range_m", Vector2(PATCH_FROM_M, PATCH_TO_M))
	set_meta("saisies_s03_junction_shape_vertex_contact_records", [])
	_publish_parent_ready(false)

func _publish_parent_ready(enabled: bool) -> void:
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s03_junction_shape_review_ready", true)
		parent.set_meta("saisies_s03_junction_shape_review_enabled", enabled)
	var current := get_tree().current_scene
	if current != null:
		current.set_meta("saisies_s03_junction_shape_review_ready", true)
		current.set_meta("saisies_s03_junction_shape_review_enabled", enabled)

func _retry(message: String) -> void:
	_attempts += 1
	if _attempts < 240:
		call_deferred("_retry_next_frame")
		return
	_fail_and_hold(message)

func _retry_next_frame() -> void:
	await get_tree().process_frame
	_try_build()

func _fail_and_hold(message: String) -> void:
	set_meta("saisies_s03_junction_shape_ready", false)
	set_meta("saisies_s03_junction_shape_enabled", false)
	set_meta("saisies_s03_junction_shape_error", message)
	_publish_parent_ready(false)
	push_error(message)

func _has_command_line_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()
