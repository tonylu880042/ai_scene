class_name SaisiesReleaseRoadside
extends Node3D

## Whole-route roadside dressing wrapper for the release candidate.
##
## The accepted R35 world owns the route, terrain, camera and historical
## review modules.  This node owns only the large roadside read: upper
## meadow/farm/rail/wall transitions, the lower rock-cut/rail/landmark pass,
## and the bounded S09/S13 near-field meshes.  Existing modules are reused as
## children so their authored contact and route sampling remain in one place.
## Forest instances are deliberately left to the release forest module.

@export var world_path: NodePath
@export var landscape_path: NodePath
@export_file("*.json") var candidate_path := "res://data/saisies_release_roadside.json"
@export var enable_refinement := true
## R35/R36 already carries bounded S09/S13 base geometry.  Keep the precise
## triangle-contact replacement opt-in so the release wrapper never stacks a
## second wall or rock cut over an accepted base mesh by default.
@export var include_nearfield_details := false

const RELEASE_STATUS := "root_selected_for_integrated_review"
const VISUAL_ACCEPTANCE := "pending"
const VIDEO_START_S := 135.0
const VIDEO_END_S := 920.067
const NEARFIELD_S09_START_S := 328.0
const NEARFIELD_S09_END_S := 336.0
const NEARFIELD_S13_START_S := 627.5
const NEARFIELD_S13_END_S := 632.5

var _world: Node3D
var _route: Node
var _landscape: Node
var _base_roadside: Node
var _upper: Node3D
var _lower: Node3D
var _nearfield: Node3D
var _candidate: Dictionary = {}
var _initialized := false
var _ready_published := false
var _build_attempts := 0
var _overlap_hidden := false
var _overlap_hide_records: Array[Dictionary] = []
var _ground_audit: SaisiesReleaseRoadsideGround
var _ground_audit_done := false
var _ground_audit_result: Dictionary = {}

func _ready() -> void:
	process_priority = -180
	call_deferred("_try_initialize")

func _try_initialize() -> void:
	if _initialized:
		return
	if not _load_candidate():
		return
	if not _resolve_world_and_route():
		_retry("release roadside is waiting for World/Route")
		return
	if _route == null or not _route.has_method("route_ready") or not bool(_route.call("route_ready")):
		_retry("release roadside is waiting for the geographic route")
		return
	_resolve_landscape()
	_resolve_base_roadside()
	_ground_audit = SaisiesReleaseRoadsideGround.new()
	_ground_audit.configure(_route, _landscape)
	_build_children()
	_initialized = true
	_set_child_visibility(enable_refinement)

func _process(_delta: float) -> void:
	if not _initialized:
		return
	_set_child_visibility(enable_refinement)
	if not _overlap_hidden and _nearfield != null and bool(_nearfield.get_meta("saisies_geo_nearfield_details_ready", false)):
		_hide_bounded_s09_overlap()
	if not _ground_audit_done and _children_ready_for_ground_audit():
		_ground_audit_result = _ground_audit.run(self) if _ground_audit != null else {"ground_proof": false, "ground_pass": false, "misses": [{"reason": "ground audit helper unavailable"}]}
		# Plain baked terrain has no Landscape script sampler.  The first audit
		# warms the helper's indexed triangle cache; release geometry then fits
		# actual support vertices against that same cache before the branch drape.
		var geometry_repaired := false
		if _upper != null and _upper.has_method("repair_release_geometry_with_sampler") and _ground_audit != null:
			geometry_repaired = bool(_upper.call("repair_release_geometry_with_sampler", _ground_audit)) or geometry_repaired
		if _lower != null and _lower.has_method("repair_release_geometry_with_sampler") and _ground_audit != null:
			geometry_repaired = bool(_lower.call("repair_release_geometry_with_sampler", _ground_audit)) or geometry_repaired
		set_meta("saisies_release_roadside_geometry_repaired", geometry_repaired)
		var branch_draped := false
		if _lower != null and _lower.has_method("drape_junction_branch_with_sampler") and _ground_audit != null:
			branch_draped = bool(_lower.call("drape_junction_branch_with_sampler", _ground_audit))
		if (geometry_repaired or branch_draped) and _ground_audit != null:
			_ground_audit_result = _ground_audit.run(self)
		_ground_audit_done = true
	_publish_ready_if_complete()

func set_release_enabled(enabled: bool) -> bool:
	enable_refinement = enabled
	visible = enabled
	_set_child_visibility(enabled)
	return true

func _load_candidate() -> bool:
	if not _candidate.is_empty():
		return true
	if not FileAccess.file_exists(candidate_path):
		push_error("Saisies release roadside candidate is missing: %s" % candidate_path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(candidate_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Saisies release roadside candidate is not a JSON object")
		return false
	_candidate = parsed as Dictionary
	if String(_candidate.get("status", "")) != RELEASE_STATUS or String(_candidate.get("visual_acceptance", "")) != VISUAL_ACCEPTANCE:
		push_error("Saisies release roadside candidate status must remain review-pending")
		return false
	if bool(_candidate.get("gps_calibrated", true)) or bool(_candidate.get("formal_route_edit", true)):
		push_error("Saisies release roadside candidate must remain visual-estimate-only")
		return false
	return true

func _resolve_world_and_route() -> bool:
	var resolved: Node = null
	if not world_path.is_empty():
		resolved = get_node_or_null(world_path)
	if resolved != null and resolved.has_method("route_ready") and resolved.has_method("pos_at"):
		_route = resolved
		_world = resolved.get_parent() as Node3D
	else:
		_world = resolved as Node3D
		if _world != null:
			_route = _world.get_node_or_null("Route")
	if _route == null:
		var cursor: Node = self
		while cursor != null and _route == null:
			var candidate := cursor.get_node_or_null("Route")
			if candidate != null and candidate.has_method("route_ready"):
				_route = candidate
				_world = cursor as Node3D
				break
			cursor = cursor.get_parent()
	return _route != null

func _resolve_landscape() -> void:
	if not landscape_path.is_empty():
		_landscape = get_node_or_null(landscape_path)
	# Prefer the ready SaisiesGeoLandscape owner because it exposes the
	# indexed triangle sampler and owns the visible terrain/shoulder meshes.
	# Falling back to the visible terrain MeshInstance keeps the audit useful in
	# standalone scenes where only the baked mesh is present.
	if _landscape == null or not _landscape.has_method("sample_mesh_triangle"):
		var candidate_landscape := _world.find_child("Landscape", true, false) if _world != null else null
		if candidate_landscape != null and candidate_landscape.has_method("sample_mesh_triangle"):
			_landscape = candidate_landscape
	if _landscape == null or (not _landscape.has_method("sample_mesh_triangle") and _world != null):
		var terrain_mesh := _world.find_child("SaisiesGeoTerrain", true, false) if _world != null else null
		if terrain_mesh != null:
			_landscape = terrain_mesh
	if _landscape == null:
		var scene := get_tree().current_scene
		if scene != null:
			var candidate_landscape := scene.find_child("Landscape", true, false)
			if candidate_landscape != null and candidate_landscape.has_method("sample_mesh_triangle"):
				_landscape = candidate_landscape
			if _landscape == null:
				_landscape = scene.find_child("SaisiesGeoTerrain", true, false)

func _resolve_base_roadside() -> void:
	_base_roadside = null
	if _world == null:
		return
	var named := _world.find_child("Roadside", true, false)
	if named != null and (String(named.name) == "Roadside" or _is_geo_roadside(named)):
		_base_roadside = named
		return
	for node in _world.find_children("*", "", true, false):
		if _is_geo_roadside(node):
			_base_roadside = node
			return

func _is_geo_roadside(node: Node) -> bool:
	if node == null:
		return false
	if String(node.name) == "Roadside":
		return true
	if node.has_meta("saisies_geo_roadside_ready") or node.has_meta("saisies_geo_roadside_span_records"):
		return true
	var script := node.get_script() as Script
	return script != null and String(script.resource_path).ends_with("scripts/saisies_geo_roadside.gd")

func _base_roadside_has_guardrail_groups() -> bool:
	if _base_roadside == null or not is_instance_valid(_base_roadside):
		return false
	if int(_base_roadside.get_meta("saisies_geo_roadside_beam_count", 0)) > 0 and int(_base_roadside.get_meta("saisies_geo_roadside_post_count", 0)) > 0:
		return true
	for node in _base_roadside.find_children("*", "", true, false):
		var node_name := String(node.name)
		if node_name.begins_with("SaisiesGeoGuardBeam") or node_name.begins_with("SaisiesGeoGuardPost"):
			return true
	return false

func _build_children() -> void:
	# S05-S09: farms, utilities and protection-type transitions.  Trees are
	# disabled here because release forest owns the shared MultiMeshes.
	_upper = _new_child("ReleaseUpperScenery", "res://scripts/saisies_release_roadside_upper.gd")
	if _upper != null:
		_upper.set("route", _route)
		_upper.set("ground_sampler", _ground_audit)
		_upper.set("base_roadside", _base_roadside)
		_upper.set("from_video_seconds", VIDEO_START_S)
		_upper.set("to_video_seconds", 395.0)
		_upper.set("include_trees", false)
		_upper.set("from_m", 1300.0)
		_upper.set("to_m", 6500.0)
		add_child(_upper)

	# S10-S18: rock cuts, alternating rails, S16 sign, S17 house/shed and the
	# S18 junction/bridge read.  The lower module's foliage is disabled so the
	# dedicated release forest can control canopy openings without duplicates.
	_lower = _new_child("ReleaseLowerScenery", "res://scripts/saisies_release_roadside_lower.gd")
	if _lower != null:
		_lower.set("route", _route)
		_lower.set("ground_sampler", _ground_audit)
		_lower.set("base_roadside", _base_roadside)
		_lower.set("player", null)
		_lower.set("lower_start_time_s", 395.0)
		_lower.set("lower_end_time_s", VIDEO_END_S)
		_lower.set("build_foliage", false)
		_lower.set("build_roadside_detail", true)
		add_child(_lower)

	# Nearfield meshes use actual visible terrain triangles for the S13 hero cut
	# and the short S09 wall.  If the release scene does not expose a terrain
	# sampler, leave the module absent and publish that proof as unavailable.
	if include_nearfield_details and _landscape != null and _landscape.has_method("sample_mesh_triangle"):
		_nearfield = _new_child("ReleaseNearfieldDetails", "res://scripts/saisies_geo_nearfield_details.gd")
		if _nearfield != null:
			_nearfield.set("route", _route)
			_nearfield.set("landscape", _landscape)
			_nearfield.set("start_video_seconds", NEARFIELD_S13_START_S)
			_nearfield.set("end_video_seconds", NEARFIELD_S13_END_S)
			_nearfield.set("s09_start_video_seconds", NEARFIELD_S09_START_S)
			_nearfield.set("s09_end_video_seconds", NEARFIELD_S09_END_S)
			add_child(_nearfield)
	else:
		set_meta("saisies_release_roadside_nearfield_unavailable", true)


func _new_child(node_name: String, script_path: String) -> Node3D:
	var script := load(script_path) as Script
	if script == null:
		push_error("Saisies release roadside could not load %s" % script_path)
		return null
	var child := Node3D.new()
	child.name = node_name
	child.set_script(script)
	return child

func _set_child_visibility(enabled: bool) -> void:
	visible = enabled
	for child in [_upper, _lower, _nearfield]:
		if child != null and is_instance_valid(child):
			child.visible = enabled

func _hide_bounded_s09_overlap() -> void:
	if _upper == null or _route == null or not _route.has_method("distance_for_position"):
		_overlap_hidden = true
		return
	# The existing upper module supplies the long S09 transition.  Nearfield
	# replaces only the 328--336 s interval with terrain-contact geometry, so
	# hide old stone blocks inside that finite interval and retain the rest.
	var start_m := _video_station(NEARFIELD_S09_START_S)
	var end_m := _video_station(NEARFIELD_S09_END_S)
	for node in _upper.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or not (mi.name.begins_with("SaisiesS09StoneBlock") or mi.name.begins_with("SaisiesS09StoneCap")):
			continue
		var station := float(_route.call("distance_for_position", mi.global_position))
		if station >= start_m - 3.0 and station <= end_m + 3.0:
			mi.visible = false
			_overlap_hide_records.append({"path": String(mi.get_path()), "station_m": station, "reason": "bounded S09 nearfield replacement"})
	_overlap_hidden = true

func _video_station(video_seconds: float) -> float:
	if _route != null and _route.has_method("distance_for_video_seconds"):
		return float(_route.call("distance_for_video_seconds", video_seconds))
	return 0.0

func _publish_ready_if_complete() -> void:
	if _ready_published:
		return
	var upper_ready := _upper != null and bool(_upper.get_meta("saisies_upper_scenery_ready", false))
	var upper_contract_ok := _upper != null and bool(_upper.get_meta("saisies_upper_roadside_contract_ok", false))
	var lower_ready := _lower != null and bool(_lower.get_meta("saisies_lower_scenery_ready", false))
	var lower_contract_ok := _lower != null and bool(_lower.get_meta("saisies_release_roadside_contract_ok", false))
	var nearfield_required := include_nearfield_details and _landscape != null and _landscape.has_method("sample_mesh_triangle")
	var nearfield_ready := not nearfield_required or (_nearfield != null and bool(_nearfield.get_meta("saisies_geo_nearfield_details_ready", false)))
	# Publish the built module even when geometry contracts fail so native review
	# can inspect the authored result and its recorded misses.  Contract flags
	# below remain false until upper/lower clearance and ground proof pass.
	if not upper_ready or not lower_ready or not nearfield_ready or not _ground_audit_done:
		return
	var upper_farms := int(_upper.get_meta("saisies_upper_farmhouses", 0))
	var upper_rails := int(_upper.get_meta("saisies_upper_s05_guardrail_beams", 0)) + int(_upper.get_meta("saisies_upper_s09_guardrail_beams", 0))
	var upper_walls := int(_upper.get_meta("saisies_upper_s08_parapet_segments", 0)) + int(_upper.get_meta("saisies_upper_s09_stonewall_segments", 0))
	var upper_wall_body_segments := int(_upper.get_meta("saisies_release_wall_body_segment_count", 0))
	var upper_wall_cap_segments := int(_upper.get_meta("saisies_release_wall_cap_segment_count", 0))
	var lower_rocks := _count_named_meshes(_lower, "SaisiesLowerContinuousRockCut")
	var lower_rails := _count_named_nodes(_lower, ["SaisiesLowerRailPosts", "SaisiesLowerRailBeams"])
	var lower_landmarks := _count_lower_landmarks()
	var nearfield_triangles := int(_nearfield.get_meta("saisies_geo_nearfield_details_triangle_count", 0)) if _nearfield != null else 0
	var upper_reused_rails: Variant = _upper.get_meta("saisies_release_roadside_reused_rail_spans", [])
	var lower_reused_rails: Variant = _lower.get_meta("saisies_release_roadside_reused_rail_spans", [])
	var upper_new_rails: Variant = _upper.get_meta("saisies_release_roadside_new_rail_records", [])
	var lower_new_rails: Variant = _lower.get_meta("saisies_release_roadside_new_rail_records", [])
	var reused_rail_span_count := 0
	if upper_reused_rails is Array:
		reused_rail_span_count += upper_reused_rails.size()
	if lower_reused_rails is Array:
		reused_rail_span_count += lower_reused_rails.size()
	var base_rail_groups_present := _base_roadside_has_guardrail_groups()
	var rail_source_contract_ok := bool(_upper.get_meta("saisies_release_roadside_rail_source_contract_ok", false)) and bool(_lower.get_meta("saisies_release_roadside_rail_source_contract_ok", false))
	var total := upper_farms + upper_rails + upper_walls + lower_rocks + lower_rails + lower_landmarks + nearfield_triangles
	set_meta("saisies_release_roadside_ready", true)
	set_meta("saisies_release_roadside_status", RELEASE_STATUS)
	set_meta("saisies_release_roadside_visual_acceptance", VISUAL_ACCEPTANCE)
	set_meta("saisies_release_roadside_count", total)
	set_meta("saisies_release_roadside_instance_count", total)
	set_meta("saisies_release_roadside_geometry_count", total)
	set_meta("saisies_release_roadside_video_range_s", Vector2(VIDEO_START_S, VIDEO_END_S))
	set_meta("saisies_release_roadside_scene_ids", ["S05", "S06", "S07", "S08", "S09", "S10", "S11", "S12", "S13", "S14", "S15", "S16", "S17", "S18"])
	set_meta("saisies_release_roadside_component_counts", {
		"upper_farmhouses": upper_farms,
		"upper_guardrail_beams": upper_rails,
		"upper_wall_segments": upper_walls,
		"upper_wall_body_segments_audited": upper_wall_body_segments,
		"upper_wall_cap_segments_excluded": upper_wall_cap_segments,
		"lower_rock_cut_meshes": lower_rocks,
		"lower_guardrail_parts": lower_rails,
		"base_roadside_rail_spans_reused": reused_rail_span_count,
		"lower_landmarks": lower_landmarks,
		"nearfield_triangles": nearfield_triangles,
	})
	set_meta("saisies_release_roadside_ground_strategy", "independent visible SaisiesGeoTerrain/shoulder triangle cache audit after Upper/Lower generation; route tangent and world Y are preserved")
	var ground := _ground_audit_result
	set_meta("saisies_release_roadside_ground_proof", bool(ground.get("ground_proof", false)))
	set_meta("saisies_release_roadside_ground_pass", bool(ground.get("ground_pass", false)))
	set_meta("saisies_release_roadside_ground_candidate_count", int(ground.get("candidate_count", 0)))
	set_meta("saisies_release_roadside_ground_sample_count", int(ground.get("sample_count", 0)))
	set_meta("saisies_release_roadside_ground_miss_count", int(ground.get("miss_count", 0)))
	set_meta("saisies_release_roadside_ground_source_counts", ground.get("source_counts", {}))
	set_meta("saisies_release_roadside_ground_support_kind_counts", ground.get("support_kind_counts", {}))
	set_meta("saisies_release_roadside_ground_min_clearance_m", float(ground.get("min_clearance_m", 0.0)))
	set_meta("saisies_release_roadside_ground_max_clearance_m", float(ground.get("max_clearance_m", 0.0)))
	set_meta("saisies_release_roadside_ground_max_abs_clearance_m", float(ground.get("max_abs_clearance_m", 0.0)))
	set_meta("saisies_release_roadside_ground_positive_float_count", int(ground.get("positive_float_count", 0)))
	set_meta("saisies_release_roadside_ground_over_embedded_count", int(ground.get("over_embedded_count", 0)))
	set_meta("saisies_release_roadside_ground_expected_embedding_count", int(ground.get("expected_embedding_count", 0)))
	set_meta("saisies_release_roadside_ground_support_failure_count", int(ground.get("support_failure_count", 0)))
	set_meta("saisies_release_roadside_ground_foundation_burial_range_m", ground.get("foundation_burial_range_m", {}))
	set_meta("saisies_release_roadside_ground_visible_triangle_cache_count", int(ground.get("visible_triangle_cache_count", 0)))
	set_meta("saisies_release_roadside_ground_visible_triangle_bin_count", int(ground.get("visible_triangle_bin_count", 0)))
	set_meta("saisies_release_roadside_ground_visible_query_bin_count", int(ground.get("visible_query_bin_count", 0)))
	set_meta("saisies_release_roadside_ground_visible_triangle_cache_mode", String(ground.get("visible_triangle_cache_mode", "unknown")))
	set_meta("saisies_release_roadside_ground_visible_sample_count", int(ground.get("visible_sample_count", 0)))
	set_meta("saisies_release_roadside_ground_fallback_sample_count", int(ground.get("fallback_sample_count", 0)))
	set_meta("saisies_release_roadside_ground_records", ground.get("records", []))
	set_meta("saisies_release_roadside_ground_misses", ground.get("misses", []))
	set_meta("saisies_release_roadside_geometry_repaired", bool(get_meta("saisies_release_roadside_geometry_repaired", false)))
	set_meta("saisies_release_roadside_upper_wall_repairs", int(_upper.get_meta("saisies_release_wall_geometry_repairs", 0)))
	set_meta("saisies_release_roadside_upper_wall_repair_misses", int(_upper.get_meta("saisies_release_wall_geometry_misses", 0)))
	set_meta("saisies_release_roadside_upper_foundation_repairs", int(_upper.get_meta("saisies_release_wall_foundation_repairs", 0)))
	set_meta("saisies_release_roadside_cut_slope_repairs", int(_upper.get_meta("saisies_release_cut_slope_repairs", 0)))
	set_meta("saisies_release_roadside_cut_slope_repair_misses", int(_upper.get_meta("saisies_release_cut_slope_repair_misses", 0)))
	set_meta("saisies_release_roadside_lower_landmark_repairs", int(_lower.get_meta("saisies_release_landmark_geometry_repairs", 0)))
	set_meta("saisies_release_roadside_lower_landmark_repair_misses", int(_lower.get_meta("saisies_release_landmark_geometry_misses", 0)))
	set_meta("saisies_release_roadside_rock_repairs", int(_lower.get_meta("saisies_release_rock_geometry_repairs", 0)))
	set_meta("saisies_release_roadside_rock_repair_misses", int(_lower.get_meta("saisies_release_rock_geometry_misses", 0)))
	set_meta("saisies_release_roadside_post_repairs", int(_lower.get_meta("saisies_release_post_geometry_repairs", 0)))
	set_meta("saisies_release_roadside_post_repair_misses", int(_lower.get_meta("saisies_release_post_geometry_misses", 0)))
	set_meta("saisies_release_roadside_contract_ok", upper_contract_ok and lower_contract_ok and bool(ground.get("ground_pass", false)))
	set_meta("saisies_release_roadside_base_roadside_present", _base_roadside != null)
	set_meta("saisies_release_roadside_base_rail_groups_present", base_rail_groups_present)
	set_meta("saisies_release_roadside_base_rail_node_path", String(_base_roadside.get_path()) if _base_roadside != null else "")
	set_meta("saisies_release_roadside_rail_source_contract_ok", rail_source_contract_ok)
	set_meta("saisies_release_roadside_reused_rail_spans", {"upper": upper_reused_rails, "lower": lower_reused_rails})
	set_meta("saisies_release_roadside_new_rail_records", {"upper": upper_new_rails, "lower": lower_new_rails})
	set_meta("saisies_release_roadside_upper_contract_ok", upper_contract_ok)
	set_meta("saisies_release_roadside_rock_contract_ok", bool(_lower.get_meta("saisies_release_roadside_rock_contract_ok", false)))
	set_meta("saisies_release_roadside_rail_contract_ok", bool(_lower.get_meta("saisies_release_roadside_rail_contract_ok", false)))
	set_meta("saisies_release_roadside_junction_rail_contract_ok", bool(_lower.get_meta("saisies_release_roadside_junction_rail_contract_ok", false)))
	set_meta("saisies_release_junction_branch_drape_ok", bool(_lower.get_meta("saisies_release_junction_branch_drape_ok", false)))
	set_meta("saisies_release_roadside_landmark_contract_ok", bool(_lower.get_meta("saisies_release_roadside_landmark_contract_ok", false)))
	set_meta("saisies_release_roadside_nearfield_enabled", nearfield_required)
	set_meta("saisies_release_roadside_nearfield_records", _nearfield.get_meta("saisies_geo_nearfield_details_base_contact_records", []) if _nearfield != null else [])
	set_meta("saisies_release_roadside_bounded_hides", _overlap_hide_records.duplicate(true))
	set_meta("saisies_release_roadside_modules", ["ReleaseUpperScenery", "ReleaseLowerScenery", "ReleaseNearfieldDetails"])
	set_meta("saisies_release_roadside_enable_refinement", enable_refinement)
	_ready_published = true
	print("saisies release roadside ready upper_farms=%d upper_rails=%d upper_walls=%d lower_rocks=%d lower_rails=%d lower_landmarks=%d nearfield_triangles=%d" % [upper_farms, upper_rails, upper_walls, lower_rocks, lower_rails, lower_landmarks, nearfield_triangles])

func _count_named_meshes(parent: Node, prefix: String) -> int:
	if parent == null:
		return 0
	var count := 0
	for node in parent.find_children("*", "MeshInstance3D", true, false):
		if String(node.name).begins_with(prefix):
			count += 1
	return count

func _count_named_nodes(parent: Node, prefixes: Array[String]) -> int:
	if parent == null:
		return 0
	var count := 0
	for node in parent.find_children("*", "", true, false):
		var node_name := String(node.name)
		for prefix in prefixes:
			if node_name.begins_with(prefix):
				count += 1
				break
	return count

func _children_ready_for_ground_audit() -> bool:
	if _ground_audit == null:
		return false
	if not _visible_terrain_ready():
		return false
	var upper_ready := _upper != null and bool(_upper.get_meta("saisies_upper_scenery_ready", false))
	var lower_ready := _lower != null and bool(_lower.get_meta("saisies_lower_scenery_ready", false))
	var nearfield_required := include_nearfield_details and _landscape != null and _landscape.has_method("sample_mesh_triangle")
	var nearfield_ready := not nearfield_required or (_nearfield != null and bool(_nearfield.get_meta("saisies_geo_nearfield_details_ready", false)))
	return upper_ready and lower_ready and nearfield_ready

func _visible_terrain_ready() -> bool:
	if _landscape == null:
		# A missing sampler is a supported, recorded audit miss; do not stall the
		# whole release module when a standalone scene intentionally omits terrain.
		return true
	if _landscape.has_method("sample_mesh_triangle"):
		var ready_variant: Variant = _landscape.get("landscape_ready")
		if ready_variant != null:
			return bool(ready_variant)
		return true
	if _landscape is MeshInstance3D:
		return (_landscape as MeshInstance3D).mesh != null
	return true

func _count_lower_landmarks() -> int:
	if _lower == null:
		return 0
	var prefixes := ["SaisiesLowerWood", "SaisiesLowerJunction", "SaisiesLowerSpeed", "SaisiesLowerBlue", "SaisiesLowerDirection"]
	var count := 0
	for node in _lower.get_children():
		var node_name := String(node.name)
		for prefix in prefixes:
			if node_name.begins_with(prefix):
				count += 1
				break
	return count

func _retry(message: String) -> void:
	_build_attempts += 1
	if _build_attempts < 180:
		call_deferred("_try_initialize")
	else:
		push_error(message)
		set_meta("saisies_release_roadside_ready", false)

