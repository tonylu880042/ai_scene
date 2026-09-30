extends CharacterBody3D

signal footstep(speed_ratio: float)  # emitted at each bob trough (foot strike)

@export_group("Movement")
@export var walk_speed := 1.5
@export var run_speed := 2.8
@export var acceleration := 12.0
@export var friction := 14.0
@export var gravity := 20.0

@export_group("Auto Run")
@export var pacer_path: NodePath   # PathFollow3D under a Path3D; runs ahead, player chases it
@export var start_auto := false
@export var auto_speed := 2.7778  # 6:00 min/km
@export var lookahead := 3.0       # metres the pacer stays ahead of the player (smaller = hugs the centre line)

@export_group("Look")
@export var mouse_sensitivity := 0.002
@export var look_smoothing := 25.0  # higher = snappier
@export var pitch_limit_deg := 80.0

@export_group("Head Bob")
@export var head_bob_enabled := false  # off = perfectly steady camera (footsteps still follow the cadence)
@export var step_freq_walk := 1.8   # steps per second
@export var step_freq_run := 2.8
@export var bob_y := 0.07           # vertical amplitude at run speed (m)
@export var bob_x := 0.035          # horizontal amplitude at run speed (m)
@export var roll_deg := 0.8         # roll tilt at run speed
@export var bob_blend := 8.0        # how fast bob fades in/out

@onready var cam: Camera3D = $Camera3D

var _yaw := 0.0
var _pitch := 0.0
var _phase := 0.0
var _step_idx := 1
var _bob_amp := 0.0
var _cam_rest: Vector3
var pacer: PathFollow3D
var _auto := false

func _ready() -> void:
	pacer = get_node_or_null(pacer_path)
	if pacer:  # start on the path centre line, facing along it
		var route: Route = pacer.get_parent()
		global_position = route.pos_at(route.start_offset) + Vector3.UP
		var d := route.pos_at(route.start_offset + 3.0) - route.pos_at(route.start_offset)
		rotation.y = atan2(-d.x, -d.z)
	_cam_rest = cam.position
	_yaw = rotation.y
	_auto = start_auto and pacer != null
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= e.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - e.relative.y * mouse_sensitivity,
				deg_to_rad(-pitch_limit_deg), deg_to_rad(pitch_limit_deg))
	elif e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif e is InputEventKey and e.pressed and e.keycode == KEY_TAB and pacer:
		_auto = not _auto
	elif e is InputEventMouseButton and e.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	if _auto:
		var path: Path3D = pacer.get_parent()
		pacer.progress = path.curve.get_closest_offset(path.to_local(global_position)) + lookahead
		var d := pacer.global_position - global_position
		_yaw = atan2(-d.x, -d.z)

	# smooth look
	var k := 1.0 - exp(-look_smoothing * delta)
	rotation.y = lerp_angle(rotation.y, _yaw, k)
	cam.rotation.x = lerpf(cam.rotation.x, _pitch, k)

	# movement (physical keys: no InputMap setup needed)
	var dir := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))
	).limit_length(1.0)
	var wish := (transform.basis * Vector3(dir.x, 0, dir.y)).normalized() * dir.length()
	var target_speed := run_speed if Input.is_physical_key_pressed(KEY_SHIFT) else walk_speed
	if _auto:
		dir = Vector2(0, -1)
		wish = -transform.basis.z
		target_speed = auto_speed

	var horiz := Vector3(velocity.x, 0, velocity.z)
	if dir != Vector2.ZERO:
		horiz = horiz.move_toward(wish * target_speed, acceleration * delta)
	else:
		horiz = horiz.move_toward(Vector3.ZERO, friction * delta)
	velocity.x = horiz.x
	velocity.z = horiz.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - gravity * delta
	move_and_slide()

	_head_bob(delta, horiz.length())

func _head_bob(delta: float, speed: float) -> void:
	var ratio := clampf(speed / run_speed, 0.0, 1.0)
	_bob_amp = lerpf(_bob_amp, ratio if is_on_floor() else 0.0, 1.0 - exp(-bob_blend * delta))
	var freq := lerpf(step_freq_walk, step_freq_run, clampf((speed - walk_speed) / (run_speed - walk_speed), 0.0, 1.0))
	if speed > 0.1:
		_phase = fmod(_phase + TAU * freq * delta, TAU * 2.0)  # 2 steps = 1 stride
	var idx := posmod(floori((_phase - 1.5 * PI) / TAU), 2)  # sin(_phase) trough = foot strike
	if idx != _step_idx:
		_step_idx = idx
		if _bob_amp > 0.2:
			footstep.emit(ratio)
	# vertical: once per step; lateral + roll: once per stride (weight shift)
	var stride := _phase * 0.5
	if head_bob_enabled:
		cam.position = _cam_rest + Vector3(cos(stride) * bob_x, sin(_phase) * bob_y, 0.0) * _bob_amp
		cam.rotation.z = cos(stride) * deg_to_rad(roll_deg) * _bob_amp
