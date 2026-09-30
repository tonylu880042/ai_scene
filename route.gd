class_name Route
extends Path3D
# One-way coastal route generated from a treadmill program (programs.json): fixed running pace,
# elevation = integral of the program's incline (x grade_scale). Sea is on the LEFT of travel.
# Terrain is a ribbon of road + sand/grass built along the centre line, in 50 m chunks.
# Run a specific course:  godot --path . -- --course=summit [--start-min=20] [--quit-at-end]

@export var course := "summit"
@export var bend := 1.0             # scales how much the route winds
@export var pace_min_per_km := 6.0
@export var grade_scale := 1.5       # visual exaggeration of the incline
@export var start_height := -0.2   # path sits ~1 m above the water
@export var sea_y := -1.3
@export var road_left := 2.25         # shared path: 2.25 m either side of the centre line; the run follows the centre line
@export var road_right := 10.0        # ... and the two-lane road beside it extends this far inland
@export var bank_lip := 1.5           # grass strip between the path and the water (harbour look)
@export var bank_run := 4.0           # horizontal run of the riprap bank down to the waterline
@export var hill_height := 32.0      # amplitude of the rolling land beside the road (independent of the course incline)
@export var grass_bank := true       # grassy sea bank (harbour look) instead of a sand beach
@export var inland_slope := 0.35     # how steeply the inland side rises (summit: mountainside)
@export var alpine_start := 99999.0  # altitude above sea (m) where grass gives way to bare rock
@export var alpine_range := 200.0    # ... and how far above that the vegetation has fully thinned out
@export var quit_at_end := false
@export var random_seed := 5

const ROW := 2.0           # metres between cross-sections
const CHUNK_ROWS := 25
const LAND_U: Array[float] = [-120.0, -60.0, -30.0, -18.0, -12.0]   # inland offsets (right of road)

var speed := 0.0           # m/s
var length := 0.0
var total_minutes := 0.0
var _segs: Array = []
var _n := 0
var _pos := PackedVector3Array()   # centre line, y = road height
var _left := PackedVector3Array()
var _cu: Array[PackedFloat32Array] = []  # per row: column offsets u (left positive)
var _cy: Array[PackedFloat32Array] = []  # ... heights
var _ck: Array[float] = []               # ... sand->grass blend (per row)
var _cr: Array[PackedFloat32Array] = []  # ... rock blend per column
var _noise := FastNoiseLite.new()
var start_time := 0.0      # seconds into the course to start from (--start-min=)
var start_offset := 0.0    # ... as metres along the route
var _t := 0.0
var _line_mat := StandardMaterial3D.new()

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--course="):
			course = a.substr(9)
		elif a.begins_with("--start-min="):
			start_time = float(a.substr(12)) * 60.0
		elif a == "--quit-at-end":
			quit_at_end = true
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://programs.json"))
	_segs = data[course]
	for s in _segs:
		total_minutes += s[0]
	speed = 1000.0 / (pace_min_per_km * 60.0)
	length = total_minutes * 60.0 * speed
	start_offset = start_time * speed
	_t = start_time
	_n = ceili(length / ROW) + 1
	_noise.seed = random_seed
	_build_centreline()
	_build_columns()
	var road_mat := StandardMaterial3D.new()
	road_mat.albedo_texture = load("res://assets/textures/asphalt_02_diff.jpg")
	road_mat.roughness_texture = load("res://assets/textures/asphalt_02_rough.jpg")
	road_mat.normal_enabled = true
	road_mat.normal_texture = load("res://assets/textures/asphalt_02_nor.jpg")
	road_mat.uv1_triplanar = true
	road_mat.uv1_world_triplanar = true
	road_mat.uv1_scale = Vector3.ONE * 0.3
	_line_mat.albedo_color = Color(0.93, 0.93, 0.9)
	_line_mat.roughness = 0.7
	var terrain_mat := ShaderMaterial.new()
	terrain_mat.shader = load("res://terrain.gdshader")
	for k in ["sand_d", "sand_n", "grass_d", "grass_n", "rock_d", "rock_n"]:
		var f := "coast_sand_01" if k.begins_with("sand") else ("aerial_grass_rock" if k.begins_with("grass") else "rock_boulder_dry")
		terrain_mat.set_shader_parameter(k, load("res://assets/textures/%s_%s.jpg" % [f, "diff" if k.ends_with("d") else "nor"]))
	for i0 in range(0, _n - 1, CHUNK_ROWS):
		_chunk(i0, mini(i0 + CHUNK_ROWS, _n - 1), road_mat, terrain_mat)

func _process(delta: float) -> void:
	_t += delta
	if quit_at_end and _t > total_minutes * 60.0 + 3.0:
		get_tree().quit()

func clock() -> float:  # seconds into the course
	return _t

# {"phase": String, "incline": float (%), "minute": float} at t seconds into the course
func info_at(t: float) -> Dictionary:
	var m := t / 60.0
	var acc := 0.0
	for s in _segs:
		acc += s[0]
		if m < acc:
			return {"phase": s[2], "incline": float(s[1]), "minute": m}
	var last: Array = _segs[-1]
	return {"phase": last[2], "incline": float(last[1]), "minute": m}

func _build_centreline() -> void:
	var p := Vector3(0, start_height, 0)
	var g := 0.0
	for i in _n:
		var s := i * ROW
		var h := bend * (0.7 * sin(s / 500.0) + 0.35 * sin(s / 220.0 + 1.0))  # gentle bends, min radius ~330 m
		var f := Vector3(cos(h), 0, sin(h))
		_pos.append(p)
		_left.append(Vector3(f.z, 0, -f.x))
		var target := float(info_at(s / speed)["incline"]) / 100.0 * grade_scale
		g += (target - g) * minf(1.0, ROW / 20.0)  # ~20 m to ease between grades
		p += f * ROW + Vector3(0, g * ROW, 0)
	var c := Curve3D.new()
	c.bake_interval = 2.0
	for q in _pos:
		c.add_point(Vector3(q.x, 0.0, q.z))  # flat: baked offsets == horizontal distance s, heights come from pos_at()
	curve = c

func _build_columns() -> void:
	for i in _n:
		var wp := _pos[i]
		var h := wp.y
		var alt := h - sea_y
		var shoulder := h - 0.03
		var us := PackedFloat32Array()
		var ys := PackedFloat32Array()
		for u in LAND_U:
			var a := absf(u) - road_right
			var q := wp + _left[i] * u
			us.append(u)
			var hills := _noise.get_noise_2d(q.x * 0.006, q.z * 0.006) + 0.35 * _noise.get_noise_2d(q.x * 0.017 + 500.0, q.z * 0.017)
			ys.append(shoulder + inland_slope * a + hills * hill_height * smoothstep(10.0, 50.0, absf(u)))  # rolling land beside the road
		us.append(-road_right)
		ys.append(shoulder)
		us.append(road_left)
		ys.append(shoulder)
		var w := clampf(alt * 2.2, bank_run if grass_bank else 20.0, 260.0)  # horizontal run from the shoulder down to the sea
		var k := smoothstep(2.0, 8.0, alt)
		var lip := lerpf(bank_lip if grass_bank else 14.0, 5.0, k)  # flat shoulder: wide on the beach (huts), narrow on cliffs
		us.append(lip)
		ys.append(shoulder)
		for f in [0.2, 0.5, 0.8, 1.0]:
			us.append(lip + w * f)
			ys.append(lerpf(shoulder, sea_y - 0.5, f * f * (3.0 - 2.0 * f)))
		var rs := PackedFloat32Array()
		for y in ys:
			rs.append(smoothstep(alpine_start, alpine_start + 0.6 * alpine_range, y - sea_y))
		_cu.append(us)
		_cy.append(ys)
		_cr.append(rs)
		_ck.append(smoothstep(2.0, 8.0, alt))

# terrain vertex colour: r = sand(0)->grass(1), g = rock amount
func _col(i: int, j: int) -> Color:
	return Color(1.0 if (j < 6 or grass_bank) else _ck[i], _cr[i][j], 0.0)


func _pt(i: int, j: int) -> Vector3:
	var q := _pos[i] + _left[i] * _cu[i][j]
	q.y = _cy[i][j]
	return q

# columns 0..5 = inland strip (far -> road edge), 6..11 = seaward strip (road edge -> sea)
func _chunk(i0: int, i1: int, road_mat: Material, terrain_mat: Material) -> void:
	var road := SurfaceTool.new()
	var terrain := SurfaceTool.new()
	var line := SurfaceTool.new()  # painted white edge line on the sea side
	line.begin(Mesh.PRIMITIVE_TRIANGLES)
	road.begin(Mesh.PRIMITIVE_TRIANGLES)
	terrain.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(i0 + 1, i1 + 1):
		var p := i - 1
		var rl_a := _pos[p] + _left[p] * road_left  # road corners, flat across
		var rr_a := _pos[p] - _left[p] * road_right
		var rl_b := _pos[i] + _left[i] * road_left
		var rr_b := _pos[i] - _left[i] * road_right
		for v in [rr_a, rl_a, rl_b, rr_a, rl_b, rr_b]:
			road.add_vertex(v)
		# painted markings: seaward edge line, solid line by the kerb, centre dashes, inland edge line
		var marks: Array = [[road_left - 0.45, road_left - 0.3, true], [-3.4, -3.25, true], [-road_right + 0.3, -road_right + 0.45, true]]
		if i % 3 == 0:
			marks.append([-6.4, -6.25, true])  # dashed centre line: one 2 m dash every 6 m
		for m in marks:
			var up := Vector3(0, 0.012, 0)
			var la: float = m[0]
			var lb: float = m[1]
			for v in [_pos[p] + _left[p] * la, _pos[p] + _left[p] * lb, _pos[i] + _left[i] * lb, _pos[p] + _left[p] * la, _pos[i] + _left[i] * lb, _pos[i] + _left[i] * la]:
				line.add_vertex(v + up)
		for j in [0, 1, 2, 3, 4, 6, 7, 8, 9, 10]:  # strips: 0-4 inland (j..j+1), 6-10 seaward
			var a := _pt(p, j)
			var b := _pt(p, j + 1)
			var c := _pt(i, j + 1)
			var d := _pt(i, j)
			var ca := _col(p, j)
			var cb := _col(p, j + 1)
			var cc := _col(i, j + 1)
			var cd := _col(i, j)
			for v in [[a, ca], [b, cb], [c, cc], [a, ca], [c, cc], [d, cd]]:
				terrain.set_color(v[1])
				terrain.add_vertex(v[0])
	line.generate_normals()
	for st: SurfaceTool in [road, terrain]:
		st.index()
		st.generate_normals()
	var rm := MeshInstance3D.new()
	rm.mesh = road.commit()
	rm.material_override = road_mat
	add_child(rm)
	rm.create_trimesh_collision()
	var lm := MeshInstance3D.new()
	lm.mesh = line.commit()
	lm.material_override = _line_mat
	lm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(lm)
	var tm := MeshInstance3D.new()
	tm.mesh = terrain.commit()
	tm.material_override = terrain_mat
	add_child(tm)

func _row(s: float) -> Vector2:  # (row index, fraction)
	var f := clampf(s / ROW, 0.0, _n - 1.001)
	return Vector2(floorf(f), f - floorf(f))

func pos_at(s: float) -> Vector3:
	var r := _row(s)
	return _pos[int(r.x)].lerp(_pos[int(r.x) + 1], r.y)

func left_at(s: float) -> Vector3:
	var r := _row(s)
	return _left[int(r.x)].lerp(_left[int(r.x) + 1], r.y).normalized()

# terrain height at route offset s, lateral offset u (left/seaward positive)
func ground_y(s: float, u: float) -> float:
	var i := int(_row(s).x)
	var us := _cu[i]
	var ys := _cy[i]
	if u <= road_left and u >= -road_right:
		return _pos[i].y
	var lo := 0 if u < 0.0 else 6
	for j in range(lo, lo + 5):
		if u <= us[j + 1] or j == lo + 4:
			var t := clampf(inverse_lerp(us[j], us[j + 1], u), 0.0, 1.0)
			return lerpf(ys[j], ys[j + 1], t)
	return ys[lo + 5]

# centre line as (x, z) every `step` metres, for the HUD minimap
func map_points(step: float = 10.0) -> PackedVector2Array:
	var out := PackedVector2Array()
	var s := 0.0
	while s < length:
		var p := pos_at(s)
		out.append(Vector2(p.x, p.z))
		s += step
	var e := pos_at(length)
	out.append(Vector2(e.x, e.z))
	return out

# lateral offset (u, seaward) where the bank meets the water at route offset s
func water_edge_u(s: float) -> float:
	var i := int(_row(s).x)
	var us := _cu[i]
	var ys := _cy[i]
	for j in range(6, 11):
		if ys[j + 1] <= sea_y + 0.2:
			return lerpf(us[j], us[j + 1], clampf(inverse_lerp(ys[j], ys[j + 1], sea_y + 0.2), 0.0, 1.0))
	return us[11]

func sea_grass(s: float) -> bool:  # true where the seaward side is grassy cliff rather than beach
	return _ck[int(_row(s).x)] > 0.5
