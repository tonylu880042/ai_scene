extends SceneTree
# Self-check for route.gd's sections "turn" key (+ left / - right, lists = S-bends), no scene needed:
#   godot --headless --path . --script tools/check_route_turns.gd

func _heading_change(r, s0: float, s1: float) -> float:  # degrees, + left of travel
	var i0 := int(s0 / 2.0)
	var i1 := int(s1 / 2.0)
	var f0: Vector3 = (r._pos[i0 + 1] - r._pos[i0]).normalized()
	var f1: Vector3 = (r._pos[i1] - r._pos[i1 - 1]).normalized()
	return rad_to_deg(atan2(f1.dot(r._left[i0]), f1.dot(f0)))

func _route(sections: Array):
	var path := "user://check_route_turns.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"video_km": 1.0, "types": {"a": {}}, "sections": sections}))
	f.close()
	var r = load("res://scripts/route.gd").new()
	r.sections_file = path
	r._segs = [[100.0, 0.0, "flat"]]
	r.speed = 1.0
	r.length = 1000.0
	r._n = 501
	r._load_sections()
	r._build_centreline()
	return r

func _init() -> void:
	var r = _route([[0.0, "a", {"turn": 90}], [0.5, "a", {"turn": [-45, 45]}]])
	var a := _heading_change(r, 0.0, 500.0)
	var b := _heading_change(r, 500.0, 750.0)
	var c := _heading_change(r, 500.0, 1000.0)
	print("left 90: %.1f  right 45: %.1f  S-bend net: %.1f" % [a, b, c])
	assert(absf(a - 90.0) < 3.0, "first section should turn 90 deg left")
	assert(absf(b + 45.0) < 3.0, "first half of the S-bend should turn 45 deg right")
	assert(absf(c) < 3.0, "S-bend should end on its starting heading")
	assert(_route([[0.0, "a"]])._turn_rates().is_empty(), "no turn key -> the old sine bends")
	print("check_route_turns: OK")
	quit()
