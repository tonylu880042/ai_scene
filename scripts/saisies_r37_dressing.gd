class_name SaisiesR37Dressing
extends Node3D

## Source-backed nearfield dressing for the three R37 representative route cuts.
##
## The representative route fitter owns the road and terrain deformation.  This
## module is intentionally a small, explicit overlay: it adds the observed
## chalet silhouettes and broadleaf layers after the corrected route is live,
## samples every root from the visible terrain triangle API, and leaves the
## inherited R36 forest, walls, guardrails, and terminal scenes untouched.

const TREE_FACTORY := preload("res://scripts/saisies_trees.gd")
const CHALET_FACTORY := preload("res://scripts/saisies_roadside_chalets.gd")
const GROUND_AUDIT := preload("res://scripts/saisies_release_roadside_ground.gd")

@export_file("*.json") var candidate_path := "res://data/saisies_r37_dressing.json"
@export var build_on_ready := false
@export var visibility_range_m := 1200.0
@export var chunk_size_m := 256.0

const MIN_TREE_SPACING_M := 4.5
const TREE_ROUTE_CLEARANCE_M := 2.0
const STRUCTURE_ROUTE_CLEARANCE_M := 12.0
const BUILDING_CLEARANCE_M := 5.0
const ROCK_WALL_CLEARANCE_M := 4.0
const MAX_TREE_ATTEMPTS_MULTIPLIER := 18

var _world: Node3D
var _route: Node
var _terrain_sampler: Object
var _terrain_sampler_mode := ""
var _candidate: Dictionary = {}
var _container: Node3D
var _generated: Node3D
var _tree_meshes: Dictionary = {}
var _tree_items: Array = []
var _tree_points: Array = []
var _obstacle_bounds: Array = []
var _cluster_reports: Array = []
var _structure_records: Array = []
var _contact_records: Array = []
var _hidden_replaced_meshes: Array = []
var _reject_counts := {
	"ground": 0,
	"route": 0,
	"spacing": 0,
	"gap": 0,
	"obstacle": 0,
	"open_window": 0,
	"asset": 0,
}
var _built_candidate := ""

func _ready() -> void:
	if build_on_ready:
		push_warning("SaisiesR37Dressing requires an explicit build_for_representative call")


## Build one source-estimated representative after the representative route has
## applied its fit.  The returned dictionary is also published on this node as
## metadata so the native harness can inspect the same contact evidence.
func build_for_representative(world: Node, route: Node, candidate_id: String, options: Dictionary = {}) -> Dictionary:
	_restore_hidden_replaced_meshes()
	if not (world is Node3D) or route == null:
		return _failure("world must be Node3D and route must be supplied")
	_world = world as Node3D
	_route = route
	if not _route.has_method("pos_at") or not _route.has_method("left_at"):
		return _failure("route requires pos_at and left_at")
	if not _load_candidate(candidate_id):
		return _failure("candidate data is invalid for %s" % candidate_id)
	_terrain_sampler = _resolve_terrain_sampler(_world)
	if _terrain_sampler == null:
		return _failure("visible terrain triangle sampler is required")
	_container = options.get("container", self) as Node3D
	if _container == null:
		_container = self
	_clear_generated()
	_tree_items.clear()
	_tree_points.clear()
	_obstacle_bounds.clear()
	_cluster_reports.clear()
	_structure_records.clear()
	_contact_records.clear()
	for key in _reject_counts.keys():
		_reject_counts[key] = 0
	if not _load_tree_meshes():
		return _failure("broadleaf mesh factory returned no usable meshes")
	_hide_replaced_r37_geometry(candidate_id)
	_collect_existing_tree_points()
	_collect_obstacle_bounds()
	_generated = Node3D.new()
	_generated.name = "SaisiesR37Dressing_%s" % candidate_id.to_upper()
	_generated.set_meta("saisies_r37_dressing_candidate", candidate_id.to_upper())
	_generated.set_meta("saisies_r37_dressing_source_estimated", true)
	_generated.set_meta("saisies_r37_dressing_preserves_inherited_nodes", true)
	_generated.set_meta("saisies_r37_dressing_no_opaque_ground_plane", true)
	_generated.set_meta("saisies_r37_dressing_hidden_replaced_mesh_count", _hidden_replaced_meshes.size())
	_container.add_child(_generated)
	_build_structures(_candidate.get("structures", []))
	_build_trees(_candidate.get("tree_clusters", []))
	_build_tree_multimeshes()
	_built_candidate = candidate_id.to_upper()
	return _publish_ready()


func _load_candidate(candidate_id: String) -> bool:
	_candidate.clear()
	if not FileAccess.file_exists(candidate_path):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(candidate_path))
	if not (parsed is Dictionary):
		return false
	var root := parsed as Dictionary
	if not bool(root.get("source_estimated", false)):
		return false
	if bool(root.get("gps_calibrated", true)) or bool(root.get("formal_route_edit", true)):
		return false
	if String(root.get("status", "")) != "root_selected_for_integrated_review":
		return false
	if String(root.get("visual_acceptance", "")) != "pending":
		return false
	var segments: Variant = root.get("segments", [])
	if not (segments is Array):
		return false
	for raw_segment in segments as Array:
		if not (raw_segment is Dictionary):
			continue
		var segment := raw_segment as Dictionary
		if String(segment.get("id", "")).to_upper() != candidate_id.to_upper():
			continue
		var scope: Dictionary = root.get("scope", {}) as Dictionary
		var scope_windows: Dictionary = scope.get("station_windows_m", {}) as Dictionary
		var declared_window: Variant = scope_windows.get(candidate_id.to_upper(), [])
		var source_window: Variant = segment.get("source_station_window_m", [])
		if source_window is Array and (source_window as Array).size() == 2:
			declared_window = source_window
		if not (declared_window is Array) or (declared_window as Array).size() != 2:
			return false
		_candidate = segment.duplicate(true)
		_candidate["broadleaf_crown_profile"] = root.get("asset_contract", {}).get("broadleaf_crown_profile", "legacy")
		_candidate["scope_station_window_m"] = declared_window
		_candidate["root_source_estimated"] = true
		return true
	return false


func _resolve_terrain_sampler(world: Node3D) -> Object:
	if world.has_method("sample_mesh_triangle"):
		_terrain_sampler_mode = "direct_indexed_sampler"
		return world
	for child in world.find_children("*", "", true, false):
		if child is Node and (child as Node).has_method("sample_mesh_triangle"):
			_terrain_sampler_mode = "direct_indexed_sampler"
			return child as Node
	var terrain_node := _resolve_visible_terrain_node(world)
	if terrain_node == null:
		return null
	var helper := GROUND_AUDIT.new() as RefCounted
	if helper == null or not helper.has_method("configure") or not helper.has_method("sample_mesh_triangle"):
		return null
	helper.call("configure", _route, terrain_node)
	var warm_points := _terrain_warm_points()
	if warm_points.is_empty():
		return null
	# The R36 helper indexes the visible SaisiesGeoTerrain/shoulder triangles
	# when Landscape is a plain Node3D.  Warm the exact candidate corridor before
	# any tree or chalet query; analytic/DEM heights are never used here.
	helper.call("_prepare_visible_mesh_cache", warm_points)
	var cached_triangles: Variant = helper.get("_visible_triangles")
	if not (cached_triangles is Array) or (cached_triangles as Array).is_empty():
		return null
	_terrain_sampler_mode = "spatial_visible_triangle_cache"
	return helper


func _resolve_visible_terrain_node(world: Node3D) -> Node:
	var landscape := world.find_child("Landscape", true, false)
	if landscape != null:
		return landscape
	var terrain := world.find_child("SaisiesGeoTerrain", true, false)
	if terrain != null:
		return terrain
	for child in world.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance != null and String(mesh_instance.name).contains("SaisiesGeoTerrain"):
			return mesh_instance
	return null


func _terrain_warm_points() -> Array[Vector3]:
	var points: Array[Vector3] = []
	var structures: Variant = _candidate.get("structures", [])
	if structures is Array:
		for raw_structure in structures as Array:
			if raw_structure is Dictionary:
				var structure := raw_structure as Dictionary
				points.append(_route_point(float(structure.get("station_m", 0.0)), float(structure.get("lateral_m", 0.0))))
	var clusters: Variant = _candidate.get("tree_clusters", [])
	if clusters is Array:
		for raw_cluster in clusters as Array:
			if not (raw_cluster is Dictionary):
				continue
			var cluster := raw_cluster as Dictionary
			var station_range: Array = cluster.get("station_m", []) as Array
			var offset_range: Array = cluster.get("offset_m", []) as Array
			if station_range.size() != 2 or offset_range.size() != 2:
				continue
			var station_span := absf(float(station_range[1]) - float(station_range[0]))
			var offset_span := absf(float(offset_range[1]) - float(offset_range[0]))
			var station_steps := maxi(int(ceil(station_span / 18.0)), 1)
			var offset_steps := maxi(int(ceil(offset_span / 12.0)), 1)
			for station_index in range(station_steps + 1):
				var station_t := float(station_index) / float(station_steps)
				var station := lerpf(float(station_range[0]), float(station_range[1]), station_t)
				for offset_index in range(offset_steps + 1):
					var offset_t := float(offset_index) / float(offset_steps)
					var offset := lerpf(float(offset_range[0]), float(offset_range[1]), offset_t)
					points.append(_route_point(station, float(cluster.get("side_route_left_sign", 1.0)) * offset))
	return points


func _load_tree_meshes() -> bool:
	_tree_meshes.clear()
	var variants: Array = TREE_FACTORY.broadleaf_variants(_candidate.get("broadleaf_crown_profile", "legacy") == "rounded")
	for index in variants.size():
		var mesh := variants[index] as Mesh
		if mesh != null:
			_tree_meshes[index] = mesh
	return not _tree_meshes.is_empty()


func _clear_generated() -> void:
	if is_instance_valid(_generated):
		_generated.free()
	_generated = null


func _restore_hidden_replaced_meshes() -> void:
	for raw_entry in _hidden_replaced_meshes:
		if not (raw_entry is Dictionary):
			continue
		var entry := raw_entry as Dictionary
		var mesh_instance := entry.get("node") as MeshInstance3D
		if mesh_instance == null or not is_instance_valid(mesh_instance):
			continue
		mesh_instance.visible = bool(entry.get("visible", true))
		if bool(entry.get("had_r37_meta", false)):
			mesh_instance.set_meta("saisies_r37_dressing_hidden_replaced_mesh", entry.get("old_r37_meta", false))
		elif mesh_instance.has_meta("saisies_r37_dressing_hidden_replaced_mesh"):
			mesh_instance.remove_meta("saisies_r37_dressing_hidden_replaced_mesh")
	_hidden_replaced_meshes.clear()


func _hide_replaced_r37_geometry(candidate_id: String) -> void:
	if _world == null or candidate_id.to_upper() != "S06":
		return
	const replaced_source_token := "SaisiesUpperFarm_S06_main_chalet"
	# The representative world is separate from the frozen R36 geometry cache.
	# Search that sibling cache as well, but keep the exact authored source token
	# so unrelated S06 buildings and inherited geometry remain visible.
	var roots: Array[Node] = [_world]
	var cursor: Node = _container
	while cursor != null:
		var cache := cursor.find_child("ReleaseGeometryCache", true, false)
		if cache != null and not roots.has(cache):
			roots.append(cache)
		cursor = cursor.get_parent()
	for root in roots:
		for raw_node in root.find_children("*", "MeshInstance3D", true, false):
			var mesh_instance := raw_node as MeshInstance3D
			if mesh_instance == null or mesh_instance.mesh == null:
				continue
			var source_path := ""
			for meta_key in ["saisies_release_cache_source_path", "source_path", "saisies_source_path"]:
				if mesh_instance.has_meta(meta_key):
					source_path = String(mesh_instance.get_meta(meta_key))
					if source_path.contains(replaced_source_token):
						break
			# Native-baked copies carry the source path metadata.  The ancestor
			# fallback keeps the exact S06 source node addressable in a live scene
			# before baking, without hiding other S06 houses or R36 geometry.
			var ancestor: Node = mesh_instance
			var ancestor_path := ""
			while ancestor != null:
				ancestor_path += "/" + String(ancestor.name)
				if String(ancestor.name) == replaced_source_token:
					source_path = "%s%s" % [source_path, ancestor_path]
					break
				ancestor = ancestor.get_parent()
			if not source_path.contains(replaced_source_token):
				continue
			_hidden_replaced_meshes.append({
				"node": mesh_instance,
				"path": String(mesh_instance.get_path()),
				"source_path": source_path,
				"visible": mesh_instance.visible,
				"had_r37_meta": mesh_instance.has_meta("saisies_r37_dressing_hidden_replaced_mesh"),
				"old_r37_meta": mesh_instance.get_meta("saisies_r37_dressing_hidden_replaced_mesh", false),
			})
			mesh_instance.visible = false
			mesh_instance.set_meta("saisies_r37_dressing_hidden_replaced_mesh", true)


func _collect_existing_tree_points() -> void:
	if _world == null:
		return
	for raw_node in _world.find_children("*", "MultiMeshInstance3D", true, false):
		var instance := raw_node as MultiMeshInstance3D
		if instance == null or instance.multimesh == null:
			continue
		var node_name := String(instance.name).to_lower()
		var tree_like := node_name.contains("tree") or node_name.contains("forest") or instance.has_meta("forest_species")
		if not tree_like:
			continue
		var authored: Variant = null
		for meta_key in ["saisies_release_forest_authored_positions", "forest_authored_positions"]:
			if instance.has_meta(meta_key):
				authored = instance.get_meta(meta_key)
				break
		if authored is PackedVector3Array and not (authored as PackedVector3Array).is_empty():
			for point in authored as PackedVector3Array:
				if point.is_finite():
					_tree_points.append(Vector2(point.x, point.z))
			continue
		for index in instance.multimesh.instance_count:
			var point := instance.global_transform * instance.multimesh.get_instance_transform(index).origin
			if point.is_finite():
				_tree_points.append(Vector2(point.x, point.z))


func _collect_obstacle_bounds() -> void:
	if _world == null:
		return
	for raw_node in _world.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := raw_node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		if bool(mesh_instance.get_meta("saisies_r37_dressing_hidden_replaced_mesh", false)):
			# A deliberately replaced R36 source is hidden for this candidate and
			# must not reject the authored replacement chalet as an obstacle.
			continue
		var name := String(mesh_instance.name).to_lower()
		var parent_name := String(mesh_instance.get_parent().name).to_lower() if mesh_instance.get_parent() != null else ""
		var owned_feature := name.contains("rock") or name.contains("wall") or name.contains("guard") or name.contains("rail") or name.contains("parapet") or name.contains("retaining") or name.contains("cut") or name.contains("chalet") or name.contains("house") or name.contains("building") or name.contains("lodge")
		owned_feature = owned_feature or parent_name.contains("rock") or parent_name.contains("wall") or parent_name.contains("guard") or parent_name.contains("parapet") or parent_name.contains("farm") or parent_name.contains("chalet") or parent_name.contains("house") or parent_name.contains("building")
		if not owned_feature:
			continue
		_obstacle_bounds.append(_world_aabb(mesh_instance))


func _world_aabb(instance: MeshInstance3D) -> AABB:
	var local := instance.get_aabb()
	var corners := [
		local.position,
		local.position + Vector3(local.size.x, 0.0, 0.0),
		local.position + Vector3(0.0, local.size.y, 0.0),
		local.position + Vector3(0.0, 0.0, local.size.z),
		local.end,
		local.position + Vector3(local.size.x, local.size.y, 0.0),
		local.position + Vector3(local.size.x, 0.0, local.size.z),
		local.position + Vector3(0.0, local.size.y, local.size.z),
	]
	var first: Vector3 = instance.global_transform * corners[0]
	var result := AABB(first, Vector3.ZERO)
	for corner in corners:
		result = result.expand(instance.global_transform * corner)
	return result


func _build_structures(structures: Variant) -> void:
	if not (structures is Array):
		return
	for raw_structure in structures as Array:
		if not (raw_structure is Dictionary):
			continue
		var definition := raw_structure as Dictionary
		var station := float(definition.get("station_m", NAN))
		var lateral := float(definition.get("lateral_m", NAN))
		if not is_finite(station) or not is_finite(lateral):
			_continue_structure(definition, "invalid_station_or_lateral")
			continue
		var route_point := _route_point(station, lateral)
		var ground := _sample_ground(Vector2(route_point.x, route_point.z))
		if ground.is_empty():
			_continue_structure(definition, "ground_sample_missing")
			continue
		if not _route_clearance_ok(station, lateral, STRUCTURE_ROUTE_CLEARANCE_M):
			_continue_structure(definition, "road_clearance")
			continue
		if not _obstacle_clear(Vector2(route_point.x, route_point.z), BUILDING_CLEARANCE_M):
			_continue_structure(definition, "owned_roadside_clearance")
			continue
		var chalet := CHALET_FACTORY.new() as Node3D
		if chalet == null:
			_continue_structure(definition, "chalet_factory_missing")
			continue
		if chalet.get("build_on_ready") != null:
			chalet.set("build_on_ready", true)
		_generated.add_child(chalet)
		if chalet.has_method("_build"):
			chalet.call("_build")
		var heading := _structure_heading(definition, station, ground["position"])
		var yaw_offset := deg_to_rad(float(definition.get("yaw_offset_deg", 0.0)))
		var final_heading := heading + yaw_offset
		chalet.name = "R37_%s" % String(definition.get("id", "Chalet"))
		chalet.global_position = ground["position"]
		chalet.global_rotation = Vector3(0.0, final_heading, 0.0)
		var scale := clampf(float(definition.get("scale", 1.0)), 0.25, 1.5)
		chalet.scale = Vector3.ONE * scale
		var fitter: Object = _terrain_sampler
		if not fitter.has_method("fit_mesh_bottom_to_sampler"):
			fitter = GROUND_AUDIT.new()
			fitter.call("configure", _route, _terrain_sampler)
		var foundations: Dictionary = chalet.call("fit_foundations", Callable(self, "_sample_ground"), Callable(fitter, "fit_mesh_bottom_to_sampler"))
		if not bool(foundations.get("passed", false)):
			_continue_structure(definition, String(foundations.get("reason", "foundation_fit_failed")))
			chalet.free()
			continue
		var record := _contact_record(definition, ground, station, lateral)
		record["foundation_fit"] = foundations
		record["kind"] = String(definition.get("kind", "structure"))
		record["node_path"] = String(chalet.get_path())
		record["scale"] = scale
		record["heading_deg"] = rad_to_deg(final_heading)
		record["front_heading_deg"] = rad_to_deg(final_heading)
		record["front_facing_camera_dot"] = _structure_camera_facing_dot(definition, final_heading, ground["position"])
		record["contact_policy"] = String(definition.get("contact_policy", "visible_triangle_root"))
		record["support_policy"] = String(definition.get("support_policy", "visible_triangle_root_with_stone_plinth"))
		record["expected_apparent_width_px"] = int(definition.get("expected_apparent_width_px", 0))
		record["evidence_role"] = String(definition.get("evidence_role", ""))
		record["source_side"] = String(definition.get("side", ""))
		record["clearance_contract_m"] = BUILDING_CLEARANCE_M
		record["road_clearance_m"] = _route_edge_clearance_m(station, lateral)
		record["road_clearance_passed"] = true
		record["asphalt_overlap"] = false
		chalet.set_meta("saisies_r37_dressing_visible_ground_support", ground)
		chalet.set_meta("saisies_r37_dressing_front_heading_deg", rad_to_deg(final_heading))
		chalet.set_meta("saisies_r37_dressing_front_facing_camera_dot", record["front_facing_camera_dot"])
		chalet.set_meta("saisies_r37_dressing_record", record)
		chalet.set_meta("saisies_r37_dressing_source_estimated", true)
		_structure_records.append(record)
		_contact_records.append(record)


func _continue_structure(definition: Dictionary, reason: String) -> void:
	_reject_counts["obstacle"] = int(_reject_counts["obstacle"]) + 1
	_structure_records.append({
		"id": String(definition.get("id", "structure")),
		"accepted": false,
		"reason": reason,
		"source_estimated": true,
	})


func _structure_heading(definition: Dictionary, station: float, root: Vector3) -> float:
	if not bool(definition.get("face_camera", false)):
		return _heading_y(station)
	var anchor: Variant = _candidate.get("camera_anchor", {})
	if not (anchor is Dictionary):
		return _heading_y(station)
	var camera_anchor := anchor as Dictionary
	var camera_station := float(camera_anchor.get("station_m", station))
	var camera_lateral := float(camera_anchor.get("lateral_m", 0.0))
	var camera_position := _route_point(camera_station, camera_lateral)
	var to_camera := camera_position - root
	to_camera.y = 0.0
	if to_camera.length_squared() < 0.000001:
		return _heading_y(station)
	# The chalet facade is authored on local -Z.  This yaw makes that facade
	# face the baseline camera ground position, rather than the probe heading
	# convention used by the route diagnostics.
	return atan2(-to_camera.x, -to_camera.z)


func _structure_camera_facing_dot(definition: Dictionary, yaw: float, root: Vector3) -> float:
	if not bool(definition.get("face_camera", false)):
		return 0.0
	var anchor: Variant = _candidate.get("camera_anchor", {})
	if not (anchor is Dictionary):
		return 0.0
	var camera_anchor := anchor as Dictionary
	var camera_position := _route_point(float(camera_anchor.get("station_m", 0.0)), float(camera_anchor.get("lateral_m", 0.0)))
	var to_camera := camera_position - root
	to_camera.y = 0.0
	if to_camera.length_squared() < 0.000001:
		return 0.0
	var facade_forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	return facade_forward.dot(to_camera.normalized())


func _build_trees(clusters: Variant) -> void:
	if not (clusters is Array):
		return
	for cluster_index in clusters.size():
		var raw_cluster: Variant = (clusters as Array)[cluster_index]
		if not (raw_cluster is Dictionary):
			continue
		var cluster := raw_cluster as Dictionary
		var cluster_id := String(cluster.get("id", "cluster_%d" % cluster_index))
		var station_range: Array = cluster.get("station_m", []) as Array
		var offset_range: Array = cluster.get("offset_m", []) as Array
		var target := maxi(int(cluster.get("count", 0)), 0)
		if station_range.size() != 2 or offset_range.size() != 2 or target <= 0:
			_cluster_reports.append({"id": cluster_id, "target_count": target, "accepted_count": 0, "attempt_count": 0, "reason": "invalid_cluster_data"})
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = 0x37D355 + abs(int(cluster_id.hash())) + cluster_index * 7919
		var accepted := 0
		var attempts := 0
		var gap_rejected := 0
		var max_attempts := maxi(target * MAX_TREE_ATTEMPTS_MULTIPLIER, target)
		var gap_probability := clampf(float(cluster.get("gap_probability", 0.0)), 0.0, 0.45)
		var station_jitter_fraction := clampf(float(cluster.get("station_jitter_fraction", 0.025)), 0.0, 0.20)
		# Reserve a few extra station slots when a cluster asks for gaps.  A gap
		# rejection must advance the slot; retrying from `accepted` would fill the
		# same interval again and produce a uniform leaf wall despite the contract.
		var planned_slot_count := target + int(ceil(float(target) * gap_probability))
		var slot_index := 0
		while accepted < target and attempts < max_attempts:
			var fraction := rng.randf()
			if slot_index < planned_slot_count:
				fraction = (float(slot_index) + rng.randf_range(0.12, 0.88)) / float(maxi(planned_slot_count, 1))
				slot_index += 1
			var station_start := minf(float(station_range[0]), float(station_range[1]))
			var station_end := maxf(float(station_range[0]), float(station_range[1]))
			var station := lerpf(station_start, station_end, clampf(fraction, 0.0, 1.0))
			var station_span := absf(float(station_range[1]) - float(station_range[0]))
			station = clampf(station + rng.randf_range(-station_span * station_jitter_fraction, station_span * station_jitter_fraction), station_start, station_end)
			var side_sign := float(cluster.get("side_route_left_sign", 1.0))
			var lateral := side_sign * lerpf(float(offset_range[0]), float(offset_range[1]), rng.randf())
			attempts += 1
			if gap_probability > 0.0 and rng.randf() < gap_probability:
				gap_rejected += 1
				_reject_counts["gap"] = int(_reject_counts["gap"]) + 1
				continue
			if _station_in_open_window(station):
				_reject_counts["open_window"] = int(_reject_counts["open_window"]) + 1
				continue
			if not _route_clearance_ok(station, lateral):
				_reject_counts["route"] = int(_reject_counts["route"]) + 1
				continue
			var route_point := _route_point(station, lateral)
			var ground := _sample_ground(Vector2(route_point.x, route_point.z))
			if ground.is_empty():
				_reject_counts["ground"] = int(_reject_counts["ground"]) + 1
				continue
			var xz := Vector2(route_point.x, route_point.z)
			if not _obstacle_clear(xz, ROCK_WALL_CLEARANCE_M) or _too_close_to_existing(xz):
				_reject_counts["obstacle"] += 1 if not _obstacle_clear(xz, ROCK_WALL_CLEARANCE_M) else 0
				_reject_counts["spacing"] += 1 if _too_close_to_existing(xz) else 0
				continue
			var variant := rng.randi_range(0, maxi(_tree_meshes.size() - 1, 0))
			var mesh := _tree_meshes.get(variant) as Mesh
			if mesh == null:
				_reject_counts["asset"] = int(_reject_counts["asset"]) + 1
				continue
			var height_range: Array = cluster.get("height_m", [4.0, 6.0]) as Array
			var width_range: Array = cluster.get("width_m", [3.0, 4.5]) as Array
			var target_height := lerpf(float(height_range[0]), float(height_range[1]), rng.randf())
			var target_width := lerpf(float(width_range[0]), float(width_range[1]), rng.randf())
			var bounds := mesh.get_aabb()
			var mesh_width := maxf(maxf(absf(bounds.size.x), absf(bounds.size.z)), 0.001)
			var mesh_height := maxf(absf(bounds.size.y), 0.001)
			var width_scale := target_width / mesh_width
			var height_scale := target_height / mesh_height
			var yaw := rng.randf_range(-PI, PI)
			var basis := Basis(Vector3.UP, yaw).scaled(Vector3(width_scale, height_scale, width_scale))
			var root := Vector3(ground["position"].x, float(ground["position"].y) - bounds.position.y * height_scale, ground["position"].z)
			var item := {
				"mesh": mesh,
				"variant": variant,
				"basis": basis,
				"root_world": root,
				"ground": ground["position"],
				"station_m": station,
				"lateral_m": lateral,
				"source_cluster": cluster_id,
				"source_scene_id": String(_candidate.get("source_scene_id", "")),
				"source_estimated": true,
				"width_scale": width_scale,
				"height_scale": height_scale,
				"target_height_m": target_height,
				"target_width_m": target_width,
				"actual_height_m": absf(bounds.size.y) * height_scale,
				"actual_width_m": mesh_width * width_scale,
				"mesh_source_bounds_size": bounds.size,
				"yaw": yaw,
				"ground_sample": ground,
				"mesh_local_min_y": bounds.position.y,
				"root_contact_expected_y": float(ground["height"]),
			}
			_tree_items.append(item)
			_tree_points.append(xz)
			_contact_records.append(_tree_contact_record(item, cluster))
			accepted += 1
		_cluster_reports.append({
			"id": cluster_id,
			"target_count": target,
			"accepted_count": accepted,
			"accepted_ratio": float(accepted) / float(maxi(target, 1)),
			"attempt_count": attempts,
			"gap_rejected_count": gap_rejected,
			"gap_probability": gap_probability,
			"planned_slot_count": planned_slot_count,
			"station_jitter_fraction": station_jitter_fraction,
			"source_estimated": true,
			"layer": String(cluster.get("layer", "")),
		})


func _build_tree_multimeshes() -> void:
	if _generated == null:
		return
	var grouped: Dictionary = {}
	for item in _tree_items:
		var key := int(item["variant"])
		if not grouped.has(key):
			grouped[key] = []
		(grouped[key] as Array).append(item)
	for raw_variant in grouped.keys():
		var variant := int(raw_variant)
		var mesh := _tree_meshes.get(variant) as Mesh
		if mesh == null:
			continue
		var chunks: Dictionary = {}
		var variant_items: Array = grouped[raw_variant]
		for item in variant_items:
			var root: Vector3 = item["root_world"]
			var cx := floori(root.x / maxf(chunk_size_m, 1.0))
			var cz := floori(root.z / maxf(chunk_size_m, 1.0))
			var chunk_key := "%d:%d" % [cx, cz]
			if not chunks.has(chunk_key):
				chunks[chunk_key] = {"cx": cx, "cz": cz, "items": []}
			(chunks[chunk_key]["items"] as Array).append(item)
		for raw_chunk in chunks.values():
			var chunk := raw_chunk as Dictionary
			var cx := int(chunk["cx"])
			var cz := int(chunk["cz"])
			var origin := Vector3((float(cx) + 0.5) * chunk_size_m, 0.0, (float(cz) + 0.5) * chunk_size_m)
			var items: Array = chunk["items"]
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.mesh = mesh
			multimesh.instance_count = items.size()
			var authored_positions := PackedVector3Array()
			var authored_stations := PackedFloat32Array()
			var authored_ground := PackedVector3Array()
			var proofs: Array = []
			var actual_heights: Array[float] = []
			var actual_widths: Array[float] = []
			for index in items.size():
				var item: Dictionary = items[index]
				multimesh.set_instance_transform(index, Transform3D(item["basis"], item["root_world"] - origin))
				authored_positions.append(item["root_world"])
				authored_stations.append(float(item["station_m"]))
				authored_ground.append(item["ground"])
				actual_heights.append(float(item.get("actual_height_m", 0.0)))
				actual_widths.append(float(item.get("actual_width_m", 0.0)))
				if proofs.size() < 24:
					proofs.append(_tree_contact_record(item, {"id": item["source_cluster"]}))
			var instance := MultiMeshInstance3D.new()
			instance.name = "SaisiesR37Dressing_Tree_%d_%d_%d" % [variant, cx, cz]
			instance.multimesh = multimesh
			# Enter the scene tree before assigning global transforms.  The native
			# harness builds this overlay during the dressing call, so global_position
			# would otherwise trigger Node3D's !is_inside_tree diagnostic.
			_generated.add_child(instance)
			instance.global_position = origin
			instance.visibility_range_end = visibility_range_m
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			instance.set_meta("saisies_r37_dressing_family", "broadleaf")
			instance.set_meta("saisies_r37_dressing_variant", variant)
			instance.set_meta("saisies_r37_dressing_instance_count", items.size())
			instance.set_meta("saisies_r37_dressing_chunk_origin", origin)
			instance.set_meta("saisies_r37_dressing_authored_positions", authored_positions)
			instance.set_meta("saisies_r37_dressing_authored_stations", authored_stations)
			instance.set_meta("saisies_r37_dressing_authored_ground_positions", authored_ground)
			instance.set_meta("saisies_r37_dressing_actual_height_range_m", [actual_heights.min() if not actual_heights.is_empty() else 0.0, actual_heights.max() if not actual_heights.is_empty() else 0.0])
			instance.set_meta("saisies_r37_dressing_actual_width_range_m", [actual_widths.min() if not actual_widths.is_empty() else 0.0, actual_widths.max() if not actual_widths.is_empty() else 0.0])
			instance.set_meta("saisies_r37_dressing_root_proof_samples", proofs)
			instance.set_meta("saisies_r37_dressing_ground_contract", "visible terrain sample_mesh_triangle")
			instance.set_meta("saisies_r37_dressing_source_estimated", true)


func _sample_ground(xz: Vector2) -> Dictionary:
	if _terrain_sampler == null or not _terrain_sampler.has_method("sample_mesh_triangle"):
		return {}
	var raw: Variant = _terrain_sampler.call("sample_mesh_triangle", xz)
	if not (raw is Dictionary):
		return {}
	var sample := raw as Dictionary
	if not sample.has("a") or not sample.has("b") or not sample.has("c"):
		return {}
	if not (sample["a"] is Vector3) or not (sample["b"] is Vector3) or not (sample["c"] is Vector3):
		return {}
	var a: Vector3 = sample["a"]
	var b: Vector3 = sample["b"]
	var c: Vector3 = sample["c"]
	var bary := _barycentric_xz(xz, a, b, c)
	if bary.x < -0.002 or bary.y < -0.002 or bary.z < -0.002:
		return {}
	var height := a.y * bary.x + b.y * bary.y + c.y * bary.z
	if not is_finite(height):
		return {}
	var normal := (b - a).cross(c - a)
	if normal.length_squared() > 0.000001:
		normal = normal.normalized()
		if normal.y < 0.0:
			normal = -normal
	else:
		normal = Vector3.UP
	var source_name := "visible_mesh:%s.sample_mesh_triangle" % String(_terrain_sampler.get_path()) if _terrain_sampler_mode == "direct_indexed_sampler" else "visible_mesh:spatial_visible_triangle_cache"
	return {
		"position": Vector3(xz.x, height, xz.y),
		"height": height,
		"normal": normal,
		"source": source_name,
		"triangle_start": int(sample.get("triangle_start", -1)),
		"surface": int(sample.get("surface", 0)),
		"barycentric": bary,
		"a": a,
		"b": b,
		"c": c,
	}


func _route_point(station: float, lateral: float) -> Vector3:
	var center: Vector3 = _route.call("pos_at", station)
	var left: Vector3 = _route.call("left_at", station)
	left.y = 0.0
	if left.length_squared() < 0.000001:
		return center
	return center + left.normalized() * lateral


func _heading_y(station: float) -> float:
	if _route.has_method("tangent_at"):
		var tangent: Vector3 = _route.call("tangent_at", station)
		tangent.y = 0.0
		if tangent.length_squared() > 0.000001:
			return atan2(tangent.x, -tangent.z)
	var ahead := _route_point(station + 1.0, 0.0)
	var behind := _route_point(station - 1.0, 0.0)
	var fallback_tangent := ahead - behind
	return atan2(fallback_tangent.x, -fallback_tangent.z) if fallback_tangent.length_squared() > 0.000001 else 0.0


func _route_clearance_ok(station: float, lateral: float, required_clearance_m: float = TREE_ROUTE_CLEARANCE_M) -> bool:
	return _route_edge_clearance_m(station, lateral) >= required_clearance_m


func _route_edge_clearance_m(station: float, lateral: float) -> float:
	var half_width := 3.0
	if _route.has_method("road_width_at"):
		half_width = maxf(float(_route.call("road_width_at", station)) * 0.5, 2.0)
	return absf(lateral) - half_width


func _station_in_open_window(station: float) -> bool:
	var windows: Variant = _candidate.get("open_station_windows_m", [])
	if not (windows is Array):
		return false
	for raw_window in windows as Array:
		if raw_window is Array and (raw_window as Array).size() == 2:
			var window := raw_window as Array
			if station >= float(window[0]) and station <= float(window[1]):
				return true
	return false


func _obstacle_clear(xz: Vector2, clearance: float) -> bool:
	for raw_bounds in _obstacle_bounds:
		var bounds: AABB = raw_bounds
		var expanded := bounds.grow(clearance)
		if expanded.has_point(Vector3(xz.x, expanded.position.y, xz.y)):
			return false
	return true


func _too_close_to_existing(xz: Vector2) -> bool:
	for raw_point in _tree_points:
		var point: Vector2 = raw_point
		if xz.distance_to(point) < MIN_TREE_SPACING_M:
			return true
	return false


func _barycentric_xz(point: Vector2, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 := Vector2(b.x - a.x, b.z - a.z)
	var v1 := Vector2(c.x - a.x, c.z - a.z)
	var v2 := point - Vector2(a.x, a.z)
	var denominator := v0.cross(v1)
	if absf(denominator) < 0.000001:
		return Vector3(-1.0, -1.0, -1.0)
	var wb := v2.cross(v1) / denominator
	var wc := v0.cross(v2) / denominator
	return Vector3(1.0 - wb - wc, wb, wc)


func _contact_record(definition: Dictionary, ground: Dictionary, station: float, lateral: float) -> Dictionary:
	return {
		"id": String(definition.get("id", "structure")),
		"accepted": true,
		"kind": "structure",
		"station_m": station,
		"lateral_m": lateral,
		"ground": ground["position"],
		"ground_height_m": float(ground["height"]),
		"ground_source": String(ground["source"]),
		"ground_triangle_start": int(ground["triangle_start"]),
		"ground_triangle_surface": int(ground["surface"]),
		"ground_triangle_barycentric": ground["barycentric"],
		"ground_normal": ground["normal"],
		"source_estimated": true,
	}


func _tree_contact_record(item: Dictionary, cluster: Dictionary) -> Dictionary:
	var ground: Dictionary = item["ground_sample"]
	var root: Vector3 = item["root_world"]
	var mesh_local_min_y := float(item.get("mesh_local_min_y", 0.0))
	var root_contact_expected_y := float(item.get("root_contact_expected_y", ground["height"]))
	return {
		"id": "%s_%s" % [String(cluster.get("id", item.get("source_cluster", "tree"))), str(item.get("station_m", 0.0))],
		"accepted": true,
		"kind": "broadleaf",
		"station_m": float(item["station_m"]),
		"lateral_m": float(item["lateral_m"]),
		"root_world": item["root_world"],
		"ground": item["ground"],
		"mesh_local_min_y": mesh_local_min_y,
		"root_contact_expected_y": root_contact_expected_y,
		"root_contact_error_m": root.y + mesh_local_min_y * float(item.get("height_scale", 1.0)) - root_contact_expected_y,
		"target_height_m": float(item.get("target_height_m", 0.0)),
		"target_width_m": float(item.get("target_width_m", 0.0)),
		"actual_height_m": float(item.get("actual_height_m", 0.0)),
		"actual_width_m": float(item.get("actual_width_m", 0.0)),
		"height_scale": float(item.get("height_scale", 1.0)),
		"width_scale": float(item.get("width_scale", 1.0)),
		"mesh_source_bounds_size": item.get("mesh_source_bounds_size", Vector3.ZERO),
		"ground_height_m": float(ground["height"]),
		"ground_source": String(ground["source"]),
		"ground_triangle_start": int(ground["triangle_start"]),
		"ground_triangle_surface": int(ground["surface"]),
		"ground_triangle_barycentric": ground["barycentric"],
		"ground_normal": ground["normal"],
		"mesh_variant": int(item["variant"]),
		"source_cluster": String(item["source_cluster"]),
		"source_estimated": true,
		"clearance_contract_m": TREE_ROUTE_CLEARANCE_M,
		"road_clearance_m": _route_edge_clearance_m(float(item["station_m"]), float(item["lateral_m"])),
		"road_clearance_passed": true,
		"owned_obstacle_clearance_contract_m": ROCK_WALL_CLEARANCE_M,
		"asphalt_overlap": false,
		"asphalt_overlap_scope": "trunk_root_footprint",
		"crown_overhang_allowed": true,
	}


func _publish_ready() -> Dictionary:
	var requested := 0
	for report in _cluster_reports:
		requested += int(report.get("target_count", 0))
	var tree_count := _tree_items.size()
	var density_contract := tree_count >= requested and requested > 0
	var contact_misses := 0
	var actual_heights: Array[float] = []
	var actual_widths: Array[float] = []
	for record in _contact_records:
		if not bool(record.get("accepted", false)):
			contact_misses += 1
		if String(record.get("kind", "")) == "broadleaf":
			actual_heights.append(float(record.get("actual_height_m", 0.0)))
			actual_widths.append(float(record.get("actual_width_m", 0.0)))
	var actual_height_range := [actual_heights.min() if not actual_heights.is_empty() else 0.0, actual_heights.max() if not actual_heights.is_empty() else 0.0]
	var actual_width_range := [actual_widths.min() if not actual_widths.is_empty() else 0.0, actual_widths.max() if not actual_widths.is_empty() else 0.0]
	var hidden_replaced_mesh_paths: Array[String] = []
	for raw_entry in _hidden_replaced_meshes:
		if raw_entry is Dictionary:
			hidden_replaced_mesh_paths.append(String((raw_entry as Dictionary).get("path", "")))
	var report := {
		"ready": true,
		"generation_complete": true,
		"candidate_id": _built_candidate,
		"source_estimated": true,
		"formal_route_edit": false,
		"actual_visible_ground": _terrain_sampler != null,
		"terrain_sampler": _terrain_sampler_mode,
		"tree_count": tree_count,
		"tree_target_count": requested,
		"density_contract": density_contract,
		"density_warning": "underfilled_after_spacing_or_owned_feature_clearance" if not density_contract else "",
		"structure_count": _structure_records.filter(func(record): return bool(record.get("accepted", false))).size(),
		"structure_records": _structure_records,
		"cluster_reports": _cluster_reports,
		"reject_counts": _reject_counts.duplicate(true),
		"contact_count": _contact_records.size(),
		"contact_miss_count": contact_misses,
		"actual_tree_height_range_m": actual_height_range,
		"actual_tree_width_range_m": actual_width_range,
		"broadleaf_crown_profile": _candidate.get("broadleaf_crown_profile", "legacy"),
		"hidden_replaced_mesh_count": hidden_replaced_mesh_paths.size(),
		"hidden_replaced_mesh_paths": hidden_replaced_mesh_paths,
		"contact_records": _contact_records,
		"root_contact_proof": {
			"contact_count": _contact_records.size(),
			"contact_miss_count": contact_misses,
			"samples": _contact_records.slice(0, mini(_contact_records.size(), 128)),
		},
		"preserved_inherited_forest": true,
		"preserved_inherited_roadside": true,
		"no_opaque_ground_plane": true,
		"no_hud_or_vehicle": true,
	}
	set_meta("saisies_r37_dressing_ready", true)
	set_meta("saisies_r37_dressing_generation_complete", true)
	set_meta("saisies_r37_dressing_candidate", _built_candidate)
	set_meta("saisies_r37_dressing_source_estimated", true)
	set_meta("saisies_r37_dressing_actual_visible_ground", true)
	set_meta("saisies_r37_dressing_terrain_sampler_mode", _terrain_sampler_mode)
	set_meta("saisies_r37_dressing_density_contract", density_contract)
	set_meta("saisies_r37_dressing_tree_count", tree_count)
	set_meta("saisies_r37_dressing_tree_target_count", requested)
	set_meta("saisies_r37_dressing_actual_tree_height_range_m", actual_height_range)
	set_meta("saisies_r37_dressing_actual_tree_width_range_m", actual_width_range)
	set_meta("saisies_r37_dressing_hidden_replaced_mesh_count", hidden_replaced_mesh_paths.size())
	set_meta("saisies_r37_dressing_hidden_replaced_mesh_paths", hidden_replaced_mesh_paths)
	set_meta("saisies_r37_dressing_structure_records", _structure_records)
	set_meta("saisies_r37_dressing_cluster_reports", _cluster_reports)
	set_meta("saisies_r37_dressing_contact_records", _contact_records)
	set_meta("saisies_r37_dressing_root_contact_proof", {
		"contact_count": _contact_records.size(),
		"contact_miss_count": contact_misses,
		"samples": _contact_records.slice(0, mini(_contact_records.size(), 128)),
	})
	set_meta("saisies_r37_dressing_reject_counts", _reject_counts.duplicate(true))
	return report


func _failure(message: String) -> Dictionary:
	set_meta("saisies_r37_dressing_ready", false)
	set_meta("saisies_r37_dressing_error", message)
	return {"ready": false, "generation_complete": false, "error": message, "source_estimated": true}
