extends MeshInstance3D
# Real-world terrain backdrop built from tools/fetch_real_terrain.py output (DEM + orthophoto).
# Heights are placed relative to the runner: the terrain centre altitude sits at y = 0 of this node, so put the
# node in a FollowPlayer with y_factor 1. The central disc (where our generated trail lives) is sunk below the
# cloud sea so the two never intersect.

@export var terrain_name := "jungfrau"
@export var hole_radius := 1800.0      # metres around the centre pushed down out of sight
@export var hole_depth := -600.0
@export var rotation_deg := 0.0        # turn the real map relative to the route
@export var height_offset := 0.0       # extra vertical shift (m)

var _mat: ShaderMaterial

func _ready() -> void:
	var dir := "res://assets/terrain/"
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir + terrain_name + ".json"))
	var g: int = meta["grid"]
	var size: float = meta["size_m"]
	var h := FileAccess.get_file_as_bytes(dir + terrain_name + "_h.f32").to_float32_array()
	var c0: float = meta["centre_m"]
	var step := size / (g - 1)
	var y := PackedFloat32Array()
	y.resize(g * g)
	for r in g:
		for c in g:
			var x := (c - (g - 1) * 0.5) * step
			var z := (r - (g - 1) * 0.5) * step
			var d := sqrt(x * x + z * z)
			var v := h[r * g + c] - c0 + height_offset
			y[r * g + c] = lerpf(hole_depth, v, smoothstep(hole_radius * 0.75, hole_radius, d))
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(g * g)
	norms.resize(g * g)
	uvs.resize(g * g)
	for r in g:
		for c in g:
			var i := r * g + c
			verts[i] = Vector3((c - (g - 1) * 0.5) * step, y[i], (r - (g - 1) * 0.5) * step)
			var hl := y[r * g + maxi(c - 1, 0)]
			var hr := y[r * g + mini(c + 1, g - 1)]
			var hu := y[maxi(r - 1, 0) * g + c]
			var hd := y[mini(r + 1, g - 1) * g + c]
			norms[i] = Vector3(hl - hr, 2.0 * step, hu - hd).normalized()
			uvs[i] = Vector2(float(c) / (g - 1), float(r) / (g - 1))
	var idx := PackedInt32Array()
	idx.resize((g - 1) * (g - 1) * 6)
	var k := 0
	for r in g - 1:
		for c in g - 1:
			var a := r * g + c
			idx[k] = a; idx[k + 1] = a + 1; idx[k + 2] = a + g
			idx[k + 3] = a + 1; idx[k + 4] = a + g + 1; idx[k + 5] = a + g
			k += 6
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh = m
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://real_terrain.gdshader")
	_mat.set_shader_parameter("albedo_tex", load(dir + terrain_name + "_albedo.jpg"))
	material_override = _mat
	rotation.y = deg_to_rad(rotation_deg)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 5000.0
	var cam := get_viewport().get_camera_3d()
	if cam:
		cam.far = maxf(cam.far, 30000.0)  # the default 4 km would clip the real mountains

func _process(_d: float) -> void:
	var env := get_viewport().world_3d.environment
	if env:
		_mat.set_shader_parameter("mist", smoothstep(0.0012, 0.006, env.fog_density))
