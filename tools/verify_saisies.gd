extends SceneTree

## Focused smoke test for the pure Saisies environment scene.
##
## Examples:
##   godot --headless --path . --script tools/verify_saisies.gd
##   godot --headless --path . --script tools/verify_saisies.gd -- --start-km=7.9
##   godot --path . --script tools/verify_saisies.gd -- --start-km=2.3 --capture=/tmp/saisies.png --capture-after=1.2

var _errors: Array[String] = []
var _capture_path := ""
var _capture_after := 0.0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture="):
			_capture_path = arg.substr(10)
		elif arg.begins_with("--capture-after="):
			_capture_after = maxf(float(arg.substr(16)), 0.0)
	call_deferred("_run")

func _run() -> void:
	var packed := load("res://scenes/MainScene_saisies.tscn") as PackedScene
	if packed == null:
		_fail("MainScene_saisies.tscn could not be loaded")
		_finish()
		return
	var scene := packed.instantiate()
	get_root().add_child(scene)
	await process_frame
	var route := scene.get_node_or_null("Route") as Node
	if route == null:
		_fail("Route node is missing")
	else:
		_verify_route(route)
		_verify_scene_nodes(scene, route)
	if not _capture_path.is_empty():
		await create_timer(maxf(_capture_after, 0.2)).timeout
		# A dummy headless renderer may never emit frame_post_draw.  A regular
		# process frame is sufficient for the non-headless Metal capture path and
		# keeps this optional harness finite in CI/headless checks.
		await process_frame
		_save_capture()
	_finish()

func _verify_route(route: Node) -> void:
	if not bool(route.call("route_ready")):
		_fail("route_ready() is false")
		return
	var length_m := float(route.get("length_m"))
	var spacing := maxf(float(route.get("sample_spacing_m")), 2.0)
	if length_m < 14000.0 or length_m > 16000.0:
		_fail("route length %.1f m is outside the Saisies target" % length_m)
	var previous := Vector3.ZERO
	var have_previous := false
	var step := maxf(spacing * 5.0, 20.0)
	var samples := 0
	var min_grade := INF
	var max_grade := -INF
	for s in range(0, int(ceil(length_m)) + 1, int(step)):
		var distance := minf(float(s), length_m)
		var point: Vector3 = route.call("pos_at", distance)
		var width := float(route.call("road_width_at", distance))
		var grade := float(route.call("grade_at", distance))
		if width < 4.0 or width > 12.0:
			_fail("road width %.2f m at %.0f m is invalid" % [width, distance])
		if absf(grade) > 20.0:
			_fail("grade %.2f%% at %.0f m is outside the authored range" % [grade, distance])
		min_grade = minf(min_grade, grade)
		max_grade = maxf(max_grade, grade)
		if have_previous and previous.distance_to(point) > step * 1.8 + 6.0:
			_fail("route gap %.2f m near %.0f m" % [previous.distance_to(point), distance])
		previous = point
		have_previous = true
		samples += 1
	var first_elevation := float(route.call("elevation_at", 0.0))
	var last_elevation := float(route.call("elevation_at", length_m))
	if absf(first_elevation - 1594.0) > 4.0 or absf(last_elevation - 717.0) > 4.0:
		_fail("elevation endpoints %.1f -> %.1f m do not match route data" % [first_elevation, last_elevation])
	for distance in [0.0, length_m * 0.25, length_m * 0.5, length_m * 0.75, length_m - 0.1]:
		var section: Dictionary = route.call("section_at", distance)
		if section.is_empty():
			_fail("missing section at %.0f m" % distance)
	var collision := route.get_node_or_null("SaisiesRoadCollision/ContinuousRoadSurface") as CollisionShape3D
	if collision == null or not (collision.shape is ConcavePolygonShape3D):
		_fail("continuous concave road collision is missing")
	else:
		var faces := (collision.shape as ConcavePolygonShape3D).get_faces()
		if faces.size() < 18:
			_fail("road collision has too few faces: %d" % faces.size())
	print("saisies route: %.1f m, %d samples, grade %.2f%%..%.2f%%, collision faces %d" % [length_m, samples, min_grade, max_grade, (collision.shape as ConcavePolygonShape3D).get_faces().size() if collision else 0])

func _verify_scene_nodes(scene: Node, route: Node) -> void:
	if scene.get_node_or_null("CameraRig/Camera3D") == null:
		_fail("invisible CameraRig/Camera3D is missing")
	if scene.get_node_or_null("Scenery") == null:
		_fail("Scenery environment node is missing")
	else:
		var has_broadleaf := false
		var has_conifer := false
		for child in (scene.get_node("Scenery") as Node).get_children():
			var child_name := String(child.name)
			has_broadleaf = has_broadleaf or child_name.begins_with("SaisiesTrees_broadleaf_")
			has_conifer = has_conifer or child_name.begins_with("SaisiesTrees_conifer_")
		if not has_broadleaf:
			_fail("mixed forest has no broadleaf MultiMesh")
		if not has_conifer:
			_fail("mixed forest has no conifer MultiMesh")
	var landscape := scene.get_node_or_null("Landscape") as Node
	if landscape == null:
		_fail("static Landscape node is missing")
	else:
		var landscape_mesh := landscape.get_node_or_null("SaisiesStaticLandscape") as MeshInstance3D
		if landscape_mesh == null or landscape_mesh.mesh == null:
			_fail("static landscape heightfield mesh is missing")
		var landscape_vertices := int(landscape.get_meta("saisies_landscape_vertex_count", 0))
		var landscape_triangles := int(landscape.get_meta("saisies_landscape_triangle_count", 0))
		if landscape_vertices < 1000 or landscape_triangles < 1800:
			_fail("static landscape is too small: %d vertices / %d triangles" % [landscape_vertices, landscape_triangles])
		print("saisies landscape: %d vertices, %d triangles" % [landscape_vertices, landscape_triangles])
	var world_environment := scene.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_environment == null or world_environment.environment == null or world_environment.environment.sky == null:
		_fail("HDRI sky environment is missing")
	if scene.get_node_or_null("Route/SaisiesAsphalt") == null:
		_fail("asphalt road mesh is missing")
	if scene.get_node_or_null("Route/SaisiesGravelShoulders") == null:
		_fail("gravel road shoulder mesh is missing")
	_verify_guardrails(scene, route)
	if scene.get_node_or_null("Bike") != null:
		_fail("pure environment scene still instantiates Bike")
	if scene.get_node_or_null("HUD") != null:
		_fail("pure environment scene still instantiates HUD")

func _verify_guardrails(scene: Node, route: Node) -> void:
	var scenery := scene.get_node_or_null("Scenery") as Node
	if scenery == null:
		return
	var rail_count := int(scenery.get_meta("saisies_guardrail_beams", 0))
	var post_count := int(scenery.get_meta("saisies_guardrail_posts", 0))
	var min_rail_dot := float(scenery.get_meta("saisies_guardrail_min_alignment", 0.0))
	var min_rail_length := float(scenery.get_meta("saisies_guardrail_min_span", 0.0))
	var max_rail_length := float(scenery.get_meta("saisies_guardrail_max_span", 0.0))
	var min_post_upright := float(scenery.get_meta("saisies_guardrail_post_upright", 0.0))
	if rail_count == 0:
		_fail("no guardrail beam instances were generated")
	elif min_rail_dot < 0.999:
		_fail("guardrail local-Z alignment %.5f is below 0.999" % min_rail_dot)
	elif min_rail_length < 10.0 or max_rail_length > 15.0:
		_fail("guardrail beam lengths %.2f..%.2f m are not 12 m spans" % [min_rail_length, max_rail_length])
	if post_count == 0:
		_fail("no upright guardrail posts were generated")
	elif min_post_upright < 0.999:
		_fail("guardrail post upright dot %.5f is below 0.999" % min_post_upright)
	print("saisies guardrails: %d beams, %d posts, direction dot %.5f, span %.2f..%.2f m, post upright %.5f" % [rail_count, post_count, min_rail_dot, min_rail_length, max_rail_length, min_post_upright])

func _save_capture() -> void:
	if DisplayServer.get_name().to_lower().contains("headless"):
		print("saisies capture skipped: headless renderer has no viewport image")
		return
	var viewport := get_root()
	if viewport == null or viewport.get_texture() == null:
		_fail("capture viewport texture is unavailable")
		return
	var output := ProjectSettings.globalize_path(_capture_path)
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var image := viewport.get_texture().get_image()
	if image == null:
		_fail("capture viewport image is unavailable")
		return
	var err := image.save_png(output)
	if err != OK:
		_fail("capture failed: %s" % output)
	else:
		print("saisies capture: ", output)

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES VERIFY: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES VERIFY PASS")
		quit(0)
	else:
		print("SAISIES VERIFY FAIL (%d errors)" % _errors.size())
		quit(1)
