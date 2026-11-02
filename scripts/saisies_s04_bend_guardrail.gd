extends Node3D

## R32 controlled S04 guardrail review over the frozen R31 linked-bends scene.
##
## Only the short right-side 105..110 second span is authored here.  The road
## and terrain remain owned by the existing route/mesh; this module adds two
## MultiMeshes and records every sampled endpoint and post transform.

@export var linked_bends_base_path: NodePath = NodePath("../LinkedBendsBase")
@export var world_path: NodePath = NodePath("../LinkedBendsBase/S03Base/JunctionShapeReview/ParasolReview/CafeTreesReview/RightForestReview/LeftForestReview/FlowersReview/SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/World")
@export var forest_refinement_path: NodePath = NodePath("../LinkedBendsBase/S03Base/JunctionShapeReview/ParasolReview/CafeTreesReview/RightForestReview/RightForestRefinement")
@export_file("*.json") var candidate_path := "res://data/saisies_s04_bend_guardrail.json"
@export var enable_refinement := true
@export var visibility_gate_end_m := 360.0

const BASE_READY_META := "saisies_s04_linked_bends_review_ready"
const REVIEW_STATUS := "root_selected_for_integrated_review"
const RIGHT_SIDE := -1.0
const EDGE_OFFSET_M := 0.45
const BEAM_TOP_M := 0.80
const BEAM_HEIGHT_M := 0.30
const BEAM_STEP_M := 2.0
const POST_SPACING_M := 3.0
const POST_WIDTH_M := 0.10
const POST_DEPTH_M := 0.10
const POST_TEMPLATE_HEIGHT_M := 1.0
const POST_BURY_M := 0.04
const POST_MIN_HEIGHT_M := 0.05

var _base: Node
var _world: Node3D
var _route: Node
var _camera: Camera3D
var _forest_refinement: Node
var _terrain_mesh_instance: MeshInstance3D
var _roadside_helper: SaisiesGeoRoadside
var _beam_mesh: ArrayMesh
var _post_mesh: BoxMesh
var _guard_material: StandardMaterial3D
var _post_material: StandardMaterial3D
var _beam_instance: MultiMeshInstance3D
var _post_instance: MultiMeshInstance3D
var _beam_records: Array[Dictionary] = []
var _post_records: Array[Dictionary] = []
var _ground_records: Array[Dictionary] = []
var _candidate_payload: Dictionary = {}
var _from_station_m := 1450.0
var _to_station_m := 1575.0
var _side := RIGHT_SIDE
var _edge_offset_m := EDGE_OFFSET_M
var _beam_top_m := BEAM_TOP_M
var _beam_height_m := BEAM_HEIGHT_M
var _beam_step_m := BEAM_STEP_M
var _post_spacing_m := POST_SPACING_M
var _span_center := Vector3.ZERO
var _built := false
var _ready_published := false
var _lod_active := false
var _attempts := 0
var _off_requested := false
var _local_ground_triangles: Array[Dictionary] = []
var _local_ground_bounds := Rect2()
var _local_ground_mesh_path := ""
var _local_ground_scan_triangle_count := 0
var _local_ground_cached_triangle_count := 0

func _ready() -> void:
	process_priority = -80
	_off_requested = _has_command_line_flag("--s04-guardrail-off")
	call_deferred("_try_build")

func _try_build() -> void:
	if _built or _ready_published:
		return
	if not _resolve_nodes():
		_retry("S04 bend guardrail dependencies are incomplete")
		return
	if not _base_ready():
		_retry("S04 bend guardrail is waiting for R31 linked-bends readiness")
		return
	if not _load_candidate():
		return
	if _off_requested or not enable_refinement:
		_publish_disabled_state()
		_built = true
		return
	if not bool(_forest_refinement.get_meta("saisies_s03_right_forest_refinement_ready", false)):
		_retry("S04 bend guardrail is waiting for the R24 baked-triangle sampler")
		return
	if not _validate_route_span():
		_retry("S04 bend guardrail route span failed the 3D side/direction check")
		return
	_prepare_local_ground_cache()
	if not _build_candidate():
		_retry("S04 bend guardrail could not build its finite candidate")
		return
	_built = true
	_update_visibility_gate()
	_publish_ready_state()

func _process(_delta: float) -> void:
	if not _built or _beam_instance == null or _post_instance == null:
		return
	_update_visibility_gate()

func _resolve_nodes() -> bool:
	_base = get_node_or_null(linked_bends_base_path)
	_world = get_node_or_null(world_path) as Node3D
	_forest_refinement = get_node_or_null(forest_refinement_path)
	_terrain_mesh_instance = _world.find_child("SaisiesGeoTerrain", true, false) as MeshInstance3D if _world != null else null
	_route = _world.get_node_or_null("Route") as Node if _world != null else null
	var rig := _world.get_node_or_null("CameraRig") as Node3D if _world != null else null
	_camera = rig.get_node_or_null("Camera3D") as Camera3D if rig != null else null
	return _base != null and _world != null and _route != null and _camera != null and _forest_refinement != null and _route.has_method("pos_at") and _route.has_method("left_at") and _route.has_method("road_width_at") and _route.has_method("ground_y")

func _base_ready() -> bool:
	if bool(_base.get_meta(BASE_READY_META, false)):
		return true
	var linked_controller := _base.find_child("S04LinkedBendsReview", true, false)
	return linked_controller != null and bool(linked_controller.get_meta(BASE_READY_META, false))

func _load_candidate() -> bool:
	if not _candidate_payload.is_empty():
		return true
	if not FileAccess.file_exists(candidate_path):
		push_error("S04 bend guardrail candidate is missing: %s" % candidate_path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(candidate_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("S04 bend guardrail candidate is not a JSON object")
		return false
	_candidate_payload = parsed as Dictionary
	if String(_candidate_payload.get("status", "")) != REVIEW_STATUS or String(_candidate_payload.get("visual_acceptance", "")) != "pending":
		push_error("S04 bend guardrail candidate must remain review-pending root selection")
		return false
	if bool(_candidate_payload.get("gps_calibrated", true)) or bool(_candidate_payload.get("formal_route_edit", true)):
		push_error("S04 bend guardrail candidate must remain non-GPS and route-only")
		return false
	_from_station_m = float(_candidate_payload.get("from_station_m", NAN))
	_to_station_m = float(_candidate_payload.get("to_station_m", NAN))
	_side = float(_candidate_payload.get("side_route_left_sign", NAN))
	_edge_offset_m = float(_candidate_payload.get("asphalt_edge_offset_m", NAN))
	_beam_top_m = float(_candidate_payload.get("beam_top_above_asphalt_edge_m", NAN))
	_beam_height_m = float(_candidate_payload.get("beam_profile_height_m", NAN))
	_beam_step_m = float(_candidate_payload.get("beam_sample_step_m", NAN))
	_post_spacing_m = float(_candidate_payload.get("post_spacing_m", NAN))
	for value in [_from_station_m, _to_station_m, _side, _edge_offset_m, _beam_top_m, _beam_height_m, _beam_step_m, _post_spacing_m]:
		if not is_finite(value):
			push_error("S04 bend guardrail candidate contains a non-finite geometry value")
			return false
	if _from_station_m >= _to_station_m or _side >= -0.5 or _edge_offset_m <= 0.0 or _beam_top_m <= _beam_height_m or _beam_step_m <= 0.0 or _post_spacing_m <= 0.0:
		push_error("S04 bend guardrail candidate geometry contract is invalid")
		return false
	return true

func _validate_route_span() -> bool:
	var previous := Vector3.INF
	var samples := [_from_station_m, (_from_station_m + _to_station_m) * 0.5, _to_station_m]
	for station_variant in samples:
		var station := float(station_variant)
		var center: Vector3 = _route.call("pos_at", station)
		var left := Vector3(_route.call("left_at", station)).normalized()
		var tangent := Vector3(_route.call("tangent_at", station)).normalized() if _route.has_method("tangent_at") else Vector3.ZERO
		var u := _right_edge_u(station)
		var edge := center + left * u
		if not center.is_finite() or not left.is_finite() or not tangent.is_finite() or not edge.is_finite() or left.length_squared() <= 0.000001 or tangent.length_squared() <= 0.000001:
			return false
		if previous != Vector3.INF and edge.distance_to(previous) <= 0.01:
			return false
		previous = edge
	set_meta("saisies_s04_bend_guardrail_route_direction_check", {"side_route_left_sign": _side, "right_side_is_negative_left": _side < 0.0, "sample_stations_m": samples, "passed": true})
	return true

func _build_candidate() -> bool:
	_roadside_helper = SaisiesGeoRoadside.new()
	# The legacy helper's profile oscillates in Y while X stays monotonic.  R32
	# uses the proper guardrail cross-section: Y descends through the height and
	# the depth/normal axis folds back twice, producing a vertical W beam.
	_beam_mesh = _make_r32_w_profile_mesh()
	_guard_material = _roadside_helper._make_guard_material()
	_roadside_helper.free()
	_roadside_helper = null
	_guard_material.albedo_color = Color(0.44, 0.49, 0.50, 1.0)
	_guard_material.metallic = 0.35
	_guard_material.roughness = 0.75
	_guard_material.metallic_specular = 0.30
	_post_material = _guard_material.duplicate() as StandardMaterial3D
	_guard_material.disable_receive_shadows = true
	_post_mesh = BoxMesh.new()
	_post_mesh.size = Vector3(POST_WIDTH_M, POST_TEMPLATE_HEIGHT_M, POST_DEPTH_M)
	if _beam_mesh == null or _post_mesh == null or _guard_material == null or _post_material == null:
		return false
	_beam_records.clear()
	_post_records.clear()
	_ground_records.clear()
	var span_sum := Vector3.ZERO
	var span_count := 0
	var station := _from_station_m
	while station < _to_station_m - 0.0001:
		var next_station := minf(station + _beam_step_m, _to_station_m)
		var beam := _make_beam_record(station, next_station)
		if beam.is_empty():
			return false
		_beam_records.append(beam)
		span_sum += beam["center0"]
		span_sum += beam["center1"]
		span_count += 2
		station = next_station
	station = _from_station_m
	while station < _to_station_m - 0.0001:
		var post := _make_post_record(station)
		if post.is_empty():
			return false
		_post_records.append(post)
		station += _post_spacing_m
	var terminal := _make_post_record(_to_station_m)
	if terminal.is_empty():
		return false
	_post_records.append(terminal)
	if span_count <= 0 or _beam_records.is_empty() or _post_records.is_empty():
		return false
	_span_center = span_sum / float(span_count)
	_spawn_multimeshes()
	return _beam_instance != null and _post_instance != null

func _make_beam_record(s0: float, s1: float) -> Dictionary:
	var center0 := _rail_point(s0)
	var center1 := _rail_point(s1)
	if not center0.is_finite() or not center1.is_finite():
		return {}
	var deck0_y := _asphalt_edge_point(s0).y
	var deck1_y := _asphalt_edge_point(s1).y
	center0.y += _beam_top_m - _beam_height_m * 0.5
	center1.y += _beam_top_m - _beam_height_m * 0.5
	var segment := center1 - center0
	var length := segment.length()
	if length <= 0.05 or not is_finite(length):
		return {}
	var direction := segment / length
	var basis := Basis.looking_at(direction, Vector3.UP)
	var transform := Transform3D(basis.scaled_local(Vector3(1.0, 1.0, length)), (center0 + center1) * 0.5)
	return {"s0": s0, "s1": s1, "side": _side, "u0": _right_edge_u(s0), "u1": _right_edge_u(s1), "deck_y0": deck0_y, "deck_y1": deck1_y, "center0": center0, "center1": center1, "center": (center0 + center1) * 0.5, "length_m": length, "direction": direction, "basis": basis, "transform": transform, "endpoint_alignment_3d": direction, "beam_top_above_asphalt_edge_m": _beam_top_m, "profile_height_m": _beam_height_m, "ground_source": "route.ground_y asphalt edge estimate", "ground_fallback_used": false}

func _make_post_record(station: float) -> Dictionary:
	var deck := _asphalt_edge_point(station)
	var rail := _rail_point(station)
	var left := Vector3(_route.call("left_at", station)).normalized()
	var rail_u := _right_edge_u(station)
	var post_u := rail_u + _side * 0.10
	var post_point := rail + left * (_side * 0.10)
	post_point.y = deck.y
	var xz := Vector2(post_point.x, post_point.z)
	var sample := _sample_visible_ground(xz)
	var fallback := sample.is_empty()
	var source := "R24 visible baked-triangle sampler"
	var sampled_point := Vector3(post_point.x, float(_route.call("ground_y", station, post_u)), post_point.z)
	var triangle_start := -1
	var triangle_surface := -1
	var barycentric := Vector3.ZERO
	var sample_normal := Vector3.UP
	if not fallback:
		var position: Vector3 = sample.get("position", Vector3.INF)
		if not position.is_finite():
			fallback = true
		else:
			sampled_point = position
			source = String(sample.get("source", source))
			triangle_start = int(sample.get("triangle_start", -1))
			triangle_surface = int(sample.get("surface", -1))
			barycentric = sample.get("barycentric", Vector3.ZERO)
			sample_normal = sample.get("normal", Vector3.UP)
	if fallback:
		source = "fallback_route_ground_not_acceptance"
	var base := sampled_point - Vector3.UP * POST_BURY_M
	var beam_top_y := deck.y + _beam_top_m - POST_BURY_M
	var height := maxf(beam_top_y - base.y, POST_MIN_HEIGHT_M)
	var center := base + Vector3.UP * (height * 0.5)
	var transform := Transform3D(Basis.IDENTITY.scaled_local(Vector3(1.0, height / POST_TEMPLATE_HEIGHT_M, 1.0)), center)
	var record := {"station_m": station, "side": _side, "u_m": post_u, "rail_u_m": rail_u, "rail_center": rail, "post_outward_offset_m": 0.10, "deck_edge": deck, "deck_ground_source": "route.ground_y asphalt edge estimate", "sampled_ground": sampled_point, "ground_y": sampled_point.y, "beam_top_y": beam_top_y, "post_top_below_beam_top_m": POST_BURY_M, "height_m": height, "base": base, "center": center, "basis": Basis.IDENTITY, "transform": transform, "upright_world_y": true, "ground_source": source, "ground_fallback_used": fallback, "ground_pass": not fallback and (source.contains("SaisiesGeoTerrain") or source.contains("visible overlay")), "triangle_start": triangle_start, "triangle_surface": triangle_surface, "barycentric": barycentric, "sample_normal": sample_normal}
	_ground_records.append({"station_m": station, "sampled_ground": sampled_point, "ground_source": source, "ground_fallback_used": fallback, "ground_pass": bool(record["ground_pass"]), "triangle_start": triangle_start, "triangle_surface": triangle_surface, "barycentric": barycentric})
	return record

func _deck_point(station: float) -> Vector3:
	return _asphalt_edge_point(station)

func _asphalt_edge_point(station: float) -> Vector3:
	var center := Vector3(_route.call("pos_at", station))
	var left := Vector3(_route.call("left_at", station)).normalized()
	var deck_u := _side * float(_route.call("road_width_at", station)) * 0.5
	var point := center + left * deck_u
	point.y = float(_route.call("ground_y", station, deck_u))
	return point

func _rail_point(station: float) -> Vector3:
	var center := Vector3(_route.call("pos_at", station))
	var left := Vector3(_route.call("left_at", station)).normalized()
	var point := center + left * _right_edge_u(station)
	point.y = _asphalt_edge_point(station).y
	return point

func _right_edge_u(station: float) -> float:
	return _side * (float(_route.call("road_width_at", station)) * 0.5 + _edge_offset_m)

func _sample_visible_ground(point: Vector2) -> Dictionary:
	var local := _sample_local_ground(point)
	if not local.is_empty():
		return local
	if _forest_refinement == null or not _forest_refinement.has_method("_sample_ground"):
		return {}
	var raw: Variant = _forest_refinement.call("_sample_ground", point)
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	return raw as Dictionary

func _prepare_local_ground_cache() -> bool:
	_local_ground_triangles.clear()
	_local_ground_bounds = Rect2()
	_local_ground_mesh_path = ""
	_local_ground_scan_triangle_count = 0
	_local_ground_cached_triangle_count = 0
	if _terrain_mesh_instance == null or _terrain_mesh_instance.mesh == null:
		return false
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	var station := _from_station_m
	while station <= _to_station_m + 0.001:
		var point := _rail_point(minf(station, _to_station_m))
		if point.is_finite():
			min_x = minf(min_x, point.x)
			max_x = maxf(max_x, point.x)
			min_z = minf(min_z, point.z)
			max_z = maxf(max_z, point.z)
		station += 5.0
	if not is_finite(min_x) or not is_finite(max_x) or not is_finite(min_z) or not is_finite(max_z):
		return false
	# The extra margin catches the full rail section and the small terrain
	# triangles immediately under its posts without caching the whole landscape.
	_local_ground_bounds = Rect2(min_x, min_z, max_x - min_x, max_z - min_z).grow(8.0)
	_local_ground_mesh_path = str(_terrain_mesh_instance.get_path())
	var mesh := _terrain_mesh_instance.mesh
	var mesh_transform := _terrain_mesh_instance.global_transform
	for surface_index in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var raw_vertices: Variant = arrays[Mesh.ARRAY_VERTEX]
		if not raw_vertices is PackedVector3Array:
			continue
		var vertices: PackedVector3Array = raw_vertices
		if vertices.size() < 3:
			continue
		var raw_indices: Variant = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX else null
		if raw_indices is PackedInt32Array and (raw_indices as PackedInt32Array).size() >= 3:
			var indices: PackedInt32Array = raw_indices
			for start in range(0, indices.size() - 2, 3):
				var ia := int(indices[start])
				var ib := int(indices[start + 1])
				var ic := int(indices[start + 2])
				if ia < 0 or ib < 0 or ic < 0 or ia >= vertices.size() or ib >= vertices.size() or ic >= vertices.size():
					continue
				var a := mesh_transform * vertices[ia]
				var b := mesh_transform * vertices[ib]
				var c := mesh_transform * vertices[ic]
				if not a.is_finite() or not b.is_finite() or not c.is_finite():
					continue
				_local_ground_scan_triangle_count += 1
				if _triangle_intersects_local_bounds(a, b, c):
					_local_ground_triangles.append({"a": a, "b": b, "c": c, "start": start, "surface": surface_index})
		else:
			for start in range(0, vertices.size() - 2, 3):
				var a := mesh_transform * vertices[start]
				var b := mesh_transform * vertices[start + 1]
				var c := mesh_transform * vertices[start + 2]
				if not a.is_finite() or not b.is_finite() or not c.is_finite():
					continue
				_local_ground_scan_triangle_count += 1
				if _triangle_intersects_local_bounds(a, b, c):
					_local_ground_triangles.append({"a": a, "b": b, "c": c, "start": start, "surface": surface_index})
	_local_ground_cached_triangle_count = _local_ground_triangles.size()
	return _local_ground_cached_triangle_count > 0

func _sample_local_ground(point: Vector2) -> Dictionary:
	if _local_ground_triangles.is_empty() or not _local_ground_bounds.grow(0.001).has_point(point):
		return {}
	var best_y := -INF
	var best: Dictionary = {}
	for triangle in _local_ground_triangles:
		var a: Vector3 = triangle["a"]
		var b: Vector3 = triangle["b"]
		var c: Vector3 = triangle["c"]
		var barycentric := _barycentric_xz_local(point, a, b, c)
		if barycentric.x < -0.0005 or barycentric.y < -0.0005 or barycentric.z < -0.0005:
			continue
		var height := a.y * barycentric.x + b.y * barycentric.y + c.y * barycentric.z
		if not is_finite(height) or height <= best_y:
			continue
		var normal := (b - a).cross(c - a)
		if normal.length_squared() > 0.000001:
			normal = normal.normalized()
			if normal.y < 0.0:
				normal = -normal
		else:
			normal = Vector3.UP
		best_y = height
		best = {
			"position": Vector3(point.x, height, point.y),
			"normal": normal,
			"source": "World/Landscape/SaisiesGeoTerrain local guardrail ROI surface%d mesh triangle" % int(triangle["surface"]),
			"triangle_start": int(triangle["start"]),
			"surface": int(triangle["surface"]),
			"barycentric": barycentric,
			"triangle_a": a,
			"triangle_b": b,
			"triangle_c": c,
		}
	return best

func _triangle_intersects_local_bounds(a: Vector3, b: Vector3, c: Vector3) -> bool:
	var min_x := minf(a.x, minf(b.x, c.x))
	var max_x := maxf(a.x, maxf(b.x, c.x))
	var min_z := minf(a.z, minf(b.z, c.z))
	var max_z := maxf(a.z, maxf(b.z, c.z))
	return max_x >= _local_ground_bounds.position.x and min_x <= _local_ground_bounds.end.x and max_z >= _local_ground_bounds.position.y and min_z <= _local_ground_bounds.end.y

func _barycentric_xz_local(point: Vector2, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 := Vector2(b.x - a.x, b.z - a.z)
	var v1 := Vector2(c.x - a.x, c.z - a.z)
	var v2 := point - Vector2(a.x, a.z)
	var denominator := v0.x * v1.y - v1.x * v0.y
	if absf(denominator) <= 0.000001:
		return Vector3(-INF, -INF, -INF)
	var weight_b := (v2.x * v1.y - v1.x * v2.y) / denominator
	var weight_c := (v0.x * v2.y - v2.x * v0.y) / denominator
	return Vector3(1.0 - weight_b - weight_c, weight_b, weight_c)

func _spawn_multimeshes() -> void:
	var beam_multimesh := MultiMesh.new()
	beam_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	beam_multimesh.mesh = _beam_mesh
	beam_multimesh.instance_count = _beam_records.size()
	for index in beam_multimesh.instance_count:
		beam_multimesh.set_instance_transform(index, _beam_records[index]["transform"])
	_beam_instance = MultiMeshInstance3D.new()
	_beam_instance.name = "S04BendGuardrailBeam"
	_beam_instance.multimesh = beam_multimesh
	_beam_instance.material_override = _guard_material
	_beam_instance.visibility_range_end = 0.0
	_beam_instance.set_meta("saisies_s04_bend_guardrail_records", _beam_records)
	add_child(_beam_instance)

	var post_multimesh := MultiMesh.new()
	post_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	post_multimesh.mesh = _post_mesh
	post_multimesh.instance_count = _post_records.size()
	for index in post_multimesh.instance_count:
		post_multimesh.set_instance_transform(index, _post_records[index]["transform"])
	_post_instance = MultiMeshInstance3D.new()
	_post_instance.name = "S04BendGuardrailPosts"
	_post_instance.multimesh = post_multimesh
	_post_instance.material_override = _post_material
	_post_instance.visibility_range_end = 0.0
	_post_instance.set_meta("saisies_s04_bend_guardrail_records", _post_records)
	add_child(_post_instance)

func _make_r32_w_profile_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_depth := 0.08 * 0.5
	var half_height := _beam_height_m * 0.5
	# Cross-section viewed across the beam: height is monotonic while the
	# normal/depth axis folds back through two corrugation waves.
	var profile := [
		Vector2(-half_depth, half_height),
		Vector2(half_depth, half_height * 0.5),
		Vector2(-half_depth, 0.0),
		Vector2(half_depth, -half_height * 0.5),
		Vector2(-half_depth, -half_height)
	]
	for index in range(profile.size() - 1):
		var a: Vector2 = profile[index]
		var b: Vector2 = profile[index + 1]
		var delta := b - a
		var normal := Vector2(-delta.y, delta.x).normalized()
		var offset := normal * 0.003 * 0.5
		var a_front := Vector3(a.x + offset.x, a.y + offset.y, -0.5)
		var b_front := Vector3(b.x + offset.x, b.y + offset.y, -0.5)
		var b_front_inner := Vector3(b.x - offset.x, b.y - offset.y, -0.5)
		var a_front_inner := Vector3(a.x - offset.x, a.y - offset.y, -0.5)
		var a_back := Vector3(a.x + offset.x, a.y + offset.y, 0.5)
		var b_back := Vector3(b.x + offset.x, b.y + offset.y, 0.5)
		var b_back_inner := Vector3(b.x - offset.x, b.y - offset.y, 0.5)
		var a_back_inner := Vector3(a.x - offset.x, a.y - offset.y, 0.5)
		_add_quad(surface, a_front, b_front, b_front_inner, a_front_inner)
		_add_quad(surface, b_back, a_back, a_back_inner, b_back_inner)
		_add_quad(surface, a_front, a_back, b_back, b_front)
		_add_quad(surface, b_front_inner, b_back_inner, a_back_inner, a_front_inner)
	surface.generate_normals()
	var mesh := surface.commit() as ArrayMesh
	if mesh != null:
		mesh.set_meta("saisies_s04_bend_guardrail_w_profile", true)
		mesh.set_meta("saisies_s04_bend_guardrail_profile_height_m", _beam_height_m)
		mesh.set_meta("saisies_s04_bend_guardrail_profile_depth_m", half_depth * 2.0)
	return mesh

func _add_quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	surface.add_vertex(a)
	surface.add_vertex(b)
	surface.add_vertex(c)
	surface.add_vertex(a)
	surface.add_vertex(c)
	surface.add_vertex(d)

func _update_visibility_gate() -> void:
	if _camera == null or _beam_instance == null or _post_instance == null:
		return
	var distance := _camera.global_position.distance_to(_span_center)
	_lod_active = enable_refinement and not _off_requested and distance <= visibility_gate_end_m
	_beam_instance.visible = _lod_active
	_post_instance.visible = _lod_active
	set_meta("saisies_s04_bend_guardrail_lod_active", _lod_active)
	set_meta("saisies_s04_bend_guardrail_camera_distance_m", distance)

func _publish_ready_state() -> void:
	_ready_published = true
	set_meta("saisies_s04_bend_guardrail_ready", true)
	set_meta("saisies_s04_bend_guardrail_enabled", true)
	set_meta("saisies_s04_bend_guardrail_status", REVIEW_STATUS)
	set_meta("saisies_s04_bend_guardrail_visual_acceptance", "pending")
	set_meta("saisies_s04_bend_guardrail_range_m", Vector2(_from_station_m, _to_station_m))
	set_meta("saisies_s04_bend_guardrail_side_route_left_sign", _side)
	set_meta("saisies_s04_bend_guardrail_edge_offset_m", _edge_offset_m)
	set_meta("saisies_s04_bend_guardrail_beam_top_above_asphalt_edge_m", _beam_top_m)
	set_meta("saisies_s04_bend_guardrail_beam_profile_height_m", _beam_height_m)
	set_meta("saisies_s04_bend_guardrail_beam_step_m", _beam_step_m)
	set_meta("saisies_s04_bend_guardrail_post_spacing_m", _post_spacing_m)
	set_meta("saisies_s04_bend_guardrail_beam_records", _beam_records)
	set_meta("saisies_s04_bend_guardrail_post_records", _post_records)
	set_meta("saisies_s04_bend_guardrail_ground_sample_records", _ground_records)
	set_meta("saisies_s04_bend_guardrail_ground_sample_count", _ground_records.size())
	set_meta("saisies_s04_bend_guardrail_ground_fallback_count", _count_ground_fallbacks())
	set_meta("saisies_s04_bend_guardrail_ground_pass", _count_ground_fallbacks() == 0 and _ground_records.size() == _post_records.size())
	set_meta("saisies_s04_bend_guardrail_local_ground_mesh_path", _local_ground_mesh_path)
	set_meta("saisies_s04_bend_guardrail_local_ground_bounds_xz", {"x": _local_ground_bounds.position.x, "z": _local_ground_bounds.position.y, "width": _local_ground_bounds.size.x, "depth": _local_ground_bounds.size.y})
	set_meta("saisies_s04_bend_guardrail_local_ground_mesh_scan_triangle_count", _local_ground_scan_triangle_count)
	set_meta("saisies_s04_bend_guardrail_local_ground_mesh_cached_triangle_count", _local_ground_cached_triangle_count)
	set_meta("saisies_s04_bend_guardrail_local_ground_sampler_source", "World/Landscape/SaisiesGeoTerrain transformed triangles in finite S04 rail ROI; R24 visible sampler only if local ROI misses")
	set_meta("saisies_s04_bend_guardrail_lod_gate_end_m", visibility_gate_end_m)
	set_meta("saisies_s04_bend_guardrail_lod_active", _lod_active)
	set_meta("saisies_s04_bend_guardrail_beam_count", _beam_records.size())
	set_meta("saisies_s04_bend_guardrail_post_count", _post_records.size())
	_publish_parent_ready(true)

func _publish_disabled_state() -> void:
	_ready_published = true
	set_meta("saisies_s04_bend_guardrail_ready", true)
	set_meta("saisies_s04_bend_guardrail_enabled", false)
	set_meta("saisies_s04_bend_guardrail_status", "disabled_baseline")
	set_meta("saisies_s04_bend_guardrail_visual_acceptance", "pending")
	set_meta("saisies_s04_bend_guardrail_range_m", Vector2(_from_station_m, _to_station_m))
	set_meta("saisies_s04_bend_guardrail_beam_count", 0)
	set_meta("saisies_s04_bend_guardrail_post_count", 0)
	set_meta("saisies_s04_bend_guardrail_ground_pass", false)
	_publish_parent_ready(false)

func _publish_parent_ready(enabled: bool) -> void:
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s04_bend_guardrail_review_ready", true)
		parent.set_meta("saisies_s04_bend_guardrail_review_enabled", enabled)

func _count_ground_fallbacks() -> int:
	var count := 0
	for record in _ground_records:
		if bool(record.get("ground_fallback_used", false)):
			count += 1
	return count

func _has_command_line_flag(flag: String) -> bool:
	for argument in OS.get_cmdline_user_args():
		if String(argument) == flag:
			return true
	return false

func _retry(message: String) -> void:
	_attempts += 1
	if _attempts < 240:
		call_deferred("_retry_next_frame")
		return
	set_meta("saisies_s04_bend_guardrail_ready", false)
	set_meta("saisies_s04_bend_guardrail_error", message)
	push_error(message)

func _retry_next_frame() -> void:
	await get_tree().process_frame
	_try_build()
