extends Node3D

## Native-only one-shot bake for the generated whole-route release overlays.
##
## The R35 base remains the source of the geographic world.  This bake copies
## only the generated ReleaseForest and ReleaseRoadside geometry into a small
## static PackedScene, preserving each MeshInstance/MultiMeshInstance global
## transform and MultiMesh instance buffer.  It deliberately refuses headless
## and Dummy renderers because those cannot prove that the GPU buffers survived
## serialization.

const DEFAULT_SOURCE_SCENE := "res://scenes/MainScene_saisies_release.tscn"
const DEFAULT_OUTPUT := "res://export/saisies/release_candidate/saisies_release_geometry_cache.scn"
const DEFAULT_MANIFEST := "res://export/saisies/release_candidate/saisies_release_geometry_cache.manifest.json"
const DEFAULT_TIMEOUT_SECONDS := 900.0

@export var existing_source_path: NodePath

var _source_scene_path := DEFAULT_SOURCE_SCENE
var _output_path := DEFAULT_OUTPUT
var _manifest_path := DEFAULT_MANIFEST
var _timeout_seconds := DEFAULT_TIMEOUT_SECONDS
var _errors: Array[String] = []
var _copy_serial := 0
var _owns_source_instance := false

func _ready() -> void:
	process_priority = -300
	_parse_arguments()
	if _is_unsafe_bake_renderer():
		_refuse_unsafe_bake()
		return
	call_deferred("_bake")

func _parse_arguments() -> void:
	for raw_arg in OS.get_cmdline_user_args():
		var arg := String(raw_arg)
		if arg.begins_with("--saisies-release-bake-scene="):
			_source_scene_path = arg.trim_prefix("--saisies-release-bake-scene=")
		elif arg.begins_with("--saisies-release-bake-output="):
			_output_path = arg.trim_prefix("--saisies-release-bake-output=")
		elif arg.begins_with("--saisies-release-bake-manifest="):
			_manifest_path = arg.trim_prefix("--saisies-release-bake-manifest=")
		elif arg.begins_with("--saisies-release-bake-timeout-s="):
			_timeout_seconds = maxf(float(arg.trim_prefix("--saisies-release-bake-timeout-s=")), 1.0)
	if _manifest_path == DEFAULT_MANIFEST and _output_path != DEFAULT_OUTPUT:
		_manifest_path = "%s.manifest.json" % _output_path
	if not is_finite(_timeout_seconds):
		_errors.append("bake timeout must be finite")

func _is_unsafe_bake_renderer() -> bool:
	var display_name := DisplayServer.get_name().to_lower()
	return OS.has_feature("headless") or display_name.contains("headless") or display_name.contains("dummy")

func _refuse_unsafe_bake() -> void:
	var display_name := DisplayServer.get_name()
	push_error("Saisies release cache bake refused: renderer '%s' is headless/Dummy; native GPU serialization is required." % display_name)
	print("Run without --headless, for example:")
	print("  godot --path . res://scenes/MainScene_saisies_release_native_bake.tscn -- --saisies-release-bake-output=%s" % _output_path)
	_finish_failure()

func _bake() -> void:
	if not _errors.is_empty():
		_finish_failure()
		return
	if _unsafe_output_path():
		_finish_failure()
		return
	var source := _resolve_source()
	if source == null:
		_finish_failure()
		return
	print("Saisies release cache bake: waiting for ReleaseBase, controller and generated modules")
	if not await _wait_for_readiness(source):
		_cleanup_source(source)
		_finish_failure()
		return
	await _settle_native_frames()
	var forest := source.find_child("ReleaseForest", true, false) as Node
	var roadside := source.find_child("ReleaseRoadside", true, false) as Node
	var terminals := source.find_child("ReleaseTerminals", true, false) as Node
	if forest == null or roadside == null or terminals == null:
		_fail("release source is missing ReleaseForest, ReleaseRoadside or ReleaseTerminals")
		_cleanup_source(source)
		_finish_failure()
		return
	var module_nodes: Array[Node] = [forest, roadside, terminals]
	var source_summary := _geometry_summary(module_nodes)
	var cache_root := Node3D.new()
	cache_root.name = "SaisiesReleaseGeometryCache"
	get_tree().root.add_child(cache_root)
	cache_root.set_meta("saisies_release_cache_source_scene", _source_scene_path)
	cache_root.set_meta("saisies_release_cache_native_only", true)
	cache_root.set_meta("saisies_release_cache_visibility_policy", "source_effective_visibility_engine_visibility_range")
	cache_root.set_meta("saisies_release_cache_pose", _pose_snapshot(source))
	var module_records: Array[Dictionary] = []
	for module in module_nodes:
		var before_mesh := _mesh_node_count
		var before_multi := _multimesh_node_count
		var before_labels := _label_node_count
		var before_instances := _multimesh_instance_total
		_copy_geometry_nodes(module, cache_root, String(module.name))
		module_records.append({
			"source_node": String(module.name),
			"source_path": String(module.get_path()),
			"mesh_node_count": _mesh_node_count - before_mesh,
			"multimesh_node_count": _multimesh_node_count - before_multi,
			"label_node_count": _label_node_count - before_labels,
			"multimesh_instance_total": _multimesh_instance_total - before_instances,
			"ready_meta": String(module.name) == "ReleaseForest" and bool(module.get_meta("saisies_release_forest_ready", false)) or String(module.name) == "ReleaseRoadside" and bool(module.get_meta("saisies_release_roadside_ready", false)) or String(module.name) == "ReleaseTerminals" and bool(module.get_meta("saisies_release_terminals_ready", false)),
		})
	cache_root.set_meta("saisies_release_cache_module_records", module_records)
	cache_root.set_meta("saisies_release_cache_mesh_node_count", _mesh_node_count)
	cache_root.set_meta("saisies_release_cache_multimesh_node_count", _multimesh_node_count)
	cache_root.set_meta("saisies_release_cache_label_node_count", _label_node_count)
	cache_root.set_meta("saisies_release_cache_multimesh_instance_total", _multimesh_instance_total)
	cache_root.set_meta("saisies_release_cache_geometry_count", _mesh_node_count + _multimesh_node_count + _label_node_count)
	var terminal_record: Dictionary = {}
	for module_record in module_records:
		if String(module_record.get("source_node", "")) == "ReleaseTerminals":
			terminal_record = module_record
			break
	cache_root.set_meta("saisies_release_cache_terminal_geometry_count", int(terminal_record.get("mesh_node_count", 0)) + int(terminal_record.get("multimesh_node_count", 0)) + int(terminal_record.get("label_node_count", 0)))
	_copy_terminal_contract_metadata(terminals, cache_root)
	var cached_summary := _geometry_summary([cache_root])
	var source_hash := String(source_summary.get("gpu_hash_sha256", ""))
	var cached_hash := String(cached_summary.get("gpu_hash_sha256", ""))
	if source_hash.is_empty() or source_hash != cached_hash:
		_fail("source/cache GPU geometry hash mismatch: %s / %s" % [source_hash, cached_hash])
		_cleanup_source(source)
		_cleanup(cache_root)
		_finish_failure()
		return
	cache_root.set_meta("saisies_release_cache_gpu_hash_sha256", cached_hash)
	cache_root.set_meta("saisies_release_cache_ready", true)
	cache_root.set_meta("saisies_release_forest_ready", true)
	cache_root.set_meta("saisies_release_terminals_ready", true)
	cache_root.set_meta("saisies_release_forest_count", _multimesh_instance_total)
	cache_root.set_meta("saisies_release_terminals_count", _label_node_count)
	cache_root.set_meta("saisies_release_cache_manifest", _manifest_path)
	var baked := PackedScene.new()
	var pack_error := baked.pack(cache_root)
	if pack_error != OK:
		_fail("PackedScene.pack failed (%d)" % pack_error)
		_cleanup_source(source)
		_cleanup(cache_root)
		_finish_failure()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_output_path).get_base_dir())
	var save_flags := ResourceSaver.FLAG_COMPRESS if _output_path.to_lower().ends_with(".scn") else 0
	var save_error := ResourceSaver.save(baked, _output_path, save_flags)
	if save_error != OK:
		_fail("ResourceSaver.save failed (%d): %s" % [save_error, _output_path])
		_cleanup_source(source)
		_cleanup(cache_root)
		_finish_failure()
		return
	var reloaded := ResourceLoader.load(_output_path, "", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	if reloaded == null:
		_fail("saved cache could not be reloaded")
		_cleanup_source(source)
		_cleanup(cache_root)
		_finish_failure()
		return
	var reloaded_instance := reloaded.instantiate()
	if reloaded_instance != null:
		# Global transforms used by the reload hash are only valid once the
		# instance is inside the scene tree.
		get_tree().root.add_child(reloaded_instance)
	var reloaded_summary := _geometry_summary([reloaded_instance]) if reloaded_instance != null else {}
	if reloaded_instance == null or int(reloaded_summary.get("geometry_count", -1)) != int(cached_summary.get("geometry_count", -2)) or String(reloaded_summary.get("gpu_hash_sha256", "")) != cached_hash:
		_fail("saved cache geometry verification failed")
		if reloaded_instance != null:
			reloaded_instance.free()
		_cleanup_source(source)
		_cleanup(cache_root)
		_finish_failure()
		return
	var manifest := _make_manifest(source, source_summary, cached_summary, module_records)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_manifest_path).get_base_dir())
	var manifest_file := FileAccess.open(_manifest_path, FileAccess.WRITE)
	if manifest_file == null:
		_fail("could not write cache manifest: %s" % _manifest_path)
		reloaded_instance.free()
		_cleanup_source(source)
		_cleanup(cache_root)
		_finish_failure()
		return
	manifest_file.store_string(JSON.stringify(manifest, "\t"))
	manifest_file.close()
	reloaded_instance.free()
	print("SAISIES RELEASE CACHE READY")
	print("saisies release cache: output=%s manifest=%s geometry=%d multimesh_instances=%d gpu_hash=%s" % [
		ProjectSettings.globalize_path(_output_path), ProjectSettings.globalize_path(_manifest_path),
		int(cached_summary.get("geometry_count", 0)), _multimesh_instance_total, cached_hash
	])
	_cleanup_source(source)
	_cleanup(cache_root)
	_finish_success()

func _resolve_source() -> Node:
	if not existing_source_path.is_empty():
		var existing := get_node_or_null(existing_source_path)
		if existing == null or not is_instance_valid(existing) or not existing.is_inside_tree():
			_fail("existing release source is not a live scene-tree node: %s" % existing_source_path)
			return null
		if existing.get_parent() != get_parent():
			_fail("existing release source must be a sibling of the native bake node: %s" % existing_source_path)
			return null
		if existing.find_child("ReleaseBase", true, false) == null or existing.find_child("ReleaseController", true, false) == null or existing.find_child("ReleaseForest", true, false) == null or existing.find_child("ReleaseRoadside", true, false) == null or existing.find_child("ReleaseTerminals", true, false) == null:
			_fail("existing source is not a complete release scene with terminals: %s" % existing_source_path)
			return null
		return existing
	var packed := load(_source_scene_path) as PackedScene
	if packed == null:
		_fail("source release scene could not be loaded: %s" % _source_scene_path)
		return null
	var source := packed.instantiate()
	if source == null:
		_fail("source release scene did not instantiate")
		return null
	get_tree().root.add_child(source)
	_owns_source_instance = true
	return source

func _cleanup_source(source: Node) -> void:
	if _owns_source_instance:
		_cleanup(source)

func _copy_terminal_contract_metadata(source: Node, cache_root: Node3D) -> void:
	# Keep the authored endpoint bounds and labels inspectable after the live
	# module has been flattened into the native cache.  Geometry hashing remains
	# independent of these review metadata fields.
	for key in [
		"station_end_m", "finish_station_m", "start_sign_station_m",
		"arrival_extension_start_m", "arrival_extension_end_m", "arrival_road_rows_m",
		"authored_terrace_bounds", "finish_arch_clear_width_m",
		"finish_arch_centerline_clear", "label_texts", "geometry_nodes", "ground_source"
	]:
		var source_key := "saisies_release_terminals_%s" % key
		if source.has_meta(source_key):
			cache_root.set_meta("saisies_release_cache_terminals_%s" % key, source.get_meta(source_key))

func _wait_for_readiness(source: Node) -> bool:
	var deadline := Time.get_ticks_usec() + int(_timeout_seconds * 1_000_000.0)
	var frame := 0
	var last_status := ""
	while Time.get_ticks_usec() < deadline:
		var pending := _pending_readiness(source)
		if pending.is_empty():
			print("saisies release cache bake: readiness complete frame=%d" % frame)
			return true
		var status := ",".join(pending)
		if status != last_status and (frame % 30 == 0 or last_status.is_empty()):
			print("saisies release cache bake: waiting [%s]" % status)
			last_status = status
		await get_tree().process_frame
		frame += 1
	_fail("readiness timeout after %.1fs: %s" % [_timeout_seconds, ",".join(_pending_readiness(source))])
	return false

func _pending_readiness(source: Node) -> Array[String]:
	var pending: Array[String] = []
	var base := source.find_child("ReleaseBase", true, false)
	var controller := source.find_child("ReleaseController", true, false)
	var forest := source.find_child("ReleaseForest", true, false)
	var roadside := source.find_child("ReleaseRoadside", true, false)
	var terminals := source.find_child("ReleaseTerminals", true, false)
	if base == null or not bool(base.get_meta("saisies_s04_batch_ready", false)):
		pending.append("ReleaseBase:saisies_s04_batch_ready")
	if controller == null or not bool(controller.get_meta("saisies_release_ready", false)):
		pending.append("ReleaseController:saisies_release_ready")
	if controller == null or not bool(controller.get_meta("saisies_release_modules_ready", false)):
		pending.append("ReleaseController:saisies_release_modules_ready")
	if forest == null or not bool(forest.get_meta("saisies_release_forest_ready", false)):
		pending.append("ReleaseForest:saisies_release_forest_ready")
	if roadside == null or not bool(roadside.get_meta("saisies_release_roadside_ready", false)):
		pending.append("ReleaseRoadside:saisies_release_roadside_ready")
	if terminals == null or not bool(terminals.get_meta("saisies_release_terminals_ready", false)):
		pending.append("ReleaseTerminals:saisies_release_terminals_ready")
	return pending

func _copy_geometry_nodes(source: Node, cache_root: Node3D, module_name: String) -> void:
	for child in source.get_children():
		_copy_geometry_node(child, cache_root, module_name)

func _copy_geometry_node(source: Node, cache_root: Node3D, module_name: String) -> void:
	if source is MeshInstance3D:
		var source_mesh := source as MeshInstance3D
		var copy := MeshInstance3D.new()
		_copy_serial += 1
		copy.name = "%sMesh%04d" % [module_name, _copy_serial]
		cache_root.add_child(copy)
		copy.owner = cache_root
		copy.mesh = source_mesh.mesh.duplicate(true) as Mesh if source_mesh.mesh != null else null
		_copy_geometry_properties(source_mesh, copy)
		copy.global_transform = source_mesh.global_transform
		_copy_metadata(source_mesh, copy, module_name)
		_mesh_node_count += 1
	elif source is MultiMeshInstance3D:
		var source_multi := source as MultiMeshInstance3D
		var copy_multi := MultiMeshInstance3D.new()
		_copy_serial += 1
		copy_multi.name = "%sMultiMesh%04d" % [module_name, _copy_serial]
		cache_root.add_child(copy_multi)
		copy_multi.owner = cache_root
		copy_multi.multimesh = source_multi.multimesh.duplicate(true) as MultiMesh if source_multi.multimesh != null else null
		_copy_geometry_properties(source_multi, copy_multi)
		copy_multi.global_transform = source_multi.global_transform
		_copy_metadata(source_multi, copy_multi, module_name)
		_multimesh_node_count += 1
		if source_multi.multimesh != null:
			_multimesh_instance_total += source_multi.multimesh.instance_count
	elif source is Label3D:
		var source_label := source as Label3D
		var copy_label := source_label.duplicate() as Label3D
		if copy_label == null:
			_fail("could not duplicate Label3D: %s" % source.get_path())
			return
		_copy_serial += 1
		copy_label.name = "%sLabel%04d" % [module_name, _copy_serial]
		cache_root.add_child(copy_label)
		copy_label.owner = cache_root
		_copy_geometry_properties(source_label, copy_label)
		copy_label.global_transform = source_label.global_transform
		_copy_metadata(source_label, copy_label, module_name)
		_label_node_count += 1
	for child in source.get_children():
		_copy_geometry_node(child, cache_root, module_name)

func _copy_geometry_properties(source: GeometryInstance3D, copy: GeometryInstance3D) -> void:
	for property_name in [
		"material_override", "material_overlay", "cast_shadow", "visibility_range_begin",
		"visibility_range_begin_margin", "visibility_range_end", "visibility_range_end_margin",
		"visibility_range_fade_mode", "extra_cull_margin", "gi_mode", "lod_bias",
		"ignore_occlusion_culling", "custom_aabb"
	]:
		if _has_property(source, property_name) and _has_property(copy, property_name):
			copy.set(property_name, source.get(property_name))
	# The cache flattens the generated module hierarchy. Preserve the effective
	# source visibility so bounded overlap hides (including S09) survive even
	# when their original ancestor node is not copied.
	copy.visible = _effective_geometry_visible(source)

func _copy_metadata(source: Node, copy: Node, module_name: String) -> void:
	copy.set_meta("saisies_release_cache_source_module", module_name)
	copy.set_meta("saisies_release_cache_source_path", String(source.get_path()))
	copy.set_meta("saisies_release_cache_original_visible", bool(source.visible))
	copy.set_meta("saisies_release_cache_original_visible_in_tree", _effective_geometry_visible(source))
	copy.set_meta("saisies_release_cache_geometry_visible", bool(copy.visible))

func _effective_geometry_visible(node: Node) -> bool:
	var cursor: Node = node
	while cursor != null:
		if cursor is Node3D and not (cursor as Node3D).visible:
			return false
		cursor = cursor.get_parent()
	return true

var _mesh_node_count := 0
var _multimesh_node_count := 0
var _label_node_count := 0
var _multimesh_instance_total := 0

func _geometry_summary(nodes: Array) -> Dictionary:
	var summary := {"mesh_node_count": 0, "multimesh_node_count": 0, "label_node_count": 0, "multimesh_instance_total": 0, "geometry_count": 0}
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	for node in nodes:
		if node != null:
			_hash_geometry(node, summary, hasher)
	summary["geometry_count"] = int(summary["mesh_node_count"]) + int(summary["multimesh_node_count"]) + int(summary["label_node_count"])
	summary["gpu_hash_sha256"] = hasher.finish().hex_encode()
	return summary

func _hash_geometry(node: Node, summary: Dictionary, hasher: HashingContext) -> void:
	if node is MeshInstance3D:
		var mesh_node := node as MeshInstance3D
		summary["mesh_node_count"] = int(summary["mesh_node_count"]) + 1
		_hash_string(hasher, "mesh")
		_hash_transform(hasher, mesh_node.global_transform)
		_hash_visibility(hasher, mesh_node)
		_hash_mesh(hasher, mesh_node.mesh)
	elif node is MultiMeshInstance3D:
		var multi_node := node as MultiMeshInstance3D
		summary["multimesh_node_count"] = int(summary["multimesh_node_count"]) + 1
		_hash_string(hasher, "multimesh")
		_hash_transform(hasher, multi_node.global_transform)
		_hash_visibility(hasher, multi_node)
		var multimesh := multi_node.multimesh
		if multimesh == null:
			_hash_string(hasher, "null")
		else:
			summary["multimesh_instance_total"] = int(summary["multimesh_instance_total"]) + multimesh.instance_count
			_hash_string(hasher, "instances=%d|visible=%d|format=%d" % [multimesh.instance_count, multimesh.visible_instance_count, multimesh.transform_format])
			_hash_mesh(hasher, multimesh.mesh)
			for index in range(multimesh.instance_count):
				if multimesh.transform_format == MultiMesh.TRANSFORM_3D:
					_hash_transform(hasher, multimesh.get_instance_transform(index))
				else:
					_hash_string(hasher, str(multimesh.get_instance_transform_2d(index)))
	elif node is Label3D:
		var label := node as Label3D
		summary["label_node_count"] = int(summary["label_node_count"]) + 1
		_hash_string(hasher, "label")
		_hash_transform(hasher, label.global_transform)
		_hash_visibility(hasher, label)
		_hash_label(hasher, label)
	for child in node.get_children():
		_hash_geometry(child, summary, hasher)

func _hash_label(hasher: HashingContext, label: Label3D) -> void:
	# These fields cover the authored S16/S18 sign text and its visible material
	# state while remaining stable across source/cache resource serialization.
	_hash_string(hasher, "text=%s|font_size=%d|pixel_size=%.9f|outline_size=%d|modulate=%s|outline_modulate=%s|billboard=%d" % [
		label.text,
		label.font_size,
		label.pixel_size,
		label.outline_size,
		str(label.modulate),
		str(label.outline_modulate),
		int(label.billboard),
	])

func _hash_visibility(hasher: HashingContext, node: GeometryInstance3D) -> void:
	# Keep visibility and range state in the source/cache fingerprint. The
	# effective visibility check accounts for the hierarchy that the cache
	# flattens, while the range fields preserve engine distance culling.
	_hash_string(hasher, "visible=%s|begin=%.9f|begin_margin=%.9f|end=%.9f|end_margin=%.9f|fade=%d" % [
		str(_effective_geometry_visible(node)),
		float(node.visibility_range_begin),
		float(node.visibility_range_begin_margin),
		float(node.visibility_range_end),
		float(node.visibility_range_end_margin),
		int(node.visibility_range_fade_mode),
	])

func _hash_mesh(hasher: HashingContext, mesh: Mesh) -> void:
	if mesh == null:
		_hash_string(hasher, "mesh=null")
		return
	_hash_string(hasher, "mesh_class=%s|surfaces=%d" % [mesh.get_class(), mesh.get_surface_count()])
	if mesh is ArrayMesh:
		var array_mesh := mesh as ArrayMesh
		for surface_index in range(array_mesh.get_surface_count()):
			var arrays := array_mesh.surface_get_arrays(surface_index)
			_hash_string(hasher, "surface=%d|array_count=%d" % [surface_index, arrays.size()])
			for array_index in range(arrays.size()):
				_hash_variant_array(hasher, array_index, arrays[array_index])
	else:
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

func _hash_vector3(hasher: HashingContext, value: Vector3) -> void:
	_hash_string(hasher, "%.9f,%.9f,%.9f" % [value.x, value.y, value.z])

func _hash_string(hasher: HashingContext, value: String) -> void:
	hasher.update(value.to_utf8_buffer())
	hasher.update("\n".to_utf8_buffer())

func _pose_snapshot(source: Node) -> Dictionary:
	var controller := source.find_child("ReleaseController", true, false)
	var camera := source.find_child("Camera3D", true, false) as Camera3D
	var pose := {
		"video_seconds": float(controller.get_meta("saisies_release_video_seconds", 0.0)) if controller != null else 0.0,
		"station_m": float(controller.get_meta("saisies_release_station_m", 0.0)) if controller != null else 0.0,
		"fov_deg": camera.fov if camera != null else 0.0,
		"camera_global_position": _vector3_array(camera.global_position) if camera != null else [0.0, 0.0, 0.0],
		"camera_global_rotation": _vector3_array(camera.global_rotation) if camera != null else [0.0, 0.0, 0.0],
	}
	return pose

func _vector3_array(value: Vector3) -> Array[float]:
	return [value.x, value.y, value.z]

func _make_manifest(source: Node, source_summary: Dictionary, cached_summary: Dictionary, module_records: Array[Dictionary]) -> Dictionary:
	var controller := source.find_child("ReleaseController", true, false)
	return {
		"schema_version": 1,
		"kind": "saisies_full_route_release_native_geometry_cache",
		"native_only": true,
		"source_scene": _source_scene_path,
		"source_scene_sha256": _sha256_file(_source_scene_path),
		"output_scene": _output_path,
		"manifest_path": _manifest_path,
		"source_modules": module_records,
		"source_summary": source_summary,
		"cached_summary": cached_summary,
		"gpu_hash_sha256": cached_summary.get("gpu_hash_sha256", ""),
		"pose": _pose_snapshot(source),
		"controller_ready": controller != null and bool(controller.get_meta("saisies_release_ready", false)),
		"modules_ready": controller != null and bool(controller.get_meta("saisies_release_modules_ready", false)),
		"visibility_policy": "source_effective_visibility_engine_visibility_range",
		"builders_removed_from_cache": true,
		"historical_pose_writers_in_source_disabled_before_capture": true,
		"verification": {
			"source_cache_geometry_count_equal": int(source_summary.get("geometry_count", -1)) == int(cached_summary.get("geometry_count", -2)),
			"source_cache_gpu_hash_equal": String(source_summary.get("gpu_hash_sha256", "")) == String(cached_summary.get("gpu_hash_sha256", "")),
			"saved_cache_reload_verified": true,
		},
	}

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

func _settle_native_frames() -> void:
	for _frame in range(4):
		await get_tree().process_frame
	RenderingServer.force_draw()
	for _frame in range(2):
		await get_tree().process_frame

func _unsafe_output_path() -> bool:
	var normalized := _output_path.simplify_path()
	if normalized == _source_scene_path or normalized == "res://scenes/MainScene_saisies_release.tscn":
		_fail("refusing to overwrite release source scene")
		return true
	if normalized == "res://export/saisies/SaisiesEnvironment_geo_r14.scn" or normalized == "res://scenes/MainScene_saisies_s04_batch_review.tscn":
		_fail("refusing to overwrite R14/R35 source artifact")
		return true
	return false

func _cleanup(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("Saisies release cache bake: " + message)

func _finish_failure() -> void:
	print("SAISIES RELEASE CACHE BAKE HOLD: %s" % "; ".join(_errors))
	get_tree().quit(1)

func _finish_success() -> void:
	get_tree().quit(0)
