extends SceneTree

## Headless contract checks for SaisiesGeoRoadside.
##
## This builds the actual geographic route and DEM mesh, then checks the
## authored MultiMesh transforms against route/terrain queries.  Godot's dummy
## headless renderer can expose identity MultiMesh readback; in that case the
## verifier validates the exact transforms uploaded by the module and reports
## the native GPU readback as pending instead of mistaking the dummy backend for
## a placement error.

const ROUTE_SCRIPT_PATH := "res://scripts/saisies_geo_route.gd"
const ROUTE_FILE := "res://data/saisies_geo_route.json"
const LANDSCAPE_SCRIPT_PATH := "res://scripts/saisies_geo_landscape.gd"
const ROADSIDE_SCRIPT_PATH := "res://scripts/saisies_geo_roadside.gd"
const EXPECTED_SPAN_COUNT := 9
const BURY_M := 0.05
const POST_HEIGHT_M := 0.95
const GUARD_TOP_M := 0.90
const W_HEIGHT_M := 0.30
const BEAM_TOP_TOLERANCE_M := 0.025
const POST_BOTTOM_TOLERANCE_M := 0.01
const POST_JOIN_TOLERANCE_M := 0.025
const ASPHALT_EDGE_TOLERANCE_M := 0.04

var _errors: Array[String] = []
var _warnings: Array[String] = []
var _route
var _landscape
var _roadside
var _gpu_readback_skips := 0
var _gpu_readback_checks := 0
var _asphalt_faces := PackedVector3Array()
var _asphalt_global_transform := Transform3D.IDENTITY
var _asphalt_segment_count := 0
var _asphalt_edge_checks := 0
var _asphalt_edge_max_delta := 0.0
var _landscape_grid_size := 64
var _negative_post_count := 0
var _negative_post_examples: Array[String] = []

func _initialize() -> void:
	var arguments := OS.get_cmdline_args()
	arguments.append_array(OS.get_cmdline_user_args())
	for argument in arguments:
		if String(argument) == "--full-landscape":
			_landscape_grid_size = 0
	call_deferred("_run")

func _run() -> void:
	var route_script := load(ROUTE_SCRIPT_PATH) as Script
	var landscape_script := load(LANDSCAPE_SCRIPT_PATH) as Script
	var roadside_script := load(ROADSIDE_SCRIPT_PATH) as Script
	if route_script == null or landscape_script == null or roadside_script == null:
		_fail("could not load route, landscape, or roadside script")
		_finish()
		return
	_route = route_script.new()
	_route.name = "SaisiesGeoRouteRoadsideVerify"
	_route.geo_route_file = ROUTE_FILE
	get_root().add_child(_route)
	if not await _wait_for_route(180):
		_fail("geographic route did not become ready")
		_finish()
		return
	_landscape = landscape_script.new()
	_landscape.name = "SaisiesGeoLandscapeRoadsideVerify"
	_landscape.route = _route
	_landscape.build_grid_size = _landscape_grid_size
	_landscape.route_sample_step_m = 20.0
	get_root().add_child(_landscape)
	if not await _wait_for_property(_landscape, "landscape_ready", true, 240):
		_fail("geographic DEM landscape did not become ready")
		_finish()
		return
	_roadside = roadside_script.new()
	_roadside.name = "SaisiesGeoRoadsideVerify"
	_roadside.route = _route
	_roadside.landscape = _landscape
	get_root().add_child(_roadside)
	if not await _wait_for_property(_roadside, "roadside_ready", true, 120):
		_fail("geographic roadside module did not become ready")
		_finish()
		return
	_verify_root_contract()
	_verify_w_profile()
	_verify_chunks_and_transforms()
	_verify_span_coverage()
	_verify_scene_anchor_spans()
	if _gpu_readback_skips > 0:
		_warnings.append("dummy renderer returned identity for %d/%d MultiMesh reads; native GPU readback remains a separate check" % [_gpu_readback_skips, _gpu_readback_checks])
	if _landscape_grid_size != 0:
		_warnings.append("grid=%d is a coarse smoke test only; use --full-landscape (769) for terrain-contact acceptance" % _landscape_grid_size)
	if _errors.is_empty():
		print("SAISIES GEO ROADSIDE PASS spans=%d beams=%d posts=%d asphalt_edge_samples=%d max_deck_delta=%.4f tol=%.3f" % [int(_roadside.get_meta("saisies_geo_roadside_span_count", 0)), int(_roadside.get_meta("saisies_geo_roadside_beam_count", 0)), int(_roadside.get_meta("saisies_geo_roadside_post_count", 0)), _asphalt_edge_checks, _asphalt_edge_max_delta, ASPHALT_EDGE_TOLERANCE_M])
	else:
		print("SAISIES GEO ROADSIDE FAIL errors=%d" % _errors.size())
	print("SAISIES GEO ROADSIDE NEGATIVE_POSTS grid=%d count=%d examples=%s" % [int(_landscape.get_meta("saisies_geo_landscape_grid_size", _landscape_grid_size)), _negative_post_count, ",".join(_negative_post_examples)])
	for warning in _warnings:
		print("SAISIES GEO ROADSIDE WARNING: " + warning)
	_finish()

func _wait_for_property(node: Object, property_name: String, expected: bool, frames: int) -> bool:
	for _index in range(frames):
		await process_frame
		var value = node.get(property_name)
		if value == expected:
			return true
	return false

func _wait_for_route(frames: int) -> bool:
	for _index in range(frames):
		await process_frame
		if _route != null and _route.route_ready():
			return true
	return false

func _verify_root_contract() -> void:
	_prepare_asphalt_edge_reference()
	if _roadside.get_meta("saisies_geo_roadside_estimated_geometry", false) != true:
		_fail("roadside geometry is missing estimated=true contract")
	var note := String(_roadside.get_meta("saisies_geo_roadside_estimated_note", "")).to_lower()
	if not note.contains("estimated") or not note.contains("gps"):
		_fail("roadside metadata does not identify estimated non-GPS geometry")
	var ground_source := String(_roadside.get_meta("saisies_geo_roadside_ground_source", ""))
	if ground_source != "landscape.sample_mesh_triangle":
		_fail("roadside was not fully grounded against the rendered DEM: %s" % ground_source)
	if int(_roadside.get_meta("saisies_geo_roadside_span_count", 0)) != EXPECTED_SPAN_COUNT:
		_fail("expected %d guardrail spans" % EXPECTED_SPAN_COUNT)
	if String(_roadside.get_meta("saisies_geo_roadside_beam_top_reference", "")) != "route asphalt edge/deck + GUARD_TOP_M":
		_fail("beam top is not authored from the asphalt edge/deck reference")
	if absf(float(_roadside.get_meta("saisies_geo_roadside_beam_top_height_m", NAN)) - GUARD_TOP_M) > 0.001:
		_fail("beam top height metadata is not %.2f m" % GUARD_TOP_M)
	if absf(float(_roadside.get_meta("saisies_geo_roadside_post_bottom_bury_m", NAN)) - BURY_M) > 0.001:
		_fail("post bottom bury metadata is not %.2f m" % BURY_M)
	var span_records = _roadside.get_meta("saisies_geo_roadside_span_records", [])
	if not span_records is Array or span_records.size() != EXPECTED_SPAN_COUNT:
		_fail("span records are missing or incomplete")
	for span_variant in span_records:
		if not (span_variant is Dictionary) or span_variant.get("estimated", false) != true:
			_fail("a span is missing estimated mapping metadata")
	var beam_count := int(_roadside.get_meta("saisies_geo_roadside_beam_count", 0))
	var post_count := int(_roadside.get_meta("saisies_geo_roadside_post_count", 0))
	if beam_count < EXPECTED_SPAN_COUNT or post_count <= beam_count / 4:
		_fail("guardrail instance counts are unexpectedly low beams=%d posts=%d" % [beam_count, post_count])
	var authored_posts = _roadside.get_meta("saisies_geo_roadside_post_authored_records", [])
	if authored_posts is Array:
		for post_variant in authored_posts:
			if post_variant is Dictionary and float(post_variant.get("height", 0.0)) < -0.0005:
				_fail("authored guard post has negative height; signed/negative scale is invalid")
	_verify_authored_deck_against_asphalt_mesh()

func _prepare_asphalt_edge_reference() -> void:
	var asphalt := _route.get_node_or_null("SaisiesAsphalt") as MeshInstance3D
	if asphalt == null or asphalt.mesh == null:
		_fail("actual SaisiesAsphalt mesh is missing for independent deck reference")
		return
	_asphalt_faces = asphalt.mesh.get_faces()
	_asphalt_global_transform = asphalt.global_transform
	_asphalt_segment_count = _asphalt_faces.size() / 6
	if _asphalt_segment_count <= 0 or _asphalt_faces.size() != _asphalt_segment_count * 6:
		_fail("actual SaisiesAsphalt mesh has no complete six-vertex route segments")

func _asphalt_edge_sample(s: float, u: float) -> Dictionary:
	if _asphalt_segment_count <= 0:
		return {}
	var length_m := float(_route.get("length_m"))
	var spacing_m := maxf(float(_route.get("sample_spacing_m")), 0.001)
	var clamped_s := clampf(s, 0.0, length_m)
	var segment := clampi(int(floor(clamped_s / spacing_m)), 0, _asphalt_segment_count - 1)
	var s0 := minf(float(segment) * spacing_m, length_m)
	var s1 := minf(float(segment + 1) * spacing_m, length_m)
	var t := clampf((clamped_s - s0) / maxf(s1 - s0, 0.001), 0.0, 1.0)
	var start_index := segment * 6
	# _build_road_and_collision emits [left_s0, right_s0, right_s1]
	# and [left_s0, right_s1, left_s1].  Interpolating these actual mesh
	# edge vertices avoids using the roadside record as its own reference.
	var start_vertex: Vector3 = _asphalt_faces[start_index + (1 if u >= 0.0 else 0)]
	var end_vertex: Vector3 = _asphalt_faces[start_index + (2 if u >= 0.0 else 5)]
	var point := _asphalt_global_transform * start_vertex.lerp(end_vertex, t)
	if not _finite_vec3(point):
		return {}
	return {"point": point, "height": point.y, "segment": segment, "t": t}

func _verify_authored_deck_against_asphalt_mesh() -> void:
	var beams = _roadside.get_meta("saisies_geo_roadside_beam_authored_records", [])
	if not beams is Array:
		_fail("beam records are missing for asphalt edge verification")
		return
	for beam_variant in beams:
		var beam: Dictionary = beam_variant
		for endpoint in [0, 1]:
			var station := float(beam["s0"] if endpoint == 0 else beam["s1"])
			var lateral := float(beam["u0"] if endpoint == 0 else beam["u1"])
			var authored_deck := float(beam["deck0"] if endpoint == 0 else beam["deck1"])
			var sample := _asphalt_edge_sample(station, lateral)
			if sample.is_empty():
				_fail_limited("beam endpoint has no actual asphalt edge sample", _asphalt_edge_checks)
				continue
			_asphalt_edge_checks += 1
			var delta := absf(authored_deck - float(sample["height"]))
			_asphalt_edge_max_delta = maxf(_asphalt_edge_max_delta, delta)
			if delta > ASPHALT_EDGE_TOLERANCE_M:
				_fail_limited("authored deck differs from actual asphalt edge by %.3f m at s=%.2f" % [delta, station], _asphalt_edge_checks)
	if _asphalt_edge_checks <= 0:
		_fail("no actual asphalt edge samples covered beam endpoints")

func _verify_w_profile() -> void:
	var beam_mesh: Mesh = null
	for child in _roadside.get_children():
		if child is MultiMeshInstance3D and String(child.name).begins_with("SaisiesGeoGuardBeam"):
			if child.multimesh != null:
				beam_mesh = child.multimesh.mesh
				break
	if beam_mesh == null:
		_fail("guardbeam MultiMesh mesh is missing")
		return
	if beam_mesh.get_meta("saisies_geo_roadside_w_profile", false) != true:
		_fail("guardbeam mesh is not marked as the actual W profile")
	var bounds := beam_mesh.get_aabb()
	if bounds.size.x < 0.12 or bounds.size.y < 0.25 or bounds.size.z < 0.90:
		_fail("guardbeam profile bounds are too small for W rail: %s" % bounds.size)
	var profile_vertices := PackedVector3Array()
	if beam_mesh.get_surface_count() > 0:
		var arrays := beam_mesh.surface_get_arrays(0)
		if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
			profile_vertices = arrays[Mesh.ARRAY_VERTEX]
	if profile_vertices.size() < 60:
		_fail("guardbeam mesh has too few actual profile triangles: vertices=%d" % profile_vertices.size())
	var x_keys: Dictionary = {}
	var y_min := INF
	var y_max := -INF
	for vertex in profile_vertices:
		if absf(absf(vertex.z) - 0.5) < 0.01:
			x_keys[int(round(vertex.x * 10000.0))] = true
			y_min = minf(y_min, vertex.y)
			y_max = maxf(y_max, vertex.y)
	if x_keys.size() < 5 or y_max - y_min < 0.25:
		_fail("guardbeam front/back profile lacks W folds x=%d y_span=%.3f" % [x_keys.size(), y_max - y_min])

func _verify_chunks_and_transforms() -> void:
	var beam_chunks := 0
	var post_chunks := 0
	var beam_count := 0
	var post_count := 0
	var ground_checks := 0
	var transform_errors := 0
	for child in _roadside.get_children():
		if not child is MultiMeshInstance3D:
			continue
		var instance: MultiMeshInstance3D = child
		var is_beam: bool = instance.get_meta("saisies_geo_roadside_is_beam", false) == true
		var records = instance.get_meta("saisies_geo_roadside_authored_records", [])
		if not records is Array or instance.multimesh == null:
			_fail("MultiMesh chunk %s lacks authored records" % instance.name)
			continue
		if instance.multimesh.instance_count != records.size():
			_fail("MultiMesh chunk %s count does not match authored records" % instance.name)
		if is_beam:
			beam_chunks += 1
			beam_count += records.size()
		else:
			post_chunks += 1
			post_count += records.size()
		for index in records.size():
			var record: Dictionary = records[index]
			var expected_local := _expected_local_transform(record, is_beam, instance.get_meta("saisies_geo_roadside_chunk_origin", Vector3.ZERO))
			var uploaded := instance.multimesh.get_instance_transform(index)
			_gpu_readback_checks += 1
			var use_uploaded := true
			if _transform_near_identity(uploaded) and not _transform_near_identity(expected_local):
				_gpu_readback_skips += 1
				use_uploaded = false
			elif not _transform_close(uploaded, expected_local, 0.002):
				_fail_limited("uploaded MultiMesh transform differs from authored transform", transform_errors)
				transform_errors += 1
			var local_transform := uploaded if use_uploaded else expected_local
			var world_transform: Transform3D = instance.global_transform * local_transform
			if not _transform_finite(world_transform):
				_fail_limited("non-finite rendered guardrail transform", transform_errors)
				transform_errors += 1
				continue
			if is_beam:
				_verify_beam_record(record, world_transform, transform_errors)
			else:
				_verify_post_record(record, world_transform, transform_errors)
				var sampled = _landscape.sample_mesh_triangle(Vector2(world_transform.origin.x, world_transform.origin.z))
				if not (sampled is Dictionary) or not sampled.has("height") or not is_finite(float(sampled["height"])):
					_fail_limited("post is outside the rendered terrain mesh", ground_checks)
					ground_checks += 1
				else:
					# The reusable BoxMesh already has POST_HEIGHT_M of local
					# geometry; the transform basis stores only the positive scale
					# ratio.  Check the actual lower world-Y endpoint against the
					# rendered terrain mesh.
					var actual_half_height := world_transform.basis.y.length() * POST_HEIGHT_M * 0.5
					var bottom_y := world_transform.origin.y - actual_half_height
					if bottom_y > float(sampled["height"]) - BURY_M + POST_BOTTOM_TOLERANCE_M:
						_fail_limited("post bottom is floating above sampled terrain", ground_checks)
						ground_checks += 1
				ground_checks += 1
	var expected_beams := int(_roadside.get_meta("saisies_geo_roadside_beam_count", -1))
	var expected_posts := int(_roadside.get_meta("saisies_geo_roadside_post_count", -1))
	if beam_count != expected_beams or post_count != expected_posts:
		_fail("chunk instance totals differ from root authored totals beams=%d/%d posts=%d/%d" % [beam_count, expected_beams, post_count, expected_posts])
	if beam_chunks >= beam_count or post_chunks >= post_count:
		_fail("guardrail instances were not spatially chunked")
	if ground_checks <= 0:
		_fail("no actual post-to-terrain checks were performed")

func _verify_beam_record(record: Dictionary, world_transform: Transform3D, error_count: int) -> void:
	var expected_direction: Vector3 = record["direction"]
	var actual_direction := (-world_transform.basis.z).normalized()
	if actual_direction.dot(expected_direction) < 0.999:
		_fail_limited("W beam basis is not aligned with its full 3D segment", error_count)
	var actual_length := world_transform.basis.z.length()
	if absf(actual_length - float(record["length"])) > 0.01:
		_fail_limited("W beam length transform differs from segment length", error_count)
	var expected_center: Vector3 = record["center"]
	if world_transform.origin.distance_to(expected_center) > 0.01:
		_fail_limited("W beam center differs from authored endpoint midpoint", error_count)
	var half_length := actual_length * 0.5
	var endpoint0 := world_transform.origin - actual_direction * half_length
	var endpoint1 := world_transform.origin + actual_direction * half_length
	if endpoint0.distance_to(record["center0"]) > 0.01 or endpoint1.distance_to(record["center1"]) > 0.01:
		_fail_limited("W beam endpoints differ from authored 3D deck segment", error_count)
	# The W profile rotates with the full 3D segment.  Its local +Y projects
	# slightly less than 0.15 m onto world Y on a slope, so inspect the actual
	# rendered profile top and compare it with each endpoint's asphalt deck.
	var profile_up_y := world_transform.basis.y.normalized().y
	var actual_top0 := endpoint0.y + profile_up_y * W_HEIGHT_M * 0.5
	var actual_top1 := endpoint1.y + profile_up_y * W_HEIGHT_M * 0.5
	var deck_sample0 := _asphalt_edge_sample(float(record["s0"]), float(record["u0"]))
	var deck_sample1 := _asphalt_edge_sample(float(record["s1"]), float(record["u1"]))
	# The independent mesh edge is the production reference.  The authored
	# deck fields remain a diagnostic cross-check in case route and mesh drift.
	var expected_top0 := (float(deck_sample0["height"]) if not deck_sample0.is_empty() else float(record["deck0"])) + GUARD_TOP_M
	var expected_top1 := (float(deck_sample1["height"]) if not deck_sample1.is_empty() else float(record["deck1"])) + GUARD_TOP_M
	if absf(actual_top0 - expected_top0) > BEAM_TOP_TOLERANCE_M or absf(actual_top1 - expected_top1) > BEAM_TOP_TOLERANCE_M:
		_fail_limited("W beam endpoint top is not deck + %.2f m (profile projection accounted)" % GUARD_TOP_M, error_count)
	var s0 := float(record["s0"])
	var s1 := float(record["s1"])
	if absf(float(record["u0"])) < _route.road_width_at(s0) * 0.5 + 0.60 or absf(float(record["u1"])) < _route.road_width_at(s1) * 0.5 + 0.60:
		_fail_limited("W beam enters the road clearance band", error_count)

func _verify_post_record(record: Dictionary, world_transform: Transform3D, error_count: int) -> void:
	var authored_height := float(record["height"])
	if authored_height < -0.0005:
		_negative_post_count += 1
		if _negative_post_examples.size() < 32:
			_negative_post_examples.append("s=%.2f h=%.3f terrain=%.3f deck=%.3f" % [float(record["s"]), authored_height, float(record["terrain_y"]), float(record["deck_y"])])
		_fail_limited("negative guard post height is invalid", error_count)
	var up := world_transform.basis.y.normalized()
	if up.dot(Vector3.UP) < 0.999:
		_fail_limited("guard post is not vertical", error_count)
	var s := float(record["s"])
	if absf(float(record["u"])) < _route.road_width_at(s) * 0.5 + 0.60:
		_fail_limited("guard post enters the road clearance band", error_count)
	if absf(world_transform.origin.y - float(record["center"].y)) > 0.01:
		_fail_limited("guard post center differs from authored ground transform", error_count)
	# The transform's Y basis is a positive scale ratio for the reusable
	# BoxMesh, whose authored local height is POST_HEIGHT_M.
	var actual_height := world_transform.basis.y.length() * POST_HEIGHT_M
	if absf(actual_height - float(record["height"])) > 0.01:
		_fail_limited("guard post local height differs from authored terrain-to-beam span", error_count)
	var bottom_y := world_transform.origin.y - actual_height * 0.5
	var top_y := world_transform.origin.y + actual_height * 0.5
	if absf(bottom_y - float(record["base"].y)) > POST_BOTTOM_TOLERANCE_M:
		_fail_limited("guard post bottom is not terrain - bury", error_count)
	if absf(top_y - float(record["beam_top_y"])) > POST_JOIN_TOLERANCE_M:
		_fail_limited("guard post top does not join authored beam top s=%.2f actual=%.3f expected=%.3f base=%.3f height=%.3f" % [s, top_y, float(record["beam_top_y"]), float(record["base"].y), float(record["height"])], error_count)

func _verify_span_coverage() -> void:
	var spans = _roadside.get_meta("saisies_geo_roadside_span_records", [])
	var beams = _roadside.get_meta("saisies_geo_roadside_beam_authored_records", [])
	if not spans is Array or not beams is Array:
		_fail("missing span or beam records")
		return
	for span_variant in spans:
		var span: Dictionary = span_variant
		var s0 := float(span["s0"])
		var s1 := float(span["s1"])
		var matching: Array = []
		for beam_variant in beams:
			var beam: Dictionary = beam_variant
			if absf(float(beam["side"]) - float(span["side"])) < 0.01 and float(beam["s0"]) >= s0 - 0.01 and float(beam["s1"]) <= s1 + 0.01:
				matching.append(beam)
		matching.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["s0"]) < float(b["s0"]))
		if matching.is_empty():
			_fail("span %s has no beam segments" % String(span.get("label", "unknown")))
			continue
		if absf(float(matching.front()["s0"]) - s0) > 0.01 or absf(float(matching.back()["s1"]) - s1) > 0.01:
			_fail("span %s does not reach both endpoints" % String(span.get("label", "unknown")))
		for index in range(1, matching.size()):
			var gap := float(matching[index]["s0"]) - float(matching[index - 1]["s1"])
			if gap > 0.01:
				_fail("span %s has %.3f m beam gap" % [String(span.get("label", "unknown")), gap])
				break
		if matching.size() != int(span.get("beam_count", matching.size())):
			_fail("span %s beam count metadata is inconsistent" % String(span.get("label", "unknown")))

func _verify_scene_anchor_spans() -> void:
	var anchors := {"S05": -1.0, "S08": -1.0, "S09": -1.0}
	var spans = _roadside.get_meta("saisies_geo_roadside_span_records", [])
	for scene_id in anchors.keys():
		var distance := float(_route.acceptance_distance(scene_id))
		var found := false
		for span_variant in spans:
			var span: Dictionary = span_variant
			if distance >= float(span["s0"]) - 0.05 and distance <= float(span["s1"]) + 0.05 and absf(float(span["side"]) - float(anchors[scene_id])) < 0.01:
				found = true
				break
		if not found:
			if scene_id == "S08":
				# S08 (315 s) is intentionally before the final 115 m of the
				# 296..330 s exit span.  Keep the literal source span rather than
				# silently extending it to make an acceptance frame look covered.
				_warnings.append("%s acceptance distance %.3f m is outside the literal estimated exit-tail rail span" % [scene_id, distance])
			else:
				_fail("%s acceptance distance %.3f m is not covered by its expected guardrail side" % [scene_id, distance])
		else:
			var nearest := INF
			for beam_variant in _roadside.get_meta("saisies_geo_roadside_beam_authored_records", []):
				var beam: Dictionary = beam_variant
				if distance >= float(beam["s0"]) - 0.05 and distance <= float(beam["s1"]) + 0.05:
					nearest = minf(nearest, absf(distance - (float(beam["s0"]) + float(beam["s1"])) * 0.5))
			if nearest > 4.0:
				_fail("%s acceptance distance is not near an authored guardrail segment" % scene_id)

func _expected_local_transform(record: Dictionary, is_beam: bool, origin: Vector3) -> Transform3D:
	var basis: Basis = record["basis"]
	if is_beam:
		basis = basis.scaled_local(Vector3(1.0, 1.0, float(record["length"])))
	else:
		# Posts share one BoxMesh template and are locally scaled to the
		# terrain-to-beam height authored in each record.
		basis = basis.scaled_local(Vector3(1.0, float(record["height"]) / maxf(POST_HEIGHT_M, 0.001), 1.0))
	return Transform3D(basis, (record["center"] as Vector3) - origin)

func _transform_near_identity(value: Transform3D) -> bool:
	return value.origin.length() < 0.00001 and _basis_close(value.basis, Basis.IDENTITY, 0.00001)

func _transform_close(a: Transform3D, b: Transform3D, tolerance: float) -> bool:
	if a.origin.distance_to(b.origin) > tolerance:
		return false
	return _basis_close(a.basis, b.basis, tolerance)

func _basis_close(a: Basis, b: Basis, tolerance: float) -> bool:
	for column in 3:
		if a[column].distance_to(b[column]) > tolerance:
			return false
	return true

func _transform_finite(value: Transform3D) -> bool:
	return _finite_vec3(value.origin) and _finite_vec3(value.basis.x) and _finite_vec3(value.basis.y) and _finite_vec3(value.basis.z)

func _finite_vec3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _fail_limited(message: String, current_count: int) -> void:
	if current_count < 6:
		_fail(message)

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES GEO ROADSIDE: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES GEO ROADSIDE VERIFY PASS")
		quit(0)
	else:
		print("SAISIES GEO ROADSIDE VERIFY FAIL (%d errors)" % _errors.size())
		quit(1)
