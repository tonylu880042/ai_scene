extends MeshInstance3D
# Distant mountain silhouette: a noisy ring of ridges around the sea. Builds its own mesh.

@export var inner_radius := 700.0   # where the ridge starts rising out of the water
@export var span := 400.0           # radial width (peak sits at the middle)
@export var max_height := 170.0
@export var openness := 0.35        # 0 = ridge all the way round, higher = more open sea gaps
@export var segments := 256
@export var rings := 8
@export var random_seed := 3
@export var color_low := Color(0.3, 0.42, 0.38)
@export var color_high := Color(0.5, 0.55, 0.6)
@export var snow_line := 2.0          # fraction of max height above which peaks turn to snow (2 = no snow)
@export var snow_color := Color(0.96, 0.97, 1.0)
@export var no_fog := false           # stay crisp instead of fading into the distance fog (fades out in mist instead)

func _ready() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = random_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var grid: Array[Vector3] = []
	for i in segments + 1:
		var a := TAU * i / segments
		var dir := Vector2(cos(a), sin(a))
		var big := clampf(noise.get_noise_2d(dir.x * 40.0, dir.y * 40.0) * 1.5 + 0.5 - openness, 0.0, 1.0)
		for j in rings + 1:
			var t := float(j) / rings
			var profile := pow(maxf(1.0 - pow(2.0 * t - 1.0, 2.0), 0.0), 1.3)
			var detail := 0.75 + 0.25 * noise.get_noise_2d(dir.x * 300.0 + t * 30.0, dir.y * 300.0)
			var r := inner_radius + span * t
			grid.append(Vector3(dir.x * r, -5.0 + (max_height + 5.0) * big * profile * detail, dir.y * r))
	for i in segments:
		for j in rings:
			var a := grid[i * (rings + 1) + j]
			var b := grid[(i + 1) * (rings + 1) + j]
			var c := grid[(i + 1) * (rings + 1) + j + 1]
			var d := grid[i * (rings + 1) + j + 1]
			for v in [a, b, c, a, c, d]:
				var t := clampf(v.y / max_height, 0.0, 1.0)
				st.set_color(color_low.lerp(color_high, t).lerp(snow_color, smoothstep(snow_line, snow_line + 0.12, t)))
				st.add_vertex(v)
	st.generate_normals()
	mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if no_fog:
		mat.disable_fog = true
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _process(_d: float) -> void:
	if not no_fog:
		return
	var env := get_viewport().world_3d.environment
	if env:  # fade with the mist so the peaks vanish in white-outs
		var a := 1.0 - smoothstep(0.0012, 0.005, env.fog_density)
		(material_override as StandardMaterial3D).albedo_color.a = lerpf(0.05, 1.0, a)
