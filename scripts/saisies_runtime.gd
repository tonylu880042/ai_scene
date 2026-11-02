extends Node3D

## Small command-line harness for visual verification without changing the normal
## project startup scene. Examples:
##   godot --path . res://scenes/MainScene_saisies.tscn -- --quit-after=8
##   godot --path . res://scenes/MainScene_saisies.tscn -- --start-km=6.4 --capture=/tmp/saisies.png --capture-after=1.5 --quit-after=3

@export var camera_path: NodePath
@export var route_path: NodePath

var _camera: Node3D
var _route: SaisiesRoute
var _elapsed := 0.0
var _quit_after := -1.0
var _capture_after := -1.0
var _capture_path := ""
var _captured := false
var _capture_done := false

func _ready() -> void:
	_camera = get_node_or_null(camera_path) as Node3D
	_route = get_node_or_null(route_path) as SaisiesRoute
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--quit-after="):
			_quit_after = maxf(float(arg.substr(13)), 0.1)
		elif arg.begins_with("--capture="):
			_capture_path = arg.substr(10)
			if _capture_after < 0.0:
				_capture_after = 1.0
		elif arg.begins_with("--capture-after="):
			_capture_after = maxf(float(arg.substr(16)), 0.0)
		elif arg.begins_with("--start-km=") and _camera:
			if _camera.has_method("reset_to_distance"):
				_camera.call("reset_to_distance", float(arg.substr(11)) * 1000.0)
		elif arg.begins_with("--start-m=") and _camera:
			if _camera.has_method("reset_to_distance"):
				_camera.call("reset_to_distance", float(arg.substr(10)))
	if not _capture_path.is_empty() and _quit_after < 0.0:
		# A capture invocation should be finite even when the caller omits the
		# optional quit flag (useful for quick headless smoke checks).
		_quit_after = maxf(_capture_after + 1.0, 1.5)

func _process(delta: float) -> void:
	_elapsed += delta
	if not _captured and not _capture_path.is_empty() and _capture_after >= 0.0 and _elapsed >= _capture_after:
		_captured = true
		_capture_frame.call_deferred()
	# A deferred capture may still be waiting for the renderer after the nominal
	# quit time. Keep the process alive until the image write (or an explicit
	# headless skip/error) has completed.
	if _quit_after >= 0.0 and _elapsed >= _quit_after and (_capture_path.is_empty() or _capture_done):
		get_tree().quit()

func _capture_frame() -> void:
	if DisplayServer.get_name().to_lower().contains("headless"):
		print("saisies capture skipped: headless renderer has no viewport image")
		_capture_done = true
		return
	await RenderingServer.frame_post_draw
	if not is_inside_tree():
		_capture_done = true
		return
	var texture := get_viewport().get_texture()
	if texture == null:
		push_error("Saisies capture failed: viewport texture unavailable")
		_capture_done = true
		return
	var image := texture.get_image()
	if image == null:
		push_error("Saisies capture failed: viewport image unavailable")
		_capture_done = true
		return
	var output := ProjectSettings.globalize_path(_capture_path)
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var err := image.save_png(output)
	if err == OK:
		print("saisies capture: ", output)
	else:
		push_error("Saisies capture failed: " + output)
	_capture_done = true
