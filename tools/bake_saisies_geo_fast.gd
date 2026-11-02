extends SceneTree

## Manually freeze the native geographic scene once its real generators report
## ready.  The packed scene keeps the generated meshes, MultiMesh buffers and
## collision children; only the lightweight baked route facade and the review
## camera script remain live on reload.
##
## This is deliberately a one-shot bake, not a stale-cache framework:
##
##   godot --path . --script tools/bake_saisies_geo_fast.gd -- \
##     --scene=res://scenes/MainScene_saisies_geo.tscn \
##     --output=res://export/saisies/SaisiesEnvironment_geo_r14.scn

const DEFAULT_SCENE := "res://scenes/MainScene_saisies_geo.tscn"
const DEFAULT_OUTPUT := "res://export/saisies/SaisiesEnvironment_geo_fast.scn"
const BAKED_ROUTE_SCRIPT := "res://scripts/saisies_geo_baked_route.gd"
const GEO_CAMERA_SCRIPT := "res://scripts/saisies_geo_camera.gd"
const REQUIRED_READY_NODES := [
	{"name": "Route", "methods": ["route_ready"], "properties": ["_ready_built"]},
	{"name": "Landscape", "methods": [], "properties": ["landscape_ready"]},
	{"name": "VillageS01S02", "methods": [], "properties": ["village_ready"]},
	{"name": "VillagePropsS01", "methods": [], "properties": ["props_ready"]},
	{"name": "Roadbed", "methods": [], "properties": ["roadbed_ready"]},
	{"name": "Buildings", "methods": [], "properties": ["buildings_ready"]},
	{"name": "Forest", "methods": [], "properties": ["forest_ready"]},
	{"name": "Roadside", "methods": [], "properties": ["roadside_ready"]},
	{"name": "NearfieldDetails", "methods": [], "properties": ["details_ready"]},
]
const ROUTE_EXPORTS := [
	"route_file", "fallback_length_m", "fallback_start_elevation_m",
	"fallback_end_elevation_m", "fallback_road_width_m", "fallback_sample_spacing_m",
	"random_seed", "centerline_start_m", "shoulder_width_m", "downhill_terrain_factor",
	"shoulder_albedo_tint", "village_flatten_radius_m", "geo_route_file",
]
const DATA_FILES := {
	"geo_route": "res://data/saisies_geo_route.json",
	"geo_buildings": "res://data/saisies_geo_buildings.json",
	"geo_forest": "res://data/saisies_geo_forest.json",
	"geo_nearfield": "res://data/saisies_geo_nearfield.json",
	"geo_camera_poses": "res://data/saisies_geo_camera_poses.json",
}
const SUMMARY_COUNT_FIELDS := [
	"node_count", "mesh_node_count", "multimesh_node_count", "multimesh_instance_total",
	"geometry_instance_count", "collision_shape_count", "road_collision_node_count",
	"forest_multimesh_node_count", "multimesh_nonzero_transform_total",
]

var _scene_path := DEFAULT_SCENE
var _output := DEFAULT_OUTPUT
var _manifest_path := ""
var _speed_kmh := 30.0
var _auto_advance := true
var _timeout_seconds := 480.0
var _output_explicit := false
var _errors: Array[String] = []

func _initialize() -> void:
	_parse_arguments()
	if _manifest_path.is_empty():
		_manifest_path = "%s.manifest.json" % _output
	if _is_unsafe_bake_renderer():
		_refuse_unsafe_bake()
		return
	call_deferred("_bake")

func _parse_arguments() -> void:
	for raw_arg in OS.get_cmdline_user_args():
		var arg := String(raw_arg)
		if arg.begins_with("--scene="):
			_scene_path = arg.substr(8)
		elif arg.begins_with("--output="):
			_output = arg.substr(9)
			_output_explicit = true
		elif arg.begins_with("--manifest="):
			_manifest_path = arg.substr(11)
		elif arg.begins_with("--speed-kmh="):
			_speed_kmh = float(arg.substr(12))
		elif arg.begins_with("--timeout-s="):
			_timeout_seconds = maxf(float(arg.substr(12)), 1.0)
		elif arg == "--auto-advance=false":
			_auto_advance = false
		elif arg == "--auto-advance=true":
			_auto_advance = true
	if not is_finite(_speed_kmh) or _speed_kmh <= 0.0:
		_errors.append("--speed-kmh must be a finite positive number")
	if not _output_explicit and _scene_path.ends_with("MainScene_saisies_geo.tscn"):
		_output = DEFAULT_OUTPUT

func _is_unsafe_bake_renderer() -> bool:
	var display_name := DisplayServer.get_name().to_lower()
	return OS.has_feature("headless") or display_name.contains("headless") or display_name.contains("dummy")

func _refuse_unsafe_bake() -> void:
	var display_name := DisplayServer.get_name()
	push_error("Saisies geo fast bake refused: renderer '%s' is headless/Dummy; native rendering is required to preserve MultiMesh buffers." % display_name)
	print("Run this one-shot bake with a native window (without --headless):")
	print("  godot --path . --script tools/bake_saisies_geo_fast.gd -- --scene=%s --output=%s" % [_scene_path, _output])
	quit(1)

func _bake() -> void:
	if not _errors.is_empty():
		_finish_failure()
		return
	if _output.to_lower().contains("v2") or _output == _scene_path or _output.ends_with("MainScene_saisies_baked.tscn"):
		_fail("refusing output path that could overwrite the source or an existing v2 bake: %s" % _output)
		_finish_failure()
		return
	var packed := load(_scene_path) as PackedScene
	if packed == null:
		_fail("source scene could not be loaded: %s" % _scene_path)
		_finish_failure()
		return
	var source := packed.instantiate()
	if source == null:
		_fail("source scene did not instantiate: %s" % _scene_path)
		_finish_failure()
		return
	get_root().add_child(source)
	var route := source.find_child("Route", true, false) as Node
	if route == null:
		_fail("source scene is missing Route")
		_cleanup_source(source)
		_finish_failure()
		return
	var route_script := route.get_script() as Script
	if route_script == null or route_script.resource_path != "res://scripts/saisies_geo_route.gd":
		_fail("source Route must use res://scripts/saisies_geo_route.gd before the fast bake")
		_cleanup_source(source)
		_finish_failure()
		return
	print("saisies geo fast bake: waiting for native readiness scene=%s timeout=%.1fs" % [_scene_path, _timeout_seconds])
	if not await _wait_for_readiness(source):
		_cleanup_source(source)
		_finish_failure()
		return
	await _settle_native_frames()
	var camera: Node = _configure_camera(source)
	if not _errors.is_empty():
		_cleanup_source(source)
		_finish_failure()
		return
	source.set_meta("saisies_geo_fast_bake", true)
	source.set_meta("saisies_geo_fast_bake_source_scene", _scene_path)
	source.set_meta("saisies_geo_fast_bake_speed_kmh", _speed_kmh)
	source.set_meta("saisies_geo_fast_bake_auto_advance", _auto_advance)
	# Setting a script on an in-tree Route clears its script state immediately.
	# Keep the live camera from sampling that transient empty route while the
	# generator scripts are replaced.
	_pause_camera_for_route_swap(camera)
	_replace_route_and_strip_scripts(source, route)
	_prepare_camera_after_route_swap(camera)
	if not _errors.is_empty():
		_cleanup_source(source)
		_finish_failure()
		return
	_set_owners(source, source)
	# Capture exactly the tree that will be handed to PackedScene.pack.  Script
	# stripping and instance flattening must not be hidden by an earlier count.
	var source_summary := _scene_summary(source)
	var baked := PackedScene.new()
	var err := baked.pack(source)
	if err != OK:
		_fail("PackedScene.pack failed (%d)" % err)
		_cleanup_source(source)
		_finish_failure()
		return
	# Probe the in-memory packed resource before writing it.  A generated child
	# that survives as an instanced scene would otherwise leave a misleading
	# output and only fail much later on reload.
	var packed_summary := await _probe_packed_scene(baked)
	if not _summaries_equal(source_summary, packed_summary, "source/packed"):
		_cleanup_source(source)
		_finish_failure()
		return
	var output_path := ProjectSettings.globalize_path(_output)
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var save_flags := ResourceSaver.FLAG_COMPRESS if _output.to_lower().ends_with(".scn") else 0
	err = ResourceSaver.save(baked, _output, save_flags)
	if err != OK:
		_fail("ResourceSaver.save failed (%d) for %s" % [err, _output])
		_cleanup_source(source)
		_finish_failure()
		return
	# Reload the saved file as a separate PackedScene resource as the verifier
	# will do in a fresh process.  This catches serialization-time instance
	# restoration as well as the in-memory pack probe.
	var saved_packed := ResourceLoader.load(_output, "", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	if saved_packed == null:
		_fail("saved packed scene could not be reloaded for native verification")
		_cleanup_source(source)
		_finish_failure()
		return
	var baked_summary := await _probe_packed_scene(saved_packed)
	if not _summaries_equal(source_summary, baked_summary, "source/native reload"):
		_cleanup_source(source)
		_finish_failure()
		return
	var manifest := _make_manifest(source_summary, baked_summary)
	var manifest_absolute := ProjectSettings.globalize_path(_manifest_path)
	DirAccess.make_dir_recursive_absolute(manifest_absolute.get_base_dir())
	var manifest_file := FileAccess.open(_manifest_path, FileAccess.WRITE)
	if manifest_file == null:
		_fail("could not write bake manifest: %s" % _manifest_path)
		_cleanup_source(source)
		_finish_failure()
		return
	manifest_file.store_string(JSON.stringify(manifest, "\t"))
	manifest_file.close()
	print("saisies geo fast bake: output=%s" % output_path)
	print("saisies geo fast bake: manifest=%s" % manifest_absolute)
	print("saisies geo fast bake: source nodes=%d mesh=%d multimesh=%d instances=%d geometry_sha256=%s" % [
		int(source_summary.get("node_count", 0)), int(source_summary.get("mesh_node_count", 0)),
		int(source_summary.get("multimesh_node_count", 0)), int(source_summary.get("multimesh_instance_total", 0)),
		String(source_summary.get("geometry_sha256", "")).substr(0, 16)
	])
	print("SAISIES GEO FAST BAKE READY")
	_cleanup_source(source)
	_finish_success()

func _wait_for_readiness(source: Node) -> bool:
	var start_usec := Time.get_ticks_usec()
	var deadline_usec := start_usec + int(_timeout_seconds * 1_000_000.0)
	var frame := 0
	var last_status := ""
	while Time.get_ticks_usec() < deadline_usec:
		var pending := _pending_readiness(source)
		if pending.is_empty():
			print("saisies geo fast bake: readiness complete frame=%d" % frame)
			return true
		var status := ",".join(pending)
		if status != last_status and (frame % 30 == 0 or last_status.is_empty()):
			print("saisies geo fast bake: waiting [%s]" % status)
			last_status = status
		await process_frame
		frame += 1
	return _fail_return("readiness timeout after %.1fs wall-clock: %s" % [float(Time.get_ticks_usec() - start_usec) / 1_000_000.0, ",".join(_pending_readiness(source))])

func _pending_readiness(source: Node) -> Array[String]:
	var pending: Array[String] = []
	for requirement in REQUIRED_READY_NODES:
		var name := String(requirement["name"])
		var node := source.find_child(name, true, false) as Node
		if node == null or not _node_is_ready(node, requirement["methods"], requirement["properties"]):
			pending.append(name)
	return pending

func _node_is_ready(node: Node, methods: Array, properties: Array) -> bool:
	for method_name in methods:
		if node.has_method(String(method_name)):
			return bool(node.call(String(method_name)))
	for property_name in properties:
		if _has_property(node, String(property_name)):
			return bool(node.get(String(property_name)))
	for meta_name in ["saisies_geo_village_ready", "saisies_village_props_ready", "saisies_geo_roadbed_ready", "saisies_geo_buildings_ready", "saisies_geo_forest_ready", "saisies_geo_roadside_ready", "saisies_geo_nearfield_details_ready"]:
		if node.has_meta(meta_name):
			return bool(node.get_meta(meta_name))
	return false

func _configure_camera(source: Node) -> Node:
	var camera := source.find_child("CameraRig", true, false) as Node
	if camera == null:
		_fail("source scene is missing CameraRig")
		return null
	var camera_script: Script = camera.get_script() as Script
	if camera_script == null or camera_script.resource_path != GEO_CAMERA_SCRIPT:
		_fail("source CameraRig must use %s" % GEO_CAMERA_SCRIPT)
	if _has_property(camera, "cruise_speed_mps"):
		camera.set("cruise_speed_mps", _speed_kmh / 3.6)
	if _has_property(camera, "auto_advance"):
		camera.set("auto_advance", _auto_advance)
	return camera

func _pause_camera_for_route_swap(camera: Node) -> void:
	if camera == null:
		return
	if _has_property(camera, "auto_advance"):
		camera.set("auto_advance", false)
	camera.set_process(false)
	camera.set_physics_process(false)
	camera.set_process_input(false)
	camera.set_process_unhandled_input(false)

func _prepare_camera_after_route_swap(camera: Node) -> void:
	if camera == null:
		return
	# Leave the source camera's processing disabled for the remainder of this
	# bake.  The source Route has no _ready callback after set_script(), so
	# re-enabling it here would sample an empty route while the packed probes
	# await native frames.  A freshly instantiated packed CameraRig starts with
	# its normal process state and is enabled by the verifier/runtime.
	if _has_property(camera, "auto_advance"):
		camera.set("auto_advance", _auto_advance)

func _replace_route_and_strip_scripts(source: Node, route: Node) -> void:
	var saved_values: Dictionary = {}
	for property_name in ROUTE_EXPORTS:
		if _has_property(route, property_name):
			saved_values[property_name] = route.get(property_name)
	var baked_script := load(BAKED_ROUTE_SCRIPT) as Script
	if baked_script == null:
		_fail("baked route script could not be loaded: %s" % BAKED_ROUTE_SCRIPT)
	else:
		route.set_script(baked_script)
		for property_name in saved_values.keys():
			if _has_property(route, String(property_name)):
				route.set(String(property_name), saved_values[property_name])
		if _has_property(route, "baked_manifest_file"):
			route.set("baked_manifest_file", _manifest_path)
		route.set_meta("saisies_geo_fast_bake_route_replaced", true)
	_strip_generator_scripts(source, route)

func _strip_generator_scripts(node: Node, route: Node) -> void:
	# A dynamically instantiated PackedScene keeps its original
	# scene_file_path.  Leaving any nested scene path in a manually packed tree
	# lets reload instantiate external children again (the existing R14 artifact
	# gained 26 such nodes in addition to the shop script's duplicate).  Clear
	# every nested scene path so the packed tree is the authored one-shot
	# geometry; owners are set separately below so generated descendants remain
	# editable packed children.
	var script := node.get_script() as Script
	var strip_script := node != route and node.name != "CameraRig" and script != null
	if node.has_method("get_scene_file_path") and not String(node.get_scene_file_path()).is_empty():
		node.set_scene_file_path("")
	if strip_script:
		node.set_script(null)
	for child in node.get_children():
		_strip_generator_scripts(child, route)
	var remaining := node.get_script() as Script
	if remaining != null:
		var path := remaining.resource_path
		var allowed := node == route and path == BAKED_ROUTE_SCRIPT
		allowed = allowed or (node.name == "CameraRig" and path == GEO_CAMERA_SCRIPT)
		if not allowed:
			_fail("generator or unexpected script remained on %s: %s" % [String(node.get_path()), path])

func _set_owners(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		_set_owners(child, owner)

func _probe_packed_scene(packed: PackedScene) -> Dictionary:
	var holder := Node3D.new()
	holder.name = "SaisiesGeoFastBakeProbe"
	get_root().add_child(holder)
	var instance := packed.instantiate()
	if instance == null:
		_fail("packed scene could not be instantiated for the post-pack summary")
		holder.queue_free()
		return {}
	var camera := instance.find_child("CameraRig", true, false) as Node
	if camera != null and _has_property(camera, "auto_advance"):
		camera.set("auto_advance", false)
	holder.add_child(instance)
	await _settle_native_frames()
	var summary := _scene_summary(instance)
	holder.queue_free()
	await process_frame
	return summary

func _summaries_equal(expected: Dictionary, actual: Dictionary, label: String) -> bool:
	var mismatches: Array[String] = []
	for field in SUMMARY_COUNT_FIELDS:
		if int(expected.get(field, -1)) != int(actual.get(field, -1)):
			mismatches.append("%s=%s/%s" % [field, expected.get(field), actual.get(field)])
	var expected_geometry := String(expected.get("geometry_sha256", ""))
	var actual_geometry := String(actual.get("geometry_sha256", ""))
	if expected_geometry.is_empty() or actual_geometry.is_empty() or expected_geometry != actual_geometry:
		mismatches.append("geometry_sha256=%s/%s" % [expected_geometry, actual_geometry])
	if mismatches.is_empty():
		return true
	_fail("%s summary mismatch: %s" % [label, ", ".join(mismatches)])
	return false

func _make_manifest(source_summary: Dictionary, baked_summary: Dictionary) -> Dictionary:
	var data_hashes: Dictionary = {}
	for key in DATA_FILES.keys():
		data_hashes[key] = _sha256_file(String(DATA_FILES[key]))
	return {
		"schema_version": 1,
		"kind": "saisies_geo_manual_fast_bake",
		"native_only": true,
		"source_scene": _scene_path,
		"source_scene_sha256": _sha256_file(_scene_path),
		"data_sha256": data_hashes,
		"output_scene": _output,
		"baked_sha256": _sha256_file(_output),
		"route_script": BAKED_ROUTE_SCRIPT,
		"camera_script": GEO_CAMERA_SCRIPT,
		"camera_speed_kmh": _speed_kmh,
		"camera_auto_advance": _auto_advance,
		"source_summary": source_summary,
		"baked_summary": baked_summary,
		"verification": {
			"source_packed_counts_equal": true,
			"source_packed_geometry_equal": true,
			"native_reload_counts_equal": true,
			"native_reload_geometry_equal": true,
			"generator_scripts_stripped": true,
		},
		"notes": "Manual native freeze for fast preview; no automatic stale-cache switching.",
	}

func _scene_summary(root: Node) -> Dictionary:
	var summary := {
		"node_count": 0,
		"mesh_node_count": 0,
		"multimesh_node_count": 0,
		"multimesh_instance_total": 0,
		"geometry_instance_count": 0,
		"collision_shape_count": 0,
		"road_collision_node_count": 0,
		"forest_multimesh_node_count": 0,
		"multimesh_nonzero_transform_total": 0,
	}
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	_snapshot_node(root, root, summary, hasher)
	summary["geometry_sha256"] = hasher.finish().hex_encode()
	return summary

func _snapshot_node(root: Node, node: Node, summary: Dictionary, hasher: HashingContext) -> void:
	summary["node_count"] = int(summary["node_count"]) + 1
	var relative_path := String(root.get_path_to(node))
	_hash_string(hasher, "node|%s|%s" % [relative_path, node.get_class()])
	if node is GeometryInstance3D:
		summary["geometry_instance_count"] = int(summary["geometry_instance_count"]) + 1
		_hash_transform(hasher, (node as GeometryInstance3D).global_transform)
	if node is CollisionShape3D:
		summary["collision_shape_count"] = int(summary["collision_shape_count"]) + 1
	if node.name == "SaisiesRoadCollision":
		summary["road_collision_node_count"] = int(summary["road_collision_node_count"]) + 1
	var is_forest := relative_path == "Forest" or relative_path.begins_with("Forest/")
	if node is MeshInstance3D:
		summary["mesh_node_count"] = int(summary["mesh_node_count"]) + 1
		var mesh_node := node as MeshInstance3D
		_hash_string(hasher, "mesh|%s" % relative_path)
		_hash_mesh(hasher, mesh_node.mesh)
	if node is MultiMeshInstance3D:
		summary["multimesh_node_count"] = int(summary["multimesh_node_count"]) + 1
		if is_forest:
			summary["forest_multimesh_node_count"] = int(summary["forest_multimesh_node_count"]) + 1
		var multi_node := node as MultiMeshInstance3D
		var multimesh := multi_node.multimesh
		_hash_string(hasher, "multimesh|%s" % relative_path)
		if multimesh == null:
			_hash_string(hasher, "null")
		else:
			summary["multimesh_instance_total"] = int(summary["multimesh_instance_total"]) + multimesh.instance_count
			_hash_string(hasher, "instances=%d visible=%d format=%d" % [multimesh.instance_count, multimesh.visible_instance_count, multimesh.transform_format])
			_hash_mesh(hasher, multimesh.mesh)
			for index in range(multimesh.instance_count):
				if multimesh.transform_format == MultiMesh.TRANSFORM_3D:
					var instance_transform := multimesh.get_instance_transform(index)
					if _transform_is_nonzero(instance_transform):
						summary["multimesh_nonzero_transform_total"] = int(summary["multimesh_nonzero_transform_total"]) + 1
					_hash_transform(hasher, instance_transform)
				else:
					_hash_string(hasher, str(multimesh.get_instance_transform_2d(index)))
	for child in node.get_children():
		_snapshot_node(root, child, summary, hasher)

func _hash_mesh(hasher: HashingContext, mesh: Mesh) -> void:
	if mesh == null:
		_hash_string(hasher, "mesh=null")
		return
	_hash_string(hasher, "mesh_class=%s surfaces=%d" % [mesh.get_class(), mesh.get_surface_count()])
	if mesh is ArrayMesh:
		var array_mesh := mesh as ArrayMesh
		for surface_index in range(array_mesh.get_surface_count()):
			_hash_string(hasher, "surface=%d" % surface_index)
			var arrays := array_mesh.surface_get_arrays(surface_index)
			for array_index in range(arrays.size()):
				_hash_variant_array(hasher, array_index, arrays[array_index])
	else:
		for property_name in ["size", "height", "radius", "top_radius", "bottom_radius", "radial_segments", "rings", "ring_segments", "subdivide_width", "subdivide_depth", "is_hemisphere", "cap_top", "cap_bottom", "left_to_right"]:
			if _has_property(mesh, property_name):
				_hash_string(hasher, "%s=%s" % [property_name, str(mesh.get(property_name))])
		var faces := mesh.get_faces()
		_hash_string(hasher, "faces=%d" % faces.size())
		if not faces.is_empty():
			hasher.update(faces.to_byte_array())

func _hash_variant_array(hasher: HashingContext, array_index: int, value: Variant) -> void:
	if value == null:
		_hash_string(hasher, "%d=null" % array_index)
	elif value is PackedByteArray:
		_hash_packed(hasher, array_index, "bytes", value.size(), value)
	elif value is PackedVector2Array:
		_hash_packed(hasher, array_index, "v2", value.size(), value.to_byte_array())
	elif value is PackedVector3Array:
		_hash_packed(hasher, array_index, "v3", value.size(), value.to_byte_array())
	elif value is PackedVector4Array:
		_hash_packed(hasher, array_index, "v4", value.size(), value.to_byte_array())
	elif value is PackedColorArray:
		_hash_packed(hasher, array_index, "color", value.size(), value.to_byte_array())
	elif value is PackedFloat32Array:
		_hash_packed(hasher, array_index, "f32", value.size(), value.to_byte_array())
	elif value is PackedFloat64Array:
		_hash_packed(hasher, array_index, "f64", value.size(), value.to_byte_array())
	elif value is PackedInt32Array:
		_hash_packed(hasher, array_index, "i32", value.size(), value.to_byte_array())
	elif value is PackedInt64Array:
		_hash_packed(hasher, array_index, "i64", value.size(), value.to_byte_array())
	else:
		_hash_string(hasher, "%d=%s:%s" % [array_index, typeof(value), str(value)])

func _hash_packed(hasher: HashingContext, array_index: int, kind: String, count: int, bytes: PackedByteArray) -> void:
	_hash_string(hasher, "%d=%s:%d:%d" % [array_index, kind, count, bytes.size()])
	hasher.update(bytes)

func _hash_transform(hasher: HashingContext, transform: Transform3D) -> void:
	_hash_vector3(hasher, transform.basis.x)
	_hash_vector3(hasher, transform.basis.y)
	_hash_vector3(hasher, transform.basis.z)
	_hash_vector3(hasher, transform.origin)

func _transform_is_nonzero(transform: Transform3D) -> bool:
	return transform.origin.length_squared() > 0.000001 \
		or transform.basis.x.distance_squared_to(Vector3.RIGHT) > 0.000001 \
		or transform.basis.y.distance_squared_to(Vector3.UP) > 0.000001 \
		or transform.basis.z.distance_squared_to(Vector3.BACK) > 0.000001

func _settle_native_frames() -> void:
	# Metal batch has previously stalled on repeated post-draw signal waits.  A
	# short process-frame settle plus force_draw is the verified native path here.
	for _frame in range(4):
		await process_frame
	RenderingServer.force_draw()
	for _frame in range(2):
		await process_frame

func _hash_vector3(hasher: HashingContext, value: Vector3) -> void:
	_hash_string(hasher, "%.9f,%.9f,%.9f" % [value.x, value.y, value.z])

func _hash_string(hasher: HashingContext, value: String) -> void:
	hasher.update(value.to_utf8_buffer())
	hasher.update("\n".to_utf8_buffer())

func _sha256_file(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	while not file.eof_reached():
		var chunk := file.get_buffer(1024 * 1024)
		if chunk.is_empty():
			break
		hasher.update(chunk)
	file.close()
	return hasher.finish().hex_encode()

func _has_property(object: Object, property_name: String) -> bool:
	if object == null:
		return false
	for item in object.get_property_list():
		if String(item.get("name", "")) == property_name:
			return true
	return false

func _cleanup_source(source: Node) -> void:
	if is_instance_valid(source):
		source.queue_free()

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("Saisies geo fast bake: " + message)

func _fail_return(message: String) -> bool:
	_fail(message)
	return false

func _finish_failure() -> void:
	print("SAISIES GEO FAST BAKE HOLD: %s" % "; ".join(_errors))
	quit(1)

func _finish_success() -> void:
	quit(0)
