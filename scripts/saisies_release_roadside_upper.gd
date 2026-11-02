class_name SaisiesReleaseRoadsideUpper
extends "res://scripts/saisies_upper_scenery.gd"

## Release-only upper scenery subclass.  The base module calls its tree factory
## even when include_trees=false; the release forest owns all tree assets, so
## make that call an intentional no-op to keep startup/cache work bounded.

var base_roadside: Node
var ground_sampler: RefCounted
var _base_rails_reused := false
var _reused_rail_spans: Array[Dictionary] = []
var _new_rail_records: Array[Dictionary] = []
var _wall_segment_serial := 0
var _wall_body_segment_count := 0
var _wall_cap_segment_count := 0
var _wall_segment_records: Array[Dictionary] = []
var _geometry_repaired := false

func _load_tree_factory() -> void:
	_tree_broadleaf.clear()
	_tree_conifer.clear()

func _farm_specs() -> Array:
	# The inherited authoring table also contains one S04 capture at 118 s.
	# The release roadside module begins at the S05 boundary (135 s), so do not
	# clamp that earlier object onto the release start and accidentally add S04.
	var filtered: Array = []
	for spec in super._farm_specs():
		if float(spec.get("video_seconds", 135.0)) < 135.0:
			continue
		filtered.append(spec)
	return filtered

func _build_scenery() -> void:
	_reused_rail_spans.clear()
	_new_rail_records.clear()
	_wall_segment_serial = 0
	_wall_body_segment_count = 0
	_wall_cap_segment_count = 0
	_wall_segment_records.clear()
	_geometry_repaired = false
	super._build_scenery()
	# Keep the inherited metadata honest after the shared builder has finished.
	set_meta("saisies_upper_scene_ids", ["S05", "S06", "S07", "S08", "S09"])
	# The shared upper module exposes readiness as a property; the release
	# wrapper consumes metadata so it can gate the ground audit uniformly.
	set_meta("saisies_upper_scenery_ready", upper_scenery_ready)
	set_meta("saisies_upper_roadside_contract_ok", _validate_upper_roadside_contract())
	set_meta("saisies_release_roadside_base_rail_groups_present", _base_guardrail_groups_present())
	set_meta("saisies_release_roadside_base_rails_reused", _base_rails_reused)
	set_meta("saisies_release_roadside_reused_rail_spans", _reused_rail_spans.duplicate(true))
	set_meta("saisies_release_roadside_new_rail_records", _new_rail_records.duplicate(true))
	set_meta("saisies_release_roadside_rail_source_contract_ok", _rail_source_contract_ok())
	set_meta("saisies_release_wall_segment_count", _wall_body_segment_count + _wall_cap_segment_count)
	set_meta("saisies_release_wall_body_segment_count", _wall_body_segment_count)
	set_meta("saisies_release_wall_cap_segment_count", _wall_cap_segment_count)

func _add_box_segment(parent: Node3D, a: Vector3, b: Vector3, width: float, height: float, material: Material, node_name: String) -> MeshInstance3D:
	var instance := super._add_box_segment(parent, a, b, width, height, material, node_name)
	if node_name.begins_with("SaisiesS08RightParapet") or node_name.begins_with("SaisiesS09StoneBlock") or node_name.begins_with("SaisiesS09StoneCap"):
		_wall_segment_serial += 1
		var is_cap := node_name.ends_with("Cap")
		if is_cap:
			_wall_cap_segment_count += 1
		else:
			_wall_body_segment_count += 1
		instance.name = "%s_%06d" % [node_name, _wall_segment_serial]
		instance.set_meta("saisies_release_wall_segment", true)
		instance.set_meta("saisies_release_wall_role", "cap" if is_cap else "body")
		var pair_id := int(floor(float(_wall_segment_serial - 1) / 2.0))
		instance.set_meta("saisies_release_wall_pair_id", pair_id)
		_wall_segment_records.append({
			"node": instance,
			"a": a,
			"b": b,
			"width": width,
			"height": height,
			"role": "cap" if is_cap else "body",
			"pair_id": pair_id,
		})
	return instance

## Refit release walls/foundations after the independent visible-terrain cache
## has warmed.  Wall bodies retain their authored top profile, while each
## paired cap follows the same per-endpoint outward shift around route bends.
## Foundation burial remains the declared authored depth rather than a generic
## surface clamp.
func repair_release_geometry_with_sampler(sampler: RefCounted) -> bool:
	if _geometry_repaired or sampler == null or not sampler.has_method("fit_mesh_bottom_to_sampler"):
		return false
	ground_sampler = sampler
	var changed := false
	var foundation_repairs := 0
	var cut_slope_repairs := 0
	var cut_slope_misses := 0
	for node in find_children("*", "Node3D", true, false):
		var name := String(node.name)
		if not name.begins_with("SaisiesUpperFarm_"):
			continue
		var farm := node as Node3D
		var foundation := _first_direct_mesh(farm)
		if foundation == null:
			continue
		var burial_depth := maxf(float(farm.get_meta("saisies_farm_foundation_burial_m", 0.0)), 0.0)
		if bool(sampler.call("fit_mesh_bottom_to_sampler", foundation, burial_depth)):
			foundation_repairs += 1
			changed = true
	var cut_slope := find_child("SaisiesS08LeftCutSlope", true, false) as MeshInstance3D
	if cut_slope != null and sampler.has_method("fit_cut_slope_inner_to_sampler"):
		if bool(sampler.call("fit_cut_slope_inner_to_sampler", cut_slope, 0.03)):
			cut_slope_repairs += 1
			changed = true
		else:
			cut_slope_misses += 1
	var wall_repairs := 0
	var wall_misses := 0
	var pairs: Dictionary = {}
	for record in _wall_segment_records:
		var pair_id := int(record.get("pair_id", -1))
		if pair_id < 0:
			continue
		var group: Array = pairs.get(pair_id, [])
		group.append(record)
		pairs[pair_id] = group
	for pair_id in pairs.keys():
		var group: Array = pairs[pair_id]
		var body: Dictionary = {}
		var cap: Dictionary = {}
		for record in group:
			if String(record.get("role", "")) == "body":
				body = record
			else:
				cap = record
		if body.is_empty():
			continue
		var body_node := body.get("node") as MeshInstance3D
		if body_node == null or not is_instance_valid(body_node):
			continue
		var a: Vector3 = body["a"]
		var b: Vector3 = body["b"]
		var shift_a := _wall_outward_shift(a)
		var shift_b := _wall_outward_shift(b)
		var shifted_a := a + shift_a
		var shifted_b := b + shift_b
		# Check the segment chord itself after endpoint shifts.  If a bend still
		# cuts inside the road at its midpoint, apply that outward correction to
		# both endpoints and therefore to the paired cap as one rigid span.
		var midpoint := (shifted_a + shifted_b) * 0.5
		var midpoint_shift := _wall_outward_shift(midpoint)
		shifted_a += midpoint_shift
		shifted_b += midpoint_shift
		_set_box_segment_transform(body_node, shifted_a, shifted_b, float(body["width"]), float(body["height"]))
		if not bool(sampler.call("fit_mesh_bottom_to_sampler", body_node, 0.03)):
			wall_misses += 1
		else:
			wall_repairs += 1
			changed = true
		if not cap.is_empty():
			var cap_node := cap.get("node") as MeshInstance3D
			if cap_node != null and is_instance_valid(cap_node):
				var cap_a: Vector3 = cap["a"]
				var cap_b: Vector3 = cap["b"]
				_set_box_segment_transform(cap_node, cap_a + shift_a + midpoint_shift, cap_b + shift_b + midpoint_shift, float(cap["width"]), float(cap["height"]))
				cap_node.set_meta("saisies_release_wall_geometry_repaired", true)
		set_meta("saisies_release_wall_last_pair", pair_id)
	set_meta("saisies_release_wall_foundation_repairs", foundation_repairs)
	set_meta("saisies_release_cut_slope_repairs", cut_slope_repairs)
	set_meta("saisies_release_cut_slope_repair_misses", cut_slope_misses)
	set_meta("saisies_release_wall_geometry_repairs", wall_repairs)
	set_meta("saisies_release_wall_geometry_misses", wall_misses)
	_geometry_repaired = true
	set_meta("saisies_release_wall_geometry_repaired", true)
	set_meta("saisies_upper_roadside_contract_ok", _validate_upper_roadside_contract())
	return changed

func _first_direct_mesh(node: Node3D) -> MeshInstance3D:
	if node == null:
		return null
	for child in node.get_children():
		var mesh := child as MeshInstance3D
		if mesh != null:
			return mesh
	return null

func _set_box_segment_transform(instance: MeshInstance3D, a: Vector3, b: Vector3, width: float, height: float) -> void:
	if instance == null:
		return
	var length := a.distance_to(b)
	var basis := _full_segment_basis(a, b)
	instance.transform = Transform3D(basis.scaled_local(Vector3(width, height, length)), (a + b) * 0.5)

func _wall_outward_shift(point: Vector3) -> Vector3:
	if route == null or not route.has_method("distance_for_position"):
		return Vector3.ZERO
	var station := clampf(float(route.call("distance_for_position", point)), 0.0, route.length_m)
	var center: Vector3 = route.call("pos_at", station)
	var left: Vector3 = route.call("left_at", station)
	var lateral := left.dot(point - center)
	var road_half := float(route.call("road_width_at", station)) * 0.5
	var required := road_half + 0.40
	var delta := maxf(required - absf(lateral), 0.0)
	if delta <= 0.0:
		return Vector3.ZERO
	var side := 1.0 if lateral >= 0.0 else -1.0
	return left * side * delta

func _build_guardrail_range(parent: Node3D, start: float, finish: float, side: float) -> Dictionary:
	if finish <= start:
		return {"beams": 0, "alignment": 1.0, "upright": 1.0}
	if _base_guardrail_groups_present():
		_base_rails_reused = true
		_reused_rail_spans.append({
			"source": "base_geo_roadside",
			"s0": start,
			"s1": finish,
			"side": side,
			"span": "upper_release_match",
		})
		return {"beams": 0, "alignment": 1.0, "upright": 1.0}
	var built := super._build_guardrail_range(parent, start, finish, side)
	_new_rail_records.append({
		"source": "release_upper",
		"s0": start,
		"s1": finish,
		"side": side,
		"beams": int(built.get("beams", 0)),
	})
	return built

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

func _rail_source_contract_ok() -> bool:
	if not _base_guardrail_groups_present():
		return not _new_rail_records.is_empty()
	return _base_rails_reused and not _reused_rail_spans.is_empty()

func _validate_upper_roadside_contract() -> bool:
	if route == null or not route.has_method("distance_for_position"):
		return false
	var checked := 0
	for node in find_children("*", "MeshInstance3D", true, false):
		var name := String(node.name)
		if not (name.begins_with("SaisiesS08RightParapet") or name.begins_with("SaisiesS09StoneBlock") or name.begins_with("SaisiesS09StoneCap") or name == "SaisiesUpperGuardPost"):
			continue
		var mesh := node as MeshInstance3D
		if mesh == null:
			continue
		var geometry_center := mesh.global_transform * mesh.get_aabb().get_center()
		var station := clampf(float(route.call("distance_for_position", geometry_center)), 0.0, route.length_m)
		var center := route.pos_at(station)
		var lateral := absf(route.left_at(station).dot(geometry_center - center))
		var road_half := route.road_width_at(station) * 0.5
		if lateral <= road_half + 0.30:
			return false
		checked += 1
	return checked > 0

