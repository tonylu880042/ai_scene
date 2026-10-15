extends Node3D
# Inflatable START / FINISH gates over the path. Passing the finish gate slows the runner to a stop,
# fires confetti and sets `finished` (the HUD shows the result). Quit-at-end still follows the course clock.

@export var path_node: NodePath      # the Route
@export var player_path: NodePath
@export var start_gap := 10.0        # start gate this far ahead of the start line
@export var finish_gap := 12.0       # finish gate this far before the end of the route
@export var stop_time := 3.0         # seconds to ease from pace to a stop after the finish gate
@export var gate_half_width := 3.2

var finished := false
var _route: Route
var _player: Node3D
var _finish_s := 0.0
var _v0 := 0.0
var _stop_t := 0.0
var _confetti: CPUParticles3D

func _ready() -> void:
	_route = get_node(path_node)
	_player = get_node(player_path)
	_finish_s = _route.length - finish_gap
	if _route.start_offset < 20.0:
		_make_gate("START", _route.start_offset + start_gap)
	var g := _make_gate("FINISH", _finish_s)
	_confetti = _make_confetti()
	g.add_child(_confetti)

func _process(delta: float) -> void:
	var s := _route.curve.get_closest_offset(_route.to_local(_player.global_position))
	if not finished and s >= _finish_s:
		finished = true
		_v0 = _player.get("auto_speed")
		_confetti.restart()
		_confetti.emitting = true
	if finished:
		_stop_t += delta
		_player.set("auto_speed", lerpf(_v0, 0.0, clampf(_stop_t / stop_time, 0.0, 1.0)))

func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.45  # glossy inflatable plastic
	return m

func _part(parent: Node3D, mesh: Mesh, m: Material, pos: Vector3, rot := Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)

func _make_gate(text: String, s: float) -> Node3D:
	var n := Node3D.new()
	add_child(n)
	n.position = _route.pos_at(s)
	var t := _route.pos_at(s + 1.0) - _route.pos_at(s - 1.0)
	t.y = 0.0
	n.basis = Basis.looking_at(t.normalized(), Vector3.UP)
	var red := _mat(Color(0.85, 0.1, 0.1))
	var white := _mat(Color(0.95, 0.95, 0.95))
	for x in [-gate_half_width, gate_half_width]:
		for k in 4:  # striped inflatable column
			var c := CylinderMesh.new()
			c.top_radius = 0.46
			c.bottom_radius = 0.46
			c.height = 1.25
			c.radial_segments = 16
			_part(n, c, red if k % 2 == 0 else white, Vector3(x, 0.62 + k * 1.25, 0))
		var ball := SphereMesh.new()
		ball.radius = 0.6
		ball.height = 1.2
		_part(n, ball, red, Vector3(x, 5.1, 0))
	var segs := 5
	var seg_len := gate_half_width * 2.0 / segs
	for k in segs:  # striped top beam
		var b := CylinderMesh.new()
		b.top_radius = 0.42
		b.bottom_radius = 0.42
		b.height = seg_len
		b.radial_segments = 14
		_part(n, b, red if k % 2 == 0 else white, Vector3(-gate_half_width + seg_len * (k + 0.5), 5.1, 0), Vector3(0, 0, PI * 0.5))
	var banner := BoxMesh.new()
	banner.size = Vector3(gate_half_width * 2.0 - 0.8, 1.3, 0.06)
	_part(n, banner, _mat(Color(0.1, 0.2, 0.5)), Vector3(0, 4.05, 0))
	for z in ([] if "--no-hud" in OS.get_cmdline_user_args() else [0.05, -0.05]):  # no banner text when recording the scene only
		var l := Label3D.new()
		l.text = text
		l.font_size = 150
		l.pixel_size = 0.0075
		l.outline_size = 10
		l.modulate = Color(1, 1, 1)
		l.position = Vector3(0, 4.05, z)
		l.rotation.y = 0.0 if z > 0.0 else PI
		n.add_child(l)
	return n

func _make_confetti() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.position = Vector3(0, 5.3, 0)
	p.amount = 220
	p.lifetime = 6.0
	p.one_shot = true
	p.emitting = false
	p.explosiveness = 0.9
	p.direction = Vector3(0, 1, -0.45)  # up and forward (gate -Z is the run direction), so it rains down ahead of the runner
	p.spread = 55.0
	p.initial_velocity_min = 4.0
	p.initial_velocity_max = 9.0
	p.gravity = Vector3(0, -3.0, 0)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(gate_half_width, 0.2, 0.3)
	var q := QuadMesh.new()
	q.size = Vector2(0.22, 0.22)
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	q.material = m
	p.mesh = q
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(1, 0.2, 0.2), Color(1, 0.85, 0.1), Color(0.2, 0.7, 1), Color(0.3, 0.9, 0.4), Color(1, 0.4, 0.8)])
	g.offsets = PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0])
	g.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	p.color_initial_ramp = g
	p.angular_velocity_min = -300.0
	p.angular_velocity_max = 300.0
	return p
