extends SceneTree
## Optional roadside geometry follows logical tiles, not spatial road neighbors.

class FixtureRoute extends RefCounted:
	var length := 3000.0
	func position_at(_s: float) -> Vector3:
		return Vector3.ZERO

class FixtureViewer extends "res://scripts/package_preview.gd":
	func _load_glb(_path: String) -> Node3D:
		return Node3D.new()

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var viewer := FixtureViewer.new()
	viewer.add_child(viewer.tiles)
	viewer.add_child(viewer.camera)
	viewer.add_child(viewer.label)
	viewer.route = FixtureRoute.new()
	viewer.package_dir = "res://fixture"
	viewer.geometry_only = true
	viewer.spatial_geometry_radius_m = 150.0
	var bounds := {"min": [-10, -1, -10], "max": [10, 5, 10]}
	viewer.manifest = {"tiles": [
		{"id": "00", "from_s": 0.0, "to_s": 250.0, "bounds": bounds,
		 "files": {"road": "road.glb", "terrain": "terrain.glb", "roadside": "roadside.glb"}},
		{"id": "08", "from_s": 2000.0, "to_s": 2250.0, "bounds": bounds,
		 "files": {"road": "road.glb", "terrain": "terrain.glb"}}]}
	viewer.progress = 50.0
	viewer._stream()
	var first: bool = viewer.loaded.has("00") and viewer.loaded["00"].get_node_or_null("00_roadside") != null
	var no_adjacent: bool = viewer.adjacent_geometry.has("08") and viewer.adjacent_geometry["08"].get_node_or_null("08_roadside") == null
	viewer.progress = 2050.0
	viewer._stream()
	var absent_ok: bool = viewer.loaded.has("08") and viewer.loaded["08"].get_node_or_null("08_roadside") == null
	var old_unloaded: bool = not viewer.loaded.has("00") and viewer.adjacent_geometry.has("00") and viewer.adjacent_geometry["00"].get_node_or_null("00_roadside") == null
	viewer.progress = 50.0
	viewer._stream()
	var back: bool = viewer.loaded.has("00") and viewer.loaded["00"].get_node_or_null("00_roadside") != null
	for original in viewer.adjacent_original_roads.values(): original.free()
	viewer.adjacent_original_roads.clear()
	viewer.free()
	var ok: bool = first and no_adjacent and absent_ok and old_unloaded and back
	print("PACKAGE_ROADSIDE_STREAM_", "OK" if ok else "FAIL", " ", [first, no_adjacent, absent_ok, old_unloaded, back])
	quit(0 if ok else 1)
