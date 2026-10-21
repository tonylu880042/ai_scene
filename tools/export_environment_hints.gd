extends SceneTree
# Scene facts for the distant environment + atmosphere stage (tools/environment.py): what a Godot scene shows beyond
# the near route and how its sky / sun / fog are set, as plain values (no shader code). Writes
# <package>/environment/hints.json; tools/environment.py turns it into the canonical environment.json.
#
#   godot --headless --path . --script tools/export_environment_hints.gd -- --scene=res://scenes/MainScene_weissensee.tscn \
#         --course=rolling_hills --package=export/packages/weissensee_rolling_hills

var A := {}

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			A[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_run.call_deferred()

func _c(c: Color) -> Array:  # scene colours as authored (sRGB); environment.py converts to linear
	return [snappedf(c.r, 0.0001), snappedf(c.g, 0.0001), snappedf(c.b, 0.0001)]

func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(p)

func _run() -> void:
	var scene_path: String = A.get("scene", "res://scenes/MainScene_weissensee.tscn")
	var scene: Node = (load(scene_path) as PackedScene).instantiate()
	for n in ["HUD", "TrackExporter", "RenderQuality"]:
		var node := scene.get_node_or_null(n)
		if node:
			node.free()
	root.add_child(scene)
	for n in ["Foliage", "Player"]:
		var node := scene.get_node_or_null(n)
		if node:
			node.process_mode = Node.PROCESS_MODE_DISABLED
	await process_frame
	await process_frame  # CourseSetup has placed the sun / sky for the start
	var route: Route = scene.get_node("Path3D")
	var setup := scene.get_node_or_null("CourseSetup")
	var sun := scene.get_node("Sun") as DirectionalLight3D
	var env := (scene.get_node("WorldEnvironment") as WorldEnvironment).environment
	var to_sun := sun.global_transform.basis.z
	var h := {"scene": scene_path, "course": route.course}
	h["sun"] = {"direction_to_sun": [to_sun.x, to_sun.y, to_sun.z], "color": _c(sun.light_color), "energy": sun.light_energy,
		"mode": "relative_to_route", "left_of_travel_deg": setup.sun_left_deg.y if setup else 45.0,
		"elevation_from_hdri": bool(setup.hdri_sky) if setup else false}
	var sky_mat := env.sky.sky_material as ShaderMaterial if env.sky else null
	if sky_mat and sky_mat.get_shader_parameter("pano"):
		var pano: Texture2D = sky_mat.get_shader_parameter("pano")
		h["sky"] = {"hdri": _abs(pano.resource_path), "sun_u": setup.hdri_sun_u if setup else 0.5,
			"sun_elevation_deg": setup.hdri_sun_elev if setup else 45.0, "energy": float(sky_mat.get_shader_parameter("energy") if sky_mat.get_shader_parameter("energy") != null else 1.0)}
	h["ambient"] = {"source": "sky", "energy": env.ambient_light_energy}
	h["fog"] = {"density": env.fog_density, "color": _c(env.fog_light_color), "aerial_perspective": env.fog_aerial_perspective,
		"sun_scatter": env.fog_sun_scatter, "sky_affect": env.fog_sky_affect, "mist": [setup._fog.x, setup._fog.y] if setup and setup.mist_enabled else null}
	h["grading"] = {"tonemap": ["linear", "reinhard", "filmic", "aces", "agx"][env.tonemap_mode] if env.tonemap_mode < 5 else "other",
		"exposure": env.tonemap_exposure, "saturation": env.adjustment_saturation if env.adjustment_enabled else 1.0,
		"contrast": env.adjustment_contrast if env.adjustment_enabled else 1.0, "glow": env.glow_enabled}
	h["time_of_day"] = {"phase": [setup._tod.x, setup._tod.y] if setup else [0.4, 0.6]}
	var rt := scene.get_node_or_null("RealBackdrop/RealTerrain")
	if rt:
		var fb := scene.get_node("RealBackdrop")
		h["real_terrain"] = {"name": rt.terrain_name, "dir": _abs("res://assets/terrain/"), "rotation_deg": rt.rotation_deg,
			"height_offset": rt.height_offset, "anchor": [rt.anchor.x, rt.anchor.y], "hole_radius": rt.hole_radius,
			"hole_depth": rt.hole_depth, "sink_west_of": rt.sink_west_of if not is_inf(rt.sink_west_of) else null,
			"sink_axis_deg": rt.sink_axis_deg, "follow": {"base_y": fb.base_y, "route_water": not fb.route_water.is_empty(), "route_yaw": fb.route_yaw}}
	var waters := []
	for nm in ["LakeFar", "Ocean", "Sea"]:
		var w := scene.get_node_or_null(nm) as MeshInstance3D
		if w and w.mesh is PlaneMesh:
			var m := w.get_surface_override_material(0) as ShaderMaterial
			var wd := {"name": nm, "size_m": [(w.mesh as PlaneMesh).size.x, (w.mesh as PlaneMesh).size.y], "base_y": float(w.get("base_y")),
				"follows_route_water": not (w.get("route_water") as NodePath).is_empty()}
			if m:
				for k in ["deep_color", "shallow_color"]:
					if m.get_shader_parameter(k) != null:
						wd[k] = _c(m.get_shader_parameter(k))
				if m.get_shader_parameter("water_roughness") != null:
					wd["roughness"] = m.get_shader_parameter("water_roughness")
			waters.append(wd)
	h["water"] = waters
	var off := []
	var yaw := []
	var s := 0.0
	while true:  # follow-runner anchoring along the route: water level below the road, backdrop turn
		off.append([snappedf(s, 0.01), snappedf(route.water_level(s) - route.pos_at(s).y, 0.001)])
		yaw.append([snappedf(s, 0.01), snappedf(route.backdrop_yaw(s), 0.00001)])
		if s >= route.length:
			break
		s = minf(s + 25.0, route.length)
	h["water_offset_m"] = off
	h["godot_backdrop_yaw_rad"] = yaw
	var clouds := []
	for n in scene.find_children("*", "MeshInstance3D", true, false):
		var mat := (n as MeshInstance3D).material_override as ShaderMaterial
		if mat and mat.shader and mat.shader.resource_path.contains("cloud"):
			clouds.append({"node": String(n.name), "shader": mat.shader.resource_path.get_file(), "y_below_route_m": snappedf(route.pos_at(0.0).y - (n as MeshInstance3D).global_position.y, 0.1)})
	h["cloud_volumes"] = clouds
	var pkg := _abs("res://").path_join(A.get("package", ""))
	DirAccess.make_dir_recursive_absolute(pkg.path_join("environment"))
	var f := FileAccess.open(pkg.path_join("environment/hints.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(h, " "))
	f.close()
	print("environment hints -> ", pkg.path_join("environment/hints.json"))
	scene.free()
	quit()
