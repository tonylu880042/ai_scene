extends SceneTree

## Round14 low-cost village alignment probe.
##
## The default mode only loads the geographic centerline and projects authored
## landmarks/OSM building centres into the estimated camera poses.  It does not
## instantiate the forest or mutate route/map/camera/village data.  Native mode
## is an optional handoff for root: it captures at most eight short sequence
## views from either the road-only scene or the geo scene with forest/detail
## modules pruned before they enter the tree.

const ROUTE_SCRIPT_PATH := "res://scripts/saisies_geo_route.gd"
const ROUTE_FILE := "res://data/saisies_geo_route.json"
const GEO_SCENE_MAP_FILE := "res://data/saisies_geo_scene_map.json"
const BASE_SCENE_MAP_FILE := "res://data/saisies_scene_map.json"
const GEO_CAMERA_POSE_FILE := "res://data/saisies_geo_camera_poses.json"
const BUILDINGS_FILE := "res://data/saisies_geo_buildings.json"
const GEO_SCENE_PATH := "res://scenes/MainScene_saisies_geo.tscn"
const SOURCE_VIDEO := "res://video/Descending Col des Saisies _ French Alps #3_1080p.mp4"
const SOURCE_FRAME_DIR := "video/saisies_analysis/acceptance"
const FROZEN_REVIEW_DIR := "export/saisies/review/round13_houses_refined"
const OVERLAP_LOG := "export/saisies/review/round13_houses_refined/verify_buildings.log"
const DEFAULT_OUTPUT_DIR := "res://export/saisies/review/round14_village_analysis"

const CAPTURE_SIZE := Vector2i(1920, 1080)
const CAMERA_HEIGHT_M := 1.65
const FOV_DEG := 78.0
const FRAME_RATE_NUM := 24000.0
const FRAME_RATE_DEN := 1001.0
const TIME_LIMIT_S := 920.067

## Keep this sequence small enough for one native handoff contact sheet.
const SNAPSHOT_TIMES_S := [0.0, 5.0, 20.0, 30.0, 40.0, 60.0, 75.0, 90.0]
const NAMED_BUILDING_IDS := [
	"way/187382065", # L'Olympe
	"way/187382002", # La Legette
	"way/187382115", # La Lazette
	"way/187382073", # round13 Restaurant_Ravoula overlap
	"way/187382099"  # round13 Restaurant_Ravoula/Rear_Hotel overlap
]

## These coordinates are source-code contracts, not GPS claims.  The S03
## records describe the mapped geo junction and retain the legacy v2 stations
## in notes so the -105m placement translation remains auditable.
const AUTHORED_LANDMARKS := [
	{
		"id": "Restaurant_Ravoula",
		"kind": "building",
		"station_m": 58.0,
		"lateral_m": 11.8,
		"width_m": 27.0,
		"depth_m": 8.8,
		"height_m": 6.8,
		"geo_scene_instantiated": true,
		"source": "scripts/saisies_geo_village.gd -> _build_restaurant_block",
		"scope": "S01/S02 geo village 0..560m"
	},
	{
		"id": "Rear_Hotel",
		"kind": "building",
		"station_m": 82.0,
		"lateral_m": 10.0,
		"width_m": 16.0,
		"depth_m": 9.6,
		"height_m": 11.2,
		"geo_scene_instantiated": true,
		"source": "scripts/saisies_geo_village.gd -> inherited _build_hotel_block",
		"scope": "S01/S02 geo village 0..560m"
	},
	{
		"id": "Right_Alpine_Lodge",
		"kind": "building",
		"station_m": 94.0,
		"lateral_m": -19.0,
		"width_m": 18.5,
		"depth_m": 8.0,
		"height_m": 6.8,
		"geo_scene_instantiated": true,
		"source": "scripts/saisies_geo_village.gd -> inherited _build_resort_block",
		"scope": "S01/S02 geo village 0..560m"
	},
	{
		"id": "Shop_Block",
		"kind": "building",
		"station_m": 237.0,
		"lateral_m": 11.4,
		"width_m": 16.0,
		"depth_m": 8.0,
		"height_m": 6.8,
		"geo_scene_instantiated": true,
		"source": "scripts/saisies_geo_village.gd -> inherited _build_resort_block",
		"scope": "S01/S02 geo village 0..560m",
		"note": "Generic authored shop block is upstream of S02; it is not evidence that the source central low shop is placed correctly."
	},
	{
		"id": "S02LowShop",
		"kind": "building",
		"station_m": 340.0,
		"lateral_m": -9.5,
		"width_m": 7.4,
		"depth_m": 4.4,
		"height_m": 4.5,
		"geo_scene_instantiated": true,
		"source": "scenes/props/SaisiesS02Shop.tscn -> scripts/saisies_s02_shop.gd",
		"scope": "S02 geo village 0..560m",
		"note": "Visible low-shop candidate moved to s340/u-9.5 after the native S02 occlusion probe; visual estimate from S02_f000719, not GPS. Previous s350/u-11.6 is retained as the retired candidate."
	},
	{
		"id": "S02StonePlantedIsland",
		"kind": "planted_island",
		"station_m": 308.0,
		"previous_station_m": 320.0,
		"station_basis": "visual_estimate_after_native_probe",
		"lateral_m": 8.0,
		"width_m": 6.4,
		"depth_m": 12.0,
		"height_m": 2.0,
		"geo_scene_instantiated": true,
		"source": "scripts/saisies_geo_village.gd -> inherited _build_s02_intersection",
		"scope": "S01/S02 geo village 0..560m",
		"planting_material": "dark_natural_green",
		"note": "Source S02's strongest visible island landmark; Geo visual candidate is s308/u+8. The inherited v2 s320/u+8 anchor is retained as previous metadata, not GPS."
	},
	{
		"id": "Intersection_Lodge",
		"kind": "building",
		"station_m": 320.0,
		"lateral_m": -14.0,
		"previous_station_m": 333.0,
		"previous_lateral_m": -11.2,
		"rejected_station_m": 333.0,
		"rejected_lateral_m": -20.0,
		"station_basis": "visual_estimate_after_native_probe",
		"width_m": 15.0,
		"depth_m": 8.5,
		"height_m": 10.5,
		"geo_scene_instantiated": true,
		"source": "scripts/saisies_geo_village.gd -> _build_geo_intersection_lodge",
		"scope": "S01/S02 geo village 0..560m",
		"note": "Current visual candidate is s320/u-14.0 after rejecting s333/u-20.0 on the lower DEM slope; inherited v2 s333/u-11.2 remains the original candidate. Layout estimates are not GPS."
	},
	{
		"id": "S03ChairliftCable",
		"kind": "chairlift_cable",
		"station_m": 955.0,
		"lateral_m": 0.0,
		"width_m": 62.0,
		"depth_m": 0.0,
		"height_m": 10.25,
		"geo_scene_instantiated": true,
		"source": "scripts/saisies_geo_village.gd -> _build_s03_chairlift/_add_sagging_cable",
		"scope": "mapped geo S03 junction 885..1005m",
		"note": "Geo anchor S03=930m plus the approximately 25m source approach. Legacy v2 cable station 1060m is retained as the pre-translation reference."
	},
	{
		"id": "S03BroadJunctionApron",
		"kind": "junction_apron",
		"station_m": 945.0,
		"lateral_m": 0.0,
		"width_m": 27.0,
		"depth_m": 120.0,
		"height_m": 0.1,
		"geo_scene_instantiated": true,
		"source": "scripts/saisies_geo_village.gd -> _build_s03_junction_apron",
		"scope": "mapped geo S03 junction 885..1005m",
		"note": "Legacy v2 apron interval 990..1110m is translated by -105m to the geo interval."
	},
	{
		"id": "S03LeftLiftLodge",
		"kind": "building",
		"station_m": 970.0,
		"previous_station_m": 943.0,
		"station_basis": "visual_estimate_after_native_probe",
		"lateral_m": 12.0,
		"width_m": 11.0,
		"depth_m": 6.0,
		"height_m": 4.5,
		"geo_scene_instantiated": true,
		"source": "scripts/saisies_geo_village.gd -> _build_s03_cafe",
		"scope": "mapped geo S03 junction 885..1005m",
		"note": "Source landmark is represented as a low one-storey dark-wood/grey-gable café. Native probe retires the prior 943m candidate in favor of visual estimate 970m; legacy v2 lodge station 1048m remains the pre-translation reference."
	}
]

const S02_STATION_CANDIDATES_M := [276.0, 296.251782202482, 308.0, 320.0]
const S03_STATION_CANDIDATES_M := [905.0, 930.0, 955.0, 970.0]

class RouteOnly extends SaisiesGeoRoute:
	func _ready() -> void:
		# This diagnostic uses the geographic centreline and no road/terrain mesh.
		pass

var _route: SaisiesGeoRoute
var _camera_contract: Node
var _output_dir := DEFAULT_OUTPUT_DIR
var _mode := "analysis"
var _capture_scope := "route"
var _errors: Array[String] = []
var _geo_scene_map: Dictionary = {}
var _base_scene_map: Dictionary = {}
var _geo_camera_pose: Dictionary = {}
var _buildings: Dictionary = {}

func _initialize() -> void:
	_parse_args()
	call_deferred("_run")

func _parse_args() -> void:
	for arg in _all_cmdline_args():
		var value := String(arg)
		if value.begins_with("--output-dir="):
			_output_dir = value.substr("--output-dir=".length())
		elif value.begins_with("--mode="):
			_mode = value.substr("--mode=".length()).to_lower()
		elif value.begins_with("--capture-scope="):
			_capture_scope = value.substr("--capture-scope=".length()).to_lower()

func _all_cmdline_args() -> PackedStringArray:
	var args := PackedStringArray()
	args.append_array(OS.get_cmdline_args())
	args.append_array(OS.get_cmdline_user_args())
	return args

func _run() -> void:
	if SNAPSHOT_TIMES_S.size() > 12:
		_fail("snapshot candidate count exceeds the <=12 handoff contract")
	if not _load_inputs() or not _load_route():
		_finish()
		return
	var report := _build_report()
	_write_json(_output_dir.path_join("round14_village_alignment.json"), report)
	_write_text(_output_dir.path_join("round14_village_alignment.md"), _markdown(report))
	if _mode == "capture":
		await _capture_native_sequence()
	_print_summary(report)
	_finish()

func _load_inputs() -> bool:
	_geo_scene_map = _load_json(GEO_SCENE_MAP_FILE)
	_base_scene_map = _load_json(BASE_SCENE_MAP_FILE)
	_geo_camera_pose = _load_json(GEO_CAMERA_POSE_FILE)
	_buildings = _load_json(BUILDINGS_FILE)
	return _errors.is_empty()

func _load_json(path: String) -> Dictionary:
	var global_path := _global_path(path)
	if not FileAccess.file_exists(global_path):
		_fail("input JSON is missing: %s" % path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(global_path))
	if not (parsed is Dictionary):
		_fail("input JSON is not an object: %s" % path)
		return {}
	return parsed.duplicate(true)

func _load_route() -> bool:
	if not FileAccess.file_exists(_global_path(ROUTE_FILE)):
		_fail("route file is missing: %s" % ROUTE_FILE)
		return false
	var route_script := load(ROUTE_SCRIPT_PATH)
	if route_script == null:
		_fail("route script could not load: %s" % ROUTE_SCRIPT_PATH)
		return false
	var route := RouteOnly.new()
	route.name = "SaisiesRound14VillageAlignmentRoute"
	route.route_file = ROUTE_FILE
	route.geo_route_file = ROUTE_FILE
	route._load_route_data()
	route._build_samples()
	route._build_curve()
	_route = route
	get_root().add_child(route)
	if not route.geography_ready or route._samples.size() < 2:
		_fail("geographic route samples did not become ready")
		return false
	var camera_script := load("res://scripts/saisies_geo_camera.gd")
	if camera_script == null:
		_fail("geo camera script could not load")
		return false
	_camera_contract = camera_script.new() as Node
	_camera_contract.set("route", route)
	_camera_contract.call("_cache_acceptance_poses")
	print("round14 route ready length=%.3f sample_spacing=%.6f" % [route.length_m, route.sample_spacing_m])
	return true

func _build_report() -> Dictionary:
	var snapshots: Array = []
	for time_value in SNAPSHOT_TIMES_S:
		snapshots.append(_snapshot_record(float(time_value)))
	var named_features := _named_osm_features()
	var source_frames := _source_frame_records()
	var route_map := _route_mapping_report(snapshots)
	var authored := _authored_landmark_report()
	var candidates := {
		"S02": _station_candidate_report(S02_STATION_CANDIDATES_M, "S02", "S02StonePlantedIsland", "Intersection_Lodge"),
		"S03": _station_candidate_report(S03_STATION_CANDIDATES_M, "S03", "S03ChairliftCable", "S03LeftLiftLodge")
	}
	var camera_sensitivity := _camera_sensitivity_report()
	var overlap := _overlap_evidence()
	var origin_time := _origin_time_diagnostic(named_features)
	var findings := _findings(named_features, snapshots, authored, overlap, camera_sensitivity)
	return {
		"schema_version": 1,
		"id": "saisies_round14_village_alignment",
		"status": "diagnostic_only_ready_hold" if _errors.is_empty() else "failed",
		"scope": "headless geographic route, authored landmark registry, OSM centre alignment, and camera projection; no production changes",
		"frozen_baseline": {
			"label": "round13_houses_refined",
			"path": "/tmp/saisies_round13_houses_refined",
			"route_file": ROUTE_FILE,
			"review_dir": FROZEN_REVIEW_DIR,
			"route_sha256": _sha256_file(ROUTE_FILE),
			"geo_scene_map_sha256": _sha256_file(GEO_SCENE_MAP_FILE),
			"camera_pose_sha256": _sha256_file(GEO_CAMERA_POSE_FILE),
			"buildings_sha256": _sha256_file(BUILDINGS_FILE),
			"production_data_changed": false
		},
		"source_video": {
			"path": SOURCE_VIDEO,
			"sha256": _sha256_file(SOURCE_VIDEO),
			"frame_rate": "24000/1001",
			"time_base": "1/24000",
			"duration_s": 920.002417,
			"frame_count": 22058
		},
		"route": _route_report(),
		"time_station_sequence": route_map,
		"snapshot_views": snapshots,
		"source_frames": source_frames,
		"authored_landmarks": authored,
		"named_osm_features": named_features,
		"origin_time_diagnostic": origin_time,
		"round13_overlap_evidence": overlap,
		"station_candidates": candidates,
		"camera_sensitivity": camera_sensitivity,
		"findings": findings,
		"probe_script_sha256": _sha256_file("res://tools/probe_saisies_village_alignment.gd"),
		"native_capture_handoff": {
			"available": true,
			"mode": "capture",
			"candidate_count": SNAPSHOT_TIMES_S.size(),
			"times_s": SNAPSHOT_TIMES_S,
			"default_scope": "route",
			"alternate_scope": "geo_landmarks",
			"geo_landmarks_prune": ["Forest", "Roadside", "NearfieldDetails"],
			"full_forest_loaded": false,
			"production_data_changed": false,
			"command_route": "godot --path /tmp/saisies_round13_houses_refined --script /Users/tunghunglu/projects/ai_scene/tools/probe_saisies_village_alignment.gd -- --mode=capture --capture-scope=route --output-dir=/Users/tunghunglu/projects/ai_scene/export/saisies/review/round14_village_analysis/native_route",
			"command_geo_landmarks": "godot --path /tmp/saisies_round13_houses_refined --script /Users/tunghunglu/projects/ai_scene/tools/probe_saisies_village_alignment.gd -- --mode=capture --capture-scope=geo_landmarks --output-dir=/Users/tunghunglu/projects/ai_scene/export/saisies/review/round14_village_analysis/native_geo_landmarks"
		},
		"generated_by": "tools/probe_saisies_village_alignment.gd"
	}

func _route_report() -> Dictionary:
	var frame := _route.frame()
	return {
		"length_m": _route.length_m,
		"sample_spacing_m": _route.sample_spacing_m,
		"road_width_m_at_s02": _route.road_width_at(_route.acceptance_distance("S02")),
		"road_width_m_at_s03": _route.road_width_at(_route.acceptance_distance("S03")),
		"geography_frame": frame,
		"world_convention": "local +X is ENU right/east, local -Z is ENU forward/north, positive signed lateral is route-left",
		"station_source": "estimated geographic centerline plus geo scene-map anchors; not GPS or telemetry",
		"scene_map_anchors": _geo_scene_map.get("time_anchors", []),
		"sections": _route_sections_near_village()
	}

func _route_sections_near_village() -> Array:
	var sections: Array = []
	for item in _route.geo_data.get("sections", []):
		if not (item is Dictionary):
			continue
		var section: Dictionary = item
		if float(section.get("to_m", 0.0)) < 0.0 or float(section.get("from_m", 0.0)) > 1300.0:
			continue
		sections.append({
			"id": String(section.get("id", "")),
			"from_m": section.get("from_m", null),
			"to_m": section.get("to_m", null),
			"video_from_s": section.get("video_from_s", null),
			"video_to_s": section.get("video_to_s", null),
			"road_width_m": section.get("road_width_m", null),
			"biome": section.get("biome", null)
		})
	return sections

func _route_mapping_report(snapshots: Array) -> Dictionary:
	var intervals: Array = []
	for index in range(1, snapshots.size()):
		var before: Dictionary = snapshots[index - 1]
		var after: Dictionary = snapshots[index]
		var dt := float(after["requested_time_s"]) - float(before["requested_time_s"])
		var ds := float(after["station_m"]) - float(before["station_m"])
		intervals.append({
			"from_time_s": before["requested_time_s"],
			"to_time_s": after["requested_time_s"],
			"from_station_m": before["station_m"],
			"to_station_m": after["station_m"],
			"distance_delta_m": ds,
			"time_delta_s": dt,
			"implied_speed_kmh": ds / maxf(dt, 0.001) * 3.6,
			"mapping_is_estimated": true
		})
	var monotonic := true
	for index in range(1, snapshots.size()):
		if float(snapshots[index]["station_m"]) <= float(snapshots[index - 1]["station_m"]):
			monotonic = false
	return {
		"mapping_type": "route.distance_for_video_seconds with geo scene-map replacement anchors",
		"monotonic": monotonic,
		"intervals": intervals,
		"note": "Speeds are plausibility diagnostics only; no time-to-station calibration is claimed."
	}

func _snapshot_record(time_s: float) -> Dictionary:
	var station := clampf(_route.distance_for_video_seconds(time_s), 0.0, _route.length_m)
	var camera := _camera_transform(station)
	var scene_id := _scene_id_for_time(time_s)
	var landmarks: Array = []
	for item_value in AUTHORED_LANDMARKS:
		var item: Dictionary = item_value
		if float(item.get("station_m", 0.0)) > 1300.0 and time_s < 110.0:
			continue
		if item.get("kind", "") == "chairlift_cable":
			landmarks.append(_project_cable(item, camera))
		else:
			landmarks.append(_project_landmark(item, camera))
	var point := _route.pos_at(station)
	var tangent := _route.tangent_at(station)
	var heading := _heading_deg(tangent)
	return {
		"id": "T%03d" % int(round(time_s)),
		"requested_time_s": time_s,
		"frame_index_zero_based": int(round(time_s * FRAME_RATE_NUM / FRAME_RATE_DEN)),
		"station_m": station,
		"station_source": "geo scene-map/interpolated checkpoint estimate",
		"scene_id_nearest": scene_id,
		"route_position_xyz": _vector_for(point),
		"route_tangent_xyz": _vector_for(tangent),
		"heading_deg": heading,
		"grade_pct": _route.grade_at(station),
		"section": _route.section_at(station),
		"camera": _camera_record(camera, station),
		"projected_authored_landmarks": landmarks
	}

func _scene_id_for_time(time_s: float) -> String:
	var best := ""
	var best_delta := INF
	for item in _geo_scene_map.get("scenes", []):
		if not (item is Dictionary) or not item.has("video_seconds"):
			continue
		var delta := absf(float(item["video_seconds"]) - time_s)
		if delta < best_delta:
			best_delta = delta
			best = String(item.get("scene_id", ""))
	return best if best_delta <= 0.001 else ""

func _camera_transform(station: float, pose_override: Dictionary = {}) -> Transform3D:
	var tangent := _route.tangent_at(station)
	var heading := _heading_deg(tangent)
	var next_station := _route.length_m if station >= _route.length_m else station + 12.0
	var next_heading := _heading_deg(_route.tangent_at(next_station))
	var turn := _angle_delta_deg(heading, next_heading)
	var pose: Vector2 = Vector2(_camera_contract.call("_pose_for_distance", station))
	var lateral: float = float(_camera_contract.call("_lateral_for_distance", station))
	if not pose_override.is_empty():
		pose = Vector2(deg_to_rad(float(pose_override.get("pitch_deg", -8.0))), deg_to_rad(float(pose_override.get("yaw_deg", 0.0))))
		lateral = float(pose_override.get("lateral_m", 0.0))
	var position: Vector3 = _route.pos_at(station) + _route.left_at(station) * lateral
	position.y = _route.ground_y(station, lateral) + 0.02 + CAMERA_HEIGHT_M
	var roll := clampf(-turn * 2.2, -5.0, 5.0)
	var basis := Basis.from_euler(Vector3(pose.x, deg_to_rad(heading) + pose.y, deg_to_rad(roll)))
	return Transform3D(basis, position)

func _camera_record(camera: Transform3D, station: float) -> Dictionary:
	var tangent := _route.tangent_at(station)
	var heading := _heading_deg(tangent)
	var pose: Vector2 = Vector2(_camera_contract.call("_pose_for_distance", station))
	var lateral: float = float(_camera_contract.call("_lateral_for_distance", station))
	var next_heading := _heading_deg(_route.tangent_at(minf(station + 12.0, _route.length_m)))
	var roll := clampf(-_angle_delta_deg(heading, next_heading) * 2.2, -5.0, 5.0)
	return {
		"position_xyz": _vector_for(camera.origin),
		"height_m": CAMERA_HEIGHT_M,
		"lateral_m": lateral,
		"pitch_deg": rad_to_deg(pose.x),
		"yaw_offset_deg": rad_to_deg(pose.y),
		"heading_deg": heading,
		"roll_deg": roll,
		"fov_deg": FOV_DEG,
		"projection_rule": "pinhole depth=-camera_local.z; 1920x1080; focal_y=(540)/tan(FOV/2)"
	}

func _project_landmark(item: Dictionary, camera: Transform3D, fov_deg := FOV_DEG) -> Dictionary:
	var station := float(item.get("station_m", 0.0))
	var lateral := float(item.get("lateral_m", 0.0))
	var height := float(item.get("height_m", 0.0))
	var centre := _route.world_at(station, lateral, height * 0.5)
	var base := _route.world_at(station, lateral, 0.0)
	var top := _route.world_at(station, lateral, height)
	return {
		"id": String(item.get("id", "")),
		"kind": String(item.get("kind", "")),
		"geo_scene_instantiated": bool(item.get("geo_scene_instantiated", false)),
		"authored_station_m": station,
		"authored_lateral_m": lateral,
		"base_projection": _project_world(base, camera, fov_deg),
		"centre_projection": _project_world(centre, camera, fov_deg),
		"top_projection": _project_world(top, camera, fov_deg),
		"source": String(item.get("source", ""))
	}

func _project_cable(item: Dictionary, camera: Transform3D, fov_deg := FOV_DEG) -> Dictionary:
	var station := float(item.get("station_m", 0.0))
	var tower_height := float(item.get("height_m", 10.25))
	var left_tower := _route.world_at(station, -31.0, tower_height)
	var right_tower := _route.world_at(station, 31.0, tower_height)
	var midpoint := left_tower.lerp(right_tower, 0.5)
	midpoint.y -= 1.6
	return {
		"id": String(item.get("id", "")),
		"kind": String(item.get("kind", "")),
		"geo_scene_instantiated": bool(item.get("geo_scene_instantiated", false)),
		"authored_station_m": station,
		"tower_lateral_m": [-31.0, 31.0],
		"left_tower_projection": _project_world(left_tower, camera, fov_deg),
		"right_tower_projection": _project_world(right_tower, camera, fov_deg),
		"midspan_projection": _project_world(midpoint, camera, fov_deg),
		"source": String(item.get("source", ""))
	}

func _project_world(world: Vector3, camera: Transform3D, fov_deg := FOV_DEG) -> Dictionary:
	var local := camera.affine_inverse() * world
	var depth := -local.z
	if depth <= 0.0001 or not is_finite(depth):
		return {"visible_depth": false, "depth_m": depth, "x_px": null, "y_px": null}
	var focal := float(CAPTURE_SIZE.y) * 0.5 / tan(deg_to_rad(fov_deg) * 0.5)
	return {
		"visible_depth": true,
		"depth_m": depth,
		"x_px": CAPTURE_SIZE.x * 0.5 + focal * local.x / depth,
		"y_px": CAPTURE_SIZE.y * 0.5 - focal * local.y / depth,
		"in_frame": (CAPTURE_SIZE.x * -0.25 <= CAPTURE_SIZE.x * 0.5 + focal * local.x / depth and CAPTURE_SIZE.x * 1.25 >= CAPTURE_SIZE.x * 0.5 + focal * local.x / depth and CAPTURE_SIZE.y * -0.25 <= CAPTURE_SIZE.y * 0.5 - focal * local.y / depth and CAPTURE_SIZE.y * 1.25 >= CAPTURE_SIZE.y * 0.5 - focal * local.y / depth)
	}

func _station_candidate_report(stations: Array, scene_id: String, primary_id: String, secondary_id: String) -> Array:
	var result: Array = []
	var pose_override := _pose_override_for_scene(scene_id)
	for station_value in stations:
		var station := clampf(float(station_value), 0.0, _route.length_m)
		var camera := _camera_transform(station, pose_override)
		var primary := _landmark_by_id(primary_id)
		var secondary := _landmark_by_id(secondary_id)
		var record := {
			"scene_id": scene_id,
			"candidate_station_m": station,
			"station_delta_from_geo_scene_map_m": station - _route.acceptance_distance(scene_id),
			"equivalent_estimated_video_s": _route._video_seconds_at_distance(station),
			"camera_hold": pose_override,
			"route": {
				"heading_deg": _heading_deg(_route.tangent_at(station)),
				"grade_pct": _route.grade_at(station),
				"section": _route.section_at(station)
			},
			"primary_projection": _project_landmark(primary, camera) if primary_id != "S03ChairliftCable" else _project_cable(primary, camera),
			"secondary_projection": _project_landmark(secondary, camera),
			"interpretation": "station-only candidate; hold yaw/lateral/FOV fixed while root compares road exit and landmark scale"
		}
		result.append(record)
	return result

func _camera_sensitivity_report() -> Dictionary:
	var result: Dictionary = {}
	var scene_specs := [
		{"scene_id": "S02", "station_m": _route.acceptance_distance("S02"), "landmark_id": "S02StonePlantedIsland", "kind": "landmark"},
		{"scene_id": "S03", "station_m": _route.acceptance_distance("S03"), "landmark_id": "S03ChairliftCable", "kind": "cable"}
	]
	var variants := [
		{"id": "base", "yaw_delta_deg": 0.0, "lateral_delta_m": 0.0, "fov_deg": FOV_DEG},
		{"id": "yaw_minus_6", "yaw_delta_deg": -6.0, "lateral_delta_m": 0.0, "fov_deg": FOV_DEG},
		{"id": "yaw_plus_6", "yaw_delta_deg": 6.0, "lateral_delta_m": 0.0, "fov_deg": FOV_DEG},
		{"id": "lateral_minus_2", "yaw_delta_deg": 0.0, "lateral_delta_m": -2.0, "fov_deg": FOV_DEG},
		{"id": "lateral_plus_2", "yaw_delta_deg": 0.0, "lateral_delta_m": 2.0, "fov_deg": FOV_DEG},
		{"id": "fov_70", "yaw_delta_deg": 0.0, "lateral_delta_m": 0.0, "fov_deg": 70.0},
		{"id": "fov_86", "yaw_delta_deg": 0.0, "lateral_delta_m": 0.0, "fov_deg": 86.0}
	]
	for scene_spec_value in scene_specs:
		var scene_spec: Dictionary = scene_spec_value
		var scene_id := String(scene_spec.get("scene_id", ""))
		var station := float(scene_spec.get("station_m", 0.0))
		var item := _landmark_by_id(String(scene_spec.get("landmark_id", "")))
		var base_pose := _pose_override_for_scene(scene_id)
		var rows: Array = []
		for variant_value in variants:
			var variant: Dictionary = variant_value
			var pose_override: Dictionary = base_pose.duplicate(true)
			pose_override["yaw_deg"] = float(base_pose.get("yaw_deg", 0.0)) + float(variant.get("yaw_delta_deg", 0.0))
			pose_override["lateral_m"] = float(base_pose.get("lateral_m", 0.0)) + float(variant.get("lateral_delta_m", 0.0))
			var camera := _camera_transform(station, pose_override)
			var fov := float(variant.get("fov_deg", FOV_DEG))
			var projection: Dictionary
			if String(scene_spec.get("kind", "")) == "cable":
				projection = _project_cable(item, camera, fov)
			else:
				projection = _project_landmark(item, camera, fov)
			var focus: Dictionary = projection.get("midspan_projection", projection.get("centre_projection", {}))
			rows.append({
				"id": String(variant.get("id", "")),
				"yaw_deg": pose_override.get("yaw_deg", 0.0),
				"lateral_m": pose_override.get("lateral_m", 0.0),
				"fov_deg": fov,
				"focus_projection": focus,
				"landmark_geo_scene_instantiated": bool(item.get("geo_scene_instantiated", false))
			})
		result[scene_id] = {
			"station_m": station,
			"landmark_id": String(scene_spec.get("landmark_id", "")),
			"rows": rows,
			"interpretation": "Yaw/lateral/FOV moves the projection of an existing authored point; it does not change route station or instantiate a missing landmark."
		}
	return result

func _pose_override_for_scene(scene_id: String) -> Dictionary:
	for item in _base_scene_map.get("scenes", []):
		if item is Dictionary and String(item.get("scene_id", "")) == scene_id:
			return {
				"pitch_deg": float(item.get("acceptance_pitch_deg", -8.0)),
				"yaw_deg": float(item.get("acceptance_yaw_deg", 0.0)),
				"lateral_m": float(item.get("acceptance_lateral_m", 0.0))
			}
	return {"pitch_deg": -8.0, "yaw_deg": 0.0, "lateral_m": 0.0}

func _landmark_by_id(landmark_id: String) -> Dictionary:
	for item_value in AUTHORED_LANDMARKS:
		var item: Dictionary = item_value
		if String(item.get("id", "")) == landmark_id:
			return item.duplicate(true)
	return {"id": landmark_id, "station_m": 0.0, "lateral_m": 0.0, "height_m": 0.0}

func _authored_landmark_report() -> Array:
	var result: Array = []
	for item_value in AUTHORED_LANDMARKS:
		var item: Dictionary = item_value.duplicate(true)
		var station := float(item.get("station_m", 0.0))
		item["route_heading_deg"] = _heading_deg(_route.tangent_at(station))
		item["route_grade_pct"] = _route.grade_at(station)
		item["estimated_video_s_from_existing_mapping"] = _route._video_seconds_at_distance(station)
		item["position_xyz"] = _vector_for(_route.world_at(station, float(item.get("lateral_m", 0.0)), 0.0))
		result.append(item)
	return result

func _named_osm_features() -> Array:
	var result: Array = []
	for feature_value in _buildings.get("buildings", []):
		if not (feature_value is Dictionary):
			continue
		var feature: Dictionary = feature_value
		var feature_id := String(feature.get("id", ""))
		if not NAMED_BUILDING_IDS.has(feature_id):
			continue
		var centre := _route.world_from_latlon(float(feature.get("centre_lat", NAN)), float(feature.get("centre_lon", NAN)))
		var nearest := _nearest_route_position(Vector2(centre.x, centre.z))
		var tags: Dictionary = feature.get("tags", {})
		var lateral := float(nearest["lateral_m"])
		result.append({
			"id": feature_id,
			"name": String(tags.get("name", tags.get("addr:housename", ""))),
			"building_tag": String(tags.get("building", "")),
			"centre_lat": feature.get("centre_lat", null),
			"centre_lon": feature.get("centre_lon", null),
			"local_centre_m": feature.get("local_centre_m", {}),
			"area_m2": feature.get("area_m2", null),
			"height_m": feature.get("height_m", null),
			"nearest_route_station_m": nearest["station_m"],
			"signed_lateral_m": lateral,
			"road_side": "left" if lateral >= 0.0 else "right",
			"horizontal_clearance_m": nearest["horizontal_distance_m"],
			"estimated_video_s_from_mapping": _route._video_seconds_at_distance(float(nearest["station_m"])),
			"nearest_route_point_xyz": nearest["route_point_xyz"],
			"station_source": "OSM feature centre nearest horizontal route sample; centre is diagnostic, not footprint registration"
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("nearest_route_station_m", 0.0)) < float(b.get("nearest_route_station_m", 0.0)))
	return result

func _origin_time_diagnostic(named_features: Array) -> Dictionary:
	var by_id: Dictionary = {}
	for item_value in named_features:
		var item: Dictionary = item_value
		by_id[String(item.get("id", ""))] = item
	var compact_sequence: Array = []
	for feature_id in ["way/187382073", "way/187382099", "way/187382065", "way/187382115", "way/187382002"]:
		var feature: Dictionary = by_id.get(feature_id, {})
		if feature.is_empty():
			continue
		compact_sequence.append({
			"id": feature_id,
			"name": feature.get("name", ""),
			"station_m": feature.get("nearest_route_station_m", null),
			"estimated_video_s": feature.get("estimated_video_s_from_mapping", null),
			"signed_lateral_m": feature.get("signed_lateral_m", null),
			"road_side": feature.get("road_side", ""),
			"horizontal_clearance_m": feature.get("horizontal_clearance_m", null)
		})
	var s01 := _route.acceptance_distance("S01")
	var s02 := _route.acceptance_distance("S02")
	var s03 := _route.acceptance_distance("S03")
	return {
		"conclusion": "The named-feature sequence gives no evidence for a hundreds-of-metres upstream geo-origin shift. The route stays near the round13 overlap pair at 37/78m and the close right-side La Legette centre at 820m; L'Olympe and La Lazette are far lateral side features, so they are not road-front anchors.",
		"s01": {
			"geo_scene_map_station_m": s01,
			"authored_restaurant_station_m": 58.0,
			"delta_authored_minus_geo_m": 58.0 - s01,
			"source_marker": "T0/T5 restaurant frontage"
		},
		"s02": {
			"geo_scene_map_station_m": s02,
			"authored_island_station_m": 308.0,
			"previous_authored_island_station_m": 320.0,
			"authored_island_station_basis": "visual_estimate_after_native_probe",
			"delta_authored_minus_geo_m": 308.0 - s02,
			"source_marker": "T30 planted island / central low shop"
		},
		"s03": {
			"geo_scene_map_station_m": s03,
			"source_map_cable_estimate_station_m": s03 + 25.0,
			"geo_authored_cable_station_m": 955.0,
			"geo_authored_minus_source_map_m": 955.0 - (s03 + 25.0),
			"legacy_v2_authored_cable_station_m": 1060.0,
			"legacy_v2_minus_source_map_m": 1060.0 - (s03 + 25.0),
			"geo_authored_cafe_station_m": 970.0,
			"previous_geo_authored_cafe_station_m": 943.0,
			"geo_authored_cafe_station_basis": "visual_estimate_after_native_probe",
			"legacy_v2_authored_lodge_station_m": 1048.0,
			"geo_village_s03_scope": "885..1005m",
			"source_marker": "T75 broad junction and cable"
		},
		"named_feature_order": compact_sequence,
			"interpretation": "Treat station/time mismatch at S02 as a station-versus-authored-island candidate. The geo S03 cable remains at 955m while the café is a separate 970m visual candidate; the legacy v2 1060m value is a documented pre-translation placement, not evidence for moving the geo origin. Hold camera FOV/yaw/lateral while root checks the native road exit and landmark scale."
	}

func _nearest_route_position(world_xz: Vector2) -> Dictionary:
	var step := maxf(_route.sample_spacing_m, 2.0)
	var best_station := 0.0
	var best_distance := INF
	var sample_count := int(ceil(_route.length_m / step))
	for index in range(sample_count + 1):
		var station := minf(float(index) * step, _route.length_m)
		var point := _route.pos_at(station)
		var distance := Vector2(point.x, point.z).distance_to(world_xz)
		if distance < best_distance:
			best_distance = distance
			best_station = station
	var refine_step := step / 20.0
	for index in range(-20, 21):
		var station := clampf(best_station + float(index) * refine_step, 0.0, _route.length_m)
		var point := _route.pos_at(station)
		var distance := Vector2(point.x, point.z).distance_to(world_xz)
		if distance < best_distance:
			best_distance = distance
			best_station = station
	var route_point := _route.pos_at(best_station)
	var delta := world_xz - Vector2(route_point.x, route_point.z)
	var left := _route.left_at(best_station)
	return {
		"station_m": best_station,
		"horizontal_distance_m": best_distance,
		"lateral_m": delta.dot(Vector2(left.x, left.z)),
		"route_point_xyz": _vector_for(route_point)
	}

func _overlap_evidence() -> Dictionary:
	var path := _global_path(OVERLAP_LOG)
	var text := ""
	if FileAccess.file_exists(path):
		text = FileAccess.get_file_as_string(path)
	var known_ids := ["way/187382067", "way/187382073", "way/187382099"]
	var found: Array = []
	for id in known_ids:
		if text.contains(id):
			found.append(id)
	return {
		"path": OVERLAP_LOG,
		"sha256": _sha256_file(OVERLAP_LOG),
		"exists": not text.is_empty(),
		"reported_suppression_ids": found,
		"named_l_olympe_way_187382065_reported": text.contains("way/187382065"),
		"interpretation": "round13 verifier log reports positive intersections for 187382067, 187382073, 187382099; L'Olympe 187382065 is absent, so its lack of suppression is evidence about overlap bookkeeping only, not a proof of route alignment."
	}

func _findings(named_features: Array, snapshots: Array, authored: Array, overlap: Dictionary, camera_sensitivity: Dictionary) -> Array:
	var findings: Array = []
	var scene_s02 := _route.acceptance_distance("S02")
	var scene_s03 := _route.acceptance_distance("S03")
	var cable := _landmark_by_id("S03ChairliftCable")
	var cable_station := float(cable.get("station_m", 0.0))
	findings.append({
		"id": "s02_station_vs_authored_island",
		"classification": "time_station_or_authored_placement",
		"evidence": {
			"geo_scene_map_s02_station_m": scene_s02,
			"authored_island_station_m": 308.0,
			"previous_authored_island_station_m": 320.0,
			"authored_island_station_basis": "visual_estimate_after_native_probe",
			"delta_m": 308.0 - scene_s02,
			"authored_intersection_lodge_station_m": 320.0,
			"authored_intersection_lodge_lateral_m": -14.0,
			"previous_intersection_lodge_station_m": 333.0,
			"previous_intersection_lodge_lateral_m": -11.2,
			"rejected_intersection_lodge_station_m": 333.0,
			"rejected_intersection_lodge_lateral_m": -20.0,
			"authored_low_shop_station_m": 340.0,
			"authored_low_shop_lateral_m": -9.5,
			"previous_low_shop_station_m": 350.0,
			"previous_low_shop_lateral_m": -11.6,
			"island_planting_material": "dark_natural_green",
			"s02_source_reference": "video/saisies_analysis/acceptance/S02_f000719.png"
		},
		"decision": "Hold camera yaw/lateral/FOV fixed at S02 station 296.252m. Keep the Geo island at s308/u+8 and low shop at s340/u-9.5; use the lodge s320/u-14.0 candidate after rejecting s333/u-20.0 on the lower DEM slope. The inherited v2 s333/u-11.2 placement remains documented. These are visual layout candidates, not GPS corrections."
	})
	findings.append({
		"id": "s03_chairlift_geo_placement",
		"classification": "landmark_authored_placement",
		"evidence": {
			"geo_scene_map_s03_station_m": scene_s03,
			"source_map_note": "Legette chairlift approach, approximately 25m before the cable landmark",
			"implied_source_cable_station_m": scene_s03 + 25.0,
			"geo_authored_cable_station_m": cable_station,
			"geo_to_source_candidate_delta_m": cable_station - (scene_s03 + 25.0),
			"legacy_v2_authored_cable_station_m": 1060.0,
			"legacy_v2_to_source_candidate_delta_m": 1060.0 - (scene_s03 + 25.0),
			"geo_authored_cafe_station_m": 970.0,
			"previous_geo_authored_cafe_station_m": 943.0,
			"geo_authored_cafe_station_basis": "visual_estimate_after_native_probe",
			"geo_village_s03_scope": "885..1005m",
			"geo_scene_village_script": "scripts/saisies_geo_village.gd",
			"source_reference": "video/saisies_analysis/acceptance/S03_f001798.png"
		},
		"decision": "GeoVillage keeps the two sampled towers and cable at 955m, while the low one-storey dark-wood/grey-roof café moves from the retired 943m candidate to the 970m visual candidate. Keep camera yaw/lateral/FOV fixed for root's native comparison; these station/layout estimates are not GPS and do not justify restoring the legacy 1060m placement."
	})
	findings.append({
		"id": "named_osm_sequence",
		"classification": "geo_origin_and_time_mapping",
		"evidence": named_features,
		"decision": "Use named feature nearest stations and side signs as a route-order diagnostic. They are OSM centres with estimated geometry and cannot be promoted to GPS anchors."
	})
	findings.append({
		"id": "camera_parameter_separation",
		"classification": "camera_yaw_lateral_fov_vs_station",
		"evidence": {
			"camera_contract": {
				"fov_deg": FOV_DEG,
				"height_m": CAMERA_HEIGHT_M,
				"pose_source": GEO_CAMERA_POSE_FILE,
				"pose_scope": "S09/S13 overrides only; S01/S02/S03 inherit scene_map estimates"
			},
			"snapshot_count": snapshots.size(),
			"numeric_sensitivity": camera_sensitivity,
			"candidate_rule": "Station candidates hold pose; camera sensitivity remains a separate numeric diagnostic in the report."
		},
		"decision": "Do not move buildings to compensate for a view that has not passed the road-exit/station probe."
	})
	findings.append({
		"id": "overlap_bookkeeping",
		"classification": "landmark_authored_placement",
		"evidence": overlap,
		"decision": "The round13 suppression log does not list L'Olympe way/187382065; this does not by itself justify relocating the geo origin, but it prevents claiming that authored Restaurant_Ravoula overlaps the named L'Olympe footprint."
	})
	return findings

func _source_frame_records() -> Array:
	var result: Array = []
	for time_value in SNAPSHOT_TIMES_S:
		var time_s := float(time_value)
		var frame_index := int(round(time_s * FRAME_RATE_NUM / FRAME_RATE_DEN))
		var pts := int(round(float(frame_index) * FRAME_RATE_DEN))
		var output_path := _output_dir.path_join("source_frames/T%03d_f%06d.png" % [int(round(time_s)), frame_index])
		var canonical := _canonical_source_for_time(time_s)
		result.append({
			"requested_seconds": time_s,
			"frame_index_zero_based": frame_index,
			"pts": pts,
			"time_base": "1/24000",
			"pts_seconds": float(pts) / FRAME_RATE_NUM,
			"output_path": output_path,
			"exists": FileAccess.file_exists(_global_path(output_path)),
			"sha256": _sha256_file(output_path),
			"canonical_reference": canonical,
			"canonical_sha256": _sha256_file(canonical) if not canonical.is_empty() else "",
			"hash_equal_to_canonical": not canonical.is_empty() and _sha256_file(output_path) == _sha256_file(canonical),
			"extraction_command": "ffmpeg -i '%s' -vf 'select=eq(n\\,%d),showinfo' -frames:v 1 -vsync 0 '%s'" % [SOURCE_VIDEO, frame_index, output_path]
		})
	return result

func _canonical_source_for_time(time_s: float) -> String:
	var frame_index := int(round(time_s * FRAME_RATE_NUM / FRAME_RATE_DEN))
	var candidate := ""
	if frame_index == 120:
		candidate = "res://video/saisies_analysis/acceptance/S01_f000120.png"
	elif frame_index == 719:
		candidate = "res://video/saisies_analysis/acceptance/S02_f000719.png"
	elif frame_index == 1798:
		candidate = "res://video/saisies_analysis/acceptance/S03_f001798.png"
	elif frame_index == 0:
		candidate = "res://export/saisies/review/round13_houses_integrated/source_T0_f000000.png"
	if candidate.is_empty():
		return ""
	return candidate if FileAccess.file_exists(_global_path(candidate)) else ""

func _capture_native_sequence() -> void:
	var packed := load(GEO_SCENE_PATH) as PackedScene
	if packed == null:
		_fail("geo scene could not load for native capture: %s" % GEO_SCENE_PATH)
		return
	var scene := packed.instantiate()
	var keep := ["Route", "CameraRig", "WorldEnvironment", "Sun"]
	if _capture_scope == "geo_landmarks":
		keep = ["Route", "Landscape", "VillageS01S02", "VillagePropsS01", "Roadbed", "Buildings", "CameraRig", "WorldEnvironment", "Sun"]
	_prune_top_level(scene, keep)
	get_root().add_child(scene)
	var root_window := get_root() as Window
	if root_window:
		root_window.size = CAPTURE_SIZE
		root_window.content_scale_size = CAPTURE_SIZE
	await process_frame
	await process_frame
	var route := scene.get_node_or_null("Route") as SaisiesGeoRoute
	var rig := scene.get_node_or_null("CameraRig") as Node3D
	var camera := rig.get_node_or_null("Camera3D") as Camera3D if rig != null else null
	if route == null or rig == null or camera == null:
		_fail("native capture scene is missing Route/CameraRig/Camera3D")
		return
	rig.set("auto_advance", false)
	var records: Array = []
	var capture_dir := _output_dir.path_join("native")
	DirAccess.make_dir_recursive_absolute(_global_path(capture_dir))
	for time_value in SNAPSHOT_TIMES_S:
		var time_s := float(time_value)
		var station := clampf(route.distance_for_video_seconds(time_s), 0.0, route.length_m)
		var transform := _camera_transform_for_route(route, station)
		rig.global_transform = Transform3D(Basis.IDENTITY, transform.origin - Vector3(0.0, CAMERA_HEIGHT_M, 0.0))
		rig.rotation = transform.basis.get_euler()
		camera.position = Vector3(0.0, CAMERA_HEIGHT_M, 0.0)
		camera.fov = FOV_DEG
		camera.current = true
		for _settle in range(6):
			await process_frame
		RenderingServer.force_draw()
		var frame_index := int(round(time_s * FRAME_RATE_NUM / FRAME_RATE_DEN))
		var output := capture_dir.path_join("T%03d_f%06d.png" % [int(round(time_s)), frame_index])
		var saved := _save_viewport(output)
		records.append({
			"id": "T%03d" % int(round(time_s)),
			"requested_time_s": time_s,
			"frame_index_zero_based": frame_index,
			"station_m": station,
			"output": output,
			"saved": saved,
			"renderer": RenderingServer.get_current_rendering_driver_name()
		})
	_write_json(_output_dir.path_join("native_capture_manifest.json"), {
		"schema_version": 1,
		"id": "saisies_round14_village_alignment_native_capture",
		"status": "captured" if _errors.is_empty() else "failed",
		"scope": "route-only" if _capture_scope != "geo_landmarks" else "geo scene with Forest/Roadside/NearfieldDetails pruned",
		"capture_scope": _capture_scope,
		"full_forest_loaded": false,
		"production_data_changed": false,
		"resolution_px": [CAPTURE_SIZE.x, CAPTURE_SIZE.y],
		"records": records,
		"generated_by": "tools/probe_saisies_village_alignment.gd"
	})

func _camera_transform_for_route(route: SaisiesGeoRoute, station: float) -> Transform3D:
	var tangent := route.tangent_at(station)
	var heading := _heading_deg(tangent)
	var next_heading := _heading_deg(route.tangent_at(minf(station + 12.0, route.length_m)))
	var roll := clampf(-_angle_delta_deg(heading, next_heading) * 2.2, -5.0, 5.0)
	var pose: Vector2 = Vector2(_camera_contract.call("_pose_for_distance", station))
	var lateral: float = float(_camera_contract.call("_lateral_for_distance", station))
	var rig_origin: Vector3 = route.pos_at(station) + route.left_at(station) * lateral
	var camera_origin: Vector3 = rig_origin
	camera_origin.y = route.ground_y(station, lateral) + 0.02 + CAMERA_HEIGHT_M
	return Transform3D(Basis.from_euler(Vector3(pose.x, deg_to_rad(heading) + pose.y, deg_to_rad(roll))), camera_origin)

func _prune_top_level(scene: Node, keep: Array) -> void:
	for child in scene.get_children():
		if keep.has(String(child.name)):
			continue
		scene.remove_child(child)
		child.free()

func _save_viewport(output: String) -> bool:
	var viewport := get_root() as Viewport
	if viewport == null or viewport.get_texture() == null:
		_fail("native capture viewport is unavailable")
		return false
	var image := viewport.get_texture().get_image()
	if image == null or image.get_width() != CAPTURE_SIZE.x or image.get_height() != CAPTURE_SIZE.y:
		_fail("native capture image has wrong size for %s" % output)
		return false
	var global_output := _global_path(output)
	var error := image.save_png(global_output)
	if error != OK:
		_fail("native capture image save failed (%s): %s" % [error, global_output])
		return false
	return true

func _heading_deg(tangent: Vector3) -> float:
	return rad_to_deg(atan2(-tangent.x, -tangent.z))

func _angle_delta_deg(a: float, b: float) -> float:
	return rad_to_deg(wrapf(deg_to_rad(b - a) + PI, 0.0, TAU) - PI)

func _vector_for(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}

func _sha256_file(path: String) -> String:
	var global_path := _global_path(path)
	var file := FileAccess.open(global_path, FileAccess.READ)
	if file == null:
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_buffer(file.get_length()))
	return context.finish().hex_encode()

func _global_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path if path.is_absolute_path() else ProjectSettings.globalize_path(path)

func _write_json(path: String, value: Variant) -> void:
	var global_path := _global_path(path)
	DirAccess.make_dir_recursive_absolute(global_path.get_base_dir())
	var file := FileAccess.open(global_path, FileAccess.WRITE)
	if file == null:
		_fail("could not write JSON: %s" % path)
		return
	file.store_string(JSON.stringify(value, "\t"))
	file.close()

func _write_text(path: String, value: String) -> void:
	var global_path := _global_path(path)
	DirAccess.make_dir_recursive_absolute(global_path.get_base_dir())
	var file := FileAccess.open(global_path, FileAccess.WRITE)
	if file == null:
		_fail("could not write text: %s" % path)
		return
	file.store_string(value)
	file.close()

func _markdown(report: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("# Saisies round14 village alignment probe")
	lines.append("")
	lines.append("Status: `%s`. Scope: headless geographic route and landmark projection only; production route/map/camera/village data unchanged." % String(report.get("status", "")))
	lines.append("")
	lines.append("Frozen baseline: `/tmp/saisies_round13_houses_refined` (`round13_houses_refined`). Source frame rate is 24000/1001 with 1/24000 time base. Distances and OSM nearest stations remain estimated diagnostics, not GPS.")
	lines.append("")
	lines.append("## Findings")
	lines.append("")
	for finding_value in report.get("findings", []):
		var finding: Dictionary = finding_value
		lines.append("- **%s** (%s): %s" % [String(finding.get("id", "")), String(finding.get("classification", "")), String(finding.get("decision", ""))])
	lines.append("")
	lines.append("## Named OSM feature nearest stations")
	lines.append("")
	lines.append("| ID | Name | nearest station m | mapped video s | signed lateral m | side | horizontal clearance m | height m |")
	lines.append("|---|---|---:|---:|---:|---|---:|---:|")
	for feature_value in report.get("named_osm_features", []):
		var feature: Dictionary = feature_value
		lines.append("| `%s` | %s | %.3f | %.3f | %.3f | %s | %.3f | %s |" % [String(feature.get("id", "")), String(feature.get("name", "")), float(feature.get("nearest_route_station_m", 0.0)), float(feature.get("estimated_video_s_from_mapping", 0.0)), float(feature.get("signed_lateral_m", 0.0)), String(feature.get("road_side", "")), float(feature.get("horizontal_clearance_m", 0.0)), str(feature.get("height_m", ""))])
	lines.append("")
	lines.append("The named OSM centres are used to inspect route order and side only. They are not promoted to a camera calibration or GPS anchor.")
	lines.append("")
	var origin_time: Dictionary = report.get("origin_time_diagnostic", {})
	lines.append("## Origin and time diagnostic")
	lines.append("")
	lines.append(String(origin_time.get("conclusion", "")))
	lines.append("")
	lines.append(String(origin_time.get("interpretation", "")))
	lines.append("")
	lines.append("## Existing authored landmark contracts")
	lines.append("")
	lines.append("| Landmark | authored station m | lateral m | geo scene instantiated | estimated video s | source |")
	lines.append("|---|---:|---:|---|---:|---|")
	for item_value in report.get("authored_landmarks", []):
		var item: Dictionary = item_value
		lines.append("| `%s` | %.3f | %.3f | %s | %.3f | `%s` |" % [String(item.get("id", "")), float(item.get("station_m", 0.0)), float(item.get("lateral_m", 0.0)), str(item.get("geo_scene_instantiated", false)), float(item.get("estimated_video_s_from_existing_mapping", 0.0)), String(item.get("source", ""))])
	lines.append("")
	lines.append("S03's mapped geo village now instantiates the cable/towers at 955m, sampled junction apron, and a low one-storey dark-wood/grey-roof café at the 970m visual candidate. The prior café candidate 943m is retired; legacy v2 cable/lodge stations (1060m/1048m) remain documented as pre-translation references. Camera yaw, lateral offset, or FOV must stay separate from this authored placement decision.")
	lines.append("")
	lines.append("## Station candidates")
	lines.append("")
	for scene_id in ["S02", "S03"]:
		lines.append("### %s" % scene_id)
		lines.append("")
		lines.append("| candidate station m | delta from geo anchor m | equivalent mapped video s | fixed pose |")
		lines.append("|---:|---:|---:|---|")
		for candidate_value in report.get("station_candidates", {}).get(scene_id, []):
			var candidate: Dictionary = candidate_value
			lines.append("| %.3f | %.3f | %.3f | `%s` |" % [float(candidate.get("candidate_station_m", 0.0)), float(candidate.get("station_delta_from_geo_scene_map_m", 0.0)), float(candidate.get("equivalent_estimated_video_s", 0.0)), JSON.stringify(candidate.get("camera_hold", {}))])
		lines.append("")
		lines.append("The candidate rows isolate station while holding pose; root should compare the road exit and landmark scale before changing yaw/lateral/FOV.")
	lines.append("")
	lines.append("## Continuous snapshot handoff")
	lines.append("")
	lines.append("Eight candidate views are available at 0, 5, 20, 30, 40, 60, 75, and 90 seconds. Default native mode is route-only; `geo_landmarks` retains route/terrain/village/buildings/roadbed and prunes Forest, Roadside, and NearfieldDetails before readiness.")
	lines.append("")
	lines.append("```text")
	lines.append(String(report.get("native_capture_handoff", {}).get("command_route", "")))
	lines.append(String(report.get("native_capture_handoff", {}).get("command_geo_landmarks", "")))
	lines.append("```")
	lines.append("")
	lines.append("Generated by `tools/probe_saisies_village_alignment.gd`; this probe does not edit route/map/camera/village files.")
	return "\n".join(lines) + "\n"

func _print_summary(report: Dictionary) -> void:
	print("round14 route length=%.3f S02=%.3f S03=%.3f snapshots=%d" % [_route.length_m, _route.acceptance_distance("S02"), _route.acceptance_distance("S03"), SNAPSHOT_TIMES_S.size()])
	for feature_value in report.get("named_osm_features", []):
		var feature: Dictionary = feature_value
		print("round14 OSM %s %s station=%.3f lateral=%.3f side=%s clearance=%.3f" % [String(feature.get("id", "")), String(feature.get("name", "")), float(feature.get("nearest_route_station_m", 0.0)), float(feature.get("signed_lateral_m", 0.0)), String(feature.get("road_side", "")), float(feature.get("horizontal_clearance_m", 0.0))])
	print("round14 outputs json=%s markdown=%s" % [_output_dir.path_join("round14_village_alignment.json"), _output_dir.path_join("round14_village_alignment.md")])

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES R14 VILLAGE ALIGNMENT: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES R14 VILLAGE ALIGNMENT READY/HOLD")
		quit(0)
	else:
		for error in _errors:
			print("SAISIES R14 VILLAGE ALIGNMENT ERROR: " + error)
		quit(1)
