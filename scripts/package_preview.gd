extends Node3D
## Shared AI Scene Package consumer. All placement comes from package data; no route edits.
const RouteReader = preload("res://scripts/route_data.gd")
const PackageInstanceTransform = preload("res://scripts/package_instance_transform.gd")
const PackageRoadMask = preload("res://scripts/package_road_mask.gd")
const PreviewGroundDetail = preload("res://scripts/package_preview_ground_detail.gd")
# Adapter lighting calibration (clear midday). The package's P6 values stay relative.
const PREVIEW_SUN_SCALE := 1.5
const PREVIEW_AMBIENT_SCALE := 1.5
const PREVIEW_EXPOSURE := .85
const PREVIEW_SATURATION := 1.0
# Shared PBR detail per package material name (CC0 Poly Haven sets in assets/textures).
# Only the texture's luminance is used, normalised to its mean, on the adapter's tuned base colour:
# it adds detail, never a new hue (per-channel ratios turn grey rocks cyan on a yellow grass set).
# Missing textures (assets/ is not in git) fall back to the flat shader.
# Real-asset substitutes per prototype id (CC0, assets/models). Each variant is rescaled to the package
# prototype mesh's height and instances alternate between variants; missing files keep the package mesh.
const PROTOTYPE_LIBRARY := {
	"tropical_palm": ["res://assets/models/nobiax_palms/palm_straight.glb", "res://assets/models/nobiax_palms/palm_bend.glb"],
	"norfolk_pine": ["res://assets/models/norfolk_pine/norfolk_pine.glb"],  # tools/build_norfolk_pine.py
}
const SURFACE_LIBRARY := {
	"terrain_ground": {"set": "aerial_grass_rock", "repeat_m": 5.0, "macro": .22, "normal": .8, "rough_min": .85},
	"shore_sand": {"set": "coast_sand_01", "repeat_m": 3.0, "macro": .12, "normal": .6},
	"road_sand": {"set": "coast_sand_01", "repeat_m": 3.0, "macro": .10, "normal": .6},
	"road_asphalt": {"set": "asphalt_02", "repeat_m": 4.0, "macro": .08, "normal": .7},
	"parking_asphalt": {"set": "asphalt_02", "repeat_m": 4.0, "macro": .08, "normal": .7},
	"context_asphalt": {"set": "asphalt_02", "repeat_m": 4.0, "macro": .08, "normal": .7},
	# Detail sets for the building shaders below (FACADE_SHADER / ROOF_TILE_SHADER), not the triplanar one.
	"facade_osm": {"set": "painted_plaster_wall", "repeat_m": 2.5, "macro": 0.0, "normal": 0.0},
	"roof_tile_osm": {"set": "clay_roof_tiles", "repeat_m": 2.0, "macro": 0.0, "normal": 0.0},
	"road_concrete": {"set": "brushed_concrete", "repeat_m": 3.0, "macro": .08, "normal": .5},
	"road_gravel": {"set": "gravel_floor_02", "repeat_m": 2.0, "macro": .10, "normal": .7},
	"road_dirt": {"set": "rocky_trail", "repeat_m": 2.5, "macro": .12, "normal": .8},
}

var route: RefCounted
var manifest: Dictionary
var package_dir := ""
var progress := 0.0
var speed := 6.0
var automatic := true
var camera := Camera3D.new()
var tiles := Node3D.new()
var label := Label.new()
var loaded := {}
var adjacent_geometry := {}
var logical_road_nodes: Dictionary = {}
var adjacent_road_nodes: Dictionary = {}
var adjacent_original_roads: Dictionary = {}
var _last_road_mask_signature := ""
var spatial_geometry_radius_m := 0.0
var capture_dir := ""
var views_file := ""
var surface_visual_overrides_file := ""
var surface_visual_overrides: Array = []
var checking := false
var batch := false
var geometry_only := false
var prototypes := {}
var prototype_meshes := {}
var prototype_variants := {}  # id -> [{mesh, fit: Transform3D}]
var objects := {}
var environment_resource: Environment
var water_material: ShaderMaterial
var material_cache := {}
var sand_pbr_texture_cache: Dictionary = {}

func _read(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))

func _load_surface_visual_overrides() -> void:
	var source_path := surface_visual_overrides_file
	if source_path.is_empty():
		# Renderer-specific appearance stays beside the engine-neutral package.
		# This optional adapter sidecar is auto-loaded so captures do not depend on
		# one-off material flags or pollute manifest.json with Godot-only settings.
		var adapter_sidecar := package_dir + ".godot_preview.json"
		if FileAccess.file_exists(adapter_sidecar): source_path = adapter_sidecar
	if source_path.is_empty() or not FileAccess.file_exists(source_path): return
	surface_visual_overrides_file = source_path
	var config: Variant = _read(source_path)
	if not config is Dictionary: return
	var overrides_value: Variant = config.get("overrides", [])
	if not overrides_value is Array: return
	surface_visual_overrides = overrides_value
	for override in surface_visual_overrides:
		if not override is Dictionary: continue
		var textures: Dictionary = override.get("textures", {})
		for key in textures.keys():
			var texture_path := String(textures[key])
			if texture_path.is_empty() or texture_path.begins_with("/") or texture_path.begins_with("res://"):
				continue
			textures[key] = package_dir.path_join(texture_path)
		override["textures"] = textures

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--package="): package_dir = arg.trim_prefix("--package=")
		elif arg.begins_with("--start-s="): progress = float(arg.trim_prefix("--start-s="))
		elif arg.begins_with("--capture-dir="): capture_dir = arg.trim_prefix("--capture-dir=")
		elif arg.begins_with("--views="): views_file = arg.trim_prefix("--views=")
		elif arg.begins_with("--surface-visual-overrides="): surface_visual_overrides_file = arg.trim_prefix("--surface-visual-overrides=")
		elif arg.begins_with("--spatial-geometry-radius-m="):
			var radius := float(arg.trim_prefix("--spatial-geometry-radius-m="))
			spatial_geometry_radius_m = maxf(0.0, radius) if is_finite(radius) else 0.0
		elif arg == "--check": checking = true
		elif arg == "--geometry-only": geometry_only = true
	if package_dir.is_empty() or not FileAccess.file_exists(package_dir.path_join("manifest.json")):
		push_error("Pass --package=<directory containing manifest.json>")
		get_tree().quit(2)
		return
	DisplayServer.window_set_title("AI Scene Package — " + package_dir.get_file())
	manifest = _read(package_dir.path_join("manifest.json"))
	route = RouteReader.load_file(package_dir.path_join("route/route.json"))
	_load_surface_visual_overrides()
	add_child(tiles)
	add_child(camera)
	camera.fov = 75.0
	camera.far = 5000.0
	camera.current = true
	_load_prototypes()
	_setup_environment()
	var canvas := CanvasLayer.new()
	add_child(canvas)
	canvas.add_child(label)
	label.position = Vector2(20, 18)
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	_jump(progress)
	if checking:
		assert(route.length > 0.0 and loaded.size() > 0)
		assert(camera.position.distance_to(route.position_at(progress)) < 3.0)
		print("PACKAGE_PREVIEW_CHECK_OK ", route.length, " m; loaded tiles ", loaded.size())
		get_tree().quit()
	elif not capture_dir.is_empty():
		batch = true
		call_deferred("_capture_views")

func _load_glb(path: String) -> Node3D:
	var instance := _load_glb_document(path)
	if instance == null:
		push_error("GLB import failed: %s" % path)
		get_tree().quit(3)
		return Node3D.new()
	return instance

static func _load_glb_document(path: String) -> Node3D:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(path, state, _gltf_import_flags_for_path(path))
	if error != OK:
		return null
	return document.generate_scene(state)

static func _gltf_import_flags_for_path(path: String) -> int:
	# Road/terrain world coordinates are gameplay-adjacent geometry; mesh compression
	# can move vertices by millimetres at Gold Coast world offsets. Keep props default.
	var basename := path.get_file().to_lower()
	if basename == "road.glb" or basename == "terrain.glb":
		return GLTFDocument.IMPORT_FLAG_FORCE_DISABLE_MESH_COMPRESSION
	return 0

func _stream() -> void:
	for tile in manifest.tiles:
		var id: String = tile.id
		var near: bool = float(tile.to_s) >= progress - 350.0 and float(tile.from_s) <= progress + 800.0
		if near and not loaded.has(id):
			var holder := Node3D.new()
			tiles.add_child(holder)
			_load_tile_geometry(holder, tile)
			for layer in ["vegetation", "structures"]:
				if not geometry_only and tile.files.has(layer): _scatter(holder, _read(package_dir.path_join(tile.files[layer])))
			loaded[id] = holder
		elif not near and loaded.has(id):
			loaded[id].free()
			loaded.erase(id)
			logical_road_nodes.erase(id)
	_stream_adjacent_geometry()

func _exit_tree() -> void:
	for node in adjacent_original_roads.values():
		if is_instance_valid(node): node.free()
	adjacent_original_roads.clear()

func _load_tile_geometry(holder: Node3D, tile: Dictionary) -> void:
	var layer_nodes := {}
	for layer in ["terrain", "road", "roadside", "buildings"]:
		if (layer == "roadside" or layer == "buildings") and not tile.files.has(layer): continue
		var node := _load_glb(package_dir.path_join(tile.files[layer]))
		node.name = String(tile.id) + "_" + layer
		_style_meshes(node, String(tile.id), layer, float(tile.from_s), float(tile.to_s))
		holder.add_child(node)
		layer_nodes[layer] = node
		if layer == "road": logical_road_nodes[String(tile.id)] = node
	if not geometry_only:
		var tufts := PreviewGroundDetail.add_terrain_grass(holder, layer_nodes.terrain, route, float(tile.from_s), float(tile.to_s), String(tile.id).hash(), layer_nodes.get("roadside"))
		print("PREVIEW_GRASS ", String(tile.id), " ", tufts)
	for candidate in surface_visual_overrides:
		if candidate.get("appearance", "") != "procedural_short_grass": continue
		if not candidate.get("tile_ids", []).has(String(tile.id)): continue
		if float(candidate.get("to_s", 0.0)) <= float(tile.from_s) or float(candidate.get("from_s", 0.0)) >= float(tile.to_s): continue
		var metrics := PreviewGroundDetail.add_procedural_short_grass(holder, package_dir, manifest.tiles, route, String(tile.id), candidate)
		print("PREVIEW_SHORT_GRASS ", String(tile.id), " ", JSON.stringify(metrics))

func _road_mask_signature(ids: Dictionary) -> String:
	var keys: Array = ids.keys()
	keys.sort()
	return ",".join(PackedStringArray(keys))

func _rebuild_adjacent_roads() -> void:
	if adjacent_geometry.is_empty():
		adjacent_road_nodes.clear()
		return
	var active_triangles: Array = []
	for node in logical_road_nodes.values(): active_triangles.append_array(PackageRoadMask.collect_world_triangles(node))
	var active_index: Dictionary = PackageRoadMask.build_spatial_index(active_triangles)
	for id_value in adjacent_geometry.keys():
		var id: String = id_value
		var holder: Node3D = adjacent_geometry[id]
		if adjacent_road_nodes.has(id) and is_instance_valid(adjacent_road_nodes[id]):
			adjacent_road_nodes[id].free()
			adjacent_road_nodes.erase(id)
		if not adjacent_original_roads.has(id): continue
		var road: Node3D = adjacent_original_roads[id].duplicate()
		road.name = id + "_road"
		holder.add_child(road)
		var stack: Array[Node] = [road]
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			if node is MeshInstance3D:
				var source_mesh: Mesh = node.mesh
				if source_mesh is ArrayMesh:
					# Active traversal gets display ownership only within the measured return-pass
					# profile disagreement bound (0.3213 m); physical route data is unchanged.
					var clipped := PackageRoadMask.clip_mesh_instance(node, active_index, 0.35)
					if clipped == null:
						push_error("Adjacent road mesh could not be safely masked: %s" % id)
						get_tree().quit(4)
						return
					node.mesh = clipped
			for child in node.get_children(): stack.append(child)
		_style_meshes(road, id, "road")
		adjacent_road_nodes[id] = road

func _stream_adjacent_geometry() -> void:
	# Only adjacent road meshes are spatially loaded. Terrain and traverse-authored scenery
	# stay in the logical route window, preserving P1 and avoiding duplicate P3/P4 content.
	var here: Vector3 = route.position_at(progress)
	var membership_changed := false
	for tile in manifest.tiles:
		var id: String = tile.id
		var near := false
		if spatial_geometry_radius_m > 0.0 and not loaded.has(id):
			var lo: Array = tile.bounds.min
			var hi: Array = tile.bounds.max
			var dx := maxf(maxf(float(lo[0]) - here.x, here.x - float(hi[0])), 0.0)
			var dz := maxf(maxf(float(lo[2]) - here.z, here.z - float(hi[2])), 0.0)
			near = dx * dx + dz * dz <= spatial_geometry_radius_m * spatial_geometry_radius_m
		if near and not adjacent_geometry.has(id):
			var holder := Node3D.new()
			tiles.add_child(holder)
			adjacent_original_roads[id] = _load_glb(package_dir.path_join(tile.files.road))
			adjacent_geometry[id] = holder
			membership_changed = true
		elif not near and adjacent_geometry.has(id):
			adjacent_geometry[id].free()
			adjacent_geometry.erase(id)
			adjacent_road_nodes.erase(id)
			if adjacent_original_roads.has(id):
				adjacent_original_roads[id].free()
				adjacent_original_roads.erase(id)
			membership_changed = true
	var signature := _road_mask_signature(logical_road_nodes) + "|" + _road_mask_signature(adjacent_geometry)
	if membership_changed or signature != _last_road_mask_signature:
		_rebuild_adjacent_roads()
		_last_road_mask_signature = signature

func _pose() -> void:
	# Reset capture-only projection before rebuilding the unchanged automatic pose.
	camera.fov = 75.0
	camera.position = route.position_at(progress) + Vector3.UP * 1.65
	var bend := 0.0
	for ds in [0.0, 2.0, 4.0, 6.0, 8.0]:
		bend = maxf(bend,absf(float(route.sample(minf(progress+ds,route.length)).curvature)))
	# Avoid aiming the camera along a long chord through the terrain inside a tight bend.
	var lookahead := clampf(0.25 / maxf(bend,0.001),0.75,8.0)
	var ahead: float = minf(progress + lookahead, route.length)
	var target: Vector3 = route.position_at(ahead) + Vector3.UP * 1.65
	if ahead - progress < 0.1:
		target = camera.position + (route.position_at(progress) - route.position_at(maxf(0.0, progress - 3.0)))
	if camera.position.distance_to(target) > 0.01:
		camera.look_at(target, Vector3.UP)

func _apply_capture_camera_override(view: Dictionary) -> void:
	# Review-only calibration inputs; route data and automatic traversal stay untouched.
	var override: Dictionary = view.get("camera_override", {})
	if override.is_empty(): return
	var tangent: Vector3 = route.position_at(minf(progress + 1.0, route.length)) - route.position_at(maxf(0.0, progress - 1.0))
	tangent.y = 0.0
	if tangent.length_squared() > 0.000001:
		tangent = tangent.normalized()
		var right := _route_right(tangent)
		var offset: Array = override.get("position_offset_route_m", [0.0, 0.0, 0.0])
		if offset.size() == 3:
			camera.position += right * float(offset[0]) + Vector3.UP * float(offset[1]) + tangent * float(offset[2])
	if override.has("yaw_offset_deg"):
		camera.rotate_object_local(Vector3.UP, deg_to_rad(float(override.yaw_offset_deg)))
	if override.has("pitch_down_deg"):
		camera.rotate_object_local(Vector3.RIGHT, -deg_to_rad(float(override.pitch_down_deg)))
	if override.has("roll_offset_deg"):
		camera.rotate_object_local(Vector3.BACK, deg_to_rad(float(override.roll_offset_deg)))
	if override.has("vertical_fov_deg"):
		camera.fov = clampf(float(override.vertical_fov_deg), 30.0, 120.0)

func _route_right(forward_tangent: Vector3) -> Vector3:
	# Godot route coordinates: for forward -Z, positive right is +X.
	return forward_tangent.cross(Vector3.UP).normalized()

func _jump(s: float) -> void:
	progress = clampf(s, 0.0, route.length)
	_stream()
	_pose()

func _process(delta: float) -> void:
	if route == null or batch: return
	if automatic:
		progress = minf(route.length, progress + speed * delta)
		_stream()
		_pose()
	else:
		var direction := Vector3.ZERO
		if Input.is_physical_key_pressed(KEY_W): direction.z -= 1
		if Input.is_physical_key_pressed(KEY_S): direction.z += 1
		if Input.is_physical_key_pressed(KEY_A): direction.x -= 1
		if Input.is_physical_key_pressed(KEY_D): direction.x += 1
		if Input.is_physical_key_pressed(KEY_E): direction.y += 1
		if Input.is_physical_key_pressed(KEY_Q): direction.y -= 1
		var rate := 45.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 12.0
		camera.position += camera.basis * direction.normalized() * rate * delta
	var sample: Dictionary = route.sample(progress)
	label.text = "%s — reconstructed world candidate\n%.0f / %.0f m   elevation %.2f m   grade %.2f%%\nTab: auto/free   WASD + Q/E: fly   mouse: look   PgUp/PgDn: ±250 m   Home: start   Esc: release" % [
		manifest.package_id, progress, route.length, sample.elevation_m, sample.grade_percent]

func _unhandled_input(event: InputEvent) -> void:
	if route == null or batch: return
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_TAB:
			automatic = not automatic
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if automatic else Input.MOUSE_MODE_CAPTURED
		elif event.keycode == KEY_ESCAPE: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif event.keycode == KEY_PAGEUP: _jump(progress + 250.0)
		elif event.keycode == KEY_PAGEDOWN: _jump(progress - 250.0)
		elif event.keycode == KEY_HOME: _jump(0.0)
	elif event is InputEventMouseMotion and not automatic and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera.rotation.y -= event.relative.x * 0.002
		camera.rotation.x = clampf(camera.rotation.x - event.relative.y * 0.002, -1.4, 1.4)

func _capture_views() -> void:
	get_viewport().size = Vector2i(1920, 1080)
	DirAccess.make_dir_recursive_absolute(capture_dir)
	var views: Array = _read(views_file) if not views_file.is_empty() else []
	if views.is_empty():
		for section in route.data.sections:
			views.append({"id": section.id, "s": (float(section.from_s) + float(section.to_s)) / 2.0})
	var records := []
	label.visible = false
	for view in views:
		_jump(float(view.s))
		_apply_capture_camera_override(view)
		for frame in range(5): await get_tree().process_frame
		RenderingServer.force_draw()
		var file := capture_dir.path_join(String(view.id) + ".png")
		var image := get_viewport().get_texture().get_image()
		assert(not image.is_empty() and image.get_width() == 1920 and image.get_height() == 1080)
		assert(image.save_png(file) == OK)
		var camera_y_offset: float = camera.position.y - route.position_at(progress).y
		records.append({"id": view.id, "s": view.s, "image": file, "baseline_camera_height_m": 1.65, "camera_height_m": camera_y_offset, "camera_y_offset_m": camera_y_offset - 1.65, "vertical_fov": camera.fov, "camera_override": view.get("camera_override", {})})
	var output := FileAccess.open(capture_dir.path_join("captures.json"), FileAccess.WRITE)
	output.store_string(JSON.stringify({"package": package_dir, "scope": "P0–P6 reconstructed world; estimated layout, visual acceptance pending", "surface_visual_overrides": surface_visual_overrides_file, "spatial_geometry_radius_m": spatial_geometry_radius_m, "views": records}, "\t"))
	print("PACKAGE_PREVIEW_CAPTURE_OK ", records.size())
	get_tree().quit()

func _first_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D: return node.mesh
	for child in node.get_children():
		var mesh := _first_mesh(child)
		if mesh != null: return mesh
	return null

func _load_prototypes() -> void:
	for layer in ["vegetation", "structures"]:
		var path := package_dir.path_join(layer + "/prototypes.json")
		if not FileAccess.file_exists(path): continue
		for proto in _read(path).prototypes:
			prototypes[proto.id] = proto
			if proto.has("mesh_file"):
				var node := _load_glb(package_dir.path_join(proto.mesh_file))
				prototype_meshes[proto.id] = _first_mesh(node)
				node.free()
				var variants := _library_variants(String(proto.id), prototype_meshes[proto.id])
				if not variants.is_empty(): prototype_variants[proto.id] = variants
	var path := package_dir.path_join("structures/structures.json")
	if FileAccess.file_exists(path):
		for object in _read(path).objects: objects[object.object_id] = object

func _library_variants(proto_id: String, package_mesh: Mesh) -> Array:
	# Uniform scale so each substitute is as tall as the package mesh; both are modelled base-at-origin.
	var variants := []
	if package_mesh == null: return variants
	for path in PROTOTYPE_LIBRARY.get(proto_id, []):
		if not FileAccess.file_exists(path): return []
		var node := _load_glb_document(path)
		if node == null: return []
		var mesh := _first_mesh(node)
		node.free()
		var height := mesh.get_aabb().size.y if mesh != null else 0.0
		if height <= 0.001: return []
		var fit := Transform3D(Basis.from_scale(Vector3.ONE * package_mesh.get_aabb().size.y / height), Vector3.ZERO)
		variants.append({"mesh": mesh, "fit": fit})
	return variants

func _scatter(holder: Node3D, data: Dictionary) -> void:
	for group in data.groups:
		if not prototype_meshes.has(group.proto): continue
		var variants: Array = prototype_variants.get(group.proto, [{"mesh": prototype_meshes[group.proto], "fit": Transform3D.IDENTITY}])
		for v in range(variants.size()):
			var indices := range(v, int(group.count), variants.size())
			if indices.is_empty(): continue
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.mesh = variants[v].mesh
			multimesh.instance_count = indices.size()
			for k in range(indices.size()):
				var i: int = indices[k]
				var a: Array = group.data.slice(i * 10, i * 10 + 10)
				var q := Quaternion(a[3], a[4], a[5], a[6])
				multimesh.set_instance_transform(k, PackageInstanceTransform.from_package(
					Vector3(a[0], a[1], a[2]), q, Vector3(a[7], a[8], a[9])) * variants[v].fit)
			var instance := MultiMeshInstance3D.new()
			instance.multimesh = multimesh
			instance.visibility_range_end = 1000.0
			holder.add_child(instance)
	for line in data.get("linear", []): _barrier(holder, line)

func _beam(holder: Node3D, a: Vector3, b: Vector3, thickness: float, material: Material, mesh_name: String = "") -> void:
	if a.distance_to(b) < 0.001: return
	var mesh := BoxMesh.new()
	mesh.size = Vector3(thickness, thickness, a.distance_to(b))
	var instance := MeshInstance3D.new()
	if not mesh_name.is_empty(): instance.name = "%s_%d" % [mesh_name, holder.get_child_count()]
	instance.mesh = mesh
	instance.material_override = material
	holder.add_child(instance)
	instance.position = (a + b) / 2
	instance.look_at(b, Vector3.UP if absf((b-a).normalized().y) < 0.95 else Vector3.RIGHT)

func _lattice_fence(holder: Node3D, pts: Array, dimensions: Dictionary) -> void:
	var height := float(dimensions.get("height", 1.0))
	var thickness := float(dimensions.get("thickness", 0.05))
	var spacing := maxf(float(dimensions.get("post_spacing", 2.0)), 0.5)
	var post_radius := clampf(thickness * 1.5, 0.045, 0.09)
	var timber := StandardMaterial3D.new()
	timber.albedo_color = Color(0.31, 0.22, 0.14)
	timber.roughness = 0.9
	var net := StandardMaterial3D.new()
	var mesh_image := Image.create(160, 48, false, Image.FORMAT_RGBA8)
	for y in range(48):
		for x in range(160):
			var wire := x % 8 < 2 or y % 6 < 1
			mesh_image.set_pixel(x, y, Color(0.025, 0.14, 0.075, 0.96) if wire else Color(0.07, 0.30, 0.19, 0.64))
	net.albedo_texture = ImageTexture.create_from_image(mesh_image)
	net.albedo_color = Color.WHITE
	net.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	net.roughness = 0.95
	net.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var points: Array[Vector3] = []
	for point in pts: points.append(Vector3(point[0], point[1], point[2]))
	if points.size() < 2: return
	var add_post := func(position: Vector3) -> void:
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = post_radius
		cylinder.bottom_radius = post_radius
		cylinder.height = height
		var post := MeshInstance3D.new()
		post.name = "FenceTimberPost_%d" % holder.get_child_count()
		post.mesh = cylinder
		post.material_override = timber
		holder.add_child(post)
		post.position = position + Vector3.UP * (height * 0.5)
	var first := points[0]
	add_post.call(first)
	var travelled := 0.0
	var next_post := spacing
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var span := a.distance_to(b)
		if span < 0.001: continue
		var horizontal := Vector3(b.x - a.x, 0.0, b.z - a.z).normalized()
		var side := horizontal.cross(Vector3.UP).normalized()
		var center := (a + b) * 0.5 + Vector3.UP * ((height + 0.08) * 0.5)
		var panel_mesh := BoxMesh.new()
		panel_mesh.size = Vector3(Vector2(b.x - a.x, b.z - a.z).length() + 0.02, maxf(height - 0.16, 0.1), 0.025)
		var panel := MeshInstance3D.new()
		panel.name = "FenceMeshPanel_%d" % holder.get_child_count()
		panel.mesh = panel_mesh
		panel.material_override = net
		holder.add_child(panel)
		panel.transform = Transform3D(Basis(horizontal, Vector3.UP, side), center)
		_beam(holder, a + Vector3.UP * (height - 0.04), b + Vector3.UP * (height - 0.04), maxf(thickness, 0.08), timber, "FenceTimberTopRail")
		while next_post <= travelled + span:
			add_post.call(a.lerp(b, (next_post - travelled) / span))
			next_post += spacing
		travelled += span
	var last := points[points.size() - 1]
	if travelled - (next_post - spacing) > 0.25: add_post.call(last)

func _timber_rail_fence(holder: Node3D, pts: Array, dimensions: Dictionary) -> void:
	var height := float(dimensions.get("height", 1.05))
	var thickness := float(dimensions.get("thickness", 0.09))
	var spacing := maxf(float(dimensions.get("post_spacing", 2.2)), 0.5)
	var timber := StandardMaterial3D.new()
	timber.albedo_color = Color(0.24, 0.17, 0.11)
	timber.roughness = 0.9
	var add_post := func(p: Vector3) -> void:
		_beam(holder, p, p + Vector3.UP * height, thickness, timber, "FenceDarkTimberPost")
	var travelled := 0.0
	var next_post := 0.0
	add_post.call(Vector3(pts[0][0], pts[0][1], pts[0][2]))
	next_post += spacing
	for i in range(pts.size() - 1):
		var a := Vector3(pts[i][0], pts[i][1], pts[i][2])
		var b := Vector3(pts[i + 1][0], pts[i + 1][1], pts[i + 1][2])
		var span := a.distance_to(b)
		if span < 0.001: continue
		_beam(holder, a + Vector3.UP * (height - thickness), b + Vector3.UP * (height - thickness), thickness, timber, "FenceDarkTimberTopRail")
		_beam(holder, a + Vector3.UP * (height * 0.34), b + Vector3.UP * (height * 0.34), thickness, timber, "FenceDarkTimberLowerRail")
		while next_post <= travelled + span:
			add_post.call(a.lerp(b, (next_post - travelled) / span))
			next_post += spacing
		travelled += span
	var last := Vector3(pts[-1][0], pts[-1][1], pts[-1][2])
	if travelled - (next_post - spacing) > 0.25: add_post.call(last)

func _barrier(holder: Node3D, line: Dictionary) -> void:
	var obj: Dictionary = objects.get(line.object_id, {})
	if obj.is_empty(): return
	var wall: bool = obj.semantic_type == "retaining_wall"
	var prototype := String(obj.get("prototype", ""))
	if not wall and prototype == "fence_lattice":
		_lattice_fence(holder, line.points, obj.get("dimensions_m", {}))
		return
	if not wall and prototype == "fence_timber_rail":
		_timber_rail_fence(holder, line.points, obj.get("dimensions_m", {}))
		return
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.45,0.44,0.39) if wall else Color(0.91,0.92,0.89)
	material.roughness = 0.85 if wall else 0.4
	var pts: Array = line.points
	for i in range(pts.size()-1):
		var a := Vector3(pts[i][0],pts[i][1],pts[i][2])
		var b := Vector3(pts[i+1][0],pts[i+1][1],pts[i+1][2])
		if wall:
			var mesh := BoxMesh.new()
			mesh.size = Vector3(0.32,0.65,a.distance_to(b))
			var instance := MeshInstance3D.new()
			instance.mesh = mesh
			instance.material_override = material
			holder.add_child(instance)
			instance.position = (a+b)/2 + Vector3.UP*.28
			instance.look_at(b+Vector3.UP*.28,Vector3.UP)
		else:
			for height in [.25,.6,1.05]: _beam(holder,a+Vector3.UP*height,b+Vector3.UP*height,.065,material)
			for t in [0.0,.5]:
				var p := a.lerp(b,t)
				_beam(holder,p,p+Vector3.UP*1.15,.07,material)

func _color_linear(values: Array) -> Color:
	return Color(values[0],values[1],values[2]).linear_to_srgb()

func _setup_environment() -> void:
	var env := Environment.new()
	environment_resource = env
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(.14,.39,.68)
	sky_material.sky_horizon_color = Color(.71,.82,.88)
	sky_material.ground_bottom_color = Color(.27,.35,.29)
	sky_material.ground_horizon_color = Color(.65,.75,.78)
	sky.sky_material = sky_material
	var path := package_dir.path_join("environment/environment.json")
	var facts: Dictionary = _read(path) if FileAccess.file_exists(path) else {}
	var atmosphere: Dictionary = facts.get("atmosphere", {})
	var sky_facts: Dictionary = atmosphere.get("sky", {}) if atmosphere.get("sky") != null else {}
	if sky_facts.has("file"):
		var image := Image.load_from_file(package_dir.path_join(sky_facts.file))
		if image != null and not image.is_empty():
			var panorama := PanoramaSkyMaterial.new()
			panorama.panorama = ImageTexture.create_from_image(image)
			sky.sky_material = panorama
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# Package intensities are relative; these adapter scales map them to a clear-day exposure.
	env.ambient_light_energy = PREVIEW_AMBIENT_SCALE * float(atmosphere.get("ambient", {}).get("intensity_relative", .35))
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = PREVIEW_EXPOSURE
	env.adjustment_enabled = true
	env.adjustment_saturation = PREVIEW_SATURATION
	env.ssao_enabled = true
	env.ssao_radius = 1.5
	env.ssao_intensity = 1.6
	env.fog_enabled = true
	env.fog_density = float(atmosphere.get("fog", {}).get("density_per_m", .00009)) * .5
	env.fog_light_color = Color(.71,.81,.86)
	env.fog_sky_affect = .02
	var world_environment := WorldEnvironment.new()
	world_environment.environment = env
	add_child(world_environment)
	var sun := DirectionalLight3D.new()
	add_child(sun)
	var sun_facts: Dictionary = atmosphere.get("sun", {})
	var direction: Array = sun_facts.get("direction_to_sun", [-.4,.7,-.4])
	sun.look_at(-Vector3(direction[0],direction[1],direction[2]),Vector3.UP)
	sun.light_energy = PREVIEW_SUN_SCALE * float(sun_facts.get("intensity_relative", 1.3))
	if sun_facts.has("color_linear"):
		var c: Array = sun_facts.color_linear
		sun.light_color = Color(c[0], c[1], c[2]).linear_to_srgb()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 200.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	# P5 skyline towers: one static mesh for the whole route (never streamed).
	var skyline_path := package_dir.path_join("environment/skyline_buildings.glb")
	if FileAccess.file_exists(skyline_path):
		var skyline := _load_glb(skyline_path)
		_style_meshes(skyline)
		add_child(skyline)
	# World water is data; land and the explicit coastal terrain conceal it inland.
	for body in facts.get("distant", {}).get("water", []):
		var mesh := PlaneMesh.new()
		mesh.size = Vector2(body.geometry.size_m[0],body.geometry.size_m[1])
		var plane := MeshInstance3D.new()
		plane.mesh = mesh
		plane.position.y = body.level_offset_m
		var shader := Shader.new()
		shader.code = """shader_type spatial;
varying vec3 world;
void vertex(){world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;}
void fragment(){
float a=sin(world.x*1.8+world.z*.9+TIME*.6)*.08;
float b=cos(world.z*2.7-world.x*.45+TIME*.8)*.08;
NORMAL=normalize(NORMAL+vec3(a,0.,b));
float v=sin(world.x*.13+world.z*.09)*.015;
ALBEDO=vec3(.012+v*.2,.075+v*.2,.12+v*.2);ROUGHNESS=.34;METALLIC=.05;
}"""
		var material := ShaderMaterial.new()
		material.shader = shader
		plane.material_override = material
		add_child(plane)

func _style_meshes(node: Node, tile_id := "", layer := "", tile_from_s := 0.0, tile_to_s := 0.0) -> void:
	if node is MeshInstance3D:
		for i in range(node.mesh.get_surface_count()):
			var original: Material = node.mesh.surface_get_material(i)
			if original == null: continue
			var key := original.resource_name
			if key == "facade_osm" or key == "roof_tile_osm":
				if not material_cache.has(key):
					var building_shader := Shader.new()
					building_shader.code = FACADE_SHADER if key == "facade_osm" else ROOF_TILE_SHADER
					var building_material := ShaderMaterial.new()
					building_material.shader = building_shader
					var maps := _surface_library_textures(key)
					if maps.size() == 3:
						building_material.set_shader_parameter("detail", maps[0])
						building_material.set_shader_parameter("detail_mean", maxf(maps[0].get_meta("mean_linear").get_luminance(), .01))
						building_material.set_shader_parameter("detail_per_m", 1.0 / float(SURFACE_LIBRARY[key].repeat_m))
					material_cache[key] = building_material
				node.set_surface_override_material(i, material_cache[key])
				continue
			# Preserve package-authored PBR for surfaces this preview does not adapt. In
			# particular, local support skirts carry their intended grass material in GLB.
			if key != "terrain_ground" and key != "shore_sand" and not key.begins_with("road_") and not SURFACE_LIBRARY.has(key):
				continue
			var surface_override: Dictionary = {}
			var lawn_overrides: Array = []
			for candidate in surface_visual_overrides:
				if key == "terrain_ground" and layer == "terrain" and candidate.get("appearance", "") == "procedural_mown_lawn":
					if not candidate.get("tile_ids", []).has(tile_id): continue
					if float(candidate.to_s) <= tile_from_s or float(candidate.from_s) >= tile_to_s: continue
					lawn_overrides.append(candidate)
				elif key.begins_with("road_"):
					var probe_s := 0.5 * (float(candidate.from_s) + float(candidate.to_s))
					surface_override = _road_surface_visual_override(key, probe_s, [candidate])
				if not surface_override.is_empty(): break
			if not lawn_overrides.is_empty(): surface_override = lawn_overrides[0]
			var cache_key := key
			if not lawn_overrides.is_empty():
				var override_keys: Array[String] = []
				for candidate in lawn_overrides: override_keys.append(JSON.stringify(candidate))
				cache_key += "|%s|%s" % [tile_id, ",".join(override_keys)]
			if not material_cache.has(cache_key):
				var shader := Shader.new()
				var grass := key == "terrain_ground"
				var sand := key == "shore_sand"
				var use_sand_pbr: bool = not surface_override.is_empty() and surface_override.get("appearance", "") == "polyhaven_coast_sand_pbr"
				var use_mown_lawn: bool = not surface_override.is_empty() and surface_override.get("appearance", "") == "procedural_mown_lawn"
				var use_library := surface_override.is_empty() and _surface_library_textures(key).size() == 3
				var color := Vector3(.11,.23,.048) if grass else (Vector3(.62,.54,.37) if sand else (Vector3(.30,.28,.235) if key == "road_concrete" else Vector3(.10,.105,.11)))
				if key == "road_dirt": color = Vector3(.42,.33,.24)
				elif key == "road_gravel": color = Vector3(.55,.50,.42)
				elif key == "road_sand": color = Vector3(.76,.70,.50)
				if use_mown_lawn:
					shader.code = _mown_lawn_terrain_shader(color, lawn_overrides)
				elif use_sand_pbr:
					shader.code = _sand_pbr_road_shader(color, surface_override)
				elif not surface_override.is_empty():
					shader.code = _sand_road_shader(color, surface_override)
				elif use_library:
					shader.code = SURFACE_LIBRARY_SHADER
				else:
					shader.code = """shader_type spatial;
varying vec3 world;
void vertex(){world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;}
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
void fragment(){float grain=hash(floor(world.xz*55.0));
float patch=sin(world.x*.23+sin(world.z*.19))*sin(world.z*.35)*.04;
ALBEDO=vec3(%f,%f,%f)*(0.92+grain*.16+patch);ROUGHNESS=.95;
}""" % [color.x,color.y,color.z]
				var material := ShaderMaterial.new()
				material.shader = shader
				if use_library:
					var entry: Dictionary = SURFACE_LIBRARY[key]
					var maps: Array = _surface_library_textures(key)
					var mean: Color = maps[0].get_meta("mean_linear")
					material.set_shader_parameter("albedo_tex", maps[0])
					material.set_shader_parameter("normal_tex", maps[1])
					material.set_shader_parameter("rough_tex", maps[2])
					material.set_shader_parameter("base_color", color)
					material.set_shader_parameter("mean_luminance", maxf(mean.get_luminance(), .01))
					material.set_shader_parameter("repeat_per_m", 1.0 / float(entry.repeat_m))
					material.set_shader_parameter("macro", float(entry.macro))
					material.set_shader_parameter("normal_strength", float(entry.normal))
					material.set_shader_parameter("rough_min", float(entry.get("rough_min", 0.0)))
				elif use_mown_lawn:
					for lawn_index in range(lawn_overrides.size()):
						var candidate: Dictionary = lawn_overrides[lawn_index]
						var texture_paths: Dictionary = candidate.get("textures", {})
						material.set_shader_parameter("lawn_diffuse_%d" % lawn_index, _load_sand_pbr_texture(String(texture_paths.get("diffuse", "")), false))
						material.set_shader_parameter("lawn_roughness_%d" % lawn_index, _load_sand_pbr_texture(String(texture_paths.get("roughness", "")), false))
				elif use_sand_pbr:
					var texture_paths: Dictionary = surface_override.get("textures", {})
					material.set_shader_parameter("sand_diffuse", _load_sand_pbr_texture(String(texture_paths.get("diffuse", "")), false))
					material.set_shader_parameter("sand_normal", _load_sand_pbr_texture(String(texture_paths.get("normal_opengl", "")), true))
					material.set_shader_parameter("sand_roughness", _load_sand_pbr_texture(String(texture_paths.get("roughness", "")), false))
					material.set_shader_parameter("sand_tint_linear", Vector3(surface_override.get("albedo_tint_linear", [1.0, 1.0, 1.0])[0], surface_override.get("albedo_tint_linear", [1.0, 1.0, 1.0])[1], surface_override.get("albedo_tint_linear", [1.0, 1.0, 1.0])[2]))
					material.set_shader_parameter("sand_repeat_per_m", 1.0 / float(surface_override.get("texture_repeat_m", 0.4)))
					material.set_shader_parameter("sand_normal_depth", float(surface_override.get("normal_depth", 0.42)))
					material.set_shader_parameter("sand_roughness_scale", float(surface_override.get("roughness_scale", 1.0)))
				material_cache[cache_key] = material
			node.set_surface_override_material(i,material_cache[cache_key])
	for child in node.get_children(): _style_meshes(child, tile_id, layer, tile_from_s, tile_to_s)

func _mown_lawn_terrain_shader(base_color: Vector3, overrides: Array) -> String:
	var checks := "float grain=hash(floor(world.xz*55.0)); float patch=sin(world.x*0.23+sin(world.z*0.19))*sin(world.z*0.35)*0.04; vec3 lawn_base=vec3(%f,%f,%f)*(0.92+grain*0.16+patch); vec3 lawn_albedo=lawn_base; float lawn_rough=0.95;" % [base_color.x,base_color.y,base_color.z]
	var uniforms := ""
	for index in range(overrides.size()):
		var override: Dictionary = overrides[index]
		var from_s := float(override.from_s)
		var to_s := float(override.to_s)
		var inner_u := float(override.get("inner_lateral_m", 2.3))
		var outer_u := float(override.get("outer_lateral_m", 13.0))
		var edge_fade := maxf(float(override.get("edge_fade_m", 0.8)), 0.1)
		var step := clampf(float(override.get("segment_step_m", 3.0)), 0.5, 10.0)
		var lateral_side := String(override.get("lateral_side", "left"))
		var lateral_expr := "best_u_%d" % index
		if lateral_side == "right":
			lateral_expr = "-best_u_%d" % index
		elif lateral_side == "both":
			lateral_expr = "abs(best_u_%d)" % index
		elif lateral_side != "left":
			push_error("Invalid mown lawn lateral_side '%s'; expected left, right, or both." % lateral_side)
		var pick := "float best_d2_%d=1e20; float best_u_%d=0.0; float best_s_%d=%f;" % [index,index,index,from_s]
		var s0 := from_s
		while s0 < to_s:
			var s1 := minf(s0 + step, to_s)
			var a3: Vector3 = route.position_at(s0)
			var b3: Vector3 = route.position_at(s1)
			var forward := Vector2(b3.x - a3.x, b3.z - a3.z).normalized()
			var left := Vector2(forward.y, -forward.x)
			pick += """{vec2 a=vec2(%f,%f), b=vec2(%f,%f), left=vec2(%f,%f); vec2 ab=b-a; float t=clamp(dot(world.xz-a,ab)/max(dot(ab,ab),0.0001),0.0,1.0); vec2 delta=world.xz-(a+t*ab); float d2=dot(delta,delta); if(d2<best_d2_%d){best_d2_%d=d2; best_u_%d=dot(delta,left); best_s_%d=mix(%f,%f,t);}}""" % [a3.x,a3.z,b3.x,b3.z,left.x,left.y,index,index,index,index,s0,s1]
			s0 = s1
		var tint: Array = override.get("albedo_tint_linear", [1.0,1.0,1.0])
		checks += pick + "float lawn_lateral_%d=%s;" % [index,lateral_expr]
		checks += "float lawn_mask_%d=smoothstep(%f,%f,lawn_lateral_%d)*(1.0-smoothstep(%f,%f,lawn_lateral_%d))*smoothstep(%f,%f,best_s_%d)*(1.0-smoothstep(%f,%f,best_s_%d))*(1.0-smoothstep(%f,%f,best_d2_%d));" % [index,inner_u,inner_u+edge_fade,index,outer_u-edge_fade,outer_u,index,from_s,from_s+edge_fade,index,to_s-edge_fade,to_s,index,outer_u*outer_u,(outer_u+edge_fade)*(outer_u+edge_fade),index]
		checks += "vec2 lawn_uv_%d=world.xz*(1.0/max(%f,0.01)); lawn_albedo=mix(lawn_albedo,texture(lawn_diffuse_%d,lawn_uv_%d).rgb*vec3(%f,%f,%f)*mix(0.91,1.025,value_noise(world.xz*0.22)),lawn_mask_%d*%f); lawn_rough=mix(lawn_rough,texture(lawn_roughness_%d,lawn_uv_%d).r,lawn_mask_%d);" % [index,float(override.get("texture_repeat_m",2.0)),index,index,tint[0],tint[1],tint[2],index,clampf(float(override.get("texture_strength",1.0)),0.0,1.0),index,index,index]
		uniforms += "uniform sampler2D lawn_diffuse_%d : source_color, filter_linear_mipmap_anisotropic, repeat_enable; uniform sampler2D lawn_roughness_%d : filter_linear_mipmap_anisotropic, repeat_enable;" % [index,index]
		if bool(override.get("debug_mask", false)):
			var debug_color: Array = override.get("debug_color_linear", [1.0,0.02,0.0])
			checks += "lawn_albedo=mix(lawn_albedo,vec3(%f,%f,%f),lawn_mask_%d);" % [debug_color[0],debug_color[1],debug_color[2],index]
	checks += "ALBEDO=lawn_albedo; ROUGHNESS=lawn_rough; METALLIC=0.0;"
	return """shader_type spatial;
%s
varying vec3 world;
void vertex(){world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;}
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float value_noise(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.0-2.0*f);float a=hash(i),b=hash(i+vec2(1.,0.)),c=hash(i+vec2(0.,1.)),d=hash(i+vec2(1.,1.));return mix(mix(a,b,f.x),mix(c,d,f.x),f.y);}
void fragment(){%s}
""" % [uniforms,checks]

func _road_surface_visual_override(material_key: String, route_s: float, overrides: Array) -> Dictionary:
	if not material_key.begins_with("road_"): return {}
	var surface_type := material_key.trim_prefix("road_")
	for override in overrides:
		if not override.get("surface_types", []).has(surface_type): continue
		if route_s < float(override.from_s) or route_s > float(override.to_s): continue
		return override
	return {}

func _load_sand_pbr_texture(path: String, normal_map: bool) -> Texture2D:
	var cache_key := "%s|normal=%s" % [path, str(normal_map)]
	if sand_pbr_texture_cache.has(cache_key): return sand_pbr_texture_cache[cache_key]
	if path.is_empty() or not FileAccess.file_exists(path):
		push_error("Sand PBR texture is missing: %s" % path)
		return null
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null or image.is_empty():
		push_error("Sand PBR texture could not be decoded: %s" % path)
		return null
	var mipmap_error := image.generate_mipmaps(normal_map)
	if mipmap_error != OK:
		push_error("Sand PBR mipmaps could not be generated: %s" % path)
		return null
	var texture := ImageTexture.create_from_image(image)
	sand_pbr_texture_cache[cache_key] = texture
	return texture

func _surface_library_textures(key: String) -> Array:
	# [albedo (meta mean_linear), normal, roughness], or [] when the library set is unavailable.
	if not SURFACE_LIBRARY.has(key): return []
	var base := "res://assets/textures/%s_" % SURFACE_LIBRARY[key].set
	var paths := [base + "diff.jpg", base + "nor.jpg", base + "rough.jpg"]
	for path in paths:
		if not FileAccess.file_exists(path): return []
	var albedo := _load_sand_pbr_texture(paths[0], false)
	if not albedo.has_meta("mean_linear"):
		var image := Image.load_from_file(ProjectSettings.globalize_path(paths[0]))
		image.convert(Image.FORMAT_RGB8)
		image.srgb_to_linear()
		image.convert(Image.FORMAT_RGBF)
		while image.get_width() > 1 or image.get_height() > 1: image.shrink_x2()
		albedo.set_meta("mean_linear", image.get_pixel(0, 0))
	return [albedo, _load_sand_pbr_texture(paths[1], true), _load_sand_pbr_texture(paths[2], false)]

# World-space triplanar PBR with a second, larger-scale sample and macro variation to hide tiling.
# Normals use a whiteout blend in world space, so terrain meshes need no UVs or tangents.
const SURFACE_LIBRARY_SHADER := """shader_type spatial;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 base_color = vec3(0.5);
uniform float mean_luminance = 0.5;
uniform float repeat_per_m = 0.25;
uniform float macro = 0.15;
uniform float normal_strength = 0.7;
uniform float rough_min = 0.0;
varying vec3 world;
varying vec3 world_normal;
void vertex(){world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;world_normal=normalize((MODEL_MATRIX*vec4(NORMAL,0.0)).xyz);}
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float value_noise(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.0-2.0*f);return mix(mix(hash(i),hash(i+vec2(1.,0.)),f.x),mix(hash(i+vec2(0.,1.)),hash(i+vec2(1.,1.)),f.x),f.y);}
void fragment(){
vec3 n=normalize(world_normal);
vec3 w=pow(abs(n),vec3(4.0));w/=w.x+w.y+w.z;
vec2 uy=world.xz*repeat_per_m,ux=world.zy*repeat_per_m,uz=world.xy*repeat_per_m;
// Anti-tiling: blend the top projection with a rotated 0.31x sample in noisy patches.
float blend=smoothstep(.35,.65,value_noise(world.xz*.09));
vec2 uy2=mat2(vec2(.8,.6),vec2(-.6,.8))*uy*.31+vec2(.37,.11);
vec3 top=mix(texture(albedo_tex,uy).rgb,texture(albedo_tex,uy2).rgb,blend);
vec3 albedo=top*w.y+texture(albedo_tex,ux).rgb*w.x+texture(albedo_tex,uz).rgb*w.z;
float rough=mix(texture(rough_tex,uy).r,texture(rough_tex,uy2).r,blend)*w.y+texture(rough_tex,ux).r*w.x+texture(rough_tex,uz).r*w.z;
float variation=value_noise(world.xz*.035)*.65+value_noise(world.xz*.17)*.35;
float detail=dot(albedo,vec3(.2126,.7152,.0722))/mean_luminance;
ALBEDO=base_color*clamp(detail,0.0,2.5)*(1.0+(variation-.5)*2.0*macro);
ROUGHNESS=clamp(rough,rough_min,1.0);METALLIC=0.0;SPECULAR=0.35;
vec3 t=texture(normal_tex,uy).xyz*2.0-1.0;t.xy*=normal_strength;
vec3 top_n=normalize(vec3(t.x+n.x,abs(t.z)*n.y,t.y+n.z));
NORMAL=normalize((VIEW_MATRIX*vec4(normalize(mix(n,top_n,w.y)),0.0)).xyz);
}"""

# P4 OSM buildings: UV is metres (u along the facade, v up), COLOR_0 the wall tint. Window bays every 3.2 m
# on 3.1 m floors with a slab line per floor; glass varies per window. Adapter-only appearance.
# Plaster luminance detail (no new hue), darker base course, faint rain streaks under each window column.
const FACADE_SHADER := """shader_type spatial;
uniform sampler2D detail : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float detail_mean = 1.0;
uniform float detail_per_m = 0.4;
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
void fragment(){
vec2 cell=vec2(UV.x/3.2,UV.y/3.1);vec2 f=fract(cell);vec2 id=floor(cell);
float window=step(.2,f.x)*step(f.x,.8)*step(.3,f.y)*step(f.y,.84);
float slab=1.0-step(.07,f.y);
float plaster=clamp(dot(texture(detail,UV*detail_per_m).rgb,vec3(.2126,.7152,.0722))/detail_mean,.6,1.4);
float base_course=mix(.72,1.0,smoothstep(.2,1.0,UV.y));
float streak=1.0-.1*step(.3,f.x)*step(f.x,.7)*(1.0-f.y)*hash(vec2(id.x,0.0));
vec3 wall=COLOR.rgb*.44*plaster*base_course*streak*(.94+.06*hash(floor(UV*.5)));
vec3 glass=mix(vec3(.07,.09,.11),vec3(.22,.27,.31),hash(id));
ALBEDO=mix(mix(wall,glass,window),wall*.8,slab);
ROUGHNESS=mix(.85,.12,window);METALLIC=mix(0.,.25,window);
}"""

const ROOF_TILE_SHADER := """shader_type spatial;
uniform sampler2D detail : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float detail_mean = 1.0;
uniform float detail_per_m = 0.5;
void fragment(){
float tiles=clamp(dot(texture(detail,UV*detail_per_m).rgb,vec3(.2126,.7152,.0722))/detail_mean,.5,1.5);
ALBEDO=COLOR.rgb*tiles;ROUGHNESS=.8;
}"""

func _sand_pbr_road_shader(base_color: Vector3, override: Dictionary) -> String:
	var color: Array = override.get("base_color_linear", [base_color.x, base_color.y, base_color.z])
	var from_s := float(override.from_s)
	var to_s := float(override.to_s)
	var repeat_per_m := 1.0 / maxf(float(override.get("texture_repeat_m", 0.4)), 0.001)
	var normal_depth := clampf(float(override.get("normal_depth", 0.42)), 0.0, 1.0)
	var roughness_scale := clampf(float(override.get("roughness_scale", 1.0)), 0.0, 1.5)
	var tint: Array = override.get("albedo_tint_linear", [1.0, 1.0, 1.0])
	var uv_warp_m := clampf(float(override.get("uv_warp_m", 0.035)), 0.0, 0.1)
	return """shader_type spatial;
uniform sampler2D sand_diffuse : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D sand_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D sand_roughness : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 sand_tint_linear = vec3(%f,%f,%f);
uniform float sand_repeat_per_m = %f;
uniform float sand_normal_depth = %f;
uniform float sand_roughness_scale = %f;
uniform float sand_uv_warp_m = %f;
varying vec3 world;
varying vec2 road_uv;
void vertex(){world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;road_uv=UV;}
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float value_noise(vec2 p){vec2 i=floor(p);vec2 f=fract(p);f=f*f*(3.0-2.0*f);float a=hash(i);float b=hash(i+vec2(1.0,0.0));float c=hash(i+vec2(0.0,1.0));float d=hash(i+vec2(1.0,1.0));return mix(mix(a,b,f.x),mix(c,d,f.x),f.y);}
void fragment(){
vec2 warp=vec2(value_noise(road_uv*vec2(0.21,0.13)),value_noise(road_uv*vec2(0.11,0.25)+vec2(17.1,5.7)))-0.5;
vec2 sand_uv=(road_uv+warp*sand_uv_warp_m)*sand_repeat_per_m;
vec3 diffuse=texture(sand_diffuse,sand_uv).rgb*sand_tint_linear;
vec3 normal_sample=texture(sand_normal,sand_uv).rgb;
float roughness=texture(sand_roughness,sand_uv).r;
float mottle=value_noise(road_uv*vec2(0.7,0.16));
float compacted=0.96+(mottle-0.5)*0.07;
NORMAL_MAP=vec3(0.5,0.5,1.0);NORMAL_MAP_DEPTH=1.0;
if(road_uv.y >= %f && road_uv.y <= %f){
ALBEDO=diffuse*compacted;
NORMAL_MAP=normal_sample;
NORMAL_MAP_DEPTH=sand_normal_depth;
ROUGHNESS=clamp(roughness*sand_roughness_scale,0.0,1.0);
METALLIC=0.0;
}else{
float grain=hash(floor(world.xz*55.0));float patch=sin(world.x*.23+sin(world.z*.19))*sin(world.z*.35)*.04;
ALBEDO=vec3(%f,%f,%f)*(0.92+grain*.16+patch);ROUGHNESS=.95;
}
}""" % [float(tint[0]), float(tint[1]), float(tint[2]), repeat_per_m, normal_depth, roughness_scale, uv_warp_m, from_s, to_s, color[0], color[1], color[2]]

func _sand_road_shader(base_color: Vector3, override: Dictionary) -> String:
	var color: Array = override.get("base_color_linear", [base_color.x, base_color.y, base_color.z])
	var from_s := float(override.from_s)
	var to_s := float(override.to_s)
	var grain_scale := float(override.get("grain_scale_per_m", 42.0))
	var cluster_scale := float(override.get("cluster_scale_per_m", 7.5))
	var mottle_scale := float(override.get("mottle_scale_per_m", 2.2))
	var track_width := float(override.get("track_width_m", 0.20))
	var track_left := absf(float(override.get("track_centres_m", [-0.34, 0.34])[0]))
	var track_right := absf(float(override.get("track_centres_m", [-0.34, 0.34])[1]))
	var roughness := float(override.get("roughness", 0.97))
	return """shader_type spatial;
varying vec3 world;
varying vec2 road_uv;
void vertex(){world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;road_uv=UV;}
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float value_noise(vec2 p){vec2 i=floor(p);vec2 f=fract(p);f=f*f*(3.0-2.0*f);float a=hash(i);float b=hash(i+vec2(1.0,0.0));float c=hash(i+vec2(0.0,1.0));float d=hash(i+vec2(1.0,1.0));return mix(mix(a,b,f.x),mix(c,d,f.x),f.y);}
void fragment(){
float cluster=value_noise(world.xz*%f);
float base_grain=value_noise(world.xz*%f);
float fine_grain=hash(floor(world.xz*%f*2.6));
float mottle=value_noise(world.xz*%f);
float track_wobble=(value_noise(vec2(road_uv.y*0.055,1.7))-0.5)*0.14;
float rut_l=1.0-smoothstep(%f*0.25,%f,abs(road_uv.x-(-%f+track_wobble)));
float rut_r=1.0-smoothstep(%f*0.25,%f,abs(road_uv.x-(%f+track_wobble)));
float tracks=max(rut_l,rut_r);
float relief=value_noise(world.xz*%f);
vec2 relief_gradient=vec2(dFdx(relief),dFdy(relief))*12.0;
if(road_uv.y >= %f && road_uv.y <= %f){
vec3 tangent_normal=normalize(vec3(-relief_gradient,1.0));
NORMAL_MAP=tangent_normal*0.5+0.5;NORMAL_MAP_DEPTH=0.65;
ALBEDO=vec3(%f,%f,%f)*(0.79+cluster*0.12+base_grain*0.22+fine_grain*0.08+(mottle-0.5)*0.26-tracks*0.08);
ROUGHNESS=%f;METALLIC=0.0;
}else{
float grain=hash(floor(world.xz*55.0));float patch=sin(world.x*.23+sin(world.z*.19))*sin(world.z*.35)*.04;
ALBEDO=vec3(%f,%f,%f)*(0.92+grain*.16+patch);ROUGHNESS=.95;
}
}""" % [cluster_scale, grain_scale, grain_scale, mottle_scale, track_width, track_width, track_left, track_width, track_width, track_right, grain_scale * 1.8, from_s, to_s, float(color[0]), float(color[1]), float(color[2]), roughness, base_color.x, base_color.y, base_color.z]
