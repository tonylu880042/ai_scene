extends SceneTree

const PackagePreview = preload("res://scripts/package_preview.gd")

func _initialize() -> void:
	var viewer = PackagePreview.new()
	var authored := StandardMaterial3D.new()
	authored.albedo_color = Color(0.30, 0.42, 0.20)
	authored.roughness = 0.61
	authored.resource_name = "support_skirt"
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _triangle_arrays())
	mesh.surface_set_material(0, authored)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	viewer._style_meshes(instance)
	assert(instance.get_surface_override_material(0) == null, "unknown authored material should retain its imported PBR material")
	var preserved := instance.mesh.surface_get_material(0) as StandardMaterial3D
	assert(preserved != null, "support skirt should retain its imported StandardMaterial3D")
	assert(preserved.get_instance_id() == authored.get_instance_id(), "support skirt should retain the exact imported material resource")
	assert(preserved.albedo_color.is_equal_approx(Color(0.30, 0.42, 0.20)), "support skirt must preserve its serialized base color")
	assert(is_equal_approx(preserved.roughness, 0.61), "support skirt should preserve its serialized roughness")
	var adapted := StandardMaterial3D.new()
	adapted.resource_name = "terrain_ground"
	var adapted_mesh := ArrayMesh.new()
	adapted_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _triangle_arrays())
	adapted_mesh.surface_set_material(0, adapted)
	var adapted_instance := MeshInstance3D.new()
	adapted_instance.mesh = adapted_mesh
	viewer._style_meshes(adapted_instance)
	assert(adapted_instance.get_surface_override_material(0) is ShaderMaterial, "named terrain material adaptation must remain active")
	print("support skirt material regression: PASS")
	viewer.add_child(instance)
	viewer.add_child(adapted_instance)
	viewer.camera.free()
	viewer.tiles.free()
	viewer.label.free()
	viewer.free()
	viewer = null
	authored = null
	adapted = null
	mesh = null
	adapted_mesh = null
	instance = null
	adapted_instance = null
	preserved = null
	quit()

func _triangle_arrays() -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.FORWARD, Vector3.FORWARD, Vector3.FORWARD])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	return arrays
