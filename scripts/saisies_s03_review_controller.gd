extends Node3D

## Fixed S03 review wrapper over the accepted S02 scene.
##
## S02Review remains instanced and is allowed to finish its S01 handoff first.
## After two settling frames this controller pauses S02ReviewController, drains
## two more frames, and owns only the shared rig's S03 acceptance pose.

@export var s02_review_path: NodePath = NodePath("../S02Review")
@export var world_path: NodePath = NodePath("../S02Review/S01Review/World")
@export var s02_controller_path: NodePath = NodePath("../S02Review/S02ReviewController")
@export var s01_camera_controller_path: NodePath = NodePath("../S02Review/S01Review/S01CameraController")
@export var junction_refinement_path: NodePath = NodePath("../S03JunctionRefinement")

const S03_ID := "S03"
const S03_FOV_DEG := 77.0

var _s02_review: Node
var _world: Node3D
var _route: Node
var _rig: Node3D
var _camera: Camera3D
var _initialized := false
var _settling := false
var _attempts := 0

func _ready() -> void:
	process_priority = -90
	call_deferred("_try_initialize")

func _try_initialize() -> void:
	if _initialized or _settling:
		return
	_s02_review = get_node_or_null(s02_review_path)
	_world = get_node_or_null(world_path) as Node3D
	_route = _world.get_node_or_null("Route") as Node if _world != null else null
	_rig = _world.get_node_or_null("CameraRig") as Node3D if _world != null else null
	_camera = _rig.get_node_or_null("Camera3D") as Camera3D if _rig != null else null
	var s02_controller := get_node_or_null(s02_controller_path) as Node
	var s01_camera_controller := get_node_or_null(s01_camera_controller_path) as Node
	var junction := get_node_or_null(junction_refinement_path) as Node
	if _s02_review == null or _world == null or _route == null or _rig == null or _camera == null or s02_controller == null or s01_camera_controller == null or junction == null:
		_retry("S03 review controller dependencies are incomplete")
		return
	if not bool(_s02_review.get_meta("saisies_s02_review_ready", false)):
		_retry("S03 review controller is waiting for S02 fixed review pose")
		return
	if not bool(junction.get_meta("saisies_s03_junction_refinement_ready", false)):
		_retry("S03 review controller is waiting for junction refinement")
		return
	if not bool(s01_camera_controller.get_meta("saisies_s01_camera_controller_ready", false)):
		_retry("S03 review controller is waiting for S01 camera controller")
		return
	_settling = true
	call_deferred("_settle_and_apply", s02_controller)

func _settle_and_apply(s02_controller: Node) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if _initialized or not is_instance_valid(s02_controller):
		_settling = false
		return
	s02_controller.set_process(false)
	s02_controller.set_physics_process(false)
	s02_controller.set_meta("saisies_s02_camera_paused_for_s03_review", true)
	await get_tree().process_frame
	await get_tree().process_frame
	if not _apply_s03_pose():
		_settling = false
		_retry("S03 review controller could not apply acceptance pose")
		return
	_initialized = true
	_settling = false
	set_meta("saisies_s03_review_ready", true)
	set_meta("saisies_s03_review_scene_id", S03_ID)
	set_meta("saisies_s03_review_fov_deg", S03_FOV_DEG)
	set_meta("saisies_s03_review_station_m", float(_route.call("acceptance_distance", S03_ID)))
	set_meta("saisies_s03_review_camera_mode", "fixed_acceptance_pose")
	set_meta("saisies_s03_review_deferred_frames_drained", 2)
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s03_review_ready", true)
		parent.set_meta("saisies_s03_review_scene_id", S03_ID)
		parent.set_meta("saisies_s03_review_fov_deg", S03_FOV_DEG)
		parent.set_meta("saisies_s03_review_station_m", float(_route.call("acceptance_distance", S03_ID)))

func _apply_s03_pose() -> bool:
	if _route == null or _rig == null or _camera == null:
		return false
	if not _route.has_method("acceptance_distance") or not _rig.has_method("reset_to_distance") or not _rig.has_method("apply_acceptance_pose"):
		return false
	var station := float(_route.call("acceptance_distance", S03_ID))
	if not is_finite(station) or station < 0.0:
		return false
	_rig.set("auto_advance", false)
	_rig.call("reset_to_distance", station)
	_rig.call("apply_acceptance_pose", S03_ID)
	_camera.fov = S03_FOV_DEG
	_camera.current = true
	_rig.set("auto_advance", false)
	_rig.set_meta("saisies_s03_review_controller", true)
	_rig.set_meta("saisies_s03_review_station_m", station)
	_rig.set_meta("saisies_s03_review_fov_deg", S03_FOV_DEG)
	return is_finite(_rig.global_position.x) and is_finite(_rig.global_position.y) and is_finite(_rig.global_position.z) and is_finite(_camera.fov)

func _retry(message: String) -> void:
	_attempts += 1
	if _attempts < 240:
		call_deferred("_retry_next_frame")
	else:
		set_meta("saisies_s03_review_ready", false)
		set_meta("saisies_s03_review_error", message)
		push_error(message)

func _retry_next_frame() -> void:
	await get_tree().process_frame
	_try_initialize()
