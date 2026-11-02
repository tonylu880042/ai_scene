class_name SaisiesLowerScenery
extends Node3D

## Static lower-route dressing for the forest and valley end of the Saisies run.
##
## The route and camera remain authoritative.  This module only owns the dense
## forest corridor, profiled roadside cuts, the lower guardrail turns, and the
## small hamlet/junction landmarks from S10 through S18.  It deliberately uses
## MultiMesh chunks for trees and low-count authored meshes for landmarks so it
## can be enabled as one scene node without streaming code.

@export var route_path: NodePath
@export var player_path: NodePath
@export var random_seed := 1881
@export var lower_start_time_s := 395.0
@export var lower_end_time_s := 920.067
@export var chunk_length_m := 480.0
@export var view_distance_m := 1250.0
@export var build_foliage := true
@export var build_roadside_detail := true

const VIDEO_END_TIME_S := 920.067
const TREE_SPACING_M := 20.0
const PROP_SPACING_M := 11.0
const ACCEPTANCE_FOV_DEG := 78.0
const ACCEPTANCE_ASPECT := 16.0 / 9.0
const ACCEPTANCE_CAMERA_HEIGHT_M := 1.67
const LANDMARK_FRUSTUM_MARGIN_DEG := 2.0
const S17_HOUSE_U := 12.0
const S17_HEDGE_U := 7.0
const S17_SHED_U := -10.0
const S17_NOTICE_U := -5.5
const S17_HOUSE_S_OFFSET := 12.0
const S17_HEDGE_S_OFFSET := 6.0
const S18_HOUSE_U := 12.0
const S18_SIGN_U := 10.0
const S18_KIOSK_U := 10.0
const S18_HOUSE_S_OFFSET := 14.0
const S18_KIOSK_S_OFFSET := 7.0
const S18_SIGN_S_OFFSET := 5.0
const S16_SPEED_SIGN_U := -9.5
const LANDMARK_ROAD_MARGIN_M := 0.85

var route: SaisiesRoute
var player: Node3D
var scenery_ready := false
var lower_start_m := 0.0
var lower_end_m := 0.0

var _rng := RandomNumberGenerator.new()
var _materials := {}
var _mesh_cache := {}
var _factory_broadleaf: Array = []
var _factory_conifer: Array = []
var _shrub_mesh: Mesh
var _rock_face_01: Mesh
var _rock_face_02: Mesh

func _ready() -> void:
	route = get_node_or_null(route_path) as SaisiesRoute
	if route == null and get_parent() != null:
		route = get_parent().get_node_or_null("Route") as SaisiesRoute
	player = get_node_or_null(player_path) as Node3D
	if route == null:
		push_warning("SaisiesLowerScenery needs a SaisiesRoute at route_path")
		return
	if not route.route_ready():
		call_deferred("_retry_build")
		return
	_build()

func _retry_build() -> void:
	for _i in range(8):
		if route != null and route.route_ready():
			_build()
			return
		await get_tree().process_frame

func _build() -> void:
	if scenery_ready or route == null or not route.route_ready():
		return
	_rng.seed = random_seed
	lower_start_m = _s_at_time(lower_start_time_s)
	lower_end_m = _s_at_time(lower_end_time_s)
	_make_materials()
	_load_factory()
	_load_scenery_meshes()
	if build_foliage:
		_build_foliage()
		_build_s13_hero_forest()
	_build_understory()
	_build_s13_hero_understory()
	if build_roadside_detail:
		_build_rock_cuts()
		_build_guardrails()
		_build_lower_landmarks()
	scenery_ready = true
	set_meta("saisies_lower_scenery_ready", true)
	set_meta("saisies_lower_start_m", lower_start_m)
	set_meta("saisies_lower_end_m", lower_end_m)
	set_meta("saisies_lower_owns_foliage", build_foliage)
	set_meta("saisies_lower_owns_roadside_detail", build_roadside_detail)

func _s_at_time(seconds: float) -> float:
	if route == null:
		return 0.0
	var t := clampf(seconds, 0.0, VIDEO_END_TIME_S)
	# SharedRoute may expose the authoritative piecewise mapping.  Keep this
	# module compatible with the current route script by reading its normalized
	# checkpoint data when that helper is not present; the linear ratio is only a
	# last-resort fallback for an authored route with no telemetry.
	if route.has_method("distance_at_video_time"):
		return clampf(float(route.call("distance_at_video_time", t)), 0.0, route.length_m)
	var checkpoints = route.get("_checkpoints")
	if checkpoints is Array and checkpoints.size() >= 2:
		var first: Dictionary = checkpoints[0]
		if t <= float(first.get("video_seconds", 0.0)):
			return float(first.get("distance_m", 0.0))
		for i in range(checkpoints.size() - 1):
			var a: Dictionary = checkpoints[i]
			var b: Dictionary = checkpoints[i + 1]
			var ta := float(a.get("video_seconds", 0.0))
			var tb := float(b.get("video_seconds", VIDEO_END_TIME_S))
			if t <= tb:
				var span := maxf(tb - ta, 0.001)
				return lerpf(float(a.get("distance_m", 0.0)), float(b.get("distance_m", route.length_m)), (t - ta) / span)
		var last: Dictionary = checkpoints.back()
		return float(last.get("distance_m", route.length_m))
	return clampf(t / VIDEO_END_TIME_S * route.length_m, 0.0, route.length_m)

func _acceptance_distance(scene_id: String, fallback_seconds: float) -> float:
	if route != null and route.has_method("acceptance_distance"):
		return clampf(float(route.call("acceptance_distance", scene_id)), 0.0, route.length_m)
	return _s_at_time(fallback_seconds)

func _route_point(s: float, u: float, lift := 0.0) -> Vector3:
	var p := route.pos_at(clampf(s, 0.0, route.length_m)) + route.left_at(s) * u
	p.y = route.ground_y(s, u) + lift
	return p

func _make_materials() -> void:
	_materials["rock"] = _texture_mat("rock_boulder_dry", Color(0.58, 0.56, 0.50), 0.98)
	_materials["rock"].uv1_scale = Vector3.ONE * 0.18
	_materials["rock"].cull_mode = BaseMaterial3D.CULL_DISABLED
	_materials["rock_dark"] = _mat(Color(0.27, 0.28, 0.25), 0.98)
	_materials["rock_light"] = _mat(Color(0.53, 0.56, 0.52), 0.94)
	_materials["rail"] = _mat(Color(0.72, 0.78, 0.79), 0.30, 0.46)
	_materials["post"] = _mat(Color(0.40, 0.45, 0.46), 0.52, 0.38)
	_materials["soil"] = _texture_mat("rocky_trail", Color(0.72, 0.56, 0.39), 0.98)
	_materials["grass"] = _mat(Color(0.16, 0.32, 0.085), 0.98)
	_materials["grass_light"] = _mat(Color(0.23, 0.40, 0.12), 0.98)
	_materials["leaf_dark"] = _mat(Color(0.15, 0.30, 0.12), 0.98)
	_materials["wood"] = _texture_mat("brown_planks_09", Color(0.72, 0.50, 0.31), 0.87)
	_materials["wood_dark"] = _texture_mat("wood_planks_grey", Color(0.39, 0.35, 0.29), 0.92)
	_materials["plaster"] = _texture_mat("painted_plaster_wall", Color(1.16, 1.05, 0.86), 0.88)
	_materials["roof"] = _texture_mat("clay_roof_tiles_02", Color(0.50, 0.48, 0.43), 0.90)
	# The S18 branch is a paved road junction.  Keep its own road material
	# separate from the soil/rocky-trail surface used on the shoulders.
	_materials["asphalt"] = _texture_mat("asphalt_02", Color(0.48, 0.50, 0.48), 0.93)
	_materials["line"] = _mat(Color(0.90, 0.90, 0.83), 0.80)
	_materials["sign_white"] = _mat(Color(0.92, 0.91, 0.82), 0.74)
	_materials["sign_yellow"] = _mat(Color(0.90, 0.63, 0.13), 0.80)
	_materials["sign_red"] = _mat(Color(0.72, 0.045, 0.028), 0.72)
	_materials["sign_blue"] = _mat(Color(0.06, 0.25, 0.72), 0.72)
	_materials["wire"] = _mat(Color(0.10, 0.11, 0.10), 0.94)
	_materials["pole"] = _mat(Color(0.30, 0.24, 0.17), 0.96)

func _mat(color: Color, roughness := 0.82, metallic := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m

func _texture_mat(stem: String, tint: Color, roughness := 0.86) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://assets/textures/%s_diff.jpg" % stem)
	m.normal_enabled = true
	m.normal_texture = load("res://assets/textures/%s_nor.jpg" % stem)
	m.roughness_texture = load("res://assets/textures/%s_rough.jpg" % stem)
	m.albedo_color = tint
	m.roughness = roughness
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE * 0.42
	return m

func _load_factory() -> void:
	var factory_script := load("res://scripts/saisies_trees.gd") as Script
	if factory_script == null:
		return
	var broad = factory_script.call("broadleaf_variants")
	var conifer = factory_script.call("conifer_variants")
	if broad is Array:
		_factory_broadleaf = broad
	if conifer is Array:
		_factory_conifer = conifer

func _load_scenery_meshes() -> void:
	_shrub_mesh = _make_shrub_mesh()
	_rock_face_01 = _mesh_from_model("rock_face_01")
	_rock_face_02 = _mesh_from_model("rock_face_02")

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
		if mi != null and mi.mesh != null:
			found = mi.mesh
			break
	root.free()
	_mesh_cache[model_name] = found
	return found

func _build_foliage() -> void:
	if _factory_broadleaf.is_empty() or _factory_conifer.is_empty():
		return
	var tree_items := {}
	for i in _factory_broadleaf.size():
		if _factory_broadleaf[i] is Mesh:
			tree_items["broadleaf_%02d" % i] = []
	for i in _factory_conifer.size():
		if _factory_conifer[i] is Mesh:
			tree_items["conifer_%02d" % i] = []
	if tree_items.is_empty():
		return
	var s := lower_start_m
	var junction_s := _s_at_time(900.0)
	while s < lower_end_m - 12.0:
		var sec := route.section_at(s)
		var biome := String(sec.get("biome", "forest"))
		var density := clampf(float(sec.get("tree_density", 0.84)), 0.0, 1.0)
		var count := 17 if biome == "forest" else 12
		if biome == "rock_cut":
			count = 16
		if biome == "hamlet":
			count = 4
		count = maxi(2, int(round(float(count) * lerpf(0.78, 1.12, density))))
		for k in count:
			var uphill := String(sec.get("uphill_side", "right")) == "left"
			var uphill_side := 1.0 if uphill else -1.0
			var downhill_side := -uphill_side
			# S13 is a left-wall/right-slope cut.  Bias the downhill side so the
			# camera sees a continuous mixed forest depth instead of a neat row of
			# isolated trunks, while retaining uphill trees for the canopy overlap.
			var downhill_bias := 0.68 if biome == "rock_cut" else (0.57 if biome == "forest" else 0.50)
			var tree_s := clampf(s + _rng.randf_range(-12.0, 12.0), lower_start_m, lower_end_m)
			var side := downhill_side if _rng.randf() < downhill_bias else uphill_side
			# Keep a few thin-trunk windows on the downhill side.  The next row
			# still closes the canopy so the forest reads continuous from the road.
			var window := fmod(tree_s + float(k) * 17.0, 390.0) < 72.0
			if window and side != uphill_side and _rng.randf() < 0.26:
				continue
			var half := route.road_width_at(tree_s) * 0.5
			var near_road := _rng.randf() < 0.67
			var inner := half + (2.4 if near_road else 13.0)
			var outer := (27.0 if biome == "rock_cut" else 21.0) if near_road else (76.0 if biome != "hamlet" else 44.0)
			var u := side * _rng.randf_range(inner, outer)
			# Leave the S18 branch and sign corner readable.  The junction owns a
			# short lateral road opening, so forest instances must not grow through
			# its approach or across the bridge throat.
			if absf(tree_s - junction_s) < 34.0 and absf(u) < 28.0:
				continue
			var p := _route_point(tree_s, u, -0.34)
			var broad_probability := 0.88 if biome == "forest" else (0.84 if biome == "rock_cut" else 0.74)
			var broad := _rng.randf() < broad_probability
			var family_size := _factory_broadleaf.size() if broad else _factory_conifer.size()
			var family := "broadleaf" if broad else "conifer"
			var model := "%s_%02d" % [family, _rng.randi_range(0, maxi(family_size - 1, 0))]
			var scale := _rng.randf_range(0.74, 1.16)
			if not near_road:
				scale *= _rng.randf_range(0.95, 1.22)
			if family == "conifer":
				scale *= _rng.randf_range(0.92, 1.15)
			tree_items[model].append({
				"s": tree_s,
				"position": p,
				"scale": scale,
				"yaw": _rng.randf() * TAU
			})
		s += TREE_SPACING_M + _rng.randf_range(-4.0, 6.0)
	for model in tree_items.keys():
		var family := String(model).split("_")[0]
		var index := int(String(model).split("_")[1])
		var mesh: Mesh = (_factory_broadleaf[index] if family == "broadleaf" else _factory_conifer[index]) as Mesh
		_spawn_mesh_chunks(mesh, tree_items[model], "SaisiesLowerTrees_%s" % model, view_distance_m)
	set_meta("saisies_lower_tree_instance_count", _count_items(tree_items))

func _count_items(groups: Dictionary) -> int:
	var total := 0
	for group in groups.values():
		total += group.size()
	return total

func _build_s13_hero_forest() -> void:
	# Add a small shared-world hero cluster around the S13 camera instead of
	# relying only on the long-range spacing pass.  Trunks stay beyond the road
	# shoulder (u <= -7.6m); their crowns can still shade the downhill edge.
	if _factory_broadleaf.is_empty() or _factory_conifer.is_empty():
		return
	var s13 := _acceptance_distance("S13", 630.0)
	var specs := [
		{"offset": 12.5, "u": -8.4, "family": "broadleaf", "index": 1, "scale": 0.84},
		{"offset": 16.8, "u": -10.8, "family": "broadleaf", "index": 0, "scale": 1.24},
		{"offset": 21.4, "u": -7.6, "family": "broadleaf", "index": 2, "scale": 0.92},
		{"offset": 25.8, "u": -12.2, "family": "broadleaf", "index": 1, "scale": 1.30},
		{"offset": 29.4, "u": -16.4, "family": "conifer", "index": 0, "scale": 0.86},
		{"offset": 30.2, "u": -9.3, "family": "broadleaf", "index": 0, "scale": 1.08},
		{"offset": 34.5, "u": -15.0, "family": "broadleaf", "index": 2, "scale": 0.80}
	]
	var items := {}
	for i in _factory_broadleaf.size():
		items["broadleaf_%02d" % i] = []
	for i in _factory_conifer.size():
		items["conifer_%02d" % i] = []
	for i in range(specs.size()):
		var spec: Dictionary = specs[i]
		var family := String(spec["family"])
		var index := int(spec["index"])
		var key := "%s_%02d" % [family, index]
		var tree_s := clampf(s13 + float(spec["offset"]), lower_start_m, lower_end_m)
		var u := float(spec["u"])
		items[key].append({
			"s": tree_s,
			"position": _route_point(tree_s, u, -0.34),
			"scale": float(spec["scale"]),
			"yaw": fmod(float(i) * 1.71 + 0.42, TAU)
		})
	for model in items.keys():
		if items[model].is_empty():
			continue
		var family := String(model).split("_")[0]
		var index := int(String(model).split("_")[1])
		var mesh: Mesh = (_factory_broadleaf[index] if family == "broadleaf" else _factory_conifer[index]) as Mesh
		_spawn_mesh_chunks(mesh, items[model], "SaisiesS13HeroTrees_%s" % model, view_distance_m)
	set_meta("saisies_s13_hero_tree_count", specs.size())

func _build_understory() -> void:
	if _shrub_mesh == null:
		return
	var items := []
	var s := lower_start_m
	var junction_s := _s_at_time(900.0)
	while s < lower_end_m - 10.0:
		var sec := route.section_at(s)
		var density := clampf(float(sec.get("tree_density", 0.7)), 0.0, 1.0)
		for i in range(2 if density > 0.3 else 1):
			var side := 1.0 if _rng.randf() < 0.5 else -1.0
			var u := side * _rng.randf_range(route.road_width_at(s) * 0.5 + 2.2, 17.0)
			if absf(s - junction_s) < 36.0 and absf(u) < 28.0:
				continue
			items.append({
				"s": s,
				"position": _route_point(s, u, 0.16),
				"scale": Vector3(_rng.randf_range(0.65, 1.55), _rng.randf_range(0.38, 0.92), _rng.randf_range(0.65, 1.55)),
				"yaw": _rng.randf() * TAU,
				"material": _materials["grass"] if _rng.randf() < 0.72 else _materials["grass_light"]
			})
		s += _rng.randf_range(19.0, 34.0)
	_spawn_material_chunks(_shrub_mesh, items, "SaisiesLowerUnderstory", 640.0)

func _build_s13_hero_understory() -> void:
	if _shrub_mesh == null:
		return
	var s13 := _acceptance_distance("S13", 630.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed + 513
	var items := []
	for i in range(18):
		var tree_s := clampf(s13 + rng.randf_range(7.0, 42.0), lower_start_m, lower_end_m)
		var road_half := route.road_width_at(tree_s) * 0.5
		var u := -rng.randf_range(road_half + 2.4, 16.5)
		items.append({
			"s": tree_s,
			"position": _route_point(tree_s, u, 0.12),
			"scale": Vector3(rng.randf_range(0.72, 1.38), rng.randf_range(0.54, 1.05), rng.randf_range(0.72, 1.38)),
			"yaw": rng.randf() * TAU,
			"material": _materials["grass"] if i % 5 else _materials["grass_light"]
		})
	_spawn_material_chunks(_shrub_mesh, items, "SaisiesS13HeroUnderstory", 640.0)
	set_meta("saisies_s13_hero_understory_count", items.size())

func _make_shrub_mesh() -> Mesh:
	# Low fern-like blades keep the forest floor readable without the bright
	# ellipsoid blobs that read as floating props at S13/S16 distance.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(7):
		var angle := TAU * float(i) / 7.0
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var side := Vector3(-direction.z, 0.0, direction.x)
		var height := 0.62 + 0.08 * float(i % 3)
		var width := 0.48 + 0.05 * float((i + 1) % 3)
		var base := Vector3(0.0, 0.03, 0.0)
		var mid := direction * width * 0.48 + Vector3.UP * height * 0.48
		var tip := direction * width + Vector3.UP * height
		var left := mid - side * width * 0.24
		var right := mid + side * width * 0.24
		for vertex in [base, left, tip, base, tip, right]:
			st.set_uv(Vector2(vertex.x + 0.5, vertex.y))
			st.add_vertex(vertex)
	st.generate_normals()
	return st.commit()

func _spawn_mesh_chunks(mesh: Mesh, items: Array, prefix: String, visibility: float) -> void:
	if mesh == null or items.is_empty():
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
			var scale := float(item["scale"])
			var basis := Basis(Vector3.UP, float(item["yaw"])).scaled(Vector3.ONE * scale)
			mm.set_instance_transform(i, Transform3D(basis, item["position"] - origin))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_%02d" % [prefix, int(idx)]
		mmi.multimesh = mm
		mmi.position = origin
		mmi.visibility_range_end = visibility
		add_child(mmi)

func _spawn_material_chunks(mesh: Mesh, items: Array, prefix: String, visibility: float) -> void:
	if mesh == null or items.is_empty():
		return
	var chunks := {}
	for item in items:
		var idx := int(floor(float(item["s"]) / chunk_length_m))
		if not chunks.has(idx):
			chunks[idx] = []
		chunks[idx].append(item)
	for idx in chunks.keys():
		var origin := route.pos_at(minf((float(idx) + 0.5) * chunk_length_m, route.length_m))
		for material in [_materials["grass"], _materials["grass_light"]]:
			var filtered := []
			for item in chunks[idx]:
				if item["material"] == material:
					filtered.append(item)
			if filtered.is_empty():
				continue
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mesh
			mm.instance_count = filtered.size()
			for i in mm.instance_count:
				var item: Dictionary = filtered[i]
				var basis := Basis(Vector3.UP, float(item["yaw"])).scaled(item["scale"])
				mm.set_instance_transform(i, Transform3D(basis, item["position"] - origin))
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "%s_%02d_%s" % [prefix, int(idx), "dark" if material == _materials["grass"] else "light"]
			mmi.multimesh = mm
			mmi.material_override = material
			mmi.position = origin
			mmi.visibility_range_end = visibility
			add_child(mmi)

func _build_rock_cuts() -> void:
	# Keep the cuts local to the reference moments instead of blanketing an
	# entire forest segment.  S13 remains the tall left wall; the other cuts
	# are short exposed faces that let soil, grass and trees reappear between
	# rock corners.
	_add_rock_cut(_s_at_time(398.0), _s_at_time(428.0), -1.0, 4.6, 2.7, _rock_face_02)
	_add_rock_cut(_s_at_time(505.0), _s_at_time(530.0), -1.0, 2.2, 2.0, _rock_face_02)
	_add_rock_cut(_s_at_time(558.0), _s_at_time(594.0), -1.0, 2.6, 2.4, _rock_face_01)
	_add_rock_cut(_s_at_time(615.0), _s_at_time(666.0), 1.0, 8.6, 3.8, _rock_face_01)
	_add_rock_cut(_s_at_time(754.0), _s_at_time(785.0), -1.0, 3.3, 2.5, _rock_face_02)

func _add_rock_cut(s0: float, s1: float, side: float, height: float, depth: float, face_mesh: Mesh) -> void:
	# The photogrammetry chunks have useful detail but their imported bounds
	# leave fins and floating gaps when repeated.  Build one continuous,
	# triangulated cliff strip instead: its front follows the route, its back
	# follows the bank, and a varied top edge keeps the silhouette natural.
	var hero_cut := side > 0.0 and height >= 7.0
	# The tall S13 face needs actual rock columns, not a long extrusion with a
	# waved top edge.  Keep the smaller cuts lighter while giving S13 a 2--3m
	# break-up interval that remains inexpensive compared with the tree meshes.
	var sample_spacing := 2.6 if hero_cut else 5.2
	var sample_count := maxi(int(ceil((s1 - s0) / sample_spacing)), 2)
	var layer_t := [0.0, 0.18, 0.48, 0.75, 1.0]
	var front_layers: Array = []
	for _layer in layer_t:
		front_layers.append([])
	var back_lower: Array = []
	var back_top: Array = []
	for i in range(sample_count + 1):
		var s := lerpf(s0, s1, float(i) / float(sample_count))
		var half := route.road_width_at(s) * 0.5
		# One shared column value drives all vertical layers.  This keeps each
		# ledge aligned as a rock pillar, with narrower notches between pillars
		# instead of unrelated sinusoidal strips.
		var column_noise := 0.5 + 0.5 * sin(s * 0.37 + float(i) * 2.41 + 0.7 * sin(s * 0.11))
		var notch_noise := 0.5 + 0.5 * cos(s * 0.23 + float(i) * 1.73)
		var toe_offset := clampf(0.24 + (column_noise - 0.5) * 0.28, 0.16, 0.42)
		var mid_push := lerpf(0.30, 1.50, notch_noise)
		var top_push := lerpf(0.80, 3.00, column_noise)
		if not hero_cut:
			mid_push *= 0.62
			top_push *= 0.62
		var offsets := [
			toe_offset,
			toe_offset + mid_push * 0.36,
			toe_offset + mid_push,
			toe_offset + lerpf(mid_push, top_push, 0.58),
			toe_offset + top_push
		]
		var back_u := side * (half + depth + 0.40)
		var wave := 0.86 + 0.10 * sin(s * 0.031 + float(i) * 0.42) + 0.045 * sin(s * 0.089)
		if hero_cut:
			# Keep the top edge irregular, but let the column profile do the
			# majority of the visible shape work.
			wave += 0.13 * sin(s * 0.039 + float(i) * 0.91) + 0.06 * cos(s * 0.097)
			wave = clampf(wave, 0.62, 1.12)
		for layer_idx in range(layer_t.size()):
			var t := float(layer_t[layer_idx])
			var u := side * (half + float(offsets[layer_idx]))
			front_layers[layer_idx].append(_route_point(s, u, height * wave * t))
		back_lower.append(_route_point(s, back_u))
		back_top.append(_route_point(s, back_u, height * (wave * 0.68 + 0.10)))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(sample_count):
		var u0 := float(i) * 0.34
		var u1 := float(i + 1) * 0.34
		for layer_idx in range(layer_t.size() - 1):
			var v0 := 1.0 - float(layer_t[layer_idx])
			var v1 := 1.0 - float(layer_t[layer_idx + 1])
			_cliff_quad(st, front_layers[layer_idx][i], front_layers[layer_idx][i + 1], front_layers[layer_idx + 1][i + 1], front_layers[layer_idx + 1][i], Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1))
		_cliff_quad(st, front_layers.back()[i], front_layers.back()[i + 1], back_top[i + 1], back_top[i], Vector2(u0, 0.0), Vector2(u1, 0.0), Vector2(u1 + 0.18, 0.0), Vector2(u0 + 0.18, 0.0))
		_cliff_quad(st, back_top[i], back_top[i + 1], back_lower[i + 1], back_lower[i], Vector2(u0 + 0.18, 0.0), Vector2(u1 + 0.18, 0.0), Vector2(u1 + 0.18, 1.0), Vector2(u0 + 0.18, 1.0))
		_cliff_quad(st, front_layers[0][i], back_lower[i], back_lower[i + 1], front_layers[0][i + 1], Vector2(u0, 1.0), Vector2(u0 + 0.18, 1.0), Vector2(u1 + 0.18, 1.0), Vector2(u1, 1.0))
	# Close both ends with the full five-layer profile, then the top and toe.
	for layer_idx in range(1, layer_t.size() - 1):
		_cliff_triangle(st, front_layers[0][0], front_layers[layer_idx][0], front_layers[layer_idx + 1][0], Vector2(0.0, 1.0), Vector2(0.0, 1.0 - float(layer_t[layer_idx])), Vector2(0.0, 1.0 - float(layer_t[layer_idx + 1])))
	_cliff_triangle(st, front_layers[0][0], front_layers.back()[0], back_top[0], Vector2(0.0, 1.0), Vector2(0.0, 0.0), Vector2(0.18, 0.0))
	_cliff_triangle(st, front_layers[0][0], back_top[0], back_lower[0], Vector2(0.0, 1.0), Vector2(0.18, 0.0), Vector2(0.18, 1.0))
	var last := sample_count
	for layer_idx in range(1, layer_t.size() - 1):
		_cliff_triangle(st, front_layers[0][last], front_layers[layer_idx + 1][last], front_layers[layer_idx][last], Vector2(0.0, 1.0), Vector2(0.0, 1.0 - float(layer_t[layer_idx + 1])), Vector2(0.0, 1.0 - float(layer_t[layer_idx])))
	_cliff_triangle(st, front_layers[0][last], back_lower[last], back_top[last], Vector2(0.0, 1.0), Vector2(0.18, 1.0), Vector2(0.18, 0.0))
	_cliff_triangle(st, front_layers[0][last], back_top[last], front_layers.back()[last], Vector2(0.0, 1.0), Vector2(0.18, 0.0), Vector2(0.0, 0.0))
	st.generate_normals()
	var cliff_mesh := st.commit()
	if cliff_mesh == null:
		return
	# The imported rock-face material is an atlas for the source photogrammetry
	# mesh.  Its UV islands are meaningless on this newly authored strip and
	# produce the stretched rainbow triangles visible on every cut.  Use the
	# shared world-triplanar, repeatable rock material instead; it is independent
	# of the strip's authored UVs and keeps a consistent metre-scale surface.
	var rock_material: Material = _materials["rock"]
	cliff_mesh.surface_set_material(0, rock_material)
	var cliff := MeshInstance3D.new()
	cliff.name = "SaisiesLowerContinuousRockCut"
	cliff.mesh = cliff_mesh
	cliff.extra_cull_margin = 80.0
	cliff.visibility_range_end = view_distance_m
	add_child(cliff)

func _cliff_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, uv_a: Vector2, uv_b: Vector2, uv_c: Vector2, uv_d: Vector2) -> void:
	for vertex in [[a, uv_a], [b, uv_b], [c, uv_c], [a, uv_a], [c, uv_c], [d, uv_d]]:
		st.set_uv(vertex[1])
		st.add_vertex(vertex[0])

func _cliff_triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, uv_a: Vector2, uv_b: Vector2, uv_c: Vector2) -> void:
	for vertex in [[a, uv_a], [b, uv_b], [c, uv_c]]:
		st.set_uv(vertex[1])
		st.add_vertex(vertex[0])

func _build_guardrails() -> void:
	# These are the lower-route outer-edge runs visible in S10, S14, S15 and S16.
	# S11 intentionally has no continuous rail, matching the reference frame.
	_add_guardrail_chain(_s_at_time(392.0), _s_at_time(431.0), 1.0)
	_add_guardrail_chain(_s_at_time(660.0), _s_at_time(730.0), -1.0)
	_add_guardrail_chain(_s_at_time(748.0), _s_at_time(804.0), 1.0)
	_add_guardrail_chain(_s_at_time(824.0), _s_at_time(861.0), -1.0)
	# S18 opens into the side branch around 898..905s; keep the bridge rail
	# beyond that throat so it cannot cross the junction in the hero frame.
	_add_guardrail_chain(_s_at_time(905.0), _s_at_time(916.0), 1.0)

func _add_guardrail_chain(s0: float, s1: float, side: float) -> void:
	var posts := []
	var rails := []
	var s := s0
	while s < s1 - 1.0:
		var s1_local := minf(s + PROP_SPACING_M, s1)
		var half0 := route.road_width_at(s) * 0.5
		var half1 := route.road_width_at(s1_local) * 0.5
		var u0 := side * (half0 + 0.66)
		var u1 := side * (half1 + 0.66)
		var p0 := _route_point(s, u0, 0.54)
		var p1 := _route_point(s1_local, u1, 0.54)
		posts.append({"s": s, "position": p0, "basis": _upright_basis_between(p0, p1)})
		var beam_basis := _basis_between(p0, p1)
		var center := (p0 + p1) * 0.5 + Vector3.UP * 0.30
		rails.append({"s": s, "position": center, "basis": beam_basis.scaled_local(Vector3(1.0, 1.0, p0.distance_to(p1)))})
		var lower := (p0 + p1) * 0.5 + Vector3.UP * 0.09
		rails.append({"s": s, "position": lower, "basis": beam_basis.scaled_local(Vector3(1.0, 1.0, p0.distance_to(p1)))})
		s = s1_local
	var post_mesh := _box(Vector3(0.11, 1.08, 0.11))
	var rail_mesh := _box(Vector3(0.12, 0.18, 1.0))
	_spawn_prop_chunks(post_mesh, posts, _materials["post"], "SaisiesLowerRailPosts")
	_spawn_prop_chunks(rail_mesh, rails, _materials["rail"], "SaisiesLowerRailBeams")

func _spawn_prop_chunks(mesh: Mesh, items: Array, material: Material, prefix: String) -> void:
	if mesh == null or items.is_empty():
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
			mm.set_instance_transform(i, Transform3D(item["basis"], item["position"] - origin))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_%02d" % [prefix, int(idx)]
		mmi.multimesh = mm
		mmi.material_override = material
		mmi.position = origin
		mmi.visibility_range_end = view_distance_m
		add_child(mmi)

func _build_lower_landmarks() -> void:
	var s17 := _acceptance_distance("S17", 870.0)
	_build_chalet(s17 + S17_HOUSE_S_OFFSET, S17_HOUSE_U, false, 2)
	_build_hedge(s17 + S17_HEDGE_S_OFFSET, S17_HEDGE_U)
	_build_shed(s17 + 8.0, S17_SHED_U)
	_build_power_line(_s_at_time(852.0), _s_at_time(889.0), -1.0)
	_add_blue_notice(s17 + 4.0, S17_NOTICE_U)

	var s18 := _acceptance_distance("S18", 900.0)
	_build_chalet(s18 + S18_HOUSE_S_OFFSET, S18_HOUSE_U, false, 5)
	_build_junction_kiosk(s18 + S18_KIOSK_S_OFFSET, S18_KIOSK_U)
	_build_junction(s18)
	_add_direction_signs(s18 + S18_SIGN_S_OFFSET, S18_SIGN_U)
	_build_power_line(_s_at_time(884.0), _s_at_time(915.0), 1.0)

	var s16 := _acceptance_distance("S16", 840.0) + 10.0
	_add_speed_sign(s16, S16_SPEED_SIGN_U)
	_validate_landmark_clearance()
	_validate_landmark_camera_visibility()

func _road_aligned_node(s: float, u: float) -> Node3D:
	var n := Node3D.new()
	n.position = _route_point(s, u)
	n.basis = Basis.looking_at(route.tangent_at(s), Vector3.UP)
	add_child(n)
	return n

func _build_chalet(s: float, u: float, hotel: bool, salt: int) -> void:
	var n := _road_aligned_node(clampf(s, 0.0, route.length_m), u)
	n.name = "SaisiesLowerChalet_%02d" % salt
	var width := 8.4 if hotel else 6.7
	var depth := 7.0 if hotel else 5.8
	var stories := 2 if hotel else 1
	var body_h := 2.45 * float(stories)
	_part(n, _box(Vector3(width + 0.4, 0.54, depth + 0.42)), _materials["rock_light"], Vector3(0.0, 0.26, 0.0))
	_part(n, _box(Vector3(width, body_h, depth)), _materials["plaster"] if hotel else _materials["wood"], Vector3(0.0, 0.54 + body_h * 0.5, 0.0))
	var roof_angle := deg_to_rad(28.0)
	var half_span := width * 0.5 + 0.32
	var slab_len := half_span / cos(roof_angle)
	var body_top := 0.54 + body_h
	var roof_rise := half_span * tan(roof_angle)
	# Each slab is rotated around its centre.  Its centre therefore sits at
	# half the gable rise, instead of at the ridge, so the eaves meet the wall.
	var roof_y := body_top + roof_rise * 0.5 + 0.04
	_part(n, _box(Vector3(slab_len, 0.24, depth + 0.50)), _materials["roof"], Vector3(-half_span * 0.5, roof_y, 0.0), Vector3(0.0, 0.0, roof_angle))
	_part(n, _box(Vector3(slab_len, 0.24, depth + 0.50)), _materials["roof"], Vector3(half_span * 0.5, roof_y, 0.0), Vector3(0.0, 0.0, -roof_angle))
	var gable_material: Material = _materials["plaster"] if hotel else _materials["wood"]
	var gable := _gable_mesh(half_span * 2.0, roof_rise, 0.14)
	_part(n, gable, gable_material, Vector3(0.0, body_top, -(depth * 0.5 + 0.03)))
	_part(n, gable, gable_material, Vector3(0.0, body_top, depth * 0.5 + 0.03))
	for floor in stories:
		var y := 0.54 + float(floor) * 2.45 + 1.10
		_part(n, _box(Vector3(1.1, 1.10, 0.10)), _materials["wood_dark"], Vector3(-width * 0.23, y, depth * 0.51))
		_part(n, _box(Vector3(1.1, 1.10, 0.10)), _materials["wood_dark"], Vector3(width * 0.23, y, depth * 0.51))
		if not hotel:
			_part(n, _box(Vector3(width * 0.65, 0.11, 0.15)), _materials["wood_dark"], Vector3(0.0, y - 0.72, depth * 0.53))

func _build_shed(s: float, u: float) -> void:
	var n := _road_aligned_node(s, u)
	n.name = "SaisiesLowerWoodShed"
	_part(n, _box(Vector3(5.6, 2.25, 4.6)), _materials["wood_dark"], Vector3(0.0, 1.15, 0.0))
	_part(n, _box(Vector3(6.0, 0.20, 5.0)), _materials["roof"], Vector3(0.0, 2.42, 0.0), Vector3(0.0, 0.0, deg_to_rad(4.0)))
	_part(n, _box(Vector3(1.3, 1.65, 0.10)), _materials["wood"], Vector3(0.0, 0.90, 2.32))

func _build_junction_kiosk(s: float, u: float) -> void:
	var n := _road_aligned_node(s, u)
	n.name = "SaisiesLowerJunctionKiosk"
	_part(n, _box(Vector3(4.2, 2.05, 3.2)), _materials["wood_dark"], Vector3(0.0, 1.08, 0.0))
	_part(n, _box(Vector3(4.65, 0.20, 3.60)), _materials["roof"], Vector3(0.0, 2.22, 0.0), Vector3(0.0, 0.0, deg_to_rad(7.0)))
	_part(n, _box(Vector3(1.20, 1.32, 0.10)), _materials["wood"], Vector3(0.0, 0.76, 1.62))

func _build_hedge(s: float, u: float) -> void:
	var hedge_mesh := SphereMesh.new()
	hedge_mesh.radius = 0.82
	hedge_mesh.height = 1.5
	hedge_mesh.radial_segments = 8
	hedge_mesh.rings = 4
	hedge_mesh.material = _materials["leaf_dark"]
	var fwd := route.tangent_at(s)
	var left := route.left_at(s)
	for i in range(6):
		var p := _route_point(s + float(i - 2) * 2.8, u + sin(float(i) * 1.4) * 0.8, 0.72)
		var mi := MeshInstance3D.new()
		mi.name = "SaisiesLowerHedge"
		mi.mesh = hedge_mesh
		mi.position = p
		mi.scale = Vector3(1.15, 0.88, 1.0)
		mi.rotation.y = fwd.signed_angle_to(Vector3.FORWARD, Vector3.UP) + float(i) * 0.13
		add_child(mi)

func _build_power_line(s0: float, s1: float, side: float) -> void:
	var pole_s := s0
	var previous := Vector3.ZERO
	var have_previous := false
	while pole_s <= s1:
		var u := side * (route.road_width_at(pole_s) * 0.5 + 8.5)
		var base := _route_point(pole_s, u)
		_part(self, _cylinder(0.085, 0.12, 6.2, 10), _materials["pole"], base + Vector3.UP * 3.1)
		var top := base + Vector3.UP * 6.15
		if have_previous:
			_add_box_between(previous, top, 0.035, _materials["wire"], "SaisiesLowerPowerWire")
		previous = top
		have_previous = true
		pole_s += 27.0

func _add_blue_notice(s: float, u: float) -> void:
	var n := _road_aligned_node(s, u)
	n.name = "SaisiesLowerBlueNotice"
	_part(n, _cylinder(0.045, 0.065, 2.4, 8), _materials["post"], Vector3(0.0, 1.2, 0.0))
	_part(n, _box(Vector3(0.92, 0.92, 0.07)), _materials["sign_blue"], Vector3(0.0, 2.42, 0.0))

func _add_speed_sign(s: float, u: float) -> void:
	var n := _road_aligned_node(s, u)
	n.name = "SaisiesLowerSpeedLimit50"
	_part(n, _cylinder(0.055, 0.075, 2.35, 10), _materials["post"], Vector3(0.0, 1.18, 0.0))
	var rim := CylinderMesh.new()
	rim.top_radius = 0.62
	rim.bottom_radius = 0.62
	rim.height = 0.08
	rim.radial_segments = 32
	_part(n, rim, _materials["sign_red"], Vector3(0.0, 2.38, 0.0), Vector3(PI * 0.5, 0.0, 0.0))
	var face := CylinderMesh.new()
	face.top_radius = 0.51
	face.bottom_radius = 0.51
	face.height = 0.085
	face.radial_segments = 32
	_part(n, face, _materials["sign_white"], Vector3(0.0, 2.38, 0.045), Vector3(PI * 0.5, 0.0, 0.0))
	var label := Label3D.new()
	label.text = "50"
	label.font_size = 42
	label.pixel_size = 0.003
	label.modulate = Color(0.08, 0.08, 0.07)
	label.outline_size = 6
	label.outline_modulate = Color(0.78, 0.05, 0.04)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0.0, 2.38, 0.10)
	n.add_child(label)

func _add_direction_signs(s: float, u: float) -> void:
	var n := _road_aligned_node(s, u)
	n.name = "SaisiesLowerJunctionSigns"
	_part(n, _cylinder(0.055, 0.075, 3.15, 10), _materials["post"], Vector3(0.0, 1.58, 0.0))
	var signs := [
		{"text": "BEAUFORT", "pos": Vector3(-0.02, 2.72, 0.0), "rot": -0.10},
		{"text": "ARECHES", "pos": Vector3(0.15, 2.22, 0.0), "rot": 0.08},
		{"text": "D 925", "pos": Vector3(0.0, 3.18, 0.0), "rot": 0.0}
	]
	for item in signs:
		var board := _part(n, _box(Vector3(2.65 if item["text"] != "D 925" else 1.15, 0.32, 0.075)), _materials["sign_white"] if item["text"] != "D 925" else _materials["sign_yellow"], item["pos"], Vector3(0.0, 0.0, float(item["rot"])))
		var label := Label3D.new()
		label.text = item["text"]
		label.font_size = 20
		label.pixel_size = 0.0022
		label.modulate = Color(0.10, 0.10, 0.08)
		label.position = item["pos"] + Vector3(0.0, 0.0, -0.045)
		label.rotation_degrees.y = 180.0
		n.add_child(label)

func _build_junction(s: float) -> void:
	# The side road widens through the main-road throat so the junction reads
	# as one continuous paved surface rather than a gravel track.
	var p := _route_point(s, 0.0, 0.045)
	var branch_axis := route.left_at(s)
	var branch := MeshInstance3D.new()
	branch.name = "SaisiesLowerJunctionBranch"
	branch.mesh = _box(Vector3(7.6, 0.10, 36.0))
	branch.material_override = _materials["asphalt"]
	branch.position = p + branch_axis * 14.0
	branch.basis = Basis.looking_at(branch_axis, Vector3.UP)
	add_child(branch)
	var edge := _box(Vector3(0.11, 0.025, 32.0))
	for side in [-1.0, 1.0]:
		var line := MeshInstance3D.new()
		line.name = "SaisiesLowerJunctionEdge"
		line.mesh = edge
		line.material_override = _materials["line"]
		line.position = p + branch_axis * (14.0 + side * 3.68) + Vector3.UP * 0.12
		line.basis = Basis.looking_at(branch_axis, Vector3.UP)
		add_child(line)
	# A transverse give-way bar sits just beyond the main-road edge.  Short
	# centre dashes continue it up the branch without making the junction a
	# parking lot of painted slabs.
	var stop_line := MeshInstance3D.new()
	stop_line.name = "SaisiesLowerJunctionGiveWayLine"
	stop_line.mesh = _box(Vector3(7.1, 0.03, 0.18))
	stop_line.material_override = _materials["line"]
	stop_line.position = p + branch_axis * (route.road_width_at(s) * 0.5 + 0.78) + Vector3.UP * 0.13
	stop_line.basis = Basis.looking_at(branch_axis, Vector3.UP)
	add_child(stop_line)
	var dash := _box(Vector3(0.10, 0.025, 2.15))
	for i in range(4):
		var mark := MeshInstance3D.new()
		mark.name = "SaisiesLowerJunctionCentreMark"
		mark.mesh = dash
		mark.material_override = _materials["line"]
		mark.position = p + branch_axis * (8.0 + float(i) * 5.0) + Vector3.UP * 0.13
		mark.basis = Basis.looking_at(branch_axis, Vector3.UP)
		add_child(mark)
	# Short bridge rail at the scene endpoint makes the end read as a crossing.
	_add_guardrail_chain(s + 16.0, minf(s + 44.0, route.length_m - 1.0), 1.0)
	_add_guardrail_chain(s + 16.0, minf(s + 44.0, route.length_m - 1.0), -1.0)

func landmark_camera_visibility_ok() -> bool:
	if route == null or not route.route_ready():
		return false
	for item in _landmark_camera_visibility_report():
		if not bool(item["ok"]):
			return false
	return true

func _acceptance_camera_state(scene_id: String, fallback_seconds: float) -> Dictionary:
	var s := _acceptance_distance(scene_id, fallback_seconds)
	var tangent := route.tangent_at(s)
	var heading := atan2(-tangent.x, -tangent.z)
	var next_tangent := route.tangent_at(minf(s + 12.0, route.length_m))
	var next_heading := atan2(-next_tangent.x, -next_tangent.z)
	var turn := wrapf(next_heading - heading + PI, 0.0, TAU) - PI
	var pose: Dictionary = {"pitch_deg": -8.0, "yaw_deg": 0.0}
	if route.has_method("acceptance_pose"):
		var resolved = route.call("acceptance_pose", scene_id)
		if resolved is Dictionary:
			pose = resolved
	var pitch := deg_to_rad(float(pose.get("pitch_deg", -8.0)))
	var yaw := heading + deg_to_rad(float(pose.get("yaw_deg", 0.0)))
	var roll := clampf(-turn * 2.2, deg_to_rad(-5.0), deg_to_rad(5.0))
	return {
		"s": s,
		"position": _route_point(s, 0.0, ACCEPTANCE_CAMERA_HEIGHT_M),
		"basis": Basis.from_euler(Vector3(pitch, yaw, roll)),
		"pitch_deg": rad_to_deg(pitch),
		"yaw_offset_deg": float(pose.get("yaw_deg", 0.0)),
	}

func _camera_visibility_entry(label: String, scene_id: String, fallback_seconds: float, s: float, u: float, height: float) -> Dictionary:
	var camera := _acceptance_camera_state(scene_id, fallback_seconds)
	var point := _route_point(s, u, height)
	var local: Vector3 = camera["basis"].inverse() * (point - camera["position"])
	var depth := -local.z
	var yaw := atan2(local.x, depth)
	var pitch := atan2(local.y, depth)
	var vertical_half := deg_to_rad(ACCEPTANCE_FOV_DEG * 0.5)
	var horizontal_half := atan(tan(vertical_half) * ACCEPTANCE_ASPECT)
	var margin := deg_to_rad(LANDMARK_FRUSTUM_MARGIN_DEG)
	var ok := depth > 0.05 and absf(yaw) <= horizontal_half - margin and absf(pitch) <= vertical_half - margin
	return {
		"label": label,
		"scene": scene_id,
		"s": s,
		"u": u,
		"depth": depth,
		"yaw_deg": rad_to_deg(yaw),
		"pitch_deg": rad_to_deg(pitch),
		"ok": ok,
	}

func _landmark_camera_visibility_report() -> Array:
	var s16 := _acceptance_distance("S16", 840.0) + 10.0
	var s17 := _acceptance_distance("S17", 870.0)
	var s18 := _acceptance_distance("S18", 900.0)
	return [
		_camera_visibility_entry("S16 50 sign", "S16", 840.0, s16, S16_SPEED_SIGN_U, 2.38),
		_camera_visibility_entry("S17 chalet", "S17", 870.0, s17 + S17_HOUSE_S_OFFSET, S17_HOUSE_U, 3.35),
		_camera_visibility_entry("S17 hedge", "S17", 870.0, s17 + S17_HEDGE_S_OFFSET, S17_HEDGE_U, 1.20),
		_camera_visibility_entry("S18 chalet", "S18", 900.0, s18 + S18_HOUSE_S_OFFSET, S18_HOUSE_U, 3.35),
		_camera_visibility_entry("S18 kiosk", "S18", 900.0, s18 + S18_KIOSK_S_OFFSET, S18_KIOSK_U, 2.10),
		_camera_visibility_entry("S18 direction signs", "S18", 900.0, s18 + S18_SIGN_S_OFFSET, S18_SIGN_U, 3.18),
	]

func _validate_landmark_camera_visibility() -> void:
	var ok := landmark_camera_visibility_ok()
	set_meta("saisies_landmark_camera_visibility_ok", ok)
	if ok:
		return
	for item in _landmark_camera_visibility_report():
		if not bool(item["ok"]):
			push_error("Landmark is outside acceptance camera frustum: %s scene=%s depth=%.2f yaw=%.2f pitch=%.2f" % [item["label"], item["scene"], item["depth"], item["yaw_deg"], item["pitch_deg"]])
	assert(ok, "SaisiesLowerScenery landmark camera visibility failed")

func landmark_clearance_ok() -> bool:
	if route == null or not route.route_ready():
		return false
	for item in _landmark_clearance_report():
		if not bool(item["ok"]):
			return false
	return true

func _landmark_clearance_report() -> Array:
	var s17 := _acceptance_distance("S17", 870.0)
	var s18 := _acceptance_distance("S18", 900.0)
	var s16 := _acceptance_distance("S16", 840.0) + 10.0
	return [
		_clearance_entry("S17 chalet", s17 + S17_HOUSE_S_OFFSET, S17_HOUSE_U, 3.35),
		_clearance_entry("S17 hedge", s17 + S17_HEDGE_S_OFFSET, S17_HEDGE_U, 1.20),
		_clearance_entry("S17 shed", s17 + 8.0, S17_SHED_U, 2.80),
		_clearance_entry("S17 blue notice", s17 + 4.0, S17_NOTICE_U, 0.46),
		_clearance_entry("S16 50 sign", s16, S16_SPEED_SIGN_U, 0.70),
		_clearance_entry("S18 chalet", s18 + S18_HOUSE_S_OFFSET, S18_HOUSE_U, 3.35),
		_clearance_entry("S18 kiosk", s18 + S18_KIOSK_S_OFFSET, S18_KIOSK_U, 2.10),
		_clearance_entry("S18 direction signs", s18 + S18_SIGN_S_OFFSET, S18_SIGN_U, 1.33),
	]

func _clearance_entry(label: String, s: float, u: float, half_width: float) -> Dictionary:
	var distance := clampf(s, 0.0, route.length_m)
	var road_half := route.road_width_at(distance) * 0.5
	var object_edge := absf(u) - half_width
	return {
		"label": label,
		"s": distance,
		"u": u,
		"road_half": road_half,
		"object_edge": object_edge,
		"ok": object_edge >= road_half + LANDMARK_ROAD_MARGIN_M,
	}

func _validate_landmark_clearance() -> void:
	var ok := landmark_clearance_ok()
	set_meta("saisies_landmark_clearance_ok", ok)
	if ok:
		return
	for item in _landmark_clearance_report():
		if not bool(item["ok"]):
			push_error("Landmark intersects road: %s s=%.1f u=%.1f edge=%.2f road=%.2f" % [item["label"], item["s"], item["u"], item["object_edge"], item["road_half"]])
	assert(ok, "SaisiesLowerScenery landmark clearance failed")

func _add_box_between(a: Vector3, b: Vector3, thickness: float, material: Material, node_name: String) -> void:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = _box(Vector3(thickness, thickness, a.distance_to(b)))
	mi.material_override = material
	mi.position = (a + b) * 0.5
	mi.basis = _basis_between(a, b)
	add_child(mi)

func _basis_between(a: Vector3, b: Vector3) -> Basis:
	var fwd := (b - a).normalized()
	return Basis.looking_at(fwd, Vector3.UP)

func _upright_basis_between(a: Vector3, b: Vector3) -> Basis:
	var fwd := b - a
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return Basis.IDENTITY
	return Basis.looking_at(fwd.normalized(), Vector3.UP)

func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b

func _gable_mesh(width: float, rise: float, thickness: float) -> Mesh:
	# A thin triangular prism at each facade closes the roof silhouette while
	# leaving the chalet body as the structural volume.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var z := thickness * 0.5
	var back_left := Vector3(-width * 0.5, 0.0, -z)
	var back_right := Vector3(width * 0.5, 0.0, -z)
	var back_peak := Vector3(0.0, rise, -z)
	var front_left := Vector3(-width * 0.5, 0.0, z)
	var front_right := Vector3(width * 0.5, 0.0, z)
	var front_peak := Vector3(0.0, rise, z)
	# Front and back triangular faces.
	_gable_triangle(st, front_left, front_right, front_peak, width, rise)
	_gable_triangle(st, back_left, back_peak, back_right, width, rise)
	# Four narrow perimeter faces keep the gable visible from oblique views.
	_gable_triangle(st, back_left, front_left, front_peak, width, rise)
	_gable_triangle(st, back_left, front_peak, back_peak, width, rise)
	_gable_triangle(st, front_right, back_right, back_peak, width, rise)
	_gable_triangle(st, front_right, back_peak, front_peak, width, rise)
	_gable_triangle(st, back_left, back_right, front_right, width, rise)
	_gable_triangle(st, back_left, front_right, front_left, width, rise)
	st.generate_normals()
	return st.commit()

func _gable_triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, width: float, rise: float) -> void:
	var safe_rise := maxf(rise, 0.001)
	for vertex in [a, b, c]:
		st.set_uv(Vector2(vertex.x / maxf(width, 0.001) + 0.5, vertex.y / safe_rise))
		st.add_vertex(vertex)

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
