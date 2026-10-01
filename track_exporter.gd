extends Node
# Records ground-truth camera data for a web player while a run is rendered (movie writer).
# Inactive unless  --export-dir=<path>  is given (after the `--`). Optional --export-minutes=N.
# See tools/EXPORT_README.md for the data contract.

@export var route_path: NodePath = ^"../Path3D"
@export var sun_path: NodePath = ^"../Sun"
@export var player_path: NodePath = ^"../Player"
@export var scene_name := "alpine"
@export var out_w := 1920
@export var out_h := 1080
@export var fps := 60
@export var occluder_ahead := 400.0

var _dir := ""
var _minutes := 0.0
var _route: Route
var _sun: DirectionalLight3D
var _cam: Camera3D
var _c := {}
var _keys := ["t", "s", "px", "py", "pz", "qx", "qy", "qz", "qw", "incline",
		"sun_dx", "sun_dy", "sun_dz", "sun_r", "sun_g", "sun_b", "sun_energy"]
var _t0 := -1.0
var _course := ""
var _markers := false

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--export-dir="):
			_dir = a.substr(13)
		elif a.begins_with("--export-minutes="):
			_minutes = float(a.substr(17))
		elif a == "--export-markers":
			_markers = true  # debug: magenta unshaded spheres on the centre line every 5 m (alignment test)
		elif a.begins_with("--course="):
			_course = a.substr(9)
	if _dir.is_empty():
		set_process(false)
		return
	process_priority = 100000  # run after every other _process: pose/sun are final for the frame
	_route = get_node(route_path)
	_sun = get_node(sun_path)
	_cam = get_node(player_path).get_node("Camera3D")
	if _course.is_empty():
		_course = _route.course
	get_tree().root.size = Vector2i(out_w, out_h)  # movie writer records the root viewport
	DirAccess.make_dir_recursive_absolute(_dir)
	for k in _keys:
		_c[k] = PackedFloat64Array()
	if _markers:
		_add_markers.call_deferred()

func _process(_d: float) -> void:
	if _route.curve == null:
		return
	var t := _route.clock()
	if _t0 < 0.0:
		_t0 = t
	var p := _cam.global_position
	var q := _cam.global_transform.basis.get_rotation_quaternion()
	var s := _route.curve.get_closest_offset(_route.to_local(p))
	var sd := _sun.global_transform.basis.z
	var vals := [t, s, p.x, p.y, p.z, q.x, q.y, q.z, q.w, _route.info_at(t)["incline"],
			sd.x, sd.y, sd.z, _sun.light_color.r, _sun.light_color.g, _sun.light_color.b, _sun.light_energy]
	for i in _keys.size():
		_c[_keys[i]].append(vals[i])
	if (_minutes > 0.0 and t - _t0 >= _minutes * 60.0 - 0.5 / fps) or t >= _route.total_minutes * 60.0:
		_finish()

func _r(a: PackedFloat64Array, step: float) -> Array:
	var out := []
	out.resize(a.size())
	for i in a.size():
		out[i] = snappedf(a[i], step)
	return out

func _write(fname: String, data) -> void:
	var f := FileAccess.open(_dir.path_join(fname), FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()

func _finish() -> void:
	set_process(false)
	var n: int = _c["t"].size()
	var fr := {}
	for k in _keys:
		var st := 0.00001
		if k == "t":
			st = 0.000001
		elif k == "s" or k == "incline":
			st = 0.0001
		fr[k] = _r(_c[k], st)
	var cam := {"version": 1, "scene": scene_name, "course": _course, "fps": fps, "width": out_w, "height": out_h,
			"fov_y_deg": _cam.fov, "near": _cam.near, "far": _cam.far, "speed_mps": _route.speed,
			"start_time": snappedf(_c["t"][0], 0.000001), "frame_count": n, "frames": fr}
	_write("camera.json", cam)
	var rs := []
	var rx := []
	var ry := []
	var rz := []
	var lx := []
	var lz := []
	for i in int(floor(_route.length)) + 1:
		var pp := _route.pos_at(float(i))
		var l := _route.left_at(float(i))
		rs.append(i)
		rx.append(snappedf(pp.x, 0.0001))
		ry.append(snappedf(pp.y, 0.0001))
		rz.append(snappedf(pp.z, 0.0001))
		lx.append(snappedf(l.x, 0.00001))
		lz.append(snappedf(l.z, 0.00001))
	_write("route.json", {"version": 1, "step": 1.0, "length": _route.length, "road_left": _route.road_left,
			"road_right": _route.road_right, "s": rs, "x": rx, "y": ry, "z": rz, "lx": lx, "lz": lz})
	_export_occluder(_c["s"][0], _c["s"][n - 1] + occluder_ahead)
	print("TrackExporter: wrote ", n, " frames to ", _dir)
	get_tree().quit()

func _export_occluder(s0: float, s1: float) -> void:
	# Route children: per 50 m chunk a road mesh, a painted-line mesh (shadows off) and a terrain mesh.
	var meshes: Array[MeshInstance3D] = []
	for ch in _route.get_children():
		if ch is MeshInstance3D and ch.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			meshes.append(ch)
	var chunk_len := Route.ROW * Route.CHUNK_ROWS
	var root := Node3D.new()
	root.name = "Occluder"
	var cnt := 0
	for i in meshes.size():
		var k := i / 2  # road, terrain pairs
		if (k + 1) * chunk_len < s0 - 20.0 or k * chunk_len > s1 + 20.0:
			continue
		var mi := MeshInstance3D.new()
		mi.name = "chunk%d_%s" % [k, "road" if i % 2 == 0 else "terrain"]
		mi.mesh = meshes[i].mesh
		mi.transform = meshes[i].global_transform
		root.add_child(mi)
		cnt += 1
	var doc := GLTFDocument.new()
	var gs := GLTFState.new()
	var err := doc.append_from_scene(root, gs)
	if err == OK:
		err = doc.write_to_filesystem(gs, _dir.path_join("occluder.glb"))
	print("TrackExporter: occluder ", cnt, " meshes, err=", err)
	root.free()

func _add_markers() -> void:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1, 0, 1)
	var sp := SphereMesh.new()
	sp.radius = 0.12
	sp.height = 0.24
	sp.material = m
	var s := _route.start_offset
	while s < _route.start_offset + 500.0 and s < _route.length:
		var mi := MeshInstance3D.new()
		mi.mesh = sp
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		mi.global_position = _route.pos_at(s) + Vector3(0, 0.12, 0)
		s += 5.0
