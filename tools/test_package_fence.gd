extends SceneTree

const PackagePreview = preload("res://scripts/package_preview.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var preview = PackagePreview.new()
	preview.objects = {
		"lattice": {
			"semantic_type": "fence",
			"prototype": "fence_lattice",
			"dimensions_m": {"height": 1.0, "thickness": 0.05, "post_spacing": 2.0}
		},
		"timber": {
			"semantic_type": "fence",
			"prototype": "fence_timber_rail",
			"dimensions_m": {"height": 1.05, "thickness": 0.09, "post_spacing": 2.2}
		},
		"legacy": {"semantic_type": "fence", "prototype": "fence_rail"}
	}
	var line := {"object_id": "lattice", "points": [[0.0, 0.0, 0.0], [5.0, 0.0, 0.0]]}
	var lattice_holder := Node3D.new()
	root.add_child(lattice_holder)
	preview.call("_barrier", lattice_holder, line)
	var posts := 0
	var panels := 0
	var rails := 0
	var mesh_texture: ImageTexture
	for child in lattice_holder.get_children():
		if child.name.begins_with("FenceTimberPost_"): posts += 1
		elif child.name.begins_with("FenceMeshPanel_"):
			panels += 1
			mesh_texture = child.material_override.albedo_texture
		elif child.name.begins_with("FenceTimberTopRail_"): rails += 1
	assert(posts == 4, "fence_lattice uses the authored 2 m post spacing")
	assert(panels == 1 and mesh_texture != null, "fence_lattice draws a procedural green mesh panel")
	assert(mesh_texture.get_image().get_pixel(0, 0).a > mesh_texture.get_image().get_pixel(3, 3).a, "mesh wires have visible contrast against the green net")
	assert(rails == 1, "fence_lattice draws one timber top rail per segment")

	var timber_holder := Node3D.new()
	root.add_child(timber_holder)
	preview.call("_barrier", timber_holder, {"object_id": "timber", "points": line.points})
	var dark_posts := 0
	var dark_top_rails := 0
	var dark_lower_rails := 0
	for child in timber_holder.get_children():
		if child.name.begins_with("FenceDarkTimberPost_"): dark_posts += 1
		elif child.name.begins_with("FenceDarkTimberTopRail_"): dark_top_rails += 1
		elif child.name.begins_with("FenceDarkTimberLowerRail_"): dark_lower_rails += 1
	assert(dark_posts == 4 and dark_top_rails == 1 and dark_lower_rails == 1,
		"fence_timber_rail draws spaced posts and two rails")
	var dark_material: StandardMaterial3D = timber_holder.get_child(0).material_override
	assert(dark_material.albedo_color.is_equal_approx(Color(0.24, 0.17, 0.11)),
		"fence_timber_rail uses the authored dark timber material")

	var legacy_holder := Node3D.new()
	root.add_child(legacy_holder)
	preview.call("_barrier", legacy_holder, {"object_id": "legacy", "points": line.points})
	assert(legacy_holder.get_child_count() == 5, "non-lattice fence keeps the existing three rails and two posts")
	var old_rail: StandardMaterial3D = legacy_holder.get_child(0).material_override
	assert(old_rail.albedo_color.is_equal_approx(Color(0.91, 0.92, 0.89)), "legacy rail material remains unchanged")
	print("PACKAGE_FENCE_STYLE_TEST_OK")
	legacy_holder.free()
	timber_holder.free()
	lattice_holder.free()
	preview.camera.free()
	preview.tiles.free()
	preview.label.free()
	preview.free()
	quit()
