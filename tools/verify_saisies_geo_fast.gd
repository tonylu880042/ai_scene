extends SceneTree

## Native reload verifier for the manually frozen geographic scene.  It checks
## packed geometry and MultiMesh instance transforms after a RenderingServer
## frame fence, while refusing headless/Dummy runs instead of pretending that a
## GPU buffer was exercised.
##
##   godot --path . --script tools/verify_saisies_geo_fast.gd -- \
##     --baked=res://export/saisies/SaisiesEnvironment_geo_r14.scn \
##     --manifest=res://export/saisies/SaisiesEnvironment_geo_r14.scn.manifest.json

const DEFAULT_BAKED := "res://export/saisies/SaisiesEnvironment_geo_fast.scn"
const BAKED_ROUTE_SCRIPT := "res://scripts/saisies_geo_baked_route.gd"
const GEO_CAMERA_SCRIPT := "res://scripts/saisies_geo_camera.gd"
const DATA_FILES := {
	"geo_route": "res://data/saisies_geo_route.json",
	"geo_buildings": "res://data/saisies_geo_buildings.json",
	"geo_forest": "res://data/saisies_geo_forest.json",
	"geo_nearfield": "res://data/saisies_geo_nearfield.json",
	"geo_camera_poses": "res://data/saisies_geo_camera_poses.json",
}
const COUNT_FIELDS := [
	"node_count", "mesh_node_count", "multimesh_node_count", "multimesh_instance_total",
	"geometry_instance_count", "collision_shape_count", "road_collision_node_count",
	"forest_multimesh_node_count", "multimesh_nonzero_transform_total",
]
const REQUIRED_VERIFICATION_FIELDS := [
	"source_packed_counts_equal", "source_packed_geometry_equal",
	"native_reload_counts_equal", "native_reload_geometry_equal",
	"generator_scripts_stripped",
]

var _baked_path := DEFAULT_BAKED
var _manifest_path := ""
var _speed_kmh := 30.0
var _speed_explicit := false
var _auto_advance := false
var _errors: Array[String] = []

func _initialize() -> void:
	_parse_arguments()
	if _manifest_path.is_empty():
		_manifest_path = "%s.manifest.json" % _baked_path
	if _is_unsafe_renderer():
		_refuse_unsafe_verify()
		return
	call_deferred("_run")

func _parse_arguments() -> void:
	for raw_arg in OS.get_cmdline_user_args():
		var arg := String(raw_arg)
		if arg.begins_with("--baked=") or arg.begins_with("--scene="):
			_baked_path = arg.substr(8)
		elif arg.begins_with("--manifest="):
			_manifest_path = arg.substr(11)
		elif arg.begins_with("--speed-kmh="):
			_speed_kmh = float(arg.substr(12))
			_speed_explicit = true
		elif arg == "--auto-advance=true":
			_auto_advance = true
		elif arg == "--auto-advance=false":
			_auto_advance = false

func _is_unsafe_renderer() -> bool:
	var display_name := DisplayServer.get_name().to_lower()
	return OS.has_feature("headless") or display_name.contains("headless") or display_name.contains("dummy")

func _refuse_unsafe_verify() -> void:
	var display_name := DisplayServer.get_name()
	push_error("Saisies geo fast verify refused: renderer '%s' is headless/Dummy; native RenderingServer/MultiMesh verification is required." % display_name)
	print("Run this verifier with a native window (without --headless): %s" % _baked_path)
	quit(1)

func _run() -> void:
	var manifest := _read_json(_manifest_path)
	if manifest.is_empty():
		_finish_failure()
		return
	if int(manifest.get("schema_version", 0)) != 1 or String(manifest.get("kind", "")) != "saisies_geo_manual_fast_bake":
		_fail("manifest schema/kind is not a Saisies geo manual fast bake")
	if manifest.get("native_only", false) != true:
		_fail("manifest is not marked native_only")
	_verify_manifest_verification(manifest)
	_validate_input_hashes(manifest)
	# Do not load a stale/failed 45 MB artifact merely to repeat metadata
	# failures.  Native reload work starts only after the manifest proves that
	# the bake completed both equality checks.
	if not _errors.is_empty():
		print("SAISIES GEO FAST VERIFY HOLD: %s" % "; ".join(_errors))
		_finish_failure()
		return
	var expected_speed := float(manifest.get("camera_speed_kmh", 30.0))
	if _speed_explicit:
		expected_speed = _speed_kmh
	if not is_finite(expected_speed) or expected_speed <= 0.0:
		_fail("manifest camera speed is not finite and positive")
	if not FileAccess.file_exists(_baked_path):
		_fail("baked scene is missing: %s" % _baked_path)
		_finish_failure()
		return
	var expected_baked_sha := String(manifest.get("baked_sha256", ""))
	if not expected_baked_sha.is_empty() and _sha256_file(_baked_path) != expected_baked_sha:
		_fail("baked scene SHA256 does not match the manifest; rerun the manual native bake")
	var packed := ResourceLoader.load(_baked_path, "", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	if packed == null:
		_fail("baked scene could not be loaded: %s" % _baked_path)
		_finish_failure()
		return
	var holder := Node3D.new()
	holder.name = "SaisiesGeoFastVerify"
	get_root().add_child(holder)
	var instance := packed.instantiate()
	if instance == null:
		_fail("baked scene did not instantiate")
		holder.queue_free()
		_finish_failure()
		return
	var camera_before_ready := instance.find_child("CameraRig", true, false) as Node
	if camera_before_ready != null and _has_property(camera_before_ready, "auto_advance"):
		camera_before_ready.set("auto_advance", _auto_advance)
	holder.add_child(instance)
	await process_frame
	await process_frame
	await _settle_native_frames()
	var summary := _scene_summary(instance)
	_verify_baked_tree(instance, manifest, expected_speed)
	_verify_summary(summary, manifest)
	_verify_camera(instance, expected_speed)
	if _errors.is_empty():
		print("saisies geo fast verify: native RenderingServer frame fence passed; MultiMesh transforms=%d" % int(summary.get("multimesh_instance_total", 0)))
		print("saisies geo fast verify: baked=%s geometry_sha256=%s" % [_baked_path, String(summary.get("geometry_sha256", "")).substr(0, 16)])
		print("SAISIES GEO FAST VERIFY PASS")
	else:
		print("SAISIES GEO FAST VERIFY HOLD: %s" % "; ".join(_errors))
	holder.queue_free()
	_finish_success() if _errors.is_empty() else _finish_failure()

func _validate_input_hashes(manifest: Dictionary) -> void:
	var source_path := String(manifest.get("source_scene", ""))
	if source_path.is_empty() or not FileAccess.file_exists(source_path):
		_fail("manifest source scene is missing: %s" % source_path)
	else:
		var expected_source_sha := String(manifest.get("source_scene_sha256", ""))
		if expected_source_sha.is_empty() or _sha256_file(source_path) != expected_source_sha:
			_fail("source scene SHA256 does not match the manual bake manifest")
	var manifest_data: Dictionary = manifest.get("data_sha256", {})
	for key in DATA_FILES.keys():
		var expected := String(manifest_data.get(key, ""))
		var actual := _sha256_file(String(DATA_FILES[key]))
		if expected.is_empty() or actual != expected:
			_fail("data SHA256 mismatch for %s" % key)

func _verify_baked_tree(instance: Node, manifest: Dictionary, expected_speed: float) -> void:
	var route := instance.find_child("Route", true, false) as Node
	if route == null:
		_fail("baked scene is missing Route")
		return
	if not route is SaisiesRoute:
		_fail("baked Route is not a SaisiesRoute subclass")
	var route_script := route.get_script() as Script
	if route_script == null or route_script.resource_path != BAKED_ROUTE_SCRIPT:
		_fail("baked Route script is not %s" % BAKED_ROUTE_SCRIPT)
	if not route.has_method("route_ready") or not bool(route.call("route_ready")):
		_fail("baked Route route_ready() is false")
	if not bool(route.get_meta("saisies_geo_baked_route_ready", false)):
		_fail("baked Route did not publish its ready metadata")
	if String(route.get_meta("saisies_geo_baked_route_build_mode", "")) != "samples+curve_only":
		_fail("baked Route build mode is not samples+curve_only")
	if not bool(route.get_meta("saisies_geo_baked_route_bound_existing_children", false)):
		_fail("baked Route did not bind existing road/collision children")
	if _find_named(route, "SaisiesAsphalt") == null or _find_named(route, "SaisiesGeoGravelShoulders") == null:
		_fail("baked Route is missing a retained road/gravel seam mesh")
	var landscape := instance.find_child("Landscape", true, false) as Node
	var geo_terrain := _find_named(landscape, "SaisiesGeoTerrain") as MeshInstance3D
	if geo_terrain == null or geo_terrain.mesh == null:
		_fail("baked Landscape is missing the retained SaisiesGeoTerrain mesh")
	var collision := _find_named(route, "SaisiesRoadCollision") as StaticBody3D
	if collision == null or _find_named(collision, "ContinuousRoadSurface") == null:
		_fail("baked Route is missing SaisiesRoadCollision/ContinuousRoadSurface")
	var forest := instance.find_child("Forest", true, false) as Node
	if forest == null:
		_fail("baked scene is missing Forest")
	var forest_multimesh_count := 0
	var forest_instance_total := 0
	for descendant in forest.find_children("*", "MultiMeshInstance3D", true, false):
		forest_multimesh_count += 1
		var multi_node := descendant as MultiMeshInstance3D
		if multi_node != null and multi_node.multimesh != null:
			forest_instance_total += multi_node.multimesh.instance_count
	if forest_multimesh_count <= 0 or forest_instance_total <= 0:
		_fail("baked Forest has no retained MultiMesh instances")
	var camera := instance.find_child("CameraRig", true, false) as Node
	if camera == null:
		_fail("baked scene is missing CameraRig")
	else:
		var camera_script := camera.get_script() as Script
		if camera_script == null or camera_script.resource_path != GEO_CAMERA_SCRIPT:
			_fail("CameraRig must retain SaisiesGeoCamera")
		if _has_property(camera, "cruise_speed_mps") and absf(float(camera.get("cruise_speed_mps")) - expected_speed / 3.6) > 0.01:
			_fail("CameraRig cruise speed does not match %.3f km/h" % expected_speed)
	_verify_no_generator_scripts(instance)

func _verify_no_generator_scripts(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back() as Node
		if node != root and not node.get_scene_file_path().is_empty():
			_fail("nested PackedScene instance remains on %s: %s" % [String(root.get_path_to(node)), node.get_scene_file_path()])
		var script: Script = node.get_script() as Script
		if script != null:
			var path: String = script.resource_path
			var allowed: bool = path == BAKED_ROUTE_SCRIPT or (node.name == "CameraRig" and path == GEO_CAMERA_SCRIPT)
			if not allowed:
				_fail("generator or unexpected script remains on %s: %s" % [String(root.get_path_to(node)), path])
		for child in node.get_children():
			stack.append(child)

func _verify_summary(actual: Dictionary, manifest: Dictionary) -> void:
	var expected_source: Dictionary = manifest.get("source_summary", {})
	var expected_baked: Dictionary = manifest.get("baked_summary", {})
	if expected_source.is_empty():
		_fail("manifest has no source_summary")
	if expected_baked.is_empty():
		_fail("manifest has no baked_summary")
	for field in COUNT_FIELDS:
		if int(actual.get(field, -1)) != int(expected_source.get(field, -2)):
			_fail("source/baked count mismatch for %s: actual=%s source=%s" % [field, actual.get(field), expected_source.get(field)])
	if String(actual.get("geometry_sha256", "")) != String(expected_source.get("geometry_sha256", "")):
		_fail("source/baked geometry fingerprint mismatch; resource paths are intentionally excluded")
	for field in COUNT_FIELDS:
		if int(actual.get(field, -1)) != int(expected_baked.get(field, -2)):
			_fail("packed summary count mismatch for %s: actual=%s baked=%s" % [field, actual.get(field), expected_baked.get(field)])
	if String(actual.get("geometry_sha256", "")) != String(expected_baked.get("geometry_sha256", "")):
		_fail("packed summary geometry fingerprint mismatch")
	for field in COUNT_FIELDS:
		if int(expected_source.get(field, -2)) != int(expected_baked.get(field, -2)):
			_fail("manifest source/baked count mismatch for %s" % field)
	if String(expected_source.get("geometry_sha256", "")) != String(expected_baked.get("geometry_sha256", "")):
		_fail("manifest source/baked geometry fingerprint mismatch")
	if int(actual.get("road_collision_node_count", 0)) <= 0:
		_fail("summary has no road collision node")
	if int(actual.get("forest_multimesh_node_count", 0)) <= 0 or int(actual.get("multimesh_instance_total", 0)) <= 0:
		_fail("summary has no retained full-line MultiMesh population")
	if int(actual.get("multimesh_nonzero_transform_total", 0)) <= 0:
		_fail("native MultiMesh transform readback has no non-zero instances")

func _verify_manifest_verification(manifest: Dictionary) -> void:
	var verification: Dictionary = manifest.get("verification", {})
	if verification.is_empty():
		_fail("manifest is missing the completed verification record")
		return
	for field in REQUIRED_VERIFICATION_FIELDS:
		if verification.get(field, false) != true:
			_fail("manifest verification field is missing or false: %s" % field)

func _verify_camera(instance: Node, expected_speed: float) -> void:
	var route := instance.find_child("Route", true, false) as Node
	var camera := instance.find_child("CameraRig", true, false) as Node
	if route == null or camera == null:
		return
	if not camera.has_method("reset_to_distance"):
		_fail("CameraRig lacks reset_to_distance")
		return
	if _has_property(camera, "auto_advance"):
		camera.set("auto_advance", false)
	var length_m := float(route.get("length_m"))
	for station in [0.0, length_m * 0.37, length_m]:
		camera.call("reset_to_distance", station)
		var actual_station := float(camera.get("distance_m"))
		if absf(actual_station - clampf(station, 0.0, length_m)) > 0.01:
			_fail("CameraRig reset station %.3f did not hold (%.3f)" % [station, actual_station])
	if _has_property(camera, "cruise_speed_mps"):
		camera.set("cruise_speed_mps", expected_speed / 3.6)
	if _has_property(camera, "auto_advance"):
		camera.set("auto_advance", true)
		camera.call("reset_to_distance", 0.0)
		camera.call("_process", maxf(length_m / maxf(expected_speed / 3.6, 0.001) + 1.0, 1.0))
		if float(camera.get("distance_m")) < length_m - 0.01:
			_fail("CameraRig 30km/h traversal did not reach route end")
		camera.set("auto_advance", _auto_advance)
		camera.call("reset_to_distance", 0.0)

func _find_named(root: Node, node_name: String) -> Node:
	if root == null:
		return null
	if root.name == node_name:
		return root
	for child in root.get_children():
		var found := _find_named(child, node_name)
		if found != null:
			return found
	return null

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
		_hash_string(hasher, "mesh|%s" % relative_path)
		_hash_mesh(hasher, (node as MeshInstance3D).mesh)
	if node is MultiMeshInstance3D:
		summary["multimesh_node_count"] = int(summary["multimesh_node_count"]) + 1
		if is_forest:
			summary["forest_multimesh_node_count"] = int(summary["forest_multimesh_node_count"]) + 1
		var multimesh := (node as MultiMeshInstance3D).multimesh
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

func _read_json(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		_fail("manifest is missing: %s" % path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		_fail("manifest is not a JSON object: %s" % path)
		return {}
	return parsed

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

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("Saisies geo fast verify: " + message)

func _finish_success() -> void:
	quit(0)

func _finish_failure() -> void:
	quit(1)
