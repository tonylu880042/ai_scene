extends SceneTree

## Reproducible Saisies load profile.
##
## The profiler keeps resource load, PackedScene instantiation, synchronous
## tree signals, deferred module readiness, viewport first-pixel timing, and
## generated geometry/tree records in separate fields.  A headless run never
## reports a GPU first frame; it records that measurement as unsupported.
##
## Examples:
##   godot --headless --path /tmp/saisies_round13_houses_refined \
##     --script /Users/tunghunglu/projects/ai_scene/tools/profile_saisies_load.gd \
##     -- --label=round13_baseline --output=/tmp/saisies_round13_baseline.json \
##     --diagnostics=/tmp/saisies_round13_baseline_forest.json
##   godot --path /tmp/saisies_round13_houses_refined \
##     --script /Users/tunghunglu/projects/ai_scene/tools/profile_saisies_load.gd \
##     -- --label=round13_baseline_native --output=/tmp/saisies_round13_native.json \
##     --diagnostics=/tmp/saisies_round13_native_forest.json \
##     --capture=/tmp/saisies_round13_native_first_image.png

const DEFAULT_SCENE := "res://scenes/MainScene_saisies_geo.tscn"
const DEFAULT_OUTPUT := "/tmp/saisies_load_profile.json"
const DEFAULT_DIAGNOSTICS := "/tmp/saisies_load_forest_diagnostics.json"
const DEFAULT_MAX_WAIT_SECONDS := 600.0
const DEFAULT_WIDTH := 1920
const DEFAULT_HEIGHT := 1080
const NONBLACK_THRESHOLD := 0.003
const COMPLETE_SCENE_SETTLE_FRAMES := 2
const READINESS_PROPERTIES := [
	"geography_ready",
	"landscape_ready",
	"village_ready",
	"props_ready",
	"roadbed_ready",
	"buildings_ready",
	"forest_ready",
	"roadside_ready",
	"details_ready",
]
const INPUT_FILES := [
	"scenes/MainScene_saisies_geo.tscn",
	"data/saisies_geo_route.json",
	"data/saisies_geo_forest.json",
	"data/saisies_geo_buildings.json",
	"data/saisies_geo_nearfield.json",
	"data/saisies_geo_scene_map.json",
	"data/saisies_geo_camera_poses.json",
	"assets/terrain/saisies_geo/metadata.json",
	"assets/terrain/saisies_geo/height.f32",
	"assets/terrain/saisies_geo/albedo.jpg",
]
const SCRIPT_FILES := [
	"scripts/saisies_geo_forest.gd",
	"scripts/saisies_geo_landscape.gd",
	"scripts/saisies_geography.gd",
]

var _args: Dictionary = {}
var _errors: Array[String] = []
var _run_started_usec := 0
var _scene: Node
var _scene_path := DEFAULT_SCENE
var _output_path := DEFAULT_OUTPUT
var _diagnostics_path := DEFAULT_DIAGNOSTICS
var _label := "saisies_load_profile"
var _max_wait_seconds := DEFAULT_MAX_WAIT_SECONDS
var _target_width := DEFAULT_WIDTH
var _target_height := DEFAULT_HEIGHT
var _sample_grid := Vector2i(32, 18)
var _capture_path := ""
var _headless := true
var _scene_ready_ms := -1.0
var _full_scene_actual_ready_ms := -1.0
var _first_nonblack: Dictionary = {
	"status": "pending",
	"measurement_scope": "after_full_scene_actual_ready",
	"found": false,
	"elapsed_ms": -1.0,
	"width": 0,
	"height": 0,
	"sample_count": 0,
	"bright_sample_count": 0,
	"resolution_match": false,
	"settle_frames_required": COMPLETE_SCENE_SETTLE_FRAMES,
	"settle_frames_waited": 0,
}
var _node_records: Dictionary = {}
var _mesh_info_cache: Dictionary = {}
var _geometry_records: Array = []
var _tree_records: Array = []
var _geometry_validation_status := "verified"
var _geometry_validation_unsupported_records := 0
var _frame_count := 0
var _settle_frames_waited := 0

func _initialize() -> void:
	_run_started_usec = Time.get_ticks_usec()
	_parse_arguments()
	_headless = DisplayServer.get_name().to_lower().contains("headless")
	call_deferred("_run")

func _parse_arguments() -> void:
	var all_args := OS.get_cmdline_args()
	all_args.append_array(OS.get_cmdline_user_args())
	for raw_arg in all_args:
		var arg := String(raw_arg)
		if arg.begins_with("--scene="):
			_scene_path = _resource_path(arg.substr(8))
		elif arg.begins_with("--output="):
			_output_path = arg.substr(9)
		elif arg.begins_with("--diagnostics="):
			_diagnostics_path = arg.substr(14)
		elif arg.begins_with("--label="):
			_label = arg.substr(8)
		elif arg.begins_with("--max-wait-s="):
			_max_wait_seconds = maxf(float(arg.substr(13)), 1.0)
		elif arg.begins_with("--width="):
			_target_width = maxi(int(arg.substr(8)), 1)
		elif arg.begins_with("--height="):
			_target_height = maxi(int(arg.substr(9)), 1)
		elif arg.begins_with("--sample-grid="):
			var parts := arg.substr(14).split("x")
			if parts.size() == 2:
				_sample_grid = Vector2i(maxi(int(parts[0]), 1), maxi(int(parts[1]), 1))
		elif arg.begins_with("--capture="):
			_capture_path = arg.substr(10)

func _run() -> void:
	_configure_native_viewport()
	var load_started_usec := Time.get_ticks_usec()
	var packed := load(_scene_path) as PackedScene
	var resource_load_ms := _elapsed_ms(load_started_usec)
	if packed == null:
		_fail("PackedScene could not be loaded: %s" % _scene_path)
		_finish(_make_snapshot(resource_load_ms, -1.0, -1.0, false))
		return

	var instantiate_started_usec := Time.get_ticks_usec()
	_scene = packed.instantiate()
	var instantiate_ms := _elapsed_ms(instantiate_started_usec)
	if _scene == null:
		_fail("PackedScene.instantiate() returned null")
		_finish(_make_snapshot(resource_load_ms, instantiate_ms, -1.0, false))
		return
	_scene.name = "%s_ProfileRoot" % _label
	_arm_scene_hooks(_scene)
	_freeze_camera_advance(_scene)
	var add_started_usec := Time.get_ticks_usec()
	get_root().add_child(_scene)
	var add_child_ms := _elapsed_ms(add_started_usec)

	await _wait_for_readiness()
	_update_actual_readiness()
	var completed := _full_scene_actual_ready()
	if not completed:
		_fail("full scene deferred readiness did not complete before %.1fs timeout" % _max_wait_seconds)
	var snapshot := _make_snapshot(resource_load_ms, instantiate_ms, add_child_ms, completed)
	_finish(snapshot)

func _freeze_camera_advance(scene: Node) -> void:
	var camera_rig := scene.get_node_or_null(NodePath("CameraRig"))
	if camera_rig != null and _has_property(camera_rig, "auto_advance"):
		camera_rig.set("auto_advance", false)

func _configure_native_viewport() -> void:
	if _headless:
		return
	# Keep the first-frame contract explicit. The snapshot also records the
	# actual image dimensions, so a platform that refuses this size is visible.
	DisplayServer.window_set_size(Vector2i(_target_width, _target_height))
	var root_viewport := get_root()
	if root_viewport != null:
		root_viewport.size = Vector2i(_target_width, _target_height)
		root_viewport.content_scale_size = Vector2i(_target_width, _target_height)

func _arm_scene_hooks(scene: Node) -> void:
	scene.ready.connect(Callable(self, "_on_scene_ready").bind(scene), CONNECT_ONE_SHOT)
	for child in scene.get_children():
		var node := child as Node
		if node == null:
			continue
		var key := _node_key(node)
		_node_records[key] = {
			"node": node,
			"path": String(node.name),
			"type": node.get_class(),
			"tree_entered_ms": -1.0,
			"ready_signal_ms": -1.0,
			"actual_ready_ms": -1.0,
			"probe_names": _readiness_probe_names(node),
			"last_probe_values": {},
		}
		node.tree_entered.connect(Callable(self, "_on_node_tree_entered").bind(node), CONNECT_ONE_SHOT)
		node.ready.connect(Callable(self, "_on_node_ready").bind(node), CONNECT_ONE_SHOT)

func _on_scene_ready(scene: Node) -> void:
	if scene == _scene:
		_scene_ready_ms = _elapsed_ms(_run_started_usec)

func _on_node_tree_entered(node: Node) -> void:
	var key := _node_key(node)
	if _node_records.has(key):
		_node_records[key]["tree_entered_ms"] = _elapsed_ms(_run_started_usec)

func _on_node_ready(node: Node) -> void:
	var key := _node_key(node)
	if _node_records.has(key):
		_node_records[key]["ready_signal_ms"] = _elapsed_ms(_run_started_usec)

func _wait_for_readiness() -> void:
	var deadline_usec := Time.get_ticks_usec() + int(_max_wait_seconds * 1000000.0)
	while true:
		_update_actual_readiness()
		var ready := _full_scene_actual_ready()
		if ready and not _headless and _settle_frames_waited < COMPLETE_SCENE_SETTLE_FRAMES:
			_settle_frames_waited += 1
			_frame_count += 1
			await process_frame
			continue
		if ready:
			_probe_first_nonblack()
		var frame_done := _headless or bool(_first_nonblack.get("found", false))
		if ready and frame_done:
			break
		if Time.get_ticks_usec() >= deadline_usec:
			break
		_frame_count += 1
		await process_frame

func _update_actual_readiness() -> void:
	var now_ms := _elapsed_ms(_run_started_usec)
	for key in _node_records.keys():
		var record: Dictionary = _node_records[key]
		if float(record.get("actual_ready_ms", -1.0)) >= 0.0:
			continue
		var node := record.get("node") as Node
		if node == null or not is_instance_valid(node):
			continue
		var ready_signal_ms := float(record.get("ready_signal_ms", -1.0))
		if ready_signal_ms < 0.0:
			continue
		var probe_values := _readiness_probe_values(node, record.get("probe_names", []))
		record["last_probe_values"] = probe_values
		var probes_ready := true
		for probe_name in probe_values.keys():
			if not bool(probe_values[probe_name]):
				probes_ready = false
				break
		if probes_ready:
			record["actual_ready_ms"] = now_ms
	if _full_scene_actual_ready_ms < 0.0 and _full_scene_actual_ready():
		_full_scene_actual_ready_ms = now_ms

func _readiness_probe_names(node: Node) -> Array[String]:
	var result: Array[String] = []
	for property_name in READINESS_PROPERTIES:
		if _has_property(node, property_name):
			result.append(property_name)
	if node.has_method("route_ready"):
		result.append("route_ready_method")
	return result

func _readiness_probe_values(node: Node, names: Array) -> Dictionary:
	var values: Dictionary = {}
	for raw_name in names:
		var name := String(raw_name)
		if name == "route_ready_method":
			values[name] = bool(node.call("route_ready"))
		else:
			values[name] = bool(node.get(name))
	return values

func _has_property(node: Object, property_name: String) -> bool:
	for property in node.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false

func _full_scene_actual_ready() -> bool:
	if _scene_ready_ms < 0.0 or _node_records.is_empty():
		return false
	for key in _node_records.keys():
		if float(_node_records[key].get("actual_ready_ms", -1.0)) < 0.0:
			return false
	return true

func _probe_first_nonblack() -> void:
	if _headless or not _full_scene_actual_ready() or bool(_first_nonblack.get("found", false)):
		return
	var root_viewport := get_root()
	if root_viewport == null or root_viewport.get_texture() == null:
		return
	# force_draw makes the timestamp represent a completed GPU submission. It is
	# only called for native runs; headless runs explicitly omit this metric.
	RenderingServer.force_draw()
	var image := root_viewport.get_texture().get_image()
	if image == null:
		return
	if not _capture_path.is_empty() and not bool(_first_nonblack.get("capture_saved", false)):
		var capture_output := _globalize_output_path(_capture_path)
		DirAccess.make_dir_recursive_absolute(capture_output.get_base_dir())
		var capture_error := image.save_png(capture_output)
		if capture_error == OK:
			_first_nonblack["capture_path"] = capture_output
			_first_nonblack["capture_saved"] = true
		else:
			_fail("could not save complete-scene first image: %s (error=%s)" % [capture_output, capture_error])
	var width := image.get_width()
	var height := image.get_height()
	var sample_count := 0
	var bright_count := 0
	for y_index in range(_sample_grid.y):
		var y := clampi(int((float(y_index) + 0.5) * float(height) / float(_sample_grid.y)), 0, maxi(height - 1, 0))
		for x_index in range(_sample_grid.x):
			var x := clampi(int((float(x_index) + 0.5) * float(width) / float(_sample_grid.x)), 0, maxi(width - 1, 0))
			var pixel := image.get_pixel(x, y)
			sample_count += 1
			if maxf(pixel.r, maxf(pixel.g, pixel.b)) > NONBLACK_THRESHOLD and pixel.a > 0.01:
				bright_count += 1
	_first_nonblack["status"] = "measured"
	_first_nonblack["measurement_scope"] = "after_full_scene_actual_ready"
	_first_nonblack["width"] = width
	_first_nonblack["height"] = height
	_first_nonblack["sample_count"] = sample_count
	_first_nonblack["bright_sample_count"] = bright_count
	_first_nonblack["resolution_match"] = width == _target_width and height == _target_height
	_first_nonblack["settle_frames_required"] = COMPLETE_SCENE_SETTLE_FRAMES
	_first_nonblack["settle_frames_waited"] = _settle_frames_waited
	if bright_count > 0 and bool(_first_nonblack["resolution_match"]):
		_first_nonblack["found"] = true
		_first_nonblack["elapsed_ms"] = _elapsed_ms(_run_started_usec)

func _make_snapshot(resource_load_ms: float, instantiate_ms: float, add_child_ms: float, completed: bool) -> Dictionary:
	_update_actual_readiness()
	_collect_geometry_records()
	var snapshot := {
		"schema_version": 3,
		"label": _label,
		"scene_path": _scene_path,
		"project_root": ProjectSettings.globalize_path("res://").trim_suffix("/"),
		"renderer": DisplayServer.get_name(),
		"headless": _headless,
		"target_resolution": [_target_width, _target_height],
		"actual_resolution": [_first_nonblack.get("width", 0), _first_nonblack.get("height", 0)],
		"completed": completed,
		"errors": _errors.duplicate(),
		"timings_ms": {
			"resource_load": resource_load_ms,
			"instantiate": instantiate_ms,
			"add_child": add_child_ms,
			"scene_ready_signal": _scene_ready_ms,
			"full_scene_actual_ready": _full_scene_actual_ready_ms if completed else -1.0,
			"process_frames_waited": _frame_count,
			"total_until_snapshot": _elapsed_ms(_run_started_usec),
		},
		"complete_scene_first_image_settle_frames": {
			"required": COMPLETE_SCENE_SETTLE_FRAMES,
			"waited": _settle_frames_waited,
			"scope": "native_complete_scene_first_image_only",
		},
		"complete_scene_first_image_1920x1080": _first_nonblack.duplicate(true) if not _headless else {"status": "unsupported_headless", "measurement_scope": "after_full_scene_actual_ready", "found": false},
		"first_nonblack_1920x1080": _first_nonblack.duplicate(true) if not _headless else {"status": "unsupported_headless", "measurement_scope": "after_full_scene_actual_ready", "found": false},
		"top_level_nodes": _serialise_node_records(),
		"counts": _collect_tree_metrics(),
		"geometry_validation_status": _geometry_validation_status,
		"geometry_validation_unsupported_records": _geometry_validation_unsupported_records,
		"geometry_records": _geometry_records,
		"geometry_records_sha256": _digest_variant(_geometry_records),
		"tree_records": _tree_records,
		"tree_records_sha256": _digest_variant(_tree_records),
		"instrumentation": _collect_instrumentation(),
		"input_hashes": _file_hashes(INPUT_FILES),
		"script_hashes": _file_hashes(SCRIPT_FILES),
	}
	return snapshot

func _serialise_node_records() -> Array:
	var result: Array = []
	for key in _node_records.keys():
		var source: Dictionary = _node_records[key]
		result.append({
			"path": source.get("path", ""),
			"type": source.get("type", ""),
			"tree_entered_ms": source.get("tree_entered_ms", -1.0),
			"ready_signal_ms": source.get("ready_signal_ms", -1.0),
			"actual_ready_ms": source.get("actual_ready_ms", -1.0),
			"probe_names": source.get("probe_names", []),
			"last_probe_values": source.get("last_probe_values", {}),
		})
	result.sort_custom(Callable(self, "_sort_path_records"))
	return result

func _sort_path_records(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("path", "")) < String(b.get("path", ""))

func _collect_tree_metrics() -> Dictionary:
	var result := {
		"node_count": 0,
		"node3d_count": 0,
		"mesh_instance_count": 0,
		"multimesh_instance_count": 0,
		"multimesh_instance_total": 0,
		"geometry_instance_count": 0,
		"collision_shape_count": 0,
		"camera_count": 0,
		"light_count": 0,
		"unique_mesh_resource_count": 0,
		"unique_multimesh_resource_count": 0,
		"mesh_vertex_total": 0,
		"mesh_index_total": 0,
		"mesh_triangle_total": 0,
		"mesh_surface_total": 0,
		"multimesh_mesh_instance_total": 0,
	}
	if _scene == null:
		return result
	var stack: Array[Node] = [_scene]
	var mesh_ids: Dictionary = {}
	var multimesh_ids: Dictionary = {}
	while not stack.is_empty():
		var node: Node = stack.pop_back() as Node
		result["node_count"] = int(result["node_count"]) + 1
		if node is Node3D:
			result["node3d_count"] = int(result["node3d_count"]) + 1
		if node is GeometryInstance3D:
			result["geometry_instance_count"] = int(result["geometry_instance_count"]) + 1
		if node is CollisionShape3D:
			result["collision_shape_count"] = int(result["collision_shape_count"]) + 1
		if node is Camera3D:
			result["camera_count"] = int(result["camera_count"]) + 1
		if node is Light3D:
			result["light_count"] = int(result["light_count"]) + 1
		if node is MeshInstance3D:
			result["mesh_instance_count"] = int(result["mesh_instance_count"]) + 1
			var mesh := (node as MeshInstance3D).mesh
			if mesh != null:
				var mesh_id := str(mesh.get_instance_id())
				if not mesh_ids.has(mesh_id):
					mesh_ids[mesh_id] = true
					var mesh_counts := _mesh_array_counts(mesh)
					result["mesh_vertex_total"] = int(result["mesh_vertex_total"]) + int(mesh_counts["vertices"])
					result["mesh_index_total"] = int(result["mesh_index_total"]) + int(mesh_counts["indices"])
					result["mesh_triangle_total"] = int(result["mesh_triangle_total"]) + int(mesh_counts["triangles"])
					result["mesh_surface_total"] = int(result["mesh_surface_total"]) + int(mesh_counts["surfaces"])
		if node is MultiMeshInstance3D:
			result["multimesh_instance_count"] = int(result["multimesh_instance_count"]) + 1
			var multimesh := (node as MultiMeshInstance3D).multimesh
			if multimesh != null:
				var multimesh_id := str(multimesh.get_instance_id())
				if not multimesh_ids.has(multimesh_id):
					multimesh_ids[multimesh_id] = true
				result["multimesh_instance_total"] = int(result["multimesh_instance_total"]) + multimesh.instance_count
				if multimesh.mesh != null:
					var mm_counts := _mesh_array_counts(multimesh.mesh)
					result["multimesh_mesh_instance_total"] = int(result["multimesh_mesh_instance_total"]) + int(mm_counts["triangles"]) * multimesh.instance_count
		for child in node.get_children():
			stack.append(child)
	result["unique_mesh_resource_count"] = mesh_ids.size()
	result["unique_multimesh_resource_count"] = multimesh_ids.size()
	return result

func _mesh_array_counts(mesh: Mesh) -> Dictionary:
	return (_mesh_geometry_info(mesh).get("mesh_counts", {
		"surfaces": 0,
		"vertices": 0,
		"indices": 0,
		"triangles": 0,
	}) as Dictionary).duplicate(true)

func _collect_geometry_records() -> void:
	_geometry_records.clear()
	_tree_records.clear()
	_mesh_info_cache.clear()
	_geometry_validation_status = "verified"
	_geometry_validation_unsupported_records = 0
	if _scene == null:
		return
	for child in _scene.get_children():
		var record := _collect_subtree_record(child)
		_geometry_records.append(record)
	_geometry_records.sort_custom(Callable(self, "_sort_path_records"))
	_geometry_records = _geometry_records

func _collect_subtree_record(root: Node) -> Dictionary:
	var record := {
		"path": String(_scene.get_path_to(root)),
		"node_count": 0,
		"mesh_instance_count": 0,
		"multimesh_instance_count": 0,
		"multimesh_instance_total": 0,
		"mesh_records": [],
	}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back() as Node
		record["node_count"] = int(record["node_count"]) + 1
		if node is MeshInstance3D:
			record["mesh_instance_count"] = int(record["mesh_instance_count"]) + 1
			var mesh_node := node as MeshInstance3D
			if mesh_node.mesh != null:
				record["mesh_records"].append(_mesh_instance_record(mesh_node))
		if node is MultiMeshInstance3D:
			record["multimesh_instance_count"] = int(record["multimesh_instance_count"]) + 1
			var multi_node := node as MultiMeshInstance3D
			if multi_node.multimesh != null:
				record["multimesh_instance_total"] = int(record["multimesh_instance_total"]) + multi_node.multimesh.instance_count
				var tree_record := _multimesh_instance_record(multi_node)
				record["mesh_records"].append(tree_record)
				if String(_scene.get_path_to(root)).begins_with("Forest") or String(_scene.get_path_to(multi_node)).begins_with("Forest"):
					_tree_records.append(tree_record)
		for child in node.get_children():
			stack.append(child)
	record["mesh_records"].sort_custom(Callable(self, "_sort_path_records"))
	return record

func _mesh_instance_record(node: MeshInstance3D) -> Dictionary:
	var mesh := node.mesh
	var info := _mesh_geometry_info(mesh)
	_mark_geometry_validation(info)
	var record := {
		"path": String(_scene.get_path_to(node)),
		"kind": "MeshInstance3D",
		"mesh_class": mesh.get_class(),
		"mesh_resource_path": mesh.resource_path,
		"mesh_counts": info["mesh_counts"],
		"mesh_digest": info["mesh_digest"],
		"mesh_geometry_validation": info["geometry_validation"],
		"global_transform": _transform_values(node.global_transform),
	}
	_add_primitive_mesh_fields(record, info)
	return record

func _multimesh_instance_record(node: MultiMeshInstance3D) -> Dictionary:
	var multimesh := node.multimesh
	var mesh := multimesh.mesh
	var info := _mesh_geometry_info(mesh) if mesh != null else _empty_mesh_geometry_info()
	_mark_geometry_validation(info)
	var record := {
		"path": String(_scene.get_path_to(node)),
		"kind": "MultiMeshInstance3D",
		"mesh_class": mesh.get_class() if mesh != null else "",
		"mesh_resource_path": mesh.resource_path if mesh != null else "",
		"mesh_counts": info["mesh_counts"],
		"mesh_digest": info["mesh_digest"],
		"mesh_geometry_validation": info["geometry_validation"],
		"instance_count": multimesh.instance_count,
		"instance_transform_digest": _multimesh_transform_digest(multimesh),
		"node_global_transform": _transform_values(node.global_transform),
		"forest_species": _compact_variant(node.get_meta("forest_species", "")),
		"authored_positions_digest": _digest_variant(node.get_meta("forest_authored_positions", PackedVector3Array())),
		"authored_s_digest": _digest_variant(node.get_meta("forest_authored_s", PackedFloat32Array())),
		"authored_local_transforms_digest": _digest_variant(node.get_meta("forest_authored_local_transforms", [])),
	}
	_add_primitive_mesh_fields(record, info)
	return record

func _mesh_geometry_digest(mesh: Mesh) -> String:
	return String(_mesh_geometry_info(mesh).get("mesh_digest", ""))

func _empty_mesh_geometry_info() -> Dictionary:
	return {
		"mesh_counts": {"surfaces": 0, "vertices": 0, "indices": 0, "triangles": 0},
		"mesh_digest": "",
		"geometry_validation": "unsupported_null_mesh",
		"primitive_properties": {},
		"primitive_faces_count": 0,
		"unsupported_primitive_properties": [],
	}

func _mesh_geometry_info(mesh: Mesh) -> Dictionary:
	if mesh == null:
		return _empty_mesh_geometry_info()
	var key := str(mesh.get_instance_id())
	if _mesh_info_cache.has(key):
		return _mesh_info_cache[key] as Dictionary
	var result := {
		"mesh_counts": {"surfaces": mesh.get_surface_count(), "vertices": 0, "indices": 0, "triangles": 0},
		"mesh_digest": "",
		"geometry_validation": "unsupported_mesh",
		"primitive_properties": {},
		"primitive_faces_count": 0,
		"unsupported_primitive_properties": [],
	}
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	_hash_update(hasher, mesh.get_class().to_utf8_buffer())
	_hash_update(hasher, mesh.resource_path.to_utf8_buffer())
	if mesh is ArrayMesh:
		var has_vertices := false
		for surface_index in mesh.get_surface_count():
			_hash_update(hasher, str(surface_index).to_utf8_buffer())
			var arrays := mesh.surface_get_arrays(surface_index)
			if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
				var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
				result["mesh_counts"]["vertices"] = int(result["mesh_counts"]["vertices"]) + vertices.size()
				has_vertices = has_vertices or not vertices.is_empty()
				_hash_update(hasher, vertices.to_byte_array())
			if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
				var indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
				var index_count := indices.size()
				result["mesh_counts"]["indices"] = int(result["mesh_counts"]["indices"]) + index_count
				result["mesh_counts"]["triangles"] = int(result["mesh_counts"]["triangles"]) + index_count / 3
				_hash_update(hasher, indices.to_byte_array())
			if arrays.size() > Mesh.ARRAY_TEX_UV and arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
				_hash_update(hasher, (arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array).to_byte_array())
		result["geometry_validation"] = "verified_array" if has_vertices else "unsupported_array"
	else:
		var primitive_properties := _primitive_mesh_properties(mesh)
		result["primitive_properties"] = primitive_properties.get("values", {})
		result["unsupported_primitive_properties"] = primitive_properties.get("unsupported", [])
		var faces := mesh.get_faces()
		result["primitive_faces_count"] = faces.size()
		_hash_update(hasher, JSON.stringify(_canonical_variant(result["primitive_properties"])).to_utf8_buffer())
		_hash_update(hasher, str(faces.size()).to_utf8_buffer())
		if not faces.is_empty():
			result["mesh_counts"]["vertices"] = faces.size()
			result["mesh_counts"]["indices"] = faces.size()
			result["mesh_counts"]["triangles"] = faces.size() / 3
			_hash_update(hasher, faces.to_byte_array())
			result["geometry_validation"] = "verified_primitive_faces"
		else:
			result["geometry_validation"] = "unsupported_primitive"
	var digest := hasher.finish().hex_encode()
	result["mesh_digest"] = digest
	_mesh_info_cache[key] = result
	return result

func _primitive_mesh_properties(mesh: Mesh) -> Dictionary:
	var values: Dictionary = {}
	var unsupported: Array[String] = []
	for raw_property in mesh.get_property_list():
		var property_name := String(raw_property.get("name", ""))
		if property_name.is_empty() or property_name.begins_with("_") or property_name in [
			"resource_name",
			"resource_path",
			"resource_local_to_scene",
			"resource_scene_unique_id",
			"resource_uid",
			"script",
			"material",
		]:
			continue
		var value = mesh.get(property_name)
		if value is Object or value is RID or value is Callable:
			unsupported.append(property_name)
			continue
		values[property_name] = _canonical_variant(value)
	return {"values": values, "unsupported": unsupported}

func _mark_geometry_validation(info: Dictionary) -> void:
	var validation := String(info.get("geometry_validation", "unsupported_mesh"))
	if not validation.begins_with("verified_"):
		_geometry_validation_status = "unsupported"
		_geometry_validation_unsupported_records += 1

func _add_primitive_mesh_fields(record: Dictionary, info: Dictionary) -> void:
	if not (info.get("primitive_properties", {}) as Dictionary).is_empty():
		record["primitive_properties"] = info["primitive_properties"]
	if not (info.get("unsupported_primitive_properties", []) as Array).is_empty():
		record["unsupported_primitive_properties"] = info["unsupported_primitive_properties"]
	record["primitive_faces_count"] = info.get("primitive_faces_count", 0)

func _multimesh_transform_digest(multimesh: MultiMesh) -> String:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	_hash_update(hasher, str(multimesh.instance_count).to_utf8_buffer())
	for index in multimesh.instance_count:
		var values := PackedFloat32Array(_transform_values(multimesh.get_instance_transform(index)))
		_hash_update(hasher, values.to_byte_array())
	return hasher.finish().hex_encode()

func _transform_values(transform: Transform3D) -> Array:
	return [
		transform.basis.x.x, transform.basis.x.y, transform.basis.x.z,
		transform.basis.y.x, transform.basis.y.y, transform.basis.y.z,
		transform.basis.z.x, transform.basis.z.y, transform.basis.z.z,
		transform.origin.x, transform.origin.y, transform.origin.z,
	]

func _collect_instrumentation() -> Dictionary:
	var result: Dictionary = {}
	if _scene == null:
		return result
	for path in ["Route", "Landscape", "Forest"]:
		var node := _scene.get_node_or_null(NodePath(path))
		if node == null:
			continue
		var phases: Dictionary = node.get_meta("saisies_profile_phases", {}) if node.has_meta("saisies_profile_phases") else {}
		var entry := {"phases": phases.duplicate(true), "meta": _compact_meta(node)}
		result[path] = entry
		if path == "Route":
			var geography = node.get("geography")
			if geography != null and geography.has_method("profile_snapshot"):
				result["Geography"] = geography.call("profile_snapshot")
	return result

func _compact_meta(node: Node) -> Dictionary:
	var result: Dictionary = {}
	for raw_name in node.get_meta_list():
		var name := String(raw_name)
		result[name] = _compact_variant(node.get_meta(raw_name))
	return result

func _compact_variant(value: Variant) -> Variant:
	if value == null or value is bool or value is int or value is float or value is String:
		return value
	if value is StringName or value is NodePath:
		return String(value)
	if value is Vector2:
		return [value.x, value.y]
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Color:
		return [value.r, value.g, value.b, value.a]
	if value is Transform3D:
		return _transform_values(value)
	if value is PackedByteArray or value is PackedInt32Array or value is PackedFloat32Array or value is PackedVector2Array or value is PackedVector3Array:
		return {"type": typeof(value), "count": value.size(), "sha256": _digest_variant(value)}
	if value is Array:
		return {"type": "Array", "count": value.size(), "sha256": _digest_variant(value)}
	if value is Dictionary:
		var keys: Array[String] = []
		for key in value.keys():
			keys.append(String(key))
		keys.sort()
		return {"type": "Dictionary", "count": value.size(), "keys": keys, "sha256": _digest_variant(value)}
	return {"type": typeof(value), "text": str(value)}

func _digest_variant(value: Variant) -> String:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	if value is PackedByteArray:
		_hash_update(hasher, value)
		return hasher.finish().hex_encode()
	if value is PackedInt32Array:
		_hash_update(hasher, (value as PackedInt32Array).to_byte_array())
		return hasher.finish().hex_encode()
	if value is PackedFloat32Array:
		_hash_update(hasher, (value as PackedFloat32Array).to_byte_array())
		return hasher.finish().hex_encode()
	if value is PackedVector2Array:
		_hash_update(hasher, (value as PackedVector2Array).to_byte_array())
		return hasher.finish().hex_encode()
	if value is PackedVector3Array:
		_hash_update(hasher, (value as PackedVector3Array).to_byte_array())
		return hasher.finish().hex_encode()
	var canonical: Variant = _canonical_variant(value)
	_hash_update(hasher, JSON.stringify(canonical).to_utf8_buffer())
	return hasher.finish().hex_encode()

func _hash_update(hasher: HashingContext, bytes: PackedByteArray) -> void:
	if bytes.is_empty():
		return
	hasher.update(bytes)

func _canonical_variant(value: Variant) -> Variant:
	if value == null or value is bool or value is int or value is float or value is String:
		return value
	if value is StringName or value is NodePath:
		return String(value)
	if value is Vector2:
		return [value.x, value.y]
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Color:
		return [value.r, value.g, value.b, value.a]
	if value is Transform3D:
		return _transform_values(value)
	if value is PackedVector2Array:
		var vector2_values: Array = []
		for item in value:
			vector2_values.append([item.x, item.y])
		return vector2_values
	if value is PackedVector3Array:
		var vector3_values: Array = []
		for item in value:
			vector3_values.append([item.x, item.y, item.z])
		return vector3_values
	if value is PackedFloat32Array or value is PackedInt32Array or value is PackedByteArray:
		var packed_values: Array = []
		for item in value:
			packed_values.append(item)
		return packed_values
	if value is Array:
		var array_values: Array = []
		for item in value:
			array_values.append(_canonical_variant(item))
		return array_values
	if value is Dictionary:
		var keys: Array[String] = []
		for raw_key in value.keys():
			keys.append(String(raw_key))
		keys.sort()
		var dictionary_values: Dictionary = {}
		for raw_key in value.keys():
			var key := String(raw_key)
			dictionary_values[key] = _canonical_variant(value[raw_key])
		return dictionary_values
	return str(value)

func _file_hashes(paths: Array) -> Dictionary:
	var result: Dictionary = {}
	for raw_path in paths:
		var path := String(raw_path)
		var resource_path := _resource_path(path)
		var absolute_path := ProjectSettings.globalize_path(resource_path)
		if not FileAccess.file_exists(resource_path):
			result[path] = {"status": "missing"}
			continue
		var bytes := FileAccess.get_file_as_bytes(resource_path)
		result[path] = {"status": "ok", "bytes": bytes.size(), "sha256": _digest_variant(bytes)}
	return result

func _write_json(path: String, payload: Dictionary) -> bool:
	var output := _globalize_output_path(path)
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		_fail("could not open output: %s" % output)
		return false
	file.store_string(JSON.stringify(_canonical_variant(payload), "\t"))
	file.store_line("")
	file.close()
	return true

func _finish(snapshot: Dictionary) -> void:
	_write_json(_output_path, snapshot)
	var diagnostics := {
		"schema_version": 1,
		"label": _label,
		"scene_path": _scene_path,
		"status": "saved_compact_only",
		"forest": snapshot.get("instrumentation", {}).get("Forest", {}),
		"tree_records": snapshot.get("tree_records", []),
		"tree_records_sha256": snapshot.get("tree_records_sha256", ""),
	}
	_write_json(_diagnostics_path, diagnostics)
	var status := "PASS" if _errors.is_empty() else "FAIL"
	print("SAISIES LOAD PROFILE %s label=%s scene=%s resource_load_ms=%.3f instantiate_ms=%.3f scene_ready_ms=%.3f full_ready_ms=%.3f first_nonblack_ms=%s nodes=%d meshes=%d multimeshes=%d tree_records=%d output=%s" % [
		status,
		_label,
		_scene_path,
		float(snapshot.get("timings_ms", {}).get("resource_load", -1.0)),
		float(snapshot.get("timings_ms", {}).get("instantiate", -1.0)),
		float(snapshot.get("timings_ms", {}).get("scene_ready_signal", -1.0)),
		float(snapshot.get("timings_ms", {}).get("full_scene_actual_ready", -1.0)),
		"unsupported_headless" if _headless else str(snapshot.get("complete_scene_first_image_1920x1080", {}).get("elapsed_ms", -1.0)),
		int(snapshot.get("counts", {}).get("node_count", 0)),
		int(snapshot.get("counts", {}).get("mesh_instance_count", 0)),
		int(snapshot.get("counts", {}).get("multimesh_instance_count", 0)),
		(snapshot.get("tree_records", []) as Array).size(),
		_globalize_output_path(_output_path),
	])
	quit(0 if _errors.is_empty() else 2)

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES LOAD PROFILE: " + message)

func _node_key(node: Node) -> String:
	return str(node.get_instance_id())

func _elapsed_ms(started_usec: int) -> float:
	return float(Time.get_ticks_usec() - started_usec) / 1000.0

func _resource_path(path: String) -> String:
	if path.begins_with("res://"):
		return path
	if path.begins_with("/"):
		return path
	return "res://" + path.trim_prefix("./")

func _globalize_output_path(path: String) -> String:
	return ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
