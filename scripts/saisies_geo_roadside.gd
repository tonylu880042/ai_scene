class_name SaisiesGeoRoadside
extends Node3D

## Estimated roadside guardrails for the independent geographic route.
##
## The source spans are legacy video-time observations mapped through the
## geographic route's estimated checkpoint mapping.  They are useful scenery
## anchors, not calibrated GPS or a claim that the source footage and OSM route
## share exact geometry.  Every rail endpoint is sampled against the rendered
## DEM when a SaisiesGeoLandscape is supplied.

@export var route_path: NodePath
@export var landscape_path: NodePath
@export var chunk_length_m := 300.0
@export var segment_length_m := 3.0
@export var visibility_range_m := 1200.0

const EDGE_OFFSET_M := 0.65
const GUARD_TOP_M := 0.90
const GUARD_BURY_M := 0.05
const W_HEIGHT_M := 0.30
const W_WIDTH_M := 0.18
const W_THICKNESS_M := 0.003
const POST_WIDTH_M := 0.10
const POST_DEPTH_M := 0.10
## BoxMesh uses this as its template height; each post is locally scaled to
## reach the actual beam top after its terrain-embedded base is authored.
const POST_HEIGHT_M := 0.95
const POST_MIN_HEIGHT_M := 0.05
const POST_SPACING_M := 3.0
## The beam center is measured from its buried deck base.  Adding
## GUARD_BURY_M keeps the visible rail top at asphalt edge/deck +
## GUARD_TOP_M after the base sinks.
const BEAM_CENTER_HEIGHT_M := GUARD_TOP_M - W_HEIGHT_M * 0.5 + GUARD_BURY_M

## Each side is expressed in route-left coordinates: right is -1, left is +1.
## The video-time mapping is explicitly estimated in the generated metadata.
const SPAN_SPECS := [
	{"from_time_s": 145.0, "to_time_s": 205.0, "side": -1.0, "label": "right_145_205"},
	{"from_time_s": 296.0, "to_time_s": 330.0, "side": -1.0, "tail_m": 115.0, "label": "right_exit_last_115m"},
	{"from_time_s": 330.0, "to_time_s": 360.0, "side": -1.0, "label": "right_330_360"},
	{"from_time_s": 360.0, "to_time_s": 390.0, "side": 1.0, "label": "left_360_390"},
	{"from_time_s": 392.0, "to_time_s": 431.0, "side": 1.0, "label": "left_392_431"},
	{"from_time_s": 660.0, "to_time_s": 730.0, "side": -1.0, "label": "right_660_730"},
	{"from_time_s": 748.0, "to_time_s": 804.0, "side": 1.0, "label": "left_748_804"},
	{"from_time_s": 824.0, "to_time_s": 861.0, "side": -1.0, "label": "right_824_861"},
	{"from_time_s": 905.0, "to_time_s": 916.0, "side": 1.0, "label": "left_905_916"}
]

var route: SaisiesRoute
var landscape: Node
var roadside_ready := false
var _build_attempts := 0
var _beam_mesh: ArrayMesh
var _post_mesh: BoxMesh

func _ready() -> void:
	call_deferred("_try_build")

func _try_build() -> void:
	if roadside_ready:
		return
	_resolve_route()
	_resolve_landscape()
	if route == null or not route.route_ready():
		_build_attempts += 1
		if _build_attempts < 24:
			call_deferred("_try_build")
		else:
			push_error("SaisiesGeoRoadside requires a ready geographic route")
		return
	# A scene with a landscape should wait for its mesh.  Falling back to the
	# route edge remains valid for a staging scene that intentionally omits DEM.
	if _landscape_has_sampler() and _landscape_has_ready_property() and not bool(landscape.get("landscape_ready")):
		_build_attempts += 1
		if _build_attempts < 48:
			call_deferred("_try_build")
			return
	_build()

func _resolve_route() -> void:
	if route != null:
		return
	if route_path != NodePath():
		route = get_node_or_null(route_path) as SaisiesRoute
	if route == null and get_parent() != null:
		route = get_parent().get_node_or_null("Route") as SaisiesRoute
	if route == null and get_parent() != null:
		route = get_parent().find_child("SaisiesGeoRoute", true, false) as SaisiesRoute

func _resolve_landscape() -> void:
	if landscape != null:
		return
	if landscape_path != NodePath():
		landscape = get_node_or_null(landscape_path)
	if landscape == null and get_parent() != null:
		landscape = get_parent().find_child("SaisiesGeoLandscape", true, false)

func _landscape_has_sampler() -> bool:
	return landscape != null and landscape.has_method("sample_mesh_triangle")

func _landscape_has_ready_property() -> bool:
	if landscape == null:
		return false
	for item in landscape.get_property_list():
		if String(item.get("name", "")) == "landscape_ready":
			return true
	return false

func _build() -> void:
	if roadside_ready or route == null:
		return
	_beam_mesh = _make_w_profile_mesh()
	_post_mesh = BoxMesh.new()
	_post_mesh.size = Vector3(POST_WIDTH_M, POST_HEIGHT_M, POST_DEPTH_M)
	var rail_material := _make_guard_material()
	var beam_items_by_chunk: Dictionary = {}
	var post_items_by_chunk: Dictionary = {}
	var span_records: Array = []
	var all_beam_records: Array = []
	var all_post_records: Array = []
	var ground_sources: Dictionary = {}

	for spec_variant in SPAN_SPECS:
		var spec: Dictionary = spec_variant
		var from_time := float(spec.get("from_time_s", 0.0))
		var to_time := float(spec.get("to_time_s", from_time))
		var s0 := clampf(route.distance_for_video_seconds(from_time), 0.0, route.length_m)
		var s1 := clampf(route.distance_for_video_seconds(to_time), 0.0, route.length_m)
		if s1 < s0:
			var swap_s := s0
			s0 = s1
			s1 = swap_s
		var tail_m := maxf(float(spec.get("tail_m", 0.0)), 0.0)
		if tail_m > 0.0:
			s0 = maxf(s0, s1 - tail_m)
		if s1 <= s0 + 0.01:
			push_warning("SaisiesGeoRoadside skipped zero-length span %s" % String(spec.get("label", "unnamed")))
			continue
		var side := -1.0 if float(spec.get("side", -1.0)) < 0.0 else 1.0
		var span_beams: Array = []
		var span_posts: Array = []
		var s := s0
		while s < s1 - 0.0001:
			var next_s := minf(s + maxf(segment_length_m, 0.25), s1)
			var item := _make_segment_record(s, next_s, side, ground_sources)
			if item.is_empty():
				break
			_add_chunk_item(beam_items_by_chunk, _chunk_index(s), item)
			span_beams.append(item)
			all_beam_records.append(item)
			var post := _make_post_record(s, side, ground_sources)
			_add_chunk_item(post_items_by_chunk, _chunk_index(s), post)
			span_posts.append(post)
			all_post_records.append(post)
			s = next_s
		# Add exactly one terminal post; segment starts already cover the other
		# endpoints and avoid thousands of duplicate posts at joins.
		var terminal := _make_post_record(s1, side, ground_sources)
		_add_chunk_item(post_items_by_chunk, _chunk_index(s1), terminal)
		span_posts.append(terminal)
		all_post_records.append(terminal)
		span_records.append({
			"label": String(spec.get("label", "estimated_span")),
			"from_time_s": from_time,
			"to_time_s": to_time,
			"side": side,
			"s0": s0,
			"s1": s1,
			"tail_m": tail_m,
			"estimated": true,
			"beam_count": span_beams.size(),
			"post_count": span_posts.size()
		})

	_spawn_chunks(beam_items_by_chunk, _beam_mesh, rail_material, "SaisiesGeoGuardBeam", true)
	_spawn_chunks(post_items_by_chunk, _post_mesh, rail_material, "SaisiesGeoGuardPost", false)
	var ground_source := "route.deck_edge"
	if int(ground_sources.get("landscape.sample_mesh_triangle", 0)) > 0 and int(ground_sources.get("route.deck_edge", 0)) == 0:
		ground_source = "landscape.sample_mesh_triangle"
	elif int(ground_sources.get("landscape.sample_mesh_triangle", 0)) > 0:
		ground_source = "landscape.sample_mesh_triangle+route.deck_edge"
	set_meta("saisies_geo_roadside_ready", true)
	set_meta("saisies_geo_roadside_estimated_geometry", true)
	set_meta("saisies_geo_roadside_estimated_note", "Legacy video-time spans mapped through estimated route checkpoints; source-view guardrail geometry is not calibrated GPS.")
	set_meta("saisies_geo_roadside_ground_source", ground_source)
	set_meta("saisies_geo_roadside_span_records", span_records)
	set_meta("saisies_geo_roadside_beam_authored_records", all_beam_records)
	set_meta("saisies_geo_roadside_post_authored_records", all_post_records)
	set_meta("saisies_geo_roadside_beam_count", all_beam_records.size())
	set_meta("saisies_geo_roadside_post_count", all_post_records.size())
	set_meta("saisies_geo_roadside_span_count", span_records.size())
	set_meta("saisies_geo_roadside_segment_length_m", segment_length_m)
	set_meta("saisies_geo_roadside_post_spacing_m", POST_SPACING_M)
	set_meta("saisies_geo_roadside_beam_top_reference", "route asphalt edge/deck + GUARD_TOP_M")
	set_meta("saisies_geo_roadside_beam_top_height_m", GUARD_TOP_M)
	set_meta("saisies_geo_roadside_beam_top_tolerance_m", 0.025)
	set_meta("saisies_geo_roadside_post_bottom_bury_m", GUARD_BURY_M)
	set_meta("saisies_geo_roadside_w_profile", true)
	set_meta("saisies_geo_roadside_authored_transform_contract", "Records retain actual 3D transforms; native MultiMesh readback is a separate GPU check.")
	roadside_ready = true
	print("saisies geo roadside: spans=%d beams=%d posts=%d ground=%s" % [span_records.size(), all_beam_records.size(), all_post_records.size(), ground_source])

func _add_chunk_item(chunks: Dictionary, chunk_index: int, item: Dictionary) -> void:
	if not chunks.has(chunk_index):
		chunks[chunk_index] = []
	chunks[chunk_index].append(item)

func _chunk_index(s: float) -> int:
	return floori(clampf(s, 0.0, route.length_m) / maxf(chunk_length_m, 1.0))

func _u_at(s: float, side: float) -> float:
	return side * (route.road_width_at(s) * 0.5 + EDGE_OFFSET_M)

func _ground_sample(s: float, u: float, ground_sources: Dictionary) -> Dictionary:
	var center := route.pos_at(s)
	var local := center + route.left_at(s) * u
	# The roadside post stands on the rendered terrain at the rail offset, while
	# the beam's datum must remain the actual asphalt edge/deck.  Sampling
	# route.ground_y at u (outside the road) for both used the lowered clearance
	# terrain as the rail top reference on cut slopes.
	var deck_u := signf(u) * route.road_width_at(s) * 0.5
	var deck_y := route.ground_y(s, deck_u)
	var ground := route.ground_y(s, u)
	var source := "route.deck_edge"
	if _landscape_has_sampler():
		var sampled = landscape.call("sample_mesh_triangle", Vector2(local.x, local.z))
		if sampled is Dictionary and sampled.has("height") and is_finite(float(sampled["height"])):
			ground = float(sampled["height"])
			source = "landscape.sample_mesh_triangle"
	ground_sources[source] = int(ground_sources.get(source, 0)) + 1
	return {
		"point": Vector3(local.x, ground, local.z),
		"terrain_y": ground,
		"deck_y": deck_y,
		"deck_u": deck_u,
		"source": source
	}

func _make_segment_record(s0: float, s1: float, side: float, ground_sources: Dictionary) -> Dictionary:
	var u0 := _u_at(s0, side)
	var u1 := _u_at(s1, side)
	var sample0 := _ground_sample(s0, u0, ground_sources)
	var sample1 := _ground_sample(s1, u1, ground_sources)
	var point0: Vector3 = sample0["point"]
	var point1: Vector3 = sample1["point"]
	var base0 := Vector3(point0.x, float(sample0["deck_y"]) - GUARD_BURY_M, point0.z)
	var base1 := Vector3(point1.x, float(sample1["deck_y"]) - GUARD_BURY_M, point1.z)
	var center0 := base0 + Vector3.UP * BEAM_CENTER_HEIGHT_M
	var center1 := base1 + Vector3.UP * BEAM_CENTER_HEIGHT_M
	var segment := center1 - center0
	var length := segment.length()
	if length <= 0.05 or not _finite_vec3(center0) or not _finite_vec3(center1):
		return {}
	var direction := segment / length
	var basis := Basis.looking_at(direction, Vector3.UP)
	return {
		"s0": s0, "s1": s1, "side": side, "u0": u0, "u1": u1,
		"ground0": sample0["terrain_y"], "ground1": sample1["terrain_y"],
		"terrain0": sample0["terrain_y"], "terrain1": sample1["terrain_y"],
		"deck0": sample0["deck_y"], "deck1": sample1["deck_y"],
		"ground_source0": sample0["source"], "ground_source1": sample1["source"],
		"base0": base0, "base1": base1, "center0": center0, "center1": center1,
		"center": (center0 + center1) * 0.5, "length": length,
		"basis": basis, "direction": direction,
		"top_height_m": GUARD_TOP_M, "profile_height_m": W_HEIGHT_M,
		"profile_width_m": W_WIDTH_M, "estimated": true
	}

func _make_post_record(s: float, side: float, ground_sources: Dictionary) -> Dictionary:
	var u := _u_at(s, side)
	var sample := _ground_sample(s, u, ground_sources)
	var base: Vector3 = sample["point"] - Vector3.UP * GUARD_BURY_M
	var beam_top_y := float(sample["deck_y"]) + GUARD_TOP_M
	var height := maxf(beam_top_y - base.y, POST_MIN_HEIGHT_M)
	var center := base + Vector3.UP * (height * 0.5)
	return {
		"s": s, "side": side, "u": u, "ground_y": sample["terrain_y"],
		"terrain_y": sample["terrain_y"], "deck_y": sample["deck_y"],
		"beam_top_y": beam_top_y, "ground_source": sample["source"],
		"base": base, "center": center, "height": height,
		"basis": Basis.IDENTITY, "estimated": true
	}

func _spawn_chunks(chunks: Dictionary, mesh: Mesh, material: Material, prefix: String, is_beam: bool) -> void:
	for chunk_variant in chunks.keys():
		var chunk_index := int(chunk_variant)
		var items: Array = chunks[chunk_variant]
		if items.is_empty():
			continue
		var midpoint_s := minf((float(chunk_index) + 0.5) * maxf(chunk_length_m, 1.0), route.length_m)
		var origin := route.pos_at(midpoint_s)
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = items.size()
		var authored_positions := PackedVector3Array()
		var authored_s := PackedFloat32Array()
		for index in multimesh.instance_count:
			var item: Dictionary = items[index]
			var item_basis: Basis = item["basis"]
			var item_origin: Vector3 = item["center"]
			var transform_basis := item_basis
			if is_beam:
				# Scale the local rail axis.  Basis.scaled() applies a world-axis
				# scale and distorts a turned/slope-following basis; scaled_local()
				# preserves the full 3D segment direction.
				transform_basis = item_basis.scaled_local(Vector3(1.0, 1.0, float(item["length"])))
			else:
				# The BoxMesh is a reusable POST_HEIGHT_M template.  Preserve its
				# vertical basis while scaling local Y to the terrain-to-beam join.
				transform_basis = item_basis.scaled_local(Vector3(1.0, float(item["height"]) / maxf(POST_HEIGHT_M, 0.001), 1.0))
			var local_transform := Transform3D(transform_basis, item_origin - origin)
			multimesh.set_instance_transform(index, local_transform)
			authored_positions.append(item_origin)
			authored_s.append(float(item.get("s", item.get("s0", 0.0))))
		var instance := MultiMeshInstance3D.new()
		instance.name = "%s_%03d" % [prefix, chunk_index]
		instance.multimesh = multimesh
		instance.position = origin
		instance.visibility_range_end = visibility_range_m
		instance.material_override = material
		instance.set_meta("saisies_geo_roadside_chunk_index", chunk_index)
		instance.set_meta("saisies_geo_roadside_is_beam", is_beam)
		instance.set_meta("saisies_geo_roadside_authored_records", items)
		instance.set_meta("saisies_geo_roadside_authored_positions", authored_positions)
		instance.set_meta("saisies_geo_roadside_authored_s", authored_s)
		instance.set_meta("saisies_geo_roadside_chunk_origin", origin)
		add_child(instance)

func _make_guard_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.38, 0.42, 0.44, 1.0)
	material.metallic = 0.72
	material.roughness = 0.30
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _make_w_profile_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_width := W_WIDTH_M * 0.5
	var half_height := W_HEIGHT_M * 0.5
	var profile := [
		Vector2(-half_width, half_height),
		Vector2(-half_width * 0.5, -half_height),
		Vector2(0.0, half_height),
		Vector2(half_width * 0.5, -half_height),
		Vector2(half_width, half_height)
	]
	for index in range(profile.size() - 1):
		var a: Vector2 = profile[index]
		var b: Vector2 = profile[index + 1]
		var delta := b - a
		var normal := Vector2(-delta.y, delta.x).normalized()
		var offset := normal * (W_THICKNESS_M * 0.5)
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
		mesh.set_meta("saisies_geo_roadside_w_profile", true)
		mesh.set_meta("saisies_geo_roadside_w_profile_width_m", W_WIDTH_M)
		mesh.set_meta("saisies_geo_roadside_w_profile_height_m", W_HEIGHT_M)
	return mesh

func _add_quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	surface.add_vertex(a)
	surface.add_vertex(b)
	surface.add_vertex(c)
	surface.add_vertex(a)
	surface.add_vertex(c)
	surface.add_vertex(d)

func _finite_vec3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
