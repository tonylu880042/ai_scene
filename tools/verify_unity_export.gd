extends SceneTree
# Rebuild an export_unity folder from its files only (glb tiles + prototypes + instance JSON + environment)
# and render one frame from the start of the route, to check the export is complete and correctly placed.
#   godot --path . --script tools/verify_unity_export.gd -- export_unity/test /tmp/out.png [s_metres]
func _initialize() -> void:
	_run.call_deferred()

func _load_glb(path: String) -> Node:
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(path, st) != OK:
		push_error("cannot load " + path)
		return Node3D.new()
	return doc.generate_scene(st)

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
		var m := mi.mesh
		for si in m.get_surface_count():  # glTF COLOR_0 multiplies base colour (Godot's importer leaves it off)
			if m.surface_get_format(si) & Mesh.ARRAY_FORMAT_COLOR and m.surface_get_material(si) is StandardMaterial3D:
				(m.surface_get_material(si) as StandardMaterial3D).vertex_color_use_as_albedo = true
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
			mm.instance_count = d.size() / 10
			for i in mm.instance_count:
				var k := i * 10
				var b := Basis(Quaternion(d[k + 3], d[k + 4], d[k + 5], d[k + 6])).scaled_local(Vector3(d[k + 7], d[k + 8], d[k + 9]))
				mm.set_instance_transform(i, Transform3D(b, Vector3(d[k], d[k + 1], d[k + 2])))
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			world.add_child(mmi)
			total += mm.instance_count
	world.add_child(_load_glb(dir.path_join("backdrop.glb")))
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.7, 0.9)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.65, 0.75)
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	we.environment = e
	world.add_child(we)
	var route: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("route.json")))
	var s := int(a[2]) if a.size() > 2 else int(env["route_from_m"]) + 5
	var p := Vector3(route["x"][s], route["y"][s] + 1.65, route["z"][s])
	var q := Vector3(route["x"][s + 3], route["y"][s + 3] + 1.65, route["z"][s + 3])
	var cam := Camera3D.new()
	cam.fov = 75.0
	cam.far = 30000.0
	world.add_child(cam)
	cam.look_at_from_position(p, q, Vector3.UP)
	cam.current = true
	print("verify: tiles ", env["tiles"].size(), ", prototypes ", meshes.size(), ", instances ", total)
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(a[1])
	print("verify: saved ", a[1])
	quit()
