extends SceneTree
# Near-route semantics of a sections-file scene (weissensee, garda, winter): what route.gd / FoliageSpawner /
# Boardwalk / Buildings put beside the route, as route-relative zones (docs/SEMANTICS.md). Needs the package's
# route/route.json (tools/export_route.gd) for route_id; validates with tools/semantics.py.
#
#   godot --headless --path . --script tools/export_semantics.gd -- --scene=res://scenes/MainScene_weissensee.tscn \
#         --course=rolling_hills --package=export/packages/weissensee_rolling_hills [--piece-m=100]
#
# Offsets come from the generators' own rules (tree bands, fence posts at the path edge + 5 cm, chalets 10-30 m
# inland, reeds around the water line), widths and water edges from the built Route. Lateral offsets are signed in
# travel direction (+ left); route.gd's u is seaward-positive, mirrored when sea_right.

const EXTENT := 150.0
const BARRIERS := {"boardfence": "fence", "woodrail": "fence", "lattice": "fence", "efence": "fence", "rail": "fence",
	"blackrail": "fence", "parapet_fence": "fence", "chainlink": "fence", "cable": "guardrail", "lograil": "guardrail",
	"guardrail": "guardrail", "lowwall": "wall", "parapet": "wall", "parapet_lamps": "wall", "wall": "wall", "cliffwall": "wall"}

var A := {}
var route: Route
var zones := []
var sgn := 1.0  # route.gd u (seaward +) -> travel lateral (left +)

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			A[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_run.call_deferred()

# zone from route.gd lateral offsets ua..ub (seaward +); side from where it lies, "both" if it spans the centre line
func _zone(type: String, a: float, b: float, ua: float, ub: float, conf: float, src: Dictionary, attrs := {}, vert: Variant = "ground") -> void:
	var l0 := minf(ua * sgn, ub * sgn)
	var l1 := maxf(ua * sgn, ub * sgn)
	l0 = clampf(l0, -EXTENT, EXTENT)
	l1 = clampf(l1, -EXTENT, EXTENT)
	if l1 - l0 < 0.05 or b - a < 0.5:
		return
	var side := "both" if l0 < -0.001 and l1 > 0.001 else ("left" if l0 >= -0.001 else "right")
	if typeof(vert) == TYPE_STRING:
		vert = _vert(a, b, ua, ub)
	zones.append({"semantic_type": type, "side": side, "from_s": snappedf(a, 0.01), "to_s": snappedf(b, 0.01),
		"lateral_offset_m": [snappedf(l0, 0.01), snappedf(l1, 0.01)], "vertical_offset_m": vert,
		"confidence": conf, "attributes": attrs, "source": src})

# terrain height relative to the road at the same s (as built), over the zone
func _vert(a: float, b: float, ua: float, ub: float) -> Array:
	var lo := INF
	var hi := -INF
	for i in 5:
		var s := lerpf(a, b, i / 4.0)
		for j in 5:
			var d := route.ground_y(s, lerpf(ua, ub, j / 4.0)) - route.pos_at(s).y
			lo = minf(lo, d)
			hi = maxf(hi, d)
	return [snappedf(lo, 0.1), snappedf(hi, 0.1)]

func _extreme(a: float, b: float, f: Callable, use_max: bool) -> float:
	var v := -INF if use_max else INF
	var ss := [a, b]
	for k in range(floori(a), ceili(b) + 1):  # every route.json sample the zone covers, and its ends
		ss.append(clampf(k, a, b))
	for s: float in ss:
		v = maxf(v, f.call(s)) if use_max else minf(v, f.call(s))
	return v

func _piece(a: float, b: float, sec: Dictionary, src: Dictionary, has_water: bool, foliage: Node, buildings: Node) -> void:
	var hl := _extreme(a, b, route.half_left, true)    # seaward half-width
	var hr := _extreme(a, b, route.half_right, true)   # inland, incl. any roadside car lane
	var pr := _extreme(a, b, route.path_right, true)
	var we := _extreme(a, b, route.water_edge_u, false) if has_water else EXTENT
	var gap := _extreme(a, b, func(s: float) -> float: return route.pos_at(s).y - route.water_level(s), true)
	var name: String = sec.get("name", "")
	# route surface
	var tex: String = sec.get("surface", "asphalt_02")
	var st := "road" if tex.contains("asphalt") else ("sidewalk" if tex.contains("concrete") else "trail")
	_zone(st, a, b, -pr, hl, 0.9, src, {"section": name, "surface_texture": tex}, [0.0, 0.0])
	if hr - pr > 0.05:
		_zone("road", a, b, -hr, -pr, 0.9, src, {"kind": "roadside lane"}, [0.0, 0.0])
	# water and ground cover
	if has_water and we < EXTENT:
		var wv := [snappedf(-gap, 0.1), snappedf(-_extreme(a, b, func(s: float) -> float: return route.pos_at(s).y - route.water_level(s), false), 0.1)]
		_zone("water", a, b, we, EXTENT, 0.9, src, {"kind": "lake", "edge_m": [snappedf(we, 0.1), snappedf(_extreme(a, b, route.water_edge_u, true), 0.1)]}, wv)
	var grassy := float(sec.get("grass", 0.5)) >= 0.25
	if grassy and we > hl + 0.3:
		_zone("grass", a, b, hl, we, 0.6, src, {"cover": float(sec.get("grass", 0.5))})
	var open := name in ["plaza", "parking"]
	if open:
		_zone("open_space", a, b, -(hr + 25.0), -hr, 0.7, src, {"kind": name})
	if grassy:
		_zone("grass", a, b, -EXTENT, -(hr + (25.0 if open else 0.0)), 0.6, src, {"cover": float(sec.get("grass", 0.5))})
	# trees (FoliageSpawner forest_mix: inland band to `depth`, wooded bank on the lake side, lake_band strip)
	var trees := float(sec.get("trees", 1.0))
	var depth := float(sec.get("depth", foliage.max_dist))
	var per_chunk := float(foliage.trees_per_chunk) * trees
	var sp := {"beech": float(sec.get("beech", 0.5)), "spruce": float(sec.get("spruce", 0.4)), "larch": float(sec.get("larch", 0.1))}
	var fa := {"density": "dense" if trees >= 1.5 else ("medium" if trees >= 0.6 else "sparse"), "species": sp,
		"autumn_share": float(sec.get("yellow", 0.5)),
		"stems_per_ha": snappedf(0.5 * per_chunk / (foliage.chunk_length * maxf(depth - hr, 1.0)) * 10000.0, 1.0),
		"floor": "leaf_litter" if float(sec.get("litter", 0.0)) > 0.3 else "grass"}
	var bank := we - 0.8 - hl - 0.6
	var tree_type := "forest" if trees >= 0.3 else "vegetation_zone"
	if trees < 0.3:
		fa = {"kind": "scattered_trees", "species": sp, "stems_per_ha": fa["stems_per_ha"]}
	if trees > 0.0:
		_zone(tree_type, a, b, -depth, -(hr + 0.6), 0.7, src, fa)
		if bank > 1.0:
			_zone(tree_type, a, b, hl + 0.6, minf(depth, we - 0.8), 0.7, src, fa)
	if int(sec.get("lake_band", 0)) > 0 and we - 1.0 > hl + 10.0:
		_zone("forest", a, b, hl + 10.0, we - 1.0, 0.6, src, {"density": "medium", "kind": "lake_band", "species": sp})
	if int(sec.get("hazel", 0)) > 0:
		var ha := {"kind": "shrubs", "per_100m": snappedf(float(sec.get("hazel", 0)) / foliage.chunk_length * 100.0, 0.1)}
		_zone("vegetation_zone", a, b, -(hr + 9.0), -(hr + 2.0), 0.6, src, ha)
		_zone("vegetation_zone", a, b, hl + 2.0, minf(hl + 9.0, we - 0.8), 0.6, src, ha)
	if has_water and int(sec.get("reeds", 0)) > 0 and gap < 4.0:
		_zone("vegetation_zone", a, b, maxf(we - 2.0, hl + 0.1), we + 4.0, 0.6, src, {"kind": "reeds", "per_100m": snappedf(float(sec.get("reeds", 0)) / foliage.chunk_length * 100.0, 0.1)})
	# landform
	var rise := float(sec.get("slope", 1.0)) * route.inland_slope
	if rise >= 0.15:
		_zone("slope", a, b, -EXTENT, -hr, 0.8, src, {"direction": "up", "rise_per_m": snappedf(rise, 0.01)})
	if has_water and gap >= 1.5 and we - hl > 0.5:
		_zone("slope", a, b, hl, we, 0.8, src, {"direction": "down", "drop_m": snappedf(gap, 0.1)})
	if float(sec.get("cliff", 0.0)) > 0.5:
		var cf := float(sec.get("cliff_from", 6.0))
		_zone("cliff", a, b, -(hr + cf + 14.0), -(hr + cf), 0.8, src, {"height_m": float(sec["cliff"])}, [0.0, float(sec["cliff"])])
	# edge barriers (Boardwalk: posts 5 cm outside the path edge)
	for e in [[String(sec.get("lake", "none")), hl, 1.0], [String(sec.get("inland", "none")), hr, -1.0]]:
		if BARRIERS.has(e[0]):
			var t: String = BARRIERS[e[0]]
			var u0: float = e[1] + 0.05
			_zone(t, a, b, e[2] * u0, e[2] * (u0 + (0.6 if t == "wall" else 0.3)), 0.8, src, {"kind": e[0]})
	# buildings (Buildings.gd chalet: chalets 10-30 m inland, barns 15-60 m, footprints ~13 m deep)
	if buildings and (buildings.get("chalet") or buildings.get("nordic")):
		if sec.get("houses", false):
			_zone("building_zone", a, b, -(hr + 37.0), -(hr + 3.0), 0.7, src, {"kind": "chalets"})
		elif sec.get("barns", false):
			_zone("building_zone", a, b, -(hr + 63.0), -(hr + 12.0), 0.6, src, {"kind": "barns"})

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
	route = scene.get_node("Path3D")
	sgn = -1.0 if route.sea_right else 1.0
	var pkg := ProjectSettings.globalize_path("res://").path_join(A.get("package", ""))
	var rj: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(pkg.path_join("route/route.json")))
	if route._secs.is_empty():
		push_error("export_semantics: scene has no sections file")
		quit(1)
		return
	var has_water := scene.get_node_or_null("Lake") != null or scene.get_node_or_null("Ocean") != null
	var foliage := scene.get_node("Foliage")
	var piece_m := float(A.get("piece-m", "100"))
	var sections_file := route.sections_file.replace("res://", "")
	for k in route._secs.size():
		var e: Array = route._secs[k]
		var s0: float = float(e[0]) / route._video_km * route.length
		var s1: float = float(route._secs[k + 1][0]) / route._video_km * route.length if k + 1 < route._secs.size() else route.length
		var sec := route.section_at(0.5 * (s0 + s1))
		var src := {"kind": "scene_generator", "ref": "%s S%02d %s" % [sections_file, k + 1, e[1]], "estimated": true}
		if e.size() > 3 and e[3] is String:
			src["note"] = e[3]
		var n := maxi(ceili((s1 - s0) / piece_m), 1)
		for p in n:
			_piece(lerpf(s0, s1, float(p) / n), lerpf(s0, s1, float(p + 1) / n), sec, src, has_water, foliage, scene.get_node_or_null("Buildings"))
	for lm in route.landmarks():  # footbridges carry the route: bridge zones over the path
		if lm[1] == "footbridge":
			var s: float = lm[0]
			var a := maxf(s - 5.0, 0.0)
			var b := minf(s + 5.0, route.length)
			var w := maxf(_extreme(a, b, route.half_left, true), _extreme(a, b, route.half_right, true)) + 0.15
			_zone("bridge", a, b, -w, w, 0.8,
				{"kind": "scene_generator", "ref": "%s landmarks footbridge (Boardwalk.gd, 10 m deck)" % sections_file, "estimated": true}, {"kind": "footbridge"}, [-1.0, 0.0])
	zones.sort_custom(func(x, y): return x["from_s"] < y["from_s"] or (x["from_s"] == y["from_s"] and x["lateral_offset_m"][0] < y["lateral_offset_m"][0]))
	for i in zones.size():
		zones[i] = {"id": "z%04d" % (i + 1)}.merged(zones[i])
	var out := {"version": "0.1", "route_id": rj["route_id"], "extent_m": EXTENT,
		"source": {"producer": "tools/export_semantics.gd", "scene": scene_path, "course": route.course,
			"note": "zones follow the scene generators' rules per section piece (<= %d m); vertical offsets are terrain relative to the road as built" % int(piece_m)},
		"zones": zones}
	var path := pkg.path_join("semantics/semantics.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, " "))
	f.close()
	var log := []
	var code := OS.execute("/usr/bin/env", ["python3", ProjectSettings.globalize_path("res://tools/semantics.py"), "validate", pkg], log, true)
	print("".join(log).strip_edges())
	scene.free()
	quit(code)
