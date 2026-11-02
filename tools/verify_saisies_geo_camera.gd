extends SceneTree

## Headless contract checks for the geo-only Saisies camera.
##
## This probe builds the actual SaisiesGeoRoute samples and the camera script,
## but deliberately skips road/terrain meshes.  It checks the authored source
## view poses, their interpolated traversal, and the v2 camera contract in the
## same process.  Geo pose values are estimated visual source-view offsets;
## they are not camera calibration or GPS.

const GEO_ROUTE_SCRIPT_PATH := "res://scripts/saisies_geo_route.gd"
const GEO_ROUTE_FILE := "res://data/saisies_geo_route.json"
const GEO_CAMERA_SCRIPT_PATH := "res://scripts/saisies_geo_camera.gd"
const GEO_POSE_FILE := "res://data/saisies_geo_camera_poses.json"
const V2_ROUTE_SCRIPT_PATH := "res://scripts/saisies_route.gd"
const V2_ROUTE_FILE := "res://data/saisies_route_v2.json"
const V2_CAMERA_SCRIPT_PATH := "res://scripts/saisies_camera.gd"
const V2_SCENE_MAP_FILE := "res://data/saisies_scene_map.json"
const GEO_SCENE_MAP_FILE := "res://data/saisies_geo_scene_map.json"
const ACCEPTANCE_FRAMES_FILE := "res://data/saisies_acceptance_frames.json"
const SCENE_IDS := [
	"S01", "S02", "S03", "S04", "S05", "S06", "S07", "S08", "S09",
	"S10", "S11", "S12", "S13", "S14", "S15", "S16", "S17", "S18"
]
const POSE_EPSILON_DEG := 0.05
const LATERAL_EPSILON_M := 0.01
const CONTINUITY_STEP_M := 1.0
const MAX_LOCAL_PITCH_STEP_DEG := 8.0
const MAX_LOCAL_YAW_STEP_DEG := 10.0
const MAX_LOCAL_LATERAL_STEP_M := 0.20
const MAX_GLOBAL_STEP_M := 4.0
const S13_DISTANCE_M := 10120.0
const REFERENCE_SHA256_BY_ID := {
	"S01": "b25ceb90f56481c1c5f1a4ae2d4e4afdf111673e2374b7ec2123d8dbd3bd65d3",
	"S02": "3c692e306cd0ebcb6eb677f7b18678f8379e6c8bbdfdab782a2f32dd8fc3c958",
	"S03": "184ee032aef47be5d52b5d5c6379300dc4dca85054ada0b93ef07ed8ca043e10",
	"S04": "dffa0a24785095907ccb27b149920438a2a2a0681dbeb83aad4e33cc0b6a3f85",
	"S05": "85a115fd19b10d3bbee9128a42f73401014e6c17b91afef8c95fd1fde0fbdd3f",
	"S06": "5775a60dfefcafcb02ed6dde3b65785cd79461edce53cda93bfbdee31fc511ed",
	"S07": "bb51995e4e6c75c1380e3d5bb8e8a41f5408d2379a8450c6a2f8d41ec78ff7ef",
	"S08": "efd6f3fd643654c9f240d2754f08c034675ba78ac98f576434e218a369910eb8",
	"S09": "f239b8983d1930c8172235f00150a7d2d426f58e8232c1cfa038611dc838cc62",
	"S10": "aa172e42e6553f6be05c5ba559ae9724e51b92b5338d96aa62bb3a76f97baa12",
	"S11": "8ecf345dc27eb5becdfbe5bd681b601b376fc21f5b2cbe50d460288ea3dbf6e2",
	"S12": "84393afa4d08534aca1981b8e8940a64ba69cd47ba2252655620bef91f642a10",
	"S13": "1852d363527548291532c2f7c267d61a0f54add9379bbc151f0f733d2c1eb2fa",
	"S14": "7510c66f179fafa1babdd46687c81453f9a88912e7f9969aee2566379654583c",
	"S15": "8b00375f35d287ba894e87a3e6bef630e19862ccef5d2daed1f3f9c61d9b0ba5",
	"S16": "fbee0cc9fcc5b8e0deed504c88ba4f6cc883a850d1fe8c2a609d2643709ab21f",
	"S17": "cedbbb1604988dedf2ff19a6daf0e68a76caf7fdb61f4d0a66d5b063c5e2a120",
	"S18": "5937c9561f740c15ea22cf74d1152f74a4fab18bc9ad07d16825fb83adbb7473"
}

class GeoProbeRoute extends SaisiesGeoRoute:
	func _ready() -> void:
		# Build route samples explicitly and avoid the production road/terrain meshes.
		pass

class V2ProbeRoute extends SaisiesRoute:
	func _ready() -> void:
		# Build route samples explicitly and avoid the production road/terrain meshes.
		pass

var _errors: Array[String] = []
var _geo_holder: Node3D
var _geo_route: SaisiesGeoRoute
var _geo_rig: SaisiesCamera
var _v2_holder: Node3D
var _v2_route: SaisiesRoute
var _v2_rig: SaisiesCamera
var _geo_pose_by_id: Dictionary = {}
var _child_scene_id := ""

func _initialize() -> void:
	for argument in _all_cmdline_args():
		var text := String(argument)
		if text.begins_with("--child-scene-id="):
			_child_scene_id = text.substr(17).to_upper()
	call_deferred("_run")

func _all_cmdline_args() -> PackedStringArray:
	var arguments := OS.get_cmdline_args()
	arguments.append_array(OS.get_cmdline_user_args())
	return arguments

func _run() -> void:
	if not _child_scene_id.is_empty():
		await _run_child_static(_child_scene_id)
		_finish()
		return
	if not await _build_geo_probe(false):
		_finish()
		return
	_load_geo_pose_metadata()
	_verify_geo_route_contract()
	_verify_geo_camera_contract()
	_verify_geo_traversal()
	await _verify_fresh_static_process()
	if not await _build_v2_probe():
		_finish()
		return
	_verify_v2_contract()
	_finish()

func _build_geo_probe(initial_auto_advance: bool) -> bool:
	var route_script := load(GEO_ROUTE_SCRIPT_PATH) as Script
	var camera_script := load(GEO_CAMERA_SCRIPT_PATH) as Script
	if route_script == null or camera_script == null:
		_fail("could not load geo route or camera script")
		return false
	var route := GeoProbeRoute.new() as SaisiesGeoRoute
	route.name = "SaisiesGeoRouteCameraVerify"
	route.geo_route_file = GEO_ROUTE_FILE
	# SaisiesGeoRoute's production _ready builds large meshes.  The probe uses
	# the same loader/sample/curve API while intentionally omitting those meshes.
	route._load_route_data()
	route._build_samples()
	route._build_curve()
	_geo_holder = Node3D.new()
	_geo_holder.name = "SaisiesGeoCameraVerification"
	_geo_route = route
	_geo_holder.add_child(route)
	var rig := camera_script.new() as SaisiesCamera
	if rig == null:
		_fail("geo camera script does not extend SaisiesCamera")
		return false
	rig.name = "CameraRig"
	rig.route_path = NodePath("../SaisiesGeoRouteCameraVerify")
	rig.auto_advance = initial_auto_advance
	rig.camera_height = 1.65
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.current = true
	camera.fov = 78.0
	rig.add_child(camera)
	_geo_rig = rig
	_geo_holder.add_child(rig)
	get_root().add_child(_geo_holder)
	await process_frame
	if _geo_rig.route == null:
		_fail("geo camera did not resolve its SaisiesGeoRoute")
		return false
	return true

func _build_v2_probe() -> bool:
	var route_script := load(V2_ROUTE_SCRIPT_PATH) as Script
	var camera_script := load(V2_CAMERA_SCRIPT_PATH) as Script
	if route_script == null or camera_script == null:
		_fail("could not load v2 route or camera script")
		return false
	var route := V2ProbeRoute.new() as SaisiesRoute
	route.name = "SaisiesV2RouteCameraVerify"
	route.route_file = V2_ROUTE_FILE
	route._load_route_data()
	route._build_samples()
	route._build_curve()
	_v2_holder = Node3D.new()
	_v2_holder.name = "SaisiesV2CameraVerification"
	_v2_route = route
	_v2_holder.add_child(route)
	var rig := camera_script.new() as SaisiesCamera
	rig.name = "CameraRig"
	rig.route_path = NodePath("../SaisiesV2RouteCameraVerify")
	rig.auto_advance = false
	rig.camera_height = 1.65
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.current = false
	camera.fov = 78.0
	rig.add_child(camera)
	_v2_rig = rig
	_v2_holder.add_child(rig)
	get_root().add_child(_v2_holder)
	await process_frame
	if _v2_rig.route == null:
		_fail("v2 camera did not resolve its route")
		return false
	return true

func _load_geo_pose_metadata() -> void:
	if not FileAccess.file_exists(GEO_POSE_FILE):
		_fail("missing geo camera pose file: %s" % GEO_POSE_FILE)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(GEO_POSE_FILE))
	if not (parsed is Dictionary):
		_fail("geo camera pose file is not a JSON object")
		return
	var payload: Dictionary = parsed
	if int(payload.get("schema_version", 0)) != 1 or String(payload.get("scope", "")) != "geo-only" or payload.get("estimated", false) != true:
		_fail("geo camera pose metadata has invalid schema/scope/estimated fields")
	var source_evidence := String(payload.get("source_evidence", ""))
	if source_evidence.is_empty() or not FileAccess.file_exists(source_evidence):
		_fail("geo camera pose metadata source_evidence is missing: %s" % source_evidence)
	var configured_height := float(payload.get("camera_height_m", NAN))
	var configured_fov := float(payload.get("fov_deg", NAN))
	if not is_finite(configured_height) or configured_height < 0.5 or configured_height > 5.0:
		_fail("geo camera height metadata is outside 0.5..5.0 m")
	if not is_finite(configured_fov) or configured_fov < 30.0 or configured_fov > 120.0:
		_fail("geo camera FOV metadata is outside 30..120 degrees")
	for item in payload.get("poses", []):
		if not (item is Dictionary):
			_fail("geo camera pose list contains a non-object")
			continue
		var scene_id := String(item.get("scene_id", "")).to_upper()
		if not SCENE_IDS.has(scene_id):
			_fail("geo camera pose references unknown scene id: %s" % scene_id)
			continue
		var pitch_deg := float(item.get("pitch_deg", NAN))
		var yaw_deg := float(item.get("yaw_deg", NAN))
		var lateral_m := float(item.get("lateral_m", NAN))
		if not is_finite(pitch_deg) or not is_finite(yaw_deg) or not is_finite(lateral_m):
			_fail("geo camera pose %s contains non-finite values" % scene_id)
			continue
		if pitch_deg < -45.0 or pitch_deg > 45.0 or yaw_deg < -180.0 or yaw_deg > 180.0:
			_fail("geo camera pose %s has an unreasonable pitch/yaw" % scene_id)
		var distance := float(_geo_route.acceptance_distance(scene_id))
		var max_lateral := maxf(_geo_route.road_width_at(distance) * 0.5 - 0.15, 0.0)
		if absf(lateral_m) > max_lateral + 0.001:
			_fail("geo camera pose %s lateral %.3f exceeds road half-width margin %.3f" % [scene_id, lateral_m, max_lateral])
		_geo_pose_by_id[scene_id] = item.duplicate(true)
	if not _geo_pose_by_id.has("S13"):
		_fail("geo camera pose file does not contain the S13 candidate")

func _verify_geo_route_contract() -> void:
	if _geo_route == null or not _geo_route.geography_ready:
		_fail("geo route did not configure the shared geography helper")
		return
	if not _finite_vec3(_geo_route.pos_at(0.0)) or not _finite_vec3(_geo_route.pos_at(_geo_route.length_m)):
		_fail("geo route endpoint position is non-finite")
	if _geo_route.length_m < 14000.0 or _geo_route.length_m > 16000.0:
		_fail("unexpected geo route length %.3f m" % _geo_route.length_m)
	var previous_distance := -INF
	for scene_id in SCENE_IDS:
		var distance := float(_geo_route.acceptance_distance(scene_id))
		if not is_finite(distance) or distance < -0.001 or distance > _geo_route.length_m + 0.001:
			_fail("geo anchor %s is outside route: %.3f m" % [scene_id, distance])
		if distance <= previous_distance:
			_fail("geo scene anchors are not strictly increasing at %s" % scene_id)
		previous_distance = distance
	if absf(float(_geo_route.acceptance_distance("S13")) - S13_DISTANCE_M) > 0.01:
		_fail("geo S13 station %.6f != candidate %.6f" % [_geo_route.acceptance_distance("S13"), S13_DISTANCE_M])
	if not FileAccess.file_exists(GEO_SCENE_MAP_FILE):
		_fail("missing geo scene map: %s" % GEO_SCENE_MAP_FILE)
	else:
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(GEO_SCENE_MAP_FILE))
		if not (parsed is Dictionary):
			_fail("geo scene map is not a JSON object")
		else:
			var payload: Dictionary = parsed
			if int(payload.get("schema_version", 0)) != 1 or payload.get("estimated", false) != true:
				_fail("geo scene map has invalid schema/estimated provenance")
			var found_s13 := false
			for item in payload.get("scenes", []):
				if item is Dictionary and String(item.get("scene_id", "")) == "S13":
					found_s13 = true
					if absf(float(item.get("distance_m", NAN)) - S13_DISTANCE_M) > 0.01:
						_fail("geo scene map S13 distance differs from candidate")
					if not bool(item.get("estimated", false)):
						_fail("geo scene map S13 lacks candidate/inference provenance")
					if String(item.get("source_evidence", "")).is_empty() or not FileAccess.file_exists(String(item.get("source_evidence", ""))):
						_fail("geo scene map S13 source_evidence is missing")
			if not found_s13:
				_fail("geo scene map has no S13 anchor")
	_verify_reference_time_mapping()

func _verify_reference_time_mapping() -> void:
	if not FileAccess.file_exists(ACCEPTANCE_FRAMES_FILE):
		_fail("missing acceptance frame manifest: %s" % ACCEPTANCE_FRAMES_FILE)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(ACCEPTANCE_FRAMES_FILE))
	if not (parsed is Dictionary):
		_fail("acceptance frame manifest is not a JSON object")
		return
	var found := {}
	for item in parsed.get("scenes", []):
		if not (item is Dictionary):
			continue
		var scene_id := String(item.get("scene_id", "")).to_upper()
		if not SCENE_IDS.has(scene_id):
			continue
		found[scene_id] = true
		var requested := float(item.get("requested_seconds", NAN))
		var mapped := float(_geo_route.distance_for_video_seconds(requested))
		var accepted := float(_geo_route.acceptance_distance(scene_id))
		if not is_finite(requested) or absf(mapped - accepted) > 0.05:
			_fail("geo time mapping %s %.3f != acceptance %.3f" % [scene_id, mapped, accepted])
		var reference_path := String(item.get("reference_image", ""))
		if reference_path.is_empty() or not FileAccess.file_exists(reference_path):
			_fail("missing source reference for %s: %s" % [scene_id, reference_path])
		elif REFERENCE_SHA256_BY_ID.has(scene_id):
			var digest := _sha256_file(reference_path)
			if digest != String(REFERENCE_SHA256_BY_ID[scene_id]):
				_fail("source reference hash changed for %s: %s" % [scene_id, digest])
	for scene_id in SCENE_IDS:
		if not found.has(scene_id):
			_fail("acceptance frame manifest omits %s" % scene_id)

func _verify_geo_camera_contract() -> void:
	if _geo_rig == null:
		_fail("geo camera rig is missing")
		return
	var camera := _geo_rig.get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		_fail("geo camera rig lacks Camera3D")
	else:
		if absf(camera.position.y - 1.65) > 0.001:
			_fail("geo camera height %.3f != 1.650" % camera.position.y)
		if absf(camera.fov - 78.0) > 0.001:
			_fail("geo camera FOV %.3f != 78.000" % camera.fov)
	if not _geo_rig.get_meta("saisies_geo_camera_estimated", false):
		_fail("geo camera did not expose estimated pose metadata")
	if String(_geo_rig.get_meta("saisies_geo_camera_pose_file", "")) != GEO_POSE_FILE:
		_fail("geo camera metadata points at the wrong pose file")
	# Explicit scene-id and normal traversal must agree at every anchor.  This
	# also verifies the S13 geo override is synchronized into both cache forms.
	for scene_id in SCENE_IDS:
		_verify_static_and_normal_pose(scene_id)

func _verify_static_and_normal_pose(scene_id: String) -> void:
	var distance := float(_geo_route.acceptance_distance(scene_id))
	_geo_rig.auto_advance = false
	_geo_rig.reset_to_distance(distance)
	_geo_rig.apply_acceptance_pose(scene_id)
	if absf(_geo_rig.distance_m - distance) > 0.01:
		_fail("static %s distance %.3f != %.3f" % [scene_id, _geo_rig.distance_m, distance])
	_verify_geo_pose_values(scene_id, "static")
	var static_position := _geo_rig.global_position
	var static_rotation := _geo_rig.rotation
	for _frame in range(2):
		await process_frame
	if absf(_geo_rig.distance_m - distance) > 0.01:
		_fail("static %s advanced while auto_advance=false" % scene_id)
	_verify_geo_pose_values(scene_id, "static-after-frames")
	_geo_rig.apply_acceptance_pose("")
	_geo_rig.reset_to_distance(distance)
	_verify_geo_pose_values(scene_id, "normal-anchor")
	if static_position.distance_to(_geo_rig.global_position) > 0.05:
		_fail("static/normal %s global position differs by %.3f m" % [scene_id, static_position.distance_to(_geo_rig.global_position)])
	if absf(rad_to_deg(static_rotation.x - _geo_rig.rotation.x)) > POSE_EPSILON_DEG:
		_fail("static/normal %s pitch differs" % scene_id)
	if absf(rad_to_deg(_angle_delta(static_rotation.y, _geo_rig.rotation.y))) > POSE_EPSILON_DEG:
		_fail("static/normal %s yaw differs" % scene_id)
	if absf(_actual_lateral(_geo_route, _geo_rig) - _expected_lateral(scene_id)) > LATERAL_EPSILON_M:
		_fail("normal %s lateral is not the authored anchor value" % scene_id)

func _verify_geo_pose_values(scene_id: String, context: String) -> void:
	var expected := _expected_pose(scene_id)
	var expected_pitch := float(expected.get("pitch_deg", -8.0))
	var expected_yaw := float(expected.get("yaw_deg", 0.0))
	var expected_lateral := _expected_lateral(scene_id)
	var actual_pitch := rad_to_deg(_geo_rig.rotation.x)
	var actual_yaw := rad_to_deg(_relative_yaw(_geo_route, _geo_rig))
	if absf(actual_pitch - expected_pitch) > POSE_EPSILON_DEG:
		_fail("%s %s pitch %.3f != %.3f" % [context, scene_id, actual_pitch, expected_pitch])
	if absf(rad_to_deg(_angle_delta(deg_to_rad(actual_yaw), deg_to_rad(expected_yaw)))) > POSE_EPSILON_DEG:
		_fail("%s %s yaw %.3f != %.3f" % [context, scene_id, actual_yaw, expected_yaw])
	if absf(_actual_lateral(_geo_route, _geo_rig) - expected_lateral) > LATERAL_EPSILON_M:
		_fail("%s %s lateral %.3f != %.3f" % [context, scene_id, _actual_lateral(_geo_route, _geo_rig), expected_lateral])
	var distance := _geo_rig.distance_m
	var expected_ground_y := _geo_route.ground_y(distance, expected_lateral) + 0.02
	if absf(_geo_rig.global_position.y - expected_ground_y) > 0.03:
		_fail("%s %s ground %.3f != %.3f" % [context, scene_id, _geo_rig.global_position.y, expected_ground_y])
	if absf(expected_lateral) > _geo_route.road_width_at(distance) * 0.5 + 0.01:
		_fail("%s %s lateral left the route corridor" % [context, scene_id])

func _verify_geo_traversal() -> void:
	_geo_rig.auto_advance = false
	_geo_rig.apply_acceptance_pose("")
	for scene_id in SCENE_IDS:
		var distance := float(_geo_route.acceptance_distance(scene_id))
		_verify_anchor_continuity(scene_id, distance)
	var first_id := String(SCENE_IDS.front())
	var last_id := String(SCENE_IDS.back())
	_geo_rig.reset_to_distance(-100.0)
	_verify_geo_pose_values(first_id, "before-first-clamp")
	_geo_rig.reset_to_distance(_geo_route.length_m + 100.0)
	_verify_geo_pose_values(last_id, "after-last-clamp")
	_geo_rig.auto_advance = true
	_geo_rig.reset_to_distance(0.0)
	_geo_rig._process(3600.0)
	if absf(_geo_rig.distance_m - _geo_route.length_m) > 0.01:
		_fail("geo normal traversal did not reach endpoint: %.3f / %.3f" % [_geo_rig.distance_m, _geo_route.length_m])
	print("geo camera traversal: anchors=%d endpoint=%.3f m" % [SCENE_IDS.size(), _geo_rig.distance_m])

func _verify_anchor_continuity(scene_id: String, distance: float) -> void:
	var left_distance := maxf(0.0, distance - CONTINUITY_STEP_M)
	var right_distance := minf(_geo_route.length_m, distance + CONTINUITY_STEP_M)
	_geo_rig.reset_to_distance(left_distance)
	var left_position := _geo_rig.global_position
	var left_pitch := _geo_rig.rotation.x
	var left_yaw := _relative_yaw(_geo_route, _geo_rig)
	var left_lateral := _actual_lateral(_geo_route, _geo_rig)
	_geo_rig.reset_to_distance(right_distance)
	var right_position := _geo_rig.global_position
	var right_pitch := _geo_rig.rotation.x
	var right_yaw := _relative_yaw(_geo_route, _geo_rig)
	var right_lateral := _actual_lateral(_geo_route, _geo_rig)
	if absf(rad_to_deg(right_pitch - left_pitch)) > MAX_LOCAL_PITCH_STEP_DEG:
		_fail("pitch discontinuity around %s" % scene_id)
	if absf(rad_to_deg(_angle_delta(right_yaw, left_yaw))) > MAX_LOCAL_YAW_STEP_DEG:
		_fail("yaw discontinuity around %s" % scene_id)
	if absf(right_lateral - left_lateral) > MAX_LOCAL_LATERAL_STEP_M:
		_fail("lateral discontinuity around %s" % scene_id)
	if left_position.distance_to(right_position) > MAX_GLOBAL_STEP_M:
		_fail("global position discontinuity around %s: %.3f m" % [scene_id, left_position.distance_to(right_position)])

func _verify_fresh_static_process() -> void:
	var executable := OS.get_executable_path()
	var project_path := ProjectSettings.globalize_path("res://")
	var script_path := ProjectSettings.globalize_path("res://tools/verify_saisies_geo_camera.gd")
	var output: Array = []
	var child_log := "/tmp/saisies_geo_camera_luna_child_s13.log"
	var args := PackedStringArray([
		"--headless", "--path", project_path, "--log-file", child_log,
		"--script", script_path, "--", "--child-scene-id=S13", "--scene-id=S13"
	])
	var exit_code := OS.execute(executable, args, output, true)
	if exit_code != 0:
		_fail("fresh process static S13 failed (%d): %s" % [exit_code, str(output)])
	else:
		print("geo camera static pose: S13 fresh process")

func _run_child_static(scene_id: String) -> void:
	if not SCENE_IDS.has(scene_id):
		_fail("unknown child scene id: %s" % scene_id)
		return
	if not await _build_geo_probe(true):
		return
	_load_geo_pose_metadata()
	if _geo_rig.auto_advance:
		_fail("fresh process %s did not disable auto advance" % scene_id)
	var distance := float(_geo_route.acceptance_distance(scene_id))
	if absf(_geo_rig.distance_m - distance) > 0.01:
		_fail("fresh process %s distance %.3f != %.3f" % [scene_id, _geo_rig.distance_m, distance])
	_verify_geo_pose_values(scene_id, "fresh-process-static")
	var fixed_distance := _geo_rig.distance_m
	for _frame in range(2):
		await process_frame
	if absf(_geo_rig.distance_m - fixed_distance) > 0.01:
		_fail("fresh process %s advanced while fixed" % scene_id)

func _verify_v2_contract() -> void:
	if _v2_route == null or _v2_rig == null:
		_fail("v2 camera probe is unavailable")
		return
	if _v2_route.length_m < 14000.0 or _v2_route.length_m > 16000.0:
		_fail("unexpected v2 route length %.3f m" % _v2_route.length_m)
	var expected_pose := {
		"S01": {"pitch_deg": -16.0, "yaw_deg": 20.0},
		"S06": {"pitch_deg": -16.0, "yaw_deg": 0.0},
		"S13": {"pitch_deg": -20.0, "yaw_deg": 0.0},
		"S18": {"pitch_deg": -8.0, "yaw_deg": 65.0}
	}
	for scene_id in SCENE_IDS:
		var distance := float(_v2_route.acceptance_distance(scene_id))
		_v2_rig.auto_advance = false
		_v2_rig.reset_to_distance(distance)
		_v2_rig.apply_acceptance_pose(scene_id)
		var pose: Dictionary = expected_pose.get(scene_id, _v2_route.acceptance_pose(scene_id))
		var pitch := rad_to_deg(_v2_rig.rotation.x)
		var yaw := rad_to_deg(_relative_yaw(_v2_route, _v2_rig))
		if absf(pitch - float(pose.get("pitch_deg", -8.0))) > POSE_EPSILON_DEG or absf(rad_to_deg(_angle_delta(deg_to_rad(yaw), deg_to_rad(float(pose.get("yaw_deg", 0.0)))))) > POSE_EPSILON_DEG:
			_fail("v2 pose changed at %s: pitch %.3f yaw %.3f" % [scene_id, pitch, yaw])
	_verify_v2_scene_map_values()
	print("v2 camera contract: pose map and source references unchanged")

func _verify_v2_scene_map_values() -> void:
	if not FileAccess.file_exists(V2_SCENE_MAP_FILE):
		_fail("missing v2 scene map: %s" % V2_SCENE_MAP_FILE)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(V2_SCENE_MAP_FILE))
	if not (parsed is Dictionary):
		_fail("v2 scene map is not a JSON object")
		return
	var expected := {
		"S01": {"acceptance_pitch_deg": -16.0, "acceptance_yaw_deg": 20.0},
		"S06": {"acceptance_pitch_deg": -16.0, "acceptance_yaw_deg": 0.0},
		"S13": {"acceptance_pitch_deg": -20.0, "acceptance_yaw_deg": 0.0},
		"S18": {"acceptance_pitch_deg": -8.0, "acceptance_yaw_deg": 65.0}
	}
	var found := {}
	for item in parsed.get("scenes", []):
		if not (item is Dictionary):
			continue
		var scene_id := String(item.get("scene_id", ""))
		if expected.has(scene_id):
			found[scene_id] = true
			for key in expected[scene_id].keys():
				if absf(float(item.get(key, NAN)) - float(expected[scene_id][key])) > 0.001:
					_fail("v2 scene map %s changed %s" % [scene_id, key])
	for scene_id in expected.keys():
		if not found.has(scene_id):
			_fail("v2 scene map omits %s" % scene_id)

func _sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_buffer(file.get_length()))
	return context.finish().hex_encode()

func _expected_pose(scene_id: String) -> Dictionary:
	if _geo_pose_by_id.has(scene_id):
		var item: Dictionary = _geo_pose_by_id[scene_id]
		return {
			"pitch_deg": float(item.get("pitch_deg", -8.0)),
			"yaw_deg": float(item.get("yaw_deg", 0.0))
		}
	return _geo_route.acceptance_pose(scene_id)

func _expected_lateral(scene_id: String) -> float:
	if _geo_pose_by_id.has(scene_id):
		return float((_geo_pose_by_id[scene_id] as Dictionary).get("lateral_m", 0.0))
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(V2_SCENE_MAP_FILE))
	if parsed is Dictionary:
		for item in parsed.get("scenes", []):
			if item is Dictionary and String(item.get("scene_id", "")) == scene_id:
				return float(item.get("acceptance_lateral_m", 0.0))
	return 0.0

func _relative_yaw(route: SaisiesRoute, rig: SaisiesCamera) -> float:
	var heading := atan2(-route.tangent_at(rig.distance_m).x, -route.tangent_at(rig.distance_m).z)
	return _angle_delta(rig.rotation.y, heading)

func _actual_lateral(route: SaisiesRoute, rig: SaisiesCamera) -> float:
	return (rig.global_position - route.pos_at(rig.distance_m)).dot(route.left_at(rig.distance_m))

func _angle_delta(a: float, b: float) -> float:
	return wrapf(a - b + PI, 0.0, TAU) - PI

func _finite_vec3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES GEO CAMERA VERIFY: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES GEO CAMERA VERIFY PASS")
		quit(0)
	else:
		print("SAISIES GEO CAMERA VERIFY FAIL (%d errors)" % _errors.size())
		quit(1)
