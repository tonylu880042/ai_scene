extends SceneTree

## Native S01 camera candidate probe against the frozen R14 full bake.
##
## The probe loads the real baked scene, applies one runtime-only camera pose at
## a time, and captures the ordinary root viewport at 1920x1080.  It keeps the
## scene's route, terrain, buildings, and materials intact.  Candidate values
## are visual diagnostics; the script never reports visual acceptance.
##
## Native example (stdout/stderr should be redirected by the caller):
##   godot --path <round15 work project> --script res://tools/probe_saisies_s01_camera.gd -- \
##     --output-dir=/absolute/path/export/saisies/review/round15_s01/native_candidates

const SCENE_PATH := "res://export/saisies/SaisiesEnvironment_geo_r14.scn"
const CONFIG_PATH := "res://data/saisies_s01_camera_calibration.json"
const REFINEMENT_PATH := "res://scripts/saisies_s01_camera_refinement.gd"
const CAPTURE_SIZE := Vector2i(1920, 1080)
const DEFAULT_OUTPUT_DIR := "res://export/saisies/review/round15_s01/native_candidates"
const DEFAULT_SETTLE_SECONDS := 3.0
const DEFAULT_FRAMES_BETWEEN := 3

var _output_dir := DEFAULT_OUTPUT_DIR
var _config_path := CONFIG_PATH
var _candidate_set := "candidates"
var _candidate_filter := ""
var _settle_seconds := DEFAULT_SETTLE_SECONDS
var _frames_between := DEFAULT_FRAMES_BETWEEN
var _dry_run := false
var _errors: Array[String] = []
var _capture_rows: Array[Dictionary] = []

func _initialize() -> void:
	_parse_args()
	call_deferred("_run")

func _parse_args() -> void:
	for argument in OS.get_cmdline_user_args():
		var arg := String(argument)
		if arg.begins_with("--output-dir="):
			_output_dir = arg.substr(13)
		elif arg.begins_with("--config="):
			_config_path = arg.substr(9)
		elif arg.begins_with("--candidate-set="):
			_candidate_set = arg.substr(16)
		elif arg.begins_with("--candidate-id="):
			_candidate_filter = arg.substr(15)
		elif arg.begins_with("--settle-seconds="):
			_settle_seconds = maxf(float(arg.substr(17)), 0.0)
		elif arg.begins_with("--frames-between="):
			_frames_between = maxi(int(arg.substr(17)), 1)
		elif arg == "--dry-run":
			_dry_run = true

func _run() -> void:
	var config := _load_config()
	if config.is_empty():
		_finish()
		return
	var candidates: Array = config.get(_candidate_set, [])
	if candidates.is_empty():
		_fail("calibration config contains no candidates in set: %s" % _candidate_set)
		_finish()
		return
	var selected: Array[Dictionary] = []
	for item in candidates:
		if not (item is Dictionary):
			_fail("calibration candidate is not an object")
			continue
		var candidate: Dictionary = item
		if _candidate_filter.is_empty() or String(candidate.get("id", "")) == _candidate_filter:
			selected.append(candidate)
	if selected.is_empty():
		_fail("candidate filter did not match any calibration entry: %s" % _candidate_filter)
		_finish()
		return
	if selected.size() > int(config.get("capture", {}).get("candidate_limit", 12)):
		_fail("selected candidate count exceeds configured limit")
		_finish()
		return

	var refinement_script := load(REFINEMENT_PATH) as Script
	if refinement_script == null:
		_fail("camera refinement script could not be loaded: %s" % REFINEMENT_PATH)
		_finish()
		return
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("frozen R14 bake could not be loaded: %s" % SCENE_PATH)
		_finish()
		return
	var scene := packed.instantiate()
	if scene == null:
		_fail("frozen R14 bake instantiate returned null")
		_finish()
		return
	get_root().add_child(scene)
	var root_window := get_root() as Window
	if root_window != null:
		root_window.size = CAPTURE_SIZE
		root_window.content_scale_size = CAPTURE_SIZE
	await process_frame
	await process_frame
	if _settle_seconds > 0.0:
		await create_timer(_settle_seconds).timeout
	var route := scene.get_node_or_null("Route") as Node
	var rig := scene.get_node_or_null("CameraRig") as Node
	if route == null or rig == null:
		_fail("frozen R14 bake is missing Route or CameraRig")
		_finish()
		return
	if not bool(route.get("_ready_built")) and not route.has_method("route_ready"):
		_fail("frozen R14 Route has no readiness contract")
		_finish()
		return
	var refinement = refinement_script.new()
	if refinement == null:
		_fail("camera refinement instance could not be created")
		_finish()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_output_dir))
	var root_viewport := get_root() as Viewport
	if root_viewport == null:
		_fail("root viewport is unavailable")
		_finish()
		return
	if DisplayServer.get_name().to_lower().contains("headless"):
		if not _dry_run:
			_fail("native image probe requires a non-headless renderer")
		else:
			print("S01 CAMERA PROBE DRY RUN: headless renderer accepted for contract parse only")
		_write_report(config, scene, true)
		_finish()
		return

	for candidate in selected:
		var row: Dictionary = refinement.apply_candidate(scene, candidate)
		if not bool(row.get("ok", false)):
			_fail("candidate %s failed: %s" % [String(candidate.get("id", "unnamed")), String(row.get("error", "unknown error"))])
			continue
		for _frame in range(_frames_between):
			await process_frame
		RenderingServer.force_draw()
		var image := root_viewport.get_texture().get_image()
		if image == null or not _image_has_visible_pixels(image):
			_fail("candidate %s produced an empty viewport" % String(candidate.get("id", "unnamed")))
			continue
		var candidate_id := String(candidate.get("id", "unnamed"))
		var image_path := ProjectSettings.globalize_path(_output_dir.path_join(candidate_id + ".png"))
		var save_error := image.save_png(image_path)
		if save_error != OK:
			_fail("candidate %s PNG save failed: %s" % [candidate_id, image_path])
			continue
		row["image"] = image_path
		row["renderer"] = RenderingServer.get_current_rendering_driver_name()
		_capture_rows.append(row)
		print("S01 CAMERA CANDIDATE id=%s station=%.3f pitch=%.3f yaw=%.3f lateral=%.3f fov=%.3f image=%s" % [candidate_id, float(row.get("station_m", 0.0)), float(row.get("pitch_deg", 0.0)), float(row.get("yaw_deg", 0.0)), float(row.get("lateral_m", 0.0)), float(row.get("fov_deg", 0.0)), image_path])
	_write_report(config, scene, false)
	_finish()

func _load_config() -> Dictionary:
	if not FileAccess.file_exists(_config_path):
		_fail("calibration config does not exist: %s" % _config_path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(_config_path))
	if not (parsed is Dictionary):
		_fail("calibration config is not a JSON object: %s" % _config_path)
		return {}
	return parsed

func _write_report(config: Dictionary, scene: Node, dry_run: bool) -> void:
	var report_path := ProjectSettings.globalize_path(_output_dir.path_join("s01_camera_probe.json"))
	var report := {
		"schema_version": 1,
		"scope": "runtime-only S01 camera candidates",
		"visual_acceptance": "root review required; this probe does not claim pass",
		"config_path": _config_path,
		"candidate_set": _candidate_set,
		"scene_path": SCENE_PATH,
		"capture_size": [CAPTURE_SIZE.x, CAPTURE_SIZE.y],
		"dry_run": dry_run,
		"renderer": RenderingServer.get_current_rendering_driver_name(),
		"selected_candidate_count": _capture_rows.size() if not dry_run else 0,
		"candidates": _capture_rows.duplicate(true),
		"source_frame_sha256": String(config.get("source_frame", {}).get("sha256", "")),
		"base_bake": String(config.get("work_project", {}).get("base_bake", SCENE_PATH)),
		"note": "Camera-only runtime transform on frozen R14 bake; no route, terrain, building, or source-file mutation."
	}
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var report_file := FileAccess.open(report_path, FileAccess.WRITE)
	if report_file == null:
		_fail("could not write probe report: %s" % report_path)
		return
	report_file.store_string(JSON.stringify(report, "\t"))
	report_file.close()

func _image_has_visible_pixels(image: Image) -> bool:
	var size := image.get_size()
	if size.x <= 0 or size.y <= 0:
		return false
	var stride := maxi(1, mini(size.x, size.y) / 128)
	var max_value := 0.0
	for y in range(0, size.y, stride):
		for x in range(0, size.x, stride):
			var pixel := image.get_pixel(x, y)
			max_value = maxf(max_value, maxf(pixel.r, maxf(pixel.g, pixel.b)))
	return max_value > 0.01

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES S01 CAMERA PROBE: " + message)

func _finish() -> void:
	if _errors.is_empty():
		print("SAISIES S01 CAMERA PROBE READY (visual review pending)")
		quit(0)
	else:
		print("SAISIES S01 CAMERA PROBE FAIL (%d errors)" % _errors.size())
		quit(1)
