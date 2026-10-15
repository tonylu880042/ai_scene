extends Node3D
# Winter roadside props along the Route, built once in chunk_m pieces (children of this node, so
# tools/export_unity.gd tiles them like the other props): thin snow poles marking the road edges and a power line of
# wooden poles with sagging wires (only in sections with "power": true).

@export var path_node: NodePath
@export var chunk_m := 100.0
@export var pole_step := Vector2(12.0, 18.0)   # snow poles: metres between poles (each side alternating)
@export var pole_skip := 0.2                   # share of snow poles missing
@export var power_step := 55.0                 # metres between power line poles
@export var power_offset := Vector2(4.0, 7.0)  # power poles this far beyond the road edge
@export var random_seed := 7

var _route: Route
var _mat := StandardMaterial3D.new()

func _ready() -> void:
	_route = get_node(path_node)
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 0.85
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed
	var power_side := 1.0 if rng.randf() < 0.5 else -1.0
	var tops := []  # previous power pole's wire attachment points (world), continued across chunks
	for c in ceili(_route.length / chunk_m):
		var s0 := c * chunk_m
		var s1 := minf(s0 + chunk_m, _route.length)
		var holder := Node3D.new()
		holder.name = "winter_props_%03d" % c
		holder.position = _route.pos_at((s0 + s1) * 0.5)
		add_child(holder)
		var o := holder.position
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		# snow poles, alternating sides
		var s := s0 + rng.randf() * pole_step.x
		var side := 1.0
		while s < s1:
			if rng.randf() >= pole_skip:
				var u := side * ((_route.half_left(s) if side > 0.0 else _route.half_right(s)) + rng.randf_range(0.3, 0.6))
				var b := _route.pos_at(s) + _route.left_at(s) * u
				b.y = _route.ground_y(s, u) - 0.2
				var lean := Vector3(rng.randf_range(-0.06, 0.06), 0, rng.randf_range(-0.06, 0.06))
				_tube(st, b - o, b - o + Vector3(0, 1.9, 0) + lean, 0.025, Color(0.62, 0.42, 0.24))
				_tube(st, b - o + Vector3(0, 1.75, 0) + lean * 0.9, b - o + Vector3(0, 1.9, 0) + lean, 0.028, Color(0.85, 0.3, 0.1))  # coloured tip
			side = -side
			s += rng.randf_range(pole_step.x, pole_step.y)
		# power line
		s = ceilf(s0 / power_step) * power_step
		while s < s1:
			if bool(_route.section_at(s).get("power", false)):
				var u := power_side * ((_route.half_left(s) if power_side > 0.0 else _route.half_right(s)) + rng.randf_range(power_offset.x, power_offset.y))
				var b := _route.pos_at(s) + _route.left_at(s) * u
				b.y = _route.ground_y(s, u) - 0.5
				var wood := Color(0.3, 0.22, 0.16)
				var top := b + Vector3(0, 9.5, 0)
				_tube(st, b - o, top - o, 0.13, wood)
				var across := _route.left_at(s) * 0.9
				var arm := top + Vector3(0, -0.6, 0)
				_tube(st, arm - across - o, arm + across - o, 0.06, wood)
				var now := [arm - across, top + Vector3(0, 0.05, 0), arm + across]
				if tops.size() == 3:
					for k in 3:
						_wire(st, tops[k], now[k], o)
				tops = now
			else:
				tops = []
			s += power_step
		var mesh := st.commit()
		if mesh.get_surface_count() > 0:
			mesh.surface_set_material(0, _mat)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			holder.add_child(mi)

# sagging wire between two attachment points (world), as a thin tube in the holder's frame
func _wire(st: SurfaceTool, a: Vector3, b: Vector3, o: Vector3) -> void:
	var prev := a
	for k in range(1, 9):
		var t := k / 8.0
		var p := a.lerp(b, t) - Vector3(0, 0.9 * 4.0 * t * (1.0 - t), 0)
		_tube(st, prev - o, p - o, 0.012, Color(0.08, 0.08, 0.08))
		prev = p

# 4-sided tube from a to b, flat-shaded, wound clockwise seen from outside: Godot's front faces (its glTF export
# flips them to glTF's counter-clockwise)
func _tube(st: SurfaceTool, a: Vector3, b: Vector3, r: float, col: Color) -> void:
	var d := (b - a).normalized()
	var side := d.cross(Vector3.UP if absf(d.y) < 0.95 else Vector3.RIGHT).normalized()
	var up := side.cross(d)
	st.set_color(col)
	for i in 4:
		var n0 := side * cos(TAU * i / 4.0) + up * sin(TAU * i / 4.0)
		var n1 := side * cos(TAU * (i + 1) / 4.0) + up * sin(TAU * (i + 1) / 4.0)
		var n := (n0 + n1).normalized()
		var q := [a + n0 * r, b + n0 * r, b + n1 * r, a + n1 * r]
		if (q[1] - q[0]).cross(q[3] - q[0]).dot(n) > 0.0:
			q = [q[0], q[3], q[2], q[1]]
		st.set_normal(n)
		for k in [0, 1, 2, 0, 2, 3]:
			st.add_vertex(q[k])
