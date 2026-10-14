extends SceneTree
# Rebuild an export_unity folder from its files only (glb tiles + prototypes + instance JSON + environment)
# and render one frame from the start of the route, to check the export is complete and correctly placed.
#   godot --path . --script tools/verify_unity_export.gd -- export_unity/test /tmp/out.png [s_metres]
const VIEW_M := 400.0  # instances farther than this from the camera are not drawn

func _initialize() -> void:
	_run.call_deferred()

func _load_glb(path: String) -> Node:
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(path, st) != OK:
		push_error("cannot load " + path)
		return Node3D.new()
	return doc.generate_scene(st)

func _vertex_colours(m: Mesh) -> void:  # glTF COLOR_0 multiplies base colour (Godot's importer leaves it off)
	if m == null:
		return
	for si in m.get_surface_count():
		if m.surface_get_format(si) & Mesh.ARRAY_FORMAT_COLOR and m.surface_get_material(si) is StandardMaterial3D:
			(m.surface_get_material(si) as StandardMaterial3D).vertex_color_use_as_albedo = true

func _run() -> void:
	var a := OS.get_cmdline_user_args()
	var dir := ProjectSettings.globalize_path("res://").path_join(a[0])
	var env: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("environment.json")))
	var world := Node3D.new()
	root.add_child(world)
	var protos := _load_glb(dir.path_join("prototypes.glb"))
	var meshes := {}
	for mi: MeshInstance3D in protos.find_children("*", "MeshInstance3D", true, false):
		meshes[str(mi.name)] = mi.mesh
		_vertex_colours(mi.mesh)
	var route: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("route.json")))
	var s := int(a[2]) if a.size() > 2 else int(env["route_from_m"]) + 5
	var p := Vector3(route["x"][s], route["y"][s] + 1.65, route["z"][s])
	var q := Vector3(route["x"][s + 3], route["y"][s + 3] + 1.65, route["z"][s + 3])
	var total := 0
	for t in env["tiles"]:
		world.add_child(_load_glb(dir.path_join(t["file"])))
		var inst: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(t["instances"])))
		for g in inst["groups"]:
			var d: Array = g["data"]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = meshes.get(g["proto"])
			if mm.mesh == null:
				push_error("missing prototype " + g["proto"])
				continue
			# only what a runtime would draw around the camera (Godot: tree_view_distance 300 m, grass less): drawing all
			# 1800 scanned trees of a route (~1.5 G vertices) made Metal time out and return black frames
			var view := 300.0 if mm.mesh.get_faces().size() > 60000 else VIEW_M
			var xfs := []
			for k in range(0, d.size(), 10):
				if Vector2(d[k] - p.x, d[k + 2] - p.z).length() > view:
					continue
				var b := Basis(Quaternion(d[k + 3], d[k + 4], d[k + 5], d[k + 6])).scaled_local(Vector3(d[k + 7], d[k + 8], d[k + 9]))
				xfs.append(Transform3D(b, Vector3(d[k], d[k + 1], d[k + 2])))
			mm.instance_count = xfs.size()
			for i in xfs.size():
				mm.set_instance_transform(i, xfs[i])
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			world.add_child(mmi)
			total += mm.instance_count
	var backdrop := _load_glb(dir.path_join("backdrop.glb"))
	world.add_child(backdrop)
	if FileAccess.file_exists(dir.path_join("water.glb")):
		world.add_child(_load_glb(dir.path_join("water.glb")))
	for mi: MeshInstance3D in world.find_children("*", "MeshInstance3D", true, false):  # tiles: COLOR_0 too
		_vertex_colours(mi.mesh)
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.7, 0.9)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.65, 0.75)
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	we.environment = e
	world.add_child(we)
	# the backdrop follows the runner (VirtualRunBackdrop.cs in Unity): x/z with the camera, y at the lake level
	var s0 := int(env["route_from_m"])
	if backdrop is Node3D:
		(backdrop as Node3D).position = Vector3(p.x - route["x"][s0], route["water_y"][s] - route["water_y"][s0], p.z - route["z"][s0])
	var cam := Camera3D.new()
	cam.fov = 75.0
	cam.far = 30000.0
	world.add_child(cam)
	cam.look_at_from_position(p, q, Vector3.UP)
	cam.current = true
	print("verify: tiles ", env["tiles"].size(), ", prototypes ", meshes.size(), ", instances drawn ", total)
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(a[1])
	print("verify: saved ", a[1])
	quit()
