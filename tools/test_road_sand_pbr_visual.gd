extends SceneTree
## Verifies the opt-in licensed PBR maps, mip generation, normal convention and scope.
const Viewer = preload("res://scripts/package_preview.gd")

func _initialize() -> void:
	var viewer := Viewer.new()
	var config: Dictionary = viewer._read("res://data/gold_coast_s17_s19_sand_pbr_visual.json")
	var overrides: Array = config.overrides
	assert(viewer._road_surface_visual_override("road_concrete", 8700.0, []).is_empty())
	assert(viewer._road_surface_visual_override("road_concrete", 8500.0, overrides).is_empty())
	assert(viewer._road_surface_visual_override("road_asphalt", 8700.0, overrides).is_empty())
	assert(viewer._road_surface_visual_override("road_gravel", 8700.0, overrides).is_empty())
	assert(viewer._road_surface_visual_override("terrain_ground", 8700.0, overrides).is_empty())
	var style: Dictionary = viewer._road_surface_visual_override("road_concrete", 8700.0, overrides)
	assert(style.appearance == "polyhaven_coast_sand_pbr")
	assert(viewer._road_surface_visual_override("road_dirt", 9000.0, overrides).appearance == "polyhaven_coast_sand_pbr")
	assert(viewer._road_surface_visual_override("road_concrete", 10000.0, overrides).is_empty())
	assert(is_equal_approx(float(style.texture_repeat_m), 0.4))
	assert(style.source_asset.license == "CC0")
	assert(style.source_asset.author == "Rob Tuytel")

	var shader_code: String = viewer._sand_pbr_road_shader(Vector3(0.42, 0.33, 0.24), style)
	assert(shader_code.contains("uniform sampler2D sand_diffuse : source_color"))
	assert(shader_code.contains("uniform sampler2D sand_normal : hint_normal"))
	assert(shader_code.contains("filter_linear_mipmap_anisotropic, repeat_enable"))
	assert(shader_code.contains("NORMAL_MAP=normal_sample"))
	assert(shader_code.contains("NORMAL_MAP_DEPTH=sand_normal_depth"))
	assert(shader_code.contains("texture(sand_roughness,sand_uv).r"))
	assert(shader_code.contains("road_uv+warp*sand_uv_warp_m"))
	assert(shader_code.contains("hash(floor(world.xz*55.0))"))
	assert(shader_code.contains("sin(world.x*.23+sin(world.z*.19))*sin(world.z*.35)*.04"))
	assert(shader_code.contains("road_uv.y >= "))

	var diffuse: Texture2D = viewer._load_sand_pbr_texture(style.textures.diffuse, false)
	var normal: Texture2D = viewer._load_sand_pbr_texture(style.textures.normal_opengl, true)
	var roughness: Texture2D = viewer._load_sand_pbr_texture(style.textures.roughness, false)
	for texture in [diffuse, normal, roughness]:
		assert(texture != null)
		var image: Image = texture.get_image()
		assert(image.get_width() == 1024 and image.get_height() == 1024)
		assert(image.has_mipmaps() and image.get_mipmap_count() == 10)
	assert(normal.get_image().get_format() == Image.FORMAT_RGB8)
	assert(roughness.get_image().get_format() == Image.FORMAT_L8)
	var normal_center: Color = normal.get_image().get_pixel(512, 512)
	assert(normal_center.r > 0.4 and normal_center.r < 0.6)
	assert(normal_center.g > 0.4 and normal_center.g < 0.6)
	assert(normal_center.b > 0.9)
	assert(viewer._load_sand_pbr_texture(style.textures.normal_opengl, true) == normal)
	var manifest: Dictionary = viewer._read("res://export/packages/gold_coast_broadwater_s18_r12_luna6/manifest.json")
	var road_surface_count := 0
	for tile in manifest.tiles:
		var road_root: Node3D = viewer._load_glb("res://export/packages/gold_coast_broadwater_s18_r12_luna6".path_join(tile.files.road))
		road_surface_count += _assert_uv_tangents(road_root)
		road_root.free()
	assert(road_surface_count == 61)

	viewer.camera.free()
	viewer.tiles.free()
	viewer.label.free()
	viewer.free()
	print("ROAD_SAND_PBR_VISUAL_TEST_OK; opt-in scope, CC0 PBR maps, mipmaps, OpenGL normal, 61 UV tangent surfaces and filters")
	quit()

func _assert_uv_tangents(node: Node) -> int:
	var count := 0
	if node is MeshInstance3D:
		for i in range(node.mesh.get_surface_count()):
			var format: int = node.mesh.surface_get_format(i)
			assert(format & Mesh.ARRAY_FORMAT_TEX_UV != 0)
			assert(format & Mesh.ARRAY_FORMAT_TANGENT != 0)
			count += 1
	for child in node.get_children(): count += _assert_uv_tangents(child)
	return count
