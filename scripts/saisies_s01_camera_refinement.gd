extends RefCounted

## Runtime-only S01 camera candidate applicator.
##
## This helper is intentionally separate from SaisiesGeoCamera and the frozen
## R14 bake.  It resolves the scene's CameraRig from a supplied world node,
## places that rig on the existing route, and changes only the runtime pose and
## Camera3D FOV. An explicit candidate roll may also be supplied. It does not
## edit route data, scene maps, terrain, or authored
## geometry.  Values are visual candidates, not calibrated camera/GPS data.

const MAX_S01_STATION_M := 220.0
const DEFAULT_HEIGHT_M := 1.65
const DEFAULT_FOV_DEG := 79.0

var world_path := NodePath("CameraRig")

func apply_candidate(world: Node, candidate: Dictionary) -> Dictionary:
	if world == null:
		return {"ok": false, "error": "world node is null"}
	var route := world.get_node_or_null("Route") as Node
	if route == null:
		return {"ok": false, "error": "Route node is missing"}
	var rig := _resolve_rig(world)
	if rig == null:
		return {"ok": false, "error": "CameraRig node is missing"}
	var camera := rig.find_child("Camera3D", true, false) as Camera3D
	if camera == null:
		return {"ok": false, "error": "CameraRig/Camera3D is missing"}
	if not route.has_method("pos_at") or not route.has_method("left_at") or not route.has_method("ground_y") or not route.has_method("tangent_at"):
		return {"ok": false, "error": "Route does not expose the required placement API"}

	var route_length := float(route.get("length_m"))
	var station_m := float(candidate.get("station_m", 50.0))
	if not is_finite(station_m) or station_m < 0.0 or station_m > MAX_S01_STATION_M:
		return {"ok": false, "error": "S01 station %.3f is outside 0..%.1f m" % [station_m, MAX_S01_STATION_M]}
	if route_length > 0.0 and station_m > route_length:
		return {"ok": false, "error": "S01 station %.3f exceeds route length %.3f m" % [station_m, route_length]}

	var pitch_deg := float(candidate.get("pitch_deg", -16.0))
	var yaw_deg := float(candidate.get("yaw_deg", 20.0))
	var lateral_m := float(candidate.get("lateral_m", -1.7))
	var fov_deg := float(candidate.get("fov_deg", DEFAULT_FOV_DEG))
	var height_m := float(candidate.get("height_m", DEFAULT_HEIGHT_M))
	var roll_deg := float(candidate.get("roll_deg", NAN))
	for value in [pitch_deg, yaw_deg, lateral_m, fov_deg, height_m]:
		if not is_finite(float(value)):
			return {"ok": false, "error": "candidate contains a non-finite camera value"}
	if not is_finite(roll_deg):
		# Existing SaisiesCamera computes road-turn roll. Preserve it when a
		# candidate does not explicitly request an override.
		roll_deg = rad_to_deg(float(rig.rotation.z))
	if roll_deg < -45.0 or roll_deg > 45.0:
		return {"ok": false, "error": "roll %.3f is outside -45..45 degrees" % roll_deg}
	if fov_deg < 30.0 or fov_deg > 120.0:
		return {"ok": false, "error": "FOV %.3f is outside 30..120 degrees" % fov_deg}
	if height_m < 0.5 or height_m > 5.0:
		return {"ok": false, "error": "camera height %.3f is outside 0.5..5.0 m" % height_m}

	# SaisiesCamera already owns the route placement contract.  Use its public
	# reset method first, then freeze processing before applying candidate-only
	# offsets, so the existing interpolation/ground_y code remains authoritative.
	if rig.has_method("reset_to_distance"):
		rig.set("auto_advance", false)
		rig.call("reset_to_distance", station_m)
	rig.set_process(false)
	rig.set_physics_process(false)

	var route_point: Vector3 = route.call("pos_at", station_m)
	var left: Vector3 = route.call("left_at", station_m)
	var ground_y := float(route.call("ground_y", station_m, lateral_m))
	var tangent: Vector3 = route.call("tangent_at", station_m)
	if tangent.length_squared() <= 0.000001:
		return {"ok": false, "error": "route tangent is degenerate at %.3f m" % station_m}
	var heading := atan2(-tangent.x, -tangent.z)
	var rig_position := route_point + left * lateral_m
	rig.global_position = Vector3(rig_position.x, ground_y + 0.02, rig_position.z)
	rig.rotation = Vector3(deg_to_rad(pitch_deg), heading + deg_to_rad(yaw_deg), deg_to_rad(roll_deg))
	camera.position = Vector3(0.0, height_m, 0.0)
	camera.fov = fov_deg
	camera.current = true
	rig.set_meta("saisies_s01_camera_refinement", true)
	rig.set_meta("saisies_s01_camera_candidate_id", String(candidate.get("id", "unnamed")))
	rig.set_meta("saisies_s01_camera_station_m", station_m)
	rig.set_meta("saisies_s01_camera_pose_estimated", true)

	return {
		"ok": true,
		"candidate_id": String(candidate.get("id", "unnamed")),
		"station_m": station_m,
		"pitch_deg": pitch_deg,
		"yaw_deg": yaw_deg,
		"lateral_m": lateral_m,
		"height_m": height_m,
		"fov_deg": fov_deg,
		"route_point": _vec3_array(route_point),
		"rig_position": _vec3_array(rig.global_position),
		"camera_world_position": _vec3_array(camera.global_position),
		"heading_deg": rad_to_deg(heading),
		"roll_deg": roll_deg,
		"ground_y_m": ground_y,
		"route_length_m": route_length
	}

func _resolve_rig(world: Node) -> Node3D:
	var rig := world.get_node_or_null(world_path) as Node3D
	if rig != null:
		return rig
	return world.find_child("CameraRig", true, false) as Node3D

func _vec3_array(value: Vector3) -> Array[float]:
	return [value.x, value.y, value.z]
