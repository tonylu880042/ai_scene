extends Node3D

## Scene dressing for Saisies: deterministic, chunked foliage and roadside props.
## Heavy source models are converted to MultiMesh chunks so only roughly 600 m
## around the rider is visible. Roadside rails/walls remain lightweight primitives.

@export var route_path: NodePath
@export var player_path: NodePath
@export var random_seed := 731
@export var chunk_length_m := 500.0
@export var view_distance_m := 720.0

var route: SaisiesRoute
var player: Node3D
var _rng := RandomNumberGenerator.new()
var _mesh_cache := {}
var _materials := {}
var _factory_broadleaf: Array = []
var _factory_conifer: Array = []

func _ready() -> void:
	route = get_node_or_null(route_path) as SaisiesRoute
	player = get_node_or_null(player_path) as Node3D
	if route == null or not route.route_ready():
		return
	_rng.seed = random_seed
	_make_materials()
	_load_tree_factory()
	_build_foliage()
	_build_guardrails()
	_build_walls_and_rocks()
	_build_chalets_and_landmarks()

func _make_materials() -> void:
	_materials["rail"] = _mat(Color(0.74, 0.79, 0.80), 0.28, 0.52)
	_materials["post"] = _mat(Color(0.53, 0.57, 0.58), 0.40, 0.42)
	_materials["stone"] = _texture_mat("stacked_stone_wall", Color(1.1, 1.08, 1.02), 0.94)
	_materials["rock"] = _texture_mat("rock_boulder_dry", Color(0.76, 0.78, 0.75), 0.98)
	_materials["cream"] = _texture_mat("painted_plaster_wall", Color(1.25, 1.12, 0.90), 0.84)
	_materials["wood"] = _texture_mat("brown_planks_09", Color(0.72, 0.48, 0.28), 0.82)
	_materials["roof"] = _texture_mat("clay_roof_tiles_02", Color(0.48, 0.48, 0.46), 0.88)
	_materials["sign"] = _mat(Color(0.92, 0.78, 0.30), 0.64)
	_materials["pole"] = _mat(Color(0.16, 0.13, 0.10), 0.9)
	_materials["mountain_near"] = _mat(Color(0.18, 0.30, 0.22), 1.0)
	_materials["mountain_mid"] = _mat(Color(0.25, 0.38, 0.38), 1.0)
	_materials["mountain_far"] = _mat(Color(0.37, 0.47, 0.54), 1.0)

func _mat(color: Color, roughness := 0.8, metallic := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m

func _texture_mat(stem: String, tint: Color, roughness := 0.8) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://assets/textures/%s_diff.jpg" % stem)
	m.normal_enabled = true
	m.normal_texture = load("res://assets/textures/%s_nor.jpg" % stem)
	m.roughness_texture = load("res://assets/textures/%s_rough.jpg" % stem)
	m.albedo_color = tint
	m.roughness = roughness
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE * 0.45
	return m

func _mesh_from_model(model_name: String) -> Mesh:
	if _mesh_cache.has(model_name):
		return _mesh_cache[model_name]
	var path := "res://assets/models/%s/%s_1k.gltf" % [model_name, model_name]
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var root := packed.instantiate()
	var found: Mesh = null
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi and mi.mesh:
			found = mi.mesh
			break
	root.free()
	_mesh_cache[model_name] = found
	return found

func _load_tree_factory() -> void:
	# Keep the environment script independent from the factory's global class
	# cache: a fresh editor import can still use the fallback asset meshes while
	# the generated tree factory is compiling.
	var factory_script := load("res://scripts/saisies_trees.gd") as Script
	if factory_script == null:
		return
	var broad = factory_script.call("broadleaf_variants")
	var conifer = factory_script.call("conifer_variants")
	if broad is Array:
		_factory_broadleaf = broad
	if conifer is Array:
		_factory_conifer = conifer

func _build_foliage() -> void:
	var tree_meshes := {}
	var model_names: Array[String] = []
	if not _factory_broadleaf.is_empty() and not _factory_conifer.is_empty():
		for i in _factory_broadleaf.size():
			tree_meshes["broadleaf_%02d" % i] = _factory_broadleaf[i] as Mesh
		for i in _factory_conifer.size():
			tree_meshes["conifer_%02d" % i] = _factory_conifer[i] as Mesh
	else:
		# Fallback meshes keep the scene useful before the factory script has been
		# imported.  The deterministic factory is preferred once available.
		model_names = ["fir_sapling", "pine_sapling_small"]
		for name in model_names:
			tree_meshes[name] = null
	var items := {}
	for name in tree_meshes.keys():
		items[name] = []
	var grass_items := []
	var shrub_items := []
	var rock_items := []
	var s := 20.0
	while s < route.length_m - 10.0:
		var sec := route.section_at(s)
		var density := clampf(float(sec.get("tree_density", 0.0)), 0.0, 1.0)
		var biome := String(sec.get("biome", "meadow"))
		var count := 0
		if biome == "forest":
			# Forest sections should read as a continuous mixed woodland canopy:
			# 18--22 candidates per 25--42 m sample, with two lateral depth bands.
			count = maxi(10, int(round(lerpf(18.0, 22.0, density))))
		elif biome == "rock_cut":
			count = maxi(2, int(round(lerpf(2.0, 6.0, density))))
		else:
			count = 1 if _rng.randf() < density else 0
			if density > 0.7 and _rng.randf() < density * 0.68:
				count += 1
		for k in count:
			# Break the same-sample rows into a loose longitudinal scatter so a
			# dense forest reads as natural clusters instead of pickets.
			var tree_s := clampf(s + _rng.randf_range(-11.0, 11.0), 0.0, route.length_m)
			var side := 1.0 if _rng.randf() < 0.5 else -1.0
			var half := route.road_width_at(tree_s) * 0.5
			var near_road := _rng.randf() < (0.80 if biome == "forest" else 0.42)
			var outer := 20.0 if near_road else (62.0 if biome == "forest" else 72.0)
			var inner := half + (2.2 if near_road else 15.0)
			var u := side * _rng.randf_range(inner, outer)
			var p := route.pos_at(tree_s) + route.left_at(tree_s) * u
			p.y = route.ground_y(tree_s, u)
			var model := ""
			var scale := 1.0
			if not _factory_broadleaf.is_empty() and not _factory_conifer.is_empty():
				var broadleaf := biome == "forest" and _rng.randf() < 0.80
				var family_size := _factory_broadleaf.size() if broadleaf else _factory_conifer.size()
				var family := "broadleaf" if broadleaf else "conifer"
				model = "%s_%02d" % [family, _rng.randi_range(0, maxi(family_size - 1, 0))]
				scale = _rng.randf_range(0.72, 1.24)
			else:
				model = String(model_names[_rng.randi_range(0, model_names.size() - 1)])
			if biome == "forest" and _rng.randf() < 0.48 and tree_meshes.has("fir_sapling"):
				model = "fir_sapling"
				scale = _rng.randf_range(5.0, 10.5)
			elif _factory_broadleaf.is_empty() or _factory_conifer.is_empty():
				scale = _rng.randf_range(5.0, 10.5) if biome == "forest" else _rng.randf_range(3.2, 7.6)
			if near_road:
				scale *= _rng.randf_range(0.76, 1.0)
			items[model].append({"s": tree_s, "position": p, "scale": scale, "canopy_widen": biome == "forest", "yaw": _rng.randf() * TAU})
		if density > 0.18 and _rng.randf() < 0.85:
			var grass_side := 1.0 if _rng.randf() < 0.5 else -1.0
			var gu := grass_side * _rng.randf_range(route.road_width_at(s) * 0.5 + 2.0, 20.0)
			var gp := route.pos_at(s) + route.left_at(s) * gu
			gp.y = route.ground_y(s, gu) - 0.02
			grass_items.append({"s": s, "position": gp, "scale": _rng.randf_range(0.45, 1.45), "yaw": _rng.randf() * TAU})
		if density > 0.42 and _rng.randf() < 0.6:
			var shrub_side := 1.0 if _rng.randf() < 0.5 else -1.0
			var u2 := shrub_side * _rng.randf_range(route.road_width_at(s) * 0.5 + 2.0, 16.0)
			var sp := route.pos_at(s) + route.left_at(s) * u2
			sp.y = route.ground_y(s, u2)
			shrub_items.append({"s": s, "position": sp, "scale": _rng.randf_range(1.2, 2.8), "yaw": _rng.randf() * TAU})
		s += _rng.randf_range(25.0, 42.0)
	for name in tree_meshes.keys():
		var mesh: Mesh = tree_meshes[name] as Mesh
		if mesh == null:
			mesh = _mesh_from_model(String(name))
		if mesh:
			_spawn_model_chunks(mesh, items[name], "SaisiesTrees_%s" % name, 420.0)
	var grass_mesh := _mesh_from_model("grass_medium_01")
	if grass_mesh:
		_spawn_model_chunks(grass_mesh, grass_items, "SaisiesGrass", 300.0)
	var shrub_mesh := _mesh_from_model("shrub_02")
	if shrub_mesh:
		_spawn_model_chunks(shrub_mesh, shrub_items, "SaisiesShrubs", 360.0)

func _spawn_model_chunks(mesh: Mesh, items: Array, node_prefix: String, view_m: float) -> void:
	if mesh == null or items.is_empty():
		return
	var chunks := {}
	for item in items:
		var idx := int(floor(float(item["s"]) / chunk_length_m))
		if not chunks.has(idx):
			chunks[idx] = []
		chunks[idx].append(item)
	for idx in chunks.keys():
		var s_mid := minf((float(idx) + 0.5) * chunk_length_m, route.length_m)
		var origin := route.pos_at(s_mid)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = chunks[idx].size()
		for i in mm.instance_count:
			var item: Dictionary = chunks[idx][i]
			var scale := float(item["scale"])
			var scale_vector := Vector3.ONE * scale
			if bool(item.get("canopy_widen", false)):
				# Broaden the crown in XZ while preserving authored tree height so
				# the near-road canopy reaches over the asphalt without giant trunks.
				scale_vector = Vector3(scale * 1.2, scale, scale * 1.2)
			var basis := Basis(Vector3.UP, float(item["yaw"])).scaled(scale_vector)
			mm.set_instance_transform(i, Transform3D(basis, item["position"] - origin))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_%02d" % [node_prefix, int(idx)]
		mmi.multimesh = mm
		mmi.position = origin
		mmi.visibility_range_end = view_m
		add_child(mmi)

func _build_guardrails() -> void:
	var posts := []
	var rails := []
	var spacing := 12.0
	var s := 0.0
	var min_alignment := 1.0
	var min_span := INF
	var max_span := 0.0
	var rail_count := 0
	var post_count := 0
	while s < route.length_m - spacing:
		var sec := route.section_at(s + spacing * 0.5)
		var style := String(sec.get("guardrail", "none"))
		if style != "none":
			for side in [-1.0, 1.0]:
				if _side_allowed(style, side):
					var half := route.road_width_at(s) * 0.5
					var u: float = side * (half + 0.62)
					var p0: Vector3 = route.pos_at(s) + route.left_at(s) * u
					var p1: Vector3 = route.pos_at(s + spacing) + route.left_at(s + spacing) * u
					p0.y = route.ground_y(s, u) + 0.52
					p1.y = route.ground_y(s + spacing, u) + 0.52
					var post_basis := _upright_basis_between(p0, p1)
					posts.append({"position": p0, "basis": post_basis, "s": s})
					var rail_basis := _basis_between(p0, p1).scaled_local(Vector3(1.0, 1.0, p0.distance_to(p1)))
					var segment_direction := (p1 - p0).normalized()
					min_alignment = minf(min_alignment, absf((-rail_basis.z.normalized()).dot(segment_direction)))
					min_span = minf(min_span, rail_basis.z.length())
					max_span = maxf(max_span, rail_basis.z.length())
					rail_count += 2
					post_count += 1
					var center: Vector3 = (p0 + p1) * 0.5 + Vector3.UP * 0.28
					rails.append({"position": center, "basis": rail_basis, "s": s})
					# A second folded beam makes the roadside barrier read as the
					# broad silver W profile from the camera rather than a wire.
					var lower: Vector3 = (p0 + p1) * 0.5 + Vector3.UP * 0.08
					rails.append({"position": lower, "basis": rail_basis, "s": s})
		s += spacing
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.11, 1.05, 0.11)
	var rail_mesh := BoxMesh.new()
	rail_mesh.size = Vector3(0.12, 0.18, 1.0)
	_spawn_prop_chunks(post_mesh, posts, _materials["post"], "SaisiesGuardPosts", 600.0)
	_spawn_prop_chunks(rail_mesh, rails, _materials["rail"], "SaisiesGuardRails", 600.0)
	set_meta("saisies_guardrail_beams", rail_count)
	set_meta("saisies_guardrail_posts", post_count)
	set_meta("saisies_guardrail_min_alignment", min_alignment)
	set_meta("saisies_guardrail_min_span", min_span)
	set_meta("saisies_guardrail_max_span", max_span)
	set_meta("saisies_guardrail_post_upright", 1.0)

func _side_allowed(style: String, side: float) -> bool:
	if style == "both":
		return true
	if style == "left":
		return side > 0.0
	if style == "right":
		return side < 0.0
	return false

func _basis_between(a: Vector3, b: Vector3) -> Basis:
	var fwd := (b - a).normalized()
	return Basis.looking_at(fwd, Vector3.UP)

func _upright_basis_between(a: Vector3, b: Vector3) -> Basis:
	var fwd := b - a
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return Basis.IDENTITY
	return Basis.looking_at(fwd.normalized(), Vector3.UP)

func _spawn_prop_chunks(mesh: Mesh, items: Array, material: Material, prefix: String, view_m: float) -> void:
	if items.is_empty():
		return
	var chunks := {}
	for item in items:
		var idx := int(floor(float(item["s"]) / chunk_length_m))
		if not chunks.has(idx):
			chunks[idx] = []
		chunks[idx].append(item)
	for idx in chunks.keys():
		var origin := route.pos_at(minf((float(idx) + 0.5) * chunk_length_m, route.length_m))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = chunks[idx].size()
		for i in mm.instance_count:
			var item: Dictionary = chunks[idx][i]
			var instance_transform := Transform3D(item["basis"], item["position"] - origin)
			mm.set_instance_transform(i, instance_transform)
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_%02d" % [prefix, int(idx)]
		mmi.multimesh = mm
		mmi.position = origin
		mmi.visibility_range_end = view_m
		mmi.material_override = material
		add_child(mmi)

func _build_walls_and_rocks() -> void:
	var wall_items := []
	var rock_items := []
	var s := 0.0
	while s < route.length_m - 12.0:
		var sec := route.section_at(s + 6.0)
		var wall_side := String(sec.get("wall", "none"))
		if wall_side != "none":
			var side := 1.0 if wall_side == "left" else -1.0
			var u := side * (route.road_width_at(s) * 0.5 + 0.78)
			var p0 := route.pos_at(s) + route.left_at(s) * u
			var p1 := route.pos_at(s + 12.0) + route.left_at(s + 12.0) * u
			var h := 2.2 + 0.8 * (0.5 + 0.5 * sin(s * 0.019))
			p0.y = route.ground_y(s, u) + h * 0.5
			p1.y = route.ground_y(s + 12.0, u) + h * 0.5
			wall_items.append({"position": (p0 + p1) * 0.5, "basis": _basis_between(p0, p1).scaled_local(Vector3(0.82, h, p0.distance_to(p1))), "s": s})
		if String(sec.get("biome", "")) in ["rock_cut", "forest", "retaining_wall"] and _rng.randf() < 0.35:
			var rside := 1.0 if _rng.randf() < 0.5 else -1.0
			var ru := rside * _rng.randf_range(route.road_width_at(s) * 0.5 + 2.5, 12.0)
			var rp := route.pos_at(s) + route.left_at(s) * ru
			# Sink the boulder pivot slightly into the bank so contact shadows do
			# not leave a visible floating gap on the sloped landscape.
			rp.y = route.ground_y(s, ru) - 0.75
			rock_items.append({"s": s, "position": rp, "scale": _rng.randf_range(0.7, 2.0), "yaw": _rng.randf() * TAU})
		s += 12.0
	var wall_mesh := BoxMesh.new()
	wall_mesh.size = Vector3(1.0, 1.0, 1.0)
	_spawn_prop_chunks(wall_mesh, wall_items, _materials["stone"], "SaisiesRetainingWall", 500.0)
	var rock_mesh := _mesh_from_model("namaqualand_boulder_03")
	if rock_mesh:
		_spawn_model_chunks(rock_mesh, rock_items, "SaisiesRocks", 340.0)

func _build_chalets_and_landmarks() -> void:
	var s := 30.0
	while s < route.length_m - 20.0:
		var sec := route.section_at(s)
		var biome := String(sec.get("biome", "meadow"))
		var density := clampf(float(sec.get("chalet_density", 0.0)), 0.0, 1.0)
		var chance := density * (0.68 if biome == "village" else 0.50)
		if density > 0.0 and _rng.randf() < chance:
			var setback_min := 8.0 if biome == "village" else 12.0
			var setback_max := 16.0 if biome == "village" else 30.0
			_build_chalet(s, (-1.0 if _rng.randf() < 0.5 else 1.0) * _rng.randf_range(setback_min, setback_max), _rng.randi())
		if biome == "village":
			s += _rng.randf_range(28.0, 54.0)
		elif biome == "hamlet":
			s += _rng.randf_range(62.0, 104.0)
		else:
			s += _rng.randf_range(82.0, 126.0)
	for landmark in route.landmarks():
		if not (landmark is Dictionary):
			continue
		var d: Dictionary = landmark
		var ls := float(d.get("distance_m", d.get("distance", 0.0)))
		var side := -1.0 if String(d.get("side", "right")) == "right" else 1.0
		var u := side * float(d.get("offset_m", 7.0))
		match String(d.get("type", "sign")):
			"chalet": _build_chalet(ls, u, _rng.randi())
			"sign": _build_sign(ls, u, String(d.get("text", "COL DES SAISIES")))
			"power_pole": _build_power_pole(ls, u)
			"bus_stop": _build_bus_stop(ls, u)
			"rock": _build_landmark_rock(ls, u)

func _road_aligned_node(s: float, u: float) -> Node3D:
	var n := Node3D.new()
	n.position = route.pos_at(s) + route.left_at(s) * u
	n.position.y = route.ground_y(s, u)
	var fwd := route.tangent_at(s)
	n.basis = Basis.looking_at(fwd, Vector3.UP)
	add_child(n)
	return n

func _build_chalet(s: float, u: float, seed: int) -> void:
	var n := _road_aligned_node(clampf(s, 0.0, route.length_m), u)
	n.name = "SaisiesChalet_%03d" % seed
	var biome := String(route.section_at(s).get("biome", "hamlet"))
	var village := biome == "village"
	var stories: int = (2 + abs(seed) % 3) if village else (1 + abs(seed) % 2)
	var floor_h := 2.45
	var body_h := floor_h * float(stories)
	var width := (7.1 + float(abs(seed) % 4)) if village else (5.5 + float(abs(seed) % 3))
	var depth := (7.6 + float((abs(seed) / 3) % 3)) if village else (6.5 + float((abs(seed) / 3) % 3))
	var foundation_h := 1.55 if village else 1.35
	_part(n, _box(Vector3(width + 0.34, foundation_h, depth + 0.34)), _materials["stone"], Vector3(0.0, 0.0, 0.0))
	_part(n, _box(Vector3(width, body_h, depth)), _materials["cream"], Vector3(0.0, body_h * 0.5, 0.0))
	# Two dark roof slabs form the steep Alpine gable visible from bends.
	var roof_angle := deg_to_rad(28.0)
	var half_span := width * 0.5 + 0.3
	var slab_len := half_span / cos(roof_angle)
	var roof_center_x := half_span * 0.5
	var roof_eave_y := body_h + 0.12
	var roof_center_y := roof_eave_y + roof_center_x * tan(roof_angle)
	var roof_a := _box(Vector3(slab_len, 0.22, depth + 0.45))
	_part(n, roof_a, _materials["roof"], Vector3(-roof_center_x, roof_center_y, 0.0), Vector3(0.0, 0.0, roof_angle))
	var roof_b := _box(Vector3(slab_len, 0.22, depth + 0.45))
	_part(n, roof_b, _materials["roof"], Vector3(roof_center_x, roof_center_y, 0.0), Vector3(0.0, 0.0, -roof_angle))
	var ridge_y := roof_eave_y + half_span * tan(roof_angle)
	_part(n, _box(Vector3(0.38, 0.24, depth + 0.52)), _materials["roof"], Vector3(0.0, ridge_y, 0.0))
	for floor in stories:
		var balcony_y := floor_h * (float(floor) + 0.82)
		var balcony_w := width * (0.70 if village else 0.54)
		_part(n, _box(Vector3(balcony_w, 0.12, 0.16)), _materials["wood"], Vector3(0.0, balcony_y, depth * 0.52))
		_part(n, _box(Vector3(balcony_w, 0.12, 0.13)), _materials["wood"], Vector3(0.0, balcony_y + 0.62, depth * 0.52))
		_part(n, _box(Vector3(0.12, 0.62, 0.13)), _materials["wood"], Vector3(-balcony_w * 0.5, balcony_y + 0.31, depth * 0.52))
		_part(n, _box(Vector3(0.12, 0.62, 0.13)), _materials["wood"], Vector3(balcony_w * 0.5, balcony_y + 0.31, depth * 0.52))
	# Repeat dark openings on every storey so the resort blocks read as occupied
	# multi-level buildings rather than a ground-floor box with blank walls.
	for floor in stories:
		var window_y := floor_h * (float(floor) + 0.58)
		_part(n, _box(Vector3(0.95, 1.2, 0.08)), _materials["wood"], Vector3(-width * 0.22, window_y, depth * 0.505))
		_part(n, _box(Vector3(1.15, 1.25, 0.08)), _materials["wood"], Vector3(width * 0.22, window_y, depth * 0.505))

func _build_sign(s: float, u: float, text: String) -> void:
	var n := _road_aligned_node(clampf(s, 0.0, route.length_m), u)
	n.name = "SaisiesRoadSign"
	_part(n, _cylinder(0.045, 0.055, 1.8, 10), _materials["pole"], Vector3(0.0, 0.9, 0.0))
	_part(n, _box(Vector3(1.15, 0.42, 0.055)), _materials["sign"], Vector3(0.0, 1.72, 0.0))
	var label := Label3D.new()
	label.text = text
	label.font_size = 20
	label.pixel_size = 0.0014
	label.modulate = Color(0.15, 0.12, 0.06)
	label.position = Vector3(0.0, 1.72, -0.035)
	label.rotation_degrees.y = 180.0
	n.add_child(label)

func _build_power_pole(s: float, u: float) -> void:
	var n := _road_aligned_node(clampf(s, 0.0, route.length_m), u)
	n.name = "SaisiesPowerPole"
	_part(n, _cylinder(0.06, 0.08, 6.0, 10), _materials["pole"], Vector3(0.0, 3.0, 0.0))
	_part(n, _box(Vector3(2.6, 0.10, 0.10)), _materials["pole"], Vector3(0.0, 5.45, 0.0))
	# Two thin lines are enough to read as the roadside utility wire at this scale.
	for x in [-0.85, 0.85]:
		_part(n, _cylinder(0.012, 0.012, 1.0, 6), _materials["pole"], Vector3(x, 5.6, 0.0))

func _build_bus_stop(s: float, u: float) -> void:
	var n := _road_aligned_node(clampf(s, 0.0, route.length_m), u)
	n.name = "SaisiesBusStop"
	for x in [-1.1, 1.1]:
		_part(n, _cylinder(0.045, 0.055, 2.2, 10), _materials["wood"], Vector3(x, 1.1, 0.0))
	_part(n, _box(Vector3(2.7, 0.12, 1.5)), _materials["roof"], Vector3(0.0, 2.25, 0.0))
	_part(n, _box(Vector3(2.2, 0.75, 0.08)), _materials["wood"], Vector3(0.0, 0.65, 0.50))

func _build_landmark_rock(s: float, u: float) -> void:
	var mesh := _mesh_from_model("namaqualand_boulder_03")
	if mesh == null:
		return
	var p := route.pos_at(clampf(s, 0.0, route.length_m)) + route.left_at(s) * u
	p.y = route.ground_y(s, u) - 0.75
	var mi := MeshInstance3D.new()
	mi.name = "SaisiesLandmarkRock"
	mi.mesh = mesh
	mi.material_override = _materials["rock"]
	mi.position = p
	mi.scale = Vector3.ONE * 1.8
	add_child(mi)

func _build_mountain_layers() -> void:
	# Build low-poly ridge strips per 1 km route chunk. Their broad silhouettes are
	# blue-green and deliberately snow-free; the source video keeps snow peaks distant.
	for idx in range(int(ceil(route.length_m / 1000.0))):
		var s_mid := minf((float(idx) + 0.5) * 1000.0, route.length_m)
		var center := route.pos_at(s_mid)
		for layer in 3:
			var fwd := route.tangent_at(s_mid)
			var left := route.left_at(s_mid)
			var depth := 620.0 + layer * 430.0
			var origin := center + fwd * depth
			var mat: Material = _materials["mountain_near"] if layer == 0 else (_materials["mountain_mid"] if layer == 1 else _materials["mountain_far"])
			var mi := MeshInstance3D.new()
			mi.name = "SaisiesMountain_%02d_%d" % [idx, layer]
			mi.mesh = _ridge_mesh(origin, left, layer, idx)
			mi.material_override = mat
			mi.visibility_range_end = 3600.0
			add_child(mi)

func _ridge_mesh(origin: Vector3, left: Vector3, layer: int, idx: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var width := 2600.0 + layer * 550.0
	var step := 180.0
	var count := int(width / step)
	for i in range(count):
		var u0 := -width * 0.5 + float(i) * step
		var u1 := u0 + step
		var h0 := 210.0 + layer * 125.0 + 95.0 * sin((float(idx) * 0.8 + float(i)) * 0.73) + 32.0 * sin(float(i) * 1.9)
		var h1 := 210.0 + layer * 125.0 + 95.0 * sin((float(idx) * 0.8 + float(i + 1)) * 0.73) + 32.0 * sin(float(i + 1) * 1.9)
		var base := -90.0 - layer * 25.0
		var a := origin + left * u0 + Vector3.UP * base
		var b := origin + left * u1 + Vector3.UP * base
		var c := origin + left * u1 + Vector3.UP * (base + h1)
		var d := origin + left * u0 + Vector3.UP * (base + h0)
		st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
		st.add_vertex(a); st.add_vertex(c); st.add_vertex(d)
	st.generate_normals()
	return st.commit()

func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b

func _cylinder(top: float, bottom: float, height: float, segments := 10) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = height
	c.radial_segments = segments
	return c

func _part(parent: Node3D, mesh: Mesh, material: Material, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi
