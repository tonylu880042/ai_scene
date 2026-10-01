extends Node3D
# Hiking-trail furniture for the alpine scene: yellow trail signposts, a timber mountain hut and cairns.
# Nothing stands on the trail; everything sits a few metres to the side. Must come after the Route.

@export var path_node: NodePath      # the Route
@export var sign_spacing := 500.0
@export var hut := true              # one timber hut about 40% along the route
@export var cairns_per_km := 3.0
@export var random_seed := 9

var _route: Route
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_route = get_node(path_node)
	_rng.seed = random_seed
	for i in int(_route.length / sign_spacing):
		_signpost((i + 0.5) * sign_spacing + _rng.randf_range(-40.0, 40.0))
	if hut:
		_hut(_route.length * 0.4)
	for i in int(_route.length / 1000.0 * cairns_per_km):
		_cairn(_rng.randf_range(20.0, _route.length - 20.0))

func _mat(c: Color, rough := 0.8) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m

func _wood() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://assets/textures/brown_planks_09_diff.jpg")
	m.roughness_texture = load("res://assets/textures/brown_planks_09_rough.jpg")
	m.normal_enabled = true
	m.normal_texture = load("res://assets/textures/brown_planks_09_nor.jpg")
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE * 0.5
	return m

func _part(parent: Node3D, mesh: Mesh, m: Material, pos: Vector3, rot := Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)

func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b

func _cyl(top: float, bottom: float, h: float, seg := 8) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = seg
	return c

# node at route offset s, u metres to the left of travel (negative = uphill side), facing the trail
func _at(s: float, u: float) -> Node3D:
	s = clampf(s, 0.0, _route.length)
	var n := Node3D.new()
	n.position = _route.pos_at(s) + _route.left_at(s) * u
	n.position.y = _route.ground_y(s, u)
	var toward := -_route.left_at(s) * signf(u)  # look back at the trail
	n.basis = Basis.looking_at(toward, Vector3.UP)
	add_child(n)
	return n

func _signpost(s: float) -> void:
	var n := _at(s, -2.4)
	var wood := _wood()
	_part(n, _cyl(0.07, 0.08, 2.4), wood, Vector3(0, 1.2, 0))
	var yellow := _mat(Color(0.98, 0.78, 0.08), 0.5)
	for k in 2:
		var sign := _box(Vector3(0.75, 0.16, 0.03))
		_part(n, sign, yellow, Vector3(0.28 * (1 if k == 0 else -1), 2.15 - k * 0.3, 0.06))
		_part(n, _box(Vector3(0.6, 0.05, 0.035)), _mat(Color(0.15, 0.15, 0.15)), Vector3(0.28 * (1 if k == 0 else -1), 2.15 - k * 0.3, 0.08))
	_part(n, _box(Vector3(0.3, 0.3, 0.03)), _mat(Color(0.9, 0.9, 0.92)), Vector3(0, 1.45, 0.07))  # trail marker plate

func _hut(s: float) -> void:
	var n := _at(s, -14.0)
	var wood := _wood()
	_part(n, _box(Vector3(8.4, 0.8, 6.4)), _mat(Color(0.5, 0.48, 0.45)), Vector3(0, -0.3, 0))  # stone footing
	_part(n, _box(Vector3(8.0, 3.2, 6.0)), wood, Vector3(0, 1.9, 0))
	var roof := PrismMesh.new()
	roof.size = Vector3(6.8, 2.4, 9.0)
	_part(n, roof, _mat(Color(0.28, 0.27, 0.27), 0.9), Vector3(0, 3.5 + 1.2, 0), Vector3(0, PI * 0.5, 0))
	_part(n, _box(Vector3(1.0, 2.0, 0.1)), _mat(Color(0.25, 0.15, 0.1)), Vector3(-1.4, 1.0, 3.02))
	for x in [1.4, 3.0]:
		_part(n, _box(Vector3(1.0, 1.0, 0.1)), _mat(Color(0.18, 0.25, 0.32), 0.3), Vector3(x, 2.0, 3.02))
	_part(n, _box(Vector3(0.6, 2.2, 0.6)), _mat(Color(0.5, 0.48, 0.45)), Vector3(2.6, 5.4, -1.0))  # chimney
	_part(n, _box(Vector3(1.6, 1.2, 0.03)), _mat(Color(0.98, 0.78, 0.08)), Vector3(0, 3.4, 3.06))  # yellow hut sign

func _cairn(s: float) -> void:
	var n := _at(s, _rng.randf_range(2.6, 6.0) * (1.0 if _rng.randf() < 0.5 else -1.0))
	var stone := _mat(Color(0.5, 0.5, 0.52), 1.0)
	for i in 5:
		var r := 0.5 - i * 0.08
		_part(n, _cyl(r, r * 1.1, 0.22, 7), stone, Vector3(_rng.randf_range(-0.04, 0.04), 0.11 + i * 0.21, _rng.randf_range(-0.04, 0.04)))
