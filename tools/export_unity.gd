extends SceneTree
# Bake the alpine trail scene for one course into Unity-ready glTF (.glb) tiles. Scene only - no avatars.
#
#   godot --path . --script tools/export_unity.gd -- --course=summit [--out=export_unity/summit]
#         [--from-m=0] [--to-m=<course length>] [--tile-m=750] [--grass=0.15] [--flowers=0.35]
#
# Run WITH a window (not --headless): textures are read back from the GPU for embedding.
# Output (see README_UNITY.md written next to the tiles):
#   tile_XX.glb       trail + terrain ribbon and unique props for one stretch of the route (world coordinates)
#   tile_XX_instances.json  where every repeated object (trees, grass clumps, flowers, rocks, fence parts) goes
#   prototypes.glb    each repeated object's mesh + materials, stored once (child nodes named after the prototype)
#   backdrop.glb      the real Swiss terrain around the start of the route + the sun (KHR_lights_punctual)
#   sky.hdr           the HDRI sky (Unity: Skybox/Panoramic); sky_yaw_deg in environment.json lines up its sun
#   environment.json  sun, ambient, fog, tonemapping, camera, tile list
#   route.json        centre line every 1 m (same format as the video exports)
# Godot-only shaders are replaced by standard PBR materials (glTF): the trail becomes dirt + grass surfaces,
# terrain is grass, grass clumps use vertex colours; the ray-marched cloud sea and the procedural sky are not
# exportable (use the HDRI + a Unity volumetric cloud asset).

const SCENE := "res://MainScene_alpine.tscn"
var A := {}
var _route: Route
var _mat_cache := {}
var _protos := {}        # source mesh instance id -> {"name", "mesh", "gpu"}
var _proto_names := {}  # name -> true

func _arg(k: String, d: String) -> String:
	return A.get(k, d)

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			A[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_run.call_deferred()

func _run() -> void:
	var course := _arg("course", "summit")
	var out := ProjectSettings.globalize_path("res://").path_join(_arg("out", "export_unity/" + course))
	DirAccess.make_dir_recursive_absolute(out)
	var scene: Node = (load(SCENE) as PackedScene).instantiate()
	for n in ["HUD", "TrackExporter", "RenderQuality"]:
		var node := scene.get_node_or_null(n)
		if node:
			node.free()
	root.add_child(scene)
	var foliage := scene.get_node("Foliage")
	var player: Node = scene.get_node("Player")
	player.set_physics_process(false)
	player.set_process_unhandled_input(false)
	foliage.set_process(false)
	await process_frame
	await process_frame
	_route = scene.get_node("Path3D")
	for k in foliage._chunks.keys():
		foliage._chunks[k].free()
	foliage._chunks.clear()
	var from_m := float(_arg("from-m", "0"))
	var to_m := minf(float(_arg("to-m", str(_route.length))), _route.length)
	var tile_m := float(_arg("tile-m", "750"))
	foliage.meadow_clumps = int(foliage.meadow_clumps * float(_arg("grass", "0.15")))
	foliage.flowers_per_patch = maxi(int(foliage.flowers_per_patch * float(_arg("flowers", "0.35"))), 1)
	print("export_unity: course ", course, " ", from_m, "..", to_m, " m")

	# --- spawn every foliage chunk in range
	var cl: float = foliage.chunk_length
	for idx in range(int(from_m / cl), int(ceil(to_m / cl))):
		await foliage._spawn(idx)
	await process_frame

	# --- sort exportable nodes into tiles by distance along the route
	var tiles := {}
	var put := func(node: Node3D, s: float) -> void:
		if s < from_m - 1.0 or s > to_m + 1.0:
			return
		var last := maxi(int(ceil((to_m - from_m) / tile_m)) - 1, 0)
		var t := clampi(int(floor((s - from_m) / tile_m)), 0, last)  # boundary objects join the last tile
		if not tiles.has(t):
			tiles[t] = []
		tiles[t].append(node)
	for c in _route.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh and (c as MeshInstance3D).mesh.get_surface_count() > 0:
			var aabb := (c as MeshInstance3D).get_aabb()
			put.call(c, _s_of(c.global_transform * aabb.get_center()))
	for idx in foliage._chunks.keys():
		put.call(foliage._chunks[idx], idx * cl + cl * 0.5)
	for parent_name in ["Props", "Gates"]:
		var p := scene.get_node_or_null(parent_name)
		if p:
			for c in p.get_children():
				if c is Node3D:
					put.call(c, _s_of((c as Node3D).global_position))

	# --- export tiles
	var tile_list := []
	for t in tiles.keys():
		var tile := Node3D.new()
		tile.name = "tile_%02d" % t
		root.add_child(tile)
		for n: Node3D in tiles[t]:
			n.reparent(tile, true)
		var groups := _prepare(tile)
		var fname := "tile_%02d.glb" % t
		_export(tile, out.path_join(fname))
		var inst_name := "tile_%02d_instances.json" % t
		var jf := FileAccess.open(out.path_join(inst_name), FileAccess.WRITE)
		jf.store_string(JSON.stringify({"tile": fname, "layout": "per instance: px py pz qx qy qz qw sx sy sz (glTF/Godot axes)", "groups": groups}))
		jf.close()
		tile_list.append({"file": fname, "instances": inst_name, "from_m": from_m + t * tile_m, "to_m": minf(from_m + (t + 1) * tile_m, to_m)})
		print("  wrote ", fname)
		tile.free()
		await process_frame

	# --- prototypes: every repeated mesh once, as a child node named after the prototype
	var pr := Node3D.new()
	pr.name = "prototypes"
	root.add_child(pr)
	for key in _protos.keys():
		var d: Dictionary = _protos[key]
		var mi := MeshInstance3D.new()
		mi.name = d["name"]
		mi.mesh = d["mesh"]
		pr.add_child(mi)
	_set_owner(pr, pr)
	_export(pr, out.path_join("prototypes.glb"))
	var plist := []
	for key in _protos.keys():
		plist.append({"name": _protos[key]["name"], "gpu_instanced": _protos[key]["gpu"]})
	pr.free()

	# --- backdrop (real terrain around the start) + sun
	var start := _route.pos_at(from_m)
	var bd := Node3D.new()
	bd.name = "backdrop"
	root.add_child(bd)
	var rt := scene.get_node_or_null("RealBackdrop/RealTerrain") as MeshInstance3D
	if rt:
		var copy := MeshInstance3D.new()
		copy.name = "RealTerrain"
		copy.mesh = rt.mesh
		var m := StandardMaterial3D.new()
		m.albedo_texture = (rt.material_override as ShaderMaterial).get_shader_parameter("albedo_tex")
		m.roughness = 1.0
		copy.material_override = m
		bd.add_child(copy)
		copy.transform = Transform3D(rt.global_transform.basis, start)
	var sun := scene.get_node("Sun") as DirectionalLight3D
	var sun_copy := DirectionalLight3D.new()
	sun_copy.name = "Sun"
	sun_copy.global_transform = sun.global_transform
	sun_copy.light_color = sun.light_color
	sun_copy.light_energy = sun.light_energy
	bd.add_child(sun_copy)
	_set_owner(bd, bd)
	_export(bd, out.path_join("backdrop.glb"))
	bd.free()

	# --- environment, route, sky
	var env := (scene.get_node("WorldEnvironment") as WorldEnvironment).environment
	var sky_mat := env.sky.sky_material as ShaderMaterial
	var sky_tex: Texture2D = sky_mat.get_shader_parameter("pano")
	var to_sun := sun.global_transform.basis.z
	var envd := {
		"course": course, "units": "metres, Y up (glTF); Unity's glTF importer converts handedness",
		"route_from_m": from_m, "route_to_m": to_m, "start_position": [start.x, start.y, start.z],
		"tiles": tile_list, "prototypes_file": "prototypes.glb", "prototypes": plist,
		"sun": {"direction_to_sun": [to_sun.x, to_sun.y, to_sun.z], "color": [sun.light_color.r, sun.light_color.g, sun.light_color.b],
			"energy": sun.light_energy, "elevation_deg": rad_to_deg(asin(to_sun.y)), "soft_shadows": true},
		"sky": {"hdri": "sky.hdr", "source": sky_tex.resource_path.get_file(), "yaw_deg": rad_to_deg(float(sky_mat.get_shader_parameter("yaw")))},
		"ambient": {"source": "sky", "energy": env.ambient_light_energy},
		"fog": {"density_exp": env.fog_density, "color": [env.fog_light_color.r, env.fog_light_color.g, env.fog_light_color.b],
			"aerial_perspective": env.fog_aerial_perspective},
		"tonemap": {"mode": "AgX", "exposure": env.tonemap_exposure, "saturation": env.adjustment_saturation, "contrast": env.adjustment_contrast},
		"camera": {"height_m": 1.65, "fov_y_deg": 75.0, "far_m": 30000.0},
		"cloud_sea": {"note": "ray-marched in Godot (cloud_volume.gdshader); recreate with a Unity volumetric cloud layer",
			"top_below_runner_m": 17.0, "thickness_m": 120.0},
	}
	var f := FileAccess.open(out.path_join("environment.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(envd, "  "))
	f.close()
	_write_route(out.path_join("route.json"))
	DirAccess.copy_absolute(ProjectSettings.globalize_path(sky_tex.resource_path), out.path_join("sky.hdr"))
	for f2 in ["README_UNITY.md", "VirtualRunScatter.cs"]:
		DirAccess.copy_absolute(ProjectSettings.globalize_path("res://").path_join("tools/unity/" + f2), out.path_join(f2))
	print("export_unity: done -> ", out)
	quit()

func _s_of(p: Vector3) -> float:
	return _route.curve.get_closest_offset(_route.to_local(p))

func _set_owner(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		c.owner = owner_node
		_set_owner(c, owner_node)

func _export(node: Node, path: String) -> void:
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var err := doc.append_from_scene(node, st)
	if err == OK:
		err = doc.write_to_filesystem(st, path)
	if err != OK:
		push_error("glTF export failed for %s: %s" % [path, err])

# ---------------------------------------------------------------- conversion to plain glTF content
func _prepare(tile: Node3D) -> Array:
	var junk := []
	for n in tile.find_children("*", "", true, false):
		if n is CollisionObject3D or n is CollisionShape3D or n is CPUParticles3D or n is Label3D:
			junk.append(n)
	for n in junk:
		if is_instance_valid(n):
			n.free()
	for n in tile.find_children("*", "MeshInstance3D", true, false):
		_convert_mesh_instance(n)
	var groups := {}  # proto name -> PackedFloat32Array
	var add := func(proto: Dictionary, xf: Transform3D) -> void:
		var q := xf.basis.get_rotation_quaternion()
		var sc := xf.basis.get_scale()
		if not groups.has(proto["name"]):
			groups[proto["name"]] = []
		groups[proto["name"]].append_array([snappedf(xf.origin.x, 0.001), snappedf(xf.origin.y, 0.001), snappedf(xf.origin.z, 0.001),
				snappedf(q.x, 0.0001), snappedf(q.y, 0.0001), snappedf(q.z, 0.0001), snappedf(q.w, 0.0001),
				snappedf(sc.x, 0.001), snappedf(sc.y, 0.001), snappedf(sc.z, 0.001)])
	var scatter := []
	for mmi: MultiMeshInstance3D in tile.find_children("*", "MultiMeshInstance3D", true, false):
		var mm := mmi.multimesh
		if mm and mm.mesh:
			for i in mm.instance_count:
				var xf := mmi.global_transform * mm.get_instance_transform(i)
				add.call(_proto(mm.mesh, i), xf)
		scatter.append(mmi)
	for mi: MeshInstance3D in tile.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh and mi.get_parent() != tile and mi.mesh.get_faces().size() > 30000:  # scanned trees
			add.call(_proto(mi.mesh, 0), mi.global_transform)
			scatter.append(mi)
	for n in scatter:
		n.free()
	_set_owner(tile, tile)
	var out := []
	for name in groups.keys():
		out.append({"proto": name, "count": groups[name].size() / 10, "data": groups[name]})
	return out

# prototype for a repeated mesh; grass clumps (custom shader) become 3 vertex-coloured colour variants
func _proto(mesh: Mesh, i: int) -> Dictionary:
	var mat := mesh.surface_get_material(0)
	var is_grass := mat is ShaderMaterial and (mat as ShaderMaterial).shader.resource_path.ends_with("grass.gdshader")
	var key: Variant = mesh.get_instance_id()
	if is_grass:
		key = "grass_%d" % (i % 3)
	if _protos.has(key):
		return _protos[key]
	var m: Mesh = mesh
	var base := mesh.resource_name if mesh.resource_name != "" else ("mesh_%d" % _protos.size())
	if is_grass:
		m = _grass_variant(mesh, i % 3)
		base = "grass_clump_%d" % (i % 3)
	var name := base.validate_node_name().replace(" ", "_")
	while _proto_names.has(name):
		name += "_b"
	_proto_names[name] = true
	var d := {"name": name, "mesh": m, "gpu": mesh.get_faces().size() < 60000}
	_protos[key] = d
	return d

func _grass_variant(mesh: Mesh, variant: int) -> ArrayMesh:
	var arr := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var tips := [Color(0.30, 0.50, 0.10), Color(0.24, 0.44, 0.08), Color(0.52, 0.52, 0.20)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in v.size():
		st.set_color(Color(0.05, 0.13, 0.03).lerp(tips[variant], smoothstep(0.0, 0.85, uv[k].y)))
		st.add_vertex(v[k])
	st.index()
	st.generate_normals()
	var out := st.commit()
	out.surface_set_material(0, _mat("grass_blades"))
	return out

func _mat(key: String) -> StandardMaterial3D:
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.resource_name = key
	match key:
		"trail_dirt":
			m.albedo_texture = load("res://assets/textures/rocky_trail_diff.jpg")
			m.normal_enabled = true
			m.normal_texture = load("res://assets/textures/rocky_trail_nor.jpg")
			m.albedo_color = Color(0.68, 0.64, 0.6)
			m.roughness = 0.9
		"meadow":
			m.albedo_texture = load("res://assets/textures/aerial_grass_rock_diff.jpg")
			m.normal_enabled = true
			m.normal_texture = load("res://assets/textures/aerial_grass_rock_nor.jpg")
			m.albedo_color = Color(0.6, 0.95, 0.35)
			m.roughness = 0.95
		"grass_blades":
			m.vertex_color_use_as_albedo = true
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.roughness = 0.8
	_mat_cache[key] = m
	return m

# rebuild a world-space mesh with planar world UVs (Godot used world-triplanar shaders, glTF needs real UVs)
func _world_uv_mesh(src: Mesh, xf: Transform3D, uv_scale: float, split_trail: bool) -> ArrayMesh:
	var out := ArrayMesh.new()
	var groups := {}  # material key -> SurfaceTool
	for si in src.get_surface_count():
		var arr := src.surface_get_arrays(si)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] else PackedVector3Array()
		var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] else PackedVector2Array()
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] else PackedInt32Array()
		var tri_count := (idx.size() if idx.size() > 0 else v.size()) / 3
		for t in tri_count:
			var ids := [t * 3, t * 3 + 1, t * 3 + 2]
			if idx.size() > 0:
				ids = [idx[t * 3], idx[t * 3 + 1], idx[t * 3 + 2]]
			var key := "meadow"
			if split_trail:  # the walked surface is |UV.x| <= 1, the blend band beyond it becomes meadow
				var inside := 0
				for k in ids:
					if absf(uv[k].x) <= 1.0:
						inside += 1
				key = "trail_dirt" if inside >= 2 else "meadow"
			if not groups.has(key):
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				groups[key] = st
			var stg: SurfaceTool = groups[key]
			var sc := uv_scale * (2.2 if key == "trail_dirt" else 1.0)
			for k in ids:
				var w := xf * v[k]
				if nrm.size() > 0:
					stg.set_normal((xf.basis * nrm[k]).normalized())
				stg.set_uv(Vector2(w.x, w.z) * sc)
				stg.add_vertex(w)
	for key in groups.keys():
		var st: SurfaceTool = groups[key]
		st.generate_tangents()
		st.commit(out)
		out.surface_set_material(out.get_surface_count() - 1, _mat(key))
	return out

func _convert_mesh_instance(mi: MeshInstance3D) -> void:
	var sm := mi.material_override as ShaderMaterial
	if sm == null or sm.shader == null:
		return
	var path := sm.shader.resource_path.get_file()
	var xf := mi.global_transform
	if path == "trail.gdshader" or path == "terrain.gdshader":
		var m := _world_uv_mesh(mi.mesh, xf, 0.2, path == "trail.gdshader")
		mi.material_override = null
		mi.mesh = m
		mi.global_transform = Transform3D.IDENTITY
	else:
		mi.material_override = _mat("meadow")

func _write_route(path: String) -> void:
	var d := {"version": 1, "step": 1.0, "length": _route.length, "s": [], "x": [], "y": [], "z": [], "half_left": [], "half_right": []}
	for i in int(floor(_route.length)) + 1:
		var p := _route.pos_at(float(i))
		d["s"].append(i)
		d["x"].append(snappedf(p.x, 0.001))
		d["y"].append(snappedf(p.y, 0.001))
		d["z"].append(snappedf(p.z, 0.001))
		d["half_left"].append(snappedf(_route.half_left(float(i)), 0.01))
		d["half_right"].append(snappedf(_route.half_right(float(i)), 0.01))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()
