extends Node3D
# Lakeside furniture along the Route (Lake Garda look), styled per scene section (Route.section_at, from the route's
# sections_file; without one: railing + intermittent wall everywhere). Lake (seaward) edge styles:
#   rail           curved steel posts, round top rail, steel-rope mesh infill (cliff boardwalk / roadside path)
#   parapet_fence  stone parapet with a green metal fence on top (olive terraces)
#   lowwall        low dry-stone wall (lanes)
#   blackrail      black metal railing with vertical bars (lanes above the lake)
#   chainlink      (inland) low dry-stone wall with a green chain-link fence (olive groves)
#   wall           retaining wall as tall as the inland one (walled alleys)
#   parapet_lamps  low stone parapet and harbour lamps
#   harbour        quay wall into the water, kerb + lamps, flower beds, benches, a pier with pontoon and mooring piles
#   houses         pastel village houses with shuttered windows
# Inland edge styles: wall (dry-stone retaining wall), cliffwall (wall with gaps of bare cliff), guardrail (green
# guardrail between path and the roadside car lane, retaining wall beyond the road), houses.
# Built once in chunk_m pieces (children of this node, so tools/export_unity.gd tiles them like other props).

@export var path_node: NodePath
@export var chunk_m := 100.0
@export var post_step := 1.6
@export var rail_h := 1.15
@export var lean := 0.2                    # how far the posts bow out over the water at the top (m)
@export var wall_h := Vector2(0.5, 1.4)    # cliffwall height range (m)
@export var lane_wall_h := Vector2(1.2, 2.6)  # "wall" / roadside retaining wall height range (m)
@export var wall_gap := 0.1               # cliffwall: noise threshold below which there is no wall (bare cliff / scrub)
@export var parapet_every := 5             # no sections file: 1 chunk in N has a stone parapet instead of the railing
@export var house_floors := Vector2i(2, 4)
@export var view_distance := 400.0
@export var random_seed := 3

const HOUSE_COLOURS: Array[Color] = [Color(0.86, 0.66, 0.38), Color(0.92, 0.86, 0.72), Color(0.88, 0.6, 0.5),
		Color(0.95, 0.84, 0.55), Color(0.93, 0.92, 0.88), Color(0.9, 0.7, 0.66)]
const GREEN := Color(0.12, 0.3, 0.2)

var _route: Route
var _noise := FastNoiseLite.new()
var _steel := StandardMaterial3D.new()
var _stone := StandardMaterial3D.new()
var _rubble := StandardMaterial3D.new()  # tall mortared rubble walls (Limone lanes, retaining walls)
var _chain := StandardMaterial3D.new()   # green chain-link fence (olive groves)
var _bars := StandardMaterial3D.new()    # vertical bars of the black lane railings
var _net := StandardMaterial3D.new()
var _paint := StandardMaterial3D.new()    # vertex-coloured: fences, guardrails, lamps, windows, shutters, doors
var _plaster := StandardMaterial3D.new()  # vertex-coloured house walls and stone trims
var _roof := StandardMaterial3D.new()
var _glass := StandardMaterial3D.new()
var _wood := StandardMaterial3D.new()
var _shutter := StandardMaterial3D.new()  # vertex-coloured slatted shutters
var _awning := StandardMaterial3D.new()   # vertex-coloured striped canvas
var _concrete := StandardMaterial3D.new()  # pier, pontoon
var _post: Mesh

func _ready() -> void:
	_route = get_node(path_node)
	_noise.seed = random_seed
	_steel.albedo_color = Color(0.72, 0.74, 0.76)
	_steel.metallic = 0.75
	_steel.roughness = 0.35
	_steel.cull_mode = BaseMaterial3D.CULL_DISABLED
	_stone.albedo_texture = _grey("stacked_stone_wall")  # the source stones are orange; Limone walls are grey-beige limestone
	_stone.albedo_color = Color(1.35, 1.28, 1.15)
	_stone.normal_enabled = true
	_stone.normal_texture = load("res://assets/textures/stacked_stone_wall_nor.jpg")
	_stone.normal_scale = 1.0
	_stone.roughness = 0.95
	_stone.cull_mode = BaseMaterial3D.CULL_DISABLED
	_stone.uv1_scale = Vector3.ONE * 0.6
	_stone.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC  # walls are seen at grazing angles
	_pbr(_rubble, "old_stone_wall", 0.4)
	_rubble.albedo_texture = _desat("old_stone_wall", 0.4)  # the scan is ochre; Limone's walls are grey-beige
	_rubble.cull_mode = BaseMaterial3D.CULL_DISABLED
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)  # diamond steel-rope mesh, one cell per 32 px
	for y in 64:
		for x in 64:
			var on := posmod(x + y, 32) < 2 or posmod(x - y, 32) < 2
			img.set_pixel(x, y, Color(0.8, 0.82, 0.84, 0.5 if on else 0.0))
	img.generate_mipmaps()  # far away the mesh averages out to a faint grey veil, like the real thing
	_net.albedo_texture = ImageTexture.create_from_image(img)
	_net.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_chain = _net.duplicate()
	_chain.albedo_color = Color(0.2, 0.6, 0.3)
	_chain.uv1_scale = Vector3(8, 8, 1)  # ~6 cm cells (the railing mesh cells are 50 cm)
	var bars := Image.create(16, 4, false, Image.FORMAT_RGBA8)  # one 2 px bar per 16 px; UV x in metres x 8 -> 12.5 cm apart
	for y in 4:
		for x in 16:
			bars.set_pixel(x, y, Color(0.05, 0.05, 0.05, 1.0 if x < 2 else 0.0))
	bars.generate_mipmaps()
	_bars.albedo_texture = ImageTexture.create_from_image(bars)
	_bars.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	_bars.alpha_scissor_threshold = 0.5
	_bars.uv1_scale = Vector3(8, 1, 1)
	_bars.cull_mode = BaseMaterial3D.CULL_DISABLED
	_bars.metallic = 0.5
	_bars.roughness = 0.5
	_net.cull_mode = BaseMaterial3D.CULL_DISABLED
	_net.metallic = 0.6
	_net.roughness = 0.4
	_net.uv1_scale = Vector3(1.0 / 0.14, 1.0 / 0.14, 1.0)  # 7 cm diamonds
	_paint.vertex_color_use_as_albedo = true
	_paint.roughness = 0.55
	_paint.cull_mode = BaseMaterial3D.CULL_DISABLED
	_pbr(_plaster, "painted_plaster_wall", 1.0 / 2.5)
	_plaster.vertex_color_use_as_albedo = true
	_plaster.albedo_color = Color(1.25, 1.25, 1.25)  # the scan is a light grey; vertex colours tint each house
	_pbr(_roof, "clay_roof_tiles_02", 1.0 / 2.0)
	_pbr(_wood, "brown_planks_09", 1.0 / 1.2)
	_wood.albedo_color = Color(0.75, 0.6, 0.45)
	_glass.albedo_color = Color(0.04, 0.05, 0.06)
	_glass.roughness = 0.06
	_glass.metallic_specular = 0.8
	var slats := Image.create(4, 32, true, Image.FORMAT_RGB8)  # louvre slats: light top edge, shadowed underside
	for y in 32:
		var v := 0.55 + 0.45 * smoothstep(0.0, 1.0, 1.0 - float(y % 8) / 7.0)
		for x2 in 4:
			slats.set_pixel(x2, y, Color(v, v, v))
	slats.generate_mipmaps()
	_shutter.albedo_texture = ImageTexture.create_from_image(slats)
	_shutter.vertex_color_use_as_albedo = true
	_shutter.uv1_scale = Vector3(1.0, 1.0 / 0.32, 1.0)  # 8 cm slats
	_shutter.roughness = 0.6
	_shutter.cull_mode = BaseMaterial3D.CULL_DISABLED
	var weave := Image.create(8, 8, true, Image.FORMAT_RGB8)  # canvas: faint vertical seams every 0.5 m
	for x2 in 8:
		for y in 8:
			weave.set_pixel(x2, y, Color(0.82, 0.82, 0.82) if x2 == 0 else Color(1, 1, 1))
	weave.generate_mipmaps()
	_awning.albedo_texture = ImageTexture.create_from_image(weave)
	_awning.vertex_color_use_as_albedo = true
	_awning.uv1_scale = Vector3(2.0, 2.0, 1.0)
	_awning.roughness = 0.9
	_awning.cull_mode = BaseMaterial3D.CULL_DISABLED
	_post = _make_post()
	_pbr(_concrete, "concrete_pavement", 1.0 / 3.0)
	_find_piers()
	for c in ceili(_route.length / chunk_m):
		_chunk(c)

func _pbr(m: StandardMaterial3D, tex: String, uv_per_m: float) -> void:
	m.albedo_texture = load("res://assets/textures/%s_diff.jpg" % tex)
	m.roughness_texture = load("res://assets/textures/%s_rough.jpg" % tex)
	m.normal_enabled = true
	m.normal_texture = load("res://assets/textures/%s_nor.jpg" % tex)
	m.uv1_scale = Vector3(uv_per_m, uv_per_m, 1.0)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

func _desat(tex: String, saturation: float) -> Texture2D:
	var img := (load("res://assets/textures/%s_diff.jpg" % tex) as Texture2D).get_image()
	img.decompress()
	img.convert(Image.FORMAT_RGB8)
	img.adjust_bcs(1.0, 1.0, saturation)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _grey(tex: String) -> Texture2D:
	var src := (load("res://assets/textures/%s_diff.jpg" % tex) as Texture2D).get_image()
	src.decompress()
	src.convert(Image.FORMAT_L8)
	src.generate_mipmaps()
	return ImageTexture.create_from_image(src)

# edge styles at route offset s: [lake, inland]
func _styles(s: float, chunk: int) -> Array:
	var sec := _route.section_at(s)
	if sec.is_empty():
		var parapet := parapet_every > 0 and (chunk + random_seed) % parapet_every == 0
		return ["lowwall" if parapet else "rail", "cliffwall"]
	return [sec["lake"], sec["inland"]]

func _chunk(c: int) -> void:
	var s0 := c * chunk_m
	var s1 := minf(s0 + chunk_m, _route.length)
	var holder := Node3D.new()
	holder.name = "boardwalk_%03d" % c
	holder.position = _route.pos_at((s0 + s1) * 0.5)
	add_child(holder)
	var o := holder.position
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed * 7919 + c
	var sts := {}
	for k in ["rails", "net", "chain", "bars", "stone", "rubble", "paint", "plaster", "roof", "glass", "wood", "shutter", "awning", "concrete"]:
		sts[k] = SurfaceTool.new()
		sts[k].begin(Mesh.PRIMITIVE_TRIANGLES)
	var rails: SurfaceTool = sts["rails"]
	var stone: SurfaceTool = sts["stone"]
	var rubble: SurfaceTool = sts["rubble"]
	var paint: SurfaceTool = sts["paint"]
	var top := PackedVector3Array()  # current run of top rail points
	var steps := maxi(int((s1 - s0) / 2.0), 1)
	for k in steps:
		var sp := lerpf(s0, s1, float(k) / steps)
		var s := lerpf(s0, s1, float(k + 1) / steps)
		var st := _styles((sp + s) * 0.5, c)
		var wh := _wall_h((sp + s) * 0.5)
		var pp := _route.pos_at(sp)
		var p := _route.pos_at(s)
		var lp := _route.left_at(sp)
		var l := _route.left_at(s)
		var ulp := _route.half_left(sp)
		var ul := _route.half_left(s)
		var prp := _route.path_right(sp)
		var pr := _route.path_right(s)
		var hrp := _route.half_right(sp)
		var hr := _route.half_right(s)
		# --- lake edge
		if st[0] == "rail":
			if top.is_empty():
				top.append(pp + lp * (ulp + lean) + Vector3(0, rail_h, 0) - o)
			top.append(p + l * (ul + lean) + Vector3(0, rail_h, 0) - o)
			# deck edge fascia: reads as a cantilevered deck, not a road on the ground
			_quad(rails, pp + lp * ulp + Vector3(0, -0.45, 0) - o, p + l * ul + Vector3(0, -0.45, 0) - o, p + l * ul - o, pp + lp * ulp - o)
			var a := pp + lp * ulp + Vector3(0, 0.06, 0) - o
			var b := p + l * ul + Vector3(0, 0.06, 0) - o
			var a2 := pp + lp * (ulp + lean * 0.9) + Vector3(0, rail_h - 0.06, 0) - o
			var b2 := p + l * (ul + lean * 0.9) + Vector3(0, rail_h - 0.06, 0) - o
			var net: SurfaceTool = sts["net"]
			net.set_normal((b - a).cross(a2 - a).normalized())
			for v in [[a, sp, 0.06], [b, s, 0.06], [b2, s, rail_h], [a, sp, 0.06], [b2, s, rail_h], [a2, sp, rail_h]]:
				net.set_uv(Vector2(v[1], v[2]))
				net.add_vertex(v[0])
		else:
			_flush_rail(rails, top)
			match st[0]:
				"harbour":
					_harbour_step(sts, sp, s, o)
				"parapet_fence":
					_wall(stone, sp, s, pp, p, lp, l, ulp + 0.4, ul + 0.4, ulp, ul, 0.8, 0.8, o)
					_fence(paint, pp, p, lp, l, ulp + 0.2, ul + 0.2, 0.8, o)
				"lowwall":
					_wall(stone, sp, s, pp, p, lp, l, ulp + 0.45, ul + 0.45, ulp, ul, 1.0, 1.0, o)
				"blackrail":  # black metal railing with vertical bars (lanes above the lake)
					_blackrail(sts, pp, p, lp, l, ulp + 0.05, ul + 0.05, sp, s, o)
				"wall":  # walled alley: retaining wall on the lake side too, the lake out of sight
					_wall(rubble, sp, s, pp, p, lp, l, ulp + 0.6, ul + 0.6, ulp, ul, _height(sp + 977.0, wh, -1.0), _height(s + 977.0, wh, -1.0), o)
				"parapet_lamps":
					_wall(stone, sp, s, pp, p, lp, l, ulp + 0.4, ul + 0.4, ulp, ul, 0.55, 0.55, o)
					if posmod(int(s), 16) < 2:
						_lamp(paint, p + l * (ul + 0.2) - o)
		# --- inland edge
		match st[1]:
			"wall":
				_wall(rubble, sp, s, pp, p, lp, l, -hrp - 0.6, -hr - 0.6, -hrp, -hr, _height(sp, wh, -1.0), _height(s, wh, -1.0), o)
			"cliffwall":
				var h0 := _height(sp, wall_h, wall_gap)
				var h1 := _height(s, wall_h, wall_gap)
				if h0 > 0.0 and h1 > 0.0:
					_wall(rubble, sp, s, pp, p, lp, l, -hrp - 0.6, -hr - 0.6, -hrp, -hr, h0, h1, o)
			"guardrail":
				_guardrail(paint, pp, p, lp, l, -prp - 0.15, -pr - 0.15, o)
				_wall(rubble, sp, s, pp, p, lp, l, -hrp - 0.6, -hr - 0.6, -hrp, -hr, _height(sp, wh, -1.0), _height(s, wh, -1.0), o)
			"chainlink":  # low dry-stone wall with a green chain-link fence on top, grass slope beyond
				_wall(stone, sp, s, pp, p, lp, l, -hrp - 0.5, -hr - 0.5, -hrp, -hr, 0.5, 0.5, o)
				_chainlink(sts, pp, p, lp, l, -hrp - 0.25, -hr - 0.25, 0.5, sp, s, o)
	_flush_rail(rails, top)
	_posts(holder, c, s0, s1, o)
	var props := {}
	for side in [1.0, -1.0]:
		_houses(sts, rng, c, s0, s1, side, o, props)
	_harbour_chunk(sts, rng, c, s0, s1, o, props, holder)
	_commit_props(holder, props)
	var rocks := {}
	_cliff_rocks(rng, s0, s1, o, rocks)
	_commit_props(holder, rocks, 450.0)
	_commit(holder, rails, _steel)
	_commit(holder, sts["net"], _net, false)
	_commit(holder, stone, _stone)
	_commit(holder, rubble, _rubble)
	_commit(holder, sts["chain"], _chain, false)
	_commit(holder, sts["bars"], _bars, false)
	_commit(holder, paint, _paint)
	_commit(holder, sts["plaster"], _plaster)
	_commit(holder, sts["roof"], _roof)
	_commit(holder, sts["glass"], _glass)
	_commit(holder, sts["wood"], _wood)
	_commit(holder, sts["shutter"], _shutter)
	_commit(holder, sts["awning"], _awning)
	_commit(holder, sts["concrete"], _concrete)

func _flush_rail(rails: SurfaceTool, top: PackedVector3Array) -> void:
	if top.size() > 1:
		_tube(rails, top, 0.045, 8)
	top.clear()

func _posts(holder: Node3D, c: int, s0: float, s1: float, o: Vector3) -> void:
	var xf: Array[Transform3D] = []
	var s := s0 + post_step * 0.5
	while s < s1:
		if _styles(s, c)[0] == "rail":
			var l := _route.left_at(s)
			xf.append(Transform3D(Basis(l, Vector3.UP, l.cross(Vector3.UP)), _route.pos_at(s) + l * _route.half_left(s) - o))
		s += post_step
	if xf.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _post
	mm.instance_count = xf.size()
	for k in xf.size():
		mm.set_instance_transform(k, xf[k])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.visibility_range_end = view_distance
	holder.add_child(mmi)

# tall-wall height range at s: the section's "wall_h" [min, max] (m), else lane_wall_h
func _wall_h(s: float) -> Vector2:
	var h: Variant = _route.section_at(s).get("wall_h", null)
	return Vector2(h[0], h[1]) if h != null else lane_wall_h

# chain-link fence 1.6 m tall standing h above the path: green posts every ~2.5 m and the mesh between them
func _chainlink(sts: Dictionary, pa: Vector3, pb: Vector3, la: Vector3, lb: Vector3, ua: float, ub: float, h: float, sa: float, sb: float, o: Vector3) -> void:
	var a := pa + la * ua - o + Vector3(0, h, 0)
	var b := pb + lb * ub - o + Vector3(0, h, 0)
	var paint: SurfaceTool = sts["paint"]
	paint.set_color(GREEN)
	if posmod(int(sb), 5) < 2:
		_tube(paint, PackedVector3Array([b, b + Vector3(0, 1.65, 0)]), 0.025, 4)
	var net: SurfaceTool = sts["chain"]
	var top := Vector3(0, 1.6, 0)
	net.set_normal((b - a).cross(top).normalized())
	for v in [[a, sa, 0.0], [b, sb, 0.0], [b + top, sb, 1.6], [a, sa, 0.0], [b + top, sb, 1.6], [a + top, sa, 1.6]]:  # UV in metres, like the railing mesh
		net.set_uv(Vector2(v[1], v[2]))
		net.add_vertex(v[0])

# black lane railing 1 m tall: posts every ~2 m, top and bottom rail, vertical bars between (alpha-scissor quad)
func _blackrail(sts: Dictionary, pa: Vector3, pb: Vector3, la: Vector3, lb: Vector3, ua: float, ub: float, sa: float, sb: float, o: Vector3) -> void:
	var a := pa + la * ua - o
	var b := pb + lb * ub - o
	var paint: SurfaceTool = sts["paint"]
	paint.set_color(Color(0.05, 0.05, 0.05))
	_tube(paint, PackedVector3Array([b, b + Vector3(0, 1.0, 0)]), 0.025, 4)
	for y in [0.1, 1.0]:
		_tube(paint, PackedVector3Array([a + Vector3(0, y, 0), b + Vector3(0, y, 0)]), 0.02, 4)
	var bars: SurfaceTool = sts["bars"]
	var lo := Vector3(0, 0.1, 0)
	var hi := Vector3(0, 1.0, 0)
	bars.set_normal((b - a).cross(Vector3.UP).normalized())
	for v in [[a + lo, sa, 0.0], [b + lo, sb, 0.0], [b + hi, sb, 1.0], [a + lo, sa, 0.0], [b + hi, sb, 1.0], [a + hi, sa, 1.0]]:
		bars.set_uv(Vector2(v[1], v[2]))
		bars.add_vertex(v[0])

# height of a wall at s within range h; with a gap threshold > -1, below it there is no wall (0)
func _height(s: float, h: Vector2, gap: float) -> float:
	var n := _noise.get_noise_1d(s * 0.012)
	if gap <= -1.0:
		return lerpf(h.x, h.y, clampf(0.5 + 0.8 * n, 0.0, 1.0))
	return 0.0 if n < gap else lerpf(h.x, h.y, clampf((n - gap) * 2.5, 0.0, 1.0))

# wall from route offset a to b: face at lateral u_face*, back at u_back*, h_a/h_b tall above the path
func _wall(st: SurfaceTool, sa: float, sb: float, pa: Vector3, pb: Vector3, la: Vector3, lb: Vector3, ub_a: float, ub_b: float, uf_a: float, uf_b: float, h_a: float, h_b: float, o: Vector3) -> void:
	var down := Vector3(0, -0.6, 0)
	var fa := pa + la * uf_a - o
	var fb := pb + lb * uf_b - o
	var ba := pa + la * ub_a - o
	var bb := pb + lb * ub_b - o
	var ua := Vector3(0, h_a, 0)
	var ub := Vector3(0, h_b, 0)
	var ya := pa.y - o.y
	var yb := pb.y - o.y
	# UV = (along the route, height) in metres: stone courses stay level through bends
	_quad(st, fa + down, fb + down, fb + ub, fa + ua, [Vector2(sa, ya - 0.6), Vector2(sb, yb - 0.6), Vector2(sb, yb + h_b), Vector2(sa, ya + h_a)])  # face
	_quad(st, fa + ua, fb + ub, bb + ub, ba + ua, [Vector2(sa, 0), Vector2(sb, 0), Vector2(sb, 0.6), Vector2(sa, 0.6)])  # top cap
	_quad(st, bb + down, ba + down, ba + ua, bb + ub, [Vector2(sb, ya - 0.6), Vector2(sa, ya - 0.6), Vector2(sa, ya + h_a), Vector2(sb, yb + h_b)])  # back

# green metal fence standing on a parapet h tall: posts every 2 m, two rails
func _fence(st: SurfaceTool, pa: Vector3, pb: Vector3, la: Vector3, lb: Vector3, ua: float, ub: float, h: float, o: Vector3) -> void:
	st.set_color(GREEN)
	var a := pa + la * ua - o + Vector3(0, h, 0)
	var b := pb + lb * ub - o + Vector3(0, h, 0)
	_tube(st, PackedVector3Array([a, a + Vector3(0, 0.9, 0)]), 0.03, 4)
	for y in [0.45, 0.88]:
		_tube(st, PackedVector3Array([a + Vector3(0, y, 0), b + Vector3(0, y, 0)]), 0.022, 4)

# road guardrail (green W-beam on posts) between the path and the car lane
func _guardrail(st: SurfaceTool, pa: Vector3, pb: Vector3, la: Vector3, lb: Vector3, ua: float, ub: float, o: Vector3) -> void:
	st.set_color(GREEN)
	var a := pa + la * ua - o
	var b := pb + lb * ub - o
	_quad(st, a + Vector3(0, 0.45, 0), b + Vector3(0, 0.45, 0), b + Vector3(0, 0.78, 0), a + Vector3(0, 0.78, 0))
	_tube(st, PackedVector3Array([a - la * 0.12 + Vector3(0, -0.2, 0), a - la * 0.12 + Vector3(0, 0.8, 0)]), 0.05, 4)

func _lamp(st: SurfaceTool, base: Vector3) -> void:  # harbour lamp: dark pole with a lantern
	st.set_color(Color(0.08, 0.1, 0.09))
	_tube(st, PackedVector3Array([base, base + Vector3(0, 3.6, 0)]), 0.06, 6)
	_tube(st, PackedVector3Array([base + Vector3(0, 3.6, 0), base + Vector3(0, 4.1, 0)]), 0.2, 6)

# Village houses along one side (1 = lake, -1 = inland) wherever that side's style is "houses". Each house is built in
# a local facade frame (x along the street, y up from the street, z out of the facade toward the path):
# plaster wall cut around real window / door openings (reveals, stone surrounds, sills, glass), open slatted shutters,
# balconies with iron railings, stone plinth, string courses, eave cornice, gutter + downpipe, pitched coppi-tile roof
# with gable ends and chimney, shop fronts with striped awnings, ground-darkened plaster, and CC0 props
# (window planters, potted plants, wall lanterns, cafe tables on the promenade).
func _houses(sts: Dictionary, rng: RandomNumberGenerator, c: int, s0: float, s1: float, side: float, o: Vector3, props: Dictionary) -> void:
	var s := s0
	while s < s1 - 3.0:
		var e := minf(s + rng.randf_range(6.5, 11.0), s1)
		var sec := _route.section_at((s + e) * 0.5)
		if _styles((s + e) * 0.5, c)[0 if side > 0.0 else 1] != "houses" or e - s < 3.0:
			s = e
			continue
		var ua := (_route.half_left(s) if side > 0.0 else _route.half_right(s)) + 0.05
		var ub := (_route.half_left(e) if side > 0.0 else _route.half_right(e)) + 0.05
		var la := _route.left_at(s) * side
		var lb := _route.left_at(e) * side
		var fa := _route.pos_at(s) + la * ua - o
		var fb := _route.pos_at(e) + lb * ub - o
		var x := Vector3(fb.x - fa.x, 0.0, fb.z - fa.z)
		var w := x.length()
		var n := -(la + lb)
		n.y = 0.0
		_f0 = Vector3(fa.x, minf(fa.y, fb.y), fa.z)
		_fx = x / w
		_fn = n.normalized()
		_house(sts, rng, w, props, sec.get("name", "") == "promenade" and side < 0.0)
		s = e

var _f0 := Vector3.ZERO   # facade frame of the house being built (chunk-local)
var _fx := Vector3.RIGHT
var _fn := Vector3.BACK

func _fp(p: Vector3) -> Vector3:  # facade-local (x, y, z) -> chunk-local
	return _f0 + _fx * p.x + Vector3.UP * p.y + _fn * p.z

# prop transform: model +Z faces out of the facade. x = up x z keeps the basis right-handed whichever side the lake
# is on (a mirrored basis would flip the props' winding).
func _fxf(p: Vector3, yaw := 0.0) -> Transform3D:
	var b := Basis(Vector3.UP.cross(_fn), Vector3.UP, _fn)
	return Transform3D(b.rotated(Vector3.UP, yaw) if yaw != 0.0 else b, _fp(p))

# quad in facade space; uv in metres (scaled by the material); col.a > 0 sets vertex colour (weather: darker near the ground)
func _fquad(st: SurfaceTool, q: Array, nrm: Vector3, uv: Array, col := Color(0, 0, 0, 0), weather := false) -> void:
	st.set_normal(_fx * nrm.x + Vector3.UP * nrm.y + _fn * nrm.z)
	for k in [0, 1, 2, 0, 2, 3]:
		if col.a > 0.0:
			var p: Vector3 = q[k]
			st.set_color(col * lerpf(0.68, 1.0, smoothstep(-0.3, 2.4, p.y)) if weather else col)
		if not uv.is_empty():
			st.set_uv(uv[k])
		st.add_vertex(_fp(q[k]))

# axis-aligned box in facade space (a = min corner, b = max corner); the -z face is skipped (it is against the wall)
func _fbox(st: SurfaceTool, a: Vector3, b: Vector3, col := Color(0, 0, 0, 0), with_uv := true) -> void:
	var f := [  # [corners, normal, uv axes]
		[[Vector3(a.x, a.y, b.z), Vector3(b.x, a.y, b.z), Vector3(b.x, b.y, b.z), Vector3(a.x, b.y, b.z)], Vector3(0, 0, 1), Vector2i(0, 1)],
		[[Vector3(a.x, b.y, a.z), Vector3(a.x, b.y, b.z), Vector3(b.x, b.y, b.z), Vector3(b.x, b.y, a.z)], Vector3(0, 1, 0), Vector2i(0, 2)],
		[[Vector3(a.x, a.y, a.z), Vector3(b.x, a.y, a.z), Vector3(b.x, a.y, b.z), Vector3(a.x, a.y, b.z)], Vector3(0, -1, 0), Vector2i(0, 2)],
		[[Vector3(a.x, a.y, a.z), Vector3(a.x, a.y, b.z), Vector3(a.x, b.y, b.z), Vector3(a.x, b.y, a.z)], Vector3(-1, 0, 0), Vector2i(2, 1)],
		[[Vector3(b.x, a.y, b.z), Vector3(b.x, a.y, a.z), Vector3(b.x, b.y, a.z), Vector3(b.x, b.y, b.z)], Vector3(1, 0, 0), Vector2i(2, 1)],
	]
	for face in f:
		var uv := []
		if with_uv:
			for p: Vector3 in face[0]:
				uv.append(Vector2(p[face[2].x], p[face[2].y]))
		_fquad(st, face[0], face[1], uv, col)

func _house(sts: Dictionary, rng: RandomNumberGenerator, w: float, props: Dictionary, cafe: bool) -> void:
	var plaster: SurfaceTool = sts["plaster"]
	var paint: SurfaceTool = sts["paint"]
	var floors := rng.randi_range(house_floors.x, house_floors.y)
	var gf := 3.4                       # ground floor height
	var fh := 3.1                       # upper floor height
	var h := gf + (floors - 1) * fh + 0.5
	var depth := 9.0
	var base := HOUSE_COLOURS[rng.randi() % HOUSE_COLOURS.size()] * rng.randf_range(0.92, 1.05)
	var trim := Color(0.93, 0.91, 0.86)
	var shutter: Color = [GREEN, Color(0.33, 0.2, 0.12), Color(0.45, 0.5, 0.45), Color(0.22, 0.32, 0.42)][rng.randi() % 4]
	var shop := rng.randf() < 0.45
	var cols := maxi(int((w - 0.8) / 2.7), 1)
	var holes: Array[Rect2] = []
	var windows := []   # [rect, floor, balcony]
	# ground floor: a shop front (wide glass + awning) or a wooden door and barred windows
	for k in cols:
		var cx := (k + 0.5) * w / cols
		var door := shop or k == cols / 2
		var r := Rect2(cx - (1.1 if shop else 0.6), 0.0, 2.2 if shop else 1.2, 2.7 if shop else 2.4) if door else Rect2(cx - 0.45, 1.0, 0.9, 1.2)
		holes.append(r)
		windows.append([r, 0, false, door])
	for f in range(1, floors):
		var balcony_row := rng.randf() < 0.35
		for k in cols:
			var cx := (k + 0.5) * w / cols
			var y0 := gf + (f - 1) * fh + 0.85
			var bal := balcony_row and rng.randf() < 0.7
			var r := Rect2(cx - 0.5, y0 - (0.75 if bal else 0.0), 1.0, 1.55 + (0.75 if bal else 0.0))
			holes.append(r)
			windows.append([r, f, bal, false])
	# --- facade wall: grid cells between all opening edges, skipping the openings
	var xs := [0.0, w]
	var ys := [-5.0, h]
	for r in holes:
		xs.append_array([r.position.x, r.end.x])
		ys.append_array([r.position.y, r.end.y])
	xs.sort()
	ys.sort()
	for i in xs.size() - 1:
		for j in ys.size() - 1:
			if xs[i + 1] - xs[i] < 0.001 or ys[j + 1] - ys[j] < 0.001:
				continue
			var mid := Vector2((xs[i] + xs[i + 1]) * 0.5, (ys[j] + ys[j + 1]) * 0.5)
			var open := false
			for r in holes:
				open = open or r.has_point(mid)
			if open:
				continue
			var q := [Vector3(xs[i], ys[j], 0), Vector3(xs[i + 1], ys[j], 0), Vector3(xs[i + 1], ys[j + 1], 0), Vector3(xs[i], ys[j + 1], 0)]
			_fquad(plaster, q, Vector3(0, 0, 1), q.map(func(p): return Vector2(p.x, p.y)), base, true)
	# side and back walls, gables, roof
	for sx in [0.0, w]:
		var q := [Vector3(sx, -5, 0), Vector3(sx, -5, -depth), Vector3(sx, h, -depth), Vector3(sx, h, 0)]
		_fquad(plaster, q, Vector3(-1 if sx == 0.0 else 1, 0, 0), q.map(func(p): return Vector2(p.z, p.y)), base, true)
		var g := [Vector3(sx, h, 0.0), Vector3(sx, h, -depth), Vector3(sx, h + 2.2, -depth * 0.5), Vector3(sx, h + 2.2, -depth * 0.5)]
		_fquad(plaster, g, Vector3(-1 if sx == 0.0 else 1, 0, 0), g.map(func(p): return Vector2(p.z, p.y)), base)
	var back := [Vector3(w, -5, -depth), Vector3(0, -5, -depth), Vector3(0, h, -depth), Vector3(w, h, -depth)]
	_fquad(plaster, back, Vector3(0, 0, -1), back.map(func(p): return Vector2(p.x, p.y)), base, true)
	var ov := 0.5
	for slope in [[0.0 + ov, 1.0], [-depth - ov, -1.0]]:
		var z0: float = slope[0]
		var sgn: float = slope[1]
		var rq := [Vector3(-0.25, h - 0.1, z0), Vector3(w + 0.25, h - 0.1, z0), Vector3(w + 0.25, h + 2.25, -depth * 0.5), Vector3(-0.25, h + 2.25, -depth * 0.5)]
		if sgn < 0.0:
			rq = [rq[1], rq[0], rq[3], rq[2]]
		var run := Vector2(depth * 0.5 + ov, 2.35).length()
		_fquad(sts["roof"], rq, Vector3(0, 0.9, 0.42 * sgn).normalized(), [Vector2(rq[0].x, 0), Vector2(rq[1].x, 0), Vector2(rq[2].x, run), Vector2(rq[3].x, run)])
	if rng.randf() < 0.6:  # chimney
		var cx := rng.randf_range(1.0, w - 1.6)
		_fbox(plaster, Vector3(cx, h + 0.8, -depth * 0.5 - 1.0), Vector3(cx + 0.6, h + 3.3, -depth * 0.5 - 0.4), base * 0.95)
		_fbox(sts["roof"], Vector3(cx - 0.1, h + 3.3, -depth * 0.5 - 1.1), Vector3(cx + 0.7, h + 3.42, -depth * 0.5 - 0.3), Color(0, 0, 0, 0))
	# --- facade relief: stone plinth, string courses, eave cornice, gutter and downpipe
	_fbox(sts["stone"], Vector3(0, -5, 0), Vector3(w, 0.6, 0.05))
	for f in range(1, floors):
		_fbox(plaster, Vector3(0, gf + (f - 1) * fh - 0.18, 0), Vector3(w, gf + (f - 1) * fh, 0.05), trim)
	_fbox(plaster, Vector3(-0.25, h - 0.3, 0), Vector3(w + 0.25, h - 0.1, 0.5), trim)
	paint.set_color(Color(0.42, 0.4, 0.38))
	var dx := w - 0.2
	_tube(paint, PackedVector3Array([_fp(Vector3(-0.2, h - 0.12, 0.55)), _fp(Vector3(w + 0.2, h - 0.12, 0.55))]), 0.06, 6)
	_tube(paint, PackedVector3Array([_fp(Vector3(dx, h - 0.12, 0.55)), _fp(Vector3(dx, h - 0.6, 0.12)), _fp(Vector3(dx, 0.1, 0.12))]), 0.045, 6)
	# --- openings
	for wd in windows:
		var r: Rect2 = wd[0]
		var fl: int = wd[1]
		var bal: bool = wd[2]
		var door: bool = wd[3]
		var d := 0.35 if door else 0.2
		var x0 := r.position.x
		var x1 := r.end.x
		var y0 := r.position.y
		var y1 := r.end.y
		# reveals (inside of the opening) and the pane at the back
		for q in [[Vector3(x0, y0, 0), Vector3(x0, y0, -d), Vector3(x0, y1, -d), Vector3(x0, y1, 0), Vector3(1, 0, 0)],
				[Vector3(x1, y0, -d), Vector3(x1, y0, 0), Vector3(x1, y1, 0), Vector3(x1, y1, -d), Vector3(-1, 0, 0)],
				[Vector3(x0, y1, 0), Vector3(x0, y1, -d), Vector3(x1, y1, -d), Vector3(x1, y1, 0), Vector3(0, -1, 0)],
				[Vector3(x0, y0, -d), Vector3(x0, y0, 0), Vector3(x1, y0, 0), Vector3(x1, y0, -d), Vector3(0, 1, 0)]]:
			_fquad(plaster, q.slice(0, 4), q[4], q.slice(0, 4).map(func(p): return Vector2(p.x + p.z, p.y + p.z)), trim * 0.92)
		var pane := [Vector3(x0, y0, -d), Vector3(x1, y0, -d), Vector3(x1, y1, -d), Vector3(x0, y1, -d)]
		if door and not shop:
			_fquad(sts["wood"], pane, Vector3(0, 0, 1), pane.map(func(p): return Vector2(p.x, p.y)))
		else:
			_fquad(sts["glass"], pane, Vector3(0, 0, 1), [])
			# window bars (cross glazing) in the pane plane
			paint.set_color(Color(0.9, 0.9, 0.86) if fl > 0 else Color(0.1, 0.1, 0.1))
			_fbox(paint, Vector3((x0 + x1) * 0.5 - 0.025, y0, -d), Vector3((x0 + x1) * 0.5 + 0.025, y1, -d + 0.04), Color(0, 0, 0, 0), false)
			_fbox(paint, Vector3(x0, y0 + (y1 - y0) * 0.62, -d), Vector3(x1, y0 + (y1 - y0) * 0.62 + 0.05, -d + 0.04), Color(0, 0, 0, 0), false)
		# stone surround + sill
		_fbox(plaster, Vector3(x0 - 0.14, y1, 0), Vector3(x1 + 0.14, y1 + 0.14, 0.05), trim)
		_fbox(plaster, Vector3(x0 - 0.14, y0, 0), Vector3(x0, y1, 0.04), trim)
		_fbox(plaster, Vector3(x1, y0, 0), Vector3(x1 + 0.14, y1, 0.04), trim)
		if not door and not bal:
			_fbox(plaster, Vector3(x0 - 0.1, y0 - 0.07, 0), Vector3(x1 + 0.1, y0, 0.12), trim)
			if fl > 0 and rng.randf() < 0.35:
				_add_prop(props, "planter_box_01", _fxf(Vector3((x0 + x1) * 0.5, y0, 0.24)))
		if fl == 0 and not door:  # iron grille on ground-floor windows
			paint.set_color(Color(0.08, 0.08, 0.08))
			var bx := x0 + 0.12
			while bx < x1:
				_tube(paint, PackedVector3Array([_fp(Vector3(bx, y0, 0.06)), _fp(Vector3(bx, y1, 0.06))]), 0.012, 4)
				bx += 0.15
		# open shutters on the upper floors, folded back against the wall
		if fl > 0:
			var sw := (x1 - x0) * 0.5
			for sx in [x0 - 0.16 - sw, x1 + 0.16]:
				var q := [Vector3(sx, y0, 0.03), Vector3(sx + sw, y0, 0.03), Vector3(sx + sw, y1, 0.03), Vector3(sx, y1, 0.03)]
				_fquad(sts["shutter"], q, Vector3(0, 0, 1), q.map(func(p): return Vector2(p.x, p.y)), shutter)
		if bal:  # stone slab, iron railing, a pot or two
			var bz := 0.85
			_fbox(sts["stone"], Vector3(x0 - 0.45, y0 - 0.16, 0), Vector3(x1 + 0.45, y0, bz))
			paint.set_color(Color(0.07, 0.07, 0.07))
			var top := y0 + 1.0
			var rail := PackedVector3Array([_fp(Vector3(x0 - 0.42, top, 0)), _fp(Vector3(x0 - 0.42, top, bz - 0.04)), _fp(Vector3(x1 + 0.42, top, bz - 0.04)), _fp(Vector3(x1 + 0.42, top, 0))])
			_tube(paint, rail, 0.02, 4)
			var bx := x0 - 0.4
			while bx < x1 + 0.42:
				_tube(paint, PackedVector3Array([_fp(Vector3(bx, y0, bz - 0.04)), _fp(Vector3(bx, top, bz - 0.04))]), 0.01, 4)
				bx += 0.12
			if rng.randf() < 0.7:
				_add_prop(props, "planter_pot_clay", _fxf(Vector3(x0 - 0.2, y0, 0.45)))
		if door and shop:  # striped awning over the shop front
			var aw := [Vector3(x0 - 0.15, y1 + 0.45, 0.0), Vector3(x1 + 0.15, y1 + 0.45, 0.0), Vector3(x1 + 0.15, y1 + 0.1, 0.85), Vector3(x0 - 0.15, y1 + 0.1, 0.85)]
			var ac: Color = AWNING_COLOURS[rng.randi() % AWNING_COLOURS.size()]
			_fquad(sts["awning"], aw, Vector3(0, 0.92, 0.38), aw.map(func(p): return Vector2(p.x, p.z)), ac)
			var vl := [Vector3(x0 - 0.15, y1 - 0.12, 0.85), Vector3(x1 + 0.15, y1 - 0.12, 0.85), Vector3(x1 + 0.15, y1 + 0.1, 0.85), Vector3(x0 - 0.15, y1 + 0.1, 0.85)]
			_fquad(sts["awning"], vl, Vector3(0, 0, 1), vl.map(func(p): return Vector2(p.x, p.y)), ac)  # front valance
		elif door and rng.randf() < 0.6:
			_add_prop(props, "potted_plant_02", _fxf(Vector3(x1 + 0.45, 0.0, 0.35)))
	if rng.randf() < 0.5:  # wall lantern between the ground-floor openings
		_add_prop(props, "street_lamp_02", _fxf(Vector3(w * 0.5 + (w / cols) * 0.5 * (1 if cols > 1 else 0), 3.0, 0.0)))
	if cafe and rng.randf() < 0.6:  # cafe table on the promenade in front of the house
		_add_prop(props, "outdoor_table_chair_set_01", _fxf(Vector3(w * 0.5, 0.0, 1.0), rng.randf() * TAU))

const AWNING_COLOURS: Array[Color] = [Color(0.6, 0.12, 0.1), Color(0.12, 0.3, 0.22), Color(0.15, 0.25, 0.45), Color(0.8, 0.62, 0.3)]

var _prop_cache := {}  # model -> [[mesh, transform in model space], ...]

func _add_prop(props: Dictionary, model: String, xf: Transform3D, tint := Color(0, 0, 0, 0)) -> void:
	var key := model + (tint.to_html() if tint.a > 0.0 else "")
	if not _prop_cache.has(key):
		var parts := []
		var root: Node = (load("res://assets/models/%s/%s_1k.gltf" % [model, model]) as PackedScene).instantiate()
		for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D"):
			var t := mi.transform
			var p := mi.get_parent()
			while p != root and p is Node3D:
				t = (p as Node3D).transform * t
				p = p.get_parent()
			parts.append([_tinted(mi.mesh, tint) if tint.a > 0.0 else mi.mesh, t])
		root.free()
		_prop_cache[key] = parts
	for part in _prop_cache[key]:
		var m: Mesh = part[0]
		if not props.has(m):
			props[m] = []
		props[m].append(xf * (part[1] as Transform3D))

# copy of a scanned mesh with greyscale, tinted albedo (the scans are warm sandstone; Limone is pale grey limestone)
func _tinted(mesh: Mesh, tint: Color) -> Mesh:
	var m := mesh.duplicate() as Mesh
	for si in m.get_surface_count():
		var mat := m.surface_get_material(si) as StandardMaterial3D
		if mat == null:
			continue
		mat = mat.duplicate() as StandardMaterial3D
		if mat.albedo_texture:
			var img := mat.albedo_texture.get_image()
			if img.is_compressed():
				img.decompress()
			img.convert(Image.FORMAT_L8)
			img.convert(Image.FORMAT_RGB8)
			img.generate_mipmaps()
			mat.albedo_texture = ImageTexture.create_from_image(img)
		mat.albedo_color = tint
		m.surface_set_material(si, mat)
	return m

const LIMESTONE := Color(1.4, 1.36, 1.28)
# scanned rock faces along the inland edge of cliff sections (section "cliff" > 0): a row of crags 9-16 m tall right
# beside the path (fronts kept clear of it), now and then a big crag mass higher up and further back
func _cliff_rocks(rng: RandomNumberGenerator, s0: float, s1: float, o: Vector3, rocks: Dictionary) -> void:
	var s := s0 + rng.randf() * 3.0
	while s < s1:
		var h := float(_route.section_at(s).get("cliff", 0.0))
		if h <= 0.0:
			s += 6.0
			continue
		_frame_at(s, o)
		var edge := _route.half_right(s) + 0.4
		var small := rng.randf() < 0.35
		var model := "rock_face_02" if small else "rock_face_01"
		var k := rng.randf_range(2.5, 4.5) * (1.6 if small else 1.0)
		# the rock_face scans lie face-up: stand them on end (+Y face -> toward the path), the scan's -Z end at the bottom
		var front := (2.4 if small else 3.6) * k + 1.2  # face depth after standing up, plus room for the yaw jitter
		var b := Basis(Vector3.UP.cross(_fn), Vector3.UP, _fn) * Basis(Vector3.UP, rng.randf_range(-0.12, 0.12)) * Basis(Vector3.RIGHT, PI * 0.5 + rng.randf_range(-0.1, 0.04))
		_add_prop(rocks, model, Transform3D(b.scaled_local(Vector3.ONE * k), _fp(Vector3(0, -0.8 + 0.3 * k, -(edge + front)))), LIMESTONE)
		if h > 30.0 and rng.randf() < 0.7:  # second tier on top, set back: covers the face up to ~25 m
			var k3 := rng.randf_range(3.0, 4.5)
			var b3 := Basis(Vector3.UP.cross(_fn), Vector3.UP, _fn) * Basis(Vector3.UP, rng.randf_range(-0.15, 0.15)) * Basis(Vector3.RIGHT, PI * 0.5 + rng.randf_range(-0.2, 0.0))
			_add_prop(rocks, "rock_face_01", Transform3D(b3.scaled_local(Vector3.ONE * k3), _fp(Vector3(rng.randf_range(-3.0, 3.0), 3.4 * k + rng.randf_range(-2.0, 1.0), -(edge + front + rng.randf_range(2.0, 5.0))))), LIMESTONE)
		if h > 30.0 and rng.randf() < 0.3:
			var k2 := rng.randf_range(1.6, 2.6)
			var b2 := Basis(Vector3.UP.cross(_fn), Vector3.UP, _fn) * Basis(Vector3.UP, rng.randf_range(-0.2, 0.2))
			_add_prop(rocks, "namaqualand_cliff_02", Transform3D(b2.scaled_local(Vector3.ONE * k2), _fp(Vector3(0, rng.randf_range(4.0, 9.0), -(edge + 5.0 + 2.2 * k2)))), LIMESTONE)
		s += rng.randf_range(0.35, 0.5) * (2.7 if small else 5.0) * k

func _commit_props(holder: Node3D, props: Dictionary, vis := 150.0) -> void:
	for m: Mesh in props:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = m
		mm.instance_count = props[m].size()
		for k in mm.instance_count:
			mm.set_instance_transform(k, props[m][k])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.visibility_range_end = vis
		holder.add_child(mmi)

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, uv: Array = []) -> void:
	st.set_normal((b - a).cross(d - a).normalized())  # flat; materials are double-sided
	var vs := [a, b, c, a, c, d]
	var order := [0, 1, 2, 0, 2, 3]
	for k in 6:
		if not uv.is_empty():
			st.set_uv(uv[order[k]])
		st.add_vertex(vs[k])

# The builders here emit triangles counter-clockwise around their (explicit) normals; Godot's front faces are clockwise.
# Godot draws these materials double-sided so it never showed, but glTF consumers (Blender, Unity) take the winding as
# the front and shade those faces black. Reverse every triangle so winding and normals agree.
func _front_faces(m: ArrayMesh) -> ArrayMesh:
	if m == null or m.get_surface_count() == 0:
		return m
	var arr := m.surface_get_arrays(0)
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if idx.is_empty():
		var n: int = (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		idx.resize(n)
		for k in n:
			idx[k] = k
	for k in range(0, idx.size() - 2, 3):
		var t := idx[k + 1]
		idx[k + 1] = idx[k + 2]
		idx[k + 2] = t
	arr[Mesh.ARRAY_INDEX] = idx
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	out.surface_set_material(0, m.surface_get_material(0))
	return out

func _commit(holder: Node3D, st: SurfaceTool, mat: Material, shadows := true) -> void:
	var mesh := _front_faces(st.commit())
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.visibility_range_end = view_distance
	if not shadows:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(mi)

# closed-ring tube along pts (smooth normals)
func _tube(st: SurfaceTool, pts: PackedVector3Array, r: float, sides: int) -> void:
	var rings := []
	for i in pts.size():
		var t := (pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]).normalized()
		var ref := Vector3.UP if absf(t.y) < 0.9 else Vector3.BACK
		var nrm := t.cross(ref).normalized()
		var bin := nrm.cross(t)
		var ring := []
		for k in sides + 1:
			var a := TAU * k / sides
			var dir := nrm * cos(a) + bin * sin(a)
			ring.append([pts[i] + dir * r, dir])
		rings.append(ring)
	for i in pts.size() - 1:
		for k in sides:
			for v in [rings[i][k], rings[i + 1][k], rings[i + 1][k + 1], rings[i][k], rings[i + 1][k + 1], rings[i][k + 1]]:
				st.set_normal(v[1])
				st.add_vertex(v[0])

# one railing post in its own frame (+X = out over the water, +Y up): rises from the deck edge and bows outward
func _make_post() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pts := PackedVector3Array()
	for k in 9:
		var t := k / 8.0
		pts.append(Vector3(lean * (1.0 - cos(t * PI * 0.5)), -0.2 + t * (rail_h + 0.2), 0.0))
	_tube(st, pts, 0.03, 8)
	var m := _front_faces(st.commit())
	m.surface_set_material(0, _steel)
	return m

# --- harbour (lake style "harbour"): quay wall into the water, low kerb with lamps, raised flower beds with fan palms,
# benches facing the lake, and once per harbour stretch a concrete pier with bollards, a ferry pontoon and mooring piles.
var _piers: Array[float] = []   # route offsets of the piers (middle of each harbour stretch)
var _flower_meshes: Array[Mesh] = []
var _palm: Mesh

func _find_piers() -> void:
	var run_start := -1.0
	var s := 0.0
	while s <= _route.length:
		var h: bool = _styles(s, 0)[0] == "harbour"
		if h and run_start < 0.0:
			run_start = s
		if (not h or s + 2.0 > _route.length) and run_start >= 0.0:
			if s - run_start > 30.0:
				_piers.append((run_start + s) * 0.5)
			run_start = -1.0
		s += 2.0

func _near_pier(s: float, r: float) -> bool:
	for p in _piers:
		if absf(s - p) < r:
			return true
	return false

# harbour edge for one 2 m step (called from _chunk)
func _harbour_step(sts: Dictionary, sp: float, s: float, o: Vector3) -> void:
	var stone: SurfaceTool = sts["stone"]
	var pp := _route.pos_at(sp)
	var p := _route.pos_at(s)
	var lp := _route.left_at(sp)
	var l := _route.left_at(s)
	var ulp := _route.half_left(sp)
	var ul := _route.half_left(s)
	var wa := _route.water_level(sp) - 1.0
	var wb := _route.water_level(s) - 1.0
	var a := pp + lp * ulp - o
	var b := p + l * ul - o
	# quay wall face, from the promenade down into the water
	_quad(stone, Vector3(a.x, wa - o.y, a.z), Vector3(b.x, wb - o.y, b.z), b, a, [Vector2(sp, wa), Vector2(s, wb), Vector2(s, p.y), Vector2(sp, pp.y)])
	if not _near_pier((sp + s) * 0.5, 2.6):
		_wall(stone, sp, s, pp, p, lp, l, ulp + 0.35, ul + 0.35, ulp, ul, 0.3, 0.3, o)
		if posmod(int(s), 18) < 2:
			_lamp(sts["paint"], p + l * (ul + 0.17) - o)

func _harbour_chunk(sts: Dictionary, rng: RandomNumberGenerator, c: int, s0: float, s1: float, o: Vector3, props: Dictionary, holder: Node3D) -> void:
	var beds := []  # [mesh, Transform3D] flower instances
	var s := s0 + 1.0
	while s < s1 - 6.0:
		if _styles(s, c)[0] != "harbour" or _styles(s + 5.0, c)[0] != "harbour" or _near_pier(s + 2.5, 6.0):
			s += 2.0
			continue
		var e := s + rng.randf_range(3.5, 6.0)
		_flower_bed(sts, rng, s, e, o, beds, props)
		var bs := e + 1.6  # bench between beds, facing the lake
		if bs < s1 - 1.0 and rng.randf() < 0.75 and not _near_pier(bs, 4.0):
			_frame_at(bs, o)
			_add_prop(props, "painted_wooden_bench", _fxf(Vector3(0, 0, _route.half_left(bs) - 0.9)))
		s = e + 3.2
	if not beds.is_empty():
		var by_mesh := {}
		for b in beds:
			if not by_mesh.has(b[0]):
				by_mesh[b[0]] = []
			by_mesh[b[0]].append(b[1])
		_commit_props(holder, by_mesh)
	for ps in _piers:
		if ps >= s0 and ps < s1:
			_pier(sts, rng, ps, o, props)

func _frame_at(s: float, o: Vector3) -> void:  # frame: x along the route, z out over the lake, origin on the centre line
	var t := _route.pos_at(minf(s + 1.0, _route.length)) - _route.pos_at(maxf(s - 1.0, 0.0))
	t.y = 0.0
	_f0 = _route.pos_at(s) - o
	_fx = t.normalized()
	_fn = _route.left_at(s)

# raised stone flower bed on the lake side of the promenade, packed with flowering clumps, sometimes a fan palm
func _flower_bed(sts: Dictionary, rng: RandomNumberGenerator, s: float, e: float, o: Vector3, beds: Array, props: Dictionary) -> void:
	var stone: SurfaceTool = sts["stone"]
	var u_in := _route.half_left(s) - 1.6
	var u_out := _route.half_left(s) - 0.4
	var pa := _route.pos_at(s)
	var pb := _route.pos_at(e)
	var la := _route.left_at(s)
	var lb := _route.left_at(e)
	var bh := 0.45
	_wall(stone, s, e, pa, pb, la, lb, u_out, u_out, u_in, u_in, bh, bh, o)
	for end in [[pa, la, s], [pb, lb, e]]:  # end caps
		var q: Vector3 = end[0] - o
		var lv: Vector3 = end[1]
		var ss: float = end[2]
		_quad(stone, q + lv * u_in + Vector3(0, -0.6, 0), q + lv * u_out + Vector3(0, -0.6, 0), q + lv * u_out + Vector3(0, bh, 0), q + lv * u_in + Vector3(0, bh, 0),
				[Vector2(u_in, -0.6), Vector2(u_out, -0.6), Vector2(u_out, bh), Vector2(u_in, bh)])
	var paint: SurfaceTool = sts["paint"]
	if _flower_meshes.is_empty():
		for k in 3:
			_flower_meshes.append(_make_flowers(31 + k))
		_palm = _make_palm()
	# the planting is a dome of busy-lizzies about a metre tall (no soil showing), like the harbour beds in Limone
	var mound := rng.randf_range(0.45, 0.65)
	var dome := func(x: float, u: float) -> float:  # height above the bed's stone rim
		var nx := clampf(2.0 * (x - s) / (e - s) - 1.0, -1.0, 1.0)
		var nu := clampf(2.0 * (u - u_in) / (u_out - u_in) - 1.0, -1.0, 1.0)
		return mound * sqrt(maxf(0.0, (1.0 - pow(absf(nx), 4.0)) * (1.0 - nu * nu))) + 0.04
	var nxs := maxi(int((e - s) / 0.3), 2)
	var nus := 6
	var pt := func(x: float, u: float) -> Vector3:
		return _route.pos_at(x) + _route.left_at(x) * u + Vector3(0, bh + float(dome.call(x, u)), 0) - o
	for ix in nxs:
		for iu in nus:
			var x0 := lerpf(s + 0.05, e - 0.05, float(ix) / nxs)
			var x1 := lerpf(s + 0.05, e - 0.05, float(ix + 1) / nxs)
			var u0 := lerpf(u_in + 0.05, u_out - 0.05, float(iu) / nus)
			var u1 := lerpf(u_in + 0.05, u_out - 0.05, float(iu + 1) / nus)
			paint.set_color(Color(0.1, 0.24, 0.07) * rng.randf_range(0.75, 1.15))  # leaf mass under the flowers
			_quad(paint, pt.call(x0, u0), pt.call(x1, u0), pt.call(x1, u1), pt.call(x0, u1))
	var step := 0.2
	var x := s + 0.12
	while x < e - 0.08:
		var u := u_in + 0.12
		while u < u_out - 0.08:
			var uu := u + rng.randf_range(-0.05, 0.05)
			var p: Vector3 = pt.call(x, uu) - Vector3(0, 0.12, 0)
			var k := rng.randf_range(1.5, 2.1)
			beds.append([_flower_meshes[rng.randi() % 3], Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(k, k * rng.randf_range(0.8, 1.2), k)), p)])
			u += step
		x += step
	if rng.randf() < 0.45:
		var m := (s + e) * 0.5
		beds.append([_palm, Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(1.4, 1.9)),
				_route.pos_at(m) + _route.left_at(m) * (u_in + u_out) * 0.5 + Vector3(0, bh + mound * 0.6, 0) - o)])

# concrete pier straight out into the lake, bollards along its edges and a lamp at the end; a ferry pontoon with white
# railings moored along its far half (gangway down from the pier); a row of wooden mooring piles beside it
func _pier(sts: Dictionary, rng: RandomNumberGenerator, s: float, o: Vector3, props: Dictionary) -> void:
	_frame_at(s, o)
	var ul := _route.half_left(s)
	var wl := _route.water_level(s) - _route.pos_at(s).y   # water surface relative to the promenade (negative)
	var length := 30.0
	var hw := 2.4
	var con: SurfaceTool = sts["concrete"]
	_fbox(con, Vector3(-hw, wl - 2.0, ul - 0.02), Vector3(hw, -0.08, ul + length))
	var paint: SurfaceTool = sts["paint"]
	paint.set_color(Color(0.1, 0.1, 0.1))
	var z := ul + 2.0
	while z < ul + length - 0.5:  # cast iron bollards
		for sx in [-hw + 0.25, hw - 0.25]:
			_tube(paint, PackedVector3Array([_fp(Vector3(sx, -0.1, z)), _fp(Vector3(sx, 0.45, z))]), 0.11, 8)
			_tube(paint, PackedVector3Array([_fp(Vector3(sx, 0.45, z)), _fp(Vector3(sx, 0.55, z))]), 0.16, 8)
		z += 5.0
	_lamp(paint, _fp(Vector3(0, -0.08, ul + length - 0.6)))
	# pontoon: a dark floating box with a white rail, beside the outer half of the pier, gangway from the pier deck
	var side := 1.0 if rng.randf() < 0.5 else -1.0
	var px0 := side * (hw + 0.3)
	var px1 := side * (hw + 3.8)
	var z0 := ul + length * 0.45
	var z1 := ul + length - 1.0
	var a := Vector3(minf(px0, px1), wl - 0.6, z0)
	var b := Vector3(maxf(px0, px1), wl + 0.5, z1)
	_fbox(con, a, b)
	paint.set_color(Color(0.93, 0.93, 0.92))
	var rx := px1 - side * 0.1
	var rail := PackedVector3Array([_fp(Vector3(px0, wl + 1.5, z0 + 0.1)), _fp(Vector3(rx, wl + 1.5, z0 + 0.1)), _fp(Vector3(rx, wl + 1.5, z1 - 0.1)), _fp(Vector3(px0, wl + 1.5, z1 - 0.1))])
	_tube(paint, rail, 0.03, 6)
	for q in [Vector3(rx, 0, z0 + 0.1), Vector3(rx, 0, (z0 + z1) * 0.5), Vector3(rx, 0, z1 - 0.1), Vector3(px0, 0, z0 + 0.1), Vector3(px0, 0, z1 - 0.1)]:
		_tube(paint, PackedVector3Array([_fp(Vector3(q.x, wl + 0.5, q.z)), _fp(Vector3(q.x, wl + 1.5, q.z))]), 0.025, 6)
	var gz := (z0 + z1) * 0.5
	_fquad(con, [Vector3(side * hw, -0.1, gz - 0.7), Vector3(px0, wl + 0.5, gz - 0.7), Vector3(px0, wl + 0.5, gz + 0.7), Vector3(side * hw, -0.1, gz + 0.7)],
			Vector3(0, 1, 0), [Vector2(0, 0), Vector2(1.5, 0), Vector2(1.5, 1.4), Vector2(0, 1.4)])
	# wooden mooring piles on the other side of the pier
	var wood: SurfaceTool = sts["paint"]
	wood.set_color(Color(0.3, 0.24, 0.17))
	for k in 6:
		var pz := ul + 6.0 + k * 4.0 + rng.randf_range(-0.5, 0.5)
		var pxx := -side * (hw + 4.5 + rng.randf_range(-0.4, 0.4))
		_tube(wood, PackedVector3Array([_fp(Vector3(pxx, wl - 2.0, pz)), _fp(Vector3(pxx, wl + rng.randf_range(1.2, 2.0), pz))]), 0.14, 8)

# a low mound of leaves dotted with five-petal flowers (busy-lizzie bedding: pink, white, magenta), ~0.3 m across
func _make_flowers(seed_: int) -> Mesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var leaf := Color(0.12, 0.28, 0.08)
	for i in 10:  # leaves
		var a := rng.randf() * TAU
		var r := rng.randf_range(0.0, 0.13)
		var c := Vector3(cos(a) * r, rng.randf_range(0.06, 0.16), sin(a) * r)
		var d := Vector3(cos(a + 1.0), 0.25, sin(a + 1.0)).normalized() * 0.09
		var sd := d.cross(Vector3.UP).normalized() * 0.04
		st.set_color(leaf * rng.randf_range(0.8, 1.3))
		st.set_normal(Vector3.UP)
		for v in [c - d, c + sd, c + d, c - d, c + d, c - sd]:
			st.add_vertex(v)
	var palette := [Color(0.98, 0.6, 0.78), Color(0.97, 0.95, 0.97), Color(0.88, 0.18, 0.5), Color(0.98, 0.45, 0.6)]
	for i in 22:  # flowers
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf()) * 0.15
		var c := Vector3(cos(a) * r, 0.17 + 0.08 * (1.0 - r / 0.15) + rng.randf_range(-0.02, 0.02), sin(a) * r)
		var col: Color = palette[rng.randi() % palette.size()]
		var n := Vector3(cos(a) * r * 3.0, 1.0, sin(a) * r * 3.0).normalized()
		var t1 := n.cross(Vector3.FORWARD).normalized()
		var t2 := n.cross(t1)
		st.set_normal(n)
		for k in 5:
			var a0 := TAU * k / 5.0
			var a1 := a0 + TAU / 5.0
			st.set_color(col * 0.85)
			st.add_vertex(c)
			st.set_color(col)
			st.add_vertex(c + (t1 * cos(a0) + t2 * sin(a0)) * 0.03)
			st.add_vertex(c + (t1 * cos(a1) + t2 * sin(a1)) * 0.03)
	var m := _front_faces(st.commit())
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.8
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.surface_set_material(0, mat)
	return m

# Mediterranean fan palm: short fibrous trunk, ~18 stiff fan leaves on long stalks
func _make_palm() -> Mesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 91
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(Color(0.3, 0.22, 0.14))
	_tube(st, PackedVector3Array([Vector3(0, -0.2, 0), Vector3(0.05, 0.8, 0), Vector3(0.0, 1.5, 0.05)]), 0.17, 8)
	var top := Vector3(0.0, 1.5, 0.05)
	for i in 18:
		var az := TAU * i / 18.0 + rng.randf_range(-0.15, 0.15)
		var el := deg_to_rad(rng.randf_range(-5.0, 65.0))
		var dir := Vector3(cos(az) * cos(el), sin(el), sin(az) * cos(el))
		var stalk := rng.randf_range(0.5, 0.8)
		var c := top + dir * stalk
		st.set_color(Color(0.22, 0.3, 0.12))
		_tube(st, PackedVector3Array([top, c]), 0.015, 3)
		var side := dir.cross(Vector3.UP).normalized()
		var up := side.cross(dir).normalized()
		var r := rng.randf_range(0.55, 0.75)
		for k in 12:  # fan of pointed segments in the plane (side, dir), slightly cupped
			var a0 := lerpf(-1.2, 1.2, k / 12.0)
			var a1 := lerpf(-1.2, 1.2, (k + 1) / 12.0)
			var am := (a0 + a1) * 0.5
			var p0 := c + (dir * cos(a0) + side * sin(a0)) * r * 0.55 + up * 0.04 * absf(a0)
			var p1 := c + (dir * cos(a1) + side * sin(a1)) * r * 0.55 + up * 0.04 * absf(a1)
			var tip := c + (dir * cos(am) + side * sin(am)) * r + up * 0.1 * absf(am) - Vector3(0, 0.08, 0)
			st.set_normal(up)
			st.set_color(Color(0.13, 0.3, 0.1) * rng.randf_range(0.85, 1.2))
			for v in [c, p0, p1, p0, tip, p1]:
				st.add_vertex(v)
	var m := _front_faces(st.commit())
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.75
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.surface_set_material(0, mat)
	return m
