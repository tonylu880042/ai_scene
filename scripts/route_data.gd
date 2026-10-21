class_name RouteData
extends RefCounted
# The canonical route.json (docs/ROUTE_SCHEMA.md) read into Godot: one consumer of the engine-independent route.
# Every field is linearly interpolated in s (horizontal metres from the first sample); heading by the shortest angle.

const NUMERIC := ["x", "y", "z", "elevation_m", "grade_percent", "heading_deg", "curvature", "width_left_m", "width_right_m"]

var data: Dictionary
var length := 0.0
var _s := PackedFloat64Array()
var _cols := {}  # field -> PackedFloat64Array

static func load_file(path: String) -> RouteData:
	var r := RouteData.new()
	r.data = JSON.parse_string(FileAccess.get_file_as_string(path))
	r.length = float(r.data["total_length_m"])
	r._s = PackedFloat64Array(r.data["samples"]["s"])
	for k in NUMERIC:
		r._cols[k] = PackedFloat64Array(r.data["samples"][k])
	return r

func sample(s: float) -> Dictionary:
	s = clampf(s, _s[0], _s[-1])
	var i := clampi(_s.bsearch(s, false) - 1, 0, _s.size() - 2)
	var t := (s - _s[i]) / (_s[i + 1] - _s[i])
	var out := {"s": s, "surface_type": data["samples"]["surface_type"][i if t < 0.5 else i + 1]}
	for k in NUMERIC:
		var a: float = _cols[k][i]
		var b: float = _cols[k][i + 1]
		out[k] = fposmod(a + wrapf(b - a, -180.0, 180.0) * t, 360.0) if k == "heading_deg" else lerpf(a, b, t)
	return out

func position_at(s: float) -> Vector3:
	var p := sample(s)
	return Vector3(p["x"], p["y"], p["z"])

# horizontal unit vector to the left of travel at s
func left_at(s: float) -> Vector3:
	var b := deg_to_rad(float(sample(s)["heading_deg"]))
	return Vector3(-cos(b), 0.0, -sin(b))

# flat Curve3D through the samples, like route.gd builds for its Path3D (baked offset == horizontal s)
func make_curve() -> Curve3D:
	var c := Curve3D.new()
	c.bake_interval = float(data["sample_interval_m"])
	for i in _s.size():
		c.add_point(Vector3(_cols["x"][i], 0.0, _cols["z"][i]))
	return c
