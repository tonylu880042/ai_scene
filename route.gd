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
@export_group("Alpine trail")
@export var alpine_trail := false    # narrow hillside trail (cross-slope terrain, no sea) instead of the coastal road
@export var trail_half := 0.8        # half-width of the dirt trail (m)
@export var side_slope := 0.35       # steepness of the downhill side of the trail
@export var trail_texture := "rocky_trail"
@export var width_jitter := 0.32     # trail half-width varies by this fraction (worn wider / pinched narrower)
@export var edge_blend := 0.7        # metres of ragged dirt-to-grass blend outside the trail edge
@export var groove_depth := 0.06     # worn groove: centre lower than the edges (m)
@export var bump_amp := 0.025        # small surface bumps on the trail (m)
@export var wiggle := 1.0            # small irregular left/right meanders on top of the big bends
@export var micro_relief := 0.35     # short rises and dips along the trail (m), on top of the course grade
@export_group("")
@export var quit_at_end := false
@export var random_seed := 5

const ROW := 2.0           # metres between cross-sections
const CHUNK_ROWS := 25
const LAND_U_COAST: Array[float] = [-120.0, -60.0, -30.0, -18.0, -12.0]   # inland offsets (right of road)
const LAND_U_ALPINE: Array[float] = [-150.0, -80.0, -40.0, -20.0, -10.0, -4.0, -2.0]
const OUT_ALPINE: Array[float] = [3.0, 12.0, 40.0, 100.0, 180.0]          # downhill columns beyond the lip

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
var _hl := PackedFloat32Array()          # alpine: per-row trail half-width to the left
var _hr := PackedFloat32Array()          # ... and to the right
var _land_u: Array[float] = LAND_U_COAST
var _ni := 5    # inland columns before the road
var _no := 5    # seaward strips after the road edge
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
	if alpine_trail:
		road_left = trail_half
		road_right = trail_half
		_land_u = LAND_U_ALPINE
		grass_bank = true
	_ni = _land_u.size()
	_no = 1 + (OUT_ALPINE.size() if alpine_trail else 4)
	_build_centreline()
	_build_widths()
	_build_columns()
	var road_mat := StandardMaterial3D.new()
	var road_tex := trail_texture if alpine_trail else "asphalt_02"
	road_mat.albedo_texture = load("res://assets/textures/%s_diff.jpg" % road_tex)
	road_mat.roughness_texture = load("res://assets/textures/%s_rough.jpg" % road_tex)
	road_mat.normal_enabled = true
	road_mat.normal_texture = load("res://assets/textures/%s_nor.jpg" % road_tex)
	road_mat.uv1_triplanar = true
	road_mat.uv1_world_triplanar = true
	road_mat.uv1_scale = Vector3.ONE * (0.45 if alpine_trail else 0.3)
	if alpine_trail:
		road_mat.albedo_color = Color(0.68, 0.64, 0.6)  # the source trail texture is pinkish
	_line_mat.albedo_color = Color(0.93, 0.93, 0.9)
	_line_mat.roughness = 0.7
	var terrain_mat := ShaderMaterial.new()
	terrain_mat.shader = load("res://terrain.gdshader")
	for k in ["sand_d", "sand_n", "grass_d", "grass_n", "rock_d", "rock_n"]:
		var f := "coast_sand_01" if k.begins_with("sand") else ("aerial_grass_rock" if k.begins_with("grass") else "rock_boulder_dry")
		if alpine_trail and k.begins_with("sand"):
			f = trail_texture  # the "sand" slot is the dirt patch along the trail edge
		terrain_mat.set_shader_parameter(k, load("res://assets/textures/%s_%s.jpg" % [f, "diff" if k.ends_with("d") else "nor"]))
	var surface_mat: Material = road_mat
	if alpine_trail:  # ragged worn trail blended into the meadow, same grass maths as terrain.gdshader
		var tm := ShaderMaterial.new()
		tm.shader = load("res://trail.gdshader")
		for k in ["dirt_d", "dirt_n", "grass_d", "grass_n", "gravel_d"]:
			var f2: String = {"dirt": trail_texture, "grass": "aerial_grass_rock", "gravel": "coast_sand_01"}[k.split("_")[0]]
			tm.set_shader_parameter(k, load("res://assets/textures/%s_%s.jpg" % [f2, "diff" if k.ends_with("d") else "nor"]))
		surface_mat = tm
	for i0 in range(0, _n - 1, CHUNK_ROWS):
		_chunk(i0, mini(i0 + CHUNK_ROWS, _n - 1), surface_mat, terrain_mat)

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
		if alpine_trail:
			h = bend * (0.9 * sin(s / 260.0) + 0.5 * sin(s / 110.0 + 1.0))  # winding trail, min radius ~125 m
			h += wiggle * (0.18 * _noise.get_noise_1d(s * 0.02) + 0.06 * _noise.get_noise_1d(s * 0.09 + 100.0))  # irregular meanders
		var f := Vector3(cos(h), 0, sin(h))
		if alpine_trail:
			_pos.append(p + Vector3(0, micro_relief * _noise.get_noise_1d(s * 0.05 + 300.0), 0))  # short rises / dips
		else:
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

func _build_widths() -> void:
	_hl.resize(_n)
	_hr.resize(_n)
	for i in _n:
		var s := i * ROW
		var base := road_left
		if alpine_trail:
			_hl[i] = clampf(trail_half * (1.0 + width_jitter * _noise.get_noise_1d(s * 0.025 + 700.0)) + 0.08 * _noise.get_noise_1d(s * 0.17 + 40.0), 0.6, 1.15)
			_hr[i] = clampf(trail_half * (1.0 + width_jitter * _noise.get_noise_1d(s * 0.025 + 1900.0)) + 0.08 * _noise.get_noise_1d(s * 0.17 + 90.0), 0.6, 1.15)
		else:
			_hl[i] = base
			_hr[i] = road_right

# outer edge of the walkable/blend surface at row i (u > 0 left, u < 0 right)
func _edge(i: int, left: bool) -> float:
	return (_hl[i] if left else _hr[i]) + (edge_blend if alpine_trail else 0.0)

# trail surface height at row i, lateral u: worn groove + small bumps, meeting the terrain shoulder at the edge
func _road_y(i: int, u: float) -> float:
	var h := _pos[i].y
	if not alpine_trail:
		return h
	var half := _hl[i] if u >= 0.0 else _hr[i]
	var e := half + edge_blend
	var a := absf(u)
	var groove := -groove_depth * (1.0 - pow(minf(a / half, 1.0), 2.0))
	var outer := lerpf(0.0, -0.03, smoothstep(half, e, a))
	var q := _pos[i] + _left[i] * u
	var bumps := bump_amp * _noise.get_noise_2d(q.x * 0.9 + 50.0, q.z * 0.9) * (1.0 - smoothstep(half * 0.8, e, a))
	return h + groove + outer + bumps

func half_left(s: float) -> float:
	return _hl[int(_row(s).x)]

func half_right(s: float) -> float:
	return _hr[int(_row(s).x)]

func _build_columns() -> void:
	for i in _n:
		var wp := _pos[i]
		var h := wp.y
		var alt := h - sea_y
		var shoulder := h - 0.03
		var us := PackedFloat32Array()
		var ys := PackedFloat32Array()
		var er := _edge(i, false)
		var el := _edge(i, true)
		for u in _land_u:
			if alpine_trail and u > -er - 0.5:
				u = -er - 0.5  # keep inland columns outside the (variable) trail band
			var a := absf(u) - er
			var q := wp + _left[i] * u
			us.append(u)
			var hills := _noise.get_noise_2d(q.x * 0.006, q.z * 0.006) + 0.35 * _noise.get_noise_2d(q.x * 0.017 + 500.0, q.z * 0.017)
			if alpine_trail:
				var y := shoulder + inland_slope * a + hills * hill_height * smoothstep(3.0, 40.0, absf(u))
				ys.append(maxf(y, shoulder + 0.08 * a))  # never a gully beside the trail
			else:
				ys.append(shoulder + inland_slope * a + hills * hill_height * smoothstep(10.0, 50.0, absf(u)))  # rolling land beside the road
		us.append(-er)
		ys.append(_road_y(i, -er) if alpine_trail else shoulder)
		us.append(el)
		ys.append(_road_y(i, el) if alpine_trail else shoulder)
		if alpine_trail:
			var lip := el + 0.2
			us.append(lip)
			ys.append(shoulder)
			for d in OUT_ALPINE:
				var q := wp + _left[i] * (lip + d)
				var hills := _noise.get_noise_2d(q.x * 0.006, q.z * 0.006) + 0.35 * _noise.get_noise_2d(q.x * 0.017 + 500.0, q.z * 0.017)
				var y := shoulder - side_slope * d + hills * hill_height * smoothstep(10.0, 80.0, d)
				us.append(lip + d)
				ys.append(minf(y, shoulder - 0.12 * d - 0.3 * maxf(d - 30.0, 0.0)))  # falls away below the cloud layer
		else:
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

# terrain vertex colour: r = sand(0)->grass(1), g = rock amount, b = trail dirt (alpine only)
func _col(i: int, j: int) -> Color:
	var dirt := 0.0
	return Color(1.0 if (j <= _ni or grass_bank) else _ck[i], _cr[i][j], dirt)


func _pt(i: int, j: int) -> Vector3:
	var q := _pos[i] + _left[i] * _cu[i][j]
	q.y = _cy[i][j]
	return q

# columns 0.._ni = inland (far -> road edge), _ni+1.. = seaward (road edge -> sea/valley)
func _chunk(i0: int, i1: int, road_mat: Material, terrain_mat: Material) -> void:
	var road := SurfaceTool.new()
	var terrain := SurfaceTool.new()
	var line := SurfaceTool.new()  # painted white edge line on the sea side
	line.begin(Mesh.PRIMITIVE_TRIANGLES)
	road.begin(Mesh.PRIMITIVE_TRIANGLES)
	terrain.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(i0 + 1, i1 + 1):
		var p := i - 1
		if alpine_trail:
			_trail_strip(road, p, i)
		else:
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
		if alpine_trail:
			marks = []
		for m in marks:
			var up := Vector3(0, 0.012, 0)
			var la: float = m[0]
			var lb: float = m[1]
			for v in [_pos[p] + _left[p] * la, _pos[p] + _left[p] * lb, _pos[i] + _left[i] * lb, _pos[p] + _left[p] * la, _pos[i] + _left[i] * lb, _pos[i] + _left[i] * la]:
				line.add_vertex(v + up)
		var strips: Array = range(_ni) + range(_ni + 1, _ni + 1 + _no)  # inland strips, then seaward strips
		for j in strips:
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

# one row-pair of the alpine trail: TRAIL_COLS columns from the right blend edge to the left blend edge.
# UV.x = u / half-width on that side (|UV.x| <= 1 on the walked surface), UV.y = distance along the route.
const TRAIL_COLS := 10
func _trail_strip(st: SurfaceTool, p: int, i: int) -> void:
	var rows := [p, i]
	var pts := []
	for r in rows:
		var er := _edge(r, false)
		var el := _edge(r, true)
		var row := []
		for k in TRAIL_COLS + 1:
			var t := float(k) / TRAIL_COLS
			var u := lerpf(-er, el, t)
			var v := _pos[r] + _left[r] * u
			v.y = _road_y(r, u)
			row.append([v, Vector2(u / (_hl[r] if u >= 0.0 else _hr[r]), r * ROW)])
		pts.append(row)
	for k in TRAIL_COLS:
		var a = pts[0][k]
		var b = pts[0][k + 1]
		var c = pts[1][k + 1]
		var d = pts[1][k]
		for v in [a, b, c, a, c, d]:
			st.set_uv(v[1])
			st.add_vertex(v[0])

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
	if u <= _edge(i, true) and u >= -_edge(i, false):
		return _road_y(i, u)
	var lo := 0 if u < 0.0 else _ni + 1
	var cnt := _ni if u < 0.0 else _no
	for j in range(lo, lo + cnt):
		var inside := u >= us[j] and u <= us[j + 1] if u < 0.0 else u <= us[j + 1]
		if inside or j == lo + cnt - 1:
			var t := clampf(inverse_lerp(us[j], us[j + 1], u), 0.0, 1.0)
			return lerpf(ys[j], ys[j + 1], t)
	return ys[lo + cnt]

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
	for j in range(_ni + 1, _ni + 1 + _no):
		if ys[j + 1] <= sea_y + 0.2:
			return lerpf(us[j], us[j + 1], clampf(inverse_lerp(ys[j], ys[j + 1], sea_y + 0.2), 0.0, 1.0))
	return us[_ni + _no]

func sea_grass(s: float) -> bool:  # true where the seaward side is grassy cliff rather than beach
	return _ck[int(_row(s).x)] > 0.5
