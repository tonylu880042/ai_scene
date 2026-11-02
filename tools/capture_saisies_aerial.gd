extends SceneTree

## Capture a full-route aerial view from the baked Saisies environment.
##
## Examples:
##   godot --path . --script tools/capture_saisies_aerial.gd -- \
##     --output=/tmp/saisies_aerial_top.png --view=top --highlight-route
##   godot --path . --script tools/capture_saisies_aerial.gd -- \
##     --output=/tmp/saisies_aerial_oblique.png --view=oblique
##
## The route fit is derived from Route/Curve3D points.  No hand-drawn path or
## outer Landscape bounds are used, so the road remains the visual anchor.

const BAKED_SCENE := "res://export/saisies/SaisiesEnvironment.scn"
const TOP_SIZE := Vector2i(1600, 2400)
const OBLIQUE_SIZE := Vector2i(2400, 1600)
const ROUTE_RIBBON_WIDTH_M := 20.0
const ROUTE_RIBBON_LIFT_M := 4.0
const FIT_MARGIN_RATIO := 0.06
const OBLIQUE_DEPRESSION_DEG := 28.0

var _output_path := "/tmp/saisies_aerial_top.png"
var _view := "top"
var _highlight_route := false
var _dry_run := false
var _errors: Array[String] = []

func _initialize() -> void:
	_parse_args()
	call_deferred("_run")

func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			_output_path = arg.substr(9)
		elif arg.begins_with("--view="):
			_view = "oblique" if arg.substr(7).to_lower() == "oblique" else "top"
		elif arg == "--highlight-route":
			_highlight_route = true
		elif arg == "--dry-run":
			_dry_run = true

func _run() -> void:
	var packed := load(BAKED_SCENE) as PackedScene
	if packed == null:
		_fail("baked scene could not be loaded: %s" % BAKED_SCENE)
		_finish()
		return

	var viewport := SubViewport.new()
	viewport.name = "SaisiesAerialViewport"
	viewport.size = OBLIQUE_SIZE if _view == "oblique" else TOP_SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.transparent_bg = false
	viewport.own_world_3d = true
	get_root().add_child(viewport)

	var scene := packed.instantiate()
	viewport.add_child(scene)
	await process_frame

	var route := scene.get_node_or_null("Route") as Path3D
	if route == null or route.curve == null:
		_fail("baked scene Route/Curve3D is missing")
		_finish()
		return
	var points := _route_world_points(route)
	if points.size() < 2:
		_fail("Route/Curve3D has too few baked points")
		_finish()
		return

	_disable_original_cameras(scene)
	_disable_distance_culling(scene)
	_disable_capture_shadows(scene)
	_disable_aerial_fog(scene)
	if _highlight_route:
		_add_route_highlight(scene, points)

	var camera := Camera3D.new()
	camera.name = "SaisiesAerialCamera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.1
	camera.far = 40000.0
	camera.current = true
	scene.add_child(camera)
	_configure_camera(camera, points, viewport.size)

	var route_bounds := _world_bounds(points)
	print("saisies aerial: view=%s points=%d world_bounds=%s camera_size=%.1f output=%s" % [
		_view, points.size(), route_bounds, camera.size, _output_path
	])
	if _dry_run:
		_finish()
		return
	if DisplayServer.get_name().to_lower().contains("headless"):
		print("saisies aerial capture skipped: headless renderer has no viewport image")
		_finish()
		return

	# Let the baked scene, sky and the new camera render several complete frames
	# before reading the SubViewport texture. This avoids the one-frame capture
	# race seen in ordinary runtime screenshots.
	for _frame in range(3):
		await process_frame
		await RenderingServer.frame_post_draw
	_save_viewport(viewport)
	_finish()

func _route_world_points(route: Path3D) -> PackedVector3Array:
	var points := PackedVector3Array()
	var local_points := route.curve.get_baked_points()
	for local_point in local_points:
		points.append(route.to_global(local_point))
	return points

func _world_bounds(points: PackedVector3Array) -> AABB:
	var bounds := AABB(points[0], Vector3.ZERO)
	for i in range(1, points.size()):
		bounds = bounds.expand(points[i])
	return bounds

func _disable_original_cameras(scene: Node) -> void:
	for candidate in scene.find_children("*", "Camera3D", true, false):
		var old_camera := candidate as Camera3D
		if old_camera:
			old_camera.current = false
	var rig := scene.get_node_or_null("CameraRig") as Node
	if rig:
		rig.process_mode = Node.PROCESS_MODE_DISABLED

func _disable_distance_culling(scene: Node) -> void:
	for candidate in scene.find_children("*", "GeometryInstance3D", true, false):
		var geometry := candidate as GeometryInstance3D
		if geometry:
			# The baked roadside MultiMeshes are intentionally culled at rider
			# distance. An aerial camera must see the complete route in one pass.
			geometry.visibility_range_end = 0.0

func _disable_capture_shadows(scene: Node) -> void:
	for candidate in scene.find_children("*", "DirectionalLight3D", true, false):
		var light := candidate as DirectionalLight3D
		if light:
			# Aerial capture covers the complete 14.8 km route. Rebuilding a
			# scene-wide directional shadow map can stall Metal before readback.
			light.shadow_enabled = false

func _disable_aerial_fog(scene: Node) -> void:
	var world_environment := scene.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_environment == null or world_environment.environment == null:
		return
	# Duplicate the resource on the capture instance so the baked scene keeps
	# its cinematic aerial perspective for ordinary runtime use.
	var aerial_environment := world_environment.environment.duplicate() as Environment
	if aerial_environment == null:
		return
	aerial_environment.fog_enabled = false
	# Keep the baked HDRI available for ambient light and reflections, but use a
	# calm color background for the very distant orthographic aerial horizon.
	aerial_environment.background_mode = Environment.BG_COLOR
	aerial_environment.background_color = Color(0.50, 0.70, 0.90)
	world_environment.environment = aerial_environment

func _configure_camera(camera: Camera3D, points: PackedVector3Array, viewport_size: Vector2i) -> void:
	var route_bounds := _world_bounds(points)
	var target := route_bounds.position + route_bounds.size * 0.5
	var horizontal_span := maxf(route_bounds.size.x, route_bounds.size.z)
	if _view == "top":
		var height := maxf(horizontal_span * 1.25, 12000.0)
		camera.position = target + Vector3.UP * height
		camera.look_at(target, Vector3.FORWARD)
	else:
		var overall_direction := Vector3(points[-1].x - points[0].x, 0.0, points[-1].z - points[0].z)
		if overall_direction.length_squared() < 1.0:
			overall_direction = Vector3(0.0, 0.0, -1.0)
		overall_direction = overall_direction.normalized()
		var side := Vector3(-overall_direction.z, 0.0, overall_direction.x).normalized()
		var horizontal_distance := maxf(horizontal_span * 0.72, 7000.0)
		var height := horizontal_distance * tan(deg_to_rad(OBLIQUE_DEPRESSION_DEG))
		camera.position = target + side * horizontal_distance + Vector3.UP * height
		camera.look_at(target, Vector3.UP)

	# Orthographic size is vertical world extent. Projecting the actual route
	# points accounts for the camera yaw/pitch and keeps both endpoints visible.
	var inverse_camera := camera.global_transform.affine_inverse()
	var min_projected := Vector2(INF, INF)
	var max_projected := Vector2(-INF, -INF)
	for point in points:
		var projected := inverse_camera * point
		min_projected.x = minf(min_projected.x, projected.x)
		min_projected.y = minf(min_projected.y, projected.y)
		max_projected.x = maxf(max_projected.x, projected.x)
		max_projected.y = maxf(max_projected.y, projected.y)
	var projected_size := max_projected - min_projected
	var margin := maxf(maxf(projected_size.x, projected_size.y) * FIT_MARGIN_RATIO, 120.0)
	var aspect := float(viewport_size.x) / float(viewport_size.y)
	camera.size = maxf(projected_size.y + margin * 2.0, (projected_size.x + margin * 2.0) / aspect)

func _add_route_highlight(scene: Node, points: PackedVector3Array) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_width := ROUTE_RIBBON_WIDTH_M * 0.5
	for i in range(points.size() - 1):
		var p0 := points[i] + Vector3.UP * ROUTE_RIBBON_LIFT_M
		var p1 := points[i + 1] + Vector3.UP * ROUTE_RIBBON_LIFT_M
		var tangent0 := _horizontal_tangent(points, i)
		var tangent1 := _horizontal_tangent(points, i + 1)
		var left0 := Vector3(tangent0.z, 0.0, -tangent0.x) * half_width
		var left1 := Vector3(tangent1.z, 0.0, -tangent1.x) * half_width
		var a := p0 + left0
		var b := p0 - left0
		var c := p1 - left1
		var d := p1 + left1
		surface.add_vertex(a); surface.add_vertex(b); surface.add_vertex(c)
		surface.add_vertex(a); surface.add_vertex(c); surface.add_vertex(d)
	surface.generate_normals()
	var mesh := surface.commit()
	var ribbon := MeshInstance3D.new()
	ribbon.name = "AerialRouteHighlight"
	ribbon.mesh = mesh
	ribbon.material_override = _highlight_material()
	ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene.add_child(ribbon)
	_add_endpoint_marker(scene, points[0], Color(0.95, 0.18, 0.04))
	_add_endpoint_marker(scene, points[-1], Color(0.12, 0.85, 0.30))

func _horizontal_tangent(points: PackedVector3Array, index: int) -> Vector3:
	var a := points[maxi(index - 1, 0)]
	var b := points[mini(index + 1, points.size() - 1)]
	var tangent := Vector3(b.x - a.x, 0.0, b.z - a.z)
	if tangent.length_squared() < 0.0001:
		return Vector3(0.0, 0.0, -1.0)
	return tangent.normalized()

func _highlight_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.16, 0.015)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.06, 0.005)
	material.emission_energy_multiplier = 2.4
	material.roughness = 0.45
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = 10
	return material

func _add_endpoint_marker(scene: Node, point: Vector3, color: Color) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 34.0
	mesh.height = 68.0
	var marker := MeshInstance3D.new()
	marker.name = "AerialRouteEndpoint"
	marker.mesh = mesh
	marker.position = point + Vector3.UP * (ROUTE_RIBBON_LIFT_M + 28.0)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 2.0
	marker.material_override = material
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene.add_child(marker)

func _save_viewport(viewport: SubViewport) -> void:
	var texture := viewport.get_texture()
	if texture == null:
		_fail("aerial viewport texture is unavailable")
		return
	var image := texture.get_image()
	if image == null:
		_fail("aerial viewport image is unavailable")
		return
	if not _image_has_visible_pixels(image):
		_fail("aerial viewport image is black or empty")
		return
	var output := ProjectSettings.globalize_path(_output_path)
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var error := image.save_png(output)
	if error != OK:
		_fail("aerial PNG save failed: %s" % output)
	else:
		print("saisies aerial capture: ", output)

func _image_has_visible_pixels(image: Image) -> bool:
	var size := image.get_size()
	if size.x <= 0 or size.y <= 0:
		return false
	# Sample a regular grid so the guard is cheap while still catching a
	# clear-black Metal readback before a misleading successful PNG is written.
	var stride := maxi(1, mini(size.x, size.y) / 128)
	var max_value := 0.0
	for y in range(0, size.y, stride):
		for x in range(0, size.x, stride):
			var pixel := image.get_pixel(x, y)
			max_value = maxf(max_value, maxf(pixel.r, maxf(pixel.g, pixel.b)))
	return max_value > 0.01

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES AERIAL: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES AERIAL PASS")
		quit(0)
	else:
		print("SAISIES AERIAL FAIL (%d errors)" % _errors.size())
		quit(1)
