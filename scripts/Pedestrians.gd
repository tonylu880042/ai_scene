extends Node3D
# Low-poly walkers, runners and cyclists on the shared path and cars on the road beside it, all
# moving along the Route (both directions). Positions are updated every frame from the Route.

@export var path_node: NodePath      # the Route
@export var people_per_km := 0.0    # no people on the path
@export var cars_per_km := 0.0      # no cars (the road stays empty)
@export var random_seed := 7

var _route: Route
var _agents: Array = []   # {node, s, v (m/s, signed), u, legs, cadence}
var _rng := RandomNumberGenerator.new()

const SHIRTS := [Color(0.85, 0.2, 0.15), Color(0.15, 0.4, 0.8), Color(0.95, 0.75, 0.1), Color(0.2, 0.6, 0.35), Color(0.9, 0.9, 0.92), Color(0.15, 0.15, 0.2)]

func _ready() -> void:
	_route = get_node(path_node)
	_rng.seed = random_seed
	for i in int(_route.length / 1000.0 * people_per_km):
		var kind := _rng.randf()
		var dir := 1.0 if _rng.randf() < 0.5 else -1.0
		if kind < 0.45:
			_add(_walker(false), _rng.randf_range(1.2, 1.6) * dir, dir)
		elif kind < 0.65:
			_add(_walker(true), _rng.randf_range(2.3, 3.0) * dir, dir)
		else:
			_add(_cyclist(), _rng.randf_range(5.0, 7.5) * dir, dir)
	for i in int(_route.length / 1000.0 * cars_per_km):
		var dir := 1.0 if _rng.randf() < 0.5 else -1.0
		_add(_car(), _rng.randf_range(11.0, 16.0) * dir, dir, true)

func _add(n: Dictionary, v: float, dir: float, car := false) -> void:
	var node: Node3D = n["node"]
	add_child(node)
	var lane := (-4.8 if dir > 0.0 else -8.0) if car else (-0.9 if dir > 0.0 else 0.9)  # keep to one side
	_agents.append({"node": node, "s": _rng.randf() * _route.length, "v": v, "u": lane, "legs": n.get("legs", []), "cadence": n.get("cadence", 0.0)})

func _process(delta: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	for a in _agents:
		a["s"] += a["v"] * delta
		if a["s"] > _route.length - 3.0:
			a["s"] = 3.0
		elif a["s"] < 3.0:
			a["s"] = _route.length - 3.0
		var s: float = a["s"]
		var node: Node3D = a["node"]
		var tan := (_route.pos_at(s + 1.0) - _route.pos_at(s - 1.0))
		tan.y = 0.0
		node.position = _route.pos_at(s) + _route.left_at(s) * a["u"]
		node.basis = Basis.looking_at(tan.normalized() * signf(a["v"]), Vector3.UP)
		var legs: Array = a["legs"]
		if legs.size() == 2:
			var sw := sin(t * a["cadence"]) * 0.6
			legs[0].rotation.x = sw
			legs[1].rotation.x = -sw

func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	return m

func _mesh(parent: Node3D, mesh: Mesh, c: Color, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat(c)
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi

func _caps(r: float, h: float) -> CapsuleMesh:
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = h
	c.radial_segments = 8
	c.rings = 3
	return c

func _walker(runner: bool) -> Dictionary:
	var root := Node3D.new()
	var shirt: Color = SHIRTS[_rng.randi() % SHIRTS.size()]
	var pants := Color(0.15, 0.17, 0.25) if _rng.randf() < 0.6 else Color(0.25, 0.22, 0.2)
	var legs := []
	for x in [-0.1, 0.1]:
		var hip := Node3D.new()
		hip.position = Vector3(x, 0.9, 0)
		root.add_child(hip)
		_mesh(hip, _caps(0.085, 0.9), pants, Vector3(0, -0.45, 0))
		legs.append(hip)
	_mesh(root, _caps(0.17, 0.66), shirt, Vector3(0, 1.25, 0))
	_mesh(root, _sphere(0.11), Color(0.85, 0.65, 0.5), Vector3(0, 1.66, 0))
	for x in [-0.23, 0.23]:
		_mesh(root, _caps(0.05, 0.6), shirt, Vector3(x, 1.25, 0))
	return {"node": root, "legs": legs, "cadence": 11.0 if runner else 7.5}

func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = 8
	s.rings = 4
	return s

func _cyclist() -> Dictionary:
	var root := Node3D.new()
	var shirt: Color = SHIRTS[_rng.randi() % SHIRTS.size()]
	for z in [-0.55, 0.55]:
		var w := CylinderMesh.new()
		w.top_radius = 0.34
		w.bottom_radius = 0.34
		w.height = 0.05
		w.radial_segments = 12
		_mesh(root, w, Color(0.1, 0.1, 0.1), Vector3(0, 0.34, z), Vector3(0, 0, PI * 0.5))
	var frame := BoxMesh.new()
	frame.size = Vector3(0.05, 0.05, 1.1)
	_mesh(root, frame, Color(0.2, 0.2, 0.25), Vector3(0, 0.55, 0))
	_mesh(root, _caps(0.17, 0.62), shirt, Vector3(0, 1.22, 0.0), Vector3(-0.5, 0, 0))  # leaning forward over the bars
	_mesh(root, _sphere(0.12), SHIRTS[_rng.randi() % SHIRTS.size()], Vector3(0, 1.55, -0.25))  # helmet
	for x in [-0.12, 0.12]:
		_mesh(root, _caps(0.07, 0.75), Color(0.15, 0.17, 0.25), Vector3(x, 0.85, -0.05), Vector3(-0.3, 0, 0))
	return {"node": root}

func _car() -> Dictionary:
	var root := Node3D.new()
	var c: Color = [Color(0.8, 0.8, 0.82), Color(0.15, 0.2, 0.35), Color(0.6, 0.1, 0.1), Color(0.1, 0.1, 0.12), Color(0.85, 0.85, 0.3)][_rng.randi() % 5]
	var body := BoxMesh.new()
	body.size = Vector3(1.8, 0.6, 4.3)
	_mesh(root, body, c, Vector3(0, 0.65, 0))
	var cab := BoxMesh.new()
	cab.size = Vector3(1.6, 0.55, 2.2)
	_mesh(root, cab, Color(0.2, 0.25, 0.3), Vector3(0, 1.2, 0.2))
	for x in [-0.9, 0.9]:
		for z in [-1.4, 1.4]:
			var w := CylinderMesh.new()
			w.top_radius = 0.32
			w.bottom_radius = 0.32
			w.height = 0.22
			w.radial_segments = 10
			_mesh(root, w, Color(0.05, 0.05, 0.05), Vector3(x, 0.32, z), Vector3(0, 0, PI * 0.5))
	return {"node": root}
