extends SceneTree

## Headless smoke check for the static tree factory.  It intentionally checks
## the public contract rather than implementation details so the scene can use
## the meshes through MultiMesh without importing a Node3D hierarchy.

const MAX_NEAR_TRIANGLES := 20000
const MAX_MID_TRIANGLES := 10000
const MAX_FAR_TRIANGLES := 4000
func _init() -> void:
	var src: Mesh = SaisiesTrees._load_model_mesh("island_tree_02")
	print("island_tree_02 source AABB=", src.get_aabb() if src else "null")
	var alpha_ok := _check_source_leaf_alpha()
	var broadleaf := SaisiesTrees.broadleaf_variants()
	var conifers := SaisiesTrees.conifer_variants()
	var ok := alpha_ok and _check_family("broadleaf", broadleaf, 12.0, 6.0)
	ok = _check_broadleaf_leaf_material(broadleaf) and ok
	ok = _check_family("conifer", conifers, 12.0, 3.0) and ok
	ok = _check_triangle_budgets("broadleaf", broadleaf) and ok
	ok = _check_triangle_budgets("conifer", conifers) and ok
	ok = _check_deterministic(broadleaf, SaisiesTrees.broadleaf_variants(), "broadleaf") and ok
	ok = _check_deterministic(conifers, SaisiesTrees.conifer_variants(), "conifer") and ok
	if ok:
		print("SaisiesTrees verification passed: 3 broadleaf + 3 conifer meshes")
		quit()
	else:
		quit(1)

func _check_source_leaf_alpha() -> bool:
	var texture := load("res://assets/models/saisies_island_tree_02/saisies_island_tree_02_leaves_diff_1k.png") as Texture2D
	if texture == null:
		push_error("official island_tree_02 leaf PNG is missing")
		return false
	var image := texture.get_image()
	if image == null or image.is_empty():
		push_error("official island_tree_02 leaf PNG has no image data")
		return false
	var min_alpha := 1.0
	var max_alpha := 0.0
	for y in range(0, image.get_height(), 32):
		for x in range(0, image.get_width(), 32):
			var alpha := image.get_pixel(x, y).a
			min_alpha = minf(min_alpha, alpha)
			max_alpha = maxf(max_alpha, alpha)
	print("official leaf PNG alpha range=%.3f..%.3f" % [min_alpha, max_alpha])
	if min_alpha > 0.05 or max_alpha < 0.95:
		push_error("official island_tree_02 leaf PNG does not contain a usable alpha mask")
		return false
	return true

func _check_family(label: String, meshes: Array[Mesh], min_height: float, min_width: float) -> bool:
	if meshes.size() != 3:
		push_error("%s family returned %d meshes; expected 3" % [label, meshes.size()])
		return false
	var ok := true
	var min_surfaces := 3 if label == "broadleaf" else 2
	for i in range(meshes.size()):
		var mesh := meshes[i]
		if mesh == null or mesh.get_surface_count() < min_surfaces:
			push_error("%s[%d] has no bark/card/dense foliage surfaces" % [label, i])
			ok = false
			continue
		if mesh.surface_get_material(0) == null or mesh.surface_get_material(1) == null or (min_surfaces >= 3 and mesh.surface_get_material(2) == null):
			push_error("%s[%d] has an unassigned material" % [label, i])
			ok = false
		var foliage := mesh.surface_get_material(1)
		if foliage is BaseMaterial3D:
			var alpha_mat := foliage as BaseMaterial3D
			if alpha_mat.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR or alpha_mat.cull_mode != BaseMaterial3D.CULL_DISABLED:
				push_error("%s[%d] foliage material is not alpha-cut and double-sided" % [label, i])
				ok = false
		elif foliage is ShaderMaterial:
			if (foliage as ShaderMaterial).shader == null:
				push_error("%s[%d] foliage shader material has no shader" % [label, i])
				ok = false
		else:
			push_error("%s[%d] foliage material is neither alpha-cut nor shader-based" % [label, i])
			ok = false
		var size := mesh.get_aabb().size
		if size.y < min_height or size.x < min_width or size.z < min_width:
			push_error("%s[%d] is too small: %s" % [label, i, size])
			ok = false
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = 1
		multimesh.set_instance_transform(0, Transform3D.IDENTITY)
		print("%s[%d] size=%s surfaces=%d" % [label, i, size, mesh.get_surface_count()])
	return ok

func _check_broadleaf_leaf_material(meshes: Array[Mesh]) -> bool:
	var atlas := SaisiesTrees._leaf_cluster_atlas()
	if atlas == null:
		push_error("broadleaf cluster atlas could not be created")
		return false
	var ok := true
	for i in range(meshes.size()):
		var mesh := meshes[i]
		if mesh == null or mesh.get_surface_count() < 2:
			continue
		var foliage := mesh.surface_get_material(1)
		if not foliage is BaseMaterial3D:
			push_error("broadleaf[%d] cluster foliage must use a StandardMaterial3D" % i)
			ok = false
			continue
		var leaf := foliage as BaseMaterial3D
		var arrays := mesh.surface_get_arrays(1)
		var normals = arrays[Mesh.ARRAY_NORMAL]
		var tint := leaf.albedo_color
		print("broadleaf[%d] leaf atlas=%s normal_enabled=%s normal_texture=%s alpha_scissor=%.3f tint=%s normals=%d" % [
			i,
			leaf.albedo_texture == atlas,
			leaf.normal_enabled,
			leaf.normal_texture != null,
			leaf.alpha_scissor_threshold,
			tint,
			normals.size() if normals is PackedVector3Array else 0,
		])
		if leaf.albedo_texture != atlas:
			push_error("broadleaf[%d] foliage is not using the generated cluster atlas" % i)
			ok = false
		if leaf.normal_enabled or leaf.normal_texture != null:
			push_error("broadleaf[%d] cluster foliage incorrectly uses the source normal atlas" % i)
			ok = false
		if leaf.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR or leaf.cull_mode != BaseMaterial3D.CULL_DISABLED:
			push_error("broadleaf[%d] cluster foliage lost alpha scissor or double-sided rendering" % i)
			ok = false
		if leaf.alpha_scissor_threshold <= 0.0 or leaf.alpha_scissor_threshold > 1.0:
			push_error("broadleaf[%d] cluster foliage has invalid alpha scissor threshold %.3f" % [i, leaf.alpha_scissor_threshold])
			ok = false
		if tint.r < 0.80 or tint.r > 1.10 or tint.g < 0.80 or tint.g > 1.10 or tint.b < 0.80 or tint.b > 1.10:
			push_error("broadleaf[%d] leaf tint is too dark or extreme: %s" % [i, tint])
			ok = false
		if not normals is PackedVector3Array or normals.is_empty():
			push_error("broadleaf[%d] cluster foliage has no generated geometry normals" % i)
			ok = false
	return ok

func _check_deterministic(first: Array[Mesh], second: Array[Mesh], label: String) -> bool:
	var ok := true
	if first.size() != second.size():
		push_error("%s factory changed variant count between calls" % label)
		return false
	for i in range(first.size()):
		if not first[i].get_aabb().position.is_equal_approx(second[i].get_aabb().position) or not first[i].get_aabb().size.is_equal_approx(second[i].get_aabb().size):
			push_error("%s[%d] changed geometry between calls" % [label, i])
			ok = false
	return ok

func _check_triangle_budgets(label: String, meshes: Array[Mesh]) -> bool:
	var ok := true
	for i in range(meshes.size()):
		var mesh := meshes[i]
		var near_triangles := _triangle_count(mesh)
		var budget: Dictionary = mesh.get_meta("saisies_triangle_budget", {})
		var mid_triangles := int(budget.get("mid", -1))
		var far_triangles := int(budget.get("far", -1))
		var shadow_mesh: Mesh = (mesh as ArrayMesh).shadow_mesh if mesh is ArrayMesh else null
		var shadow_triangles := _triangle_count(shadow_mesh) if shadow_mesh != null else 0
		var lod_thresholds = mesh.get_meta("saisies_lod_thresholds", [])
		var importer := ImporterMesh.from_mesh(mesh)
		var lod_totals := _lod_triangle_totals(importer)
		print("%s[%d] triangles near=%d mid=%d far=%d shadow=%d mesh_lods=%s" % [label, i, near_triangles, mid_triangles, far_triangles, shadow_triangles, lod_totals])
		if near_triangles > MAX_NEAR_TRIANGLES:
			push_error("%s[%d] exceeds near triangle budget: %d > %d" % [label, i, near_triangles, MAX_NEAR_TRIANGLES])
			ok = false
		if mid_triangles < 0 or mid_triangles > MAX_MID_TRIANGLES:
			push_error("%s[%d] has no valid mid triangle budget: %d" % [label, i, mid_triangles])
			ok = false
		if far_triangles < 0 or far_triangles > MAX_FAR_TRIANGLES:
			push_error("%s[%d] has no valid far triangle budget: %d" % [label, i, far_triangles])
			ok = false
		if shadow_mesh != null:
			push_error("%s[%d] must use its valid LOD surfaces for shadows; shadow_mesh proxy is invalid" % [label, i])
			ok = false
		if not lod_thresholds is Array or lod_thresholds.size() < 2:
			push_error("%s[%d] is missing actual LOD distance keys" % [label, i])
			ok = false
		else:
			var mid_distance := float(lod_thresholds[0])
			var far_distance := float(lod_thresholds[1])
			if mid_distance >= far_distance:
				push_error("%s[%d] LOD distance keys are reversed: mid=%.3f far=%.3f" % [label, i, mid_distance, far_distance])
				ok = false
		if lod_totals.size() < 2:
			push_error("%s[%d] has fewer than two render LOD index buffers" % [label, i])
			ok = false
		else:
			var largest_lod := 0
			var smallest_lod := MAX_NEAR_TRIANGLES + 1
			for lod_triangles in lod_totals:
				largest_lod = maxi(largest_lod, int(lod_triangles))
				smallest_lod = mini(smallest_lod, int(lod_triangles))
			if largest_lod >= near_triangles or largest_lod > MAX_MID_TRIANGLES or smallest_lod > MAX_FAR_TRIANGLES:
				push_error("%s[%d] render LOD buffers exceed their budgets: %s" % [label, i, lod_totals])
				ok = false
		if not (near_triangles > mid_triangles and mid_triangles > far_triangles):
			push_error("%s[%d] LOD triangle counts are not descending" % [label, i])
			ok = false
	return ok

func _lod_triangle_totals(importer: ImporterMesh) -> Array:
	if importer == null:
		return []
	var lod_count := 0
	for si in range(importer.get_surface_count()):
		lod_count = maxi(lod_count, importer.get_surface_lod_count(si))
	var totals: Array = []
	for lod_index in range(lod_count):
		var total := 0
		for si in range(importer.get_surface_count()):
			if lod_index < importer.get_surface_lod_count(si):
				total += importer.get_surface_lod_indices(si, lod_index).size() / 3
		totals.append(total)
	return totals

func _triangle_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for si in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(si)
		var indices = arrays[Mesh.ARRAY_INDEX]
		if indices is PackedInt32Array and not indices.is_empty():
			total += indices.size() / 3
		else:
			var vertices = arrays[Mesh.ARRAY_VERTEX]
			if vertices is PackedVector3Array:
				total += vertices.size() / 3
	return total
