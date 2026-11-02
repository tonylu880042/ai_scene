class_name SaisiesTrees
extends RefCounted

## Deterministic, MultiMesh-friendly tree meshes for the Col des Saisies route.
##
## The meshes are authored in metres.  The caller can instance them at roughly
## 0.7..1.3 scale to break up the silhouette without changing the species mix.
## Each mesh has a bark surface and a separate alpha-cut foliage surface, so a
## MultiMesh can share the resource without creating per-instance nodes.

const _LEAF_ALPHA := 0.20
# ArrayMesh LOD keys are distance thresholds: a larger key is selected farther
# away.  Keep the mid buffer first and the coarsest far buffer second.
const _LOD_MID_DISTANCE := 0.12
const _LOD_FAR_DISTANCE := 0.36
const _SCANNED_NEAR_BUDGETS := [2600, 9800, 5200]
const _SCANNED_MID_BUDGETS := [1300, 4800, 2600]
const _SCANNED_FAR_BUDGETS := [500, 1600, 800]

static var _lod_importer_cache: Dictionary = {}
static var _broadleaf_cache: Array[Mesh] = []
static var _rounded_broadleaf_cache: Array[Mesh] = []
static var _conifer_cache: Array[Mesh] = []
static var _leaf_cluster_cache: Texture2D

static func broadleaf_variants(round_crown := false) -> Array[Mesh]:
	if round_crown:
		if _rounded_broadleaf_cache.is_empty():
			_rounded_broadleaf_cache = _scanned_broadleaf_variants(true)
		if not _rounded_broadleaf_cache.is_empty():
			return _rounded_broadleaf_cache
	if not _broadleaf_cache.is_empty():
		return _broadleaf_cache
	var scanned := _scanned_broadleaf_variants()
	if scanned.size() == 3:
		_broadleaf_cache = scanned
		return _broadleaf_cache
	var leaves := _card_mat(_leaf_atlas())
	var bark := _bark_mat("japanese_sycamore", Color(0.72, 0.72, 0.68))
	_broadleaf_cache = [
		_make_beech(601, Color(0.12, 0.30, 0.035), leaves, bark),
		_make_beech(613, Color(0.18, 0.39, 0.055), leaves, bark),
		_make_beech(629, Color(0.09, 0.24, 0.025), leaves, bark),
	]
	return _broadleaf_cache

static func conifer_variants() -> Array[Mesh]:
	if not _conifer_cache.is_empty():
		return _conifer_cache
	var needles := _card_mat(_needle_atlas())
	_conifer_cache = [
		_make_conifer(701, 0.19, [Color(0.012, 0.045, 0.015), Color(0.035, 0.13, 0.035), Color(0.10, 0.26, 0.06)], 1.16, _bark_mat("knotted_pine_bark", Color(0.62, 0.56, 0.48)), needles),
		_make_conifer(719, 0.27, [Color(0.008, 0.032, 0.012), Color(0.025, 0.095, 0.028), Color(0.075, 0.20, 0.05)], 1.08, _bark_mat("pine_bark", Color(0.56, 0.48, 0.38)), needles),
		_make_conifer(733, 0.11, [Color(0.018, 0.060, 0.018), Color(0.055, 0.16, 0.038), Color(0.14, 0.31, 0.07)], 0.98, _bark_mat("knotted_pine_bark", Color(0.68, 0.59, 0.46)), needles),
	]
	return _conifer_cache

static func _card_mat(tex: Texture2D) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = _LEAF_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 0.88
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m

static func _bark_mat(stem: String, tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://assets/textures/%s_diff.jpg" % stem)
	m.normal_enabled = true
	m.normal_texture = load("res://assets/textures/%s_nor.jpg" % stem)
	m.roughness_texture = load("res://assets/textures/%s_rough.jpg" % stem)
	m.albedo_color = tint
	m.roughness = 0.93
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

static func _dense_mat(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint * 1.50
	m.roughness = 0.96
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

static func _scanned_broadleaf_variants(round_crown := false) -> Array[Mesh]:
	var out: Array[Mesh] = []
	var source := _load_model_mesh("island_tree_02")
	if source == null or source.get_surface_count() < 2:
		return out
	var scales := [
		Vector3(2.25, 3.85, 2.25),
		Vector3(2.55, 4.10, 2.55),
		Vector3(2.75, 3.95, 2.75),
	]
	# The source PNG already carries the dark summer-green color.  Keep these
	# tints near white so the source color is preserved, with only small warm,
	# neutral, and cool variants between the three trees.
	var tints := [Color(0.96, 1.02, 0.94), Color(1.03, 0.98, 0.92), Color(0.94, 1.00, 1.04)]
	var bark_tints := [Color(0.58, 0.53, 0.45), Color(0.64, 0.57, 0.47), Color(0.52, 0.48, 0.41)]
	for i in range(scales.size()):
		var mesh := _scaled_source_tree(source, scales[i], tints[i], bark_tints[i], 901 + i * 17, round_crown)
		if mesh == null:
			return []
		out.append(mesh)
	# Keep the shared final meshes cached, but release the temporary full
	# ImporterMesh so the three scene modules do not retain its million-triangle
	# source alongside the budgeted resources.
	_lod_importer_cache.erase("island_tree_02")
	return out

static func _load_model_mesh(model_name: String) -> Mesh:
	var meshes := _load_model_meshes(model_name)
	return meshes[0] if not meshes.is_empty() else null

static func _load_model_meshes(model_name: String) -> Array[Mesh]:
	var out: Array[Mesh] = []
	var packed := load("res://assets/models/%s/%s_1k.gltf" % [model_name, model_name]) as PackedScene
	if packed == null:
		return out
	var root := packed.instantiate()
	if root is MeshInstance3D and (root as MeshInstance3D).mesh != null:
		out.append((root as MeshInstance3D).mesh)
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi != null and mi.mesh != null:
			out.append(mi.mesh)
	root.free()
	return out

static func _leaf_shader_material(source: Material, tint: Color, atlas: Texture2D = null) -> Material:
	var texture: Texture2D
	var source_alpha: Texture2D = atlas
	if source_alpha == null:
		source_alpha = load("res://assets/models/saisies_island_tree_02/saisies_island_tree_02_leaves_diff_1k.png") as Texture2D
	if source_alpha != null:
		var cutout := StandardMaterial3D.new()
		cutout.albedo_texture = source_alpha
		cutout.albedo_color = tint
		cutout.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		cutout.alpha_scissor_threshold = 0.035
		cutout.cull_mode = BaseMaterial3D.CULL_DISABLED
		cutout.roughness = 0.90
		cutout.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		# The generated cluster atlas has different UVs from the imported leaf
		# surface, so its source normal map would shade the cards with unrelated
		# texels.  The cards already carry their generated geometry normals; only
		# retain the imported normal when using the original leaf UVs.
		var source_base := source as BaseMaterial3D
		if atlas == null and source_base != null and source_base.normal_enabled and source_base.normal_texture != null:
			cutout.normal_enabled = true
			cutout.normal_texture = source_base.normal_texture
		return cutout
	var base := source as BaseMaterial3D
	if base != null:
		texture = base.albedo_texture
	if texture == null:
		texture = _leaf_atlas()
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
	render_mode cull_disabled, diffuse_burley, specular_disabled;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
uniform vec4 tint : source_color = vec4(1.0);

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	ALBEDO = tex.rgb * tint.rgb;
	float alpha = smoothstep(0.002, 0.014, max(max(tex.r, tex.g), tex.b));
	ALPHA_SCISSOR_THRESHOLD = 0.035;
	if (alpha < 0.04) {
		discard;
	}
	ROUGHNESS = 0.9;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("albedo_texture", texture)
	material.set_shader_parameter("tint", tint)
	return material

static func _scaled_source_tree(source: Mesh, scale: Vector3, leaf_tint: Color, bark_tint: Color, variant_seed: int, round_crown := false) -> Mesh:
	var importer := _lod_importer(source, "island_tree_02")
	if importer == null or importer.get_surface_count() < 2:
		return null
	var mesh := ArrayMesh.new()
	var near_total := 0
	var mid_total := 0
	var far_total := 0
	# Keep the source's low-poly trunk and branch silhouette, but do not use its
	# million-triangle leaf surface as the visible crown.  Its independent leaf
	# triangles are too sparse after simplification, so the cards below rebuild
	# an even summer canopy from the original alpha texture.
	var trunk_counts := _append_scaled_source_surface(mesh, importer, 0, scale, bark_tint, 2200, 1100, 400)
	near_total += trunk_counts[0]
	mid_total += trunk_counts[1]
	far_total += trunk_counts[2]
	var leaf_raw := _make_scanned_leaf_cards(scale, variant_seed, round_crown)
	if leaf_raw == null:
		return null
	var leaf_arrays: Array = leaf_raw.surface_get_arrays(0).duplicate()
	var leaf_source_indices := _surface_indices(leaf_arrays)
	var leaf_near := _sample_group_indices(leaf_source_indices, 4, 3000)
	# Keep enough whole clusters in the reduced buffers to preserve the crown
	# silhouette; reducing to a handful of individual leaf triangles makes the
	# tree read as bare branches at the road and valley distances.
	var leaf_mid := _sample_group_indices(leaf_source_indices, 4, 1800)
	var leaf_far := _sample_group_indices(leaf_source_indices, 4, 1000)
	leaf_arrays[Mesh.ARRAY_INDEX] = leaf_near
	# The far threshold is larger than the mid threshold, matching Godot's
	# distance-key ordering so the compact cluster silhouette persists farther.
	var leaf_lods: Dictionary = {_LOD_MID_DISTANCE: leaf_mid, _LOD_FAR_DISTANCE: leaf_far}
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, leaf_arrays, [], leaf_lods)
	mesh.surface_set_material(mesh.get_surface_count() - 1, _leaf_shader_material(importer.get_surface_material(1), leaf_tint, _leaf_cluster_atlas()))
	near_total += leaf_near.size() / 3
	mid_total += leaf_mid.size() / 3
	far_total += leaf_far.size() / 3
	if importer.get_surface_count() > 2:
		# Keep the scanned limb silhouette inside the generated crown.  The
		# source branch mesh spreads far beyond its leaf volume; a slightly
		# tighter branch scale and lower budget leaves readable trunks while
		# reducing the exposed vine-like network and transparent overdraw.
		var branch_scale := Vector3(scale.x * 0.78, scale.y * 0.84, scale.z * 0.78)
		var branch_counts := _append_scaled_source_surface(mesh, importer, 2, branch_scale, bark_tint, 900, 420, 140)
		near_total += branch_counts[0]
		mid_total += branch_counts[1]
		far_total += branch_counts[2]
	_set_lod_contract(mesh, near_total, mid_total, far_total)
	return mesh

static func _append_scaled_source_surface(mesh: ArrayMesh, importer: ImporterMesh, surface_index: int, scale: Vector3, bark_tint: Color, near_budget: int, mid_budget: int, far_budget: int) -> Array:
	var arrays: Array = importer.get_surface_arrays(surface_index).duplicate()
	var near_indices := _select_lod_indices(importer, surface_index, near_budget)
	var mid_indices := _select_lod_indices(importer, surface_index, mid_budget)
	var far_indices := _select_lod_indices(importer, surface_index, far_budget)
	if near_indices.is_empty():
		return [0, 0, 0]
	arrays[Mesh.ARRAY_INDEX] = near_indices
	_scale_surface_arrays(arrays, scale)
	var lods: Dictionary = {}
	if mid_indices.size() > 0 and mid_indices.size() < near_indices.size():
		lods[_LOD_MID_DISTANCE] = mid_indices
	if far_indices.size() > 0 and far_indices.size() < mid_indices.size():
		lods[_LOD_FAR_DISTANCE] = far_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], lods)
	var source_material := importer.get_surface_material(surface_index)
	var bark := source_material.duplicate() as BaseMaterial3D if source_material != null else null
	if bark == null:
		bark = _bark_mat("japanese_sycamore", bark_tint)
	else:
		bark.albedo_color = bark_tint
		bark.cull_mode = BaseMaterial3D.CULL_DISABLED
		bark.roughness = 0.90
	mesh.surface_set_material(mesh.get_surface_count() - 1, bark)
	return [near_indices.size() / 3, mid_indices.size() / 3, far_indices.size() / 3]

static func _lod_importer(source: Mesh, cache_key: String) -> ImporterMesh:
	if _lod_importer_cache.has(cache_key):
		return _lod_importer_cache[cache_key] as ImporterMesh
	var importer := ImporterMesh.from_mesh(source)
	if importer == null:
		return null
	# Godot's importer simplifier preserves the original UV/vertex streams while
	# producing index buffers suitable for an ArrayMesh LOD surface.  The base
	# surface is selected below, so the million-triangle source never becomes a
	# renderable or shadow-casting base mesh.
	importer.generate_lods(45.0, 45.0, [])
	_lod_importer_cache[cache_key] = importer
	return importer

static func _surface_budget(budgets: Array, surface_index: int, fallback: int) -> int:
	return int(budgets[surface_index]) if surface_index < budgets.size() else fallback

static func _select_lod_indices(importer: ImporterMesh, surface_index: int, triangle_budget: int) -> PackedInt32Array:
	var arrays: Array = importer.get_surface_arrays(surface_index)
	var original = arrays[Mesh.ARRAY_INDEX]
	var fallback := PackedInt32Array()
	if original is PackedInt32Array and not original.is_empty():
		fallback = original
	else:
		var vertices = arrays[Mesh.ARRAY_VERTEX]
		if vertices is PackedVector3Array:
			fallback.resize(vertices.size())
			for i in range(vertices.size()):
				fallback[i] = i
	if fallback.is_empty():
		return fallback
	var candidates: Array[PackedInt32Array] = [fallback]
	for lod_index in range(importer.get_surface_lod_count(surface_index)):
		var candidate := importer.get_surface_lod_indices(surface_index, lod_index)
		if candidate.size() >= 3:
			candidates.append(candidate)
	var best := fallback
	var best_triangles := fallback.size() / 3
	var found_under_budget := best_triangles <= triangle_budget
	for candidate in candidates:
		var triangles := candidate.size() / 3
		if triangles <= triangle_budget and (not found_under_budget or triangles > best_triangles):
			best = candidate
			best_triangles = triangles
			found_under_budget = true
	if not found_under_budget:
		for candidate in candidates:
			var triangles := candidate.size() / 3
			if triangles < best_triangles:
				best = candidate
				best_triangles = triangles
		if best_triangles > triangle_budget:
			best = _sample_indices(best, triangle_budget)
	return best

static func _sample_indices(indices: PackedInt32Array, triangle_budget: int) -> PackedInt32Array:
	var source_triangles := indices.size() / 3
	var target_triangles := mini(source_triangles, maxi(triangle_budget, 1))
	if target_triangles >= source_triangles:
		return indices
	var sampled := PackedInt32Array()
	sampled.resize(target_triangles * 3)
	for i in range(target_triangles):
		var source_triangle := mini(int(floor(float(i) * float(source_triangles) / float(target_triangles))), source_triangles - 1)
		for corner in range(3):
			sampled[i * 3 + corner] = indices[source_triangle * 3 + corner]
	return sampled

static func _sample_group_indices(indices: PackedInt32Array, triangles_per_group: int, triangle_budget: int) -> PackedInt32Array:
	var source_triangles := indices.size() / 3
	var source_groups := source_triangles / maxi(triangles_per_group, 1)
	var target_groups := mini(source_groups, maxi(triangle_budget / maxi(triangles_per_group, 1), 1))
	if target_groups >= source_groups:
		return indices
	var sampled := PackedInt32Array()
	sampled.resize(target_groups * triangles_per_group * 3)
	for group in range(target_groups):
		var source_group := mini(int(floor(float(group) * float(source_groups) / float(target_groups))), source_groups - 1)
		var source_offset := source_group * triangles_per_group * 3
		var target_offset := group * triangles_per_group * 3
		for i in range(triangles_per_group * 3):
			sampled[target_offset + i] = indices[source_offset + i]
	return sampled

static func _budget_procedural_mesh(source: Mesh, near_budgets: Array, mid_budgets: Array, far_budgets: Array) -> Mesh:
	var mesh := ArrayMesh.new()
	var near_total := 0
	var mid_total := 0
	var far_total := 0
	for si in range(source.get_surface_count()):
		var arrays: Array = source.surface_get_arrays(si).duplicate()
		var source_indices := _surface_indices(arrays)
		if source_indices.is_empty():
			continue
		var near_indices := _sample_indices(source_indices, _surface_budget(near_budgets, si, 18000))
		var mid_indices := _sample_indices(source_indices, _surface_budget(mid_budgets, si, 9000))
		var far_indices := _sample_indices(source_indices, _surface_budget(far_budgets, si, 3000))
		arrays[Mesh.ARRAY_INDEX] = near_indices
		var lods: Dictionary = {}
		if mid_indices.size() < near_indices.size():
			lods[_LOD_MID_DISTANCE] = mid_indices
		if far_indices.size() < mid_indices.size():
			lods[_LOD_FAR_DISTANCE] = far_indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], lods)
		mesh.surface_set_material(si, source.surface_get_material(si))
		near_total += near_indices.size() / 3
		mid_total += mid_indices.size() / 3
		far_total += far_indices.size() / 3
	_set_lod_contract(mesh, near_total, mid_total, far_total)
	return mesh

static func _set_lod_contract(mesh: ArrayMesh, near_total: int, mid_total: int, far_total: int) -> void:
	assert(_LOD_MID_DISTANCE < _LOD_FAR_DISTANCE, "SaisiesTrees LOD distance keys are reversed")
	assert(near_total > mid_total and mid_total > far_total, "SaisiesTrees LOD triangle counts are not descending")
	mesh.set_meta("saisies_triangle_budget", {"near": near_total, "mid": mid_total, "far": far_total})
	mesh.set_meta("saisies_lod_thresholds", [_LOD_MID_DISTANCE, _LOD_FAR_DISTANCE])

static func _surface_indices(arrays: Array) -> PackedInt32Array:
	var indices = arrays[Mesh.ARRAY_INDEX]
	if indices is PackedInt32Array and not indices.is_empty():
		return indices
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	if not vertices is PackedVector3Array or vertices.is_empty():
		return PackedInt32Array()
	var sequential := PackedInt32Array()
	sequential.resize(vertices.size())
	for i in range(vertices.size()):
		sequential[i] = i
	return sequential

static func _scale_surface_arrays(arrays: Array, scale: Vector3) -> void:
	var transform := Basis.IDENTITY.scaled(scale)
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	if vertices is PackedVector3Array:
		var scaled_vertices := PackedVector3Array()
		scaled_vertices.resize(vertices.size())
		for i in range(vertices.size()):
			scaled_vertices[i] = transform * vertices[i]
		arrays[Mesh.ARRAY_VERTEX] = scaled_vertices
	var normals = arrays[Mesh.ARRAY_NORMAL]
	var normal_transform := transform.inverse().transposed().orthonormalized()
	if normals is PackedVector3Array:
		var scaled_normals := PackedVector3Array()
		scaled_normals.resize(normals.size())
		for i in range(normals.size()):
			scaled_normals[i] = (normal_transform * normals[i]).normalized()
		arrays[Mesh.ARRAY_NORMAL] = scaled_normals
	var tangents = arrays[Mesh.ARRAY_TANGENT]
	if tangents is PackedFloat32Array and tangents.size() >= 4:
		var scaled_tangents := PackedFloat32Array()
		scaled_tangents.resize(tangents.size())
		for i in range(0, tangents.size(), 4):
			var tangent := (normal_transform * Vector3(tangents[i], tangents[i + 1], tangents[i + 2])).normalized()
			scaled_tangents[i] = tangent.x
			scaled_tangents[i + 1] = tangent.y
			scaled_tangents[i + 2] = tangent.z
			scaled_tangents[i + 3] = tangents[i + 3]
		arrays[Mesh.ARRAY_TANGENT] = scaled_tangents

static func _make_scanned_leaf_cards(scale: Vector3, seed_: int, round_crown := false) -> Mesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var height := 3.35 * scale.y
	var radius_x := 1.62 * scale.x
	var radius_z := 1.46 * scale.z
	var bottom := height * 0.24
	var top := height * 0.96
	# Each 0.8..1.5m card is a twig cluster texture containing several small
	# leaves from the official PNG.  This preserves a continuous crown at mid
	# and far LODs without turning one quad into one oversized leaf.
	for i in range(720):
		var layer := rng.randf()
		var branch_index := rng.randi_range(0, 9)
		var angle := TAU * float(branch_index) / 10.0 + rng.randf_range(-0.24, 0.24)
		var ring := lerpf(0.12, 1.0, pow(rng.randf(), 0.58))
		var crown_width := 0.76 + 0.24 * sin(PI * layer)
		if round_crown:
			# Taper the caps and break the circular outline into broad lobes.
			# The default retains the exact legacy crown for accepted scenes.
			crown_width = (0.16 + 0.84 * sqrt(sin(PI * layer))) * (0.91 + 0.09 * sin(angle * 3.0 + float(seed_)))
		var branch_sway := Vector3(cos(angle), 0.0, sin(angle)) * rng.randf_range(-0.18, 0.22)
		var center := Vector3(
			cos(angle) * radius_x * ring * crown_width + branch_sway.x + rng.randf_range(-0.16, 0.16),
			lerpf(bottom, top, layer) + rng.randf_range(-0.28, 0.28),
			sin(angle) * radius_z * ring * crown_width + branch_sway.z + rng.randf_range(-0.16, 0.16)
		)
		var width := rng.randf_range(0.82, 1.38)
		var leaf_height := width * rng.randf_range(0.72, 1.08)
		var yaw := rng.randf() * TAU
		var rect := _leaf_cluster_rect(rng.randi_range(0, 3))
		_atlas_card(st, center, width, leaf_height, yaw, rect)
		_atlas_card(st, center + Vector3(rng.randf_range(-0.10, 0.10), rng.randf_range(-0.08, 0.08), rng.randf_range(-0.10, 0.10)), width * rng.randf_range(0.84, 0.97), leaf_height * rng.randf_range(0.84, 0.97), yaw + PI * 0.5, rect)
	st.generate_normals()
	return st.commit()

static func _leaf_cluster_rect(index: int) -> Rect2:
	var inset := 0.012
	var span := 0.5 - inset * 2.0
	var column := posmod(index, 2)
	var row := posmod(index / 2, 2)
	return Rect2(float(column) * 0.5 + inset, float(row) * 0.5 + inset, span, span)

static func _leaf_cluster_atlas() -> Texture2D:
	if _leaf_cluster_cache != null:
		return _leaf_cluster_cache
	var source_texture := load("res://assets/models/saisies_island_tree_02/saisies_island_tree_02_leaves_diff_1k.png") as Texture2D
	if source_texture == null:
		return null
	var source := source_texture.get_image()
	if source == null or source.is_empty():
		return null
	var atlas := Image.create(512, 512, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0.0, 0.0, 0.0, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 517
	var offsets := [
		Vector2i(20, 62), Vector2i(67, 25), Vector2i(112, 76),
		Vector2i(160, 30), Vector2i(190, 84), Vector2i(48, 142),
		Vector2i(124, 142), Vector2i(184, 146)
	]
	for variant in range(4):
		var cell_origin := Vector2i((variant % 2) * 256, (variant / 2) * 256)
		for leaf_index in range(offsets.size()):
			var source_rect_norm := _leaf_atlas_rect(posmod(variant * 3 + leaf_index, 8))
			var src_rect := Rect2i(
				int(source_rect_norm.position.x * float(source.get_width())),
				int(source_rect_norm.position.y * float(source.get_height())),
				maxi(1, int(source_rect_norm.size.x * float(source.get_width()))),
				maxi(1, int(source_rect_norm.size.y * float(source.get_height())))
			)
			var leaf := source.get_region(src_rect)
			var target_width := rng.randi_range(22, 38)
			var target_height := rng.randi_range(48, 82)
			leaf.resize(target_width, target_height, Image.INTERPOLATE_LANCZOS)
			var dst: Vector2i = cell_origin + offsets[leaf_index]
			atlas.blend_rect(leaf, Rect2i(0, 0, target_width, target_height), dst)
	atlas.generate_mipmaps()
	_leaf_cluster_cache = ImageTexture.create_from_image(atlas)
	return _leaf_cluster_cache

static func _leaf_atlas_rect(index: int) -> Rect2:
	var rects := [
		Rect2(0.012, 0.018, 0.145, 0.485),
		Rect2(0.172, 0.018, 0.180, 0.485),
		Rect2(0.365, 0.022, 0.135, 0.462),
		Rect2(0.518, 0.038, 0.158, 0.438),
		Rect2(0.694, 0.016, 0.165, 0.498),
		Rect2(0.012, 0.570, 0.184, 0.414),
		Rect2(0.212, 0.570, 0.185, 0.422),
		Rect2(0.438, 0.576, 0.184, 0.414),
	]
	return rects[posmod(index, rects.size())]

static func _atlas_card(st: SurfaceTool, center: Vector3, width: float, height: float, yaw: float, rect: Rect2) -> void:
	var right := Vector3(cos(yaw), 0.0, sin(yaw)).normalized()
	var up := Vector3(sin(yaw) * 0.10, 0.995, cos(yaw) * 0.10).normalized()
	var half_right := right * width * 0.5
	var half_up := up * height * 0.5
	var q := [center - half_right - half_up, center + half_right - half_up, center + half_right + half_up, center - half_right + half_up]
	var uv := [
		Vector2(rect.position.x, rect.position.y + rect.size.y),
		Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y),
		Vector2(rect.position.x + rect.size.x, rect.position.y),
		Vector2(rect.position.x, rect.position.y),
	]
	var normal := right.cross(up).normalized()
	st.set_color(Color.WHITE)
	st.set_normal(normal)
	for k in [0, 1, 2, 0, 2, 3]:
		st.set_uv(uv[k])
		st.add_vertex(q[k])

## Leaf clusters are generated once per factory call.  The fixed seed keeps
## every run and every MultiMesh build identical while still giving leaves a
## visible midrib and a few brown twigs inside each card.
static func _leaf_atlas() -> ImageTexture:
	var img := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for k in range(5):
		var a := Vector2(128, 128) + Vector2(rng.randf_range(-20, 20), rng.randf_range(-20, 20))
		var b := Vector2(rng.randf_range(10, 246), rng.randf_range(10, 246))
		for t in range(60):
			var q := a.lerp(b, float(t) / 60.0)
			img.set_pixel(clampi(int(q.x), 0, 255), clampi(int(q.y), 0, 255), Color(0.25, 0.20, 0.15, 1))
	for k in range(130):
		var c := Vector2(rng.randf_range(16, 240), rng.randf_range(16, 240))
		if c.distance_to(Vector2(128, 128)) > 118.0:
			continue
		var ang := rng.randf() * TAU
		var ln := rng.randf_range(10.0, 18.0)
		var wd := ln * rng.randf_range(0.45, 0.60)
		var v := rng.randf_range(0.62, 1.0)
		var ax := Vector2(cos(ang), sin(ang))
		for y in range(int(c.y - ln), int(c.y + ln) + 1):
			for x in range(int(c.x - ln), int(c.x + ln) + 1):
				var d := Vector2(x, y) - c
				var along := d.dot(ax)
				var across := d.dot(Vector2(-ax.y, ax.x))
				if (along / ln) * (along / ln) + (across / wd) * (across / wd) <= 1.0 and x >= 0 and y >= 0 and x < 256 and y < 256:
					var shade := v * (0.82 if absf(across) < 0.8 else 1.0) * lerpf(1.05, 0.85, (along / ln) * 0.5 + 0.5)
					img.set_pixel(x, y, Color(shade, shade, shade, 1))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

static func _needle_atlas() -> ImageTexture:
	var img := Image.create(256, 128, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var twigs: Array = [[Vector2(0, 64), Vector2(255, 60)]]
	for k in range(7):
		var x := rng.randf_range(30, 220)
		twigs.append([Vector2(x, 63), Vector2(x + rng.randf_range(30, 60), 63 + (1 if k % 2 == 0 else -1) * rng.randf_range(25, 45))])
	for tw in twigs:
		var a: Vector2 = tw[0]
		var b: Vector2 = tw[1]
		var n := maxi(1, int(a.distance_to(b) / 2.0))
		for t in range(n):
			var q := a.lerp(b, float(t) / n)
			var dir := (b - a).normalized()
			for sgn in [-1.0, 1.0]:
				var nd := dir.rotated(sgn * rng.randf_range(0.7, 1.2))
				var ln := rng.randf_range(7.0, 13.0) * (1.0 - 0.4 * float(t) / n)
				var v := rng.randf_range(0.55, 1.0)
				for u in range(int(ln)):
					var p := q + nd * u
					if p.x >= 0 and p.y >= 0 and p.x < 256 and p.y < 128:
						_dot(img, p, Color(v, v, v, 1), 1)
			_dot(img, q, Color(0.3, 0.25, 0.2, 1), 1)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

static func _dot(img: Image, p: Vector2, color: Color, radius: int) -> void:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dy * dy > radius * radius + 1:
				continue
			var x := int(p.x) + dx
			var y := int(p.y) + dy
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				img.set_pixel(x, y, color)

static func _bark_limb(st: SurfaceTool, a: Vector3, b: Vector3, r0: float, r1: float, v0: float) -> float:
	var d := (b - a).normalized()
	var side := d.cross(Vector3.UP if absf(d.y) < 0.95 else Vector3.RIGHT).normalized()
	var up := side.cross(d)
	var v1 := v0 + a.distance_to(b) / 1.5
	var around := TAU * maxf(r0, 0.05) / 1.5
	for i in range(6):
		var a0 := TAU * i / 6.0
		var a1 := TAU * (i + 1) / 6.0
		var n0 := side * cos(a0) + up * sin(a0)
		var n1 := side * cos(a1) + up * sin(a1)
		var verts := [
			[a + n0 * r0, n0, Vector2(i / 6.0 * around, v0)],
			[b + n0 * r1, n0, Vector2(i / 6.0 * around, v1)],
			[b + n1 * r1, n1, Vector2((i + 1) / 6.0 * around, v1)],
			[a + n0 * r0, n0, Vector2(i / 6.0 * around, v0)],
			[b + n1 * r1, n1, Vector2((i + 1) / 6.0 * around, v1)],
			[a + n1 * r0, n1, Vector2((i + 1) / 6.0 * around, v0)],
		]
		for vert in verts:
			st.set_normal(vert[1])
			st.set_uv(vert[2])
			st.add_vertex(vert[0])
	return v1

## One foliage card.  `along` turns the card into a branch/needle spray while
## the default mode makes a crossed, irregular leaf card around its centre.
static func _card(st: SurfaceTool, c: Vector3, n: Vector3, size_u: float, size_v: float, col: Color, nrm: Vector3, along := Vector3.ZERO) -> void:
	var t := along if along != Vector3.ZERO else n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var b := n.cross(t).normalized()
	var q := [c - b * size_v * 0.5, c + t * size_u - b * size_v * 0.5, c + t * size_u + b * size_v * 0.5, c + b * size_v * 0.5] if along != Vector3.ZERO \
			else [c - t * size_u * 0.5 - b * size_v * 0.5, c + t * size_u * 0.5 - b * size_v * 0.5, c + t * size_u * 0.5 + b * size_v * 0.5, c - t * size_u * 0.5 + b * size_v * 0.5]
	var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	st.set_color(col)
	st.set_normal(nrm)
	for k in [0, 1, 2, 0, 2, 3]:
		st.set_uv(uvs[k])
		st.add_vertex(q[k])

static func _two_surfaces(bark: SurfaceTool, bark_mat: Material, leaves: SurfaceTool, leaf_mat: Material, dense: SurfaceTool, dense_mat: Material) -> Mesh:
	var m := bark.commit()
	leaves.commit(m)
	dense.commit(m)
	m.surface_set_material(0, bark_mat)
	m.surface_set_material(1, leaf_mat)
	m.surface_set_material(2, dense_mat)
	return m

static func _append_clump(st: SurfaceTool, shape: SphereMesh, center: Vector3, scale: Vector3, yaw: float) -> void:
	var basis := Basis(Vector3.UP, yaw).scaled(scale)
	st.append_from(shape, 0, Transform3D(basis, center))

## European beech silhouette: a tall, bare lower trunk, angled limbs and a
## broad crown of hundreds of overlapping alpha-cut leaf clusters.
static func _make_beech(seed_: int, leaf: Color, leaf_mat: Material, bark_mat: Material) -> Mesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var bk := SurfaceTool.new()
	bk.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lf := SurfaceTool.new()
	lf.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dense := SurfaceTool.new()
	dense.begin(Mesh.PRIMITIVE_TRIANGLES)
	var clump_shape := SphereMesh.new()
	clump_shape.radius = 1.0
	clump_shape.height = 2.0
	clump_shape.radial_segments = 8
	clump_shape.rings = 4
	var h := rng.randf_range(14.0, 20.0)
	var pts: Array[Vector3] = [Vector3.ZERO]
	for k in range(6):
		pts.append(Vector3(rng.randf_range(-0.35, 0.35), h * 0.88 * (k + 1) / 6.0, rng.randf_range(-0.35, 0.35)))
	var v := 0.0
	for k in range(6):
		v = _bark_limb(bk, pts[k], pts[k + 1], lerpf(0.30, 0.07, float(k) / 6.0), lerpf(0.30, 0.07, float(k + 1) / 6.0), v)
	var tips: Array[Vector3] = [pts[6] + Vector3(0, 0.8, 0)]
	for k in range(rng.randi_range(7, 10)):
		var t := rng.randf_range(0.35, 0.85)
		var a := rng.randf() * TAU
		var segment := mini(5, int(t * 6.0))
		var base := pts[segment].lerp(pts[segment + 1], fmod(t * 6.0, 1.0))
		var tip := base + Vector3(cos(a) * rng.randf_range(1.9, 3.0), rng.randf_range(1.0, 2.8), sin(a) * rng.randf_range(1.9, 3.0))
		_bark_limb(bk, base, tip, 0.09, 0.03, 0.0)
		tips.append(tip)
	var crown := Vector3(0, h * 0.72, 0)
	for k in range(4):
		var center := crown + Vector3(rng.randf_range(-0.65, 0.65), rng.randf_range(-1.0, 1.0), rng.randf_range(-0.65, 0.65))
		_append_clump(dense, clump_shape, center, Vector3(1.15, 0.82, 1.15), rng.randf() * TAU)
	for k in range(rng.randi_range(22, 28)):
		var mc: Vector3 = tips[k % tips.size()] + Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-0.9, 0.9), rng.randf_range(-1.0, 1.0))
		var r := rng.randf_range(0.85, 1.35)
		# Opaque low-poly lobes fill the crown between the alpha-cut cards;
		# the cards then add the fine leaf silhouette at the edges.
		_append_clump(dense, clump_shape, mc, Vector3(r * 1.08, r * 0.72, r * 1.08), rng.randf() * TAU)
		for j in range(17):
			var off := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.7, 0.8), rng.randf_range(-1, 1)) * r
			var c := mc + off
			var out := (c - crown).normalized()
			var lit := clampf(0.5 + 0.35 * out.y + 0.25 * off.y / r, 0.0, 1.0)
			var col := leaf * lerpf(0.5, 1.15, lit) * rng.randf_range(0.85, 1.1)
			var sz := rng.randf_range(0.95, 1.55)
			_card(lf, c, Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.4, 1), rng.randf_range(-1, 1)).normalized(), sz, sz, col, (out + Vector3.UP * 0.6).normalized())
	var dense_mat := _dense_mat(leaf * 1.05)
	var raw := _two_surfaces(bk, bark_mat, lf, leaf_mat, dense, dense_mat)
	return _budget_procedural_mesh(raw, _SCANNED_NEAR_BUDGETS, _SCANNED_MID_BUDGETS, _SCANNED_FAR_BUDGETS)

## Spruce/fir silhouette: a straight trunk with a tall bare section and dense
## tiered sprays of crossed needle cards, so it reads as a full woodland tree
## from the road rather than as a stack of primitive cones.
static func _make_conifer(seed_: int, bare: float, palette: Array, density: float, bark_mat: Material, needle_mat: Material) -> Mesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var bk := SurfaceTool.new()
	bk.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lf := SurfaceTool.new()
	lf.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dense := SurfaceTool.new()
	dense.begin(Mesh.PRIMITIVE_TRIANGLES)
	var clump_shape := SphereMesh.new()
	clump_shape.radius = 1.0
	clump_shape.height = 2.0
	clump_shape.radial_segments = 8
	clump_shape.rings = 3
	var h := rng.randf_range(14.0, 22.0)
	var v := 0.0
	for k in range(5):
		v = _bark_limb(bk, Vector3(0, h * k / 5.0, 0), Vector3(0, h * (k + 1) / 5.0, 0), lerpf(0.34, 0.04, float(k) / 5.0), lerpf(0.34, 0.04, float(k + 1) / 5.0), v)
	var y_low := bare * h
	var rmax := rng.randf_range(3.10, 3.70)
	var y := y_low
	while y < h - 0.3:
		var t := (y - y_low) / (h - y_low)
		var r := rmax * pow(1.0 - t, 0.9) + 0.25
		for k in range(int(rng.randi_range(8, 11) * density)):
			var a := rng.randf() * TAU
			var dir := Vector3(cos(a), -0.15 - 0.35 * (1.0 - t) * rng.randf_range(0.6, 1.2), sin(a)).normalized()
			var base := Vector3(0, y, 0)
			var shade := clampf(0.35 + 0.65 * t + rng.randf_range(-0.15, 0.15), 0.0, 1.0)
			var col: Color = (palette[0] as Color).lerp(palette[1], shade).lerp(palette[2], maxf(shade - 0.6, 0.0) * 1.5)
			var w := 0.45 + r * 0.22
			var flat := dir.cross(Vector3.UP).normalized()
			_card(lf, base, Vector3.UP, r, w, col, (dir + Vector3.UP * 0.8).normalized(), dir)
			_card(lf, base, flat, r, w * 0.8, col * 0.85, (dir + Vector3.UP * 0.5).normalized(), dir)
			# A compact opaque bough pad prevents the tree from collapsing to a
			# black trunk when the needle texture minifies at road distance.
			# Stretch two overlapping opaque pads along each individual bough
			# instead of forming a repeated cone ring.  Random vertical offsets
			# keep the dense summer crown irregular from every camera angle.
			var yaw := PI * 0.5 - a
			var pad_base := base + dir * r * 0.34 + Vector3(0, rng.randf_range(-0.18, 0.22), 0)
			_append_clump(dense, clump_shape, pad_base, Vector3(maxf(0.52, r * 0.26), maxf(0.42, w * 0.66), maxf(0.78, r * 0.64)), yaw)
			_append_clump(dense, clump_shape, base + dir * r * 0.72 + Vector3(0, rng.randf_range(-0.13, 0.18), 0), Vector3(maxf(0.40, r * 0.18), maxf(0.28, w * 0.44), maxf(0.48, r * 0.40)), yaw + rng.randf_range(-0.22, 0.22))
		y += rng.randf_range(0.62, 0.95)
	var dense_color: Color = (palette[1] as Color).lerp(palette[2], 0.35)
	dense.generate_normals()
	var raw := _two_surfaces(bk, bark_mat, lf, needle_mat, dense, _dense_mat(dense_color))
	return _budget_procedural_mesh(raw, _SCANNED_NEAR_BUDGETS, _SCANNED_MID_BUDGETS, _SCANNED_FAR_BUDGETS)
