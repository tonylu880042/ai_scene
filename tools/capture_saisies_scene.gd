extends SceneTree

## Deterministic 1920x1080 reference capture for the continuous v2 Saisies
## scene.  The scene-id is resolved through SaisiesRoute.acceptance_distance,
## so the same route-time mapping drives every scenery module and camera.
##
## Example:
##   godot --path . --script tools/capture_saisies_scene.gd -- \
##     --scene-id=S01 --output=/tmp/saisies_v2_S01.png

const SCENE_PATH := "res://scenes/MainScene_saisies_v2.tscn"
const CAPTURE_SIZE := Vector2i(1920, 1080)

var _scene_id := "S01"
var _output_path := "/tmp/saisies_v2_S01.png"
var _output_explicit := false
var _dry_run := false
var _errors: Array[String] = []

func _initialize() -> void:
	_parse_args()
	call_deferred("_run")

func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scene-id="):
			_scene_id = arg.substr(11).to_upper()
		elif arg.begins_with("--output="):
			_output_path = arg.substr(9)
			_output_explicit = true
		elif arg == "--dry-run":
			_dry_run = true
	if not _output_explicit:
		_output_path = "/tmp/saisies_v2_%s.png" % _scene_id

func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("v2 scene could not be loaded: %s" % SCENE_PATH)
		_finish()
		return
	var scene := packed.instantiate()
	get_root().add_child(scene)
	var root_window := get_root() as Window
	if root_window:
		root_window.size = CAPTURE_SIZE
		root_window.content_scale_size = CAPTURE_SIZE
	await process_frame
	await process_frame
	var route := scene.get_node_or_null("Route") as SaisiesRoute
	var rig := scene.get_node_or_null("CameraRig") as SaisiesCamera
	if route == null or not route.route_ready():
		_fail("v2 scene Route is not ready")
	if rig == null:
		_fail("v2 scene CameraRig is missing")
	if not _errors.is_empty():
		_finish()
		return
	var distance := route.acceptance_distance(_scene_id)
	rig.auto_advance = false
	rig.reset_to_distance(distance)
	if rig.has_method("apply_acceptance_pose"):
		rig.apply_acceptance_pose(_scene_id)
	var camera := rig.get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		_fail("v2 scene CameraRig/Camera3D is missing")
	else:
		camera.current = true
		camera.fov = _fov_for_scene(_scene_id)
	print("saisies scene capture: scene_id=%s distance_m=%.2f output=%s" % [_scene_id, distance, _output_path])
	if _dry_run:
		_finish()
		return
	if DisplayServer.get_name().to_lower().contains("headless"):
		print("saisies scene capture skipped: headless renderer has no viewport image")
		_finish()
		return
	# Village/forest modules build on deferred route readiness. Allow several
	# complete frames before readback, then capture the root viewport (Metal's
	# ordinary runtime path) instead of a second SubViewport.
	for _frame in range(6):
		await process_frame
		await RenderingServer.frame_post_draw
	_save_viewport()
	_finish()

func _fov_for_scene(scene_id: String) -> float:
	match scene_id:
		"S01": return 79.0
		"S02": return 77.0
		"S03": return 76.0
		_: return 78.0

func _save_viewport() -> void:
	var viewport := get_root() as Viewport
	if viewport == null:
		_fail("root viewport is unavailable")
		return
	var texture := viewport.get_texture()
	if texture == null:
		_fail("root viewport texture is unavailable")
		return
	var image := texture.get_image()
	if image == null:
		_fail("root viewport image is unavailable")
		return
	if not _image_has_visible_pixels(image):
		_fail("reference viewport image is black or empty")
		return
	var output := ProjectSettings.globalize_path(_output_path)
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var error := image.save_png(output)
	if error != OK:
		_fail("reference PNG save failed: %s" % output)
	else:
		print("saisies scene capture: ", output)

func _image_has_visible_pixels(image: Image) -> bool:
	var size := image.get_size()
	if size.x <= 0 or size.y <= 0:
		return false
	var stride := maxi(1, mini(size.x, size.y) / 128)
	var max_value := 0.0
	for y in range(0, size.y, stride):
		for x in range(0, size.x, stride):
			var pixel := image.get_pixel(x, y)
			max_value = maxf(max_value, maxf(pixel.r, maxf(pixel.g, pixel.b)))
	return max_value > 0.01

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES SCENE CAPTURE: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES SCENE CAPTURE PASS")
		quit(0)
	else:
		print("SAISIES SCENE CAPTURE FAIL (%d errors)" % _errors.size())
		quit(1)
