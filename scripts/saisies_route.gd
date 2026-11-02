class_name SaisiesRoute
extends Path3D

## Deterministic road and terrain ribbon for the Col des Saisies biking scene.
##
## The route data is deliberately small and authored separately from this script.  The
## current contract is data/saisies_route.json with the following useful fields:
##   estimated_length_m, start_elevation_m, end_elevation_m, road_width_m,
##   sample_spacing_m, checkpoints[], sections[], landmarks[].
## Checkpoints contain distance_m, elevation_m and heading_deg (0 looks down -Z;
## positive values turn clockwise).  If the data file is not present, a deterministic
## visual fallback is generated so the scene remains useful while the route is edited.

@export_file("*.json") var route_file := "res://data/saisies_route.json"
@export var fallback_length_m := 14800.0
@export var fallback_start_elevation_m := 1594.0
@export var fallback_end_elevation_m := 717.0
@export var fallback_road_width_m := 6.4
@export var fallback_sample_spacing_m := 5.0
@export var random_seed := 2509
@export var centerline_start_m := 7.0
@export var shoulder_width_m := 1.48
@export var downhill_terrain_factor := 0.20
@export var shoulder_albedo_tint := Color(0.62, 0.67, 0.64, 1.0)
@export var village_flatten_radius_m := 0.0

const SCENE_MAP_FILE := "res://data/saisies_scene_map.json"

const DEFAULT_SECTION_NAMES := ["summit_village", "open_meadow", "retaining_wall", "forest_descent", "valley_hamlet"]
const DEFAULT_SECTION_FROM := [0.0, 950.0, 4200.0, 6500.0, 12800.0]
const DEFAULT_SECTION_TO := [950.0, 4200.0, 6500.0, 12800.0, 14800.0]
const DEFAULT_SECTION_GRADES := [-4.0, -5.2, -7.0, -7.0, -5.0]
const TERRAIN_OFFSETS := [-110.0, -64.0, -34.0, -14.0, -4.2, 4.2, 14.0, 34.0, 64.0, 110.0]
const TERRAIN_TRANSITION_WIDTH_M := 70.0

var length_m := 0.0
var road_width_m := 6.4
var sample_spacing_m := 5.0
var start_elevation_m := 1594.0
var end_elevation_m := 717.0

var _samples: Array[Vector3] = []
var _headings: PackedFloat32Array
var _elevations: PackedFloat32Array
var _grades: PackedFloat32Array
var _sections: Array = []
var _landmarks: Array = []
var _checkpoints: Array = []
var _terrain_overrides: Array = []
var _terrain_boundary_distances: Array[float] = []
var _terrain_boundaries_ready := false
var _noise := FastNoiseLite.new()
var _ready_built := false
var _road_mesh: MeshInstance3D
var _terrain_mesh: MeshInstance3D
var _shoulder_mesh: MeshInstance3D
var _road_collision: StaticBody3D

func _ready() -> void:
	_load_route_data()
	_build_samples()
	_build_curve()
	_build_road_and_collision()
	_build_terrain()
	_ready_built = true

func _load_route_data() -> void:
	_noise.seed = random_seed
	# Use route-space coordinates directly in _terrain_point.  This gives the
	# banks an 60--80 m natural undulation while leaving the road edge smooth.
	_noise.frequency = 0.014
	length_m = fallback_length_m
	start_elevation_m = fallback_start_elevation_m
	end_elevation_m = fallback_end_elevation_m
	road_width_m = fallback_road_width_m
	sample_spacing_m = fallback_sample_spacing_m
	_sections = _fallback_sections()
	_checkpoints = []
	_landmarks = []
	_terrain_overrides = []
	_terrain_boundary_distances.clear()
	_terrain_boundaries_ready = false
	if not FileAccess.file_exists(route_file):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(route_file))
	if not (parsed is Dictionary):
		push_warning("Saisies route data is not a JSON object; using fallback route")
		return
	var d: Dictionary = parsed
	# v2 route files may carry a small, traceable overlay instead of copying the
	# full v1 route.  The base keeps all authored sections/landmarks while the
	# overlay can correct only evidence-backed checkpoint values.
	if d.get("base_route_file", null) is String:
		var base_path := String(d["base_route_file"])
		if FileAccess.file_exists(base_path):
			var base_parsed = JSON.parse_string(FileAccess.get_file_as_string(base_path))
			if base_parsed is Dictionary:
				for key in base_parsed.keys():
					if not d.has(key):
						d[key] = base_parsed[key]
		if d.get("checkpoint_overrides", null) is Array:
			var merged_checkpoints: Array = d.get("checkpoints", []).duplicate(true)
			for override in d["checkpoint_overrides"]:
				if not (override is Dictionary):
					continue
				var override_distance := float(override.get("distance_m", -1.0))
				var replaced := false
				for i in merged_checkpoints.size():
					if absf(float(merged_checkpoints[i].get("distance_m", -2.0)) - override_distance) < 0.1:
						merged_checkpoints[i] = override.duplicate(true)
						replaced = true
						break
				if not replaced:
					merged_checkpoints.append(override.duplicate(true))
			d["checkpoints"] = merged_checkpoints
	# A future editor may wrap metadata in `route`; merge it without making the
	# runtime depend on the wrapper.
	if d.get("route", null) is Dictionary:
		var wrapped: Dictionary = d["route"]
		for k in wrapped.keys():
			d[k] = wrapped[k]
	length_m = maxf(float(d.get("estimated_length_m", d.get("length_m", length_m))), 100.0)
	start_elevation_m = float(d.get("start_elevation_m", d.get("elevation_start_m", start_elevation_m)))
	end_elevation_m = float(d.get("end_elevation_m", d.get("elevation_end_m", end_elevation_m)))
	road_width_m = clampf(float(d.get("road_width_m", road_width_m)), 4.0, 12.0)
	sample_spacing_m = clampf(float(d.get("sample_spacing_m", sample_spacing_m)), 2.0, 20.0)
	if d.has("random_seed"):
		random_seed = int(d["random_seed"])
		_noise.seed = random_seed
	if d.get("sections", null) is Array and not d["sections"].is_empty():
		_sections = _normalise_sections(d["sections"])
	if d.get("checkpoints", null) is Array:
		_checkpoints = _normalise_checkpoints(d["checkpoints"])
	if d.get("landmarks", null) is Array:
		_landmarks = d["landmarks"].duplicate(true)
	if d.get("terrain_overrides", null) is Array:
		_terrain_overrides = d["terrain_overrides"].duplicate(true)

func _fallback_sections() -> Array:
	var out: Array = []
	var biome := ["village", "meadow", "retaining_wall", "forest", "hamlet"]
	var trees := [0.16, 0.38, 0.55, 0.92, 0.32]
	var uphill := ["right", "right", "left", "right", "left"]
	var rails := ["both", "both", "right", "none", "both"]
	var walls := ["none", "none", "left", "right", "none"]
	var chalets := [0.7, 0.08, 0.0, 0.0, 0.75]
	for i in DEFAULT_SECTION_NAMES.size():
		out.append({
			"id": DEFAULT_SECTION_NAMES[i],
			"name": DEFAULT_SECTION_NAMES[i].replace("_", " ").capitalize(),
			"from_m": DEFAULT_SECTION_FROM[i],
			"to_m": DEFAULT_SECTION_TO[i],
			"tree_density": trees[i],
			"uphill_side": uphill[i],
			"guardrail": rails[i],
			"wall": walls[i],
			"chalet_density": chalets[i],
			"biome": biome[i],
			"grade_pct": DEFAULT_SECTION_GRADES[i],
			"road_width_m": fallback_road_width_m
		})
	return out

func _normalise_sections(raw: Array) -> Array:
	var out: Array = []
	for item in raw:
		if not (item is Dictionary):
			continue
		var src: Dictionary = item
		var e: Dictionary = src.duplicate(true)
		var from_m := float(src.get("from_m", src.get("from", src.get("start_m", 0.0))))
		var to_m := float(src.get("to_m", src.get("to", src.get("end_m", length_m))))
		if src.has("from_km"):
			from_m = float(src["from_km"]) * 1000.0
		if src.has("to_km"):
			to_m = float(src["to_km"]) * 1000.0
		e["from_m"] = clampf(from_m, 0.0, length_m)
		e["to_m"] = clampf(maxf(to_m, from_m + 1.0), 0.0, length_m)
		e["name"] = String(src.get("name", src.get("id", src.get("biome", "route"))))
		e["id"] = String(src.get("id", e["name"]))
		e["biome"] = String(src.get("biome", "meadow"))
		out.append(e)
	if out.is_empty():
		return _fallback_sections()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["from_m"]) < float(b["from_m"]))
	return out

func _normalise_checkpoints(raw: Array) -> Array:
	var out: Array = []
	for item in raw:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var s := float(d.get("distance_m", d.get("distance", d.get("m", 0.0))))
		out.append({
			"distance_m": clampf(s, 0.0, length_m),
			"video_seconds": float(d.get("video_seconds", d.get("time_s", 0.0))),
			"elevation_m": float(d.get("elevation_m", lerpf(start_elevation_m, end_elevation_m, s / maxf(length_m, 1.0)))),
			"heading_deg": float(d.get("heading_deg", 0.0))
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["distance_m"]) < float(b["distance_m"]))
	return out

func _build_samples() -> void:
	var n := maxi(int(ceil(length_m / sample_spacing_m)), 2) + 1
	_samples.clear()
	_headings.resize(n)
	_elevations.resize(n)
	_grades.resize(n)
	var raw_elev := PackedFloat32Array()
	raw_elev.resize(n)
	var no_checkpoints := _checkpoints.size() < 2
	# First create a smooth elevation profile. Checkpoint values are treated as
	# author observations and interpolated; fallback data integrates grade values.
	if no_checkpoints:
		raw_elev[0] = start_elevation_m
		for i in range(1, n):
			var s0 := float(i - 1) * sample_spacing_m
			var s1 := minf(float(i) * sample_spacing_m, length_m)
			var g := _configured_grade_at(s0)
			raw_elev[i] = raw_elev[i - 1] + g * (s1 - s0) / 100.0
		var raw_drop := raw_elev[n - 1] - raw_elev[0]
		var scale := (end_elevation_m - start_elevation_m) / raw_drop if absf(raw_drop) > 0.1 else 1.0
		for i in n:
			raw_elev[i] = start_elevation_m + (raw_elev[i] - start_elevation_m) * scale
	else:
		for i in n:
			raw_elev[i] = _checkpoint_elevation_at(minf(float(i) * sample_spacing_m, length_m))
	# A short box filter removes telemetry stair steps while preserving endpoint HUD values.
	var smooth_elev := raw_elev.duplicate()
	for i in range(1, n - 1):
		smooth_elev[i] = (raw_elev[i - 1] + raw_elev[i] * 2.0 + raw_elev[i + 1]) * 0.25
	smooth_elev[0] = start_elevation_m
	smooth_elev[n - 1] = end_elevation_m
	for i in n:
		var s := minf(float(i) * sample_spacing_m, length_m)
		var heading := _heading_at(s)
		_headings[i] = heading
		_elevations[i] = smooth_elev[i]
		var fwd := Vector3(sin(heading), 0.0, -cos(heading))
		if i == 0:
			_samples.append(Vector3.ZERO)
		else:
			var ds := s - minf(float(i - 1) * sample_spacing_m, length_m)
			var prev := _samples[i - 1]
			_samples.append(prev + fwd * ds + Vector3.UP * (smooth_elev[i] - smooth_elev[i - 1]))
	for i in n:
		if i == 0:
			_grades[i] = (_elevations[1] - _elevations[0]) / sample_spacing_m * 100.0
		elif i == n - 1:
			_grades[i] = (_elevations[i] - _elevations[i - 1]) / sample_spacing_m * 100.0
		else:
			_grades[i] = (_elevations[i + 1] - _elevations[i - 1]) / (2.0 * sample_spacing_m) * 100.0

func _build_curve() -> void:
	var c := Curve3D.new()
	c.bake_interval = 2.0
	for p in _samples:
		c.add_point(p)
	curve = c

func _road_y(s: float, u: float) -> float:
	var p := pos_at(s)
	# A subtle crown gives the road a readable wet-weather edge and prevents a
	# perfectly flat card from appearing on banked bends.
	var half := road_width_at(s) * 0.5
	var crown := -0.018 * clampf(u / maxf(half, 0.1), -1.0, 1.0)
	return p.y + crown

func _road_point(s: float, u: float, lift := 0.0) -> Vector3:
	var p := pos_at(s) + left_at(s) * u
	p.y = _road_y(s, u) + lift
	return p

func _build_road_and_collision() -> void:
	var road_st := SurfaceTool.new()
	road_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces := PackedVector3Array()
	for i in range(_samples.size() - 1):
		var s0 := minf(float(i) * sample_spacing_m, length_m)
		var s1 := minf(float(i + 1) * sample_spacing_m, length_m)
		var half0 := road_width_at(s0) * 0.5
		var half1 := road_width_at(s1) * 0.5
		var a := _road_point(s0, -half0)
		var b := _road_point(s0, half0)
		var c := _road_point(s1, half1)
		var d := _road_point(s1, -half1)
		_add_quad(road_st, a, b, c, d, Vector2(s0 * 0.25, -half0 * 0.25), Vector2(s1 * 0.25, half1 * 0.25))
		faces.append(a); faces.append(b); faces.append(c)
		faces.append(a); faces.append(c); faces.append(d)
	road_st.generate_normals()
	_road_mesh = MeshInstance3D.new()
	_road_mesh.name = "SaisiesAsphalt"
	_road_mesh.mesh = road_st.commit()
	_road_mesh.material_override = _asphalt_material()
	add_child(_road_mesh)

	var collision_shape := ConcavePolygonShape3D.new()
	collision_shape.set_faces(faces)
	_road_collision = StaticBody3D.new()
	_road_collision.name = "SaisiesRoadCollision"
	var cs := CollisionShape3D.new()
	cs.name = "ContinuousRoadSurface"
	cs.shape = collision_shape
	_road_collision.add_child(cs)
	add_child(_road_collision)

	var mark_st := SurfaceTool.new()
	mark_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dash := 8.0
	var gap := 8.0
	var s := centerline_start_m
	while s < length_m - 1.0:
		var s1 := minf(s + dash, length_m)
		var w := 0.10
		var a0 := _road_point(s, -w, 0.025)
		var b0 := _road_point(s, w, 0.025)
		var a1 := _road_point(s1, -w, 0.025)
		var b1 := _road_point(s1, w, 0.025)
		_add_quad(mark_st, a0, b0, b1, a1, Vector2(s * 0.2, 0.0), Vector2(s1 * 0.2, 1.0))
		s += dash + gap
	mark_st.generate_normals()
	var marks := MeshInstance3D.new()
	marks.name = "CentreDashedMarkings"
	marks.mesh = mark_st.commit()
	marks.material_override = _marking_material()
	add_child(marks)

func _build_terrain() -> void:
	var shoulder_st := SurfaceTool.new()
	shoulder_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var terrain_shoulder_width := maxf(shoulder_width_m - 0.02, 0.10)
	var outer_offsets := [-110.0, -64.0, -34.0, -14.0]
	for i in range(_samples.size() - 1):
		var s0 := minf(float(i) * sample_spacing_m, length_m)
		var s1 := minf(float(i + 1) * sample_spacing_m, length_m)
		var half0 := road_width_at(s0) * 0.5
		var half1 := road_width_at(s1) * 0.5
		# A narrow crushed-stone shoulder bridges the asphalt edge and the
		# grass bank.  Keeping it as its own mesh avoids the blue-grey aerial
		# texture reading as a flat drainage strip beside the road.
		for side in [-1.0, 1.0]:
			var in0: float = side * (half0 + 0.03)
			var out0: float = side * (half0 + shoulder_width_m)
			var in1: float = side * (half1 + 0.03)
			var out1: float = side * (half1 + shoulder_width_m)
			if side < 0.0:
				_add_quad(shoulder_st, _terrain_point(s0, out0), _terrain_point(s0, in0), _terrain_point(s1, in1), _terrain_point(s1, out1), Vector2(0.0, s0 * 0.12), Vector2(1.0, s1 * 0.12))
			else:
				_add_quad(shoulder_st, _terrain_point(s0, in0), _terrain_point(s0, out0), _terrain_point(s1, out1), _terrain_point(s1, in1), Vector2(0.0, s0 * 0.12), Vector2(1.0, s1 * 0.12))
		# Build separate strips on both sides. A single cross-road terrain quad
		# would put sloped grass above the asphalt on banked sections.
		for side in [-1.0, 1.0]:
			var offsets0: Array = outer_offsets.duplicate()
			var offsets1: Array = outer_offsets.duplicate()
			if side < 0.0:
				offsets0.append(-half0 - terrain_shoulder_width)
				offsets1.append(-half1 - terrain_shoulder_width)
			else:
				offsets0 = [half0 + terrain_shoulder_width, 14.0, 34.0, 64.0, 110.0]
				offsets1 = [half1 + terrain_shoulder_width, 14.0, 34.0, 64.0, 110.0]
			for j in range(offsets0.size() - 1):
				var u0: float = float(offsets0[j])
				var u1: float = float(offsets0[j + 1])
				var v0: float = float(offsets1[j])
				var v1: float = float(offsets1[j + 1])
				var a := _terrain_point(s0, u0)
				var b := _terrain_point(s0, u1)
				var c := _terrain_point(s1, v1)
				var d := _terrain_point(s1, v0)
				_add_quad(st, a, b, c, d, Vector2(u0 * 0.04, s0 * 0.035), Vector2(u1 * 0.04, s1 * 0.035))
	st.generate_normals()
	_terrain_mesh = MeshInstance3D.new()
	_terrain_mesh.name = "SaisiesGrassBanks"
	_terrain_mesh.mesh = st.commit()
	_terrain_mesh.material_override = _terrain_material()
	add_child(_terrain_mesh)
	shoulder_st.generate_normals()
	_shoulder_mesh = MeshInstance3D.new()
	_shoulder_mesh.name = "SaisiesGravelShoulders"
	_shoulder_mesh.mesh = shoulder_st.commit()
	_shoulder_mesh.material_override = _shoulder_material()
	add_child(_shoulder_mesh)
	# Draw the road over the terrain ribbon in the scene tree and keep the
	# terrain just below it; the 4.2 m samples overlap the asphalt edge.
	move_child(_terrain_mesh, 0)

func _terrain_point(s: float, u: float) -> Vector3:
	var p := _road_point(s, u)
	var half := road_width_at(s) * 0.5
	var side := 1.0 if u >= 0.0 else -1.0
	var edge_u := half * side
	var dist := maxf(absf(u) - half, 0.0)
	var sec := section_at(s)
	var uphill := _terrain_uphill_factor_at(s)
	var slope := _terrain_base_slope_at(s)
	slope *= _terrain_slope_scale_at(s)
	# `uphill` is allowed to be a continuous blend while crossing an authored
	# bank-side change.  Comparing the interpolated value to `side` would make
	# both banks suddenly use the downhill branch until the blend completed,
	# producing a vertical cross-section step.  Interpolate the uphill and
	# downhill factors from their signed alignment instead.
	var bank_alignment := side * uphill
	var rise_factor := lerpf(-downhill_terrain_factor, 1.0, clampf((bank_alignment + 1.0) * 0.5, 0.0, 1.0))
	var rise := dist * slope * rise_factor
	if village_flatten_radius_m > 0.0:
		# Summit streets sit on a built plateau.  Keep the plateau influence
		# fading through the village-to-meadow boundary as well as across the
		# cross-section, otherwise the first meadow sample exposes a hard bank
		# seam beside the road.
		var plateau_end := maxf(village_flatten_radius_m, half + 0.5)
		var bank_t := smoothstep(plateau_end, plateau_end + 8.0, dist)
		var plateau_rise := lerpf(0.18, rise, bank_t)
		rise = lerpf(rise, plateau_rise, _village_plateau_weight_at(s))
	var near_factor := smoothstep(5.0, 42.0, dist)
	var far_factor := smoothstep(42.0, 110.0, dist)
	var terrain_amplitude := 0.10 + near_factor * 1.55 + far_factor * 1.85
	var noise := _noise.get_noise_2d(s, u) * terrain_amplitude
	p.y = _road_y(s, edge_u) + rise + noise
	return p

func _asphalt_material() -> Material:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/saisies_asphalt.gdshader") as Shader
	m.set_shader_parameter("albedo_tex", load("res://assets/textures/asphalt_02_diff.jpg"))
	m.set_shader_parameter("normal_tex", load("res://assets/textures/asphalt_02_nor.jpg"))
	return m

func _terrain_material() -> Material:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/saisies_terrain.gdshader") as Shader
	m.set_shader_parameter("albedo_tex", load("res://assets/textures/aerial_grass_rock_diff.jpg"))
	m.set_shader_parameter("normal_tex", load("res://assets/textures/aerial_grass_rock_nor.jpg"))
	m.set_shader_parameter("brightness", 1.0)
	return m

func _shoulder_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://assets/textures/gravel_floor_02_diff.jpg")
	m.normal_enabled = true
	m.normal_texture = load("res://assets/textures/gravel_floor_02_nor.jpg")
	m.roughness_texture = load("res://assets/textures/gravel_floor_02_rough.jpg")
	m.albedo_color = shoulder_albedo_tint
	m.roughness = 0.96
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE * 0.42
	return m

func _marking_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.98, 0.98, 0.92)
	m.roughness = 0.62
	return m

func _add_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, uv0: Vector2, uv1: Vector2) -> void:
	st.set_uv(uv0); st.add_vertex(a)
	st.set_uv(Vector2(uv1.x, uv0.y)); st.add_vertex(b)
	st.set_uv(uv1); st.add_vertex(c)
	st.set_uv(uv0); st.add_vertex(a)
	st.set_uv(uv1); st.add_vertex(c)
	st.set_uv(Vector2(uv0.x, uv1.y)); st.add_vertex(d)

func _configured_grade_at(s: float) -> float:
	var sec := section_at(s)
	if sec.has("grade_pct"):
		var g := float(sec["grade_pct"])
		return g * 100.0 if absf(g) < 1.0 else g
	if sec.has("grade"):
		var g2 := float(sec["grade"])
		return g2 * 100.0 if absf(g2) < 1.0 else g2
	return -6.0

func _checkpoint_elevation_at(s: float) -> float:
	if _checkpoints.is_empty():
		return lerpf(start_elevation_m, end_elevation_m, s / maxf(length_m, 1.0))
	if s <= float(_checkpoints[0]["distance_m"]):
		return float(_checkpoints[0]["elevation_m"])
	for i in range(_checkpoints.size() - 1):
		var a: Dictionary = _checkpoints[i]
		var b: Dictionary = _checkpoints[i + 1]
		if s <= float(b["distance_m"]):
			var span := maxf(float(b["distance_m"]) - float(a["distance_m"]), 0.01)
			return lerpf(float(a["elevation_m"]), float(b["elevation_m"]), (s - float(a["distance_m"])) / span)
	return float(_checkpoints.back()["elevation_m"])

func _heading_at(s: float) -> float:
	if _checkpoints.size() < 2:
		# Gentle, broad bends with a few tighter switchbacks in the forest.
		var forest_factor := 1.0 if s > 6200.0 and s < 12800.0 else 0.55
		return 0.11 * sin(s / 310.0) + forest_factor * 0.075 * sin(s / 87.0 + 1.3) + 0.035 * sin(s / 51.0 + 0.7)
	if s <= float(_checkpoints[0]["distance_m"]):
		return deg_to_rad(float(_checkpoints[0]["heading_deg"]))
	for i in range(_checkpoints.size() - 1):
		var a: Dictionary = _checkpoints[i]
		var b: Dictionary = _checkpoints[i + 1]
		if s <= float(b["distance_m"]):
			var span := maxf(float(b["distance_m"]) - float(a["distance_m"]), 0.01)
			var t := (s - float(a["distance_m"])) / span
			return lerp_angle(deg_to_rad(float(a["heading_deg"])), deg_to_rad(float(b["heading_deg"])), smoothstep(0.0, 1.0, t))
	return deg_to_rad(float(_checkpoints.back()["heading_deg"]))

func _sample_index(s: float) -> Dictionary:
	var clamped := clampf(s, 0.0, length_m)
	var f := clamped / maxf(sample_spacing_m, 0.01)
	var i := clampi(int(f), 0, _samples.size() - 1)
	var j := mini(i + 1, _samples.size() - 1)
	return {"i": i, "j": j, "t": f - float(i)}

func pos_at(s: float) -> Vector3:
	if _samples.is_empty():
		return Vector3.ZERO
	var q := _sample_index(s)
	return _samples[q.i].lerp(_samples[q.j], q.t)

func tangent_at(s: float) -> Vector3:
	var q := _sample_index(s)
	var a := Vector3(sin(_headings[q.i]), 0.0, -cos(_headings[q.i]))
	var b := Vector3(sin(_headings[q.j]), 0.0, -cos(_headings[q.j]))
	return a.lerp(b, q.t).normalized()

func left_at(s: float) -> Vector3:
	var f := tangent_at(s)
	return Vector3(f.z, 0.0, -f.x).normalized()

func elevation_at(s: float) -> float:
	if _elevations.is_empty():
		return lerpf(start_elevation_m, end_elevation_m, clampf(s / maxf(length_m, 1.0), 0.0, 1.0))
	var q := _sample_index(s)
	return lerpf(_elevations[q.i], _elevations[q.j], q.t)

func grade_at(s: float) -> float:
	if _grades.is_empty():
		return _configured_grade_at(s)
	var q := _sample_index(s)
	return lerpf(_grades[q.i], _grades[q.j], q.t)

func road_width_at(s: float) -> float:
	var sec := section_at(s)
	return clampf(float(sec.get("road_width_m", road_width_m)), 4.0, 12.0)

func ground_y(s: float, u: float) -> float:
	if absf(u) <= road_width_at(s) * 0.5:
		return _road_y(s, u)
	return _terrain_point(s, u).y

func section_at(s: float) -> Dictionary:
	if _sections.is_empty():
		return {}
	var clamped := clampf(s, 0.0, length_m)
	var result: Dictionary = _sections[0]
	for e in _sections:
		if clamped >= float(e.get("from_m", 0.0)):
			result = e
		if clamped <= float(e.get("to_m", length_m)) and clamped >= float(e.get("from_m", 0.0)):
			break
	return result.duplicate(true)

func landmarks() -> Array:
	return _landmarks.duplicate(true)

func distance_for_position(world_position: Vector3) -> float:
	if _samples.is_empty():
		return 0.0
	var best := 0.0
	var best_dist := INF
	for i in _samples.size():
		var d := world_position.distance_squared_to(_samples[i])
		if d < best_dist:
			best_dist = d
			best = minf(float(i) * sample_spacing_m, length_m)
	return best

func distance_for_video_seconds(video_seconds: float) -> float:
	## Interpolate the authored video-time checkpoints without coupling capture
	## tools to the route's private checkpoint array.
	if _checkpoints.size() < 2:
		return clampf(video_seconds / 920.067 * length_m, 0.0, length_m)
	if video_seconds <= float(_checkpoints[0]["video_seconds"]):
		return float(_checkpoints[0]["distance_m"])
	for i in range(_checkpoints.size() - 1):
		var a: Dictionary = _checkpoints[i]
		var b: Dictionary = _checkpoints[i + 1]
		var ta := float(a.get("video_seconds", 0.0))
		var tb := float(b.get("video_seconds", ta + 1.0))
		if video_seconds <= tb:
			var span := maxf(tb - ta, 0.001)
			return lerpf(float(a["distance_m"]), float(b["distance_m"]), (video_seconds - ta) / span)
	return float(_checkpoints.back()["distance_m"])

func distance_at_video_time(video_seconds: float) -> float:
	## Alias used by scenery modules so they do not need to know checkpoint
	## storage details.
	return distance_for_video_seconds(video_seconds)

func _video_seconds_at_distance(distance: float) -> float:
	if _checkpoints.size() < 2:
		return clampf(distance / maxf(length_m, 1.0) * 920.067, 0.0, 920.067)
	if distance <= float(_checkpoints[0]["distance_m"]):
		return float(_checkpoints[0].get("video_seconds", 0.0))
	for i in range(_checkpoints.size() - 1):
		var a: Dictionary = _checkpoints[i]
		var b: Dictionary = _checkpoints[i + 1]
		var da := float(a["distance_m"])
		var db := float(b["distance_m"])
		if distance <= db:
			var span := maxf(db - da, 0.01)
			return lerpf(float(a.get("video_seconds", 0.0)), float(b.get("video_seconds", 0.0)), (distance - da) / span)
	return float(_checkpoints.back().get("video_seconds", 920.067))

func _terrain_override_at(distance: float) -> Dictionary:
	if _terrain_overrides.is_empty():
		return {}
	var video_seconds := _video_seconds_at_distance(clampf(distance, 0.0, length_m))
	for item in _terrain_overrides:
		if not (item is Dictionary):
			continue
		var override: Dictionary = item
		var from_s := float(override.get("from_video_s", -INF))
		var to_s := float(override.get("to_video_s", INF))
		if video_seconds >= from_s and video_seconds <= to_s:
			return override
	return {}

func _terrain_side_sign_at(distance: float) -> float:
	var clamped := clampf(distance, 0.0, length_m)
	var sec := section_at(clamped)
	var override := _terrain_override_at(clamped)
	var uphill_side := String(override.get("uphill_side", sec.get("uphill_side", "right")))
	return 1.0 if uphill_side == "left" else -1.0

func _terrain_slope_scale_raw_at(distance: float) -> float:
	return 0.25 if bool(_terrain_override_at(distance).get("flatten", false)) else 1.0

func _terrain_section_slope_raw_at(distance: float) -> float:
	var sec := section_at(distance)
	match String(sec.get("biome", "meadow")):
		"retaining_wall", "rock_cut":
			return 0.50
		"forest":
			return 0.40
		"village", "hamlet":
			return 0.18
		_:
			return 0.22

func _village_plateau_weight_at(distance: float) -> float:
	var village_end := -1.0
	for section in _sections:
		if section is Dictionary and String(section.get("biome", "")) == "village":
			village_end = maxf(village_end, float(section.get("to_m", -1.0)))
	if village_end < 0.0:
		return 0.0
	return 1.0 - smoothstep(village_end - TERRAIN_TRANSITION_WIDTH_M, village_end + TERRAIN_TRANSITION_WIDTH_M, distance)

func _terrain_base_slope_at(distance: float) -> float:
	# Section biome changes also alter the bank slope. Blend those changes over
	# the same short transition window so a meadow-to-wall boundary cannot form
	# a five-metre vertical end face beside the road.
	var result := _terrain_section_slope_raw_at(distance)
	for section in _sections:
		if not (section is Dictionary) or not section.has("from_m"):
			continue
		var boundary := float(section["from_m"])
		if absf(distance - boundary) >= TERRAIN_TRANSITION_WIDTH_M:
			continue
		var before := _terrain_section_slope_raw_at(boundary - 0.5)
		var after := _terrain_section_slope_raw_at(boundary + 0.5)
		if absf(after - before) < 0.001:
			continue
		var t := smoothstep(-TERRAIN_TRANSITION_WIDTH_M, TERRAIN_TRANSITION_WIDTH_M, distance - boundary)
		result = lerpf(before, after, t)
	return result

func _terrain_transition_boundaries() -> Array[float]:
	if _terrain_boundaries_ready:
		return _terrain_boundary_distances
	_terrain_boundary_distances.clear()
	for item in _terrain_overrides:
		if item is Dictionary and item.has("from_video_s"):
			_terrain_boundary_distances.append(distance_for_video_seconds(float(item["from_video_s"])))
			if item.has("to_video_s"):
				_terrain_boundary_distances.append(distance_for_video_seconds(float(item["to_video_s"])))
	for section in _sections:
		if section is Dictionary and section.has("from_m"):
			_terrain_boundary_distances.append(float(section["from_m"]))
	_terrain_boundaries_ready = true
	return _terrain_boundary_distances

func _terrain_uphill_factor_at(distance: float) -> float:
	var result := _terrain_side_sign_at(distance)
	for boundary in _terrain_transition_boundaries():
		# Only blend while crossing this boundary.  Without the distance gate,
		# every later boundary overwrites the local side choice even when it is
		# kilometres away, which creates the wrong bank (and vertical terrain
		# faces) in otherwise stable sections.
		if absf(distance - boundary) >= TERRAIN_TRANSITION_WIDTH_M:
			continue
		var before := _terrain_side_sign_at(boundary - 0.5)
		var after := _terrain_side_sign_at(boundary + 0.5)
		if absf(after - before) < 0.01:
			continue
		var t := smoothstep(-TERRAIN_TRANSITION_WIDTH_M, TERRAIN_TRANSITION_WIDTH_M, distance - boundary)
		result = lerpf(before, after, t)
	return result

func _terrain_slope_scale_at(distance: float) -> float:
	var result := _terrain_slope_scale_raw_at(distance)
	for boundary in _terrain_transition_boundaries():
		if absf(distance - boundary) >= TERRAIN_TRANSITION_WIDTH_M:
			continue
		var before := _terrain_slope_scale_raw_at(boundary - 0.5)
		var after := _terrain_slope_scale_raw_at(boundary + 0.5)
		if absf(after - before) < 0.01:
			continue
		var t := smoothstep(-TERRAIN_TRANSITION_WIDTH_M, TERRAIN_TRANSITION_WIDTH_M, distance - boundary)
		result = lerpf(before, after, t)
	return result

func world_at(distance_m: float, lateral_m := 0.0, height_offset_m := 0.0) -> Vector3:
	## Resolve a route-local anchor onto the continuous road/terrain world.
	var distance := clampf(distance_m, 0.0, length_m)
	var point := pos_at(distance) + left_at(distance) * lateral_m
	point.y = ground_y(distance, lateral_m) + height_offset_m
	return point

func acceptance_distance(scene_id: String) -> float:
	## Shared deterministic scene-id contract for fixed reference captures.
	if FileAccess.file_exists(SCENE_MAP_FILE):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(SCENE_MAP_FILE))
		if parsed is Dictionary:
			for item in parsed.get("scenes", []):
				if item is Dictionary and String(item.get("scene_id", "")) == scene_id:
					if item.has("distance_m"):
						return clampf(float(item["distance_m"]), 0.0, length_m)
					return distance_for_video_seconds(float(item.get("video_seconds", 0.0)))
	return distance_for_video_seconds(0.0)

func acceptance_pose(scene_id: String) -> Dictionary:
	## Scene-specific source-camera calibration shared by capture and preview.
	## Values are artistic viewpoint offsets, not a claim of calibrated footage.
	var pose := {"pitch_deg": -8.0, "yaw_deg": 0.0}
	if not FileAccess.file_exists(SCENE_MAP_FILE):
		return pose
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SCENE_MAP_FILE))
	if not (parsed is Dictionary):
		return pose
	for item in parsed.get("scenes", []):
		if item is Dictionary and String(item.get("scene_id", "")) == scene_id:
			pose["pitch_deg"] = float(item.get("acceptance_pitch_deg", pose["pitch_deg"]))
			pose["yaw_deg"] = float(item.get("acceptance_yaw_deg", pose["yaw_deg"]))
			break
	return pose

func route_ready() -> bool:
	return _ready_built and _samples.size() >= 2 and _road_collision != null
