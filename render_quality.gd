extends Node
# Offline "film" quality for recorded courses. Active with --hq on the command line (export_course.sh passes it
# through EXPORT_EXTRA) or when `always_on` is set. Real-time play keeps the cheaper defaults.
#   godot --path . res://MainScene_alpine.tscn --write-movie out.avi --fixed-fps 60 -- --course=summit --hq

@export var env_path: NodePath
@export var sun_path: NodePath
@export var always_on := false
@export var supersample := 2.0          # render scale; 2.0 = 4K internally for a 1080p movie
@export var shadow_atlas := 8192
@export var shadow_distance := 220.0
@export var volumetric_fog := true
@export var post_fx := true

func _ready() -> void:
	if not (always_on or "--hq" in OS.get_cmdline_user_args()):
		return
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = supersample
	vp.mesh_lod_threshold = 0.0
	vp.msaa_3d = Viewport.MSAA_2X
	RenderingServer.directional_shadow_atlas_set_size(shadow_atlas, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_ULTRA)
	var sun: DirectionalLight3D = get_node(sun_path)
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = shadow_distance
	sun.shadow_blur = 1.0
	var env := (get_node(env_path) as WorldEnvironment).environment
	env.ssao_enabled = true
	env.ssao_radius = 1.2
	env.ssao_intensity = 1.6
	env.ssil_enabled = true
	env.ssil_radius = 4.0
	if volumetric_fog:
		env.volumetric_fog_enabled = true
		env.volumetric_fog_density = 0.0005
		env.volumetric_fog_albedo = Color(0.9, 0.93, 1.0)
		env.volumetric_fog_length = 250.0
		env.volumetric_fog_anisotropy = 0.6   # forward scattering: light shafts toward the sun
		env.volumetric_fog_sky_affect = 0.0
	if post_fx:
		var layer := CanvasLayer.new()
		layer.layer = -1   # under the HUD
		var rect := ColorRect.new()
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		var m := ShaderMaterial.new()
		m.shader = load("res://post_fx.gdshader")
		rect.material = m
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(rect)
		add_child(layer)
