extends SceneTree
# A scene's route centre line + section spans as JSON, without building terrain or props (used by tools/plot_route.py):
#   godot --headless --path . --script tools/dump_route.gd -- res://scenes/MainScene_garda.tscn <course|""> out.json

func _find(n: Node, script_name: String) -> Node:
	var sc: Script = n.get_script()
	if sc != null and sc.resource_path.ends_with(script_name):
		return n
	for c in n.get_children():
		var f := _find(c, script_name)
		if f != null:
			return f
	return null

func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var root: Node = (load(a[0]) as PackedScene).instantiate()
	var r = _find(root, "route.gd")
	if a[1] != "":
		r.course = a[1]
	var setup := _find(root, "course_setup.gd")
	if setup != null:  # the course template's settings, as CourseSetup applies them before Route builds
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(setup.courses_file))
		var cfg: Dictionary = data["templates"][data["courses"][r.course]["template"]]
		for k: String in cfg.get(String(r.name), {}):
			r.set(k, cfg[String(r.name)][k])
	r.setup_course()
	r._load_sections()
	r._build_centreline()
	var pts := []
	for i in range(0, r._n, 5):  # every 10 m
		pts.append([snappedf(r._pos[i].x, 0.1), snappedf(r._pos[i].z, 0.1)])
	var secs := []
	for k in r._secs.size():
		var s0: float = float(r._secs[k][0]) / r._video_km * r.length
		var s1: float = float(r._secs[k + 1][0]) / r._video_km * r.length if k + 1 < r._secs.size() else r.length
		var t: Dictionary = r.section_at(0.5 * (s0 + s1))
		secs.append({"id": "S%02d" % (k + 1), "s0": s0, "s1": s1, "name": t["name"], "turn": t.get("turn")})
	var out := {"scene": a[0], "course": r.course, "length": r.length, "step_m": 10.0, "sea_right": r.sea_right,
		"points": pts, "sections": secs, "landmarks": r.landmarks() if not r._secs.is_empty() else []}
	var f := FileAccess.open(a[2], FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	root.free()
	quit()
