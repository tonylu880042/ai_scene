class_name SaisiesGeoCamera
extends SaisiesCamera

## Geo-only camera overlay.
##
## The geographic route has its own candidate source-view offsets.  This class
## layers those offsets over the inherited v2 cache only when the route exposes
## the SaisiesGeoRoute frame API; the shipped v2 camera and scene map remain
## untouched.  Values are estimated visual poses, not camera calibration/GPS.

const GEO_POSE_FILE := "res://data/saisies_geo_camera_poses.json"

var _geo_pose_cache_ready := false

func _cache_acceptance_poses() -> void:
	super._cache_acceptance_poses()
	# SaisiesRoute intentionally has no frame() method.  This guard keeps the
	# geo pose file from affecting the existing v2 camera in any scene.
	if route == null or not route.has_method("frame") or not _acceptance_cache_ready:
		return
	if _geo_pose_cache_ready:
		return
	_geo_pose_cache_ready = true
	if not FileAccess.file_exists(GEO_POSE_FILE):
		push_error("SaisiesGeoCamera pose file is missing: %s" % GEO_POSE_FILE)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(GEO_POSE_FILE))
	if not (parsed is Dictionary):
		push_error("SaisiesGeoCamera pose file is not a JSON object")
		return
	var payload: Dictionary = parsed
	if int(payload.get("schema_version", 0)) != 1 or String(payload.get("scope", "")) != "geo-only" or payload.get("estimated", false) != true:
		push_error("SaisiesGeoCamera pose metadata has invalid schema/scope/estimated fields")
		return
	# Camera defaults are part of the geo camera contract and are applied once,
	# after the base node has created its Camera3D child.
	var configured_height := float(payload.get("camera_height_m", camera_height))
	var configured_fov := float(payload.get("fov_deg", _camera.fov if _camera != null else 78.0))
	if not is_finite(configured_height) or configured_height < 0.5 or configured_height > 5.0:
		push_error("SaisiesGeoCamera camera_height_m is outside 0.5..5.0 m")
		return
	if not is_finite(configured_fov) or configured_fov < 30.0 or configured_fov > 120.0:
		push_error("SaisiesGeoCamera fov_deg is outside 30..120 degrees")
		return
	camera_height = configured_height
	if _camera != null:
		_camera.position.y = camera_height
		_camera.fov = configured_fov
	set_meta("saisies_geo_camera_estimated", true)
	set_meta("saisies_geo_camera_pose_file", GEO_POSE_FILE)
	set_meta("saisies_geo_camera_source_evidence", String(payload.get("source_evidence", "")))
	set_meta("saisies_geo_camera_note", String(payload.get("note", "")))
	for item in payload.get("poses", []):
		if not (item is Dictionary):
			push_error("SaisiesGeoCamera pose entry is not an object")
			continue
		var scene_id := String(item.get("scene_id", "")).to_upper()
		if not ACCEPTANCE_SCENE_IDS.has(scene_id):
			push_error("SaisiesGeoCamera pose references unknown scene id: %s" % scene_id)
			continue
		var pitch_deg := float(item.get("pitch_deg", DEFAULT_ACCEPTANCE_PITCH_DEG))
		var yaw_deg := float(item.get("yaw_deg", 0.0))
		var lateral_m := float(item.get("lateral_m", _acceptance_lateral_by_id.get(scene_id, 0.0)))
		if not is_finite(pitch_deg) or not is_finite(yaw_deg) or not is_finite(lateral_m):
			push_error("SaisiesGeoCamera pose %s contains non-finite values" % scene_id)
			continue
		if pitch_deg < -45.0 or pitch_deg > 45.0 or yaw_deg < -180.0 or yaw_deg > 180.0:
			push_error("SaisiesGeoCamera pose %s has an unreasonable pitch/yaw" % scene_id)
			continue
		var pose := Vector2(deg_to_rad(pitch_deg), deg_to_rad(yaw_deg))
		_acceptance_pose_by_id[scene_id] = pose
		_acceptance_lateral_by_id[scene_id] = lateral_m
		var distance := float(route.call("acceptance_distance", scene_id))
		var max_lateral := maxf(float(route.call("road_width_at", distance)) * 0.5 - 0.15, 0.0)
		if absf(lateral_m) > max_lateral + 0.001:
			push_error("SaisiesGeoCamera pose %s lateral %.3f exceeds road half-width margin %.3f" % [scene_id, lateral_m, max_lateral])
			_acceptance_pose_by_id.erase(scene_id)
			_acceptance_lateral_by_id.erase(scene_id)
			continue
		var index := _acceptance_index_for_distance(distance)
		if index < 0:
			push_error("SaisiesGeoCamera pose %s has no matching continuous anchor" % scene_id)
			continue
		# Keep normal traversal and explicit scene-id placement synchronized.
		_acceptance_pitches[index] = pose.x
		_acceptance_yaws[index] = pose.y
		_acceptance_laterals[index] = lateral_m

func _acceptance_index_for_distance(distance: float) -> int:
	for index in range(_acceptance_distances.size()):
		if absf(float(_acceptance_distances[index]) - distance) <= 0.01:
			return index
	return -1
