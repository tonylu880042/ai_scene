extends SceneTree

const Preview = preload("res://scripts/package_preview.gd")
const TERRAIN := "res://export/packages/gold_coast_broadwater_shore_infill_r42_luna6/tiles/49/terrain.glb"
const EXPECTED := [
	Vector3(238.4876480102539, 2.465971738100052, 810.024471282959),
	Vector3(238.6645278930664, 2.423297554254532, 810.5845680236816),
	Vector3(238.91961288452148, 2.4130879044532776, 810.7140884399414),
]

func _initialize() -> void:
	call_deferred("_run")

func _collect_meshes(node:Node, output:Array) -> void:
	if node is MeshInstance3D and node.mesh is ArrayMesh:
		output.append(node)
	for child in node.get_children():
		_collect_meshes(child, output)

func _run() -> void:
	assert(Preview._gltf_import_flags_for_path("tiles/49/terrain.glb") == GLTFDocument.IMPORT_FLAG_FORCE_DISABLE_MESH_COMPRESSION)
	assert(Preview._gltf_import_flags_for_path("tiles/49/road.glb") == GLTFDocument.IMPORT_FLAG_FORCE_DISABLE_MESH_COMPRESSION)
	assert(Preview._gltf_import_flags_for_path("prototypes/palm.glb") == 0)
	var result := {}
	for flags in [0, GLTFDocument.IMPORT_FLAG_FORCE_DISABLE_MESH_COMPRESSION]:
		var instance:Node3D
		if flags == GLTFDocument.IMPORT_FLAG_FORCE_DISABLE_MESH_COMPRESSION:
			# Exercise the actual runtime consumer path, including its path-based flag choice.
			instance=Preview._load_glb_document(TERRAIN)
		else:
			var document := GLTFDocument.new()
			var state := GLTFState.new()
			assert(document.append_from_file(TERRAIN, state, 0) == OK)
			instance=document.generate_scene(state)
		root.add_child(instance)
		var meshes := []
		_collect_meshes(instance, meshes)
		var vertices := PackedVector3Array()
		for mesh_instance in meshes:
			for surface in range(mesh_instance.mesh.get_surface_count()):
				var arrays:Array=mesh_instance.mesh.surface_get_arrays(surface)
				for vertex in arrays[Mesh.ARRAY_VERTEX]:
					vertices.append(mesh_instance.global_transform*vertex)
		var errors := []
		for expected in EXPECTED:
			var nearest := INF
			for vertex in vertices:
				nearest=minf(nearest,vertex.distance_to(expected))
			errors.append(nearest)
		result[str(flags)]=errors
		instance.free()
	var precise:Array=result[str(GLTFDocument.IMPORT_FLAG_FORCE_DISABLE_MESH_COMPRESSION)]
	var compressed:Array=result["0"]
	var precise_max:float=precise.max()
	var compressed_max:float=compressed.max()
	assert(precise_max < 0.00005, "uncompressed per-vertex max error %.9fm" % precise_max)
	assert(compressed_max > 0.001, "default-compression control unexpectedly below 1mm: %.9fm" % compressed_max)
	print("PACKAGE_GLTF_PRECISION_OK default_errors_m=", compressed, " precise_errors_m=", precise)
	quit()
