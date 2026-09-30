extends CanvasLayer

@export var player_path: NodePath
@export var route_path: NodePath
@export var gates_path: NodePath
var _gates: Node
var _finish := Label.new()
var _route: Route
var _player: CharacterBody3D
var _label := Label.new()
var _time := 0.0
var _dist := 0.0

func _ready() -> void:
	if "--no-hud" in OS.get_cmdline_user_args():  # scene only: no text, no minimap, no finish overlay
		visible = false
	_player = get_node(player_path)
	_route = get_node_or_null(route_path)
	_gates = get_node_or_null(gates_path)
	if _route:
		_time = _route.start_time
		var mm := Control.new()
		mm.set_script(load("res://minimap.gd"))
		add_child(mm)
		mm.setup(_route, _player)
	_label.position = Vector2(24, 20)
	_label.add_theme_font_size_override("font_size", 26)
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_label.add_theme_constant_override("shadow_offset_x", 2)
	_label.add_theme_constant_override("shadow_offset_y", 2)
	add_child(_label)
	_finish.add_theme_font_size_override("font_size", 64)
	_finish.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_finish.add_theme_constant_override("shadow_offset_x", 3)
	_finish.add_theme_constant_override("shadow_offset_y", 3)
	_finish.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_finish.visible = false
	add_child(_finish)

func _process(delta: float) -> void:
	var v := Vector2(_player.velocity.x, _player.velocity.z).length()
	var done: bool = _gates != null and _gates.finished
	if not done:
		_time += delta
		_dist += v * delta
	else:
		_finish.visible = true
		var size := get_viewport().get_visible_rect().size
		_finish.size = Vector2(size.x, 200)
		_finish.position = Vector2(0, size.y * 0.3)
		_finish.text = "FINISH\n%02d:%02d  ·  %.2f km" % [int(_time) / 60, int(_time) % 60, _dist / 1000.0]
	var pace := "--:--"
	if v > 0.3:
		var sec := int(1000.0 / v)
		pace = "%d:%02d" % [sec / 60, sec % 60]
	var course := ""
	if _route:
		var info := _route.info_at(_time)
		var total := int(_route.total_minutes * 60.0)
		course = "%s · %s · Incline %d%%   %02d:%02d / %02d:%02d\n" % [String(_route.course).capitalize().replace("_", " "),
				info["phase"], info["incline"], int(_time) / 60, int(_time) % 60, total / 60, total % 60]
	_label.text = course + "Pace %s /km   Time %02d:%02d   Dist %.2f km\nF1 HUD · F11 fullscreen · Tab auto/manual · Esc mouse" % [
			pace, int(_time) / 60, int(_time) % 60, _dist / 1000.0]

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed:
		if e.keycode == KEY_F1:
			visible = not visible
		elif e.keycode == KEY_F11:
			var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)
