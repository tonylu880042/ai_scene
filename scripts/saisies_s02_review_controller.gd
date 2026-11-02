extends Node3D

## Fixed S02 review wrapper.
##
## The S01 controller stays in the tree so its normal exit restoration remains
## valid, but this wrapper pauses its _process after all deferred S01 writes have
## drained.  The existing CameraRig then holds the route's S02 acceptance station
## and pose with FOV 77; no route, camera data, or terrain is edited.

@export var world_path: NodePath = NodePath("../S01Review/World")
@export var s01_architecture_path: NodePath = NodePath("../S01Review/S01Architecture")
@export var s01_landscape_path: NodePath = NodePath("../S01Review/S01Landscape")
@export var s01_camera_controller_path: NodePath = NodePath("../S01Review/S01CameraController")
@export var lodge_refinement_path: NodePath = NodePath("../S02LodgeRefinement")

const S02_ID := "S02"
const S02_FOV_DEG := 77.0

var _world: Node3D
var _route: Node
var _rig: Node3D
var _camera: Camera3D
var _initialized := false
var _attempts := 0
var _settling := false

func _ready() -> void:
	process_priority = -90
	call_deferred("_try_initialize")

func _try_initialize() -> void:
	if _initialized or _settling:
		return
	_world = get_node_or_null(world_path) as Node3D
	_route = _world.get_node_or_null("Route") as Node if _world != null else null
	_rig = _world.get_node_or_null("CameraRig") as Node3D if _world != null else null
	_camera = _rig.get_node_or_null("Camera3D") as Camera3D if _rig != null else null
	var architecture := get_node_or_null(s01_architecture_path) as Node
	var landscape := get_node_or_null(s01_landscape_path) as Node
	var s01_controller := get_node_or_null(s01_camera_controller_path) as Node
	var lodge_refinement := get_node_or_null(lodge_refinement_path) as Node
	if _world == null or _route == null or _rig == null or _camera == null or architecture == null or landscape == null or s01_controller == null or lodge_refinement == null:
		_retry("S02 review controller dependencies are incomplete")
		return
	if not bool(architecture.get_meta("saisies_s01_architecture_ready", false)) or not bool(landscape.get_meta("saisies_s01_landscape_ready", false)) or not bool(landscape.get_meta("saisies_s01_actual_triangle_contact", false)):
		_retry("S02 review controller is waiting for S01 architecture/landscape")
		return
	if not bool(s01_controller.get_meta("saisies_s01_camera_controller_ready", false)):
		_retry("S02 review controller is waiting for S01 camera")
		return
	var s01_lodge := _world.get_node_or_null("VillageS01S02/S01S02Buildings/Right_Alpine_Lodge") as Node
	if s01_lodge == null or String(s01_lodge.get_meta("saisies_s01_lodge_visible_face_detail", "")).is_empty():
		_retry("S02 review controller is waiting for S01 visible lodge detail")
		return
	if not bool(lodge_refinement.get_meta("saisies_s02_lodge_refinement_ready", false)):
		_retry("S02 review controller is waiting for Intersection_Lodge refinement")
		return
	# Let the S01 architecture/camera deferred writes settle before taking the rig
	# over. The S01 node stays in the tree, preserving its _exit_tree restore.
	_settling = true
	call_deferred("_settle_and_apply", s01_controller)

func _settle_and_apply(s01_controller: Node) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if _initialized or not is_instance_valid(s01_controller):
		_settling = false
		return
	# The S01 wrapper's deferred pose must finish before the S02 fixed pose owns
	# the rig. Pause only its process; two complete frames drain its queued pose.
	s01_controller.set_process(false)
	s01_controller.set_physics_process(false)
	s01_controller.set_meta("saisies_s01_camera_paused_for_s02_review", true)
	await get_tree().process_frame
	await get_tree().process_frame
	if not _apply_s02_pose():
		_settling = false
		_retry("S02 review controller could not apply acceptance pose")
		return
	_initialized = true
	_settling = false
	set_meta("saisies_s02_review_ready", true)
	set_meta("saisies_s02_review_scene_id", S02_ID)
	set_meta("saisies_s02_review_fov_deg", S02_FOV_DEG)
	set_meta("saisies_s02_review_station_m", float(_route.call("acceptance_distance", S02_ID)))
	set_meta("saisies_s02_review_camera_mode", "fixed_acceptance_pose")
	set_meta("saisies_s02_review_deferred_frames_drained", 2)
	get_parent().set_meta("saisies_s02_review_ready", true)

func _apply_s02_pose() -> bool:
	if _route == null or _rig == null or _camera == null:
		return false
	if not _route.has_method("acceptance_distance") or not _route.has_method("acceptance_pose") or not _rig.has_method("reset_to_distance"):
		return false
	var station := float(_route.call("acceptance_distance", S02_ID))
	if not is_finite(station) or station < 0.0:
		return false
	_rig.set("auto_advance", false)
	_rig.call("reset_to_distance", station)
	if _rig.has_method("apply_acceptance_pose"):
		_rig.call("apply_acceptance_pose", S02_ID)
	else:
		return false
	_camera.fov = S02_FOV_DEG
	_camera.current = true
	_rig.set("auto_advance", false)
	_rig.set_meta("saisies_s02_review_controller", true)
	_rig.set_meta("saisies_s02_review_station_m", station)
	_rig.set_meta("saisies_s02_review_fov_deg", S02_FOV_DEG)
	return is_finite(_rig.global_position.x) and is_finite(_rig.global_position.y) and is_finite(_rig.global_position.z) and is_finite(_camera.fov)

func _retry(message: String) -> void:
	_attempts += 1
	if _attempts < 240:
		call_deferred("_try_initialize")
	else:
		set_meta("saisies_s02_review_ready", false)
		set_meta("saisies_s02_review_error", message)
		push_error(message)
