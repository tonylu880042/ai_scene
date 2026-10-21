extends SceneTree
# Route (Path3D, scripts/route.gd) -> canonical route.json (docs/ROUTE_SCHEMA.md), then a round trip through RouteData.
#
#   godot --headless --path . --script tools/export_route.gd -- --scene=res://scenes/MainScene_weissensee.tscn \
#         --course=rolling_hills --out=export/packages/weissensee_rolling_hills/route/route.json \
#         [--route-id=<id>] [--step=1] [--checkpoint-every-m=1000]
#
# Writes the primary facts (s, x, z, physical elevation, widths, surface, markers) and lets tools/route_model.py
# finalize derive grade / heading / curvature and validate. Elevation is Route.elevation_at(): the program's grade,
# not the rendered road (pos_at().y is x grade_scale + micro_relief; recorded under "visual" only).

var A := {}

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			A[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_run.call_deferred()

# section / trail texture -> surface_type (schemas/route.schema.json)
const SURFACES := [["asphalt", "asphalt"], ["concrete", "concrete"], ["cobble", "cobblestone"], ["gravel", "gravel"],
	["plank", "boardwalk"], ["wood", "boardwalk"], ["snow", "snow"], ["ice", "ice"], ["mud", "dirt"], ["trail", "dirt"],
	["dirt", "dirt"], ["sand", "sand"], ["grass", "grass"]]

func _surface(route: Route, s: float) -> String:
	var tex := "asphalt_02"
	if not route._secs.is_empty():
		tex = route.section_at(s).get("surface", tex)
	elif route.alpine_trail:
		tex = route.trail_texture
	elif route.deck:
		tex = route.deck_texture
	for m in SURFACES:
		if tex.contains(m[0]):
			return m[1]
	return "unknown"

func _run() -> void:
	var scene: Node = (load(A.get("scene", "res://scenes/MainScene_weissensee.tscn")) as PackedScene).instantiate()
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
	var route: Route = scene.get_node("Path3D")
	var step := float(A.get("step", "1"))
	var smp := {"s": [], "x": [], "z": [], "elevation_m": [], "width_left_m": [], "width_right_m": [], "surface_type": []}
	var ss := []
	var k := 0
	while k * step < route.length - 1e-6:
		ss.append(k * step)
		k += 1
	ss.append(route.length)
	for s: float in ss:
		var p := route.pos_at(s)
		smp["s"].append(s)
		smp["x"].append(p.x)
		smp["z"].append(p.z)
		smp["elevation_m"].append(route.start_height + route.elevation_at(s))
		# route.gd's "left" is the seaward side, which is travel-right when sea_right (garda)
		smp["width_left_m"].append(route.half_right(s) if route.sea_right else route.half_left(s))
		smp["width_right_m"].append(route.half_left(s) if route.sea_right else route.half_right(s))
		smp["surface_type"].append(_surface(route, s))
	var gates := scene.get_node_or_null("Gates")
	var start_s: float = float(gates.start_gap) if gates else 0.0
	var finish_s: float = route.length - float(gates.finish_gap) if gates else route.length
	var cps := []
	var every := float(A.get("checkpoint-every-m", "1000"))
	var c := every
	while every > 0.0 and c < finish_s - 1.0:
		if c > start_s + 1.0:
			cps.append({"id": "cp%02d" % (cps.size() + 1), "s": c, "name": "%.1f km" % (c / 1000.0)})
		c += every
	var secs := []
	for i in route._secs.size():
		var s0: float = float(route._secs[i][0]) / route._video_km * route.length
		var s1: float = float(route._secs[i + 1][0]) / route._video_km * route.length if i + 1 < route._secs.size() else route.length
		secs.append({"id": "S%02d" % (i + 1), "from_s": s0, "to_s": s1, "type": String(route._secs[i][1])})
	var scene_path: String = A.get("scene", "res://scenes/MainScene_weissensee.tscn")
	var raw := {
		"route_id": A.get("route-id", scene_path.get_file().get_basename().to_lower() + "_" + route.course),
		"sample_interval_m": step,
		"closed": false,
		"start": {"id": "start", "s": start_s, "name": "START gate"},
		"finish": {"id": "finish", "s": finish_s, "name": "FINISH gate"},
		"checkpoints": cps,
		"visual": {"vertical_exaggeration": route.grade_scale, "relief_amplitude_m": route.micro_relief if route.alpine_trail else 0.0,
			"note": "the Godot scene draws the road at start_height + vertical_exaggeration * (elevation_m - start_height) + relief; not physical"},
		"source": {"producer": "tools/export_route.gd (scripts/route.gd)", "scene": scene_path, "course": route.course,
			"pace_min_per_km": route.pace_min_per_km, "grade": "treadmill program incline, eased over ~20 m (data/programs.json)",
			"widths": "Route.half_left / half_right (paved edge incl. any roadside lane)"},
		"samples": smp,
	}
	if not secs.is_empty():
		raw["sections"] = secs
	var out := ProjectSettings.globalize_path("res://").path_join(A.get("out", "export/packages/%s/route/route.json" % raw["route_id"]))
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(raw))
	f.close()
	var log := []
	var code := OS.execute("/usr/bin/env", ["python3", ProjectSettings.globalize_path("res://tools/route_model.py"), "finalize", out], log, true)
	print("".join(log).strip_edges())
	if code == 0:
		code = _round_trip(route, RouteData.load_file(out))
	scene.free()
	quit(code)

# consumer check: route.json read back through RouteData agrees with the live Route
func _round_trip(route: Route, rd: RouteData) -> int:
	var worst := 0.0
	var s := 0.0
	while s <= route.length:
		var a := route.pos_at(s)
		var b := rd.position_at(s)
		worst = maxf(worst, maxf(Vector2(a.x - b.x, a.z - b.z).length(), absf(route.start_height + route.elevation_at(s) - float(rd.sample(s)["elevation_m"]))))
		s += 7.3
	var dl := absf(rd.make_curve().get_baked_length() - route.curve.get_baked_length())
	var ok := worst < 0.005 and dl < 0.005 * route.length
	print("round trip Route -> route.json -> RouteData: max position/elevation error %.4f m, curve length diff %.3f m -> %s" % [worst, dl, "OK" if ok else "FAIL"])
	return 0 if ok else 1
