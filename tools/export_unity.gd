extends SceneTree
# Bake the alpine trail scene for one course into Unity-ready glTF (.glb) tiles. Scene only - no avatars.
#
#   godot --path . --script tools/export_unity.gd -- --course=summit [--out=export_unity/summit] [--scene=res://MainScene_garda.tscn]
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
var _sheared := {}      # prototype names already warned about

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
	FileAccess.open(out.get_base_dir().path_join(".gdignore"), FileAccess.WRITE)  # keep Godot from importing the output
	var scene: Node = (load(_arg("scene", SCENE)) as PackedScene).instantiate()
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
		# as at runtime: the backdrop follows the runner at the lake level, the terrain offset by its anchor
		copy.transform = Transform3D(rt.global_transform.basis, Vector3(start.x, _route.water_level(from_m), start.z) + rt.position)
	var lake_far := scene.get_node_or_null("LakeFar") as MeshInstance3D
	if lake_far:  # the 40 km far lake that follows the runner in Godot: moves with the backdrop (covers its sunk hole)
		var lf := MeshInstance3D.new()
		lf.name = "lake_far"
		var pm := PlaneMesh.new()
		pm.size = Vector2(40000, 40000)
		lf.mesh = pm
		lf.material_override = _water_mat(lake_far.get_surface_override_material(0) as ShaderMaterial)
		lf.position = Vector3(start.x, _route.water_level(from_m) - 0.08, start.z)
		bd.add_child(lf)
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

	# --- lake: in Godot a plane follows the runner at Route.water_level (it differs per section, and rises with the
	# course's climb), so the static scene gets a ribbon at that level from under the path out to WATER_OUT_M lakeward
	var lake := scene.get_node_or_null("Lake") as MeshInstance3D
	if lake:
		var wn := Node3D.new()
		wn.name = "water"
		root.add_child(wn)
		var wmi := MeshInstance3D.new()
		wmi.name = "lake"
		wmi.mesh = _water_mesh(from_m, to_m, lake.get_surface_override_material(0) as ShaderMaterial)
		wn.add_child(wmi)
		_set_owner(wn, wn)
		_export(wn, out.path_join("water.glb"))
		wn.free()

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
		"backdrop": {"file": "backdrop.glb", "follows_runner": true, "placed_at_m": from_m,
			"note": "placed for the route start; moves with the runner in x/z at the lake level (water_y) and turns by backdrop_yaw about the runner, as in Godot - VirtualRunBackdrop.cs"},
		"water": {"file": "water.glb" if lake else "", "note": "lake surface (material lake_water: replace with a Unity water shader); its height follows route.json water_y"},
		"sea_y": _route.sea_y, "sea_side": "right" if _route.sea_right else "left",  # water plane level (coast / garda scenes)
	}
	var f := FileAccess.open(out.path_join("environment.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(envd, "  "))
	f.close()
	_write_route(out.path_join("route.json"))
	DirAccess.copy_absolute(ProjectSettings.globalize_path(sky_tex.resource_path), out.path_join("sky.hdr"))
	for f2 in ["README_UNITY.md", "VirtualRunScatter.cs", "VirtualRunBackdrop.cs"]:
		DirAccess.copy_absolute(ProjectSettings.globalize_path("res://").path_join("tools/unity/" + f2), out.path_join(f2))
	print("export_unity: done -> ", out)
	quit()

const WATER_OUT_M := 1500.0

func _water_mesh(from_m: float, to_m: float, sm: ShaderMaterial) -> ArrayMesh:
	var side := -1.0 if _route.sea_right else 1.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rows := []
	var s := from_m
	while true:
		var p := _route.pos_at(s)
		var l := _route.left_at(s) * side
		l = Vector3(l.x, 0.0, l.z).normalized()
		var a := Vector3(p.x, _route.water_level(s), p.z)
		rows.append([a, a + l * WATER_OUT_M])
		if s >= to_m:
			break
		s = minf(s + 5.0, to_m)
	for i in range(1, rows.size()):
		var q := [rows[i - 1][0], rows[i - 1][1], rows[i][1], rows[i][0]]
		var order := [0, 1, 2, 0, 2, 3]
		if (q[1] - q[0]).cross(q[2] - q[0]).y < 0.0:  # Godot's front faces are clockwise seen from the normal side
			order = [0, 2, 1, 0, 3, 2]
		for k in order:
			var w: Vector3 = q[k]
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(w.x, w.z) * 0.08)  # ocean_water.gdshader normal_scale
			st.add_vertex(w)
	st.index()
	st.generate_tangents()
	var mesh := st.commit()
	mesh.surface_set_material(0, _water_mat(sm))
	return mesh

var _water_m: StandardMaterial3D
func _water_mat(sm: ShaderMaterial) -> StandardMaterial3D:
	if _water_m:
		return _water_m
	var m := StandardMaterial3D.new()
	m.resource_name = "lake_water"
	m.albedo_color = Color(0.03, 0.22, 0.42)
	m.roughness = 0.12
	if sm:
		m.albedo_color = (sm.get_shader_parameter("deep_color") as Color) if sm.get_shader_parameter("deep_color") != null else m.albedo_color
		m.roughness = sm.get_shader_parameter("water_roughness") if sm.get_shader_parameter("water_roughness") != null else m.roughness
		var nt: Texture2D = sm.get_shader_parameter("normal_a")
		if nt and nt.get_image():
			m.normal_enabled = true
			m.normal_texture = ImageTexture.create_from_image(nt.get_image())
	_water_m = m
	return m

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
		if not Basis(q).scaled_local(sc).is_equal_approx(xf.basis) and not _sheared.has(proto["name"]):
			_sheared[proto["name"]] = true  # glTF / Unity keep rotation + scale only: a sheared basis comes out twisted
			push_warning("export_unity: %s instances are sheared (use Basis.scaled_local)" % proto["name"])
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
	_gltf_safe_mesh(m)
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
	if mi.material_override is StandardMaterial3D:
		mi.material_override = _gltf_safe(mi.material_override)
	if mi.mesh:
		_gltf_safe_mesh(mi.mesh)
	var sm := mi.material_override as ShaderMaterial
	if sm == null or sm.shader == null:
		return
	var path := sm.shader.resource_path.get_file()
	var xf := mi.global_transform
	if path == "trail.gdshader" or path == "terrain.gdshader":
		var m := _terrain_mesh(mi.mesh, xf, sm) if path == "terrain.gdshader" else _world_uv_mesh(mi.mesh, xf, 0.2, true)
		mi.material_override = null
		mi.mesh = m
		mi.global_transform = Transform3D.IDENTITY
	else:
		mi.material_override = _mat("meadow")

# ---------------------------------------------------------------- terrain.gdshader -> plain glTF
# Per triangle: grass, sand or rock material whose texture is only detail (normalised to a flat mean, rock greyed), with
# box-projected world UVs. Per vertex COLOR_0 (glTF multiplies it into the base colour; keep glTFast's materials in
# Unity): the shader's low-frequency terms - tints, dry patches, macro light/dark, limestone streaks and stains, the
# orthophoto colour on the real mountains. Fine noise of the shader (grain, second scales) is not reproduced.
const DETAIL_MEAN := 0.75  # mean of the normalised detail textures (headroom: vertex colours stay <= 1)
var _tex_info_cache := {}

func _sp(sm: ShaderMaterial, k: String, d: Variant) -> Variant:
	var v: Variant = sm.get_shader_parameter(k)
	return d if v == null else v

func _lum(c: Color) -> float:
	return c.r * 0.3 + c.g * 0.59 + c.b * 0.11

# {small: 64 px linear image for low-frequency lookups, mean: linear mean colour, tex: normalised detail texture}
func _tex_info(t: Texture2D, grey: bool) -> Dictionary:
	var key := "%d_%s" % [t.get_instance_id(), grey]
	if _tex_info_cache.has(key):
		return _tex_info_cache[key]
	var img := t.get_image()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGB8)
	var small := img.duplicate() as Image
	small.resize(64, 64, Image.INTERPOLATE_TRILINEAR)
	small.convert(Image.FORMAT_RGBF)
	var mean := Color(0, 0, 0)
	for y in 64:
		for x in 64:
			var c := small.get_pixel(x, y).srgb_to_linear()
			small.set_pixel(x, y, c)
			mean += c / 4096.0
	if grey:
		var l := _lum(mean)
		mean = Color(l, l, l)
	if img.get_width() > 1024:
		img.resize(1024, 1024, Image.INTERPOLATE_CUBIC)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y).srgb_to_linear()
			if grey:
				var l := clampf(_lum(c) / mean.r, 0.6, 1.33) * DETAIL_MEAN
				c = Color(l, l, l)
			else:
				c = Color(clampf(c.r / mean.r, 0.6, 1.33), clampf(c.g / mean.g, 0.6, 1.33), clampf(c.b / mean.b, 0.6, 1.33)) * DETAIL_MEAN
			img.set_pixel(x, y, c.linear_to_srgb())
	img.generate_mipmaps()
	var d := {"small": small, "mean": mean, "tex": ImageTexture.create_from_image(img)}
	_tex_info_cache[key] = d
	return d

func _samp(img: Image, uv: Vector2) -> Color:  # bilinear, repeating
	var n := img.get_width()
	var x := fposmod(uv.x, 1.0) * n - 0.5
	var y := fposmod(uv.y, 1.0) * n - 0.5
	var x0 := floori(x)
	var y0 := floori(y)
	var fx := x - x0
	var fy := y - y0
	var c00 := img.get_pixel(posmod(x0, n), posmod(y0, n))
	var c10 := img.get_pixel(posmod(x0 + 1, n), posmod(y0, n))
	var c01 := img.get_pixel(posmod(x0, n), posmod(y0 + 1, n))
	var c11 := img.get_pixel(posmod(x0 + 1, n), posmod(y0 + 1, n))
	return c00.lerp(c10, fx).lerp(c01.lerp(c11, fx), fy)

func _terrain_mat(sm: ShaderMaterial, cls: String) -> StandardMaterial3D:
	var key := "terrain_%s_%d" % [cls, sm.get_instance_id()]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.resource_name = "terrain_" + cls
	m.albedo_texture = _tex_info(sm.get_shader_parameter(cls + "_d"), cls == "rock")["tex"]
	m.vertex_color_use_as_albedo = true
	var nt: Texture2D = sm.get_shader_parameter(cls + "_n")
	if nt:
		m.normal_enabled = true
		m.normal_texture = nt
	m.roughness = 0.95
	_mat_cache[key] = m
	return m

func _terrain_mesh(src: Mesh, xf: Transform3D, sm: ShaderMaterial) -> ArrayMesh:
	var uvs: float = _sp(sm, "uv_scale", 0.2)
	var g := _tex_info(sm.get_shader_parameter("grass_d"), false)
	var sd := _tex_info(sm.get_shader_parameter("sand_d"), false)
	var rk := _tex_info(sm.get_shader_parameter("rock_d"), true)
	var tint: Color = (_sp(sm, "grass_tint", Color(0.55, 0.90, 0.30)) as Color).srgb_to_linear()
	var tint_dry: Color = (_sp(sm, "grass_tint_dry", Color(0.78, 0.82, 0.38)) as Color).srgb_to_linear()
	var rock_tint: Color = (_sp(sm, "rock_tint", Color(0.5, 0.5, 0.5)) as Color).srgb_to_linear()
	var streaks: float = _sp(sm, "rock_streaks", 0.0)
	var gain: float = _sp(sm, "ortho_gain", 1.5)
	var dirt: float = _sp(sm, "dirt_strength", 1.0)
	var scale := {"grass": uvs * 0.75, "sand": uvs, "rock": uvs * 0.5}
	var out := ArrayMesh.new()
	var groups := {}
	for si in src.get_surface_count():
		var arr := src.surface_get_arrays(si)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var col: PackedColorArray = arr[Mesh.ARRAY_COLOR] if arr[Mesh.ARRAY_COLOR] else PackedColorArray()
		var cu: Variant = arr[Mesh.ARRAY_CUSTOM0]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] else PackedInt32Array()
		# per vertex: world position, normal, rock weight, colour
		var wp := PackedVector3Array()
		var wn := PackedVector3Array()
		var rw := PackedFloat32Array()
		var vc := PackedColorArray()
		wp.resize(v.size())
		wn.resize(v.size())
		rw.resize(v.size())
		vc.resize(v.size())
		for k in v.size():
			var w := xf * v[k]
			var n := (xf.basis * nrm[k]).normalized()
			var c := col[k] if col.size() > 0 else Color(1, 0, 0, 1)
			wp[k] = w
			wn[k] = n
			# grass: macro light/dark, sun-bleached patches, patchy light (terrain.gdshader terms, low frequencies only)
			var mac := _lum(_samp(g["small"], Vector2(w.x, w.z) * uvs * 0.11))
			var patch := _samp(g["small"], Vector2(w.x, w.z) * 0.009).g
			var dry := smoothstep(0.35, 0.65, _samp(g["small"], Vector2(w.x, w.z) * 0.004 + Vector2(0.3, 0.3)).r)
			var grass: Color = g["mean"] * (0.55 + mac * 1.7) * tint.lerp(tint_dry, dry * 0.7) * lerpf(0.8, 1.25, patch)
			var low: Color = (sd["mean"] as Color).lerp(grass, c.r)
			low = low.lerp(sd["mean"] * 0.8, c.b * dirt)
			var rock: Color = rk["mean"] * rock_tint
			if streaks > 0.0:
				rock *= 0.35 + 1.6 * (rk["mean"] as Color).r  # close-up grain, on average (terrain.gdshader)
				var streak := smoothstep(0.28, 0.48, _samp(rk["small"], Vector2((w.x + w.z) * 0.015, w.y * 0.0015)).r)
				var stain := smoothstep(0.40, 0.50, _samp(rk["small"], Vector2(w.x, w.z) * 0.003 + Vector2(w.y * 0.004, 0.0)).g)
				rock *= lerpf(1.0, lerpf(0.4, 1.15, streak), streaks)
				rock = rock.lerp(rock * Color(1.2, 0.95, 0.7), stain * streaks)
			rw[k] = maxf(c.g, smoothstep(0.35, 0.6, 1.0 - n.y) * c.a)
			var alb := low.lerp(rock, rw[k])
			var oa := 0.0
			var oc := Color()
			if cu is PackedByteArray and (cu as PackedByteArray).size() >= v.size() * 4:
				var b: PackedByteArray = cu
				oa = b[k * 4 + 3] / 255.0
				if oa > 0.001:
					oc = Color(b[k * 4] / 255.0, b[k * 4 + 1] / 255.0, b[k * 4 + 2] / 255.0) / oa
			if oa > 0.001:  # real mountains: the photo's colour, the texture only as detail
				var detail := clampf(_lum(alb) / 0.35, 0.6, 1.4)
				alb = alb.lerp(oc * gain * detail, oa)
			alb = alb / DETAIL_MEAN
			vc[k] = Color(minf(alb.r, 1.0), minf(alb.g, 1.0), minf(alb.b, 1.0), 1.0)
		var tri_count := (idx.size() if idx.size() > 0 else v.size()) / 3
		for t in tri_count:
			var ids := [t * 3, t * 3 + 1, t * 3 + 2]
			if idx.size() > 0:
				ids = [idx[t * 3], idx[t * 3 + 1], idx[t * 3 + 2]]
			var r := (rw[ids[0]] + rw[ids[1]] + rw[ids[2]]) / 3.0
			var gr := 1.0
			if col.size() > 0:
				gr = (col[ids[0]].r + col[ids[1]].r + col[ids[2]].r) / 3.0
			var cls := "rock" if r > 0.5 else ("grass" if gr >= 0.5 else "sand")
			if not groups.has(cls):
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				groups[cls] = st
			var stg: SurfaceTool = groups[cls]
			# box projection along the face's dominant axis (no stretching on cliffs)
			var fn := (wp[ids[1]] - wp[ids[0]]).cross(wp[ids[2]] - wp[ids[0]]).abs()
			var sc: float = scale[cls]
			for k in ids:
				var w := wp[k]
				var uv := Vector2(w.x, w.z) if fn.y >= fn.x and fn.y >= fn.z else (Vector2(w.z, w.y) if fn.x >= fn.z else Vector2(w.x, w.y))
				stg.set_normal(wn[k])
				stg.set_color(vc[k])
				stg.set_uv(uv * sc)
				stg.add_vertex(w)
	for cls in groups.keys():
		var st: SurfaceTool = groups[cls]
		st.generate_tangents()
		st.commit(out)
		out.surface_set_material(out.get_surface_count() - 1, _terrain_mat(sm, cls))
	return out

# glTF caps baseColorFactor at 1, but Godot materials brighten dim scans with albedo_color > 1 (stone x1.35, deck x1.7):
# bake that gain into a copy of the albedo texture so Unity / Blender see the same brightness
var _safe_cache := {}
func _gltf_safe(m: Material) -> Material:
	var sm := m as StandardMaterial3D
	if sm == null:
		return m
	var c := sm.albedo_color
	var k := maxf(c.r, maxf(c.g, c.b))
	if k <= 1.001:
		return m
	if _safe_cache.has(sm):
		return _safe_cache[sm]
	var out := sm.duplicate() as StandardMaterial3D
	out.albedo_color = Color(c.r / k, c.g / k, c.b / k, c.a)
	if sm.albedo_texture:
		var img := sm.albedo_texture.get_image()
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		img.adjust_bcs(k, 1.0, 1.0)
		img.generate_mipmaps()
		out.albedo_texture = ImageTexture.create_from_image(img)
	_safe_cache[sm] = out
	return out

func _gltf_safe_mesh(mesh: Mesh) -> void:
	for si in mesh.get_surface_count():
		var mat := mesh.surface_get_material(si)
		if mat is StandardMaterial3D:
			mesh.surface_set_material(si, _gltf_safe(mat))

func _write_route(path: String) -> void:
	var d := {"version": 1, "step": 1.0, "length": _route.length, "s": [], "x": [], "y": [], "z": [], "half_left": [], "half_right": [], "water_y": [], "backdrop_yaw": []}
	for i in int(floor(_route.length)) + 1:
		var p := _route.pos_at(float(i))
		d["s"].append(i)
		d["x"].append(snappedf(p.x, 0.001))
		d["y"].append(snappedf(p.y, 0.001))
		d["z"].append(snappedf(p.z, 0.001))
		d["half_left"].append(snappedf(_route.half_left(float(i)), 0.01))
		d["half_right"].append(snappedf(_route.half_right(float(i)), 0.01))
		d["water_y"].append(snappedf(_route.water_level(float(i)), 0.01))  # lake surface (varies per scene section)
		d["backdrop_yaw"].append(snappedf(_route.backdrop_yaw(float(i)), 0.0001))  # rad about +Y: the backdrop turns with the route
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()
