extends SceneTree

## Focused geometry contract for the isolated S02 low-shop prefab.
## Default mode is headless geometry/scale verification. Add --preview when a
## native viewport capture is wanted; headless runs report the skip and never
## claim a rendered image.

const SCENE_PATH := "res://scenes/props/SaisiesS02Shop.tscn"
const SOURCE_FRAME := "video/saisies_analysis/acceptance/S02_f000719.png"
const SOURCE_SHA256 := "3c692e306cd0ebcb6eb677f7b18678f8379e6c8bbdfdab782a2f32dd8fc3c958"

var _errors: Array[String] = []
var _preview_requested := false
var _preview_output := "/private/tmp/saisies_s02_shop_preview.png"
var _preview_view := "iso"

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--preview":
			_preview_requested = true
		elif argument.begins_with("--output="):
			_preview_output = argument.substr(9)
		elif argument.begins_with("--view="):
			_preview_view = argument.substr(7).to_lower()
	call_deferred("_run")

func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("could not load %s" % SCENE_PATH)
		_finish()
		return
	var world := Node3D.new()
	world.name = "SaisiesS02ShopVerification"
	get_root().add_child(world)
	var shop := packed.instantiate() as Node3D
	if shop == null:
		_fail("SaisiesS02Shop scene did not instantiate a Node3D")
		_finish()
		return
	world.add_child(shop)
	await process_frame
	await process_frame
	_verify_shop(shop)
	if not _errors.is_empty():
		_finish()
		return
	var building := shop.get_node("S02LowShopBuilding") as Node3D
	print("saisies s02 shop: local footprint=%s roof_length=%.2fm meshes=%d source=%s" % [shop.get_meta("saisies_s02_shop_footprint_m"), float(shop.get_meta("saisies_s02_shop_roof_length_m", 0.0)), _mesh_count(building), SOURCE_FRAME])
	if _preview_requested:
		await _run_preview(world, shop)
	print("SAISIES S02 SHOP VERIFY PASS")
	_finish()

func _verify_shop(shop: Node3D) -> void:
	if not bool(shop.get_meta("saisies_s02_shop_ready", false)):
		_fail("shop did not publish saisies_s02_shop_ready")
	if String(shop.get_meta("saisies_s02_shop_source_frame", "")) != SOURCE_FRAME:
		_fail("shop source frame metadata does not match S02 acceptance evidence")
	if String(shop.get_meta("saisies_s02_shop_source_sha256", "")) != SOURCE_SHA256:
		_fail("shop source SHA256 metadata does not match the retained evidence")
	if not bool(shop.get_meta("saisies_s02_shop_local_space", false)) or not bool(shop.get_meta("saisies_s02_shop_opaque_shell", false)):
		_fail("shop must publish local-space and opaque-shell contracts")
	if shop.get_node_or_null("S02LowShopBuilding") == null:
		_fail("S02LowShopBuilding is missing")
		return
	var building := shop.get_node("S02LowShopBuilding") as Node3D
	if building.scale != Vector3.ONE:
		_fail("shop prefab must keep unit local scale")
	var shell := _require_box(building, "OpaqueTimberShell")
	var base := _require_box(building, "LightBase")
	var plinth := _require_box(building, "StonePlinth")
	var door := _require_box(building, "FrontDoor")
	if shell != null and (absf(shell.size.x - 7.4) > 0.01 or absf(shell.size.y - 2.45) > 0.01 or absf(shell.size.z - 4.4) > 0.01):
		_fail("opaque shell dimensions changed from the visual estimate: %s" % shell.size)
	if base != null and (base.size.y < 0.45 or base.size.y > 0.75):
		_fail("light base height is outside the low-shop estimate: %.2f" % base.size.y)
	if plinth != null and plinth.size.y < 0.35:
		_fail("stone plinth is too thin to read as the light foundation")
	if door == null or door.size.y < 1.90 or door.size.y > 2.20:
		_fail("front door must remain a normal approximately 2m door")
	for index in range(2):
		var window := _require_box(building, "FrontWindow_%02d" % index)
		if window != null and (window.size.y < 1.0 or window.size.y > 1.30):
			_fail("front window %02d has an implausible height %.2f" % [index, window.size.y])
	for index in range(2):
		var side_window := _require_box(building, "SideWindow_%02d" % index)
		if side_window != null and side_window.size.y < 0.95:
			_fail("side window %02d is too short" % index)

	var roof_neg := _require_box(building, "RoofSlopeNegZ")
	var roof_pos := _require_box(building, "RoofSlopePosZ")
	var ridge := _require_box(building, "RoofRidgeCap")
	if roof_neg != null and roof_neg.size.x < 7.9:
		_fail("negative roof slope does not extend along the long local +X axis")
	if roof_pos != null and roof_pos.size.x < 7.9:
		_fail("positive roof slope does not extend along the long local +X axis")
	if ridge == null or ridge.size.x < 7.5:
		_fail("long roof ridge is missing or too short")
	_verify_roof_slope_geometry(building)
	if _require_box(building, "Chimney") == null or _require_box(building, "ChimneyCap") == null:
		_fail("roof chimney and cap details are missing")
	if _require_box(building, "RoofVent") == null or _require_box(building, "RoofVentCap") == null:
		_fail("small roof fitting details are missing")

	var gable := building.get_node_or_null("FrontGable") as MeshInstance3D
	if gable == null or not (gable.mesh is ArrayMesh):
		_fail("front gable must be an ArrayMesh with explicit winding")
	else:
		_verify_gable_winding(gable.mesh as ArrayMesh)
	if building.get_node_or_null("FrontSignPanel") == null or building.get_node_or_null("FrontSignBacking") == null:
		_fail("unlettered cream/dark sign silhouette is missing")
	else:
		var sign_face := building.get_node("FrontSignPanel") as MeshInstance3D
		if not (sign_face.material_override is StandardMaterial3D):
			_fail("front sign face must use a readable material")
		else:
			var sign_color := (sign_face.material_override as StandardMaterial3D).albedo_color
			if sign_color.r < 0.55 or sign_color.g < 0.50 or sign_color.b < 0.40:
				_fail("front sign face must remain visibly cream/white")
		for outline_name in ["FrontSignOutlineTop", "FrontSignOutlineBottom", "FrontSignOutlineLeft", "FrontSignOutlineRight"]:
			if building.get_node_or_null(outline_name) == null:
				_fail("front sign dark outline is incomplete: %s" % outline_name)
	if building.get_node_or_null("FrontSignLabel") != null:
		_fail("shop must not invent unknown source lettering")

	_verify_finite(shop)
	_verify_opaque_meshes(building)
	_verify_forbidden_names(shop)

func _require_box(parent: Node3D, node_name: String) -> BoxMesh:
	var instance := parent.get_node_or_null(node_name) as MeshInstance3D
	if instance == null:
		_fail("required shop mesh is missing: %s" % node_name)
		return null
	if not (instance.mesh is BoxMesh):
		_fail("shop mesh is not a BoxMesh: %s" % node_name)
		return null
	return instance.mesh as BoxMesh

func _verify_gable_winding(mesh: ArrayMesh) -> void:
	if mesh.get_surface_count() != 1:
		_fail("front gable must contain one triangle surface")
		return
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if vertices.size() < 18 or vertices.size() % 3 != 0:
		_fail("front gable triangle vertex count is invalid: %d" % vertices.size())
		return
	for index in range(0, vertices.size(), 3):
		var a := vertices[index]
		var b := vertices[index + 1]
		var c := vertices[index + 2]
		var normal := (b - a).cross(c - a)
		if normal.length_squared() < 0.000001:
			_fail("front gable contains a degenerate triangle at %d" % index)
	var front_normal := (vertices[1] - vertices[0]).cross(vertices[2] - vertices[0])
	if front_normal.x >= -0.001:
		_fail("front gable first face does not wind outward toward local -X")

func _verify_roof_slope_geometry(building: Node3D) -> void:
	var negative := building.get_node_or_null("RoofSlopeNegZ") as MeshInstance3D
	var positive := building.get_node_or_null("RoofSlopePosZ") as MeshInstance3D
	var ridge_cap := building.get_node_or_null("RoofRidgeCap") as MeshInstance3D
	if negative == null or positive == null or ridge_cap == null:
		_fail("roof slope geometry nodes are missing for transformed-height checks")
		return
	var negative_mesh := negative.mesh as BoxMesh
	var positive_mesh := positive.mesh as BoxMesh
	var cap_mesh := ridge_cap.mesh as BoxMesh
	if negative_mesh == null or positive_mesh == null or cap_mesh == null:
		_fail("roof slope geometry is not BoxMesh-backed")
		return
	var negative_ridge := _roof_top_edge_height(negative, negative_mesh, true)
	var negative_eave := _roof_top_edge_height(negative, negative_mesh, false)
	var positive_ridge := _roof_top_edge_height(positive, positive_mesh, true)
	var positive_eave := _roof_top_edge_height(positive, positive_mesh, false)
	if negative_ridge <= negative_eave + 0.35 or positive_ridge <= positive_eave + 0.35:
		_fail("roof slope top surface rises away from the ridge: neg %.3f/%.3f pos %.3f/%.3f" % [negative_ridge, negative_eave, positive_ridge, positive_eave])
	if absf(negative_ridge - positive_ridge) > 0.08:
		_fail("left/right roof ridge heights diverge: %.3f vs %.3f" % [negative_ridge, positive_ridge])
	var cap_center := ridge_cap.global_transform * Vector3(0.0, 0.0, 0.0)
	if absf(((negative_ridge + positive_ridge) * 0.5) - cap_center.y) > 0.18:
		_fail("roof ridge edges do not meet ridge cap within thickness tolerance: %.3f vs %.3f" % [((negative_ridge + positive_ridge) * 0.5), cap_center.y])
	print("saisies s02 shop roof slopes: neg ridge/eave=%.3f/%.3f pos ridge/eave=%.3f/%.3f cap_center=%.3f" % [negative_ridge, negative_eave, positive_ridge, positive_eave, cap_center.y])

func _roof_top_edge_height(instance: MeshInstance3D, mesh: BoxMesh, toward_ridge: bool) -> float:
	var half_x := mesh.size.x * 0.5
	var half_z := mesh.size.z * 0.5
	var edge_z := half_z if (instance.name == "RoofSlopeNegZ" and toward_ridge) or (instance.name == "RoofSlopePosZ" and not toward_ridge) else -half_z
	var top_y := mesh.size.y * 0.5
	var first := instance.global_transform * Vector3(-half_x, top_y, edge_z)
	var second := instance.global_transform * Vector3(half_x, top_y, edge_z)
	return (first.y + second.y) * 0.5

func _verify_opaque_meshes(parent: Node) -> void:
	for child in parent.get_children():
		if child is MeshInstance3D:
			var mesh_instance := child as MeshInstance3D
			if mesh_instance.material_override == null:
				_fail("shop mesh has no material: %s" % mesh_instance.name)
			elif mesh_instance.material_override is BaseMaterial3D and (mesh_instance.material_override as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
				_fail("shop mesh must remain opaque: %s" % mesh_instance.name)
		_verify_opaque_meshes(child)

func _verify_finite(parent: Node) -> void:
	if parent is Node3D:
		var node := parent as Node3D
		var origin := node.position
		var scale := node.scale
		if not _finite_vector(origin) or not _finite_vector(scale):
			_fail("non-finite local transform: %s" % node.get_path())
		if absf(scale.x) > 100.0 or absf(scale.y) > 100.0 or absf(scale.z) > 100.0:
			_fail("implausible local scale: %s" % node.get_path())
		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			if mesh_instance.mesh != null:
				var aabb := mesh_instance.get_aabb()
				if not _finite_vector(aabb.position) or not _finite_vector(aabb.size):
					_fail("non-finite mesh bounds: %s" % node.get_path())
	for child in parent.get_children():
		_verify_finite(child)

func _verify_forbidden_names(parent: Node) -> void:
	for child in parent.get_children():
		var lower_name := String(child.name).to_lower()
		for forbidden in ["person", "rider", "car", "vehicle", "bicycle", "bike", "hud"]:
			if lower_name.contains(forbidden):
				_fail("forbidden shop content node: %s" % child.get_path())
		_verify_forbidden_names(child)

func _finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _mesh_count(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if child is MeshInstance3D:
			count += 1
		count += _mesh_count(child)
	return count

func _run_preview(world: Node3D, shop: Node3D) -> void:
	if DisplayServer.get_name().to_lower().contains("headless"):
		print("saisies s02 shop preview: headless renderer; native capture skipped")
		return
	_add_preview_environment(world)
	var camera := Camera3D.new()
	camera.name = "S02ShopPreviewCamera"
	camera.current = true
	camera.fov = 48.0
	camera.near = 0.05
	camera.far = 100.0
	world.add_child(camera)
	if _preview_view == "front":
		camera.look_at_from_position(Vector3(-13.0, 5.2, -0.2), Vector3(0.0, 2.2, 0.0), Vector3.UP)
	else:
		camera.look_at_from_position(Vector3(-12.5, 7.0, -10.0), Vector3(0.0, 2.2, 0.0), Vector3.UP)
	var root_window := get_root() as Window
	if root_window != null:
		root_window.size = Vector2i(1280, 720)
		root_window.content_scale_size = Vector2i(1280, 720)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var viewport := get_root() as Viewport
	if viewport == null or viewport.get_texture() == null:
		_fail("preview viewport texture is unavailable")
		return
	var image := viewport.get_texture().get_image()
	var error := image.save_png(_preview_output)
	if error != OK:
		_fail("could not save preview to %s" % _preview_output)
	else:
		print("saisies s02 shop preview: saved %s" % _preview_output)

func _add_preview_environment(world: Node3D) -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.43, 0.65, 0.82)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.76, 0.82, 0.90)
	environment.ambient_light_energy = 0.78
	var world_environment := WorldEnvironment.new()
	world_environment.name = "S02ShopPreviewEnvironment"
	world_environment.environment = environment
	world.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.name = "S02ShopPreviewSun"
	sun.rotation_degrees = Vector3(-48.0, -32.0, 0.0)
	sun.light_color = Color(1.0, 0.93, 0.82)
	sun.light_energy = 1.40
	sun.shadow_enabled = true
	world.add_child(sun)
	var ground_mesh := BoxMesh.new()
	ground_mesh.size = Vector3(28.0, 0.16, 24.0)
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.27, 0.35, 0.25)
	ground_material.roughness = 0.94
	var ground := MeshInstance3D.new()
	ground.name = "S02ShopPreviewGround"
	ground.mesh = ground_mesh
	ground.material_override = ground_material
	ground.position = Vector3(0.0, -0.08, 0.0)
	world.add_child(ground)

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES S02 SHOP VERIFY: %s" % message)

func _finish() -> void:
	if not _errors.is_empty():
		print("SAISIES S02 SHOP VERIFY FAIL count=%d" % _errors.size())
		quit(1)
	else:
		quit(0)
