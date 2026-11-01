extends SceneTree
## Physical neighbor roads must fill P1 clips without duplicating return-pass scenery.

class FixtureRoute extends RefCounted:
	var length := 3000.0
	func position_at(_s: float) -> Vector3:
		return Vector3.ZERO

class FixtureViewer extends "res://scripts/package_preview.gd":
	func _load_glb(path: String) -> Node3D:
		var node := Node3D.new()
		node.name = path.get_file().get_basename()
		return node
	func _read(path: String) -> Variant:
		return {"source": path.get_file().get_basename()}
	func _scatter(holder: Node3D, data: Dictionary) -> void:
		var node := Node3D.new()
		node.name = "instances_" + data.source
		holder.add_child(node)

var failures := 0

func _init() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _tile(id: String, station: float, minimum: Array, maximum: Array) -> Dictionary:
	return {"id": id, "from_s": station, "to_s": station + 250.0,
		"bounds": {"min": minimum, "max": maximum},
		"files": {"road": id + "_road.glb", "terrain": id + "_terrain.glb",
			"vegetation": id + "_plants.json", "structures": id + "_props.json"}}

func _count(viewer: Node, name: String) -> int:
	return viewer.tiles.find_children(name, "Node3D", true, false).size()

func _run() -> void:
	var viewer := FixtureViewer.new()
	viewer.add_child(viewer.tiles)
	viewer.add_child(viewer.camera)
	viewer.add_child(viewer.label)
	viewer.route = FixtureRoute.new()
	viewer.package_dir = "res://fixture"
	viewer.manifest = {"tiles": [
		_tile("outbound", 0.0, [-10, -1, -10], [10, 5, 10]),
		_tile("return", 2000.0, [8, -1, -10], [18, 5, 10]),
		_tile("far", 4000.0, [151, -1, 0], [161, 5, 10]),
		_tile("corner", 5000.0, [110, -1, 110], [120, 5, 120])]}
	viewer.progress = 50.0
	viewer._stream()
	_check(_count(viewer, "outbound_road") == 1, "Current route road must load once")
	_check(_count(viewer, "return_road") == 0, "Legacy default remains unchanged")
	viewer.set("spatial_geometry_radius_m", 150.0)
	viewer._stream()
	_check(_count(viewer, "return_road") == 1, "Adjacent physical return road must fill the route-edge gap")
	_check(_count(viewer, "return_terrain") == 0, "Adjacent loading must not add foreign terrain over P1 water/ground")
	_check(_count(viewer, "instances_return_*") == 0, "Return-pass plants/props must not be scattered twice")
	_check(_count(viewer, "far_road") == 0, "Road outside the spatial radius must remain unloaded")
	_check(_count(viewer, "corner_road") == 0, "Use distance to the bounds, not an expanded square")
	viewer.progress = 2050.0
	viewer._stream()
	_check(_count(viewer, "return_road") == 1, "Spatial-to-logical handoff must keep one geometry copy")
	_check(_count(viewer, "instances_return_*") == 2, "Logical return pass must have its plants and props")
	_check(_count(viewer, "outbound_road") == 1, "Former logical pass remains as adjacent geometry")
	_check(_count(viewer, "instances_outbound_*") == 0, "Former logical pass must release its plants and props")
	viewer.set("spatial_geometry_radius_m", 0.0)
	viewer._stream()
	_check(_count(viewer, "outbound_road") == 0, "Disabling spatial geometry must unload its nodes")
	_check(_count(viewer, "return_road") == 1, "Disabling spatial geometry preserves the logical road")
	viewer.progress = 50.0
	viewer.set("spatial_geometry_radius_m", 150.0)
	viewer._stream()
	_check(_count(viewer, "outbound_road") == 1, "Reverse traversal returns the outbound tile to the logical window")
	_check(_count(viewer, "return_road") == 1, "Reverse handoff remasks the return tile from its original source")
	_check(_count(viewer, "instances_return_*") == 0, "Reverse spatial loading does not scatter return-pass objects")
	for original in viewer.adjacent_original_roads.values(): original.free()
	viewer.adjacent_original_roads.clear()
	viewer.free()
	if failures == 0:
		print("PACKAGE_SPATIAL_GEOMETRY_TEST_OK")
	quit(1 if failures else 0)
