extends Node
# Applies a course's scene template (courses.json) to the Route / Foliage / Buildings nodes and
# drifts the sun and fog through the course's time-of-day range. Must be the FIRST child of the
# scene so it configures siblings before their _ready. Course: --course=<name> (else Route.course).

@export var route_path: NodePath
@export var sun_path: NodePath
@export var env_path: NodePath
@export var player_path: NodePath
@export var sea_path: NodePath       # optional (alpine scene has no ocean shader)
@export var extra_sea_paths: Array[NodePath] = []  # more shader layers that need the sun direction
@export var courses_file := "res://courses.json"
@export var mist_enabled := false     # episodic mist / white-out from the course json "fog": [base, extra]
@export var sun_left_deg := Vector2(20.0, 65.0)  # sun azimuth left of the run direction: low sun .. high sun

var _route: Route
var _sun: DirectionalLight3D
var _env: Environment
var _player: Node3D
var _sea_mat: ShaderMaterial
var _extra_mats: Array[ShaderMaterial] = []
var _tod := Vector2(0.4, 0.6)   # start/end phase: 0 sunrise ... 0.5 noon ... 1 sunset
var _template := ""
var _fog := Vector2(0.0007, 0.0)

func _ready() -> void:
	_route = get_node(route_path)
	_sun = get_node(sun_path)
	_player = get_node(player_path)
	if not sea_path.is_empty():
		_sea_mat = (get_node(sea_path) as MeshInstance3D).get_surface_override_material(0) as ShaderMaterial
	for p in extra_sea_paths:
		_extra_mats.append((get_node(p) as MeshInstance3D).get_surface_override_material(0) as ShaderMaterial)
	_env = (get_node(env_path) as WorldEnvironment).environment
	var course := _route.course
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--course="):
			course = a.substr(9)
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(courses_file))
	var c: Dictionary = data["courses"][course]
	_template = c["template"]
	_tod = Vector2(c["tod"][0], c["tod"][1])
	if c.has("fog"):
		_fog = Vector2(c["fog"][0], c["fog"][1])
	var cfg: Dictionary = data["templates"][_template]
	for node_name: String in cfg:
		var n := get_parent().get_node_or_null(node_name)
		if n == null:
			continue
		for k: String in cfg[node_name]:
			n.set(k, cfg[node_name][k])
	_update()

func _process(_d: float) -> void:
	_update()

func _update() -> void:
	if _route.curve == null:  # Route builds itself in its own _ready, after this node's
		return
	var p := lerpf(_tod.x, _tod.y, clampf(_route.clock() / (_route.total_minutes * 60.0), 0.0, 1.0))
	var elev := 4.0 + 46.0 * sin(p * PI)
	# sun azimuth is measured from the run direction, so a low sun stays in front-left (in view)
	var left := _route.left_at(_route.curve.get_closest_offset(_route.to_local(_player.global_position)))
	var fwd := Vector3(-left.z, 0.0, left.x)
	var alpha := deg_to_rad(lerpf(sun_left_deg.x, sun_left_deg.y, smoothstep(4.0, 35.0, elev)))
	var sd := Basis(Vector3.UP, alpha) * fwd  # direction toward the sun (horizontal)
	_sun.rotation_degrees = Vector3(-elev, rad_to_deg(atan2(sd.x, sd.z)), 0.0)
	if _sea_mat:
		_sea_mat.set_shader_parameter("sun_dir", _sun.global_transform.basis.z)
	for m in _extra_mats:
		m.set_shader_parameter("sun_dir", _sun.global_transform.basis.z)
	var warm := 1.0 - smoothstep(4.0, 28.0, elev)  # 1 near the horizon
	_sun.light_color = Color(1.0, 0.95, 0.88).lerp(Color(1.0, 0.6, 0.35), warm)
	_sun.light_energy = lerpf(1.5, 0.8, warm)
	_env.fog_light_color = Color(0.62, 0.75, 0.9).lerp(Color(0.95, 0.72, 0.58), warm)
	_env.ambient_light_energy = lerpf(1.4, 0.9, warm)
	if mist_enabled:
		# mist episodes: two slow sine waves, thresholded so there are clear spells and white-outs
		var t := _route.clock()
		var m := smoothstep(0.35, 0.85, 0.5 + 0.32 * sin(t / 173.0) + 0.22 * sin(t / 61.0 + 1.3) + 0.12 * sin(t / 419.0 + 2.0))
		_env.fog_density = _fog.x + _fog.y * m
		_env.fog_light_color = _env.fog_light_color.lerp(Color(0.86, 0.89, 0.93), m)
		_env.fog_sky_affect = lerpf(0.25, 1.0, m)
		_sun.light_energy *= lerpf(1.0, 0.45, m)
		_env.ambient_light_energy *= lerpf(1.0, 0.8, m)
