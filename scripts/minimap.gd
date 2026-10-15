extends Control
# Top-right minimap: the whole route as a line (travelled part bright) and a red dot for the runner.

const W := 300.0
const PAD := 14.0

var _pts := PackedVector2Array()
var _player: Node3D
var _route: Route
var _min := Vector2.ZERO
var _scale := 1.0
var _step := 10.0

func setup(route: Route, player: Node3D) -> void:
	_route = route
	_player = player
	_pts = route.map_points(_step)
	var lo := _pts[0]
	var hi := _pts[0]
	for p in _pts:
		lo = lo.min(p)
		hi = hi.max(p)
	_min = lo
	_scale = (W - 2.0 * PAD) / maxf(hi.x - lo.x, 1.0)
	var h := clampf((hi.y - lo.y) * _scale + 2.0 * PAD, 80.0, 240.0)
	_scale = minf(_scale, (h - 2.0 * PAD) / maxf(hi.y - lo.y, 1.0))
	size = Vector2(W, h)

func _to_map(x: float, z: float) -> Vector2:
	return Vector2(PAD + (x - _min.x) * _scale, PAD + (z - _min.y) * _scale)

func _process(_d: float) -> void:
	position = Vector2(get_viewport_rect().size.x - size.x - 24.0, 20.0)
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.45))
	draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.35), false, 1.5)
	var pp := _player.global_position
	var done := clampi(int(_route.curve.get_closest_offset(_route.to_local(pp)) / _step), 0, _pts.size() - 1)
	var line := PackedVector2Array()
	for p in _pts:
		line.append(_to_map(p.x, p.y))
	draw_polyline(line, Color(1, 1, 1, 0.4), 3.0, true)
	if done > 0:
		draw_polyline(line.slice(0, done + 1), Color(1, 1, 1, 0.95), 3.0, true)
	var me := _to_map(pp.x, pp.z)
	draw_circle(me, 7.5, Color(1, 1, 1))
	draw_circle(me, 5.5, Color(0.9, 0.1, 0.1))
