extends Node3D

## Bounded S03 left-forest LOD replacement over the accepted R22 scene.
##
## Diagnosis of R22 S03 left slope:
## 1. Upper-left grey repetitive faceted crown wall (x: 0..360, y: 40..400) is
##    owned by S01Landscape/S01LandscapeRefinement/S01MixedCanopy/
##    S01ForestClosedCrownMass (S01Landscape_closed_crown_0..2), whose 8-sided
##    low-poly ellipsoid lobes were authored for far S01 views (~1.2 km away)
##    but sit only 340..718 m from the S03 camera.
## 2. Lower-left sparse noisy trees are owned by World/Forest chunks
##    SaisiesGeoForest_* at x=0, z=-7..-4 and x=1, z=-6, which leave a large
##    bare gap across the mid/lower left slope (z=-935..-1240).
##
## This module gates visibility by distance to the S03 camera so S01 and S02
## retain their exact original representations, and replaces the bounded S03
## left-slope subset with layered SaisiesTrees conifer and broadleaf MultiMeshes
## sampled on the actual visible ground triangles.

const TREE_FACTORY := preload("res://scripts/saisies_trees.gd")

@export var flowers_review_path: NodePath = NodePath("../FlowersReview")
@export var world_path: NodePath = NodePath("../FlowersReview/SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/World")
@export var s01_landscape_path: NodePath = NodePath("../FlowersReview/SignsReview/LiftReview/GroundReview/CafeReview/S03Review/S02Review/S01Review/S01Landscape")
@export var enable_refinement := true

const SOURCE_FRAME := "video/saisies_analysis/acceptance/S03_f001798.png"
const SOURCE_SHA256 := "184ee032aef47be5d52b5d5c6379300dc4dca85054ada0b93ef07ed8ca043e10"
const CAMERA_GATE_CENTER := Vector3(138.9204, -65.5922, -839.3978)
const CAMERA_GATE_FULL_M := 260.0
const CAMERA_GATE_END_M := 420.0
const SELECTED_FOREST_CHUNKS := [
	Vector2i(0, -7),
	Vector2i(0, -6),
	Vector2i(0, -5),
	Vector2i(0, -4),
	Vector2i(1, -6),
]
const SELECTED_FAMILY_PREFIXES := [
	"conifer_00", "conifer_01", "conifer_02",
	"broadleaf_00", "broadleaf_01", "broadleaf_02",
]
const S01_CROWN_NODE_NAMES := [
	"S01Landscape_closed_crown_0",
	"S01Landscape_closed_crown_1",
	"S01Landscape_closed_crown_2",
]
const S01_CONIFER_NODE_NAMES := [
	"S01Landscape_conifer_0",
	"S01Landscape_conifer_1",
	"S01Landscape_conifer_2",
]
## The R22 S01 crown mass is a separate far representation of the same
## conifer roots.  Only this measured rectangle is close enough to S03 to
## replace; crowns outside it must remain available for S01/S02.
const S01_CROWN_REPLACEMENT_BOUNDS := Rect2(142.0, -1555.0, 116.0, 390.0)
const ROOT_BURY_M := 0.04
const FOREST_SCREEN_ROI := Rect2(-80.0, 24.0, 520.0, 470.0)
const LEFT_SIGN_WORLD_XZ := Vector2(163.5, -907.5)
const LEFT_SIGN_CLEARANCE_M := 16.5
const CLOSE_CAMERA_WORLD := Vector3(156.0, -58.0, -862.0)
const CLOSE_TARGET_WORLD := Vector3(188.0, -28.0, -1045.0)

var _flowers_review: Node
var _world: Node3D
var _landscape: Node
var _forest_root: Node3D
var _camera: Camera3D
var _replacement: Node3D
var _old_nodes: Array[MultiMeshInstance3D] = []
var _old_visibility: Dictionary = {}
var _s01_crown_filtered_nodes: Array[MultiMeshInstance3D] = []
var _s01_crown_source_records: Array[Dictionary] = []
var _s01_crown_spec_transform_cache: Dictionary = {}
var _source_records: Array[Dictionary] = []
var _replacement_records: Array[Dictionary] = []
var _projection_records: Array[Dictionary] = []
var _hidden_paths: Array[String] = []
var _built := false
var _attempts := 0
var _lod_active := false
var _old_count := 0
var _s01_crown_replaced_count := 0
var _s01_crown_total_count := 0
var _s01_crown_preserved_count := 0
var _s01_crown_selected_count := 0
var _s01_crown_transform_source_counts: Dictionary = {}
var _new_count := 0
var _extra_count := 0
var _conifer_count := 0
var _broadleaf_count := 0
var _front_edge_conifer_count := 0
var _front_edge_mix_count := 0
var _tree_meshes: Dictionary = {}
var _tree_surface0_contact_points: Dictionary = {}
var _surface0_contact_correction_count := 0
var _surface0_max_positive_clearance_m := 0.0
var _surface0_max_burial_m := 0.0

func _ready() -> void:
	process_priority = -85
	if _has_command_line_flag("--s03-forest-off"):
		enable_refinement = false
	call_deferred("_try_build")

func _process(_delta: float) -> void:
	if not _built or not enable_refinement or _camera == null:
		return
	_update_lod_gate()

func _try_build() -> void:
	if _built:
		return
	_flowers_review = get_node_or_null(flowers_review_path)
	_world = get_node_or_null(world_path) as Node3D
	_landscape = get_node_or_null(s01_landscape_path)
	if _flowers_review == null or _world == null or _landscape == null:
		_retry("S03 forest dependencies are incomplete")
		return
	if not bool(_flowers_review.get_meta("saisies_s03_flowers_review_ready", false)):
		_retry("S03 forest is waiting for frame-wise R22 flowers readiness")
		return
	if not bool(_landscape.get_meta("saisies_s01_landscape_ready", false)):
		_retry("S03 forest is waiting for S01Landscape readiness")
		return
	_forest_root = _world.get_node_or_null("Forest") as Node3D
	var rig := _world.get_node_or_null("CameraRig") as Node3D
	_camera = rig.get_node_or_null("Camera3D") as Camera3D if rig != null else null
	if _forest_root == null or _camera == null:
		_retry("S03 forest could not resolve World/Forest or Camera3D")
		return
	if not _landscape.has_method("_sample_baked_ground"):
		_fail_and_hold("S03 forest requires S01Landscape._sample_baked_ground")
		return
	if not enable_refinement:
		_publish_disabled_state()
		_built = true
		return
	if not _build_candidate():
		_fail_and_hold("S03 forest could not build finite authored replacement")
		return
	_built = true
	_update_lod_gate()
	_publish_ready_state()

func _build_candidate() -> bool:
	_old_nodes.clear()
	_old_visibility.clear()
	_s01_crown_filtered_nodes.clear()
	_s01_crown_source_records.clear()
	_s01_crown_spec_transform_cache.clear()
	_source_records.clear()
	_replacement_records.clear()
	_projection_records.clear()
	_hidden_paths.clear()
	_old_count = 0
	_s01_crown_replaced_count = 0
	_s01_crown_total_count = 0
	_s01_crown_preserved_count = 0
	_s01_crown_selected_count = 0
	_s01_crown_transform_source_counts.clear()
	_new_count = 0
	_extra_count = 0
	_conifer_count = 0
	_broadleaf_count = 0
	_front_edge_conifer_count = 0
	_front_edge_mix_count = 0
	_tree_surface0_contact_points.clear()
	_surface0_contact_correction_count = 0
	_surface0_max_positive_clearance_m = 0.0
	_surface0_max_burial_m = 0.0
	_replacement = Node3D.new()
	_replacement.name = "S03ForestRefinementCandidate"
	_replacement.set_meta("saisies_s03_forest_owner", "S01ForestClosedCrownMass + World/Forest x=0 z=-7..-4, x=1 z=-6")
	_replacement.set_meta("saisies_s03_forest_mesh_source", "res://scripts/saisies_trees.gd")
	add_child(_replacement)
	_tree_meshes = _load_tree_meshes()
	if _tree_meshes.is_empty():
		return false
	var selected_nodes := _resolve_selected_world_forest_nodes()
	if selected_nodes.is_empty():
		return false
	var grouped: Dictionary = {}
	for old_node in selected_nodes:
		if not _collect_world_forest_node(old_node, grouped):
			return false
	if not _collect_s01_upper_slope_nodes(grouped):
		return false
	_append_layered_slope_canopy(grouped)
	if _old_count <= 0 or grouped.is_empty():
		return false
	if not _build_replacement_multimeshes(grouped):
		return false
	return _all_geometry_finite()

func _resolve_selected_world_forest_nodes() -> Array[MultiMeshInstance3D]:
	var selected: Array[MultiMeshInstance3D] = []
	for family_prefix in SELECTED_FAMILY_PREFIXES:
		for chunk in SELECTED_FOREST_CHUNKS:
			var chunk_vec: Vector2i = chunk
			var node_name := "SaisiesGeoForest_%s_%d_%d" % [family_prefix, chunk_vec.x, chunk_vec.y]
			var node := _forest_root.get_node_or_null(node_name) as MultiMeshInstance3D
			if node != null and node.multimesh != null and node.multimesh.mesh != null:
				selected.append(node)
	return selected

func _register_hidden_node(node: MultiMeshInstance3D) -> void:
	if not _old_nodes.has(node):
		_old_nodes.append(node)
		_old_visibility[node] = node.visible
		_hidden_paths.append(str(node.get_path()))

func _collect_world_forest_node(old_node: MultiMeshInstance3D, grouped: Dictionary) -> bool:
	var positions := old_node.get_meta("forest_authored_positions", PackedVector3Array()) as PackedVector3Array
	var scales := old_node.get_meta("forest_authored_scales", PackedVector3Array()) as PackedVector3Array
	var local_transforms: Array = old_node.get_meta("forest_authored_local_transforms", [])
	if positions.is_empty() or local_transforms.size() != positions.size():
		return false
	var family_key := String(old_node.get_meta("forest_species", ""))
	var parts := family_key.split("_")
	if parts.size() != 2:
		return false
	var family := String(parts[0])
	var variant := clampi(int(parts[1]), 0, 2)
	var old_bounds := old_node.multimesh.mesh.get_aabb()
	_register_hidden_node(old_node)
	for index in positions.size():
		var source_position: Vector3 = positions[index]
		var source_local: Transform3D = local_transforms[index]
		var source_transform := old_node.global_transform * source_local
		var sample := _sample_ground(Vector2(source_position.x, source_position.z))
		if sample.is_empty():
			return false
		var ground: Vector3 = sample["position"]
		if not source_position.is_finite() or not source_transform.is_finite() or not ground.is_finite():
			return false
		var source_scale := scales[index] if index < scales.size() else Vector3.ONE
		var stable_id := _stable_id(old_node.name, index)
		var taper := _cafe_side_height_taper(ground.x, ground.z)
		var width_scale := clampf(absf(source_scale.x) * lerpf(0.88, 1.16, _hash01(stable_id, 17)), 0.50, 1.50)
		var height_scale := clampf(absf(source_scale.y) * lerpf(0.84, 1.18, _hash01(stable_id, 23)) * taper, 0.45, 1.58)
		var source_yaw := source_transform.basis.get_euler().y
		var yaw := source_yaw + lerpf(-0.24, 0.24, _hash01(stable_id, 29))
		var replacement_family := family
		var replacement_variant := variant
		var placement_ground := ground
		var front_edge_mix := false
		var source_record := {
			"path": str(old_node.get_path()),
			"index": index,
			"family": family,
			"variant": variant,
			"source_position": source_position,
			"source_transform": source_transform,
			"source_mesh_aabb": old_bounds,
			"sampled_ground": ground,
			"ground_source": String(sample.get("source", "S01Landscape._sample_ground")),
		}
		_source_records.append(source_record)
		_old_count += 1
		if not _is_clear_of_s03_landmarks(Vector2(ground.x, ground.z)):
			continue
		if _is_low_front_slope_position(ground):
			if family == "conifer":
				_front_edge_conifer_count += 1
			# Recede/advance the footline by a small authored offset, then resample
			# the same terrain so the root remains on the visible slope.  The
			# deterministic height variation breaks the former even lower edge.
			var edge_offset := Vector2(
				lerpf(-1.8, 1.8, _hash01(stable_id, 131)),
				lerpf(-2.8, 2.8, _hash01(stable_id, 137))
			)
			var edge_xz := Vector2(ground.x, ground.z) + edge_offset
			if _is_clear_of_s03_landmarks(edge_xz):
				var edge_sample := _sample_ground(edge_xz)
				if not edge_sample.is_empty():
					placement_ground = edge_sample["position"]
			height_scale = clampf(height_scale * lerpf(0.80, 1.12, _hash01(stable_id, 139)), 0.40, 1.42)
			front_edge_mix = family == "conifer" and _hash01(stable_id, 143) < 0.34
			if front_edge_mix:
				_front_edge_mix_count += 1
				replacement_family = "broadleaf"
				replacement_variant = (variant + int(_hash01(stable_id, 149) * 3.0)) % 3
				height_scale = clampf(height_scale * lerpf(0.56, 0.78, _hash01(stable_id, 151)), 0.38, 0.92)
				width_scale = clampf(height_scale * lerpf(0.86, 1.18, _hash01(stable_id, 157)), 0.52, 1.16)
		source_record["replacement_family"] = replacement_family
		source_record["replacement_variant"] = replacement_variant
		source_record["replacement_ground"] = placement_ground
		source_record["front_edge_mix"] = front_edge_mix
		_append_group_item(grouped, replacement_family, replacement_variant, placement_ground, width_scale, height_scale, yaw, source_record, false)
	return true

func _collect_s01_upper_slope_nodes(grouped: Dictionary) -> bool:
	# The closed-crown nodes contain the entire 4003-instance S01 ridge. Build
	# local filtered copies first, so the active S03 gate hides the originals
	# without deleting the 3373 crowns outside the measured replacement bounds.
	for variant_idx in S01_CROWN_NODE_NAMES.size():
		var crown_name: String = S01_CROWN_NODE_NAMES[variant_idx]
		var crown_node := _landscape.find_child(crown_name, true, false) as MultiMeshInstance3D
		var conifer_name: String = S01_CONIFER_NODE_NAMES[variant_idx]
		var conifer_node := _landscape.find_child(conifer_name, true, false) as MultiMeshInstance3D
		if crown_node == null or crown_node.multimesh == null or crown_node.multimesh.mesh == null:
			return false
		if conifer_node == null or conifer_node.multimesh == null or conifer_node.multimesh.mesh == null:
			return false
		if not _build_filtered_s01_crown_copy(crown_node, conifer_node, variant_idx):
			return false
	for variant_idx in S01_CONIFER_NODE_NAMES.size():
		var conifer_name: String = S01_CONIFER_NODE_NAMES[variant_idx]
		var conifer_node := _landscape.find_child(conifer_name, true, false) as MultiMeshInstance3D
		var crown_name: String = S01_CROWN_NODE_NAMES[variant_idx]
		var crown_node := _landscape.find_child(crown_name, true, false) as MultiMeshInstance3D
		if conifer_node == null or conifer_node.multimesh == null or conifer_node.multimesh.mesh == null:
			return false
		if crown_node == null or crown_node.multimesh == null:
			return false
		var mm := conifer_node.multimesh
		var old_bounds := mm.mesh.get_aabb()
		var fallback_specs := _build_s01_crown_spec_transforms(variant_idx)
		for index in mm.instance_count:
			# Headless MultiMesh reads can expose identity placeholders even though
			# native rendering has the authored buffer. Reuse the same transform
			# resolver as the filtered crown copy so authored bounds stay stable.
			var source := _read_s01_crown_world_transform(crown_node, conifer_node, index, fallback_specs)
			if source.is_empty():
				return false
			var world_xf: Transform3D = source["world_transform"]
			var pos := world_xf.origin
			if not _is_s01_crown_replacement_position(pos):
				continue
			var sample := _sample_ground(Vector2(pos.x, pos.z))
			if sample.is_empty():
				continue
			var ground: Vector3 = sample["position"]
			var stable_id := _stable_id(conifer_name, index)
			var source_record := {
				"path": str(conifer_node.get_path()),
				"index": index,
				"family": "conifer",
				"variant": variant_idx,
				"source_position": pos,
				"source_transform": world_xf,
				"source_mesh_aabb": old_bounds,
				"sampled_ground": ground,
				"ground_source": String(sample.get("source", "S01Landscape._sample_ground")),
			}
			_source_records.append(source_record)
			_old_count += 1
			_s01_crown_replaced_count += 1
			# Break up the dense 7.5m x 8.5m S01 lattice on the steep back-slope
			# while keeping full irregular skyline and mid-ridge coverage.
			var keep_prob := 0.56 if ground.z < -1310.0 else 0.78
			if _hash01(stable_id, 61) > keep_prob:
				continue
			var jitter_angle := _hash01(stable_id, 67) * TAU
			var jitter_radius := lerpf(0.6, 2.6, _hash01(stable_id, 71))
			var jxz := Vector2(ground.x + cos(jitter_angle) * jitter_radius, ground.z + sin(jitter_angle) * jitter_radius)
			var jsample := _sample_ground(jxz)
			var placed_ground: Vector3 = jsample["position"] if not jsample.is_empty() else ground
			var taper := _cafe_side_height_taper(placed_ground.x, placed_ground.z)
			var is_lower_mix := placed_ground.x > 222.0 and placed_ground.z > -1290.0 and _hash01(stable_id, 73) < 0.28
			var fam := "broadleaf" if is_lower_mix else "conifer"
			var var_id := (variant_idx + int(_hash01(stable_id, 79) * 3.0)) % 3
			var h_scale := lerpf(0.82, 1.48, _hash01(stable_id, 83)) * taper
			var w_scale := h_scale * lerpf(0.84, 1.14, _hash01(stable_id, 89))
			if fam == "broadleaf":
				h_scale = clampf(h_scale * 0.74, 0.48, 0.96)
				w_scale = clampf(w_scale * 0.92, 0.62, 1.12)
			var yaw := _hash01(stable_id, 97) * TAU
			_append_group_item(grouped, fam, var_id, placed_ground, w_scale, h_scale, yaw, source_record, false)
	if _s01_crown_selected_count != _s01_crown_replaced_count:
		push_error("S03 forest crown/conifer bound mismatch: crowns=%d conifers=%d" % [_s01_crown_selected_count, _s01_crown_replaced_count])
		return false
	return _s01_crown_replaced_count > 0

func _build_filtered_s01_crown_copy(crown_node: MultiMeshInstance3D, fallback_node: MultiMeshInstance3D, variant_idx: int) -> bool:
	var source_mm := crown_node.multimesh
	if source_mm == null or source_mm.mesh == null:
		return false
	var fallback_specs := _build_s01_crown_spec_transforms(variant_idx)
	var preserved_transforms: Array[Transform3D] = []
	var preserved_records: Array[Dictionary] = []
	var retained_source_indices := PackedInt32Array()
	for index in source_mm.instance_count:
		var source := _read_s01_crown_world_transform(crown_node, fallback_node, index, fallback_specs)
		if source.is_empty():
			push_error("S03 forest could not read S01 crown transform %s[%d]" % [crown_node.name, index])
			return false
		var world_transform: Transform3D = source["world_transform"]
		var local_transform: Transform3D = source["local_transform"]
		var position := world_transform.origin
		if not world_transform.is_finite() or not position.is_finite():
			return false
		var selected := _is_s01_crown_replacement_position(position)
		var record := {
			"path": str(crown_node.get_path()),
			"index": index,
			"variant": variant_idx,
			"selected_for_s03": selected,
			"source": String(source["source"]),
			"local_transform": local_transform,
			"world_transform": world_transform,
			"position": position,
		}
		_s01_crown_source_records.append(record)
		_s01_crown_total_count += 1
		var source_name := String(source["source"])
		_s01_crown_transform_source_counts[source_name] = int(_s01_crown_transform_source_counts.get(source_name, 0)) + 1
		if selected:
			_s01_crown_selected_count += 1
		else:
			preserved_transforms.append(local_transform)
			preserved_records.append(record)
			retained_source_indices.append(index)
			_s01_crown_preserved_count += 1
	if preserved_transforms.is_empty():
		return false
	var filtered_mm := MultiMesh.new()
	filtered_mm.transform_format = MultiMesh.TRANSFORM_3D
	filtered_mm.mesh = source_mm.mesh
	filtered_mm.instance_count = preserved_transforms.size()
	for index in preserved_transforms.size():
		filtered_mm.set_instance_transform(index, preserved_transforms[index])
	var filtered_instance := MultiMeshInstance3D.new()
	filtered_instance.name = "S03RetainedCrowns_%d" % variant_idx
	filtered_instance.multimesh = filtered_mm
	filtered_instance.top_level = true
	filtered_instance.visibility_range_end = crown_node.visibility_range_end
	filtered_instance.visibility_range_end_margin = crown_node.visibility_range_end_margin
	filtered_instance.cast_shadow = crown_node.cast_shadow
	filtered_instance.set_meta("saisies_s03_forest_s01_crown_filtered_copy", true)
	filtered_instance.set_meta("saisies_s03_forest_s01_crown_source_path", str(crown_node.get_path()))
	filtered_instance.set_meta("saisies_s03_forest_retained_source_path", str(crown_node.get_path()))
	filtered_instance.set_meta("saisies_s03_forest_s01_crown_variant", variant_idx)
	filtered_instance.set_meta("saisies_s03_forest_s01_crown_preserved_count", preserved_transforms.size())
	filtered_instance.set_meta("saisies_s03_forest_s01_crown_retained_source_indices", retained_source_indices)
	filtered_instance.set_meta("saisies_s03_forest_retained_source_indices", retained_source_indices)
	filtered_instance.set_meta("saisies_s03_forest_s01_crown_transform_source_counts", _s01_crown_transform_source_counts.duplicate(true))
	filtered_instance.set_meta("saisies_s03_forest_s01_crown_instance_records", preserved_records)
	_replacement.add_child(filtered_instance)
	filtered_instance.global_transform = crown_node.global_transform
	_s01_crown_filtered_nodes.append(filtered_instance)
	_register_hidden_node(crown_node)
	return true

func _read_s01_crown_world_transform(crown_node: MultiMeshInstance3D, fallback_node: MultiMeshInstance3D, index: int, fallback_specs: Array) -> Dictionary:
	var source_mm := crown_node.multimesh
	if source_mm != null and index < source_mm.instance_count:
		var source_local := source_mm.get_instance_transform(index)
		if _is_valid_s01_instance_transform(source_local):
			return {
				"source": "crown_multimesh",
				"local_transform": source_local,
				"world_transform": crown_node.global_transform * source_local,
			}
	var metadata_transform := _read_s01_crown_transform_metadata(crown_node, index)
	if not metadata_transform.is_empty():
		return metadata_transform
	if fallback_node != null and fallback_node.multimesh != null and index < fallback_node.multimesh.instance_count:
		var fallback_local := fallback_node.multimesh.get_instance_transform(index)
		if _is_valid_s01_instance_transform(fallback_local):
			var world_transform := fallback_node.global_transform * fallback_local
			return {
				"source": "conifer_same_root_multimesh",
				"local_transform": crown_node.global_transform.affine_inverse() * world_transform,
				"world_transform": world_transform,
			}
	if index < fallback_specs.size():
		var world_transform: Transform3D = fallback_specs[index]
		return {
			"source": "s01_tree_specs_fallback",
			"local_transform": crown_node.global_transform.affine_inverse() * world_transform,
			"world_transform": world_transform,
		}
	return {}

func _read_s01_crown_transform_metadata(crown_node: MultiMeshInstance3D, index: int) -> Dictionary:
	for key in ["saisies_s01_crown_local_transforms", "saisies_s01_crown_transforms", "saisies_s01_instance_transforms"]:
		var raw: Variant = crown_node.get_meta(key, [])
		if raw is Array and index < (raw as Array).size() and (raw as Array)[index] is Transform3D:
			var local_transform: Transform3D = (raw as Array)[index]
			if _is_valid_s01_instance_transform(local_transform):
				return {
					"source": "crown_metadata",
					"local_transform": local_transform,
					"world_transform": crown_node.global_transform * local_transform,
				}
	return {}

func _build_s01_crown_spec_transforms(variant_idx: int) -> Array:
	if _s01_crown_spec_transform_cache.has(variant_idx):
		return _s01_crown_spec_transform_cache[variant_idx]
	var result: Array = []
	if not _landscape.has_method("_tree_specs"):
		return result
	var specs: Variant = _landscape.call("_tree_specs")
	if not specs is Array:
		return result
	for spec_variant in specs as Array:
		if not spec_variant is Dictionary:
			continue
		var spec: Dictionary = spec_variant
		if String(spec.get("family", "")) != "conifer" or int(spec.get("variant", -1)) != variant_idx:
			continue
		var position: Vector2 = spec.get("position", Vector2(INF, INF))
		if not position.is_finite():
			continue
		var sample := _sample_ground(position)
		if sample.is_empty():
			continue
		var ground: Vector3 = sample["position"]
		var stable_id := int(spec.get("stable_id", 0))
		var width_m := lerpf(7.2, 11.8, _hash01(stable_id, 113))
		var height_m := lerpf(10.0, 18.0, _hash01(stable_id, 127))
		var yaw := float(spec.get("yaw", 0.0))
		var basis := Basis(Vector3.UP, yaw).scaled(Vector3(width_m, height_m, width_m))
		result.append(Transform3D(basis, ground))
	_s01_crown_spec_transform_cache[variant_idx] = result
	return result

func _is_valid_s01_instance_transform(transform: Transform3D) -> bool:
	if not transform.is_finite():
		return false
	# An identity transform is the headless placeholder seen when a source
	# MultiMesh has not exposed its authored buffer yet; no S01 crown root lives
	# at world origin, so it cannot be a valid record here.
	return transform.origin.length_squared() > 0.0001 or not transform.basis.is_equal_approx(Basis.IDENTITY)

func _is_s01_crown_replacement_position(position: Vector3) -> bool:
	return S01_CROWN_REPLACEMENT_BOUNDS.has_point(Vector2(position.x, position.z))

func _append_layered_slope_canopy(grouped: Dictionary) -> void:
	var anchor_record: Dictionary = _source_records[0] if not _source_records.is_empty() else {}
	# Populate the S03 left slope (z = -936..-1420) across three woodland strata:
	# 1) Upper/mid conifer overstory with irregular tips and skyline coverage,
	# 2) Mid-slope mixed conifer + broadleaf overlap with non-grid gaps,
	# 3) Rounded lower broadleaf/shrub edge above the left roadside grass bank.
	var z_step := 7.0
	var z_count := int(floor((1420.0 - 936.0) / z_step)) + 1
	for z_idx in z_count:
		var z_base := -936.0 - float(z_idx) * z_step
		var x_min := _slope_crest_x(z_base)
		var x_max := _slope_lower_edge_x(z_base)
		if x_max <= x_min + 4.0:
			continue
		var span := x_max - x_min
		var x_step := 6.2
		var x_count := maxi(2, int(floor(span / x_step)) + 1)
		for x_idx in x_count:
			var cell_id := 50000 + z_idx * 313 + x_idx * 17
			# Deterministic non-grid gaps so the canopy has natural openings.
			var u_nom := float(x_idx) / float(maxi(1, x_count - 1))
			# Keep visible grass openings along the lower slope; the previous
			# threshold made the 719 authored extras read as a continuous curtain.
			var gap_threshold := 0.22 if u_nom < 0.72 else 0.16
			if _hash01(cell_id, 11) < gap_threshold:
				continue
			# Skip the upper-left zone already well populated by S01 conifer records,
			# except near the crest (u_nom < 0.25) and right extension (x > 238).
			var x_nom := lerpf(x_min, x_max, u_nom)
			if z_base < -1185.0 and x_nom >= 162.0 and x_nom <= 238.0 and u_nom >= 0.22 and u_nom <= 0.76:
				if _hash01(cell_id, 13) < 0.68:
					continue
			var jx := (_hash01(cell_id, 19) * 2.0 - 1.0) * 2.85
			var jz := (_hash01(cell_id, 23) * 2.0 - 1.0) * 3.10
			var x := x_nom + jx
			var z := z_base + jz
			if not _is_clear_of_s03_landmarks(Vector2(x, z)):
				continue
			var sample := _sample_ground(Vector2(x, z))
			if sample.is_empty():
				continue
			var ground: Vector3 = sample["position"]
			var u := clampf((x - x_min) / maxf(span, 1.0), 0.0, 1.0)
			var taper := _cafe_side_height_taper(x, z)
			var family := "conifer"
			var variant := int(_hash01(cell_id, 31) * 3.0) % 3
			var height_scale := 1.0
			var width_scale := 1.0
			if u >= 0.72:
				# Lower woodland edge: predominantly rounded broadleaf/shrub crowns
				# with occasional smaller conifer tips rising behind.
				var is_edge_broadleaf := _hash01(cell_id, 37) < 0.90
				family = "broadleaf" if is_edge_broadleaf else "conifer"
				if family == "broadleaf":
					var edge_t := clampf((u - 0.72) / 0.28, 0.0, 1.0)
					height_scale = lerpf(0.78, 0.34, edge_t) * lerpf(0.76, 1.22, _hash01(cell_id, 41)) * taper
					width_scale = lerpf(0.96, 0.74, edge_t) * lerpf(0.90, 1.22, _hash01(cell_id, 43))
				else:
					height_scale = lerpf(0.68, 0.98, _hash01(cell_id, 47)) * taper
					width_scale = height_scale * lerpf(0.84, 1.08, _hash01(cell_id, 53))
			elif u >= 0.46:
				# Mid-slope transition: layered mix of conifer spires above broadleaf crowns.
				var is_mid_broadleaf := _hash01(cell_id, 59) < 0.44
				family = "broadleaf" if is_mid_broadleaf else "conifer"
				if family == "broadleaf":
					height_scale = lerpf(0.64, 0.94, _hash01(cell_id, 61)) * taper
					width_scale = lerpf(0.78, 1.14, _hash01(cell_id, 67))
				else:
					height_scale = lerpf(0.88, 1.36, _hash01(cell_id, 71)) * taper
					width_scale = height_scale * lerpf(0.84, 1.12, _hash01(cell_id, 73))
			else:
				# Upper slope & skyline crest: tall irregular dark-green conifers.
				family = "conifer"
				var crest_boost := 1.14 if u < 0.24 else 1.0
				height_scale = lerpf(0.94, 1.54, _hash01(cell_id, 79)) * crest_boost * taper
				width_scale = height_scale * lerpf(0.82, 1.12, _hash01(cell_id, 83))
			height_scale = clampf(height_scale, 0.38, 1.65)
			width_scale = clampf(width_scale, 0.48, 1.55)
			var yaw := _hash01(cell_id, 89) * TAU
			var extra_record := {
				"path": str(anchor_record.get("path", "")),
				"index": int(anchor_record.get("index", 0)),
				"family": family,
				"variant": variant,
				"source_position": ground,
				"source_transform": Transform3D(Basis.IDENTITY, ground),
				"sampled_ground": ground,
				"ground_source": String(sample.get("source", "S01Landscape._sample_ground")),
				"extra": true,
			}
			_append_group_item(grouped, family, variant, ground, width_scale, height_scale, yaw, extra_record, true)
			_extra_count += 1

			# Add a low compact shrub-skirt companion along the outermost lower edge
			# so bare trunks are hidden by rounded foliage at the grass margin.
			if u >= 0.78 and _hash01(cell_id, 97) < 0.58:
				var skirt_xz := Vector2(x + lerpf(1.2, 2.8, _hash01(cell_id, 101)), z + lerpf(-1.6, 1.6, _hash01(cell_id, 103)))
				if _is_clear_of_s03_landmarks(skirt_xz):
					var skirt_sample := _sample_ground(skirt_xz)
					if not skirt_sample.is_empty():
						var skirt_ground: Vector3 = skirt_sample["position"]
						var skirt_var := (variant + 1) % 3
						var skirt_h := clampf(lerpf(0.28, 0.62, _hash01(cell_id, 107)) * taper, 0.28, 0.66)
						var skirt_w := clampf(lerpf(0.68, 0.98, _hash01(cell_id, 109)), 0.58, 1.08)
						var skirt_yaw := _hash01(cell_id, 113) * TAU
						var skirt_record := extra_record.duplicate()
						skirt_record["family"] = "broadleaf"
						skirt_record["variant"] = skirt_var
						skirt_record["sampled_ground"] = skirt_ground
						_append_group_item(grouped, "broadleaf", skirt_var, skirt_ground, skirt_w, skirt_h, skirt_yaw, skirt_record, true)
						_extra_count += 1

func _slope_crest_x(z: float) -> float:
	if z >= -1000.0:
		return lerpf(136.0, 144.0, clampf((-936.0 - z) / 64.0, 0.0, 1.0))
	elif z >= -1240.0:
		return lerpf(144.0, 162.0, clampf((-1000.0 - z) / 240.0, 0.0, 1.0))
	return lerpf(162.0, 182.0, clampf((-1240.0 - z) / 180.0, 0.0, 1.0))

func _slope_lower_edge_x(z: float) -> float:
	if z >= -1000.0:
		return lerpf(153.0, 178.0, clampf((-936.0 - z) / 64.0, 0.0, 1.0))
	elif z >= -1140.0:
		return lerpf(178.0, 228.0, clampf((-1000.0 - z) / 140.0, 0.0, 1.0))
	elif z >= -1280.0:
		return lerpf(228.0, 266.0, clampf((-1140.0 - z) / 140.0, 0.0, 1.0))
	return 268.0

func _cafe_side_height_taper(x: float, z: float) -> float:
	# Gradually reduce tree height toward the lower-right of the left slope
	# (approaching the direction sign mound and the cafe/chalets).
	var x_t := clampf((x - 185.0) / 82.0, 0.0, 1.0)
	var z_t := clampf((z - (-1060.0)) / 125.0, 0.0, 1.0)
	return lerpf(1.0, 0.64, maxf(x_t * 0.85, z_t * 0.75))

func _is_low_front_slope_position(position: Vector3) -> bool:
	# World/Forest's near lower edge is the z=-1230..-900 band beside the
	# cafe-facing slope. Keep the farther ridge conifers untouched.
	return position.x >= 58.0 and position.x <= 246.0 and position.z >= -1230.0 and position.z <= -900.0

func _is_clear_of_s03_landmarks(xz: Vector2) -> bool:
	if xz.distance_to(LEFT_SIGN_WORLD_XZ) < LEFT_SIGN_CLEARANCE_M:
		return false
	# Keep clear of the background chalets and cafe footprint on the lower right.
	if xz.y > -955.0 and xz.x > 158.0:
		return false
	if xz.y > -928.0 and xz.x > 150.0:
		return false
	var point3 := Vector3(xz.x, -68.0, xz.y)
	return _extra_clear_of_route(point3)

func _append_group_item(grouped: Dictionary, family: String, variant: int, ground: Vector3, width_scale: float, height_scale: float, yaw: float, source_record: Dictionary, is_extra: bool) -> void:
	var key := "%s_%d" % [family, variant]
	if not grouped.has(key):
		grouped[key] = []
	(grouped[key] as Array).append({
		"family": family,
		"variant": variant,
		"ground": ground,
		"width_scale": width_scale,
		"height_scale": height_scale,
		"yaw": yaw,
		"source_record": source_record,
		"extra": is_extra,
	})
	if family == "conifer":
		_conifer_count += 1
	else:
		_broadleaf_count += 1

func _build_surface0_contact_points(mesh: Mesh) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if mesh == null or mesh.get_surface_count() <= 0:
		return points
	var arrays: Array = mesh.surface_get_arrays(0)
	if arrays.is_empty() or arrays.size() <= Mesh.ARRAY_VERTEX:
		return points
	var raw_vertices: Variant = arrays[Mesh.ARRAY_VERTEX]
	if not raw_vertices is PackedVector3Array:
		return points
	var vertices: PackedVector3Array = raw_vertices
	if vertices.is_empty():
		return points
	var used_indices := PackedInt32Array()
	if arrays.size() > Mesh.ARRAY_INDEX:
		var raw_indices: Variant = arrays[Mesh.ARRAY_INDEX]
		if raw_indices is PackedInt32Array:
			used_indices = raw_indices
	if used_indices.is_empty():
		used_indices.resize(vertices.size())
		for index in vertices.size():
			used_indices[index] = index
	var min_y := INF
	for index in used_indices:
		if index < 0 or index >= vertices.size():
			continue
		var vertex: Vector3 = vertices[index]
		if vertex.is_finite():
			min_y = minf(min_y, vertex.y)
	if not is_finite(min_y):
		return points
	var lowest_band: Array[Vector3] = []
	for index in used_indices:
		if index < 0 or index >= vertices.size():
			continue
		var vertex: Vector3 = vertices[index]
		if vertex.is_finite() and vertex.y <= min_y + 0.035:
			lowest_band.append(vertex)
	if lowest_band.is_empty():
		return points
	var min_x_index := 0
	var max_x_index := 0
	var min_z_index := 0
	var max_z_index := 0
	for index in lowest_band.size():
		var vertex: Vector3 = lowest_band[index]
		if vertex.x < lowest_band[min_x_index].x:
			min_x_index = index
		if vertex.x > lowest_band[max_x_index].x:
			max_x_index = index
		if vertex.z < lowest_band[min_z_index].z:
			min_z_index = index
		if vertex.z > lowest_band[max_z_index].z:
			max_z_index = index
	for extreme_index in [min_x_index, max_x_index, min_z_index, max_z_index]:
		var extreme: Vector3 = lowest_band[int(extreme_index)]
		var duplicate := false
		for existing_value in points:
			var existing: Vector3 = existing_value
			if existing.distance_squared_to(extreme) <= 0.000001:
				duplicate = true
				break
		if not duplicate:
			points.append(extreme)
	for vertex in lowest_band:
		if points.size() >= 4:
			break
		var duplicate := false
		for existing_value in points:
			var existing: Vector3 = existing_value
			if existing.distance_squared_to(vertex) <= 0.000001:
				duplicate = true
				break
		if not duplicate:
			points.append(vertex)
	return points

func _correct_tree_root_for_surface_contacts(local_points: Array[Vector3], basis: Basis, root_position: Vector3, fallback_ground: Vector3) -> Dictionary:
	if local_points.is_empty() or not root_position.is_finite() or not fallback_ground.is_finite():
		return {"valid": false}
	var initial_world_points := PackedVector3Array()
	var corrected_world_points := PackedVector3Array()
	var ground_heights := PackedFloat32Array()
	var ground_sources: Array[String] = []
	var max_positive_clearance := 0.0
	var initial_max_burial := 0.0
	for local_point in local_points:
		var world_point := root_position + basis * local_point
		if not world_point.is_finite():
			return {"valid": false}
		var sample := _sample_ground(Vector2(world_point.x, world_point.z))
		var ground_y := fallback_ground.y
		var ground_source := "fallback_instance_ground"
		if not sample.is_empty():
			var sample_position: Vector3 = sample["position"]
			if sample_position.is_finite():
				ground_y = sample_position.y
				ground_source = String(sample.get("source", "S01Landscape._sample_ground"))
		var clearance := world_point.y - ground_y
		max_positive_clearance = maxf(max_positive_clearance, maxf(clearance, 0.0))
		initial_max_burial = maxf(initial_max_burial, maxf(-clearance, 0.0))
		initial_world_points.append(world_point)
		ground_heights.append(ground_y)
		ground_sources.append(ground_source)
	var additional_bury := max_positive_clearance + ROOT_BURY_M if max_positive_clearance > 0.0 else 0.0
	var corrected_root := root_position - Vector3.UP * additional_bury
	var corrected_max_positive := 0.0
	var corrected_max_burial := 0.0
	for index in initial_world_points.size():
		var corrected_point := initial_world_points[index] - Vector3.UP * additional_bury
		var clearance := corrected_point.y - ground_heights[index]
		corrected_max_positive = maxf(corrected_max_positive, maxf(clearance, 0.0))
		corrected_max_burial = maxf(corrected_max_burial, maxf(-clearance, 0.0))
		corrected_world_points.append(corrected_point)
	return {
		"valid": corrected_root.is_finite() and corrected_max_positive <= 0.001,
		"root_position": corrected_root,
		"initial_world_points": initial_world_points,
		"corrected_world_points": corrected_world_points,
		"ground_heights": ground_heights,
		"ground_sources": ground_sources,
		"initial_max_positive_clearance_m": max_positive_clearance,
		"post_correction_max_positive_clearance_m": corrected_max_positive,
		"initial_max_burial_m": initial_max_burial,
		"deep_burial_m": corrected_max_burial,
		"additional_bury_m": additional_bury,
	}

func _build_replacement_multimeshes(grouped: Dictionary) -> bool:
	for key in grouped.keys():
		var items: Array = grouped[key]
		if items.is_empty() or not _tree_meshes.has(String(key)):
			continue
		var mesh := _tree_meshes[key] as Mesh
		if mesh == null:
			return false
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = items.size()
		var bounds := mesh.get_aabb()
		var surface0_contact_points: Array[Vector3] = _tree_surface0_contact_points.get(String(key), [])
		if surface0_contact_points.size() != 4:
			return false
		var records: Array[Dictionary] = []
		for index in items.size():
			var item: Dictionary = items[index]
			var width_scale := float(item["width_scale"])
			var height_scale := float(item["height_scale"])
			var basis := Basis(Vector3.UP, float(item["yaw"])).scaled(Vector3(width_scale, height_scale, width_scale))
			var ground: Vector3 = item["ground"]
			var root_position := Vector3(ground.x, ground.y - bounds.position.y * height_scale - ROOT_BURY_M, ground.z)
			var contact := _correct_tree_root_for_surface_contacts(surface0_contact_points, basis, root_position, ground)
			if not bool(contact.get("valid", false)):
				return false
			root_position = contact["root_position"]
			var initial_points: PackedVector3Array = contact["initial_world_points"]
			var corrected_points: PackedVector3Array = contact["corrected_world_points"]
			var contact_ground_heights: PackedFloat32Array = contact["ground_heights"]
			var contact_ground_sources: Array[String] = contact["ground_sources"]
			var initial_clearance := float(contact["initial_max_positive_clearance_m"])
			var corrected_clearance := float(contact["post_correction_max_positive_clearance_m"])
			var initial_burial := float(contact["initial_max_burial_m"])
			var additional_bury := float(contact["additional_bury_m"])
			var deep_burial := float(contact["deep_burial_m"])
			_surface0_contact_correction_count += 1 if additional_bury > 0.0 else 0
			_surface0_max_positive_clearance_m = maxf(_surface0_max_positive_clearance_m, initial_clearance)
			_surface0_max_burial_m = maxf(_surface0_max_burial_m, deep_burial)
			multimesh.set_instance_transform(index, Transform3D(basis, root_position))
			var source_record: Dictionary = item["source_record"]
			var record := {
				"index": index,
				"family": String(item["family"]),
				"variant": int(item["variant"]),
				"root_world": root_position,
				"root_local_y": root_position.y,
				"mesh_aabb": bounds,
				"mesh_bottom_world_y": root_position.y + bounds.position.y * height_scale,
				"sampled_ground_y": ground.y,
				"ground_contact_error_m": root_position.y + bounds.position.y * height_scale - ground.y,
				"surface0_contact_points_local": surface0_contact_points,
				"surface0_contact_points_world": corrected_points,
				"surface0_contact_ground_heights": contact_ground_heights,
				"surface0_contact_ground_sources": contact_ground_sources,
				"surface0_initial_max_positive_clearance_m": initial_clearance,
				"surface0_post_correction_max_positive_clearance_m": corrected_clearance,
				"surface0_initial_max_burial_m": initial_burial,
				"surface0_additional_bury_m": additional_bury,
				"surface0_deep_burial_m": deep_burial,
				"source_path": String(source_record.get("path", "")),
				"source_index": int(source_record.get("index", -1)),
				"source_transform": source_record.get("source_transform", Transform3D()),
				"extra": bool(item.get("extra", false)),
			}
			records.append(record)
			_replacement_records.append(record)
			_projection_records.append({
				"replacement_family": String(item["family"]),
				"replacement_index": index,
				"root_world": root_position,
				"root_screen": _project_point(root_position),
				"top_world": root_position + Vector3.UP * maxf(2.0, bounds.size.y * height_scale),
				"top_screen": _project_point(root_position + Vector3.UP * maxf(2.0, bounds.size.y * height_scale)),
				"behind_camera": _camera.is_position_behind(root_position),
				"screen_roi_hit": _screen_rect_hit(root_position, bounds, basis),
			})
		var instance := MultiMeshInstance3D.new()
		instance.name = "S03Forest_%s" % String(key)
		instance.multimesh = multimesh
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		instance.set_meta("saisies_s03_forest_family", String(items[0]["family"]))
		instance.set_meta("saisies_s03_forest_variant", int(items[0]["variant"]))
		instance.set_meta("saisies_s03_forest_instance_count", items.size())
		instance.set_meta("saisies_s03_forest_mesh_aabb", bounds)
		instance.set_meta("saisies_s03_forest_root_local_y_contract", "AABB bottom seeds root y; indexed surface0 contact correction only moves floating roots downward")
		instance.set_meta("saisies_s03_forest_surface0_contact_points_local", surface0_contact_points)
		instance.set_meta("saisies_s03_forest_surface0_contact_band_m", 0.035)
		instance.set_meta("saisies_s03_forest_surface0_contact_contract", "indexed surface0 vertices within min_y+0.035, four XZ extremes, visible-ground samples after full instance basis")
		instance.set_meta("saisies_s03_forest_instance_records", records)
		_replacement.add_child(instance)
		for record in records:
			record["replacement_path"] = str(instance.get_path())
		_new_count += items.size()
	return _new_count > 0

func _load_tree_meshes() -> Dictionary:
	var result := {}
	var conifers: Array = TREE_FACTORY.conifer_variants()
	var broadleaf: Array = TREE_FACTORY.broadleaf_variants()
	var conifer_card_tints := [
		Color(0.46, 0.64, 0.32, 1.0),
		Color(0.40, 0.58, 0.28, 1.0),
		Color(0.50, 0.68, 0.35, 1.0),
	]
	var conifer_dense_colors := [
		Color(0.026, 0.072, 0.022, 1.0),
		Color(0.020, 0.058, 0.018, 1.0),
		Color(0.032, 0.086, 0.026, 1.0),
	]
	var broadleaf_tints := [
		Color(0.54, 0.70, 0.34, 1.0),
		Color(0.62, 0.76, 0.41, 1.0),
		Color(0.47, 0.65, 0.29, 1.0),
	]
	for index in mini(3, conifers.size()):
		var key := "conifer_%d" % index
		var local_mesh := _tinted_local_mesh(
			conifers[index] as Mesh,
			Color(0.20, 0.18, 0.15, 1.0),
			conifer_card_tints[index],
			conifer_dense_colors[index]
		)
		result[key] = local_mesh
		_tree_surface0_contact_points[key] = _build_surface0_contact_points(local_mesh)
	for index in mini(3, broadleaf.size()):
		var key := "broadleaf_%d" % index
		var local_mesh := _tinted_local_mesh(
			broadleaf[index] as Mesh,
			Color(0.22, 0.19, 0.16, 1.0),
			broadleaf_tints[index],
			Color(0.07, 0.14, 0.04, 1.0)
		)
		result[key] = local_mesh
		_tree_surface0_contact_points[key] = _build_surface0_contact_points(local_mesh)
	return result

func _tinted_local_mesh(source_mesh: Mesh, bark_tint: Color, foliage_tint: Color, dense_color: Color) -> Mesh:
	if source_mesh == null:
		return null
	var copy := source_mesh.duplicate() as ArrayMesh
	if copy == null:
		return source_mesh
	for surface_idx in copy.get_surface_count():
		var mat := copy.surface_get_material(surface_idx)
		if mat is StandardMaterial3D:
			var smat := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
			smat.disable_fog = true
			if surface_idx == 0:
				smat.albedo_color = bark_tint
				smat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
				smat.roughness = 0.96
			elif surface_idx == 1:
				smat.albedo_color = smat.albedo_color * foliage_tint
				smat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
				smat.roughness = 0.96
				smat.emission_enabled = true
				smat.emission = Color(0.012, 0.045, 0.008, 1.0)
				smat.emission_energy_multiplier = 0.35
			# A slightly firmer alpha cut removes the pale transparent card
			# fringe at the near left edge while retaining the needle clusters.
				smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				smat.alpha_scissor_threshold = maxf(smat.alpha_scissor_threshold, 0.24)
			elif surface_idx == 2:
				if smat.albedo_texture == null:
					smat.albedo_color = dense_color
				else:
					smat.albedo_color = bark_tint
				smat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
				smat.roughness = 0.98
				smat.emission_enabled = true
				smat.emission = Color(0.009, 0.036, 0.006, 1.0)
				smat.emission_energy_multiplier = 0.30
			copy.surface_set_material(surface_idx, smat)
	return copy

func _sample_ground(point: Vector2) -> Dictionary:
	var candidates: Array[Dictionary] = []
	if _landscape.has_method("_sample_ground"):
		var visible_variant: Variant = _landscape.call("_sample_ground", point)
		if visible_variant is Dictionary and visible_variant.has("position") and (visible_variant["position"] as Vector3).is_finite():
			candidates.append(visible_variant.duplicate(true))
	var baked_variant: Variant = _landscape.call("_sample_baked_ground", point)
	if baked_variant is Dictionary and baked_variant.has("position") and (baked_variant["position"] as Vector3).is_finite():
		candidates.append(baked_variant.duplicate(true))
	if candidates.is_empty():
		return {}
	var chosen: Dictionary = candidates[0]
	for candidate in candidates:
		if float((candidate["position"] as Vector3).y) > float((chosen["position"] as Vector3).y):
			chosen = candidate
	return chosen

func _extra_clear_of_route(point: Vector3) -> bool:
	var route := _world.get_node_or_null("Route")
	if route == null or not route.has_method("distance_for_position") or not route.has_method("pos_at") or not route.has_method("left_at"):
		return true
	var station := float(route.call("distance_for_position", point))
	var route_point := Vector3(route.call("pos_at", station))
	var left := Vector3(route.call("left_at", station))
	left.y = 0.0
	if left.length_squared() <= 0.001:
		return true
	var lateral := (Vector2(point.x - route_point.x, point.z - route_point.z)).dot(Vector2(left.x, left.z).normalized())
	return lateral > 14.5

func _screen_rect_hit(root_position: Vector3, bounds: AABB, basis: Basis) -> bool:
	var minp := Vector2(INF, INF)
	var maxp := Vector2(-INF, -INF)
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			for z in [bounds.position.z, bounds.end.z]:
				var point := root_position + basis * Vector3(x, y, z)
				var screen := _project_point(point)
				minp.x = minf(minp.x, screen.x)
				minp.y = minf(minp.y, screen.y)
				maxp.x = maxf(maxp.x, screen.x)
				maxp.y = maxf(maxp.y, screen.y)
	return not _camera.is_position_behind(root_position) and Rect2(minp, maxp - minp).intersects(FOREST_SCREEN_ROI)

func _project_point(point: Vector3) -> Vector2:
	return _camera.unproject_position(point) if _camera != null and point.is_finite() else Vector2(-1.0, -1.0)

func _update_lod_gate() -> void:
	if _camera == null:
		return
	var distance := _camera.global_position.distance_to(CAMERA_GATE_CENTER)
	var active := distance <= CAMERA_GATE_END_M
	if active == _lod_active and _replacement != null:
		set_meta("saisies_s03_forest_camera_gate_distance_m", distance)
		return
	_lod_active = active
	if _replacement != null:
		_replacement.visible = active
	for old_node in _old_nodes:
		if is_instance_valid(old_node):
			old_node.visible = false if active else bool(_old_visibility.get(old_node, true))
	set_meta("saisies_s03_forest_lod_active", active)
	set_meta("saisies_s03_forest_camera_gate_distance_m", distance)

func _all_geometry_finite() -> bool:
	if _old_count <= 0 or _new_count <= 0 or _replacement_records.is_empty():
		return false
	for record in _replacement_records:
		var root_world: Vector3 = record.get("root_world", Vector3.INF)
		if not root_world.is_finite():
			return false
		if not is_finite(float(record.get("sampled_ground_y", NAN))):
			return false
		if float(record.get("ground_contact_error_m", INF)) > ROOT_BURY_M + 0.001:
			return false
		if float(record.get("surface0_post_correction_max_positive_clearance_m", INF)) > 0.001:
			return false
	return true

func _publish_ready_state() -> void:
	set_meta("saisies_s03_forest_refinement_ready", true)
	set_meta("saisies_s03_forest_refinement_enabled", true)
	set_meta("saisies_s03_forest_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_forest_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_forest_hidden_old_paths", PackedStringArray(_hidden_paths))
	set_meta("saisies_s03_forest_selected_old_paths", PackedStringArray(_hidden_paths))
	set_meta("saisies_s03_forest_selected_old_records", _source_records)
	set_meta("saisies_s03_forest_replacement_path", str(_replacement.get_path()))
	set_meta("saisies_s03_forest_replacement_records", _replacement_records)
	set_meta("saisies_s03_forest_projection_records", _projection_records)
	set_meta("saisies_s03_forest_old_count", _old_count)
	set_meta("saisies_s03_forest_s01_crown_replaced_count", _s01_crown_replaced_count)
	set_meta("saisies_s03_forest_s01_crown_total_count", _s01_crown_total_count)
	set_meta("saisies_s03_forest_s01_crown_preserved_count", _s01_crown_preserved_count)
	set_meta("saisies_s03_forest_s01_crown_selected_count", _s01_crown_selected_count)
	set_meta("saisies_s03_forest_s01_crown_replacement_bounds", S01_CROWN_REPLACEMENT_BOUNDS)
	set_meta("saisies_s03_forest_s01_crown_source_transform_counts", _s01_crown_transform_source_counts)
	set_meta("saisies_s03_forest_s01_crown_source_records", _s01_crown_source_records)
	set_meta("saisies_s03_forest_s01_crown_filtered_paths", PackedStringArray(_filtered_crown_paths()))
	set_meta("saisies_s03_forest_s01_crown_native_transform_contract", "filtered local MultiMesh copies retain every original crown transform outside bounds; native get_instance_transform readback is required")
	set_meta("saisies_s03_forest_new_count", _new_count)
	set_meta("saisies_s03_forest_extra_count", _extra_count)
	set_meta("saisies_s03_forest_conifer_count", _conifer_count)
	set_meta("saisies_s03_forest_broadleaf_count", _broadleaf_count)
	set_meta("saisies_s03_forest_front_edge_conifer_count", _front_edge_conifer_count)
	set_meta("saisies_s03_forest_front_edge_mix_count", _front_edge_mix_count)
	set_meta("saisies_s03_forest_selected_chunk_bounds", {"chunks": SELECTED_FOREST_CHUNKS, "s01_crown_nodes": S01_CROWN_NODE_NAMES})
	set_meta("saisies_s03_forest_screen_roi", FOREST_SCREEN_ROI)
	set_meta("saisies_s03_forest_close_camera", CLOSE_CAMERA_WORLD)
	set_meta("saisies_s03_forest_close_target", CLOSE_TARGET_WORLD)
	set_meta("saisies_s03_forest_ground_contact_method", "S01Landscape._sample_ground/_sample_baked_ground at four indexed surface0 lowest-band XZ extremes, full-basis correction, ROOT_BURY_M")
	set_meta("saisies_s03_forest_root_bury_m", ROOT_BURY_M)
	set_meta("saisies_s03_forest_surface0_contact_correction_count", _surface0_contact_correction_count)
	set_meta("saisies_s03_forest_surface0_max_positive_clearance_m", _surface0_max_positive_clearance_m)
	set_meta("saisies_s03_forest_surface0_max_burial_m", _surface0_max_burial_m)
	set_meta("saisies_s03_forest_surface0_contact_contract", "surface0 indexed used vertices within min_y+0.035; four XZ extremes per mesh; visible-ground samples per instance; only positive clearance gets additional downward correction")
	set_meta("saisies_s03_forest_tree_mesh_source", "res://scripts/saisies_trees.gd conifer_variants/broadleaf_variants")
	set_meta("saisies_s03_forest_lod_gate", {"center": CAMERA_GATE_CENTER, "full_m": CAMERA_GATE_FULL_M, "end_m": CAMERA_GATE_END_M, "active": _lod_active})
	set_meta("saisies_s03_forest_geometry_contract", "local MultiMesh replacement; no terrain, camera, route, building, or shared source module edits")
	_publish_parent_ready(true)

func _filtered_crown_paths() -> Array[String]:
	var paths: Array[String] = []
	for node in _s01_crown_filtered_nodes:
		if is_instance_valid(node):
			paths.append(str(node.get_path()))
	return paths

func _publish_disabled_state() -> void:
	set_meta("saisies_s03_forest_refinement_ready", true)
	set_meta("saisies_s03_forest_refinement_enabled", false)
	set_meta("saisies_s03_forest_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_forest_source_sha256", SOURCE_SHA256)
	set_meta("saisies_s03_forest_hidden_old_paths", PackedStringArray())
	set_meta("saisies_s03_forest_old_count", 0)
	set_meta("saisies_s03_forest_new_count", 0)
	set_meta("saisies_s03_forest_close_camera", CLOSE_CAMERA_WORLD)
	set_meta("saisies_s03_forest_close_target", CLOSE_TARGET_WORLD)
	set_meta("saisies_s03_forest_ground_contact_method", "disabled baseline")
	_publish_parent_ready(false)

func _publish_parent_ready(enabled: bool) -> void:
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s03_forest_review_ready", true)
		parent.set_meta("saisies_s03_forest_review_enabled", enabled)
		parent.set_meta("saisies_s03_forest_review_source_frame", SOURCE_FRAME)
	var current := get_tree().current_scene
	if current != null:
		current.set_meta("saisies_s03_forest_review_ready", true)
		current.set_meta("saisies_s03_forest_review_enabled", enabled)

func _stable_id(text: String, index: int) -> int:
	return int(hash("%s:%d" % [text, index]) & 0x7fffffff)

func _hash01(value: int, salt: int) -> float:
	var n: int = (value & 0xffffffff) ^ ((salt & 0xffffffff) * 0x9e3779b9)
	n &= 0xffffffff
	n = ((n ^ (n >> 16)) * 0x45d9f3b) & 0xffffffff
	n = ((n ^ (n >> 16)) * 0x45d9f3b) & 0xffffffff
	n = (n ^ (n >> 16)) & 0xffffffff
	return float(n) / 4294967295.0

func _retry(message: String) -> void:
	_attempts += 1
	if _attempts < 240:
		call_deferred("_retry_next_frame")
	else:
		_fail_and_hold(message)

func _retry_next_frame() -> void:
	await get_tree().process_frame
	_try_build()

func _fail_and_hold(message: String) -> void:
	set_meta("saisies_s03_forest_refinement_ready", false)
	set_meta("saisies_s03_forest_refinement_error", message)
	_publish_parent_ready(false)
	push_error(message)

func _has_command_line_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()
