extends Node3D
# Streams CC0 Poly Haven grass/ferns (MultiMesh per chunk) and trees along the Route, a few chunks
# around the player at a time. Sea side is left empty on beach sections.

const MODEL := "res://assets/models/%s/%s_1k.gltf"

@export var path_node: NodePath      # the Route (Path3D with route.gd)
@export var player_path: NodePath
@export var chunk_length := 60.0
@export var chunks_ahead := 3
@export var chunks_behind := 2
@export var min_dist := 11.5         # keep the road clear (the road extends 10 m inland of the path)
@export var max_dist := 40.0
@export var view_distance := 120.0   # visibility_range_end for grass/ferns
@export var random_seed := 1
@export_group("Density (per chunk)")
@export var grass_per_mesh := 900    # for each of 4 grass variants
@export var fern_per_mesh := 25      # for each of 2 fern variants
@export var trees_per_chunk := 14
@export var tree_min_dist := 14.0
@export var tree_view_distance := 250.0
@export_group("Scenery (per chunk)")
@export var flower_patches := 4
@export var flowers_per_patch := 40  # for each of 7 flower variants
@export var flower_scale := Vector2(5.0, 8.0)
@export var rocks_per_chunk := 3     # boulders; small ones get +2
@export var fence_every := 3         # 1 chunk in N gets a wooden fence along the inland side
@export var fence_offset := 10.6      # metres inland from the road centre
@export var logwall_every := 4       # 1 chunk in N gets a timber-post retaining wall on the inland verge
@export var shore_rocks := 120       # dark riprap boulders along the waterline (low, sheltered sections)
@export var conifer_ratio := 0.6     # share of trees that are dark conifers
@export var conifer_scale := Vector2(0.5, 1.0)
@export_group("Scale jitter")
@export var grass_scale := Vector2(2.5, 4.0)
@export var fern_scale := Vector2(1.0, 1.8)
@export var tree_scale := Vector2(1.5, 2.6)

var _route: Route
var _player: Node3D
var _grass: Array[Mesh]
var _ferns: Array[Mesh]
var _trees: Array[Mesh]
var _flowers: Array[Mesh]
var _rocks_big: Array[Mesh]
var _rocks_small: Array[Mesh]
var _blobs: Array[Mesh]
var _log := CylinderMesh.new()
var _lamp: Mesh
var _post := BoxMesh.new()
var _rail := BoxMesh.new()
var _chunks := {}
var _t := 1.0

func _ready() -> void:
	_route = get_node(path_node)
	_player = get_node(player_path)
	_grass = _meshes("grass_medium_01", ["tall_a", "tall_b", "tall_c", "small_b"])
	_ferns = _meshes("fern_02", ["fern_02_a", "fern_02_d"])
	_trees = _meshes("island_tree_02", ["LOD0"])
	_flowers.append_array(_meshes("celandine_01", ["celandine_01_a", "celandine_01_b", "celandine_01_e"]))
	_flowers.append_array(_meshes("periwinkle_plant", ["plant_06", "plant_05"]))
	_flowers.append_array(_meshes("dandelion_01", ["dandelion_01_d", "dandelion_01_e"]))
	_rocks_big = _meshes("boulder_01", ["boulder_01"])
	_rocks_small = _meshes("namaqualand_boulder_03", ["boulder_03"])
	var wood := StandardMaterial3D.new()
	wood.albedo_texture = load("res://assets/textures/brown_planks_09_diff.jpg")
	wood.roughness_texture = load("res://assets/textures/brown_planks_09_rough.jpg")
	wood.normal_enabled = true
	wood.normal_texture = load("res://assets/textures/brown_planks_09_nor.jpg")
	wood.uv1_triplanar = true
	wood.uv1_world_triplanar = true
	var wood_dark := wood.duplicate() as StandardMaterial3D
	wood_dark.albedo_color = Color(0.55, 0.5, 0.45)
	_log.top_radius = 0.14
	_log.bottom_radius = 0.14
	_log.height = 1.15
	_log.radial_segments = 6
	_log.material = wood_dark
	for k in 5:
		_blobs.append(_make_tree(k < 3, 11 + k))
	_lamp = _make_lamp()
	for m in _rocks_big + _rocks_small:  # dark grey riprap instead of the orange source texture
		var rm := m.surface_get_material(0).duplicate() as StandardMaterial3D
		rm.albedo_color = Color(0.5, 0.5, 0.55)
		m.surface_set_material(0, rm)
	_post.size = Vector3(0.12, 1.1, 0.12)
	_post.material = wood
	_rail.size = Vector3(0.05, 0.08, 1.0)  # z is stretched to each span
	_rail.material = wood
	for m in _grass + _ferns:  # the source grass/fern textures are very dark; brighten them
		var mat := m.surface_get_material(0).duplicate() as StandardMaterial3D
		mat.albedo_color = Color(2.2, 2.2, 1.6)
		m.surface_set_material(0, mat)

func _process(delta: float) -> void:
	_t += delta
	if _t < 0.4:
		return
	_t = 0.0
	var c := int(_route.curve.get_closest_offset(_route.to_local(_player.global_position)) / chunk_length)
	for i in range(c - chunks_behind, c + chunks_ahead + 1):
		if i >= 0 and i * chunk_length < _route.length and not _chunks.has(i):
			_spawn(i)
	for i in _chunks.keys():
		if i < c - chunks_behind or i > c + chunks_ahead:
			_chunks[i].queue_free()
			_chunks.erase(i)

func _meshes(model: String, keys: Array) -> Array[Mesh]:
	var out: Array[Mesh] = []
	var root: Node = (load(MODEL % [model, model]) as PackedScene).instantiate()
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D"):
		for k: String in keys:
			if String(mi.name).contains(k):
				out.append(mi.mesh)
	root.free()
	return out

# world point beside the route at offset s (retries the left/sea side away on beach sections)
func _spot(rng: RandomNumberGenerator, s: float, dmin: float) -> Vector3:
	var side := 1.0 if rng.randf() < 0.5 and _route.sea_grass(s) else -1.0
	var u := side * lerpf(dmin, max_dist, pow(rng.randf(), 1.6))  # denser near the road
	var p := _route.pos_at(s) + _route.left_at(s) * u
	p.y = _route.ground_y(s, u)
	return p

func _spawn(idx: int) -> void:  # coroutine: one mesh type per frame to avoid hitches
	var holder := Node3D.new()
	add_child(holder)
	_chunks[idx] = holder
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed * 100003 + idx
	var s0 := idx * chunk_length
	var origin := _route.pos_at(s0 + chunk_length * 0.5)
	# alpine thinning: 1 = lush, -> 0 above the route's alpine_start (Summit): bare rock, no trees
	var veg := clampf(1.0 - (origin.y - _route.sea_y - _route.alpine_start) / _route.alpine_range, 0.05, 1.0)
	for set: Array in [[_grass, int(grass_per_mesh * veg), grass_scale], [_ferns, int(fern_per_mesh * veg), fern_scale]]:
		for m: Mesh in set[0]:
			_multimesh(holder, rng, s0, origin, m, set[1], set[2])
			await get_tree().process_frame
			if not is_instance_valid(holder):
				return
	for i in (trees_per_chunk if veg > 0.6 else 0):
		var tree := MeshInstance3D.new()
		var pine := rng.randf() < conifer_ratio
		tree.mesh = _blobs[rng.randi() % _blobs.size()] if pine else _trees[0]
		tree.position = _spot(rng, s0 + rng.randf() * chunk_length, tree_min_dist)
		tree.rotation.y = rng.randf() * TAU
		var sr := conifer_scale if pine else tree_scale
		tree.scale = Vector3.ONE * rng.randf_range(sr.x, sr.y)
		tree.visibility_range_end = tree_view_distance
		holder.add_child(tree)
	await get_tree().process_frame
	if not is_instance_valid(holder):
		return
	if veg > 0.5:
		_flower_patches(holder, rng, s0, origin)
	await get_tree().process_frame
	if not is_instance_valid(holder):
		return
	_rocks(holder, rng, s0, origin, 1.0 + (1.0 - veg) * 3.0)
	_fence(holder, idx, s0, origin)
	_logwall(holder, idx, s0, origin)
	_shore_rocks(holder, rng, s0, origin)
	_roadside(holder, s0, origin)

func _multimesh(holder: Node3D, rng: RandomNumberGenerator, s0: float, origin: Vector3, mesh: Mesh, count: int, scale_range: Vector2) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = count
	for i in count:
		var pos := _spot(rng, s0 + rng.randf() * chunk_length, min_dist) - origin
		var s := rng.randf_range(scale_range.x, scale_range.y)  # scale jitter
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s * rng.randf_range(0.8, 1.2), s, s * rng.randf_range(0.8, 1.2)))
		mm.set_instance_transform(i, Transform3D(basis, pos))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.position = origin
	mmi.visibility_range_end = view_distance
	holder.add_child(mmi)

func _new_mm(mesh: Mesh, count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = count
	return mm

func _add_mm(holder: Node3D, mm: MultiMesh, origin: Vector3, vis: float) -> void:
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.position = origin
	mmi.visibility_range_end = vis
	holder.add_child(mmi)

# instance i at route offset s, lateral u, with scale jitter and a little sink into the ground
func _put(mm: MultiMesh, i: int, rng: RandomNumberGenerator, s: float, u: float, origin: Vector3, scale_range: Vector2, sink: float) -> void:
	s = clampf(s, 0.0, _route.length)
	var p := _route.pos_at(s) + _route.left_at(s) * u
	p.y = _route.ground_y(s, u) - sink
	var k := rng.randf_range(scale_range.x, scale_range.y)
	var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * k)
	mm.set_instance_transform(i, Transform3D(basis, p - origin))

func _flower_patches(holder: Node3D, rng: RandomNumberGenerator, s0: float, origin: Vector3) -> void:
	var centres: Array[Vector2] = []
	for i in flower_patches:
		var side := 1.0 if rng.randf() < 0.5 and _route.sea_grass(s0) else -1.0
		centres.append(Vector2(s0 + rng.randf() * chunk_length, side * rng.randf_range(min_dist + 2.0, 20.0)))
	for m in _flowers:
		var mm := _new_mm(m, flower_patches * flowers_per_patch)
		for i in mm.instance_count:
			var c := centres[i % flower_patches]  # patchy meadow: scatter around a few centres
			_put(mm, i, rng, c.x + rng.randf_range(-6.0, 6.0), c.y + rng.randf_range(-6.0, 6.0), origin, flower_scale, 0.0)
		_add_mm(holder, mm, origin, view_distance * 0.7)

func _rocks(holder: Node3D, rng: RandomNumberGenerator, s0: float, origin: Vector3, mult: float) -> void:
	for set: Array in [[_rocks_big, rocks_per_chunk, Vector2(0.6, 1.6)], [_rocks_small, rocks_per_chunk + 2, Vector2(0.25, 0.6)]]:
		for m: Mesh in set[0]:
			var mm := _new_mm(m, int(set[1] * mult))
			for i in mm.instance_count:
				var u := (1.0 if rng.randf() < 0.5 and _route.sea_grass(s0) else -1.0) * rng.randf_range(min_dist, 28.0)  # never into the water
				_put(mm, i, rng, s0 + rng.randf() * chunk_length, u, origin, set[2], 0.15)
			_add_mm(holder, mm, origin, 200.0)

func _fence(holder: Node3D, idx: int, s0: float, origin: Vector3) -> void:
	if (idx + random_seed) % fence_every != 0:
		return
	var step := 3.0
	var n := int(chunk_length / step)
	var posts := _new_mm(_post, n + 1)
	var rails := _new_mm(_rail, n * 2)
	var prev := Vector3.ZERO
	for i in n + 1:
		var s := minf(s0 + i * step, _route.length)
		var p := _route.pos_at(s) - _route.left_at(s) * fence_offset  # inland = right of travel
		p.y = _route.ground_y(s, -fence_offset)
		posts.set_instance_transform(i, Transform3D(Basis.IDENTITY, p + Vector3(0, 0.5, 0) - origin))
		if i > 0:
			var d := p - prev
			for r in 2:
				var mid := (p + prev) * 0.5 + Vector3(0, 0.45 + 0.4 * r, 0) - origin
				rails.set_instance_transform((i - 1) * 2 + r, Transform3D(Basis.looking_at(d.normalized(), Vector3.UP).scaled_local(Vector3(1, 1, d.length())), mid))
		prev = p
	_add_mm(holder, posts, origin, view_distance)
	_add_mm(holder, rails, origin, view_distance)

# Leafy blob trees: overlapping noisy ellipsoids with a light/dark vertex-colour variation (tall = cypress,
# wide = round broadleaf). Much closer to a dense harbour-side tree than stacked cones.
func _make_tree(tall: bool, seed_: int) -> Mesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.22
	trunk.bottom_radius = 0.38
	trunk.height = 5.0 if tall else 4.5
	trunk.radial_segments = 6
	_add_arrays(st, trunk.get_mesh_arrays(), Vector3(0, trunk.height * 0.5, 0), Vector3.ONE, 0, func(_v, _h, _t): return Color(0.25, 0.17, 0.1))
	var sph := SphereMesh.new()
	sph.radius = 1.0
	sph.height = 2.0
	sph.radial_segments = 16
	sph.rings = 10
	var n := 9 if tall else 7
	for k in n:
		var t := float(k) / (n - 1)
		var r := (lerpf(2.2, 0.7, t) if tall else lerpf(3.4, 1.8, absf(t - 0.35))) * rng.randf_range(0.85, 1.15)
		var c := Vector3(rng.randf_range(-0.5, 0.5), (3.0 if tall else 4.5) + t * (11.0 if tall else 5.0), rng.randf_range(-0.5, 0.5))
		_add_arrays(st, sph.get_mesh_arrays(), c, Vector3(r, r * (1.5 if tall else 1.0), r), k + 1, func(v: Vector3, h: float, tt: float) -> Color:
			return Color(0.05, 0.22, 0.08).lerp(Color(0.2, 0.42, 0.16), clampf(0.3 * h + 0.45 * (v.y * 0.5 + 0.5) * (0.4 + t) + 0.15, 0.0, 1.0)))
	st.index()
	st.generate_normals()
	var m := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = load("res://assets/textures/aerial_grass_rock_diff.jpg")  # mottled leaf-like detail
	mat.albedo_color = Color(1.7, 1.8, 1.4)
	mat.uv1_triplanar = true
	mat.uv1_scale = Vector3.ONE * 0.45
	mat.roughness = 1.0
	m.surface_set_material(0, mat)
	return m

# append a mesh's triangles with per-vertex noise displacement and a colour from `col(v, hash, 0)`
func _add_arrays(st: SurfaceTool, arr: Array, c: Vector3, sc: Vector3, salt: int, col: Callable) -> void:
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var pts := PackedVector3Array()
	var cols := PackedColorArray()
	for v in verts:
		var h := fposmod(sin(v.x * 12.9898 + v.y * 78.233 + v.z * 37.719 + salt) * 43758.5453, 1.0)
		var bump := 1.0 if salt == 0 else 0.82 + 0.36 * h  # salt 0 = trunk (no displacement)
		pts.append(c + Vector3(v.x * sc.x * bump, v.y * sc.y * bump, v.z * sc.z * bump))
		cols.append(col.call(v, h, 0.0))
	for i in idx:
		st.set_color(cols[i])
		st.add_vertex(pts[i])

func _shore_rocks(holder: Node3D, rng: RandomNumberGenerator, s0: float, origin: Vector3) -> void:
	if _route.sea_grass(s0 + chunk_length * 0.5):  # cliff sections have no waterline nearby
		return
	for m in _rocks_small:
		var mm := _new_mm(m, shore_rocks)
		for i in mm.instance_count:
			var s := s0 + rng.randf() * chunk_length
			_put(mm, i, rng, s, maxf(_route.water_edge_u(s) + rng.randf_range(-1.5, 1.0), _route.road_left + 0.9), origin, Vector2(0.1, 0.24), 0.1)
		_add_mm(holder, mm, origin, 150.0)

func _logwall(holder: Node3D, idx: int, s0: float, origin: Vector3) -> void:
	if (idx + random_seed + 1) % logwall_every != 0:
		return
	var step := 0.34
	var n := int(chunk_length / step)
	var logs := _new_mm(_log, n)
	for i in n:
		var s := minf(s0 + i * step, _route.length)
		var p := _route.pos_at(s) - _route.left_at(s) * 10.4
		p.y = _route.ground_y(s, -10.4) + 0.5
		logs.set_instance_transform(i, Transform3D(Basis.IDENTITY, p - origin))
	_add_mm(holder, logs, origin, view_distance)
	var rails := _new_mm(_rail, int(chunk_length / 3.0))  # timber handrail on top
	var prev := Vector3.ZERO
	for i in rails.instance_count + 1:
		var s := minf(s0 + i * 3.0, _route.length)
		var p := _route.pos_at(s) - _route.left_at(s) * 10.4
		p.y = _route.ground_y(s, -10.4) + 1.25
		if i > 0:
			var d := p - prev
			rails.set_instance_transform(i - 1, Transform3D(Basis.looking_at(d.normalized(), Vector3.UP).scaled_local(Vector3(1, 1.5, d.length())), (p + prev) * 0.5 - origin))
		prev = p
	_add_mm(holder, rails, origin, view_distance)

# street lamps along the inland road edge (nothing stands on the road surface)
func _roadside(holder: Node3D, s0: float, origin: Vector3) -> void:
	var nl := int(chunk_length / 40.0) + 1
	var lamps := _new_mm(_lamp, nl)
	for i in nl:
		var s := minf(s0 + i * 40.0, _route.length - 2.0)
		var p := _route.pos_at(s) - _route.left_at(s) * 10.5
		var t := (_route.pos_at(s + 1.5) - _route.pos_at(s)).normalized()
		lamps.set_instance_transform(i, Transform3D(Basis.looking_at(t, Vector3.UP), p - origin))
	_add_mm(holder, lamps, origin, 200.0)

func _make_lamp() -> Mesh:  # pole + arm toward the road (-X = travel-left) + lamp head
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pole := CylinderMesh.new()
	pole.top_radius = 0.07
	pole.bottom_radius = 0.1
	pole.height = 8.0
	pole.radial_segments = 6
	st.append_from(pole, 0, Transform3D(Basis.IDENTITY, Vector3(0, 4.0, 0)))
	var arm := BoxMesh.new()
	arm.size = Vector3(2.2, 0.1, 0.1)
	st.append_from(arm, 0, Transform3D(Basis.IDENTITY, Vector3(-1.1, 7.9, 0)))
	var head := BoxMesh.new()
	head.size = Vector3(0.9, 0.16, 0.3)
	st.append_from(head, 0, Transform3D(Basis.IDENTITY, Vector3(-2.2, 7.85, 0)))
	var m := st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.57, 0.6)
	mat.metallic = 0.4
	mat.roughness = 0.5
	m.surface_set_material(0, mat)
	return m
