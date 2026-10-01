extends SceneTree
# Convert a Microsoft Rocketbox avatar FBX + a Rocketbox run-clip FBX into a web-ready GLB with an in-place "run" clip.
# usage: godot --headless --script tools/rocketbox_to_glb.gd -- <avatar.fbx> <run.fbx> <texture prefix e.g. m026> <out.glb>
# Textures (<prefix>_{body,head}_{color,normal}.jpg, <prefix>_opacity_color.png) must sit next to the avatar FBX.
# Prints SPEED = ground speed (m/s) of the removed root motion; store it in player_web/assets/rocketbox/speeds.json.
# usage: -- <avatar.fbx> <run.fbx> <tex_prefix e.g. m021> <out.glb>
func load_fbx(p: String) -> Node:
	var doc := FBXDocument.new(); var st := FBXState.new()
	if doc.append_from_file(p, st) != OK: push_error("load " + p)
	return doc.generate_scene(st)
func tex(p: String) -> Texture2D:
	var img := Image.load_from_file(p)
	return ImageTexture.create_from_image(img)
func _initialize():
	var a := OS.get_cmdline_user_args()
	var dir := a[0].get_base_dir()
	var av := load_fbx(a[0]); var run := load_fbx(a[1]); var pre := a[2]
	var skel: Skeleton3D = av.find_children("*", "Skeleton3D")[0]
	var imi: ImporterMeshInstance3D = av.find_children("*", "ImporterMeshInstance3D")[0]
	var mi := MeshInstance3D.new()
	mi.name = "Body"
	mi.mesh = imi.mesh.get_mesh()
	mi.skin = imi.skin
	mi.transform = imi.transform
	var mesh: ArrayMesh = mi.mesh
	for s in mesh.get_surface_count():
		var old = mesh.surface_get_material(s)
		var nm: String = (old.resource_name if old else "").to_lower()
		var m := StandardMaterial3D.new()
		m.resource_name = nm
		var part := "head" if nm.contains("head") else "body"
		if nm.contains("opacity") or nm.contains("hair") or nm.contains("lash") or nm.contains("transp"):
			if FileAccess.file_exists("%s/%s_opacity_color.png" % [dir, pre]):
				m.albedo_texture = tex("%s/%s_opacity_color.png" % [dir, pre])
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				m.alpha_scissor_threshold = 0.5
				m.cull_mode = BaseMaterial3D.CULL_DISABLED
				part = ""
		if part != "":
			m.albedo_texture = tex("%s/%s_%s_color.jpg" % [dir, pre, part])
			m.normal_enabled = true
			m.normal_texture = tex("%s/%s_%s_normal.jpg" % [dir, pre, part])
		m.roughness = 0.75
		mesh.surface_set_material(s, m)
		print("surface ", s, " mat '", nm, "' -> ", part if part != "" else "opacity")
	imi.get_parent().add_child(mi)
	mi.owner = av
	mi.skeleton = mi.get_path_to(skel)
	imi.get_parent().remove_child(imi)
	imi.free()
	# animation
	var rap: AnimationPlayer = run.find_children("*", "AnimationPlayer")[0]
	var anim: Animation = rap.get_animation(rap.get_animation_list()[0]).duplicate()
	anim.loop_mode = Animation.LOOP_LINEAR
	var speed := 0.0
	for t in range(anim.get_track_count() - 1, -1, -1):
		var path := str(anim.track_get_path(t))
		if not path.begins_with("Skeleton3D:"):
			anim.remove_track(t)
			continue
		if path == "Skeleton3D:Bip01" and anim.track_get_type(t) == Animation.TYPE_POSITION_3D:
			# in place: remove the linear forward drift of the root (keep bounce / sway)
			var p0: Vector3 = anim.track_get_key_value(t, 0)
			var p1: Vector3 = anim.track_get_key_value(t, anim.track_get_key_count(t) - 1)
			var t1 := anim.track_get_key_time(t, anim.track_get_key_count(t) - 1)
			var drift := (p1 - p0) / t1
			drift.y = 0.0
			speed = drift.length()
			for k in anim.track_get_key_count(t):
				var v: Vector3 = anim.track_get_key_value(t, k)
				anim.track_set_key_value(t, k, v - drift * anim.track_get_key_time(t, k))
	var lib := AnimationLibrary.new(); lib.add_animation("run", anim)
	var ap: AnimationPlayer = av.find_children("*", "AnimationPlayer")[0]
	for l in ap.get_animation_library_list(): ap.remove_animation_library(l)
	ap.add_animation_library("", lib)
	# report root motion + size
	for t in anim.get_track_count():
		if str(anim.track_get_path(t)) == "Skeleton3D:Bip01" and anim.track_get_type(t) == Animation.TYPE_POSITION_3D:
			print("Bip01 pos t0 ", anim.position_track_interpolate(t, 0.0), " tEnd ", anim.position_track_interpolate(t, anim.length))
	var aabb := mi.get_aabb()
	print("mesh aabb ", aabb, " skel scale ", skel.global_transform.basis.get_scale(), " root xf ", av.transform)
	for n in av.find_children("*", "", true, false): n.owner = av
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	var err := doc.append_from_scene(av, st)
	err = doc.write_to_filesystem(st, a[3])
	print("export ", a[3], " err ", err)
	print("SPEED ", speed, " LEN ", anim.length)
	quit()
