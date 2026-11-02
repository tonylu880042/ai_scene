class_name SaisiesReleaseRoadsideLower
extends "res://scripts/saisies_lower_scenery.gd"

## Release-only lower scenery subclass.  Lower roadside detail still uses the
## shared rock/shrub meshes, but it must not load the large tree variant set;
## release forest owns the canopy MultiMeshes.

var base_roadside: Node
var ground_sampler: RefCounted
var _release_rock_records: Array[Dictionary] = []
var _release_rail_records: Array[Dictionary] = []
var _base_rails_reused := false
var _reused_rail_spans: Array[Dictionary] = []
var _new_rail_records: Array[Dictionary] = []
var _prop_chunk_serial := 0
var _geometry_repaired := false

const JUNCTION_BRANCH_HALF_WIDTH_M := 3.8
const JUNCTION_BRANCH_HALF_LENGTH_M := 18.0
const JUNCTION_BRANCH_THICKNESS_M := 0.10
const JUNCTION_BRANCH_WIDTH_STEPS := 2
const JUNCTION_BRANCH_LENGTH_STEPS := 12

func _build() -> void:
	if not scenery_ready:
		_release_rock_records.clear()
		_release_rail_records.clear()
		_reused_rail_spans.clear()
		_new_rail_records.clear()
		_prop_chunk_serial = 0
		_geometry_repaired = false
	super._build()
	if scenery_ready:
		_validate_release_roadside_contract()

## Refit release lower support meshes after the independent terrain cache has
## warmed.  The helper rewrites actual bottom vertices and leaves roofs/signs
## untouched; rock correction is limited to positive selected toe vertices.
func repair_release_geometry_with_sampler(sampler: RefCounted) -> bool:
	if _geometry_repaired or sampler == null or not sampler.has_method("fit_mesh_bottom_to_sampler"):
		return false
	ground_sampler = sampler
	var changed := false
	var landmark_repairs := 0
	var landmark_misses := 0
	for node in get_children():
		var name := String(node.name)
		if not (name.begins_with("SaisiesLowerChalet_") or name == "SaisiesLowerWoodShed" or name == "SaisiesLowerJunctionKiosk"):
			continue
		var landmark := node as Node3D
		var foundation := _first_direct_mesh(landmark)
		if foundation == null:
			continue
		# A lower chalet is one authored parent: when a sloped visible triangle
		# rises above its floor, lift the parent and keep the roof/facade local
		# offsets intact before refitting the foundation.
		if bool(sampler.call("fit_mesh_bottom_to_sampler", foundation, 0.03, true)):
			landmark_repairs += 1
			changed = true
		else:
			landmark_misses += 1
	var rock_repairs := 0
	var rock_misses := 0
	for node in get_children():
		if not String(node.name).begins_with("SaisiesLowerContinuousRockCut"):
			continue
		var rock := node as MeshInstance3D
		if rock == null:
			continue
		if bool(sampler.call("fit_rock_footline_to_sampler", rock, 0.03)):
			rock_repairs += 1
			changed = true
		else:
			rock_misses += 1
	var post_repairs := 0
	var post_misses := 0
	for node in get_children():
		if not String(node.name).begins_with("SaisiesLowerRailPosts"):
			continue
		var posts := node as MultiMeshInstance3D
		if posts == null or not sampler.has_method("fit_rail_post_multimesh_to_sampler"):
			continue
		if bool(sampler.call("fit_rail_post_multimesh_to_sampler", posts, 0.03)):
			post_repairs += 1
			changed = true
		else:
			post_misses += 1
	set_meta("saisies_release_landmark_geometry_repairs", landmark_repairs)
	set_meta("saisies_release_landmark_geometry_misses", landmark_misses)
	set_meta("saisies_release_rock_geometry_repairs", rock_repairs)
	set_meta("saisies_release_rock_geometry_misses", rock_misses)
	set_meta("saisies_release_post_geometry_repairs", post_repairs)
	set_meta("saisies_release_post_geometry_misses", post_misses)
	_geometry_repaired = true
	set_meta("saisies_release_lower_geometry_repaired", true)
	_validate_release_roadside_contract()
	return changed

func _first_direct_mesh(node: Node3D) -> MeshInstance3D:
	if node == null:
		return null
	for child in node.get_children():
		var mesh := child as MeshInstance3D
		if mesh != null:
			return mesh
	return null

func _load_factory() -> void:
	_factory_broadleaf.clear()
	_factory_conifer.clear()

func _ready() -> void:
	# The wrapper injects the shared SaisiesGeoRoute before attaching this
	# child.  The base _ready() unconditionally resolves an empty route_path and
	# would overwrite that valid reference with null because the wrapper itself
	# has no Route child.  Resolve only when injection is absent, then reuse the
	# base build/retry flow without touching the original module.
	if route == null and not route_path.is_empty():
		route = get_node_or_null(route_path) as SaisiesRoute
	if route == null and get_parent() != null:
		route = get_parent().get_node_or_null("Route") as SaisiesRoute
	if player == null and not player_path.is_empty():
		player = get_node_or_null(player_path) as Node3D
	if route == null:
		push_warning("SaisiesReleaseRoadsideLower needs an injected SaisiesRoute or route_path")
		return
	if not route.route_ready():
		call_deferred("_retry_build")
		return
	_build()

func _add_rock_cut(s0: float, s1: float, side: float, height: float, depth: float, face_mesh: Mesh) -> void:
	var scene_id := _release_rock_scene_id(s0, s1, side)
	var effective_height := height
	var effective_depth := depth
	if scene_id == "S13":
		effective_height = maxf(effective_height, 9.2)
		effective_depth = maxf(effective_depth, 4.2)
	elif scene_id == "S15":
		effective_height = maxf(effective_height, 4.2)
		effective_depth = maxf(effective_depth, 3.0)
	var before_count := get_child_count()
	super._add_rock_cut(s0, s1, side, effective_height, effective_depth, face_mesh)
	for index in range(before_count, get_child_count()):
		var mesh := get_child(index) as MeshInstance3D
		if mesh == null:
			continue
		mesh.name = "SaisiesLowerContinuousRockCut_%s" % scene_id if not scene_id.is_empty() else "SaisiesLowerContinuousRockCut"
		mesh.set_meta("saisies_release_rock_scene", scene_id)
		mesh.set_meta("saisies_release_rock_side", side)
		mesh.set_meta("saisies_release_rock_height_m", effective_height)
		mesh.set_meta("saisies_release_rock_depth_m", effective_depth)
		_release_rock_records.append({
			"scene": scene_id,
			"s0": s0,
			"s1": s1,
			"side": side,
			"height_m": effective_height,
			"depth_m": effective_depth,
			"path": String(mesh.get_path()),
		})

func _build_junction(s: float) -> void:
	super._build_junction(s)
	_drape_junction_branch()

func drape_junction_branch_with_sampler(sampler: RefCounted) -> bool:
	ground_sampler = sampler
	var draped := _drape_junction_branch()
	if draped:
		_validate_release_roadside_contract()
	return draped

func _drape_junction_branch() -> bool:
	var branch := get_node_or_null("SaisiesLowerJunctionBranch") as MeshInstance3D
	if branch == null:
		return false
	if bool(branch.get_meta("saisies_release_junction_branch_draped", false)):
		return true
	if ground_sampler == null or not ground_sampler.has_method("sample_mesh_triangle"):
		return false
	var mesh := _build_draped_branch_mesh(branch)
	if mesh == null:
		return false
	branch.mesh = mesh
	branch.set_meta("saisies_release_junction_branch_draped", true)
	branch.set_meta("saisies_release_junction_branch_support", "indexed_visible_terrain_triangle")
	branch.set_meta("saisies_release_junction_branch_thickness_m", JUNCTION_BRANCH_THICKNESS_M)
	return true

func _build_draped_branch_mesh(branch: MeshInstance3D) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var inverse := branch.global_transform.affine_inverse()
	for z_index in range(JUNCTION_BRANCH_LENGTH_STEPS + 1):
		var z_fraction := float(z_index) / float(JUNCTION_BRANCH_LENGTH_STEPS)
		var local_z := lerpf(-JUNCTION_BRANCH_HALF_LENGTH_M, JUNCTION_BRANCH_HALF_LENGTH_M, z_fraction)
		for x_index in range(JUNCTION_BRANCH_WIDTH_STEPS + 1):
			var x_fraction := float(x_index) / float(JUNCTION_BRANCH_WIDTH_STEPS)
			var local_x := lerpf(-JUNCTION_BRANCH_HALF_WIDTH_M, JUNCTION_BRANCH_HALF_WIDTH_M, x_fraction)
			var probe_world := branch.global_transform * Vector3(local_x, 0.0, local_z)
			var sample_variant: Variant = ground_sampler.call("sample_mesh_triangle", Vector2(probe_world.x, probe_world.z))
			if typeof(sample_variant) != TYPE_DICTIONARY:
				return null
			var sample: Dictionary = sample_variant
			if not sample.has("height") or not is_finite(float(sample["height"])):
				return null
			var ground_y := float(sample["height"])
			var top_world := Vector3(probe_world.x, ground_y + JUNCTION_BRANCH_THICKNESS_M * 0.5, probe_world.z)
			var bottom_world := Vector3(probe_world.x, ground_y - JUNCTION_BRANCH_THICKNESS_M * 0.5, probe_world.z)
			vertices.append(inverse * top_world)
			normals.append(Vector3.UP)
			vertices.append(inverse * bottom_world)
			normals.append(Vector3.UP)
	for z_index in range(JUNCTION_BRANCH_LENGTH_STEPS):
		for x_index in range(JUNCTION_BRANCH_WIDTH_STEPS):
			var top_a := _branch_vertex_index(z_index, x_index, true)
			var top_b := _branch_vertex_index(z_index, x_index + 1, true)
			var top_c := _branch_vertex_index(z_index + 1, x_index + 1, true)
			var top_d := _branch_vertex_index(z_index + 1, x_index, true)
			indices.append_array(PackedInt32Array([top_a, top_c, top_b, top_a, top_d, top_c]))
			var bottom_a := _branch_vertex_index(z_index, x_index, false)
			var bottom_b := _branch_vertex_index(z_index + 1, x_index, false)
			var bottom_c := _branch_vertex_index(z_index + 1, x_index + 1, false)
			var bottom_d := _branch_vertex_index(z_index, x_index + 1, false)
			indices.append_array(PackedInt32Array([bottom_a, bottom_b, bottom_c, bottom_a, bottom_c, bottom_d]))
	# Close the two long sides and the two ends so the pavement keeps a constant
	# thickness while each top/bottom vertex follows its sampled terrain point.
	for z_index in range(JUNCTION_BRANCH_LENGTH_STEPS):
		for x_index in [0, JUNCTION_BRANCH_WIDTH_STEPS]:
			var top_a := _branch_vertex_index(z_index, x_index, true)
			var top_b := _branch_vertex_index(z_index + 1, x_index, true)
			var bottom_a := _branch_vertex_index(z_index, x_index, false)
			var bottom_b := _branch_vertex_index(z_index + 1, x_index, false)
			indices.append_array(PackedInt32Array([top_a, bottom_b, top_b, top_a, bottom_a, bottom_b]))
	for x_index in range(JUNCTION_BRANCH_WIDTH_STEPS):
		for z_index in [0, JUNCTION_BRANCH_LENGTH_STEPS]:
			var top_a := _branch_vertex_index(z_index, x_index, true)
			var top_b := _branch_vertex_index(z_index, x_index + 1, true)
			var bottom_a := _branch_vertex_index(z_index, x_index, false)
			var bottom_b := _branch_vertex_index(z_index, x_index + 1, false)
			indices.append_array(PackedInt32Array([top_a, top_b, bottom_b, top_a, bottom_b, bottom_a]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _branch_vertex_index(z_index: int, x_index: int, top: bool) -> int:
	var row_width := JUNCTION_BRANCH_WIDTH_STEPS + 1
	return (z_index * row_width + x_index) * 2 + (0 if top else 1)

func _spawn_prop_chunks(mesh: Mesh, items: Array, material: Material, prefix: String) -> void:
	var before_count := get_child_count()
	super._spawn_prop_chunks(mesh, items, material, prefix)
	# S18 invokes the bridge rail builder twice with the same chunk id (left and
	# right).  Rename every newly-created MultiMesh after the base helper adds it
	# so Godot's duplicate-name auto-renaming cannot hide a complete post set
	# from the release contact audit.
	for index in range(before_count, get_child_count()):
		var chunk := get_child(index) as MultiMeshInstance3D
		if chunk == null:
			continue
		_prop_chunk_serial += 1
		chunk.name = "%s_release_%03d" % [prefix, _prop_chunk_serial]
		chunk.set_meta("saisies_release_prop_chunk_prefix", prefix)
		chunk.set_meta("saisies_release_prop_chunk_index", _prop_chunk_serial)

func _release_rock_scene_id(s0: float, _s1: float, side: float) -> String:
	if side > 0.0 and absf(s0 - _s_at_time(615.0)) < 1.0:
		return "S13"
	if side < 0.0 and absf(s0 - _s_at_time(754.0)) < 1.0:
		return "S15"
	if absf(s0 - _s_at_time(398.0)) < 1.0:
		return "S10"
	if absf(s0 - _s_at_time(505.0)) < 1.0:
		return "S11"
	if absf(s0 - _s_at_time(558.0)) < 1.0:
		return "S12"
	return "roadside"

func _add_guardrail_chain(s0: float, s1: float, side: float) -> void:
	super._add_guardrail_chain(s0, s1, side)
	var s18 := _acceptance_distance("S18", 900.0)
	var record := {
		"source": "release_s18_junction" if _base_rails_reused else "release_lower",
		"s0": s0,
		"s1": s1,
		"side": side,
		"junction_bridge": s0 >= s18 + 14.0 and s0 <= s18 + 18.0,
	}
	_release_rail_records.append(record)
	_new_rail_records.append(record.duplicate(true))

func _build_guardrails() -> void:
	if _base_guardrail_groups_present():
		_base_rails_reused = true
		_reused_rail_spans = _matched_base_rail_spans()
		return
	_base_rails_reused = false
	super._build_guardrails()

func _base_guardrail_groups_present() -> bool:
	if base_roadside == null or not is_instance_valid(base_roadside):
		return false
	if int(base_roadside.get_meta("saisies_geo_roadside_beam_count", 0)) > 0 and int(base_roadside.get_meta("saisies_geo_roadside_post_count", 0)) > 0:
		return true
	for node in base_roadside.find_children("*", "", true, false):
		var node_name := String(node.name)
		if node_name.begins_with("SaisiesGeoGuardBeam") or node_name.begins_with("SaisiesGeoGuardPost"):
			return true
	return false

func _matched_base_rail_spans() -> Array[Dictionary]:
	var matched: Array[Dictionary] = []
	if base_roadside == null:
		return matched
	var raw: Variant = base_roadside.get_meta("saisies_geo_roadside_span_records", [])
	if not raw is Array:
		return matched
	var labels := {
		"left_392_431": true,
		"right_660_730": true,
		"left_748_804": true,
		"right_824_861": true,
		"left_905_916": true,
	}
	for item in raw:
		if not item is Dictionary or not labels.has(String(item.get("label", ""))):
			continue
		var record: Dictionary = item.duplicate(true)
		record["source"] = "base_geo_roadside"
		record["reuse"] = true
		matched.append(record)
	return matched

func _rail_source_contract_ok() -> bool:
	if not _base_guardrail_groups_present():
		return not _new_rail_records.is_empty()
	return _base_rails_reused and _reused_rail_spans.size() == 5 and _new_rail_records.size() >= 2

func _validate_release_roadside_contract() -> void:
	var rock_ids: Dictionary = {}
	for record in _release_rock_records:
		if not String(record.get("scene", "")).is_empty():
			rock_ids[String(record["scene"])] = true
	var rocks_ok := rock_ids.has("S13") and rock_ids.has("S15")
	var rails_ok := true
	for record in _release_rail_records:
		var side := float(record.get("side", 0.0))
		var s0 := float(record.get("s0", 0.0))
		var s1 := float(record.get("s1", 0.0))
		var sample_s := (s0 + s1) * 0.5
		var road_half := route.road_width_at(sample_s) * 0.5
		var rail_edge := absf(side) * (road_half + 0.66)
		if absf(side) < 0.5 or s1 <= s0 or rail_edge <= road_half + 0.30:
			rails_ok = false
	var junction_ok := _junction_rail_clearance_ok()
	var branch := get_node_or_null("SaisiesLowerJunctionBranch") as MeshInstance3D
	var branch_drape_ok := branch == null or bool(branch.get_meta("saisies_release_junction_branch_draped", false))
	var landmark_ok := bool(get_meta("saisies_landmark_clearance_ok", false)) and bool(get_meta("saisies_landmark_camera_visibility_ok", false))
	var rail_source_ok := _rail_source_contract_ok()
	var contract_ok := rocks_ok and rails_ok and junction_ok and branch_drape_ok and landmark_ok and rail_source_ok
	set_meta("saisies_release_roadside_contract_ok", contract_ok)
	set_meta("saisies_release_roadside_rock_contract_ok", rocks_ok)
	set_meta("saisies_release_roadside_rail_contract_ok", rails_ok)
	set_meta("saisies_release_roadside_base_rail_groups_present", _base_guardrail_groups_present())
	set_meta("saisies_release_roadside_base_rails_reused", _base_rails_reused)
	set_meta("saisies_release_roadside_reused_rail_spans", _reused_rail_spans.duplicate(true))
	set_meta("saisies_release_roadside_new_rail_records", _new_rail_records.duplicate(true))
	set_meta("saisies_release_roadside_rail_source_contract_ok", rail_source_ok)
	set_meta("saisies_release_roadside_junction_rail_contract_ok", junction_ok)
	set_meta("saisies_release_junction_branch_drape_ok", branch_drape_ok)
	set_meta("saisies_release_roadside_rock_records", _release_rock_records.duplicate(true))
	set_meta("saisies_release_roadside_rail_records", _release_rail_records.duplicate(true))
	set_meta("saisies_release_roadside_landmark_contract_ok", landmark_ok)
	var branch_pending := branch != null and not branch_drape_ok
	if not contract_ok and not branch_pending:
		push_error("Saisies release roadside geometry contract failed: rocks=%s rails=%s junction=%s landmarks=%s rail_source=%s" % [rocks_ok, rails_ok, junction_ok, landmark_ok, rail_source_ok])

func _junction_rail_clearance_ok() -> bool:
	if route == null:
		return false
	var s18 := _acceptance_distance("S18", 900.0)
	var origin := _route_point(s18, 0.0, 0.0) + route.left_at(s18) * 14.0
	var branch_axis := route.left_at(s18)
	var road_axis := route.tangent_at(s18)
	for record in _release_rail_records:
		var s0 := float(record["s0"])
		var s1 := float(record["s1"])
		var side := float(record["side"])
		for fraction in [0.0, 0.5, 1.0]:
			var sample_s := lerpf(s0, s1, float(fraction))
			var u := side * (route.road_width_at(sample_s) * 0.5 + 0.66)
			var local := _route_point(sample_s, u, 0.0) - origin
			var branch_distance := local.dot(branch_axis)
			var throat_distance := absf(local.dot(road_axis))
			if branch_distance > -1.0 and branch_distance < 36.0 and throat_distance < 4.2:
				return false
	return true

