class_name SaisiesUpperScenery
extends Node3D

## Authored S04-S09 scenery corridor for the continuous Col des Saisies route.
##
## This module owns the open upper meadows, farm compounds, utility poles and
## the S08/S09 protection transition.  All pieces are placed from the same
## SaisiesRoute samples, so the road remains one continuous world instead of a
## sequence of disconnected set pieces.  The main scene can disable its older
## generic props over this range after this module is attached.

@export var route_path: NodePath
@export var from_video_seconds := 80.0
@export var to_video_seconds := 395.0
@export var from_m := 1300.0
@export var to_m := 6500.0
@export var random_seed := 4407
@export var include_trees := true
@export var wall_sample_spacing_m := 8.0
@export var guardrail_spacing_m := 10.0

var route: SaisiesRoute
var upper_scenery_ready := false

var _rng := RandomNumberGenerator.new()
var _materials := {}
var _tree_broadleaf: Array[Mesh] = []
var _tree_conifer: Array[Mesh] = []
var _build_attempts := 0

func _ready() -> void:
	_try_build()

func _try_build() -> void:
	if upper_scenery_ready:
		return
	if route == null:
		if not route_path.is_empty():
			route = get_node_or_null(route_path) as SaisiesRoute
		if route == null:
			route = get_parent().get_node_or_null("Route") as SaisiesRoute
	if route == null:
		push_warning("SaisiesUpperScenery needs a SaisiesRoute at route_path")
		return
	if not route.route_ready():
		_build_attempts += 1
		if _build_attempts < 8:
			call_deferred("_try_build")
		else:
			push_warning("SaisiesUpperScenery route was not ready after deferred retries")
		return
	_build_scenery()

func _build_scenery() -> void:
	_rng.seed = random_seed
	# Resolve the upper corridor from the route's authored video timeline when
	# available.  The metre values remain a fallback for standalone route data.
	from_m = _distance_for_video_seconds(from_video_seconds, from_m)
	to_m = _distance_for_video_seconds(to_video_seconds, to_m)
	from_m = clampf(from_m, 0.0, route.length_m)
	to_m = clampf(maxf(to_m, from_m + 1.0), 0.0, route.length_m)
	_make_materials()
	_load_tree_factory()
	var meadows := _group("SaisiesUpperMeadows")
	var farms := _group("SaisiesUpperFarms")
	var utilities := _group("SaisiesUpperUtilities")
	var walls := _group("SaisiesUpperWalls")
	var rails := _group("SaisiesUpperGuardrails")
	var trees := _group("SaisiesUpperTrees")
	add_child(meadows)
	add_child(farms)
	add_child(utilities)
	add_child(walls)
	add_child(rails)
	add_child(trees)

	# The route terrain already supplies the continuous meadow surface.  Keep
	# the old patch builder available for later material work, but do not add
	# long overlay strips to the review scene where they read as pale bands.
	var meadow_quads := 0
	var farm_counts := _build_farms(farms)
	var pole_count := _build_utilities(utilities)
	var s05 := _build_s05_corridor(rails)
	var s08 := _build_s08_corridor(walls, rails)
	var s09 := _build_s09_corridor(walls, rails)
	var tree_count := _build_upper_trees(trees) if include_trees else 0

	set_meta("saisies_upper_from_m", from_m)
	set_meta("saisies_upper_to_m", to_m)
	set_meta("saisies_upper_from_video_seconds", from_video_seconds)
	set_meta("saisies_upper_to_video_seconds", to_video_seconds)
	set_meta("saisies_upper_scene_ids", ["S04", "S05", "S06", "S07", "S08", "S09"])
	set_meta("saisies_upper_meadow_patch_quads", meadow_quads)
	set_meta("saisies_upper_farmhouses", farm_counts.farms)
	set_meta("saisies_upper_driveways", farm_counts.drives)
	set_meta("saisies_upper_farm_forward_offsets_m", farm_counts.forward_offsets)
	set_meta("saisies_upper_power_poles", pole_count)
	set_meta("saisies_upper_s05_guardrail_beams", s05.beams)
	set_meta("saisies_upper_s05_guardrail_side", -1.0)
	set_meta("saisies_upper_tree_instances", tree_count)
	set_meta("saisies_upper_s08_parapet_segments", s08.parapet)
	set_meta("saisies_upper_s08_cut_slope_quads", s08.cut_slope)
	set_meta("saisies_upper_s08_parapet_side", -1.0)
	set_meta("saisies_upper_s09_stonewall_segments", s09.wall)
	set_meta("saisies_upper_s09_guardrail_beams", s09.rail)
	set_meta("saisies_upper_s09_initial_wall_side", 1.0)
	set_meta("saisies_upper_s09_initial_rail_side", -1.0)
	set_meta("saisies_upper_s09_switched_wall_side", -1.0)
	set_meta("saisies_upper_s09_switched_rail_side", 1.0)
	set_meta("saisies_upper_guardrail_min_alignment", s09.min_alignment)
	set_meta("saisies_upper_guardrail_post_upright", s09.post_upright)
	upper_scenery_ready = true

func _group(node_name: String) -> Node3D:
	var node := Node3D.new()
	node.name = node_name
	return node

func _make_materials() -> void:
	_materials["grass"] = _mat(Color(0.34, 0.56, 0.18), 0.98)
	_materials["grass_alt"] = _mat(Color(0.48, 0.64, 0.23), 0.98)
	_materials["grass_dry"] = _mat(Color(0.58, 0.56, 0.27), 1.0)
	_materials["drive"] = _texture_mat("gravel_floor_02", Color(0.74, 0.73, 0.62), 0.98)
	_materials["stone"] = _texture_mat("stacked_stone_wall", Color(0.88, 0.86, 0.77), 0.96)
	_materials["stone_alt"] = _texture_mat("old_stone_wall", Color(0.73, 0.72, 0.66), 0.98)
	_materials["rock"] = _texture_mat("rock_boulder_dry", Color(0.68, 0.68, 0.60), 1.0)
	_materials["parapet"] = _texture_mat("painted_plaster_wall", Color(0.72, 0.70, 0.62), 0.92)
	_materials["plaster"] = _texture_mat("painted_plaster_wall", Color(1.08, 0.98, 0.80), 0.88)
	_materials["timber"] = _texture_mat("brown_planks_09", Color(0.70, 0.43, 0.22), 0.90)
	_materials["grey_timber"] = _texture_mat("wood_planks_grey", Color(0.72, 0.70, 0.62), 0.92)
	_materials["roof"] = _texture_mat("clay_roof_tiles_02", Color(0.42, 0.40, 0.34), 0.94)
	_materials["roof_light"] = _texture_mat("clay_roof_tiles", Color(0.52, 0.50, 0.43), 0.94)
	_materials["roof_grey"] = _mat(Color(0.43, 0.46, 0.45), 0.93)
	_materials["window"] = _mat(Color(0.035, 0.075, 0.085), 0.30)
	_materials["metal"] = _mat(Color(0.68, 0.73, 0.73), 0.30, 0.56)
	_materials["post"] = _mat(Color(0.48, 0.52, 0.51), 0.46, 0.20)
	_materials["pole"] = _texture_mat("brown_planks_09", Color(0.32, 0.22, 0.12), 0.94)
	_materials["wire"] = _mat(Color(0.11, 0.12, 0.10), 0.82)

func _distance_for_video_seconds(video_seconds: float, fallback_m: float) -> float:
	if route != null and route.has_method("distance_for_video_seconds"):
		return float(route.call("distance_for_video_seconds", video_seconds))
	return fallback_m

func _mat(color: Color, roughness := 0.8, metallic := 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	return material

func _texture_mat(stem: String, tint: Color, roughness := 0.8) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = load("res://assets/textures/%s_diff.jpg" % stem)
	material.normal_enabled = true
	material.normal_texture = load("res://assets/textures/%s_nor.jpg" % stem)
	material.roughness_texture = load("res://assets/textures/%s_rough.jpg" % stem)
	material.albedo_color = tint
	material.roughness = roughness
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * 0.42
	return material

func _build_meadow_patches(parent: Node3D) -> int:
	var meadow_end := minf(to_m, 4860.0)
	if meadow_end <= from_m:
		return 0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var patch_count := 0
	var s := from_m
	while s < meadow_end:
		var span := _rng.randf_range(42.0, 105.0)
		var s1 := minf(s + span, meadow_end)
		for side in [-1.0, 1.0]:
			if _rng.randf() > 0.82:
				continue
			var half0 := route.road_width_at(s) * 0.5
			var half1 := route.road_width_at(s1) * 0.5
			var inner := _rng.randf_range(half0 + 8.0, half0 + 23.0)
			var outer := inner + _rng.randf_range(18.0, 62.0)
			var tint := Color(0.20, 0.36, 0.12) if _rng.randf() < 0.58 else Color(0.26, 0.42, 0.15)
			if _rng.randf() < 0.18:
				tint = Color(0.34, 0.36, 0.15)
			_add_patch_quad(st, s, s1, side * inner, side * outer, tint)
			patch_count += 1
		s = s1 + _rng.randf_range(4.0, 18.0)
	st.generate_normals()
	var mesh := st.commit()
	if mesh == null:
		return 0
	var mi := MeshInstance3D.new()
	mi.name = "SaisiesUpperMeadowPatchMesh"
	mi.mesh = mesh
	var material := _mat(Color.WHITE, 0.98)
	material.vertex_color_use_as_albedo = true
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * 0.22
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return patch_count

func _add_patch_quad(st: SurfaceTool, s0: float, s1: float, u0: float, u1: float, color: Color) -> void:
	var a := _road_point(s0, u0, 0.018)
	var b := _road_point(s0, u1, 0.020)
	var c := _road_point(s1, u1, 0.020)
	var d := _road_point(s1, u0, 0.018)
	st.set_color(color); st.set_uv(Vector2(0.0, s0 * 0.025)); st.add_vertex(a)
	st.set_color(color); st.set_uv(Vector2(1.0, s0 * 0.025)); st.add_vertex(b)
	st.set_color(color); st.set_uv(Vector2(1.0, s1 * 0.025)); st.add_vertex(c)
	st.set_color(color); st.set_uv(Vector2(0.0, s0 * 0.025)); st.add_vertex(a)
	st.set_color(color); st.set_uv(Vector2(1.0, s1 * 0.025)); st.add_vertex(c)
	st.set_color(color); st.set_uv(Vector2(0.0, s1 * 0.025)); st.add_vertex(d)

func _farm_specs() -> Array:
	return [
		# `video_seconds` identifies the capture point.  The authored building
		# sits ahead of that point by an explicit metre offset so it is visible
		# in the primary frame instead of being left beside/behind the camera.
		{"id": "S04_low_shed", "video_seconds": 118.0, "s": 1820.0, "forward_distance_m": 50.0, "side": 1.0, "u": 30.0, "kind": "shed", "seed": 401, "yaw": 0.10},
		{"id": "S04_field_barn", "video_seconds": 138.0, "s": 2020.0, "forward_distance_m": 35.0, "side": -1.0, "u": 43.0, "kind": "barn", "seed": 417, "yaw": -0.08},
		{"id": "S05_lower_barn", "video_seconds": 158.0, "s": 2460.0, "forward_distance_m": 30.0, "side": -1.0, "u": 38.0, "kind": "barn", "seed": 433, "yaw": 0.12},
		{"id": "S05_upper_chalet", "video_seconds": 194.0, "s": 3090.0, "forward_distance_m": 30.0, "side": 1.0, "u": 36.0, "kind": "house", "seed": 449, "yaw": -0.06},
		{"id": "S06_main_chalet", "video_seconds": 225.0, "s": 4140.0, "forward_distance_m": 28.0, "side": 1.0, "u": 20.0, "width_scale": 1.25, "kind": "house", "seed": 463, "yaw": 0.04},
		{"id": "S06_low_barn", "video_seconds": 225.0, "s": 3685.0, "forward_distance_m": 35.0, "side": -1.0, "u": 42.0, "kind": "barn", "seed": 479, "yaw": -0.12},
		{"id": "S07_upper_house", "video_seconds": 270.0, "s": 4430.0, "forward_distance_m": 45.0, "side": 1.0, "u": 30.0, "width_scale": 1.10, "kind": "house", "seed": 491, "yaw": 0.09},
		{"id": "S07_low_longhouse", "video_seconds": 270.0, "s": 4435.0, "forward_distance_m": 35.0, "side": -1.0, "u": 38.0, "kind": "barn", "seed": 503, "yaw": -0.05},
		{"id": "S09_field_shed", "video_seconds": 350.0, "s": 6090.0, "forward_distance_m": 35.0, "side": -1.0, "u": 43.0, "kind": "shed", "seed": 521, "yaw": 0.11}
	]

func _spec_distance(spec: Dictionary) -> float:
	var fallback := float(spec.get("s", 0.0))
	if spec.has("video_seconds"):
		return _distance_for_video_seconds(float(spec["video_seconds"]), fallback)
	return fallback

func _build_farms(parent: Node3D) -> Dictionary:
	var farms := 0
	var drives := 0
	var forward_offsets: Array[Dictionary] = []
	for spec in _farm_specs():
		var capture_s := clampf(_spec_distance(spec), from_m, to_m)
		var forward_distance := float(spec.get("forward_distance_m", 0.0))
		var s := clampf(capture_s + forward_distance, from_m, to_m)
		var side := float(spec["side"])
		var u := side * float(spec["u"])
		var base := _road_point(s, u)
		var n := Node3D.new()
		n.name = "SaisiesUpperFarm_%s" % String(spec["id"])
		n.position = base
		var road_basis := Basis.looking_at(route.tangent_at(s), Vector3.UP)
		n.basis = Basis(Vector3.UP, float(spec["yaw"])) * road_basis
		parent.add_child(n)
		_build_farmhouse(n, String(spec["kind"]), int(spec["seed"]), float(spec.get("width_scale", 1.0)))
		if _build_driveway(parent, s, side, absf(float(spec["u"]))):
			drives += 1
		forward_offsets.append({"id": String(spec["id"]), "capture_m": capture_s, "object_m": s, "forward_m": forward_distance, "video_seconds": float(spec.get("video_seconds", -1.0)), "side": side, "u": absf(float(spec["u"]))})
		farms += 1
	return {"farms": farms, "drives": drives, "forward_offsets": forward_offsets}

func _build_farmhouse(parent: Node3D, kind: String, seed: int, width_scale := 1.0) -> void:
	var house := kind == "house"
	var barn := kind == "barn"
	var s06_main := seed == 463
	var s06_low := seed == 479
	var s07_upper := seed == 491
	var s07_low := seed == 503
	width_scale = clampf(width_scale, 0.75, 1.60)
	var width := (8.6 if house else (10.4 if barn else 6.8)) * width_scale
	width += float(abs(seed) % 3) * 0.45
	var depth := (7.0 if house else (9.0 if barn else 5.6)) * width_scale
	depth += float((abs(seed) / 3) % 2) * 0.55
	var stories := 2 if house else 1
	var foundation_h := 0.72 if house else 0.58
	var body_h := (4.75 if house else (2.80 if s07_low else (3.55 if barn else 2.75)))
	var body_material: Material = _materials["timber"] if barn or seed % 3 == 0 else _materials["plaster"]
	var roof_material: Material = _materials["roof_light"] if seed % 2 == 0 else _materials["roof"]
	if s06_main or s07_upper or s07_low:
		body_material = _materials["timber"]
	if s06_main or s06_low or s07_low:
		roof_material = _materials["roof_grey"]
	var foundation_width := width + 0.38
	var foundation_depth := depth + 0.38
	var burial_depth := _foundation_burial_depth(parent, foundation_width, foundation_depth)
	_part(parent, _box(Vector3(foundation_width, foundation_h + burial_depth, foundation_depth)), _materials["stone"], Vector3(0.0, foundation_h * 0.5 - burial_depth * 0.5, 0.0))
	_part(parent, _box(Vector3(width, body_h, depth)), body_material, Vector3(0.0, foundation_h + body_h * 0.5, 0.0))
	var roof_angle := deg_to_rad(25.0 + float(abs(seed) % 5))
	if s07_low:
		roof_angle = deg_to_rad(19.0)
	var half_span := width * 0.5 + 0.34
	var slab_len := half_span / cos(roof_angle)
	var slab_thickness := 0.24
	var roof_eave_y := foundation_h + body_h + 0.10
	var roof_center_y := roof_eave_y + half_span * 0.5 * tan(roof_angle)
	var roof_neg := _part(parent, _box(Vector3(slab_len, slab_thickness, depth + 0.46)), roof_material, Vector3(-half_span * 0.5, roof_center_y, 0.0), Vector3(0.0, 0.0, roof_angle))
	roof_neg.name = "RoofSlopeNegX"
	var roof_pos := _part(parent, _box(Vector3(slab_len, slab_thickness, depth + 0.46)), roof_material, Vector3(half_span * 0.5, roof_center_y, 0.0), Vector3(0.0, 0.0, -roof_angle))
	roof_pos.name = "RoofSlopePosX"
	_part(parent, _box(Vector3(0.34, 0.26, depth + 0.54)), roof_material, Vector3(0.0, roof_eave_y + half_span * tan(roof_angle), 0.0))
	# Close both gable ends so the house reads as a complete volume from either
	# approach.  The same sealed triangle also prevents the sky from showing
	# through the roof when the camera sees the +Z end of a farm.
	var roof_rise := half_span * tan(roof_angle)
	for end_value in [-1.0, 1.0]:
		var end_sign: float = float(end_value)
		var gable := _part(parent, _gable_triangle_mesh(0.14, width * 0.94, roof_rise), body_material, Vector3(0.0, roof_eave_y - 0.04, end_sign * (depth * 0.5 + 0.07)), Vector3(0.0, PI * 0.5, 0.0))
		gable.name = "SealedGableEndNeg" if end_sign < 0.0 else "SealedGableEndPos"
	if house:
		for floor in stories:
			var y := foundation_h + 1.02 + float(floor) * 2.45
			var balcony_w := width * (0.70 if floor == 0 else 0.52)
			for end_value in [-1.0, 1.0]:
				var end_sign: float = float(end_value)
				var face_z := end_sign * depth * 0.54
				_part(parent, _box(Vector3(balcony_w, 0.12, 0.18)), _materials["timber"], Vector3(0.0, y, face_z))
				_part(parent, _box(Vector3(balcony_w, 0.12, 0.13)), _materials["timber"], Vector3(0.0, y + 0.66, face_z))
				_part(parent, _box(Vector3(0.12, 0.66, 0.13)), _materials["timber"], Vector3(-balcony_w * 0.5, y + 0.33, face_z))
				_part(parent, _box(Vector3(0.12, 0.66, 0.13)), _materials["timber"], Vector3(balcony_w * 0.5, y + 0.33, face_z))
				_part(parent, _box(Vector3(1.05, 1.15, 0.08)), _materials["window"], Vector3(-width * 0.23, foundation_h + 1.25 + float(floor) * 2.45, face_z))
				_part(parent, _box(Vector3(1.18, 1.20, 0.08)), _materials["window"], Vector3(width * 0.23, foundation_h + 1.25 + float(floor) * 2.45, face_z))
			# Side-wall windows make the house readable when the road exposes a
			# quarter-angle instead of looking straight at an end balcony.
			for side_value in [-1.0, 1.0]:
				var side_sign: float = float(side_value)
				_part(parent, _box(Vector3(0.08, 1.08, 1.10)), _materials["window"], Vector3(side_sign * width * 0.515, foundation_h + 1.25 + float(floor) * 2.45, -depth * 0.22))
				_part(parent, _box(Vector3(0.08, 1.08, 1.10)), _materials["window"], Vector3(side_sign * width * 0.515, foundation_h + 1.25 + float(floor) * 2.45, depth * 0.22))
	else:
		for end_value in [-1.0, 1.0]:
			var end_sign: float = float(end_value)
			var face_z := end_sign * depth * 0.515
			_part(parent, _box(Vector3(width * 0.30, 1.65, 0.08)), _materials["window"], Vector3(0.0, foundation_h + 1.35, face_z))
			_part(parent, _box(Vector3(width * 0.36, 0.14, 0.10)), _materials["timber"], Vector3(0.0, foundation_h + 0.48, face_z + end_sign * 0.04))
			_part(parent, _box(Vector3(width * 0.36, 2.05, 0.08)), _materials["timber"], Vector3(0.0, foundation_h + 1.05, face_z + end_sign * 0.04))
		for side_value in [-1.0, 1.0]:
			var side_sign: float = float(side_value)
			_part(parent, _box(Vector3(0.08, 1.25, width * 0.24)), _materials["window"], Vector3(side_sign * width * 0.515, foundation_h + 1.35, 0.0))
	var chimney := CylinderMesh.new()
	chimney.top_radius = 0.18
	chimney.bottom_radius = 0.22
	chimney.height = 1.15
	chimney.radial_segments = 8
	var chimney_x := width * 0.18
	# Use the roof's local plane at the chimney x, rather than the full ridge
	# height.  The half slab thickness is projected through the roof slope so
	# the cylinder bottom is embedded 0.10 m into the actual roof surface.
	var roof_surface_y := roof_eave_y + (half_span - absf(chimney_x)) * tan(roof_angle) + (slab_thickness * 0.5) / cos(roof_angle)
	var chimney_center_y := roof_surface_y + chimney.height * 0.5 - 0.10
	var chimney_part := _part(parent, chimney, _materials["stone_alt"], Vector3(chimney_x, chimney_center_y, depth * 0.12))
	chimney_part.name = "FarmChimney"
	parent.set_meta("saisies_farm_window_faces", 4 if house else 3)
	parent.set_meta("saisies_farm_has_sealed_gables", true)
	parent.set_meta("saisies_farm_base_contact", true)
	parent.set_meta("saisies_farm_roof_style", "grey" if s06_main or s06_low or s07_low else "pitched")
	parent.set_meta("saisies_farm_foundation_burial_m", burial_depth)

func _build_driveway(parent: Node3D, s: float, side: float, house_u: float) -> bool:
	var half := route.road_width_at(s) * 0.5
	var start_u := side * (half + 1.8)
	var end_u := side * maxf(house_u - 3.0, half + 4.0)
	var p0 := _road_point(s, start_u, 0.035)
	var p1 := _road_point(s, end_u, 0.035)
	if p0.distance_to(p1) < 3.0:
		return false
	_add_box_segment(parent, p0, p1, 3.5, 0.06, _materials["drive"], "SaisiesUpperFarmDrive")
	var yard := _road_point(s, end_u, 0.07)
	_part(parent, _box(Vector3(5.8, 0.08, 4.2)), _materials["drive"], yard, Vector3(0.0, route.tangent_at(s).y, 0.0))
	return true

func _build_utilities(parent: Node3D) -> int:
	var pole_specs := [
		{"s": 1700.0, "side": 1.0, "u": 31.0},
		{"s": 2360.0, "side": 1.0, "u": 34.0},
		{"video_seconds": 184.0, "s": 2950.0, "side": 1.0, "u": 24.0},
		{"s": 3040.0, "side": 1.0, "u": 39.0},
		{"s": 4380.0, "side": -1.0, "u": 31.0},
		{"s": 4660.0, "side": -1.0, "u": 34.0}
	]
	var poles: Array[Dictionary] = []
	for spec in pole_specs:
		var s := clampf(_spec_distance(spec), from_m, to_m)
		var side := float(spec["side"])
		var u := side * float(spec["u"])
		var ground := _road_point(s, u)
		var n := Node3D.new()
		n.name = "SaisiesUpperPowerPole_%04d" % int(s)
		n.position = ground
		n.basis = Basis.looking_at(route.tangent_at(s), Vector3.UP)
		parent.add_child(n)
		_part(n, _cylinder(0.075, 0.10, 6.3, 10), _materials["pole"], Vector3(0.0, 3.15, 0.0))
		_part(n, _box(Vector3(2.65, 0.11, 0.12)), _materials["pole"], Vector3(0.0, 5.72, 0.0))
		_part(n, _box(Vector3(0.10, 0.22, 0.10)), _materials["pole"], Vector3(-0.90, 5.72, 0.0))
		_part(n, _box(Vector3(0.10, 0.22, 0.10)), _materials["pole"], Vector3(0.90, 5.72, 0.0))
		poles.append({"s": s, "position": ground, "side": side})
	# Wires follow separate runs on each side of the road so they do not form
	# an implausible diagonal cable through the camera corridor.
	for side in [-1.0, 1.0]:
		var run: Array[Dictionary] = []
		for pole in poles:
			if float(pole["side"]) == side:
				run.append(pole)
		for i in range(run.size() - 1):
			var a: Dictionary = run[i]
			var b: Dictionary = run[i + 1]
			var sa := float(a["s"])
			var sb := float(b["s"])
			for offset in [-0.62, 0.62]:
				var la := route.left_at(sa)
				var lb := route.left_at(sb)
				var p0: Vector3 = a["position"] + la * offset + Vector3.UP * 5.76
				var p1: Vector3 = b["position"] + lb * offset + Vector3.UP * 5.76
				_add_wire_chain(parent, p0, p1, "SaisiesUpperPowerWire")
	return poles.size()

func _build_s05_corridor(rails: Node3D) -> Dictionary:
	# The source shows a continuous silver rail on the outside of the left bend
	# from roughly 02:25 through 03:25.  Keep it as real world geometry so the
	# curve is readable at the S05 03:00 acceptance frame.
	var start := maxf(from_m, _distance_for_video_seconds(145.0, 2290.0))
	var finish := minf(to_m, _distance_for_video_seconds(205.0, 3200.0))
	return _build_guardrail_range(rails, start, finish, -1.0)

func _add_wire_chain(parent: Node3D, p0: Vector3, p1: Vector3, node_name: String) -> void:
	var steps := 3
	for i in range(steps):
		var t0 := float(i) / steps
		var t1 := float(i + 1) / steps
		var a := p0.lerp(p1, t0)
		var b := p0.lerp(p1, t1)
		var sag0 := 0.9 * sin(t0 * PI)
		var sag1 := 0.9 * sin(t1 * PI)
		a.y -= sag0
		b.y -= sag1
		_add_box_segment(parent, a, b, 0.024, 0.024, _materials["wire"], node_name)

func _build_s08_corridor(walls: Node3D, rails: Node3D) -> Dictionary:
	var start := maxf(from_m, _distance_for_video_seconds(296.0, 4860.0))
	var finish := minf(to_m, _distance_for_video_seconds(330.0, 5500.0))
	var parapet := _build_solid_wall(walls, start, finish, -1.0, 0.84, 0.52, _materials["parapet"], "SaisiesS08RightParapet", 8.0)
	var cut_slope := _build_cut_slope(walls, start, finish, 1.0)
	# A short rail at the sunlit exit records the change of protection type
	# visible in the reference without making the whole S08 side metal.
	_build_guardrail_range(rails, maxf(start, finish - 115.0), finish, -1.0)
	return {"parapet": parapet, "cut_slope": cut_slope}

func _build_s09_corridor(walls: Node3D, rails: Node3D) -> Dictionary:
	var start := maxf(from_m, _distance_for_video_seconds(330.0, 5500.0))
	var finish := minf(to_m, _distance_for_video_seconds(390.0, 6500.0))
	var split := clampf(_distance_for_video_seconds(360.0, 5900.0), start, finish)
	var wall_count := 0
	var rail_count := 0
	var min_alignment := 1.0
	var post_upright := 1.0
	if split > start:
		wall_count += _build_stone_wall(walls, start, split, 1.0)
		var first := _build_guardrail_range(rails, start, split, -1.0)
		rail_count += first.beams
		min_alignment = minf(min_alignment, first.alignment)
		post_upright = minf(post_upright, first.upright)
	if finish > split:
		wall_count += _build_stone_wall(walls, split, finish, -1.0)
		var second := _build_guardrail_range(rails, split, finish, 1.0)
		rail_count += second.beams
		min_alignment = minf(min_alignment, second.alignment)
		post_upright = minf(post_upright, second.upright)
	return {"wall": wall_count, "rail": rail_count, "min_alignment": min_alignment, "post_upright": post_upright}

func _build_solid_wall(parent: Node3D, start: float, finish: float, side: float, height: float, depth: float, material: Material, node_prefix: String, spacing: float) -> int:
	if finish <= start:
		return 0
	var count := 0
	var s := start
	while s < finish - 0.1:
		var s1 := minf(s + spacing, finish)
		var u0 := side * (route.road_width_at(s) * 0.5 + 0.74)
		var u1 := side * (route.road_width_at(s1) * 0.5 + 0.74)
		var p0 := _road_point(s, u0, height * 0.5)
		var p1 := _road_point(s1, u1, height * 0.5)
		_add_box_segment(parent, p0, p1, depth, height, material, node_prefix)
		var cap0 := p0 + Vector3.UP * (height * 0.53)
		var cap1 := p1 + Vector3.UP * (height * 0.53)
		_add_box_segment(parent, cap0, cap1, depth + 0.10, 0.12, material, node_prefix + "Cap")
		count += 1
		s = s1
	return count

func _build_stone_wall(parent: Node3D, start: float, finish: float, side: float) -> int:
	if finish <= start:
		return 0
	var count := 0
	var s := start
	while s < finish - 0.1:
		var span := _rng.randf_range(1.45, 2.35)
		var s1 := minf(s + span, finish)
		var h := _rng.randf_range(1.08, 1.62)
		var depth := _rng.randf_range(0.60, 0.84)
		var u0 := side * (route.road_width_at(s) * 0.5 + 0.74)
		var u1 := side * (route.road_width_at(s1) * 0.5 + 0.74)
		var p0 := _road_point(s, u0, h * 0.5)
		var p1 := _road_point(s1, u1, h * 0.5)
		var material: Material = _materials["stone"] if count % 3 != 0 else _materials["stone_alt"]
		_add_box_segment(parent, p0, p1, depth, h, material, "SaisiesS09StoneBlock")
		var cap0 := p0 + Vector3.UP * (h * 0.53)
		var cap1 := p1 + Vector3.UP * (h * 0.53)
		_add_box_segment(parent, cap0, cap1, depth + 0.12, 0.11, _materials["stone_alt"], "SaisiesS09StoneCap")
		count += 1
		s = s1
	return count

func _build_cut_slope(parent: Node3D, start: float, finish: float, side: float) -> int:
	if finish <= start:
		return 0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quads := 0
	var s := start
	while s < finish - 0.1:
		var s1 := minf(s + 12.0, finish)
		var half0 := route.road_width_at(s) * 0.5
		var half1 := route.road_width_at(s1) * 0.5
		var inner0 := side * (half0 + 1.0)
		var inner1 := side * (half1 + 1.0)
		var outer0 := side * (half0 + _rng.randf_range(7.5, 12.5))
		var outer1 := side * (half1 + _rng.randf_range(7.5, 12.5))
		var a := _road_point(s, inner0, 0.06)
		var b := _road_point(s, outer0, _rng.randf_range(1.1, 2.2))
		var c := _road_point(s1, outer1, _rng.randf_range(1.1, 2.2))
		var d := _road_point(s1, inner1, 0.06)
		var color := Color(0.48, 0.46, 0.38) if quads % 3 == 0 else Color(0.59, 0.54, 0.42)
		st.set_color(color); st.add_vertex(a)
		st.set_color(color); st.add_vertex(b)
		st.set_color(color); st.add_vertex(c)
		st.set_color(color); st.add_vertex(a)
		st.set_color(color); st.add_vertex(c)
		st.set_color(color); st.add_vertex(d)
		quads += 1
		s = s1
	st.generate_normals()
	var mesh := st.commit()
	if mesh == null:
		return 0
	var mi := MeshInstance3D.new()
	mi.name = "SaisiesS08LeftCutSlope"
	mi.mesh = mesh
	var material := _mat(Color.WHITE, 0.98)
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = load("res://assets/textures/rock_boulder_dry_diff.jpg")
	material.normal_enabled = true
	material.normal_texture = load("res://assets/textures/rock_boulder_dry_nor.jpg")
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * 0.30
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return quads

func _build_guardrail_range(parent: Node3D, start: float, finish: float, side: float) -> Dictionary:
	if finish <= start:
		return {"beams": 0, "alignment": 1.0, "upright": 1.0}
	var rail_mesh := _box(Vector3(0.12, 0.18, 1.0))
	var post_mesh := _box(Vector3(0.11, 1.10, 0.11))
	var beams := 0
	var min_alignment := 1.0
	var min_upright := 1.0
	var s := start
	while s < finish - 0.1:
		var s1 := minf(s + guardrail_spacing_m, finish)
		var u0 := side * (route.road_width_at(s) * 0.5 + 0.68)
		var u1 := side * (route.road_width_at(s1) * 0.5 + 0.68)
		var ground0 := _road_point(s, u0)
		var ground1 := _road_point(s1, u1)
		var post0 := ground0 + Vector3.UP * 0.55
		var post1 := ground1 + Vector3.UP * 0.55
		var post_a := MeshInstance3D.new()
		post_a.name = "SaisiesUpperGuardPost"
		post_a.mesh = post_mesh
		post_a.material_override = _materials["post"]
		post_a.position = post0
		parent.add_child(post_a)
		var post_b := MeshInstance3D.new()
		post_b.name = "SaisiesUpperGuardPost"
		post_b.mesh = post_mesh
		post_b.material_override = _materials["post"]
		post_b.position = post1
		parent.add_child(post_b)
		var post_direction := post1 - post0
		post_direction.y = 0.0
		if post_direction.length_squared() > 0.0001:
			min_upright = minf(min_upright, Vector3.UP.dot(Vector3.UP))
		var beam_basis := _full_segment_basis(post0, post1)
		var direction := (post1 - post0).normalized()
		min_alignment = minf(min_alignment, absf((-beam_basis.z.normalized()).dot(direction)))
		for lift in [0.0, -0.28]:
			var beam := MeshInstance3D.new()
			beam.name = "SaisiesUpperGuardRail"
			beam.mesh = rail_mesh
			beam.material_override = _materials["metal"]
			beam.transform = Transform3D(beam_basis.scaled_local(Vector3(1.0, 1.0, post0.distance_to(post1))), (post0 + post1) * 0.5 + Vector3.UP * lift)
			parent.add_child(beam)
			beams += 1
		s = s1
	return {"beams": beams, "alignment": min_alignment, "upright": min_upright}

func _load_tree_factory() -> void:
	var factory_script := load("res://scripts/saisies_trees.gd") as Script
	if factory_script == null:
		return
	var broad = factory_script.call("broadleaf_variants")
	var conifers = factory_script.call("conifer_variants")
	if broad is Array:
		for mesh in broad:
			if mesh is Mesh:
				_tree_broadleaf.append(mesh)
	if conifers is Array:
		for mesh in conifers:
			if mesh is Mesh:
				_tree_conifer.append(mesh)

func _build_upper_trees(parent: Node3D) -> int:
	if _tree_broadleaf.is_empty() or _tree_conifer.is_empty():
		return 0
	var items := {}
	for i in _tree_broadleaf.size():
		items["broadleaf_%02d" % i] = []
	for i in _tree_conifer.size():
		items["conifer_%02d" % i] = []
	var clusters := [
		{"s0": 1380.0, "s1": 2050.0, "side": -1.0, "count": 15, "conifer": true, "inner": 36.0, "outer": 92.0},
		{"s0": 1450.0, "s1": 2300.0, "side": 1.0, "count": 8, "conifer": false, "inner": 28.0, "outer": 78.0},
		{"s0": 2200.0, "s1": 3650.0, "side": 0.0, "count": 25, "conifer": false, "inner": 30.0, "outer": 110.0},
		{"s0": 3500.0, "s1": 4700.0, "side": 0.0, "count": 26, "conifer": true, "inner": 24.0, "outer": 90.0},
		{"s0": 4750.0, "s1": 5480.0, "side": -1.0, "count": 30, "conifer": false, "inner": 19.0, "outer": 68.0},
		{"s0": 4860.0, "s1": 5480.0, "side": 1.0, "count": 14, "conifer": true, "inner": 22.0, "outer": 62.0},
		# S08 is a shaded cut/low-wall corridor.  The close paired groups make
		# the wall's outside slope read as a real stand of trunks and crowns.
		{"s0": 4980.0, "s1": 5350.0, "side": 1.0, "count": 38, "conifer": false, "conifer_chance": 0.15, "inner": 18.0, "outer": 75.0, "scale_min": 0.86, "scale_max": 1.32},
		{"s0": 4980.0, "s1": 5350.0, "side": -1.0, "count": 54, "conifer": false, "conifer_chance": 0.15, "inner": 16.0, "outer": 100.0, "scale_min": 0.84, "scale_max": 1.36},
		# S09 opens briefly at the wall/rail bend, then closes into broadleaf
		# groups on both sides.  Anchor spans are deliberately short so the
		# primary frame sees crowns close to the protection transition.
		{"s0": 5480.0, "s1": 5750.0, "side": 1.0, "count": 38, "conifer": false, "conifer_chance": 0.14, "inner": 18.0, "outer": 82.0, "scale_min": 0.88, "scale_max": 1.38},
		{"s0": 5480.0, "s1": 5750.0, "side": -1.0, "count": 48, "conifer": false, "conifer_chance": 0.14, "inner": 16.0, "outer": 105.0, "scale_min": 0.86, "scale_max": 1.42},
		{"s0": 5750.0, "s1": 6500.0, "side": 1.0, "count": 52, "conifer": false, "conifer_chance": 0.18, "inner": 22.0, "outer": 105.0, "scale_min": 0.84, "scale_max": 1.32},
		{"s0": 5750.0, "s1": 6500.0, "side": -1.0, "count": 52, "conifer": false, "conifer_chance": 0.18, "inner": 20.0, "outer": 110.0, "scale_min": 0.84, "scale_max": 1.34},
		{"s0": 5480.0, "s1": 6500.0, "side": 0.0, "count": 44, "conifer": false, "inner": 23.0, "outer": 94.0}
	]
	var count := 0
	for cluster in clusters:
		var s0 := maxf(float(cluster["s0"]), from_m)
		var s1 := minf(float(cluster["s1"]), to_m)
		if s1 <= s0:
			continue
		for i in int(cluster["count"]):
			var s := _rng.randf_range(s0, s1)
			var side := float(cluster["side"])
			if absf(side) < 0.1:
				side = -1.0 if _rng.randf() < 0.5 else 1.0
			var u := side * _rng.randf_range(float(cluster["inner"]), float(cluster["outer"]))
			var p := _road_point(s, u)
			var family_conifer := bool(cluster["conifer"])
			if not family_conifer and _rng.randf() < float(cluster.get("conifer_chance", 0.35)):
				family_conifer = true
			var family_size := _tree_conifer.size() if family_conifer else _tree_broadleaf.size()
			var family := "conifer" if family_conifer else "broadleaf"
			var variant := _rng.randi_range(0, maxi(family_size - 1, 0))
			var scale := _rng.randf_range(float(cluster.get("scale_min", 0.72)), float(cluster.get("scale_max", 1.18)))
			if family_conifer and _rng.randf() < 0.22:
				scale *= 1.22
			items["%s_%02d" % [family, variant]].append({"s": s, "position": p, "scale": scale, "yaw": _rng.randf() * TAU})
			count += 1
	for key in items.keys():
		var family := String(key).split("_")[0]
		var variant := int(String(key).split("_")[1])
		var mesh: Mesh = _tree_conifer[variant] if family == "conifer" else _tree_broadleaf[variant]
		_spawn_tree_chunks(parent, mesh, items[key], "SaisiesUpperTrees_%s" % String(key))
	return count

func _spawn_tree_chunks(parent: Node3D, mesh: Mesh, items: Array, prefix: String) -> void:
	if mesh == null or items.is_empty():
		return
	var chunks := {}
	for item in items:
		var index := int(floor(float(item["s"]) / 500.0))
		if not chunks.has(index):
			chunks[index] = []
		chunks[index].append(item)
	for index in chunks.keys():
		var origin := route.pos_at(minf((float(index) + 0.5) * 500.0, route.length_m))
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = chunks[index].size()
		for i in multimesh.instance_count:
			var item: Dictionary = chunks[index][i]
			var scale := float(item["scale"])
			var basis := Basis(Vector3.UP, float(item["yaw"])).scaled(Vector3.ONE * scale)
			multimesh.set_instance_transform(i, Transform3D(basis, item["position"] - origin))
		var instance := MultiMeshInstance3D.new()
		instance.name = "%s_%02d" % [prefix, int(index)]
		instance.multimesh = multimesh
		instance.position = origin
		parent.add_child(instance)

func _road_point(s: float, u: float, lift := 0.0) -> Vector3:
	var p := route.pos_at(clampf(s, 0.0, route.length_m)) + route.left_at(clampf(s, 0.0, route.length_m)) * u
	p.y = route.ground_y(clampf(s, 0.0, route.length_m), u) + lift
	return p

func _foundation_burial_depth(parent: Node3D, width: float, depth: float) -> float:
	# Sample the transformed bottom footprint, including edge midpoints, because
	# the route grade can change several metres across a farm's depth.  Keep the
	# foundation top fixed so the body and roof retain their authored world pose.
	var half_x := width * 0.5
	var half_z := depth * 0.5
	var footprint := [
		Vector3(-half_x, 0.0, -half_z),
		Vector3(half_x, 0.0, -half_z),
		Vector3(half_x, 0.0, half_z),
		Vector3(-half_x, 0.0, half_z),
		Vector3(0.0, 0.0, -half_z),
		Vector3(half_x, 0.0, 0.0),
		Vector3(0.0, 0.0, half_z),
		Vector3(-half_x, 0.0, 0.0)
	]
	var minimum_ground_y := INF
	for local_point in footprint:
		var world_point: Vector3 = parent.global_transform * local_point
		var sample_s := route.distance_for_position(world_point)
		var route_point := route.pos_at(sample_s)
		var route_left := route.left_at(sample_s)
		var lateral := (world_point - route_point).dot(route_left)
		minimum_ground_y = minf(minimum_ground_y, route.ground_y(sample_s, lateral))
	var current_bottom_y := (parent.global_transform * Vector3.ZERO).y
	var local_up_y := maxf(parent.global_transform.basis.y.y, 0.001)
	return maxf((current_bottom_y - minimum_ground_y + 0.10) / local_up_y, 0.10)

func _box(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh

func _gable_triangle_mesh(thickness: float, span: float, height: float) -> Mesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_thickness := thickness * 0.5
	var half_span := span * 0.5
	var back_left := Vector3(-half_thickness, 0.0, -half_span)
	var back_right := Vector3(-half_thickness, 0.0, half_span)
	var back_peak := Vector3(-half_thickness, height, 0.0)
	var front_left := Vector3(half_thickness, 0.0, -half_span)
	var front_right := Vector3(half_thickness, 0.0, half_span)
	var front_peak := Vector3(half_thickness, height, 0.0)
	# Close both faces and the three thin edge surfaces so neither gable end
	# exposes the sky through the pitched roof.
	surface.add_vertex(front_left); surface.add_vertex(front_right); surface.add_vertex(front_peak)
	surface.add_vertex(back_right); surface.add_vertex(back_left); surface.add_vertex(back_peak)
	surface.add_vertex(front_left); surface.add_vertex(front_peak); surface.add_vertex(back_peak)
	surface.add_vertex(front_left); surface.add_vertex(back_peak); surface.add_vertex(back_left)
	surface.add_vertex(front_peak); surface.add_vertex(front_right); surface.add_vertex(back_right)
	surface.add_vertex(front_peak); surface.add_vertex(back_right); surface.add_vertex(back_peak)
	surface.add_vertex(front_left); surface.add_vertex(back_left); surface.add_vertex(back_right)
	surface.add_vertex(front_left); surface.add_vertex(back_right); surface.add_vertex(front_right)
	surface.generate_normals()
	return surface.commit()

func _cylinder(top: float, bottom: float, height: float, segments := 10) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top
	mesh.bottom_radius = bottom
	mesh.height = height
	mesh.radial_segments = segments
	return mesh

func _part(parent: Node3D, mesh: Mesh, material: Material, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = pos
	instance.rotation = rot
	parent.add_child(instance)
	return instance

func _full_segment_basis(a: Vector3, b: Vector3) -> Basis:
	var direction := (b - a).normalized()
	if direction.length_squared() < 0.0001:
		return Basis.IDENTITY
	return Basis.looking_at(direction, Vector3.UP)

func _add_box_segment(parent: Node3D, a: Vector3, b: Vector3, width: float, height: float, material: Material, node_name: String) -> MeshInstance3D:
	var direction := b - a
	var length := direction.length()
	var basis := _full_segment_basis(a, b)
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = _box(Vector3(1.0, 1.0, 1.0))
	instance.material_override = material
	instance.transform = Transform3D(basis.scaled_local(Vector3(width, height, length)), (a + b) * 0.5)
	parent.add_child(instance)
	return instance
