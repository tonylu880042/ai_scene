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
@export var shrubs_per_mesh := 0     # for each variant of shrub_model (0 = off)
@export var shrub_model := "shrub_02"
@export var shrub_scale := Vector2(0.8, 1.6)
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
@export var spruce := false          # alpine spruces (tiered dark cones) instead of the leafy harbour trees
@export var tree_cluster := 5         # fir_models: saplings per tree spot
@export var fir_tint := Color(0.5, 0.6, 0.46)  # darkens the scanned fir/pine foliage
@export var blob_tint := Color(1, 1, 1)         # multiplies the procedural leafy/cypress trees (Mediterranean: dark olive)
@export var snow_load := 0.0         # procedural spruces: 0 green .. 1 every branch tier white with snow on top
@export var birches := false         # the broadleaf trees are bare, frosted birches (winter) instead of the scanned tree
@export var autumn_share := 0.0      # share of broadleaf trees in autumn colours (yellow beech, orange, red maple)
@export var forest_mix := false      # weissensee: the video's species per section (beech / spruce / larch shares, hazel, reeds,
                                     # logs, scree from the sections file) as procedural meshes, instead of the scanned leafy tree
@export var fir_models := false      # real Poly Haven fir/pine saplings (scaled up) instead of the procedural spruces
@export var lamps := true            # street lamps along the inland road edge
@export var rock_scale_mult := 1.0   # alpine: bigger boulders
@export var meadow_clumps := 0       # per chunk: cheap procedural grass clumps that fill the meadow (0 = off)
@export var clump_view := 90.0
@export var clump_scale := Vector2(0.35, 0.8)
@export_group("Scale jitter")
@export var grass_scale := Vector2(2.5, 4.0)
@export var fern_scale := Vector2(1.0, 1.8)
@export var tree_scale := Vector2(1.5, 2.6)

var _route: Route
var _player: Node3D
var _grass: Array[Mesh]
var _ferns: Array[Mesh]
var _shrubs: Array[Mesh]
var _trees: Array[Mesh]
var _trees_autumn: Array[Mesh] = []
var _beech_green: Array[Mesh] = []
var _beech_yellow: Array[Mesh] = []
var _fspruce: Array[Mesh] = []   # forest spruce: bare lower trunk, narrow crown
var _larch: Array[Mesh] = []
var _hazel_green: Array[Mesh] = []
var _hazel_yellow: Array[Mesh] = []
var _reed: Mesh
var _bark_beech: StandardMaterial3D
var _logm: Mesh
var _flowers: Array[Mesh]
var _rocks_big: Array[Mesh]
var _rocks_small: Array[Mesh]
var _blobs: Array[Mesh]
var _birch: Array[Mesh] = []
var _autumn: Array[Mesh] = []  # rust and yellow copies of the leafy crowns (autumn scrub on the cliffs)
var _clump: Mesh
var _root_mesh: Mesh
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
	if shrubs_per_mesh > 0:
		_shrubs = _meshes(shrub_model, [shrub_model.get_slice("_", 0)])  # every mesh of the model
	_trees = _meshes("island_tree_02", ["LOD0"])
	for tint in [Color(1.5, 1.3, 0.35), Color(1.45, 1.15, 0.3), Color(1.6, 0.85, 0.3), Color(1.5, 0.45, 0.3)]:  # yellow x2, orange, red
		var m := _trees[0].duplicate() as Mesh
		for si in m.get_surface_count():
			var mat := m.surface_get_material(si)
			if mat.resource_name.contains("leaves"):
				mat = mat.duplicate()
				mat.albedo_color *= tint
				m.surface_set_material(si, mat)
		_trees_autumn.append(m)
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
	if fir_models:
		_blobs.append_array(_meshes("fir_sapling", ["fir_sapling_a", "fir_sapling_b", "fir_sapling_c"]))
		_blobs.append_array(_meshes("pine_sapling_small", ["sapling_small_a", "sapling_small_b", "sapling_small_c"]))
		for m in _blobs:  # deeper green: multiply the scanned foliage/trunk materials
			for s in m.get_surface_count():
				var tm := m.surface_get_material(s).duplicate() as StandardMaterial3D
				tm.albedo_color = fir_tint
				m.surface_set_material(s, tm)
	else:
		for k in 5:
			_blobs.append(_make_spruce(21 + k) if spruce else _make_tree(k < 3, 11 + k))
	if birches:
		for k in 4:
			_birch.append(_make_birch(51 + k))
	for tint in [Color(1.5, 0.75, 0.45), Color(1.3, 1.1, 0.45)]:
		var m := _blobs[0].duplicate() as Mesh
		for si in m.get_surface_count():
			var mat := m.surface_get_material(si).duplicate() as StandardMaterial3D
			mat.albedo_color *= tint
			m.surface_set_material(si, mat)
		_autumn.append(m)
	if forest_mix:  # leaf colours (linear vertex colours) picked from the video's beech: fresh green .. yellow .. orange
		_leaf_mat_cards = _card_mat(_leaf_atlas())
		_needle_mat_cards = _card_mat(_needle_atlas())
		_bark_beech = _bark_mat("japanese_sycamore")
		_bark_beech.albedo_color = Color(0.6, 0.6, 0.58)  # beech bark is mid grey; the scan is nearly white
		for k in 3:
			_beech_green.append(_make_beech(61 + k, [Color(0.1, 0.26, 0.03), Color(0.26, 0.4, 0.05), Color(0.16, 0.32, 0.04)][k]))
		for k in 4:
			_beech_yellow.append(_make_beech(71 + k, [Color(0.7, 0.5, 0.03), Color(0.5, 0.48, 0.05), Color(0.75, 0.3, 0.03), Color(0.62, 0.42, 0.04)][k]))
		var spruce_bark := _bark_mat("knotted_pine_bark")
		for k in 3:
			_fspruce.append(_make_conifer(81 + k, 0.45, [Color(0.01, 0.035, 0.012), Color(0.03, 0.09, 0.025), Color(0.07, 0.17, 0.04)], 1.0, spruce_bark))
		for k in 2:
			_larch.append(_make_conifer(91 + k, 0.4, [Color(0.15, 0.09, 0.01), Color(0.45, 0.3, 0.03), Color(0.7, 0.48, 0.07)], 0.75, _bark_mat("pine_bark")))
		for k in 2:
			_hazel_green.append(_make_hazel(101 + k, Color(0.2, 0.36, 0.05)))
			_hazel_yellow.append(_make_hazel(111 + k, Color(0.62, 0.5, 0.06)))
		_reed = _make_reeds(121)
		_logm = _make_log()
	if meadow_clumps > 0:
		_clump = _make_clump()
	_lamp = _make_lamp()
	var grey := {}
	for m in _rocks_big + _rocks_small:  # grey granite: the source rock texture is orange, so desaturate it
		var rm := m.surface_get_material(0).duplicate() as StandardMaterial3D
		var src := rm.albedo_texture
		if not grey.has(src):
			var img := src.get_image()
			img.decompress()
			img.convert(Image.FORMAT_L8)
			grey[src] = ImageTexture.create_from_image(img)
		rm.albedo_texture = grey[src]
		rm.albedo_color = Color(0.62, 0.62, 0.64)
		m.surface_set_material(0, rm)
	_post.size = Vector3(0.12, 1.1, 0.12)
	_post.material = wood
	_rail.size = Vector3(0.05, 0.08, 1.0)  # z is stretched to each span
	_rail.material = wood
	for m in _grass + _ferns:  # the source grass/fern textures are very dark; brighten them
		var mat := m.surface_get_material(0).duplicate() as StandardMaterial3D
		mat.albedo_color = Color(2.2, 2.2, 1.6) if not (forest_mix and m in _ferns) else Color(1.1, 1.15, 0.9)  # shaded forest ferns
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
	var we := _route.water_edge_u(s) - 0.5
	var low_bank := forest_mix and we > _route.half_left(s) + 1.0  # weissensee: lawn / herbs reach down to the waterline
	var side := 1.0 if rng.randf() < 0.5 and (_route.sea_grass(s) or low_bank) else -1.0
	var u := side * lerpf(dmin, max_dist, pow(rng.randf(), 1.6))  # denser near the road
	if low_bank and side > 0.0:
		u = lerpf(dmin, we, rng.randf())
	if spruce:  # alpine: plants may crowd right up to the (variable-width) trail edge, but not onto it
		var edge := (_route.half_left(s) if side > 0.0 else _route.half_right(s)) + 0.2
		u = side * maxf(absf(u), edge + rng.randf() * 0.4)
	else:  # never on the road / path (sections can widen it with a car lane)
		u = side * maxf(absf(u), (_route.half_left(s) if side > 0.0 else _route.half_right(s)) + 0.6)
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
	var veg := clampf(1.0 - (origin.y - _route.water_level(s0 + chunk_length * 0.5) - _route.alpine_start) / _route.alpine_range, 0.05, 1.0)
	var sec := _route.section_at(s0 + chunk_length * 0.5)
	var sm := float(sec.get("trees", 1.0))  # scene section: village 0 .. olive terraces 1.6
	var gm := float(sec.get("grass", sm))  # ground plants (forest_mix: grass on meadows, little under a closed canopy)
	var fm := float(sec.get("ferns", sm))
	for set: Array in [[_grass, int(grass_per_mesh * veg * gm), grass_scale], [_ferns, int(fern_per_mesh * veg * fm), fern_scale], [_shrubs, int(shrubs_per_mesh * veg * sm), shrub_scale]]:
		for m: Mesh in set[0]:
			_multimesh(holder, rng, s0, origin, m, set[1], set[2])
			await get_tree().process_frame
			if not is_instance_valid(holder):
				return
	if meadow_clumps > 0:
		_multimesh(holder, rng, s0, origin, _clump, int(meadow_clumps * veg * float(sec.get("clumps", sm))), clump_scale, clump_view)
		await get_tree().process_frame
		if not is_instance_valid(holder):
			return
	if forest_mix:
		_forest(holder, rng, s0, origin, sec)
	for i in (int(trees_per_chunk * sm) if veg > 0.6 and not forest_mix else 0):
		var pine := rng.randf() < conifer_ratio
		var spot := _spot(rng, s0 + rng.randf() * chunk_length, tree_min_dist)
		var sr := conifer_scale if pine else tree_scale
		var n := tree_cluster if (pine and fir_models) else 1  # saplings are sparse, so a stand of a few reads as one full tree
		for k in n:
			var tree := MeshInstance3D.new()
			tree.mesh = _blobs[rng.randi() % _blobs.size()] if pine else _broadleaf(rng)
			var off := Vector3(rng.randf_range(-2.6, 2.6), 0, rng.randf_range(-2.6, 2.6)) if k > 0 else Vector3.ZERO
			tree.position = spot + off
			tree.rotation.y = rng.randf() * TAU
			var sc := rng.randf_range(sr.x, sr.y) * (1.0 if k == 0 else rng.randf_range(0.7, 0.95))
			tree.scale = Vector3(sc * rng.randf_range(1.0, 1.25), sc, sc * rng.randf_range(1.0, 1.25))
			tree.visibility_range_end = tree_view_distance
			holder.add_child(tree)
	await get_tree().process_frame
	if not is_instance_valid(holder):
		return
	if veg > 0.5 and sm > 0.0:
		_flower_patches(holder, rng, s0, origin)
	await get_tree().process_frame
	if not is_instance_valid(holder):
		return
	_rocks(holder, rng, s0, origin, (1.0 + (1.0 - veg) * 3.0) * minf(sm, 1.0))
	_bank_plants(holder, rng, s0, origin)
	_cliff_plants(holder, rng, s0, origin)
	if spruce:
		_trail_debris(holder, rng, s0, origin)
	_fence(holder, idx, s0, origin)
	_logwall(holder, idx, s0, origin)
	_shore_rocks(holder, rng, s0, origin)
	if lamps:
		_roadside(holder, s0, origin)

func _broadleaf(rng: RandomNumberGenerator) -> Mesh:
	if birches:
		return _birch[rng.randi() % _birch.size()]
	if autumn_share > 0.0 and rng.randf() < autumn_share:  # no rng draw at 0: other scenes keep their tree layout
		return _trees_autumn[rng.randi() % _trees_autumn.size()]
	return _trees[0]

func _multimesh(holder: Node3D, rng: RandomNumberGenerator, s0: float, origin: Vector3, mesh: Mesh, count: int, scale_range: Vector2, vis := -1.0) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = count
	for i in count:
		var pos := _spot(rng, s0 + rng.randf() * chunk_length, min_dist) - origin
		var s := rng.randf_range(scale_range.x, scale_range.y)  # scale jitter
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled_local(Vector3(s * rng.randf_range(0.8, 1.2), s, s * rng.randf_range(0.8, 1.2)))
		mm.set_instance_transform(i, Transform3D(basis, pos))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.position = origin
	mmi.visibility_range_end = view_distance if vis < 0.0 else vis
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
	var clear := 0.3 if spruce else 0.6  # bare verge beside the walking surface (alpine: grass may crowd the edge)
	var hl := _route.half_left(s)
	var hr := _route.half_right(s)
	if u > -hr - clear and u < hl + clear:
		u = (hl + clear) if u >= 0.0 else -(hr + clear)
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
	# [meshes, count, scale range, min distance from the centre line]: boulders keep clear of the walked line
	for set: Array in [[_rocks_big, rocks_per_chunk, Vector2(0.6, 1.6) * rock_scale_mult, maxf(min_dist, 2.0 + 1.6 * rock_scale_mult)],
			[_rocks_small, rocks_per_chunk + 2, Vector2(0.25, 0.6) * rock_scale_mult, maxf(min_dist, 1.2 + 0.6 * rock_scale_mult)]]:
		for m: Mesh in set[0]:
			var mm := _new_mm(m, int(set[1] * mult))
			for i in mm.instance_count:
				var u := (1.0 if rng.randf() < 0.5 and _route.sea_grass(s0) else -1.0) * rng.randf_range(set[3], 28.0)  # never into the water
				_put(mm, i, rng, s0 + rng.randf() * chunk_length, u, origin, set[2], 0.15)
			_add_mm(holder, mm, origin, 200.0)

# scrub and a few trees on the lake bank between the path edge and the waterline (sections "bank_plants" per chunk):
# below a cantilevered path they fill the slope and their crowns rise past the railing
func _bank_plants(holder: Node3D, rng: RandomNumberGenerator, s0: float, origin: Vector3) -> void:
	var n := int(_route.section_at(s0 + chunk_length * 0.5).get("bank_plants", 0))
	if n <= 0:
		return
	var bank_u := func(s: float) -> float:
		var a := _route.half_left(s) + 0.8  # crowded near the path edge: lower down the slope they drop out of sight
		return lerpf(a, maxf(_route.water_edge_u(s) - 0.5, a + 0.5), pow(rng.randf(), 2.0))
	for m: Mesh in _shrubs:
		var mm := _new_mm(m, n)
		for i in n:
			var s := s0 + rng.randf() * chunk_length
			_put(mm, i, rng, s, bank_u.call(s), origin, shrub_scale * 1.5, 0.1)
		_add_mm(holder, mm, origin, tree_view_distance)
	for m: Mesh in _blobs:  # dense low evergreen scrub (holm oak / pittosporum look): the light procedural crowns, bush-sized
		var mm := _new_mm(m, n / 4)
		for i in mm.instance_count:
			var s := s0 + rng.randf() * chunk_length
			_put(mm, i, rng, s, bank_u.call(s), origin, Vector2(0.12, 0.3), 0.6)
		_add_mm(holder, mm, origin, tree_view_distance)
	for i in n / 8:
		var s := s0 + rng.randf() * chunk_length
		var u: float = bank_u.call(s)
		var pine := rng.randf() < conifer_ratio
		var tree := MeshInstance3D.new()
		tree.mesh = _blobs[rng.randi() % _blobs.size()] if pine else _broadleaf(rng)
		tree.position = _route.pos_at(s) + _route.left_at(s) * u
		tree.position.y = _route.ground_y(s, u) - 0.2
		tree.rotation.y = rng.randf() * TAU
		var sr := conifer_scale if pine else tree_scale
		var sc := rng.randf_range(sr.x, sr.y)
		tree.scale = Vector3(sc, sc, sc)
		tree.visibility_range_end = tree_view_distance
		holder.add_child(tree)

# scrub clinging to the ledges of the rock face (sections "cliff_plants" per chunk): green and autumn crowns and shrubs,
# only where the face is not sheer (ground rising < 3 m per m across the slope)
func _cliff_plants(holder: Node3D, rng: RandomNumberGenerator, s0: float, origin: Vector3) -> void:
	var sec := _route.section_at(s0 + chunk_length * 0.5)
	var n := int(sec.get("cliff_plants", 0))
	if n <= 0:
		return
	var cf := float(sec.get("cliff_from", 6.0))
	var spots := []
	for k in n * 4:
		if spots.size() >= n:
			break
		var s := s0 + rng.randf() * chunk_length
		var u := -(_route.half_right(s) + cf + rng.randf_range(0.5, 22.0))
		if absf(_route.ground_y(s, u + 1.0) - _route.ground_y(s, u - 1.0)) < 6.0:
			spots.append([s, u])
	var meshes: Array[Mesh] = []
	meshes.append_array(_shrubs)
	meshes.append(_blobs[0])
	meshes.append_array(_autumn)
	for m: Mesh in meshes:
		var mine := spots.filter(func(_p): return rng.randf() < 1.0 / meshes.size())
		var mm := _new_mm(m, mine.size())
		var small := m in _shrubs
		for i in mine.size():
			_put(mm, i, rng, mine[i][0], mine[i][1], origin, shrub_scale * 1.2 if small else Vector2(0.1, 0.25), 0.3)
		_add_mm(holder, mm, origin, tree_view_distance)

func _fence(holder: Node3D, idx: int, s0: float, origin: Vector3) -> void:
	if (idx + random_seed) % fence_every != 0 or not bool(_route.section_at(s0 + chunk_length * 0.5).get("fence", true)):
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
	mat.albedo_color = Color(1.7, 1.8, 1.4) * blob_tint
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

# alpine spruce: many drooping, jagged-edged branch tiers (star-shaped rings hanging from each tier's tip),
# dark green with lighter tips; a dark underside disc per tier hides the see-through gap.
# bare = fraction of the height below the lowest branch tier (forest spruce / larch: tall bare trunks under the canopy);
# palette = [dark, mid, tip] needle colours (larch: autumn yellow)
func _make_spruce(seed_: int, bare := 0.0, palette: Array = []) -> Mesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tiers := rng.randi_range(10, 13)
	var height := rng.randf_range(12.0, 17.0) * (1.0 + 0.5 * bare)  # forest trees are taller
	var rmax := rng.randf_range(2.7, 3.4) * (1.0 - 0.4 * bare)  # ... and narrower
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.14 if bare == 0.0 else 0.06
	trunk.bottom_radius = 0.3 if bare == 0.0 else 0.32
	trunk.height = 4.0 if bare == 0.0 else height * 0.92
	trunk.radial_segments = 6
	_add_arrays(st, trunk.get_mesh_arrays(), Vector3(0, trunk.height * 0.5, 0), Vector3.ONE, 0, func(_v, _h, _t): return Color(0.2, 0.14, 0.09))
	var n := 14
	var dark: Color = palette[0] if palette else Color(0.015, 0.06, 0.025)
	var mid: Color = palette[1] if palette else Color(0.05, 0.14, 0.04)
	var tip: Color = palette[2] if palette else Color(0.12, 0.26, 0.07)
	var y_low := maxf(1.8, bare * height)
	for k in tiers:
		var t := float(k) / (tiers - 1)
		var y0 := y_low + t * (height - 0.8 - y_low)
		var r := rmax * pow(1.0 - t, 0.85) * rng.randf_range(0.9, 1.08) + 0.35
		var h := lerpf(3.2, 1.6, t)
		var apex := Vector3(0, y0 + h, 0)
		var ring: Array[Vector3] = []
		for i in n:
			var a := TAU * i / n + rng.randf_range(-0.12, 0.12)
			var rr := r * (0.68 if i % 2 == 0 else 1.08) * rng.randf_range(0.9, 1.1)  # alternating long/short branches
			ring.append(Vector3(cos(a) * rr, y0 - 0.55 * rr / rmax * 1.4 - rng.randf_range(0.0, 0.25), sin(a) * rr))  # branch tips droop
		var centre := Vector3(0, y0 - 0.15, 0)
		for i in n:
			var p0 := ring[i]
			var p1 := ring[(i + 1) % n]
			var lum := rng.randf_range(0.0, 1.0)
			var snow := snow_load * rng.randf_range(0.55, 1.0)  # snow lying on the tier's upper side, patchy
			st.set_color(tip.lerp(mid, 0.3 + 0.4 * lum).lerp(SNOW, snow))
			st.add_vertex(apex)
			st.set_color(mid.lerp(dark, 0.35 + 0.4 * lum).lerp(SNOW, snow * 0.75))  # branch tips: thinner snow
			st.add_vertex(p1)
			st.set_color(mid.lerp(dark, 0.35 + 0.4 * lum).lerp(SNOW, snow * 0.75))
			st.add_vertex(p0)
			st.set_color(dark)  # underside
			st.add_vertex(centre)
			st.add_vertex(p0)
			st.add_vertex(p1)
	st.generate_normals()
	var m := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = load("res://assets/textures/aerial_grass_rock_diff.jpg")  # needle-like speckle
	mat.uv1_triplanar = true
	mat.uv1_scale = Vector3.ONE * 0.9
	mat.albedo_color = Color(1.5, 1.5, 1.3)
	if snow_load > 0.0:  # a neutral speckle, so the snow stays white (the needle texture is green)
		mat.albedo_texture = load("res://assets/textures/snow_02_diff.jpg")
		mat.albedo_color = Color(1.1, 1.1, 1.1)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 1.0
	m.surface_set_material(0, mat)
	return m

const SNOW := Color(0.92, 0.94, 0.98)

# bare winter birch: white trunk with dark marks, two levels of thin upswept branches, frost on their upper sides
func _make_birch(seed_: int) -> Mesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var height := rng.randf_range(9.0, 13.0)
	var limb := func(a: Vector3, b: Vector3, r0: float, r1: float, col: Color) -> void:
		_limb(st, a, b, r0, r1, col, 0.55)
	var bark := Color(0.82, 0.8, 0.76)
	var pts := [Vector3.ZERO]
	for k in 6:  # slightly wandering trunk
		pts.append(Vector3(rng.randf_range(-0.25, 0.25), height * (k + 1) / 6.0, rng.randf_range(-0.25, 0.25)))
	for k in 6:
		var dark := rng.randf() < 0.3
		limb.call(pts[k], pts[k + 1], lerpf(0.22, 0.05, k / 6.0), lerpf(0.22, 0.05, (k + 1) / 6.0), Color(0.12, 0.1, 0.09) if dark else bark)
	var twig := Color(0.3, 0.24, 0.2)
	for k in rng.randi_range(14, 20):  # branches from the upper two thirds, each with a few twigs
		var t := rng.randf_range(0.3, 0.95)
		var base := Vector3(0, height * t, 0)
		var dir := Vector3(cos(rng.randf() * TAU), rng.randf_range(0.6, 1.4), sin(rng.randf() * TAU)).normalized()
		var len := lerpf(3.2, 1.2, t) * rng.randf_range(0.8, 1.2)
		var tip := base + dir * len
		limb.call(base, tip, 0.05, 0.02, twig)
		for j in 3:
			var tb := base.lerp(tip, rng.randf_range(0.4, 0.9))
			var td := (dir + Vector3(rng.randf_range(-0.8, 0.8), rng.randf_range(-0.2, 0.6), rng.randf_range(-0.8, 0.8))).normalized()
			limb.call(tb, tb + td * len * 0.45, 0.02, 0.008, twig)
	st.index()
	var m := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # thin limbs: seen from every side
	m.surface_set_material(0, mat)
	return m

# 5-sided tapered limb from a to b; frost > 0 whitens its upper side (winter birch)
func _limb(st: SurfaceTool, a: Vector3, b: Vector3, r0: float, r1: float, col: Color, frost := 0.0) -> void:
	var d := (b - a).normalized()
	var side := d.cross(Vector3.UP if absf(d.y) < 0.95 else Vector3.RIGHT).normalized()
	var up := side.cross(d)
	for i in 5:
		var a0 := TAU * i / 5
		var a1 := TAU * (i + 1) / 5
		var n0 := side * cos(a0) + up * sin(a0)
		var n1 := side * cos(a1) + up * sin(a1)
		st.set_color(col.lerp(SNOW, frost * clampf(n0.y + 0.3, 0.0, 1.0)))  # frost / snow on the upper side
		for v in [[a + n0 * r0, n0], [b + n0 * r1, n0], [b + n1 * r1, n1], [a + n0 * r0, n0], [b + n1 * r1, n1], [a + n1 * r0, n1]]:
			st.set_normal(v[1])
			st.add_vertex(v[0])

func _leaf_mat() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat

# leaf-cluster card texture (alpha-cut): ~70 oval leaves on a few twigs, grey so the vertex colour sets the crown colour
func _leaf_atlas() -> ImageTexture:
	var img := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for k in 5:  # twigs
		var a := Vector2(128, 128) + Vector2(rng.randf_range(-20, 20), rng.randf_range(-20, 20))
		var b := Vector2(rng.randf_range(10, 246), rng.randf_range(10, 246))
		for t in 60:
			var q := a.lerp(b, t / 60.0)
			img.set_pixel(clampi(int(q.x), 0, 255), clampi(int(q.y), 0, 255), Color(0.25, 0.2, 0.15, 1))
	for k in 130:
		var c := Vector2(rng.randf_range(16, 240), rng.randf_range(16, 240))
		if c.distance_to(Vector2(128, 128)) > 118.0:
			continue
		var ang := rng.randf() * TAU
		var ln := rng.randf_range(10.0, 18.0)
		var wd := ln * rng.randf_range(0.45, 0.6)
		var v := rng.randf_range(0.62, 1.0)
		var ax := Vector2(cos(ang), sin(ang))
		for y in range(int(c.y - ln), int(c.y + ln) + 1):
			for x in range(int(c.x - ln), int(c.x + ln) + 1):
				var d := Vector2(x, y) - c
				var along := d.dot(ax)
				var across := d.dot(Vector2(-ax.y, ax.x))
				if (along / ln) * (along / ln) + (across / wd) * (across / wd) <= 1.0 and x >= 0 and y >= 0 and x < 256 and y < 256:
					var shade := v * (0.82 if absf(across) < 0.8 else 1.0) * lerpf(1.05, 0.85, (along / ln) * 0.5 + 0.5)  # midrib, lit tip
					img.set_pixel(x, y, Color(shade, shade, shade, 1))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

# needle spray card texture: a twig along U with dense short needles on both sides (spruce / larch branches)
func _needle_atlas() -> ImageTexture:
	var img := Image.create(256, 128, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var twigs := [[Vector2(0, 64), Vector2(255, 60)]]
	for k in 7:  # side shoots
		var x := rng.randf_range(30, 220)
		twigs.append([Vector2(x, 63), Vector2(x + rng.randf_range(30, 60), 63 + (1 if k % 2 == 0 else -1) * rng.randf_range(25, 45))])
	for tw in twigs:
		var a: Vector2 = tw[0]
		var b: Vector2 = tw[1]
		var n := int(a.distance_to(b) / 2.0)
		for t in n:
			var q := a.lerp(b, float(t) / n)
			var dir := (b - a).normalized()
			for sgn in [-1.0, 1.0]:
				var nd := dir.rotated(sgn * rng.randf_range(0.7, 1.2))
				var ln := rng.randf_range(7.0, 13.0) * (1.0 - 0.4 * float(t) / n)
				var v := rng.randf_range(0.55, 1.0)
				for u in int(ln):
					var p := q + nd * u
					if p.x >= 0 and p.y >= 0 and p.x < 256 and p.y < 128:
						img.set_pixel(int(p.x), int(p.y), Color(v, v, v, 1))
			img.set_pixel(clampi(int(q.x), 0, 255), clampi(int(q.y), 0, 127), Color(0.3, 0.25, 0.2, 1))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

var _leaf_mat_cards: StandardMaterial3D
var _needle_mat_cards: StandardMaterial3D

func _card_mat(tex: Texture2D) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.35
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 0.85
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m

func _bark_mat(tex: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://assets/textures/%s_diff.jpg" % tex)
	m.normal_enabled = true
	m.normal_texture = load("res://assets/textures/%s_nor.jpg" % tex)
	m.roughness_texture = load("res://assets/textures/%s_rough.jpg" % tex)
	return m

# trunk / limb with bark UVs (u around, v along; ~1.5 m of bark texture per repeat)
func _bark_limb(st: SurfaceTool, a: Vector3, b: Vector3, r0: float, r1: float, v0: float) -> float:
	var d := (b - a).normalized()
	var side := d.cross(Vector3.UP if absf(d.y) < 0.95 else Vector3.RIGHT).normalized()
	var up := side.cross(d)
	var v1 := v0 + a.distance_to(b) / 1.5
	var around := TAU * maxf(r0, 0.05) / 1.5
	for i in 6:
		var a0 := TAU * i / 6
		var a1 := TAU * (i + 1) / 6
		var n0 := side * cos(a0) + up * sin(a0)
		var n1 := side * cos(a1) + up * sin(a1)
		for v in [[a + n0 * r0, n0, Vector2(i / 6.0 * around, v0)], [b + n0 * r1, n0, Vector2(i / 6.0 * around, v1)], [b + n1 * r1, n1, Vector2((i + 1) / 6.0 * around, v1)],
				[a + n0 * r0, n0, Vector2(i / 6.0 * around, v0)], [b + n1 * r1, n1, Vector2((i + 1) / 6.0 * around, v1)], [a + n1 * r0, n1, Vector2((i + 1) / 6.0 * around, v0)]]:
			st.set_normal(v[1])
			st.set_uv(v[2])
			st.add_vertex(v[0])
	return v1

# one foliage card: quad of `size` m at c, facing roughly `n`, normal bent outward from the crown centre for soft shading
func _card(st: SurfaceTool, c: Vector3, n: Vector3, size_u: float, size_v: float, col: Color, nrm: Vector3, uv := Rect2(0, 0, 1, 1), along := Vector3.ZERO) -> void:
	var t := along if along != Vector3.ZERO else n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var b := n.cross(t).normalized()
	var q := [c - b * size_v * 0.5, c + t * size_u - b * size_v * 0.5, c + t * size_u + b * size_v * 0.5, c + b * size_v * 0.5] if along != Vector3.ZERO \
			else [c - t * size_u * 0.5 - b * size_v * 0.5, c + t * size_u * 0.5 - b * size_v * 0.5, c + t * size_u * 0.5 + b * size_v * 0.5, c - t * size_u * 0.5 + b * size_v * 0.5]
	var uvs := [uv.position + Vector2(0, uv.size.y), uv.position + uv.size, uv.position + Vector2(uv.size.x, 0), uv.position]
	st.set_color(col)
	st.set_normal(nrm)
	for k in [0, 1, 2, 0, 2, 3]:
		st.set_uv(uvs[k])
		st.add_vertex(q[k])

func _two_surfaces(bark: SurfaceTool, bark_mat: Material, leaves: SurfaceTool, leaf_mat: Material) -> ArrayMesh:
	var m := bark.commit()
	leaves.commit(m)
	m.surface_set_material(0, bark_mat)
	m.surface_set_material(1, leaf_mat)
	return m

# European beech as in the video: tall smooth grey trunk bare for half its height, limbs angled up and out, a fine
# crown of ~250 alpha-cut leaf-cluster cards around their tips (leaf = crown colour: green .. yellow .. orange)
func _make_beech(seed_: int, leaf: Color) -> Mesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var bk := SurfaceTool.new()
	bk.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lf := SurfaceTool.new()
	lf.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := rng.randf_range(14.0, 21.0)
	var pts: Array[Vector3] = [Vector3.ZERO]
	for k in 6:
		pts.append(Vector3(rng.randf_range(-0.35, 0.35), h * 0.88 * (k + 1) / 6.0, rng.randf_range(-0.35, 0.35)))
	var v := 0.0
	for k in 6:
		v = _bark_limb(bk, pts[k], pts[k + 1], lerpf(0.3, 0.07, k / 6.0), lerpf(0.3, 0.07, (k + 1) / 6.0), v)
	var tips: Array[Vector3] = [pts[6] + Vector3(0, 0.8, 0)]
	for k in rng.randi_range(7, 10):
		var t := rng.randf_range(0.35, 0.85)
		var a := rng.randf() * TAU
		var base := pts[int(t * 6.0)].lerp(pts[int(t * 6.0) + 1], fmod(t * 6.0, 1.0))
		var tip := base + Vector3(cos(a) * rng.randf_range(2.2, 4.0), rng.randf_range(1.0, 3.0), sin(a) * rng.randf_range(2.2, 4.0))
		_bark_limb(bk, base, tip, 0.09, 0.03, 0.0)
		tips.append(tip)
	var crown := Vector3(0, h * 0.72, 0)
	for k in rng.randi_range(22, 28):
		var mc: Vector3 = tips[k % tips.size()] + Vector3(rng.randf_range(-1.6, 1.6), rng.randf_range(-1.2, 1.2), rng.randf_range(-1.6, 1.6))
		var r := rng.randf_range(1.3, 2.1)
		for j in 17:
			var off := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.7, 0.8), rng.randf_range(-1, 1)) * r
			var c := mc + off
			var out := (c - crown).normalized()
			var lit := clampf(0.5 + 0.35 * out.y + 0.25 * off.y / r, 0.0, 1.0)
			var col := leaf * lerpf(0.5, 1.15, lit) * rng.randf_range(0.85, 1.1)
			var sz := rng.randf_range(1.1, 1.8)
			_card(lf, c, Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.4, 1), rng.randf_range(-1, 1)).normalized(), sz, sz, col, (out + Vector3.UP * 0.6).normalized())
	return _two_surfaces(bk, _bark_beech, lf, _leaf_mat_cards)

# forest conifer as in the video: tall straight trunk, bare below `bare` of the height, dense tiers of drooping branches
# made of crossed needle-spray cards; palette = [shade, mid, tip] (spruce dark green, larch autumn yellow)
func _make_conifer(seed_: int, bare: float, palette: Array, density: float, bark_mat: Material) -> Mesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var bk := SurfaceTool.new()
	bk.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lf := SurfaceTool.new()
	lf.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := rng.randf_range(19.0, 27.0)
	var v := 0.0
	for k in 5:
		v = _bark_limb(bk, Vector3(0, h * k / 5.0, 0), Vector3(0, h * (k + 1) / 5.0, 0), lerpf(0.34, 0.04, k / 5.0), lerpf(0.34, 0.04, (k + 1) / 5.0), v)
	var y_low := bare * h
	var rmax := rng.randf_range(2.2, 2.9)
	var y := y_low
	while y < h - 0.3:
		var t := (y - y_low) / (h - y_low)
		var r := rmax * pow(1.0 - t, 0.9) + 0.25
		for k in int(rng.randi_range(6, 9) * density):
			var a := rng.randf() * TAU
			var dir := Vector3(cos(a), -0.15 - 0.35 * (1.0 - t) * rng.randf_range(0.6, 1.2), sin(a)).normalized()
			var base := Vector3(0, y, 0)
			var shade := clampf(0.35 + 0.65 * t + rng.randf_range(-0.15, 0.15), 0.0, 1.0)
			var col: Color = (palette[0] as Color).lerp(palette[1], shade).lerp(palette[2], maxf(shade - 0.6, 0.0) * 1.5)
			var w := 0.45 + r * 0.22
			var flat := dir.cross(Vector3.UP).normalized()
			_card(lf, base, Vector3.UP, r, w, col, (dir + Vector3.UP * 0.8).normalized(), Rect2(0, 0, 1, 1), dir)
			_card(lf, base, flat, r, w * 0.8, col * 0.85, (dir + Vector3.UP * 0.5).normalized(), Rect2(0, 0, 1, 1), dir)
		y += rng.randf_range(0.45, 0.7)
	return _two_surfaces(bk, bark_mat, lf, _needle_mat_cards)

# hazel / young beech: 6-9 thin stems fanning out from the ground, leaf-cluster cards along their upper half
func _make_hazel(seed_: int, leaf: Color) -> Mesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var bk := SurfaceTool.new()
	bk.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lf := SurfaceTool.new()
	lf.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := rng.randf_range(2.5, 4.5)
	for k in rng.randi_range(6, 9):
		var a := rng.randf() * TAU
		var tip := Vector3(cos(a) * rng.randf_range(0.8, 1.8), h * rng.randf_range(0.75, 1.0), sin(a) * rng.randf_range(0.8, 1.8))
		_bark_limb(bk, Vector3(cos(a) * 0.1, 0.0, sin(a) * 0.1), tip, 0.035, 0.015, 0.0)
		for j in 10:
			var c := tip * rng.randf_range(0.45, 1.05) + Vector3(rng.randf_range(-0.4, 0.4), rng.randf_range(-0.2, 0.3), rng.randf_range(-0.4, 0.4))
			var col := leaf * lerpf(0.6, 1.1, clampf(c.y / h, 0.0, 1.0)) * rng.randf_range(0.85, 1.1)
			var sz := rng.randf_range(0.5, 0.8)
			_card(lf, c, Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 1), rng.randf_range(-1, 1)).normalized(), sz, sz, col, (c.normalized() + Vector3.UP).normalized())
	return _two_surfaces(bk, _bark_beech, lf, _leaf_mat_cards)

# reed clump on the waterline: ~46 thin straw blades 1.4-2.4 m, leaning a little, with brown plumes
func _make_reeds(seed_: int) -> Mesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in 46:
		var a := rng.randf() * TAU
		var base := Vector3(cos(a), 0.0, sin(a)) * rng.randf_range(0.0, 0.6)
		var top := base + Vector3(rng.randf_range(-0.25, 0.25), rng.randf_range(1.4, 2.4), rng.randf_range(-0.25, 0.25))
		var side := Vector3(cos(a + 1.57), 0.0, sin(a + 1.57)) * 0.025
		for v in [[base - side, Color(0.2, 0.17, 0.07)], [base + side, Color(0.2, 0.17, 0.07)], [top, Color(0.55, 0.43, 0.2)]]:
			st.set_color(v[1])
			st.add_vertex(v[0])
		var p0 := top.lerp(base, 0.15)
		for v in [[p0 - side * 2.0, Color(0.3, 0.2, 0.1)], [p0 + side * 2.0, Color(0.3, 0.2, 0.1)], [top + Vector3(0, 0.05, 0), Color(0.38, 0.27, 0.14)]]:
			st.set_color(v[1])
			st.add_vertex(v[0])
	st.generate_normals()
	var m := st.commit()
	m.surface_set_material(0, _leaf_mat())
	return m

# fallen trunk, 7 m long along X, lying on the ground
func _make_log() -> Mesh:
	var c := CylinderMesh.new()
	c.top_radius = 0.2
	c.bottom_radius = 0.28
	c.height = 7.0
	c.radial_segments = 7
	var arr := c.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] = Vector3(verts[i].y, verts[i].x + 0.22, verts[i].z)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = null
	arr[Mesh.ARRAY_TANGENT] = null
	var st := SurfaceTool.new()
	st.create_from_arrays(arr)
	st.generate_normals()
	var m := st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.36, 0.31, 0.26)
	mat.roughness = 0.95
	m.surface_set_material(0, mat)
	return m

# weissensee forest per section (forest_mix): trees by the section's beech / spruce / larch shares ("yellow" = share of
# autumn-coloured beech crowns), out to "depth" m from the path; "hazel" bushes crowding the path edge, "reeds" on the
# waterline, fallen "logs", "scree" rubble across the trail. Counts are per chunk.
func _forest(holder: Node3D, rng: RandomNumberGenerator, s0: float, origin: Vector3, sec: Dictionary) -> void:
	var groups := {}
	var add := func(m: Mesh, s: float, u: float, sc: float, sink: float) -> void:
		var p := _route.pos_at(s) + _route.left_at(s) * u
		p.y = _route.ground_y(s, u) - sink
		if not groups.has(m):
			groups[m] = []
		groups[m].append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * sc), p - origin))
	var pick := func(arr: Array[Mesh]) -> Mesh:
		return arr[rng.randi() % arr.size()]
	var side_u := func(s: float, from: float, to: float, power: float, lake_share := 0.5) -> float:  # beside the path, never in the lake
		var bank := _route.water_edge_u(s) - 0.8 - _route.half_left(s) - from
		var lake := rng.randf() < lake_share * clampf(bank / 15.0, 0.0, 1.0)  # the wooded bank, as many trees as it has room for
		var edge := (_route.half_left(s) if lake else _route.half_right(s)) + from
		if lake:  # spread over the bank between the path and the water (clamping would line them up on the shore)
			return lerpf(edge, minf(to, _route.water_edge_u(s) - 0.8), pow(rng.randf(), power))
		return -lerpf(edge, maxf(to, edge + 0.5), pow(rng.randf(), power))
	var wb := float(sec.get("beech", 0.5))
	var ws := float(sec.get("spruce", 0.4))
	var wl := float(sec.get("larch", 0.1))
	var yellow := float(sec.get("yellow", 0.5))
	var depth := float(sec.get("depth", max_dist))
	for i in int(trees_per_chunk * float(sec.get("trees", 1.0))):
		var s := s0 + rng.randf() * chunk_length
		var r := rng.randf() * maxf(wb + ws + wl, 0.001)
		var m: Mesh = pick.call(_beech_yellow if rng.randf() < yellow else _beech_green) if r < wb else (pick.call(_fspruce) if r < wb + ws else pick.call(_larch))
		add.call(m, s, side_u.call(s, 0.6, depth, 1.15), rng.randf_range(0.75, 1.15), 0.2)
	for i in int(sec.get("hazel", 0)):
		var s := s0 + rng.randf() * chunk_length
		add.call(pick.call(_hazel_yellow if rng.randf() < yellow else _hazel_green), s, side_u.call(s, 2.0, 9.0, 1.8, 0.7), rng.randf_range(0.7, 1.3), 0.1)  # crowns stay out of the walker's face
	for i in int(sec.get("reeds", 0)):
		var s := s0 + rng.randf() * chunk_length
		if _route.sea_grass(s) or _route.water_level(s) > _route.pos_at(s).y - 4.0:
			add.call(_reed, s, _route.water_edge_u(s) + rng.randf_range(-2.0, 4.0), rng.randf_range(0.8, 1.3), 0.3)  # a belt out into the shallows
	for i in int(sec.get("logs", 0)):
		var s := s0 + rng.randf() * chunk_length
		add.call(_logm, s, side_u.call(s, 0.6, 14.0, 1.2), rng.randf_range(0.6, 1.3), 0.08)
	for i in int(sec.get("scree", 0)):
		var s := s0 + rng.randf() * chunk_length
		add.call(pick.call(_rocks_small), s, rng.randf_range(-8.0, 8.0), rng.randf_range(0.1, 0.35), 0.05)
	for m: Mesh in groups:
		var xf: Array = groups[m]
		var mm := _new_mm(m, xf.size())
		for k in xf.size():
			mm.set_instance_transform(k, xf[k])
		_add_mm(holder, mm, origin, tree_view_distance)

# meadow grass clump: a tuft of thin, tapered, curved blades (2 segments each). UV.y = height fraction,
# used by grass.gdshader for wind bending and the root-to-tip colour ramp.
func _make_clump() -> Mesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	for i in 28:
		var a := rng.randf() * TAU
		var r := rng.randf_range(0.0, 0.18)
		var base := Vector3(cos(a) * r, 0.0, sin(a) * r)
		var h := rng.randf_range(0.35, 0.9)
		var out := Vector3(cos(a), 0.0, sin(a))
		var lean := rng.randf_range(0.1, 0.45)
		var side := Vector3(-sin(a), 0.0, cos(a)) * rng.randf_range(0.012, 0.022)
		var mid := base + out * h * lean * 0.35 + Vector3(0, h * 0.55, 0)
		var tip := base + out * h * lean + Vector3(0, h, 0)
		for tri in [[base - side, 0.0, base + side, 0.0, mid + side * 0.7, 0.55], [base - side, 0.0, mid + side * 0.7, 0.55, mid - side * 0.7, 0.55], [mid - side * 0.7, 0.55, mid + side * 0.7, 0.55, tip, 1.0]]:
			for k in 3:
				st.set_uv(Vector2(0.5, tri[k * 2 + 1]))
				st.add_vertex(tri[k * 2])
	var m := st.commit()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/grass.gdshader")
	m.surface_set_material(0, mat)
	return m

# alpine: pebbles and the odd exposed root on the walked surface (no collision, partly sunk, never tall)
@export var trail_pebbles := 45      # per chunk
@export var trail_roots := 2         # per chunk
func _trail_debris(holder: Node3D, rng: RandomNumberGenerator, s0: float, origin: Vector3) -> void:
	var sec := _route.section_at(s0 + chunk_length * 0.5)
	var n_peb := int(sec.get("pebbles", trail_pebbles))
	var n_root := int(sec.get("roots", trail_roots))
	for m in _rocks_small:
		var mm := _new_mm(m, n_peb)
		for i in n_peb:
			var s := s0 + rng.randf() * chunk_length
			var u := rng.randf_range(-_route.half_right(s), _route.half_left(s)) * 0.95
			var p := _route.pos_at(s) + _route.left_at(s) * u
			p.y = _route.ground_y(s, u) - 0.03
			var k := rng.randf_range(0.03, 0.11)
			var b := Basis(Vector3.UP, rng.randf() * TAU).rotated(Vector3.RIGHT, rng.randf_range(-0.4, 0.4)).scaled_local(Vector3(k, k * 0.6, k))
			mm.set_instance_transform(i, Transform3D(b, p - origin))
		_add_mm(holder, mm, origin, 60.0)
	if _root_mesh == null:
		var c := CapsuleMesh.new()
		c.radius = 0.035
		c.height = 1.0
		c.radial_segments = 6
		c.rings = 2
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.24, 0.17, 0.11)
		mat.roughness = 0.9
		c.material = mat
		_root_mesh = c
	var rm := _new_mm(_root_mesh, n_root)
	for i in n_root:
		var s := s0 + rng.randf() * chunk_length
		var p := _route.pos_at(s) + _route.left_at(s) * rng.randf_range(-0.3, 0.3)
		p.y = _route.ground_y(s, 0.0) - 0.02
		var len := (_route.half_left(s) + _route.half_right(s)) * rng.randf_range(0.6, 1.1)
		var side := _route.left_at(s)
		var b := Basis.looking_at(side.rotated(Vector3.UP, rng.randf_range(-0.5, 0.5)), Vector3.UP)
		b = b * Basis(Vector3.RIGHT, PI * 0.5)  # capsule axis (Y) -> across the trail
		b = b.scaled_local(Vector3(1.0, len, 1.0))  # local: global scale shears, which glTF TRS cannot hold
		rm.set_instance_transform(i, Transform3D(b, p - origin))
	_add_mm(holder, rm, origin, 60.0)
