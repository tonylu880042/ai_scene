extends SceneTree

## Isolated 1920x1080 preview for the two-chalet roadside landmark.
## Example:
##   godot --path . --script res://tools/preview_saisies_roadside_chalets.gd -- \
##     --output=/tmp/saisies_roadside_chalets.png

const SCENE_PATH := "res://scenes/props/SaisiesRoadsideChalets.tscn"
const CAPTURE_SIZE := Vector2i(1920, 1080)

var _output_path := "/tmp/saisies_roadside_chalets.png"
var _view := "iso"
var _errors: Array[String] = []

func _initialize() -> void:
	_parse_args()
	call_deferred("_run")

func _parse_args() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			_output_path = argument.substr(9)
		elif argument.begins_with("--view="):
			_view = argument.substr(7).to_lower()

func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("could not load chalet scene: %s" % SCENE_PATH)
		_finish()
		return
	var world := Node3D.new()
	world.name = "SaisiesRoadsideChaletsPreview"
	get_root().add_child(world)
	var chalets := packed.instantiate()
	world.add_child(chalets)
	_add_environment(world)
	_add_ground(world)
	_add_camera(world)
	var root_window := get_root() as Window
	if root_window != null:
		root_window.size = CAPTURE_SIZE
		root_window.content_scale_size = CAPTURE_SIZE
	await process_frame
	await process_frame
	var group := chalets.get_node_or_null("AdjoiningAlpineChalets")
	if group == null:
		_fail("generated chalet group is missing")
	else:
		_verify_geometry(chalets, group)
	print("saisies chalet preview: view=%s meshes=%d bounds=%s" % [_view, _mesh_count(group), _mesh_bounds(group)])
	if not _errors.is_empty():
		_finish()
		return
	if DisplayServer.get_name().to_lower().contains("headless"):
		print("saisies chalet preview: headless renderer verified geometry; native capture skipped")
		_finish()
		return
	for _frame in range(3):
		await process_frame
		await RenderingServer.frame_post_draw
	RenderingServer.force_draw()
	await RenderingServer.frame_post_draw
	_save_viewport()
	_finish()

func _add_environment(world: Node3D) -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.40, 0.63, 0.82)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.72, 0.78, 0.86)
	environment.ambient_light_energy = 0.75
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	var world_environment := WorldEnvironment.new()
	world_environment.name = "PreviewEnvironment"
	world_environment.environment = environment
	world.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.name = "PreviewSun"
	sun.rotation_degrees = Vector3(-48.0, -32.0, 0.0)
	sun.light_color = Color(1.0, 0.92, 0.79)
	sun.light_energy = 1.55
	sun.shadow_enabled = true
	world.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.name = "PreviewFill"
	fill.rotation_degrees = Vector3(-28.0, 145.0, 0.0)
	fill.light_color = Color(0.68, 0.78, 1.0)
	fill.light_energy = 0.28
	world.add_child(fill)

func _add_ground(world: Node3D) -> void:
	var ground_mesh := BoxMesh.new()
	ground_mesh.size = Vector3(34.0, 0.16, 26.0)
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.27, 0.36, 0.24)
	ground_material.roughness = 0.94
	var ground := MeshInstance3D.new()
	ground.name = "PreviewGround"
	ground.mesh = ground_mesh
	ground.material_override = ground_material
	ground.position = Vector3(0.0, -0.08, 0.7)
	world.add_child(ground)

func _add_camera(world: Node3D) -> void:
	var camera := Camera3D.new()
	camera.name = "PreviewCamera"
	camera.current = true
	camera.fov = 48.0 if _view == "front" else 52.0
	camera.near = 0.05
	camera.far = 120.0
	world.add_child(camera)
	if _view == "front":
		camera.look_at_from_position(Vector3(0.0, 5.2, -22.5), Vector3(0.0, 3.0, 0.6), Vector3.UP)
	else:
		# Front gables remain dominant while the camera also reveals the near
		# chalet's right side, eaves, balcony depth, and the stepped rear house.
		camera.look_at_from_position(Vector3(12.4, 8.0, -21.5), Vector3(0.0, 3.0, 0.55), Vector3.UP)

func _verify_geometry(root_node: Node, group: Node) -> void:
	if root_node.get_meta("saisies_roadside_chalets_ready", false) != true:
		_fail("chalet prefab did not set ready metadata")
	if int(root_node.get_meta("saisies_roadside_chalets_count", 0)) != 2:
		_fail("expected exactly two chalet roots")
	var near := group.get_node_or_null("NearChalet")
	var rear := group.get_node_or_null("RearChalet")
	if near == null or rear == null:
		_fail("near/rear chalet roots are missing")
		return
	if absf(float(rear.position.x - near.position.x) - 7.2) > 0.01:
		_fail("chalet X stagger is not 7.2 m")
	if absf(float(rear.position.z - near.position.z) - 1.3) > 0.01:
		_fail("rear chalet setback is not 1.3 m")
	if _mesh_count(group) < 90:
		_fail("generated chalet detail count is unexpectedly low")
	var bounds := _mesh_bounds(group)
	if bounds.size.x < 13.0 or bounds.size.z < 8.0 or bounds.size.y < 6.0:
		_fail("generated chalet bounds are too small: %s" % bounds)

func _mesh_count(node: Node) -> int:
	return node.find_children("*", "MeshInstance3D", true, false).size()

func _mesh_bounds(node: Node) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	for candidate in node.find_children("*", "MeshInstance3D", true, false):
		var instance := candidate as MeshInstance3D
		if instance == null or instance.mesh == null:
			continue
		var local_bounds := _transform_aabb(instance.get_aabb(), instance.global_transform)
		if not has_bounds:
			bounds = local_bounds
			has_bounds = true
		else:
			bounds = bounds.merge(local_bounds)
	return bounds

func _transform_aabb(source: AABB, transform: Transform3D) -> AABB:
	var result := AABB()
	var has_point := false
	for x in [source.position.x, source.end.x]:
		for y in [source.position.y, source.end.y]:
			for z in [source.position.z, source.end.z]:
				var point := transform * Vector3(x, y, z)
				if not has_point:
					result = AABB(point, Vector3.ZERO)
					has_point = true
				else:
					result = result.expand(point)
	return result

func _save_viewport() -> void:
	var viewport := get_root() as Viewport
	if viewport == null or viewport.get_texture() == null:
		_fail("root viewport texture is unavailable")
		return
	var image := viewport.get_texture().get_image()
	if image == null or image.get_width() <= 0 or image.get_height() <= 0:
		_fail("preview image is empty")
		return
	var output := ProjectSettings.globalize_path(_output_path)
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var error := image.save_png(output)
	if error != OK:
		_fail("could not save preview PNG: %s" % output)
	else:
		print("saisies chalet preview saved: %s (%dx%d)" % [output, image.get_width(), image.get_height()])

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("saisies chalet preview: " + message)

func _finish() -> void:
	if _errors.is_empty():
		quit(0)
	else:
		quit(1)
