extends Node3D
# Procedural coastal props (beach huts, lighthouse, pier) textured with CC0 Poly Haven materials,
# plus a few Poly Haven sailing ships at sea. Must come after the Path3D in the tree.

@export var path_node: NodePath      # the Route (Path3D with route.gd)
@export var hut_spacing := 0.0       # one beach hut per this many metres of beach route (0 = none)
@export var hut_offset := 8.5        # metres seaward (left) of the road centre
@export var farm_spacing := 700.0    # one farmhouse per this many metres, inland
@export var summit_lookout := false  # viewing deck, cairn and flag at the end of the route (Summit)
@export var boat_sheds := 2          # small white boat sheds on stilts at the waterline
@export var pier_length := 40.0
@export var ship_count := 3
@export var ship_distance := Vector2(200.0, 450.0)
@export var random_seed := 4

var _route: Route
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_route = get_node(path_node)
	_rng.seed = random_seed
	var beach: Array[float] = []  # route offsets where the sea side is sand (buildings go there)
	var s := 30.0
	while s < _route.length - 30.0:
		if not _route.sea_grass(s):
			beach.append(s)
		s += 10.0
	if not beach.is_empty():
		if hut_spacing > 0.0:
			for i in maxi(int(beach.size() * 10.0 / hut_spacing), 1):
				_hut(beach[_rng.randi() % beach.size()])
		if not _route.grass_bank:
			_lighthouse(beach[int(beach.size() * 0.3)])
		_pier(beach[int(beach.size() * 0.6)])
		for i in boat_sheds:
			_boatshed(beach[int(beach.size() * (0.15 + 0.35 * i + 0.05 * _rng.randf()))])
	for i in maxi(int(_route.length / farm_spacing), 1):
		_farmhouse((i + _rng.randf_range(0.2, 0.8)) * farm_spacing)
	if summit_lookout:
		_lookout(_route.length - 12.0)  # deck right beside the finish gate
	var ship := load("res://assets/models/dutch_ship_medium/dutch_ship_medium_1k.gltf") as PackedScene
	for i in ship_count:
		var s2 := _rng.randf() * _route.length
		var n: Node3D = ship.instantiate()
		n.position = _route.pos_at(s2) + _route.left_at(s2) * _rng.randf_range(ship_distance.x, ship_distance.y)
		n.position.y = _route.sea_y + 0.8
		n.rotation.y = _rng.randf() * TAU
		add_child(n)

func _mat(tex: String, scale: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://assets/textures/%s_diff.jpg" % tex)
	m.roughness_texture = load("res://assets/textures/%s_rough.jpg" % tex)
	m.normal_enabled = true
	m.normal_texture = load("res://assets/textures/%s_nor.jpg" % tex)
	m.uv1_triplanar = true
	m.uv1_scale = Vector3.ONE * scale
	return m

func _part(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi

func _plain(color: Color, emissive := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.6
	if emissive:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = 2.0
	return m

# node at route offset s, u metres seaward, whose -Z points along `look`
func _at(s: float, u: float, look: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = _route.pos_at(s) + _route.left_at(s) * u
	n.position.y = _route.ground_y(s, u)
	n.basis = Basis.looking_at(look, Vector3.UP)
	add_child(n)
	return n

func _hut(s: float) -> void:
	var n := _at(s, hut_offset, -_route.left_at(s))  # door faces the road
	var w := _rng.randf_range(3.5, 5.0)
	var d := _rng.randf_range(3.0, 4.0)
	var walls := _mat("brown_planks_09" if _rng.randf() < 0.5 else "beige_wall_001", 0.4)
	_part(n, BoxMesh.new(), walls, Vector3.ZERO)
	(n.get_child(0) as MeshInstance3D).mesh = _box(Vector3(w, 2.6, d))
	(n.get_child(0) as MeshInstance3D).position.y = 1.3
	var roof := PrismMesh.new()
	roof.size = Vector3(w + 0.8, 1.3, d + 0.8)
	_part(n, roof, _mat("clay_roof_tiles", 0.4), Vector3(0, 2.6 + 0.65, 0))
	_part(n, _box(Vector3(0.9, 1.9, 0.1)), _plain(Color(0.25, 0.15, 0.1)), Vector3(0, 0.95, -d * 0.5 - 0.02))

func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b

func _lighthouse(s: float) -> void:
	var n := _at(s, 10.0, -_route.left_at(s))
	var white := _mat("beige_wall_001", 0.3)
	var red := _plain(Color(0.75, 0.12, 0.1))
	var radius := func(y: float) -> float: return 2.2 - 1.0 * y / 13.0
	_part(n, _cyl(radius.call(13.0), radius.call(0.0), 13.0), white, Vector3(0, 6.5, 0))
	for band: Vector2 in [Vector2(3, 5.5), Vector2(8, 10.5)]:
		_part(n, _cyl(radius.call(band.y) + 0.03, radius.call(band.x) + 0.03, band.y - band.x), red, Vector3(0, (band.x + band.y) * 0.5, 0))
	_part(n, _cyl(2.1, 2.1, 0.3), _plain(Color(0.15, 0.15, 0.15)), Vector3(0, 13.15, 0))
	_part(n, _cyl(1.0, 1.0, 1.6), _plain(Color(1, 0.9, 0.55), true), Vector3(0, 14.1, 0))
	_part(n, _cyl(0.0, 1.5, 1.3), red, Vector3(0, 15.55, 0))

func _cyl(top: float, bottom: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	return c

func _pier(s: float) -> void:
	var out := _route.left_at(s)
	var n := _at(s, _route.water_edge_u(s) - 2.0 + pier_length * 0.5, out)
	n.position.y = 0.0
	var planks := _mat("brown_planks_09", 0.5)
	_part(n, _box(Vector3(3.0, 0.25, pier_length)), planks, Vector3(0, _route.sea_y + 0.95, 0))
	for z in range(int(-pier_length * 0.5), int(pier_length * 0.5) + 1, 5):
		for x in [-1.3, 1.3]:
			_part(n, _cyl(0.13, 0.13, 3.0), planks, Vector3(x, _route.sea_y - 0.55, z))

func _farmhouse(s: float) -> void:
	s = minf(s, _route.length - 20.0)
	var n := _at(s, -_rng.randf_range(22.0, 34.0), _route.left_at(s))  # inland; door faces the road
	var modern := _rng.randf() < 0.5  # white walls + slate roof (harbour houses) or plaster + clay tiles
	var plaster: Material = _plain(Color(0.92, 0.94, 0.96)) if modern else _mat("beige_wall_001", 0.3)
	_part(n, _box(Vector3(9.4, 2.6, 6.4)), plaster, Vector3(0, -0.6, 0))  # foundation hides the slope
	_part(n, _box(Vector3(9.0, 3.4, 6.0)), plaster, Vector3(0, 1.7, 0))
	var roof := PrismMesh.new()
	roof.size = Vector3(7.2, 2.6, 10.0)
	_part(n, roof, _plain(Color(0.3, 0.34, 0.4)) if modern else _mat("clay_roof_tiles", 0.4), Vector3(0, 3.4 + 1.3, 0)).rotation.y = PI * 0.5  # ridge along the long side
	var dark := _plain(Color(0.22, 0.14, 0.1))
	_part(n, _box(Vector3(1.1, 2.1, 0.12)), dark, Vector3(-1.2, 1.05, -3.03))
	for x in [1.6, 3.3, -3.4]:
		_part(n, _box(Vector3(1.0, 1.1, 0.1)), _plain(Color(0.2, 0.28, 0.35)), Vector3(x, 1.9, -3.03))
	_part(n, _box(Vector3(0.7, 2.4, 0.7)), _plain(Color(0.45, 0.4, 0.38)), Vector3(3.0, 5.0, 0.8))

# Summit finish: wooden viewing deck on the sea side (rail + posts over the drop), a cairn and a flag inland.
func _lookout(s: float) -> void:
	var wood := _mat("brown_planks_09", 0.5)
	var n := _at(s, 8.0, _route.left_at(s))  # -Z points seaward
	var y := _route.pos_at(s).y - n.position.y  # deck sits at road height
	_part(n, _box(Vector3(7.0, 0.25, 7.0)), wood, Vector3(0, y - 0.15, 0))
	for x in [-3.4, 3.4]:
		for z in [-3.4, 3.4]:
			_part(n, _cyl(0.15, 0.15, 5.0), wood, Vector3(x, y - 2.6, z))
	for x in [-3.4, 0.0, 3.4]:  # seaward railing (-Z side)
		_part(n, _cyl(0.06, 0.06, 1.1), wood, Vector3(x, y + 0.55, -3.45))
	_part(n, _box(Vector3(7.0, 0.08, 0.08)), wood, Vector3(0, y + 1.05, -3.45))
	_part(n, _box(Vector3(7.0, 0.08, 0.08)), wood, Vector3(0, y + 0.6, -3.45))
	var stone := _mat("coast_sand_01", 0.5)  # cairn: stacked flattened stones
	var c := _at(s, -6.0, _route.left_at(s))
	for i in 5:
		var r := 1.0 - i * 0.16
		_part(c, _cyl(r, r * 1.08, 0.35), stone, Vector3(_rng.randf_range(-0.1, 0.1), 0.18 + i * 0.34, _rng.randf_range(-0.1, 0.1)))
	var f := _at(s + 6.0, -5.0, _route.left_at(s))
	_part(f, _cyl(0.05, 0.05, 6.0), _plain(Color(0.85, 0.85, 0.85)), Vector3(0, 3.0, 0))
	_part(f, _box(Vector3(1.4, 0.9, 0.03)), _plain(Color(0.85, 0.15, 0.1)), Vector3(0.7, 5.4, 0))

# white boat shed with a pale-blue roof on a short jetty over the water, plus a flagpole
func _boatshed(s: float) -> void:
	var u := _route.water_edge_u(s) - 1.0
	var n := _at(s, u, _route.left_at(s))
	var wood := _mat("brown_planks_09", 0.5)
	n.position.y = 0.0
	var deck := _route.sea_y + 0.9
	_part(n, _box(Vector3(4.6, 0.2, 7.0)), wood, Vector3(0, deck, 2.0))
	for x in [-2.0, 2.0]:
		for z in [-1.0, 2.0, 5.0]:
			_part(n, _cyl(0.12, 0.12, 2.6), wood, Vector3(x, deck - 1.3, z))
	_part(n, _box(Vector3(3.4, 2.3, 3.0)), _plain(Color(0.94, 0.95, 0.97)), Vector3(0, deck + 1.25, 0.5))
	var roof := PrismMesh.new()
	roof.size = Vector3(3.9, 1.0, 3.5)
	_part(n, roof, _plain(Color(0.62, 0.74, 0.86)), Vector3(0, deck + 2.9, 0.5))
	_part(n, _box(Vector3(0.9, 1.5, 0.08)), _plain(Color(0.25, 0.3, 0.4)), Vector3(0, deck + 0.95, -1.03))
	_part(n, _cyl(0.04, 0.04, 4.5), _plain(Color(0.85, 0.85, 0.85)), Vector3(1.9, deck + 2.3, 4.6))
	_part(n, _box(Vector3(0.7, 0.45, 0.02)), _plain(Color(0.15, 0.25, 0.55)), Vector3(2.25, deck + 4.2, 4.6))
