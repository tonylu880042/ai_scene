extends SceneTree
## Shared preview surface library: known names get triplanar PBR (when assets/ is present), others are untouched.

const PackagePreview = preload("res://scripts/package_preview.gd")
const GroundDetail = preload("res://scripts/package_preview_ground_detail.gd")

class StraightRoute extends RefCounted:  # route along +X at z = 0
	var length := 200.0
	func position_at(s: float) -> Vector3: return Vector3(s, 0.0, 0.0)

func _check_prototype_library(viewer) -> void:
	# Substitutes are fitted to the package mesh height; unknown ids keep the package mesh.
	var package_mesh := BoxMesh.new()
	package_mesh.size = Vector3(2, 12.2, 2)
	assert(viewer._library_variants("rock_small", package_mesh).is_empty())
	var variants: Array = viewer._library_variants("tropical_palm", package_mesh)
	if variants.is_empty(): return  # assets/models not present
	assert(variants.size() == PackagePreview.PROTOTYPE_LIBRARY.tropical_palm.size())
	for v in variants:
		assert(is_equal_approx(v.mesh.get_aabb().size.y * v.fit.basis.get_scale().y, 12.2))

func _check_grass() -> void:
	# Flat 2 m grid of terrain_ground (x 25..85, z -30..30 after the mesh offset), a vertical bank and a sand
	# patch: grass lands only on the flat ground and within the lateral limit (centroid test, so +1 cell).
	var mesh := ArrayMesh.new()
	var flat := PackedVector3Array()
	for x in range(20, 80, 2):
		for z in range(-30, 30, 2):
			flat.append_array([Vector3(x,0,z), Vector3(x+2,0,z), Vector3(x+2,0,z+2), Vector3(x,0,z), Vector3(x+2,0,z+2), Vector3(x,0,z+2)])
	var bank := PackedVector3Array([Vector3(20,0,5), Vector3(80,0,5), Vector3(80,3,5), Vector3(20,0,5), Vector3(80,3,5), Vector3(20,3,5)])
	var sand := PackedVector3Array([Vector3(20,1,-30), Vector3(80,1,-30), Vector3(80,1,30)])
	for spec in [["terrain_ground", flat], ["terrain_ground", bank], ["shore_sand", sand]]:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = spec[1]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material := StandardMaterial3D.new()
		material.resource_name = spec[0]
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	var root := Node3D.new()
	var terrain := MeshInstance3D.new()
	terrain.mesh = mesh
	terrain.position = Vector3(5, 0, 0)
	root.add_child(terrain)
	var cells: Dictionary = GroundDetail.sample_terrain_grass(root, StraightRoute.new(), 0.0, 200.0, 7)
	var count := 0
	for buffer in cells.values():
		for i in range(0, buffer.size(), 12):
			var p := Vector3(buffer[i + 3], buffer[i + 7], buffer[i + 11])
			assert(absf(p.y) < 1e-4 and p.x >= 25.0 - 1e-3 and p.x <= 85.0 + 1e-3)
			assert(absf(p.z) <= GroundDetail.GRASS_MAX_LATERAL_M + 2.0)
			count += 1
	var reach := 60.0 * 2.0 * GroundDetail.GRASS_MAX_LATERAL_M
	assert(count > reach * GroundDetail.GRASS_FAR_DENSITY and count < reach * GroundDetail.GRASS_NEAR_DENSITY)
	root.free()

func _initialize() -> void:
	var viewer = PackagePreview.new()
	assert(viewer._surface_library_textures("support_skirt").is_empty())
	var maps: Array = viewer._surface_library_textures("terrain_ground")
	if maps.is_empty():
		print("SURFACE_LIBRARY_TEST_SKIPPED; assets/textures not present (flat fallback is used)")
		for node in [viewer.camera, viewer.tiles, viewer.label, viewer]: node.free()
		quit()
		return
	var mean: Color = maps[0].get_meta("mean_linear")
	assert(maps.size() == 3 and mean.get_luminance() > 0.01 and mean.get_luminance() < 1.0)
	var authored := StandardMaterial3D.new()
	authored.resource_name = "terrain_ground"
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3(1, 0, 0), Vector3(0, 0, 1)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, authored)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	viewer._style_meshes(instance)
	var styled: ShaderMaterial = instance.get_surface_override_material(0)
	assert(styled.shader.code == PackagePreview.SURFACE_LIBRARY_SHADER)
	assert(styled.get_shader_parameter("albedo_tex") == maps[0])
	assert(is_equal_approx(styled.get_shader_parameter("mean_luminance"), mean.get_luminance()))
	_check_grass()
	_check_prototype_library(viewer)
	print("SURFACE_LIBRARY_TEST_OK; terrain grass bounded")
	instance.free()
	for node in [viewer.camera, viewer.tiles, viewer.label, viewer]: node.free()
	quit()
