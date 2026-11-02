extends SceneTree

## Bake the generated Saisies environment into an editor-friendly scene.
## The generated file is written under export/ (ignored by the repository), so
## the source scene remains the deterministic runtime entry point.
##
##   godot --path . --script tools/bake_saisies.gd -- \
##     --output=res://export/saisies/MainScene_saisies_baked.tscn
##
## Native compressed output is also supported:
##   godot --path . --script tools/bake_saisies.gd -- \
##     --output=res://export/saisies/SaisiesEnvironment.scn

var _scene_path := "res://scenes/MainScene_saisies.tscn"
var _output := "res://export/saisies/MainScene_saisies_baked.tscn"
var _output_explicit := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scene="):
			_scene_path = arg.substr(8)
		elif arg.begins_with("--output="):
			_output = arg.substr(9)
			_output_explicit = true
	if not _output_explicit and _scene_path.ends_with("MainScene_saisies_v2.tscn"):
		_output = "res://export/saisies/SaisiesEnvironment_v2.scn"
	if _is_unsafe_bake_renderer():
		_refuse_unsafe_bake()
		return
	call_deferred("_bake")

func _is_unsafe_bake_renderer() -> bool:
	var display_name := DisplayServer.get_name().to_lower()
	return OS.has_feature("headless") or display_name.contains("headless") or display_name.contains("dummy")

func _refuse_unsafe_bake() -> void:
	var display_name := DisplayServer.get_name()
	push_error("Saisies bake refused: renderer '%s' is headless/Dummy and cannot preserve MultiMesh instance buffers." % display_name)
	print("Run the bake with a native window (without --headless), for example:")
	print("  godot --path . --script tools/bake_saisies.gd -- --scene=%s --output=%s" % [_scene_path, _output])
	quit(1)

func _bake() -> void:
	var packed := load(_scene_path) as PackedScene
	if packed == null:
		push_error("Saisies bake: source scene could not be loaded: " + _scene_path)
		quit(1)
		return
	var source := packed.instantiate()
	get_root().add_child(source)
	# One frame lets route mesh, static landscape, foliage chunks, roadside props
	# and cloud layer finish building before the generated tree is packed.
	await process_frame
	_strip_generator_scripts(source)
	_set_owners(source, source)
	var baked := PackedScene.new()
	var err := baked.pack(source)
	if err != OK:
		push_error("Saisies bake: PackedScene.pack failed (%d)" % err)
		quit(1)
		return
	var output_path := ProjectSettings.globalize_path(_output)
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var save_flags := ResourceSaver.FLAG_COMPRESS if _output.to_lower().ends_with(".scn") else 0
	err = ResourceSaver.save(baked, _output, save_flags)
	if err != OK:
		push_error("Saisies bake: ResourceSaver.save failed (%d)" % err)
		quit(1)
		return
	print("saisies baked scene: ", output_path)
	quit(0)

func _strip_generator_scripts(node: Node) -> void:
	# The source scene is procedural.  Clear every Saisies generator script
	# recursively so nested SceneryModules children cannot rebuild a second copy
	# when the packed scene is opened in the editor or instantiated later.
	var script := node.get_script() as Script
	if script != null and script.resource_path.begins_with("res://scripts/saisies_"):
		node.set_script(null)
	for child in node.get_children():
		_strip_generator_scripts(child)

func _set_owners(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		_set_owners(child, owner)
