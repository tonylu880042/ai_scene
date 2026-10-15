class_name Route
extends Path3D
# One-way coastal route generated from a treadmill program (programs.json): fixed running pace,
# elevation = integral of the program's incline (x grade_scale). Sea is on the LEFT of travel
# (sea_right mirrors it: `_left`/left_at() then point to the right, i.e. u > 0 is always the seaward side).
# Terrain is a ribbon of road + sand/grass built along the centre line, in 50 m chunks.
# Run a specific course:  godot --path . -- --course=summit [--start-min=20] [--quit-at-end]

@export var course := "summit"
@export var bend := 1.0             # scales how much the route winds
@export var pace_min_per_km := 6.0
@export var grade_scale := 1.5       # visual exaggeration of the incline
@export var start_height := -0.2   # path sits ~1 m above the water
@export var sea_y := -1.3
@export var sea_right := false       # mirror: sea / lake on the RIGHT of travel
@export var road_left := 2.25         # shared path: 2.25 m either side of the centre line; the run follows the centre line
@export var road_right := 10.0        # ... and the two-lane road beside it extends this far inland
@export var bank_lip := 1.5           # grass strip between the path and the water (harbour look)
@export var bank_run := 4.0           # horizontal run of the riprap bank down to the waterline
@export var hill_height := 32.0      # amplitude of the rolling land beside the road (independent of the course incline)
@export var grass_bank := true       # grassy sea bank (harbour look) instead of a sand beach
@export var inland_slope := 0.35     # how steeply the inland side rises (summit: mountainside)
@export var alpine_start := 99999.0  # altitude above sea (m) where grass gives way to bare rock
@export var alpine_range := 200.0    # ... and how far above that the vegetation has fully thinned out
@export var bank_ratio := 2.2        # horizontal run of the sea bank per metre of height (small = cliff)
@export var cliff_lip := 5.0         # flat shoulder beside the road on high (cliff) sections
@export var sea_side_plants := true  # trees/rocks may grow on the seaward side of high sections
@export var mountain_height := 0.0  # coastal: a limestone mountain wall rising 190-900 m inland, this tall (0 = off)
@export var real_shore := ""        # assets/terrain/<dem>_shore.json (tools/real_shore.py): the inland columns from 190 m
                                     # to 3 km take the real mountains along that shoreline (heights above the lake), and
                                     # rock vs vegetation from its orthophoto; replaces mountain_height's procedural wall
@export var sections_file := ""      # json timeline of scene sections (garda_sections.json): per-section widths, surface, roadside lane, slope
@export var terrain_params := {}     # terrain.gdshader overrides, e.g. {"grass_tint": Color(...), "rock_tint": ...}
@export_group("Boardwalk deck")
@export var deck := false            # plank deck (route-aligned boards, no road markings) instead of asphalt
@export var deck_texture := "wood_planks_grey"
@export var deck_tint := Color(1, 1, 1)
@export var deck_board_m := 0.7      # metres of route per texture repeat (5 boards)
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
const MOUNTAIN_U: Array[float] = [-900.0, -600.0, -420.0, -280.0, -190.0]  # coastal + mountain_height: the wall behind
const REAL_U: Array[float] = [-3000.0, -2600.0, -2250.0, -1950.0, -1700.0, -1500.0, -1330.0, -1180.0, -1050.0,
		-950.0, -900.0, -850.0, -800.0, -750.0, -710.0, -670.0, -630.0, -590.0, -550.0, -510.0, -470.0, -430.0, -395.0,
		-360.0, -325.0, -290.0, -260.0, -235.0, -210.0, -190.0]  # every ~40 m near the shore (the real DEM is ~14 m)
const NEAR_U_MOUNTAIN: Array[float] = [-120.0, -80.0, -55.0, -38.0, -26.0, -18.0, -12.0, -8.0, -5.0, -3.0]  # finer, for cliffs
const LAND_U_ALPINE: Array[float] = [-150.0, -80.0, -40.0, -20.0, -10.0, -4.0, -2.0]
const OUT_ALPINE: Array[float] = [3.0, 12.0, 40.0, 100.0, 180.0]          # downhill columns beyond the lip

var speed := 0.0           # m/s
var length := 0.0
var total_minutes := 0.0
var _segs: Array = []
var _n := 0
var _pos := PackedVector3Array()   # centre line, y = road height
var _left := PackedVector3Array()
var _cpos := PackedVector3Array()  # prefix sums of _pos / _left (box-filtered centre line for far columns, backdrop yaw)
var _cleft := PackedVector3Array()
var _cu: Array[PackedFloat32Array] = []  # per row: column offsets u (left positive)
var _cy: Array[PackedFloat32Array] = []  # ... heights
var _ck: Array[float] = []               # ... sand->grass blend (per row)
var _cr: Array[PackedFloat32Array] = []  # ... rock blend per column
var _co: Array[PackedColorArray] = []    # ... orthophoto colour (real mountains, alpha 1) for CUSTOM0, else transparent
var _hl := PackedFloat32Array()          # alpine: per-row trail half-width to the left
var _hr := PackedFloat32Array()          # ... and to the right
var _pr := PackedFloat32Array()          # coastal: walked path half-width to the right (_hr minus a roadside car lane)
var _slope := PackedFloat32Array()       # coastal: per-row multiplier of inland_slope (sections)
var _sec_types := {}
var _secs: Array = []
var _video_km := 1.0
var _surf_mats := {}
var _wy := PackedFloat32Array()          # per-row water level: sea_y, or (sections with "water_gap") that far below the path
var _quay := PackedByteArray()           # per-row: harbour quay wall straight into the water instead of a bank
var _br := PackedFloat32Array()          # per-row lake-bank run per metre of drop (sections "bank_ratio", else bank_ratio)
var _cliff := PackedFloat32Array()       # per-row height of the natural rock face rising from the inland edge (sections "cliff")
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
	if not real_shore.is_empty():
		_load_real()
	if not alpine_trail and _mtn():
		var lu: Array[float] = []
		lu.append_array(REAL_U if not _real.is_empty() else MOUNTAIN_U)
		lu.append_array(NEAR_U_MOUNTAIN)
		_land_u = lu
	_ni = _land_u.size()
	_no = 1 + (OUT_ALPINE.size() if alpine_trail else 5)
	_load_sections()
	_build_centreline()
	_build_widths()
	_build_columns()
	var road_mat := StandardMaterial3D.new()
	var road_tex := trail_texture if alpine_trail else (deck_texture if deck else "asphalt_02")
	road_mat.albedo_texture = load("res://assets/textures/%s_diff.jpg" % road_tex)
	road_mat.roughness_texture = load("res://assets/textures/%s_rough.jpg" % road_tex)
	road_mat.normal_enabled = true
	road_mat.normal_texture = load("res://assets/textures/%s_nor.jpg" % road_tex)
	road_mat.uv1_triplanar = not deck
	road_mat.uv1_world_triplanar = not deck
	if deck:  # UV = (along, across) in metres, so the boards stay square to the walking line through bends
		road_mat.albedo_color = deck_tint
	road_mat.uv1_scale = Vector3.ONE * (0.45 if alpine_trail else (1.0 / deck_board_m if deck else 0.3))
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
	for k in terrain_params:
		terrain_mat.set_shader_parameter(k, terrain_params[k])
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
		_left.append(Vector3(f.z, 0, -f.x) * (-1.0 if sea_right else 1.0))
		var target := float(info_at(s / speed)["incline"]) / 100.0 * grade_scale
		g += (target - g) * minf(1.0, ROW / 20.0)  # ~20 m to ease between grades
		p += f * ROW + Vector3(0, g * ROW, 0)
	_cpos.resize(_n + 1)
	_cleft.resize(_n + 1)
	for i in _n:
		_cpos[i + 1] = _cpos[i] + _pos[i]
		_cleft[i + 1] = _cleft[i] + _left[i]
	var c := Curve3D.new()
	c.bake_interval = 2.0
	for q in _pos:
		c.add_point(Vector3(q.x, 0.0, q.z))  # flat: baked offsets == horizontal distance s, heights come from pos_at()
	curve = c

func _load_sections() -> void:
	if sections_file.is_empty():
		return
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(sections_file))
	_video_km = d["video_km"]
	_sec_types = d["types"]
	_secs = d["sections"]

# scene section at route offset s: the reference video's timeline (sections: [[video_km, type], ...]) stretched over
# this course's length. Returns that type's settings plus "name"; empty without a sections file.
func section_at(s: float) -> Dictionary:
	if _secs.is_empty():
		return {}
	var km := clampf(s / length, 0.0, 1.0) * _video_km
	var name: String = _secs[0][1]
	for e in _secs:
		if km >= float(e[0]):
			name = e[1]
	var t: Dictionary = _sec_types[name].duplicate()
	t["name"] = name
	return t

func _mtn() -> bool:  # mountain mode: finer near columns, cliff ledges, rock by steepness
	return mountain_height > 0.0 or not real_shore.is_empty()

# --- real mountains along a real shoreline (real_shore)
var _real := {}
var _dem := PackedFloat32Array()
var _dem_g := 0
var _dem_size := 1.0
var _dem_img: Image

func _load_real() -> void:
	_real = JSON.parse_string(FileAccess.get_file_as_string(real_shore))
	var dir := real_shore.get_base_dir() + "/"
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir + _real["dem"] + ".json"))
	_dem_g = meta["grid"]
	_dem_size = meta["size_m"]
	_dem = FileAccess.get_file_as_bytes(dir + _real["dem"] + "_h.f32").to_float32_array()
	_dem_img = (load(dir + _real["dem"] + "_albedo.jpg") as Texture2D).get_image()
	if _dem_img.is_compressed():
		_dem_img.decompress()

func _real_point(s: float, d: float) -> Vector2:  # DEM-local metres: shore point for route offset s, d metres inland
	var pts: Array = _real["points"]
	var nrm: Array = _real["normals"]
	var f := clampf(s / float(_real["step"]), 0.0, pts.size() - 1.001)
	var k := int(f)
	var t := f - k
	var p := Vector2(pts[k][0], pts[k][1]).lerp(Vector2(pts[k + 1][0], pts[k + 1][1]), t)
	var n := Vector2(nrm[k][0], nrm[k][1]).lerp(Vector2(nrm[k + 1][0], nrm[k + 1][1]), t).normalized()
	return p + n * d

func _real_height(s: float, d: float) -> float:  # metres above the lake
	var p := _real_point(s, d)
	var step := _dem_size / (_dem_g - 1)
	var c := clampf(p.x / step + (_dem_g - 1) * 0.5, 0.0, _dem_g - 1.001)
	var r := clampf(p.y / step + (_dem_g - 1) * 0.5, 0.0, _dem_g - 1.001)
	var c0 := int(c)
	var r0 := int(r)
	var fc := c - c0
	var fr := r - r0
	var h00 := _dem[r0 * _dem_g + c0]
	var h01 := _dem[r0 * _dem_g + c0 + 1]
	var h10 := _dem[(r0 + 1) * _dem_g + c0]
	var h11 := _dem[(r0 + 1) * _dem_g + c0 + 1]
	return maxf(lerpf(lerpf(h00, h01, fc), lerpf(h10, h11, fc), fr) - float(_real["lake_m"]), 0.0)

func _real_ortho(s: float, d: float) -> Color:  # orthophoto colour at the real point
	var p := _real_point(s, d)
	var w := _dem_img.get_width()
	var c := _dem_img.get_pixel(clampi(int((p.x / _dem_size + 0.5) * w), 0, w - 1), clampi(int((p.y / _dem_size + 0.5) * w), 0, w - 1))
	c.a = 1.0
	return c

func _real_rock(s: float, d: float) -> float:  # bare rock where the orthophoto is pale and not green
	var p := _real_point(s, d)
	var w := _dem_img.get_width()
	var px := clampi(int((p.x / _dem_size + 0.5) * w), 0, w - 1)
	var py := clampi(int((p.y / _dem_size + 0.5) * w), 0, w - 1)
	var c := _dem_img.get_pixel(px, py)
	var green := c.g - (c.r + c.b) * 0.5
	return smoothstep(0.2, 0.4, c.get_luminance()) * smoothstep(0.03, -0.01, green)

# limestone wall behind the inland side: steep from ~190 m inland to the top at ~650 m, ridges and gullies along the route
func _mountain(u: float, q: Vector3, s: float) -> float:
	if mountain_height <= 0.0:
		return 0.0
	var t := smoothstep(150.0, 650.0, absf(u))
	var ridge := 0.65 + 0.3 * _noise.get_noise_1d(s * 0.004 + 50.0) + 0.3 * _noise.get_noise_1d(s * 0.03 + 90.0) \
			+ 0.2 * _noise.get_noise_2d(q.x * 0.008, q.z * 0.008)
	return mountain_height * t * ridge

# natural limestone face behind the path (cliff sections): near-vertical from ~6 m behind the edge, craggy, then easing
# into the slope above. a = metres inland of the path / road edge.
func _rock_face(i: int, a: float, q: Vector3) -> float:
	var h := _cliff[i]
	if h <= 0.5 or a <= 0.0:
		return 0.0
	var crag := 0.7 + 0.3 * _noise.get_noise_2d(q.x * 0.06 + 300.0, q.z * 0.06) + 0.25 * _noise.get_noise_2d(q.x * 0.21, q.z * 0.21 + 70.0)
	return h * crag * pow(clampf((a - 6.0) / 14.0, 0.0, 1.0), 0.55)  # starts ~6 m back: scanned crags (Boardwalk.gd) form the face in front

func _smooth(a: PackedFloat32Array, r: int) -> PackedFloat32Array:  # box filter over 2r+1 rows
	var out := a.duplicate()
	for i in a.size():
		var acc := 0.0
		for k in range(-r, r + 1):
			acc += a[clampi(i + k, 0, a.size() - 1)]
		out[i] = acc / (2 * r + 1)
	return out

func _build_widths() -> void:
	_hl.resize(_n)
	_hr.resize(_n)
	_pr.resize(_n)
	_slope.resize(_n)
	_slope.fill(1.0)
	var gap := PackedFloat32Array()
	gap.resize(_n)
	_cliff.resize(_n)
	_cliff.fill(0.0)
	_br.resize(_n)
	_br.fill(bank_ratio)
	_quay.resize(_n)
	_quay.fill(0)
	for i in _n:
		var s := i * ROW
		var base := road_left
		var sec := section_at(s)
		if not sec.is_empty():
			_hl[i] = sec["half"][0]
			_pr[i] = sec["half"][1]
			_hr[i] = _pr[i] + float(sec.get("road", 0.0))
			_slope[i] = float(sec.get("slope", 1.0))
			gap[i] = float(sec.get("water_gap", _pos[i].y - sea_y))
			_quay[i] = 1 if sec.get("quay", false) else 0
			_cliff[i] = float(sec.get("cliff", 0.0))
			_br[i] = float(sec.get("bank_ratio", bank_ratio))
			continue
		if alpine_trail:
			_hl[i] = clampf(trail_half * (1.0 + width_jitter * _noise.get_noise_1d(s * 0.025 + 700.0)) + 0.08 * _noise.get_noise_1d(s * 0.17 + 40.0), 0.6, 1.15)
			_hr[i] = clampf(trail_half * (1.0 + width_jitter * _noise.get_noise_1d(s * 0.025 + 1900.0)) + 0.08 * _noise.get_noise_1d(s * 0.17 + 90.0), 0.6, 1.15)
		else:
			_hl[i] = base
			_hr[i] = road_right
		_pr[i] = _hr[i]
		gap[i] = _pos[i].y - sea_y
	if not _secs.is_empty():  # water level follows the section (harbour ~1 m below the path, cliffs far below), eased over ~150 m
		gap = _smooth(gap, 37)
	_wy.resize(_n)
	for i in _n:
		_wy[i] = _pos[i].y - gap[i]
	if not _secs.is_empty():  # ease the cross-section over ~14 m at section changes
		_hl = _smooth(_hl, 3)
		_hr = _smooth(_hr, 3)
		_pr = _smooth(_pr, 3)
		_slope = _smooth(_slope, 10)
		_cliff = _smooth(_cliff, 15)
		_br = _smooth(_br, 15)

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
		var wy := _wy[i]
		var alt := h - wy
		var shoulder := h - 0.03
		var us := PackedFloat32Array()
		var ys := PackedFloat32Array()
		var er := _edge(i, false)
		var el := _edge(i, true)
		var prev_u := -INF
		for u in _land_u:
			if alpine_trail and u > -er - 0.5:
				u = -er - 0.5  # keep inland columns outside the (variable) trail band
			if _mtn():  # near columns stay outside the path / car lane and in order
				u = minf(u, -er - 0.3)
				if _cliff[i] > 0.5 and u > -40.0:  # rock face: buttresses and recesses 0-4 m deep along the route
					var s_ := i * ROW
					u -= (2.0 + 1.4 * _noise.get_noise_1d(s_ * 0.09 + 11.0) + 0.8 * _noise.get_noise_1d(s_ * 0.31 + 23.0)) * smoothstep(er + 0.3, er + 3.0, -u) * minf(_cliff[i] / 30.0, 1.0)
				u = maxf(u, prev_u + 0.01)
				prev_u = u
			var a := absf(u) - er
			var q := wp + _left[i] * u
			us.append(u)
			var hills := _noise.get_noise_2d(q.x * 0.006, q.z * 0.006) + 0.35 * _noise.get_noise_2d(q.x * 0.017 + 500.0, q.z * 0.017)
			if alpine_trail:
				var y := shoulder + inland_slope * a + hills * hill_height * smoothstep(3.0, 40.0, absf(u))
				ys.append(maxf(y, shoulder + 0.08 * a))  # never a gully beside the trail
			else:
				var ledge := smoothstep(6.0, 14.0, a) if _cliff[i] > 0.5 else 1.0  # cliff sections: a low ledge the scanned crags stand on
				ys.append(shoulder + inland_slope * _slope[i] * a * ledge + hills * hill_height * clampf(_slope[i], 0.3, 1.5) * smoothstep(10.0, 50.0, absf(u)) + _mountain(u, q, i * ROW) + _rock_face(i, a, q))  # rolling land beside the road
				if not _real.is_empty():  # real mountains from 190 m; the near band hands over to them from ~15 m inland
					# never below a rise of 30 m over the first 100 m: flat real shore land (towns, deltas) at lake level
					# would leave a trough behind the path that reads as a dark strip on the water across a bend
					var rh := maxf(wy + _real_height(i * ROW, -u), shoulder + 0.3 * minf(a, 100.0))
					ys[ys.size() - 1] = rh if u <= -190.0 else lerpf(ys[ys.size() - 1], rh, smoothstep(15.0, 110.0, a))
		if not _real.is_empty():  # never a hollow between the near slope and the real mountains
			for j in range(_ni - 2, -1, -1):
				ys[j] = maxf(ys[j], ys[j + 1] - 25.0)
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
			var w := clampf(alt * _br[i], bank_run if grass_bank else 20.0, 260.0)  # horizontal run from the shoulder down to the sea
			var k := smoothstep(2.0, 8.0, alt)
			var lip := lerpf(bank_lip if grass_bank else 14.0, cliff_lip, k)  # flat shoulder: wide on the beach (huts), narrow on cliffs
			if _quay[i] == 1:  # harbour: the quay wall (Boardwalk.gd) drops straight into the water at the path edge
				lip = el + 0.02
				w = 0.25
			us.append(lip)
			ys.append(shoulder)
			for f in [0.2, 0.5, 0.8, 1.0]:
				us.append(lip + w * f)
				var knob := 0.0  # wide (section) banks: outcrops and hollows, not one smooth sweep down to the water
				if _br[i] > bank_ratio + 0.1 and f < 1.0:
					knob = 0.12 * alt * _noise.get_noise_2d(i * ROW * 0.05, f * 7.0) * 4.0 * f * (1.0 - f)
				ys.append(lerpf(shoulder, wy - 0.5, f * f * (3.0 - 2.0 * f)) + knob)
			us.append(lip + w + 3.0)  # skirt below the water: no bank edge in the air when the lake sits lower elsewhere
			ys.append(wy - 40.0)
		var rs := PackedFloat32Array()
		var steep := PackedFloat32Array()
		for j in ys.size():
			var r := smoothstep(alpine_start, alpine_start + 0.6 * alpine_range, ys[j] - wy)
			var st := 0.0
			if _mtn() and j < _ni:  # steep inland faces are bare rock at any altitude
				var du := absf(us[j + 1] - us[j]) + 0.01
				st = smoothstep(0.9, 1.8, absf(ys[j + 1] - ys[j]) / du)
				r = maxf(r, st)
				if not _real.is_empty() and us[j] <= -40.0:  # real mountains: bare rock where the orthophoto shows it, and on cliffs
					r = maxf(lerpf(r, _real_rock(i * ROW, absf(us[j])), smoothstep(40.0, 190.0, absf(us[j]))), st)
			rs.append(r)
			steep.append(st)
		_cu.append(us)
		_cy.append(ys)
		_cr.append(rs)
		var co := PackedColorArray()
		for j in ys.size():
			var ow := smoothstep(40.0, 190.0, absf(us[j])) if (not _real.is_empty() and j < _ni) else 0.0
			ow *= 1.0 - steep[j]  # a 10 m/px photo smears down a cliff face: procedural limestone there instead
			var oc := _real_ortho(i * ROW, absf(us[j])) if ow > 0.0 else Color(0, 0, 0, 0)
			co.append(Color(oc.r * ow, oc.g * ow, oc.b * ow, ow))  # premultiplied: the shader divides by alpha
		_co.append(co)
		_ck.append(smoothstep(2.0, 8.0, alt))

# terrain vertex colour: r = sand(0)->grass(1), g = rock amount, b = trail dirt (alpine only)
func _col(i: int, j: int) -> Color:
	var dirt := 0.0
	var steep_rock := 1.0 - _co[i][j].a  # a: real mountains use the orthophoto mask only (fades in with the photo colour)
	if j > _ni and _br[i] > bank_ratio + 0.1:
		steep_rock = 0.0  # wide (section) lake banks are scrub-covered, not bare rock: no pale strip on the water across a bay
	return Color(1.0 if (j <= _ni or grass_bank) else _ck[i], _cr[i][j], dirt, steep_rock)


# Columns far from the path hang off a smoothed centre line (window ~ twice their distance): an offset curve folds over itself
# where the bend radius is smaller than the offset (the real-mountain band reaches 3 km, bends are ~550 m). The 150 m
# beside the path are exact, so props placed with ground_y() stay on the ground.
const FAR_SMOOTH_FROM := 150.0

func _box(pre: PackedVector3Array, i: int, k: int) -> Vector3:
	var a := maxi(i - k, 0)
	var b := mini(i + k + 1, _n)
	return (pre[b] - pre[a]) / float(b - a)

func _pt(i: int, j: int) -> Vector3:
	var u := _cu[i][j]
	var k := int(maxf(absf(u) - FAR_SMOOTH_FROM, 0.0) / ROW)  # half-window = distance beyond FAR_SMOOTH_FROM
	var q := _pos[i] + _left[i] * u
	if k > 0:
		var l := _box(_cleft, i, k)
		q = _box(_cpos, i, k) + Vector3(l.x, 0.0, l.z).normalized() * u
	q.y = _cy[i][j]
	return q

# columns 0.._ni = inland (far -> road edge), _ni+1.. = seaward (road edge -> sea/valley)
func _chunk(i0: int, i1: int, road_mat: Material, terrain_mat: Material) -> void:
	var road := SurfaceTool.new()
	var extra := {}  # sections: surface texture -> SurfaceTool
	var terrain := SurfaceTool.new()
	var line := SurfaceTool.new()  # painted white edge line on the sea side
	line.begin(Mesh.PRIMITIVE_TRIANGLES)
	road.begin(Mesh.PRIMITIVE_TRIANGLES)
	terrain.begin(Mesh.PRIMITIVE_TRIANGLES)
	terrain.set_custom_format(0, SurfaceTool.CUSTOM_RGBA8_UNORM)  # orthophoto colour on the real mountains
	for i in range(i0 + 1, i1 + 1):
		var p := i - 1
		if alpine_trail:
			_trail_strip(road, p, i)
		else:
			var keys: Array = ["", ""]  # walked path, roadside car lane
			if not _secs.is_empty():
				keys = [section_at(p * ROW)["surface"], "asphalt_02"]
			for k in keys:
				if k != "" and not extra.has(k):
					extra[k] = SurfaceTool.new()
					extra[k].begin(Mesh.PRIMITIVE_TRIANGLES)
			_strip(road if keys[0] == "" else extra[keys[0]], p, i, -_pr[p], -_pr[i], _hl[p], _hl[i])
			if _hr[p] - _pr[p] > 0.05 or _hr[i] - _pr[i] > 0.05:
				_strip(road if keys[1] == "" else extra[keys[1]], p, i, -_hr[p], -_hr[i], -_pr[p], -_pr[i])
		# painted markings: seaward edge line, solid line by the kerb, centre dashes, inland edge line
		var marks: Array = [[road_left - 0.45, road_left - 0.3, true], [-3.4, -3.25, true], [-road_right + 0.3, -road_right + 0.45, true]]
		if i % 3 == 0:
			marks.append([-6.4, -6.25, true])  # dashed centre line: one 2 m dash every 6 m
		if alpine_trail or deck or not _secs.is_empty():
			marks = []
		if not _secs.is_empty() and _hr[p] - _pr[p] > 3.0:  # roadside car lane: centre dashes + edge line
			var cu := -(_pr[p] + _hr[p]) * 0.5
			marks = [[-_hr[p] + 0.3, -_hr[p] + 0.42, true]]
			if i % 3 == 0:
				marks.append([cu - 0.06, cu + 0.06, true])
		for m in marks:
			var up := Vector3(0, 0.012, 0)
			var la: float = m[0]
			var lb: float = m[1]
			for v in _wind([_pos[p] + _left[p] * la, _pos[p] + _left[p] * lb, _pos[i] + _left[i] * lb, _pos[p] + _left[p] * la, _pos[i] + _left[i] * lb, _pos[i] + _left[i] * la]):
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
			var oa: Color = _co[p][j]
			var ob: Color = _co[p][j + 1]
			var oc: Color = _co[i][j + 1]
			var od: Color = _co[i][j]
			for v in _wind([[a, ca, oa], [b, cb, ob], [c, cc, oc], [a, ca, oa], [c, cc, oc], [d, cd, od]]):
				terrain.set_color(v[1])
				terrain.set_custom(0, v[2])
				terrain.add_vertex(v[0])
	line.generate_normals()
	terrain.index()
	terrain.generate_normals()
	if extra.is_empty():
		extra[""] = road
	for k in extra:
		var st: SurfaceTool = extra[k]
		st.index()
		st.generate_normals()
		var mesh := st.commit()
		if mesh.get_surface_count() == 0:  # no car lane in this chunk
			continue
		var rm := MeshInstance3D.new()
		rm.mesh = mesh
		rm.material_override = road_mat if k == "" else _surface_mat(k)
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

# flat road quad between rows p and i, from lateral ua to ub. UV = (along, across) in metres.
func _strip(st: SurfaceTool, p: int, i: int, ua_p: float, ua_i: float, ub_p: float, ub_i: float) -> void:
	var a := [_pos[p] + _left[p] * ua_p, ua_p, p]
	var b := [_pos[p] + _left[p] * ub_p, ub_p, p]
	var c := [_pos[i] + _left[i] * ub_i, ub_i, i]
	var d := [_pos[i] + _left[i] * ua_i, ua_i, i]
	for v in _wind([a, b, c, a, c, d]):
		st.set_uv(Vector2(v[2] * ROW, v[1]))  # plank textures' boards run along v: this lays them across the route
		st.add_vertex(v[0])

# road surface material for a section's "surface" texture (settings from the first section type using it)
func _surface_mat(key: String) -> Material:
	if not _surf_mats.has(key):
		var cfg := {}
		for t in _sec_types.values():
			if t["surface"] == key:
				cfg = t
				break
		var m := StandardMaterial3D.new()
		m.albedo_texture = load("res://assets/textures/%s_diff.jpg" % key)
		m.roughness_texture = load("res://assets/textures/%s_rough.jpg" % key)
		m.normal_enabled = true
		m.normal_texture = load("res://assets/textures/%s_nor.jpg" % key)
		m.uv1_scale = Vector3.ONE / float(cfg.get("uv_m", 3.0))
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		var tint: Array = cfg.get("tint", [1, 1, 1])
		m.albedo_color = Color(tint[0], tint[1], tint[2])
		_surf_mats[key] = m
	return _surf_mats[key]

# yaw (rad, about +Y) that turns the route's direction at the start into its direction at s, smoothed over ~600 m:
# the real-terrain backdrop turns with the runner so its lake / shore layout stays as it is at the start
func backdrop_yaw(s: float) -> float:
	var k := int(300.0 / ROW)
	var a := _box(_cleft, 0, k)
	var b := _box(_cleft, clampi(int(_row(s).x), 0, _n - 1), k)
	return atan2(-b.z, b.x) - atan2(-a.z, a.x)

func water_level(s: float) -> float:  # lake / sea surface height at route offset s
	var r := _row(s)
	return lerpf(_wy[int(r.x)], _wy[int(r.x) + 1], r.y)

func path_right(s: float) -> float:  # walked path to the right of the centre line (half_right minus any car lane)
	return _pr[int(_row(s).x)]

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

# triangle list in the unmirrored winding -> front faces up whichever side the sea is on
func _wind(tris: Array) -> Array:
	if sea_right:
		for k in range(0, tris.size(), 3):
			var t = tris[k + 1]
			tris[k + 1] = tris[k + 2]
			tris[k + 2] = t
	return tris

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
		var wl := _wy[int(_row(s).x)] + 0.2
		if ys[j + 1] <= wl:
			return lerpf(us[j], us[j + 1], clampf(inverse_lerp(ys[j], ys[j + 1], wl), 0.0, 1.0))
	return us[_ni + _no]

func sea_grass(s: float) -> bool:  # true where the seaward side is grassy cliff rather than beach
	return bool(section_at(s).get("lake_trees", sea_side_plants)) and _ck[int(_row(s).x)] > 0.5
