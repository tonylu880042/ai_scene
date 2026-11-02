class_name SaisiesReleaseTerminals
extends Node3D

## Small authored terminal set dressing for the whole-route release.
##
## The route and its frozen terrain remain the source of truth.  This module
## only adds a readable departure marker and a deliberately compact alpine
## arrival square beyond the last route sample.  All geometry is generated in
## route space so the cache bake can flatten it together with the other release
## overlays without changing the road or its centreline.

@export var world_path: NodePath
@export var landscape_path: NodePath
@export_file("*.json") var candidate_path := "res://data/saisies_release_terminals.json"
@export var enable_refinement := true

const RELEASE_STATUS := "root_selected_for_integrated_review"
const VISUAL_ACCEPTANCE := "pending"
const EXPECTED_ROUTE_LENGTH_M := 14615.087922
const START_SIGN_STATION_M := 14.0
const START_SIGN_LATERAL_M := 6.8
const FINISH_OFFSET_M := 16.0
const ARRIVAL_START_OFFSET_M := 22.0
const ARRIVAL_END_OFFSET_M := 180.0

var _world: Node3D
var _route: Node
var _landscape: Node
var _terrain_sampler: Node
var _candidate: Dictionary = {}
var _start_root: Node3D
var _finish_root: Node3D
var _arrival_root: Node3D
var _initialized := false
var _build_attempts := 0
var _mesh_count := 0
var _label_count := 0
var _ground_sample_count := 0
var _ground_fallback_count := 0
var _materials: Dictionary = {}
var _live_geometry_suppressed := false

func _ready() -> void:
	process_priority = -185
	call_deferred("_try_initialize")

func _process(_delta: float) -> void:
	if not _initialized:
		return
	_set_geometry_visible(enable_refinement)
	_publish_state()

func set_release_enabled(enabled: bool) -> bool:
	enable_refinement = enabled
	visible = enabled
	_set_geometry_visible(enabled)
	_publish_state()
	return true

func _try_initialize() -> void:
	if _initialized:
		return
	if not _load_candidate():
		return
	if not _resolve_nodes():
		_retry("release terminals are waiting for World/Route")
		return
	if not _route.has_method("route_ready") or not bool(_route.call("route_ready")):
		_retry("release terminals are waiting for the geographic route")
		return
	if _has_baked_terminal_cache():
		# The cached wrapper carries the same terminal meshes and labels after a
		# native bake.  Keep this live module as a readiness/metadata shim there;
		# an old cache without this marker still receives the live terminal set for
		# quick endpoint inspection.
		_live_geometry_suppressed = true
		_initialized = true
		set_meta("saisies_release_terminals_cache_source", "native_baked_terminal_geometry")
		_publish_state()
		return
	if not _build_terminals():
		_fail("release terminals could not build finite endpoint geometry")
		return
	_initialized = true
	_set_geometry_visible(enable_refinement)
	_publish_state()

func _has_baked_terminal_cache() -> bool:
	var cache_gate := get_parent().get_node_or_null("ReleaseCacheGate") if get_parent() != null else null
	var cache := cache_gate.get_node_or_null("ReleaseGeometryCache") if cache_gate != null else null
	return cache != null and int(cache.get_meta("saisies_release_cache_terminal_geometry_count", 0)) > 0

func _resolve_nodes() -> bool:
	_world = get_node_or_null(world_path) as Node3D if not world_path.is_empty() else null
	if _world == null and get_parent() != null:
		_world = get_parent().get_node_or_null("World") as Node3D
	if _world == null:
		return false
	_route = _world.get_node_or_null("Route")
	if _route == null:
		for candidate in _world.find_children("*", "", true, false):
			if candidate.has_method("route_ready") and candidate.has_method("pos_at"):
				_route = candidate
				break
	if _route == null:
		return false
	_resolve_landscape()
	return _route.has_method("pos_at") and _route.has_method("left_at") and _route.has_method("tangent_at") and _route.has_method("ground_y")

func _resolve_landscape() -> void:
	_landscape = get_node_or_null(landscape_path) if not landscape_path.is_empty() else null
	if _landscape == null:
		_landscape = _world.find_child("Landscape", true, false)
	if _landscape != null and _landscape.has_method("sample_mesh_triangle"):
		_terrain_sampler = _landscape
		return
	var terrain := _world.find_child("SaisiesGeoTerrain", true, false)
	if terrain != null and terrain.get_parent() != null and terrain.get_parent().has_method("sample_mesh_triangle"):
		_terrain_sampler = terrain.get_parent()

func _load_candidate() -> bool:
	if not _candidate.is_empty():
		return true
	if not FileAccess.file_exists(candidate_path):
		push_error("Saisies release terminals candidate is missing: %s" % candidate_path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(candidate_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Saisies release terminals candidate is not a JSON object")
		return false
	_candidate = parsed as Dictionary
	if String(_candidate.get("kind", "")) != "saisies_full_route_release_terminals" or String(_candidate.get("status", "")) != RELEASE_STATUS or String(_candidate.get("visual_acceptance", "")) != VISUAL_ACCEPTANCE:
		push_error("Saisies release terminals candidate has an unexpected review status")
		return false
	if bool(_candidate.get("gps_calibrated", true)) or bool(_candidate.get("formal_route_edit", true)):
		push_error("Saisies release terminals candidate must remain visual-estimate-only")
		return false
	var route_payload: Variant = _candidate.get("route", {})
	if typeof(route_payload) != TYPE_DICTIONARY:
		return false
	var station_end := float((route_payload as Dictionary).get("station_end_m", EXPECTED_ROUTE_LENGTH_M))
	var finish_offset := float((route_payload as Dictionary).get("finish_offset_m", FINISH_OFFSET_M))
	var start_station := float((route_payload as Dictionary).get("start_sign_station_m", START_SIGN_STATION_M))
	return is_finite(station_end) and absf(station_end - EXPECTED_ROUTE_LENGTH_M) <= 0.25 and is_finite(finish_offset) and finish_offset >= 12.0 and finish_offset <= 20.0 and is_finite(start_station) and start_station >= 8.0 and start_station <= 30.0

func _build_terminals() -> bool:
	_clear_generated()
	_make_materials()
	var length_m := float(_route.get("length_m"))
	if not is_finite(length_m) or length_m <= 0.0:
		return false
	var finish_station := length_m + FINISH_OFFSET_M
	_start_root = _route_node("SaisiesReleaseDeparture", START_SIGN_STATION_M, START_SIGN_LATERAL_M)
	_finish_root = _route_node("SaisiesReleaseFinishArch", finish_station, 0.0)
	_arrival_root = Node3D.new()
	_arrival_root.name = "SaisiesReleaseArrivalSquare"
	add_child(_arrival_root)
	_build_departure(_start_root)
	_build_finish_arch(_finish_root, finish_station)
	_build_arrival_square(_arrival_root, length_m)
	set_meta("saisies_release_terminals_station_end_m", length_m)
	set_meta("saisies_release_terminals_finish_station_m", finish_station)
	set_meta("saisies_release_terminals_start_sign_station_m", START_SIGN_STATION_M)
	set_meta("saisies_release_terminals_arrival_extension_start_m", length_m - 14.0)
	set_meta("saisies_release_terminals_arrival_extension_end_m", length_m + ARRIVAL_END_OFFSET_M)
	set_meta("saisies_release_terminals_arrival_road_rows_m", [length_m - 14.0, length_m - 7.0, length_m, length_m + 16.0, length_m + 114.0])
	set_meta("saisies_release_terminals_authored_terrace_bounds", {"station_start_m": length_m - 14.0, "station_end_m": length_m + 180.0, "width_m": 160.0, "surface": "route-end height", "fill_depth_m": 6.0})
	set_meta("saisies_release_terminals_finish_arch_clear_width_m", 13.18)
	set_meta("saisies_release_terminals_finish_arch_centerline_clear", true)
	set_meta("saisies_release_terminals_label_texts", ["DÉPART", "START", "ARRIVÉE", "FINISH", "COL DES SAISIES"])
	set_meta("saisies_release_terminals_geometry_nodes", ["SaisiesReleaseDeparture", "SaisiesReleaseFinishArch", "ArrivalTerraceBase", "ArrivalPavingCenter", "ArrivalChaletEast", "ArrivalChaletWest", "ArrivalGarden_00", "ArrivalGarden_01", "ArrivalBench", "ArrivalTree", "ArrivalHill"])
	set_meta("saisies_release_terminals_ground_source", "authored_terminal_terrain at route-end height; route sample only for the -14m transition")
	set_meta("saisies_release_terminals_ground_sample_count", _ground_sample_count)
	set_meta("saisies_release_terminals_ground_fallback_count", _ground_fallback_count)
	return _mesh_count > 0 and _label_count >= 4

func _clear_generated() -> void:
	for child in get_children():
		child.free()
	_start_root = null
	_finish_root = null
	_arrival_root = null
	_mesh_count = 0
	_label_count = 0
	_ground_sample_count = 0
	_ground_fallback_count = 0

func _route_node(node_name: String, station: float, lateral: float, parent: Node = null) -> Node3D:
	var node := Node3D.new()
	node.name = node_name
	if parent == null:
		add_child(node)
	else:
		parent.add_child(node)
	var frame := _frame_at(station)
	var ground := _ground_y(station, lateral, frame.origin + frame.left * lateral)
	var world_position: Vector3 = frame.origin + frame.left * lateral
	world_position.y = ground
	node.global_position = world_position
	# Set dressing stays world-Y upright even when the route is climbing or
	# descending.  The authored arrival road below carries its own grade mesh;
	# signs, chalets, trees, and hills should never lean with that grade.
	var horizontal_tangent: Vector3 = frame.tangent
	horizontal_tangent.y = 0.0
	if horizontal_tangent.length_squared() < 0.0001:
		horizontal_tangent = Vector3(0.0, 0.0, -1.0)
	node.basis = Basis.looking_at(horizontal_tangent.normalized(), Vector3.UP)
	node.set_meta("saisies_release_terminal_station_m", station)
	node.set_meta("saisies_release_terminal_lateral_m", lateral)
	return node

func _frame_at(station: float) -> Dictionary:
	var length_m := float(_route.get("length_m"))
	var sample_station := clampf(station, 0.0, length_m)
	var origin: Vector3 = _route.call("pos_at", sample_station)
	var tangent: Vector3 = _route.call("tangent_at", sample_station)
	var left: Vector3 = _route.call("left_at", sample_station)
	if station > length_m:
		origin += tangent * (station - length_m)
	if tangent.length_squared() < 0.0001:
		tangent = Vector3(0.0, 0.0, -1.0)
	if left.length_squared() < 0.0001:
		left = Vector3(1.0, 0.0, 0.0)
	return {"origin": origin, "tangent": tangent.normalized(), "left": left.normalized()}

func _ground_y(station: float, lateral: float, world_position: Vector3) -> float:
	var length_m := float(_route.get("length_m"))
	# The route has no surveyed terrain beyond its final sample.  Keep every
	# authored terminal root on the endpoint terrace instead of accepting a
	# coincidental Landscape hit in the extension valley.
	if station > length_m:
		_ground_fallback_count += 1
		return float(_route.call("ground_y", length_m, 0.0))
	if _terrain_sampler != null and _terrain_sampler.has_method("sample_mesh_triangle"):
		var sampled: Variant = _terrain_sampler.call("sample_mesh_triangle", Vector2(world_position.x, world_position.z))
		if typeof(sampled) == TYPE_DICTIONARY and (sampled as Dictionary).has("height") and is_finite(float((sampled as Dictionary)["height"])):
			_ground_sample_count += 1
			return float((sampled as Dictionary)["height"])
	_ground_fallback_count += 1
	return float(_route.call("ground_y", clampf(station, 0.0, length_m), lateral))

func _build_departure(root: Node3D) -> void:
	# A small right-side sign is already behind the accepted S01 station (50 m).
	# Its face is aligned with the route and leaves the road centreline open.
	_add_box(root, "DepartureBoard", Vector3(3.8, 1.05, 0.16), Vector3(0.0, 2.65, 0.0), _materials["ivory"])
	_add_box(root, "DepartureStripe", Vector3(3.8, 0.16, 0.19), Vector3(0.0, 2.08, 0.0), _materials["gold"])
	_add_cylinder(root, "DeparturePostLeft", 0.10, 2.35, Vector3(-1.35, 1.15, 0.0), _materials["wood"])
	_add_cylinder(root, "DeparturePostRight", 0.10, 2.35, Vector3(1.35, 1.15, 0.0), _materials["wood"])
	_add_label(root, "DepartureFrench", "DÉPART", Vector3(0.0, 2.86, 0.105), 0.0090, _materials["ink"], 0.0)
	_add_label(root, "DepartureEnglish", "START", Vector3(0.0, 2.39, 0.105), 0.0075, _materials["ink"], 0.0)
	# A compact route crest gives the opening marker a cycling identity without a HUD.
	_add_box(root, "DepartureCrest", Vector3(0.72, 0.72, 0.18), Vector3(2.15, 2.62, 0.0), _materials["blue"])
	_add_label(root, "DepartureCrestLabel", "D218B", Vector3(2.15, 2.64, 0.12), 0.0017, _materials["ivory"], 0.0)

func _build_finish_arch(root: Node3D, finish_station: float) -> void:
	var frame := _frame_at(finish_station)
	var center_ground := _ground_y(finish_station, 0.0, frame.origin)
	var left_ground := _ground_y(finish_station, 6.65, frame.origin + frame.left * 6.65)
	var right_ground := _ground_y(finish_station, -6.65, frame.origin - frame.left * 6.65)
	var left_post_y := left_ground - center_ground
	var right_post_y := right_ground - center_ground
	_add_box(root, "FinishPostLeft", Vector3(0.72, 5.65, 0.72), Vector3(-6.65, left_post_y + 2.825, 0.0), _materials["cedar"])
	_add_box(root, "FinishPostRight", Vector3(0.72, 5.65, 0.72), Vector3(6.65, right_post_y + 2.825, 0.0), _materials["cedar"])
	_add_box(root, "FinishBeam", Vector3(13.9, 0.70, 0.64), Vector3(0.0, 5.60, 0.0), _materials["blue"])
	_add_box(root, "FinishBanner", Vector3(10.8, 1.55, 0.18), Vector3(0.0, 4.425, -0.08), _materials["ivory"])
	_add_box(root, "FinishBannerStripe", Vector3(10.8, 0.16, 0.20), Vector3(0.0, 3.72, -0.08), _materials["gold"])
	# Give the bilingual lines their own generous rows.  The old 0.54m
	# separation made the two labels collide in the actual final camera.
	# Keep the rider-facing labels just in front of the panel and the beam's
	# near face, so the upper blue beam cannot crop ARRIVÉE.
	_add_label(root, "FinishFrench", "ARRIVÉE", Vector3(0.0, 4.82, -0.38), 0.0145, _materials["ink"], 180.0)
	_add_label(root, "FinishEnglish", "FINISH", Vector3(0.0, 4.08, -0.38), 0.0115, _materials["ink"], 180.0)
	_add_label(root, "FinishBackFrench", "ARRIVÉE", Vector3(0.0, 4.82, 0.38), 0.0145, _materials["ink"], 0.0)
	_add_label(root, "FinishBackEnglish", "FINISH", Vector3(0.0, 4.08, 0.38), 0.0115, _materials["ink"], 0.0)
	# Alternating route-colour blocks make the overhead gate legible at distance.
	for index in range(7):
		var x := -5.4 + float(index) * 1.8
		_add_box(root, "FinishRibbon_%02d" % index, Vector3(0.76, 0.24, 0.74), Vector3(x, 6.06, 0.0), _materials["gold"] if index % 2 == 0 else _materials["red"])
	# Low side markers frame the arrival without placing an obstacle in the lane.
	_add_box(root, "FinishLeftPlinth", Vector3(1.45, 0.34, 1.15), Vector3(-8.0, left_ground - center_ground + 0.17, 0.0), _materials["stone"])
	_add_box(root, "FinishRightPlinth", Vector3(1.45, 0.34, 1.15), Vector3(8.0, right_ground - center_ground + 0.17, 0.0), _materials["stone"])

func _build_arrival_square(root: Node3D, route_end: float) -> void:
	# The final camera sees beyond the stop, so the square continues past the arch
	# with side plazas, two chalets, gardens, and a layered tree/hill backdrop.
	var square_station := route_end + 50.0
	var square := _route_node("ArrivalSquareSurface", square_station, 0.0, root)
	# The centre lane is an authored continuation of the route surface.  It
	# starts just before the real stop so the final frame never shows a hard road
	# cut, while every post-end row shares the exact route-end height.
	_add_terminal_road_strip(square, "ArrivalPavingCenter", 8.0, route_end, _materials["asphalt"])
	# A deep earth-filled terrace supports every authored footprint, including
	# the far mounds.  It begins exactly at the road transition (-14m) and ends
	# beyond the last backdrop (+180m); its top remains at route-end height while
	# the six-metre fill prevents a thin plane from floating over the old DEM.
	_add_box(square, "ArrivalTerraceBase", Vector3(160.0, 6.0, 194.0), Vector3(0.0, -3.0, -33.0), _materials["grass"])
	_add_box(square, "ArrivalPavingLeft", Vector3(11.5, 0.05, 46.0), Vector3(-13.0, -0.025, 0.0), _materials["cobble"])
	_add_box(square, "ArrivalPavingRight", Vector3(11.5, 0.05, 46.0), Vector3(13.0, -0.025, 0.0), _materials["cobble"])
	_add_box(square, "ArrivalShoulderLeft", Vector3(4.0, 0.08, 128.0), Vector3(-6.0, -0.04, 0.0), _materials["soil"])
	_add_box(square, "ArrivalShoulderRight", Vector3(4.0, 0.08, 128.0), Vector3(6.0, -0.04, 0.0), _materials["soil"])
	_build_chalet(root, route_end + 43.0, 17.5, 7.8, 8.0, "ArrivalChaletEast", true)
	_build_chalet(root, route_end + 76.0, -17.0, 8.6, 8.5, "ArrivalChaletWest", false)
	_build_garden(root, route_end + 35.0, -10.5, 0)
	_build_garden(root, route_end + 69.0, 10.8, 1)
	for item in [
		[route_end + 28.0, -25.0, 6.0], [route_end + 28.0, 25.0, 6.4],
		[route_end + 42.0, -31.0, 7.0], [route_end + 46.0, 31.0, 7.4],
		[route_end + 60.0, -24.0, 6.8], [route_end + 64.0, 24.0, 7.2],
		[route_end + 78.0, -33.0, 7.8], [route_end + 82.0, 33.0, 8.0],
		[route_end + 96.0, -27.0, 7.5], [route_end + 99.0, 27.0, 8.2],
		[route_end + 114.0, -35.0, 8.4], [route_end + 118.0, 35.0, 8.0],
		[route_end + 128.0, -22.0, 7.4], [route_end + 128.0, 22.0, 7.0]
	]:
		_build_tree(root, float(item[0]), float(item[1]), float(item[2]))
	# Close the last white DEM wedge with a few deliberately sparse foreground
	# conifers.  Their lateral offsets stay outside the 8m lane and frame the
	# gate instead of crossing its centre or its bilingual sign.
	for item in [
		[route_end + 8.0, -17.0, 8.2], [route_end + 12.0, 17.0, 9.1],
		[route_end + 18.0, -14.0, 7.4], [route_end + 22.0, 16.0, 8.6],
		[route_end + 28.0, -18.0, 9.5], [route_end + 32.0, 15.0, 8.0]
	]:
		_build_tree(root, float(item[0]), float(item[1]), float(item[2]))
	# Layer a proper village tree belt around the square.  The route centreline
	# stays open (all roots are at least 24m lateral), while the alternating
	# near/mid/far rows close the empty green field in the actual stop frame.
	for belt_index in range(16):
		var belt_station := route_end + 32.0 + float(belt_index) * 9.0
		for side_value in [-1.0, 1.0]:
			var side: float = float(side_value)
			var lateral := side * (25.0 + float(belt_index % 3) * 4.0)
			var height := 6.4 + float((belt_index + int(side_value > 0.0) * 2) % 5) * 0.55
			_build_tree(root, belt_station, lateral, height)
			if belt_index % 2 == 0:
				_build_tree(root, belt_station + 3.0, side * (41.0 + float(belt_index % 3) * 3.0), height + 1.15)
	_build_hills(root, route_end)
	_build_bench(root, route_end + 27.0, -8.8)
	_build_bench(root, route_end + 58.0, 8.8)
	_add_arrival_marker(root, route_end + 27.0, -10.5)

func _add_terminal_road_strip(parent: Node3D, node_name: String, width: float, route_end: float, material: Material) -> MeshInstance3D:
	# The terminal square is intentionally authored as one flat terrace.  Only
	# the short -14m..0m approach follows the real route samples; every row after
	# the endpoint uses the endpoint height, so a clamped route.ground_y value
	# cannot pull a far edge into a floating slab.  Keep these rows explicit: they
	# are also useful proof points when the baked cache is reviewed.
	var length_m := float(_route.get("length_m"))
	var endpoint_station := clampf(route_end, 0.0, length_m)
	var endpoint_origin: Vector3 = _route.call("pos_at", endpoint_station)
	var endpoint_tangent: Vector3 = _route.call("tangent_at", endpoint_station)
	var endpoint_left: Vector3 = _route.call("left_at", endpoint_station)
	endpoint_tangent.y = 0.0
	endpoint_left.y = 0.0
	if endpoint_tangent.length_squared() < 0.0001:
		endpoint_tangent = Vector3(0.0, 0.0, -1.0)
	else:
		endpoint_tangent = endpoint_tangent.normalized()
	if endpoint_left.length_squared() < 0.0001:
		endpoint_left = Vector3(1.0, 0.0, 0.0)
	else:
		endpoint_left = endpoint_left.normalized()
	var endpoint_ground := float(_route.call("ground_y", endpoint_station, 0.0))
	var rows := [route_end - 14.0, route_end - 7.0, route_end, route_end + 16.0, route_end + 114.0]
	var left_points: Array[Vector3] = []
	var right_points: Array[Vector3] = []
	var half_width := width * 0.5
	for row_value in rows:
		var row_station: float = float(row_value)
		var center: Vector3
		var lateral_axis: Vector3
		var ground: float
		if row_station <= length_m:
			var sample_station := clampf(row_station, 0.0, length_m)
			center = _route.call("pos_at", sample_station)
			lateral_axis = _route.call("left_at", sample_station)
			lateral_axis.y = 0.0
			# Keep the road transition on the route's own centerline elevation.  The
			# visible terrain sampler may contain nearby non-road triangles at this
			# junction, while ground_y is the accepted route surface contract.
			ground = float(_route.call("ground_y", sample_station, 0.0))
		else:
			center = endpoint_origin + endpoint_tangent * (row_station - endpoint_station)
			lateral_axis = endpoint_left
			ground = endpoint_ground
		if lateral_axis.length_squared() < 0.0001:
			lateral_axis = endpoint_left
		# Keep the authored asphalt visibly above the muted terrace, while its
		# shallow lower side still sinks into the earth fill.
		center.y = ground + 0.04
		left_points.append(parent.to_local(center + lateral_axis.normalized() * half_width))
		right_points.append(parent.to_local(center - lateral_axis.normalized() * half_width))

	var thickness := 0.14
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for row_index in range(left_points.size() - 1):
		var lf: Vector3 = left_points[row_index + 1]
		var rf: Vector3 = right_points[row_index + 1]
		var rb: Vector3 = right_points[row_index]
		var lb: Vector3 = left_points[row_index]
		var lfb := lf + Vector3.DOWN * thickness
		var rfb := rf + Vector3.DOWN * thickness
		var rbb := rb + Vector3.DOWN * thickness
		var lbb := lb + Vector3.DOWN * thickness
		var segment_depth := maxf(lf.distance_to(lb), 0.001)
		for triangle in [[lf, rb, rf], [lf, lb, rb], [lfb, rfb, rbb], [lfb, rbb, lbb], [lf, rfb, lfb], [lf, rf, rfb], [rf, rbb, rfb], [rf, rb, rbb], [rb, lbb, rbb], [rb, lb, lbb], [lb, lfb, lbb], [lb, lf, lfb]]:
			for vertex in triangle:
				var point: Vector3 = vertex
				st.set_uv(Vector2(point.x / maxf(width, 0.001) + 0.5, point.z / segment_depth))
				st.add_vertex(point)
	st.generate_normals()
	var mesh := st.commit()
	return _add_mesh(parent, node_name, mesh, Vector3.ZERO, material)

func _build_chalet(parent: Node3D, station: float, lateral: float, width: float, depth: float, node_name: String, warm: bool) -> void:
	var root := _route_node(node_name, station, lateral, parent)
	var body_height := 3.4
	_add_box(root, "Foundation", Vector3(width + 0.35, 0.38, depth + 0.35), Vector3(0.0, 0.19, 0.0), _materials["stone"])
	_add_box(root, "Body", Vector3(width, body_height, depth), Vector3(0.0, 0.38 + body_height * 0.5, 0.0), _materials["plaster_warm"] if warm else _materials["plaster_cool"])
	var gable := MeshInstance3D.new()
	gable.name = "GableRoof"
	gable.mesh = _gable_mesh(width + 0.85, 1.45, depth + 0.72)
	gable.material_override = _materials["roof"]
	gable.position = Vector3(0.0, 0.38 + body_height, 0.0)
	root.add_child(gable)
	_mesh_count += 1
	# The rider approaches from local +Z and therefore sees the +Z facade.  The
	# previous details were on -Z, leaving the actual arrival image with blank
	# chalet backs.
	for x in [-width * 0.25, width * 0.25]:
		_add_box(root, "Window", Vector3(1.10, 1.15, 0.10), Vector3(x, 2.06, depth * 0.51), _materials["window"])
		_add_box(root, "WindowFrame", Vector3(1.28, 0.12, 0.12), Vector3(x, 2.06, depth * 0.55), _materials["wood_dark"])
	_add_box(root, "Door", Vector3(0.95, 2.05, 0.12), Vector3(0.0, 1.40, depth * 0.52), _materials["wood_dark"])
	_add_box(root, "FlowerBox", Vector3(2.7, 0.18, 0.42), Vector3(0.0, 1.15, depth * 0.59), _materials["wood"])
	_add_box(root, "FrontStep", Vector3(1.35, 0.18, 0.72), Vector3(0.0, 0.09, depth * 0.60), _materials["stone"])
	for index in range(4):
		_add_sphere(root, "Flower_%02d" % index, 0.18, Vector3(-1.0 + float(index) * 0.65, 1.38, depth * 0.63), _materials["flower_%d" % (index % 3)], Vector3(1.0, 1.3, 1.0))

func _build_garden(parent: Node3D, station: float, lateral: float, variant: int) -> void:
	var root := _route_node("ArrivalGarden_%02d" % variant, station, lateral, parent)
	_add_box(root, "GardenBed", Vector3(6.6, 0.16, 8.2), Vector3(0.0, 0.08, 0.0), _materials["grass"])
	for index in range(5):
		var x := -2.2 + float(index) * 1.1
		_add_sphere(root, "GardenShrub_%02d" % index, 0.55, Vector3(x, 0.58, sin(float(index) * 1.7) * 2.3), _materials["leaf"] if index % 2 == 0 else _materials["flower_1"], Vector3(1.0, 0.75, 1.0))
	_add_box(root, "GardenEdge", Vector3(7.2, 0.32, 0.26), Vector3(0.0, 0.18, -4.0), _materials["stone"])
	# A low timber rail gives the garden a readable village edge without
	# narrowing the lane or introducing a road-centreline obstacle.
	for side_value in [-1.0, 1.0]:
		var side: float = float(side_value)
		_add_cylinder(root, "GardenFencePost", 0.08, 1.05, Vector3(side * 3.1, 0.53, 3.9), _materials["wood"])
		_add_box(root, "GardenFenceRail", Vector3(0.12, 0.12, 7.8), Vector3(side * 3.1, 0.76, 0.0), _materials["wood"])
	_add_box(root, "GardenFrontRail", Vector3(6.2, 0.12, 0.12), Vector3(0.0, 0.76, 3.9), _materials["wood"])

func _build_bench(parent: Node3D, station: float, lateral: float) -> void:
	var root := _route_node("ArrivalBench_%d" % _mesh_count, station, lateral, parent)
	_add_box(root, "BenchSeat", Vector3(2.5, 0.16, 0.48), Vector3(0.0, 0.92, 0.0), _materials["wood"])
	_add_box(root, "BenchBack", Vector3(2.5, 0.72, 0.14), Vector3(0.0, 1.32, 0.20), _materials["wood"])
	for x in [-0.85, 0.85]:
		_add_box(root, "BenchLeg", Vector3(0.14, 0.90, 0.40), Vector3(x, 0.45, 0.0), _materials["wood_dark"])

func _build_tree(parent: Node3D, station: float, lateral: float, height: float) -> void:
	var root := _route_node("ArrivalTree_%d" % _mesh_count, station, lateral, parent)
	# Reuse the release tree factory so the endpoint silhouette shares the
	# scanned alpha-card / bark treatment used by the full-route forest.  The
	# primitive fallback keeps standalone cached-base previews deterministic when
	# an asset import is unavailable.
	var tree_script := load("res://scripts/saisies_trees.gd") as Script
	# Use conifers for the terminal backdrop.  The imported broadleaf cards are
	# deliberately broad and low, which made the previous endpoint read as
	# detached green ellipsoids instead of a continuous alpine tree line.
	var variants: Variant = tree_script.call("conifer_variants") if tree_script != null else []
	if variants is Array and not (variants as Array).is_empty() and (variants as Array)[0] is Mesh:
		var meshes: Array = variants as Array
		var mesh_index: int = absi(int(station)) % meshes.size()
		var source_mesh := meshes[mesh_index] as Mesh
		var mesh_height := maxf(source_mesh.get_aabb().size.y, 0.1)
		var scale_factor := height / mesh_height
		var crown := _add_mesh(root, "ReleaseTreeAsset", source_mesh, Vector3(0.0, -source_mesh.get_aabb().position.y * scale_factor, 0.0), null, Vector3.ONE * scale_factor)
		crown.set_meta("saisies_release_terminal_tree_height_m", height)
		crown.set_meta("saisies_release_terminal_tree_asset", "SaisiesTrees")
		return
	_add_cylinder(root, "Trunk", 0.28, height * 0.52, Vector3(0.0, height * 0.26, 0.0), _materials["wood_dark"])
	var canopy := SphereMesh.new()
	canopy.radius = 1.6
	canopy.height = 3.2
	canopy.radial_segments = 12
	canopy.rings = 6
	var fallback_crown := _add_mesh(root, "CrownFallback", canopy, Vector3(0.0, height * 0.70, 0.0), _materials["leaf"], Vector3(1.0, 1.22, 1.0))
	fallback_crown.set_meta("saisies_release_terminal_tree_height_m", height)

func _build_hills(parent: Node3D, route_end: float) -> void:
	# Low irregular mounds grow out of the same endpoint terrace as the road and
	# tree bases.  They replace the old floating SphereMesh ellipsoids, while the
	# real conifer instances above carry the readable near/mid/far tree silhouette.
	var stations := [route_end + 90.0, route_end + 108.0, route_end + 132.0, route_end + 154.0]
	var laterals := [-38.0, 38.0, -48.0, 48.0]
	var radii_x := [25.0, 23.0, 30.0, 28.0]
	var radii_z := [18.0, 20.0, 24.0, 22.0]
	var heights := [9.0, 11.0, 13.0, 10.0]
	for index in range(stations.size()):
		var station: float = float(stations[index])
		var lateral: float = float(laterals[index])
		var root := _route_node("ArrivalHill_%02d" % index, station, lateral, parent)
		var mound := _mound_mesh(float(radii_x[index]), float(radii_z[index]), float(heights[index]), index)
		_add_mesh(root, "HillMound", mound, Vector3.ZERO, _materials["hill_%d" % (index % 2)])

func _mound_mesh(radius_x: float, radius_z: float, height: float, seed_value: int) -> ArrayMesh:
	var segments := 12
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(segments):
		var next_index := (index + 1) % segments
		var angle_a := TAU * float(index) / float(segments)
		var angle_b := TAU * float(next_index) / float(segments)
		var jitter_a := 0.92 + 0.07 * sin(float(seed_value + index * 5))
		var jitter_b := 0.92 + 0.07 * sin(float(seed_value + next_index * 5))
		var base_a := Vector3(cos(angle_a) * radius_x * jitter_a, 0.0, sin(angle_a) * radius_z * jitter_a)
		var base_b := Vector3(cos(angle_b) * radius_x * jitter_b, 0.0, sin(angle_b) * radius_z * jitter_b)
		var shoulder_a := Vector3(base_a.x * 0.67, height * (0.46 + 0.04 * sin(float(index))), base_a.z * 0.67)
		var shoulder_b := Vector3(base_b.x * 0.67, height * (0.46 + 0.04 * sin(float(next_index))), base_b.z * 0.67)
		var crown := Vector3(0.0, height, 0.0)
		for triangle in [[base_a, base_b, shoulder_b], [base_a, shoulder_b, shoulder_a], [shoulder_a, shoulder_b, crown]]:
			for vertex in triangle:
				var point: Vector3 = vertex
				st.set_uv(Vector2(point.x / maxf(radius_x * 2.0, 0.001) + 0.5, point.z / maxf(radius_z * 2.0, 0.001) + 0.5))
				st.add_vertex(point)
	st.generate_normals()
	return st.commit()

func _add_arrival_marker(parent: Node3D, station: float, lateral: float) -> void:
	var root := _route_node("ArrivalSquareMarker", station, lateral, parent)
	_add_box(root, "MarkerBoard", Vector3(4.5, 1.0, 0.16), Vector3(0.0, 2.5, 0.0), _materials["blue"])
	_add_label(root, "MarkerLabel", "COL DES SAISIES", Vector3(0.0, 2.55, 0.11), 0.0040, _materials["ivory"], 0.0)
	_add_cylinder(root, "MarkerPostL", 0.08, 2.2, Vector3(-1.7, 1.1, 0.0), _materials["wood"])
	_add_cylinder(root, "MarkerPostR", 0.08, 2.2, Vector3(1.7, 1.1, 0.0), _materials["wood"])

func _add_box(parent: Node3D, node_name: String, size: Vector3, position: Vector3, material: Material, rotation := Vector3.ZERO) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _add_mesh(parent, node_name, mesh, position, material, Vector3.ONE, rotation)

func _add_cylinder(parent: Node3D, node_name: String, radius: float, height: float, position: Vector3, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 12
	return _add_mesh(parent, node_name, mesh, position, material)

func _add_sphere(parent: Node3D, node_name: String, radius: float, position: Vector3, material: Material, scale := Vector3.ONE) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	return _add_mesh(parent, node_name, mesh, position, material, scale)

func _add_mesh(parent: Node3D, node_name: String, mesh: Mesh, position: Vector3, material: Material, scale := Vector3.ONE, rotation := Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	instance.scale = scale
	instance.rotation = rotation
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)
	_mesh_count += 1
	return instance

func _add_label(parent: Node3D, node_name: String, text_value: String, position: Vector3, pixel_size: float, material: Material, yaw_deg: float) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.text = text_value
	label.font_size = 64
	label.pixel_size = pixel_size
	label.modulate = (material as StandardMaterial3D).albedo_color if material is StandardMaterial3D else Color.WHITE
	label.outline_size = 7
	label.outline_modulate = Color(0.04, 0.05, 0.07, 1.0)
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.position = position
	label.rotation_degrees.y = yaw_deg
	parent.add_child(label)
	_label_count += 1
	return label

func _gable_mesh(width: float, rise: float, depth: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var z := depth * 0.5
	var vertices := [
		Vector3(-width * 0.5, 0.0, -z), Vector3(width * 0.5, 0.0, -z), Vector3(0.0, rise, -z),
		Vector3(-width * 0.5, 0.0, z), Vector3(0.0, rise, z), Vector3(width * 0.5, 0.0, z)
	]
	for triangle in [[0, 1, 2], [3, 4, 5], [0, 3, 4], [0, 4, 2], [1, 5, 4], [1, 4, 2]]:
		for index in triangle:
			var vertex: Vector3 = vertices[index]
			st.set_uv(Vector2(vertex.x / maxf(width, 0.001) + 0.5, vertex.y / maxf(rise, 0.001)))
			st.add_vertex(vertex)
	st.generate_normals()
	return st.commit()

func _make_materials() -> void:
	_materials["ivory"] = _mat(Color(0.94, 0.87, 0.69), 0.78)
	_materials["ink"] = _mat(Color(0.05, 0.08, 0.10), 0.88)
	_materials["blue"] = _mat(Color(0.04, 0.18, 0.38), 0.78)
	_materials["gold"] = _mat(Color(0.94, 0.57, 0.08), 0.74)
	_materials["red"] = _mat(Color(0.74, 0.10, 0.08), 0.80)
	_materials["cedar"] = _mat(Color(0.40, 0.18, 0.08), 0.90)
	_materials["wood"] = _texture_mat("brown_planks_09", Color(0.62, 0.43, 0.25), 0.92)
	_materials["wood_dark"] = _texture_mat("brown_planks_09", Color(0.34, 0.22, 0.13), 0.94)
	_materials["stone"] = _texture_mat("stacked_stone_wall", Color(0.72, 0.72, 0.66), 0.98)
	_materials["cobble"] = _texture_mat("patterned_cobblestone", Color(0.72, 0.70, 0.63), 0.98)
	_materials["asphalt"] = _texture_mat("asphalt_02", Color(0.74, 0.76, 0.76), 0.94)
	_materials["soil"] = _texture_mat("brown_mud_leaves_01", Color(0.66, 0.50, 0.34), 0.98)
	_materials["plaster_warm"] = _texture_mat("painted_plaster_wall", Color(0.92, 0.72, 0.48), 0.90)
	_materials["plaster_cool"] = _texture_mat("beige_wall_001", Color(0.85, 0.88, 0.82), 0.90)
	_materials["roof"] = _texture_mat("clay_roof_tiles_02", Color(0.72, 0.42, 0.26), 0.92)
	_materials["window"] = _mat(Color(0.08, 0.20, 0.24), 0.38)
	_materials["grass"] = _texture_mat("aerial_grass_rock", Color(0.62, 0.62, 0.48), 0.98)
	_materials["leaf"] = _mat(Color(0.13, 0.30, 0.10), 0.98)
	_materials["leaf_dark"] = _mat(Color(0.07, 0.20, 0.10), 0.98)
	_materials["flower_0"] = _mat(Color(0.94, 0.42, 0.30), 0.78)
	_materials["flower_1"] = _mat(Color(0.94, 0.73, 0.25), 0.78)
	_materials["flower_2"] = _mat(Color(0.75, 0.34, 0.72), 0.78)
	_materials["hill_0"] = _texture_mat("aerial_grass_rock", Color(0.54, 0.56, 0.43), 0.98)
	_materials["hill_1"] = _texture_mat("aerial_grass_rock", Color(0.64, 0.62, 0.46), 0.98)

func _mat(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material

func _texture_mat(stem: String, tint: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = load("res://assets/textures/%s_diff.jpg" % stem)
	material.normal_enabled = true
	material.normal_texture = load("res://assets/textures/%s_nor.jpg" % stem)
	material.roughness_texture = load("res://assets/textures/%s_rough.jpg" % stem)
	material.albedo_color = tint
	material.roughness = roughness
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * 0.42
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _set_geometry_visible(enabled: bool) -> void:
	if _live_geometry_suppressed:
		enabled = false
	for child in get_children():
		if child is Node3D:
			(child as Node3D).visible = enabled
	visible = enabled

func _publish_state() -> void:
	set_meta("saisies_release_terminals_ready", _initialized)
	set_meta("saisies_release_terminals_enabled", enable_refinement)
	set_meta("saisies_release_terminals_geometry_count", _mesh_count)
	set_meta("saisies_release_terminals_label_count", _label_count)
	set_meta("saisies_release_terminals_status", RELEASE_STATUS)
	set_meta("saisies_release_terminals_visual_acceptance", VISUAL_ACCEPTANCE)
	set_meta("saisies_release_terminals_features", ["DÉPART / START", "ARRIVÉE / FINISH", "alpine arrival square", "textured endpoint-height earth terrace", "textured chalets", "gardens, benches and timber rails", "dense conifer belt and textured mounds"])
	set_meta("saisies_release_terminals_geometry_contract", {
		"station_end_m": get_meta("saisies_release_terminals_station_end_m", 0.0),
		"finish_arch_station_m": get_meta("saisies_release_terminals_finish_station_m", 0.0),
		"finish_arch_offset_m": FINISH_OFFSET_M,
		"arrival_extension_end_m": get_meta("saisies_release_terminals_arrival_extension_end_m", 0.0),
		"arrival_road_rows_m": get_meta("saisies_release_terminals_arrival_road_rows_m", []),
		"authored_terrace_bounds": get_meta("saisies_release_terminals_authored_terrace_bounds", {}),
		"finish_arch_clear_width_m": get_meta("saisies_release_terminals_finish_arch_clear_width_m", 0.0),
		"centerline_clear": bool(get_meta("saisies_release_terminals_finish_arch_centerline_clear", false)),
		"label_texts": get_meta("saisies_release_terminals_label_texts", []),
	})

func _retry(message: String) -> void:
	_build_attempts += 1
	if _build_attempts < 240:
		call_deferred("_retry_next_frame")
		return
	_fail(message)

func _retry_next_frame() -> void:
	await get_tree().process_frame
	_try_initialize()

func _fail(message: String) -> void:
	set_meta("saisies_release_terminals_ready", false)
	set_meta("saisies_release_terminals_error", message)
	push_error(message)
