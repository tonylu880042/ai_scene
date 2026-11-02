extends Node3D

## Bounded S03 junction opening refinement.
##
## The accepted S02 world remains the owner of the route, camera, and baked
## terrain.  This node hides only the authored S03 apron in the instantiated
## world, then adds one local pavement/curb/rail assembly whose vertices are
## sampled from S01Landscape's baked mesh triangles.  The rail is deliberately
## made from upright posts and horizontal world-XZ segments so a curved edge
## cannot turn into a slanted camera-facing fence.

@export var s02_review_path: NodePath = NodePath("../S02Review")
@export var world_path: NodePath = NodePath("../S02Review/S01Review/World")
@export var s01_landscape_path: NodePath = NodePath("../S02Review/S01Review/S01Landscape")
@export var chairlift_path: NodePath = NodePath("../S02Review/S01Review/World/VillageS01S02/S03Chairlift")
@export var old_apron_path: NodePath = NodePath("../S02Review/S01Review/World/VillageS01S02/S03Chairlift/S03BroadJunctionApron")
@export var enable_refinement := true

const S03_ID := "S03"
const STATION_FROM_M := 885.0
const STATION_TO_M := 1005.0
const STATION_STEP_M := 15.0
const RAIL_STEP_M := 3.0
const PAVEMENT_LIFT_M := 0.10
const CENTER_OVERLAY_LIFT_M := 0.145
const WALL_HEIGHT_M := 0.48
const WALL_HALF_THICKNESS_M := 0.32
const RAIL_LOWER_OFFSET_M := 0.28
const RAIL_UPPER_OFFSET_M := 0.70
const SOURCE_FRAME := "video/saisies_analysis/acceptance/S03_f001798.png"
const SOURCE_SHA256 := "184ee032aef47be5d52b5d5c6379300dc4dca85054ada0b93ef07ed8ca043e10"

var _s02_review: Node
var _world: Node3D
var _route: Node
var _landscape: Node
var _chairlift: Node3D
var _old_apron: VisualInstance3D
var _attempts := 0
var _built := false
var _actual_contact_count := 0
var _contact_samples: Array[Dictionary] = []
var _junction_asphalt: StandardMaterial3D

func _ready() -> void:
	top_level = true
	if _has_command_line_flag("--s03-junction-off"):
		enable_refinement = false
	call_deferred("_try_build")

func _try_build() -> void:
	if _built:
		return
	_s02_review = get_node_or_null(s02_review_path)
	_world = get_node_or_null(world_path) as Node3D
	_landscape = get_node_or_null(s01_landscape_path)
	_chairlift = get_node_or_null(chairlift_path) as Node3D
	_route = _world.get_node_or_null("Route") as Node if _world != null else null
	_old_apron = get_node_or_null(old_apron_path) as VisualInstance3D
	if _s02_review == null or _world == null or _route == null or _landscape == null or _chairlift == null or _old_apron == null:
		_retry("S03 junction refinement dependencies are incomplete")
		return
	if not enable_refinement:
		_publish_disabled_state()
		_built = true
		return
	if not bool(_s02_review.get_meta("saisies_s02_review_ready", false)):
		_retry("S03 junction refinement is waiting for S02 fixed review pose")
		return
	if not bool(_landscape.get_meta("saisies_s01_landscape_ready", false)) or not bool(_landscape.get_meta("saisies_s01_actual_triangle_contact", false)):
		_retry("S03 junction refinement is waiting for S01 baked terrain")
		return
	if not _route.has_method("pos_at") or not _route.has_method("left_at") or not _route.has_method("road_width_at"):
		_fail_and_hold("S03 junction refinement requires the shared route frame")
		return
	if not _landscape.has_method("_sample_baked_ground"):
		_fail_and_hold("S03 junction refinement requires S01Landscape._sample_baked_ground")
		return
	if _apply_candidate():
		_built = true
		_publish_ready_state()
	else:
		_fail_and_hold("S03 junction refinement could not establish baked-mesh contacts")

func _retry(message: String) -> void:
	_attempts += 1
	if _attempts < 240:
		# A deferred call alone can exhaust all retries in one frame while the
		# accepted S02 controller is still draining its own deferred pose.
		call_deferred("_retry_next_frame")
	else:
		_fail_and_hold(message)

func _retry_next_frame() -> void:
	await get_tree().process_frame
	_try_build()

func _fail_and_hold(message: String) -> void:
	set_meta("saisies_s03_junction_refinement_ready", false)
	set_meta("saisies_s03_junction_refinement_error", message)
	push_error(message)

func _publish_disabled_state() -> void:
	set_meta("saisies_s03_junction_refinement_ready", true)
	set_meta("saisies_s03_junction_refinement_enabled", false)
	set_meta("saisies_s03_junction_refinement_source_frame", SOURCE_FRAME)
	set_meta("saisies_s03_junction_refinement_station_range_m", Vector2(STATION_FROM_M, STATION_TO_M))
	set_meta("saisies_s03_junction_refinement_old_apron_hidden", false)
	_publish_parent_ready()

func _publish_parent_ready() -> void:
	var parent := get_parent()
	if parent != null:
		parent.set_meta("saisies_s03_junction_refinement_ready", true)
		parent.set_meta("saisies_s03_junction_refinement_enabled", enable_refinement)

func _apply_candidate() -> bool:
	_old_apron.visible = false
	var root := Node3D.new()
	root.name = "S03JunctionRefinement"
	root.set_meta("saisies_s03_junction_scope", "local junction pavement and curved low edge rails")
	root.set_meta("saisies_s03_junction_station_from_m", STATION_FROM_M)
	root.set_meta("saisies_s03_junction_station_to_m", STATION_TO_M)
	root.set_meta("saisies_s03_junction_ground_source", "S01Landscape._sample_baked_ground actual mesh triangles")
	root.set_meta("saisies_s03_junction_source_frame", SOURCE_FRAME)
	root.set_meta("saisies_s03_junction_source_sha256", SOURCE_SHA256)
	add_child(root)

	_contact_samples.clear()
	_actual_contact_count = 0
	var pavement := _build_pavement(root)
	var center_overlay := _build_center_overlay(root)
	var left_wall := _build_edge(root, -1.0, "S03JunctionLeftEdge")
	var right_wall := _build_edge(root, 1.0, "S03JunctionRightEdge")
	if pavement == null or center_overlay == null or left_wall == null or right_wall == null or _contact_samples.is_empty():
		root.queue_free()
		_old_apron.visible = true
		return false
	if _actual_contact_count < 8:
		root.queue_free()
		_old_apron.visible = true
		return false

	root.set_meta("saisies_s03_junction_pavement", true)
	root.set_meta("saisies_s03_junction_center_overlay", true)
	root.set_meta("saisies_s03_junction_left_edge", true)
	root.set_meta("saisies_s03_junction_right_edge", true)
	root.set_meta("saisies_s03_junction_contact_sample_count", _contact_samples.size())
	root.set_meta("saisies_s03_junction_actual_triangle_contact_count", _actual_contact_count)
	root.set_meta("saisies_s03_junction_contact_samples", _contact_samples)
	root.set_meta("saisies_s03_junction_pavement_lift_m", PAVEMENT_LIFT_M)
	root.set_meta("saisies_s03_junction_edge_half_width_range_m", Vector2(10.5, 20.5))
	root.set_meta("saisies_s03_junction_wall_height_m", WALL_HEIGHT_M)
	root.set_meta("saisies_s03_junction_rail_orientation", "world-space grade-following segments with upright world-Y posts")
	root.set_meta("saisies_s03_junction_rail_station_step_m", RAIL_STEP_M)
	root.set_meta("saisies_s03_junction_road_surface_source", "Route._road_point actual road mesh helper")
	set_meta("saisies_s03_junction_refinement_applied", true)
	set_meta("saisies_s03_junction_refinement_owner", "S03Chairlift/S03BroadJunctionApron")
	set_meta("saisies_s03_junction_refinement_node_path", str(root.get_path()))
	set_meta("saisies_s03_junction_refinement_ready", true)
	set_meta("saisies_s03_junction_refinement_enabled", true)
	set_meta("saisies_s03_junction_refinement_old_apron_hidden", true)
	set_meta("saisies_s03_junction_refinement_contact_source", "S01Landscape._sample_baked_ground actual mesh triangles")
	set_meta("saisies_s03_junction_refinement_contact_samples", _contact_samples)
	set_meta("saisies_s03_junction_refinement_actual_triangle_contact_count", _actual_contact_count)
	return true

func _publish_ready_state() -> void:
	set_meta("saisies_s03_junction_refinement_ready", true)
	_publish_parent_ready()

func _edge_half_width(station: float) -> float:
	var t := clampf((station - STATION_FROM_M) / (STATION_TO_M - STATION_FROM_M), 0.0, 1.0)
	# The opening grows toward the 930m junction, then tapers into the route.
	var arch := sin(t * PI)
	return lerpf(10.5, 20.5, arch)

func _route_point(station: float, lateral: float, lift: float) -> Dictionary:
	var base: Vector3 = _route.call("pos_at", station)
	var left: Vector3 = _route.call("left_at", station)
	var xz := base + left * lateral
	var sampled = _landscape.call("_sample_baked_ground", Vector2(xz.x, xz.z))
	if sampled is Dictionary and sampled.has("position"):
		var ground: Vector3 = sampled["position"]
		var source := String(sampled.get("source", "Landscape.sample_mesh_triangle"))
		if source == "Landscape.sample_mesh_triangle" or source == "baked_mesh_triangle":
			_actual_contact_count += 1
		_contact_samples.append({
			"station_m": station,
			"lateral_m": lateral,
			"ground_y": ground.y,
			"source": source,
			"triangle_start": int(sampled.get("triangle_start", -1)),
			"lift_m": lift,
		})
		return {"position": Vector3(ground.x, ground.y + lift, ground.z), "ground": ground, "source": source}
	var fallback: Vector3 = _route.call("world_at", station, lateral, lift)
	_contact_samples.append({
		"station_m": station,
		"lateral_m": lateral,
		"ground_y": fallback.y - lift,
		"source": "route.world_at_fallback",
		"triangle_start": -1,
		"lift_m": lift,
	})
	return {"position": fallback, "ground": fallback - Vector3.UP * lift, "source": "route.world_at_fallback"}

func _station_list() -> Array[float]:
	var stations: Array[float] = []
	var s := STATION_FROM_M
	while s < STATION_TO_M:
		stations.append(s)
		s += STATION_STEP_M
	stations.append(STATION_TO_M)
	return stations

func _rail_station_list() -> Array[float]:
	var stations: Array[float] = []
	var s := STATION_FROM_M
	while s < STATION_TO_M:
		stations.append(s)
		s += RAIL_STEP_M
	stations.append(STATION_TO_M)
	return stations

func _build_pavement(parent: Node3D) -> MeshInstance3D:
	var stations := _station_list()
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var vertex_count := 0
	for i in range(stations.size() - 1):
		var s0: float = stations[i]
		var s1: float = stations[i + 1]
		var h0 := _edge_half_width(s0)
		var h1 := _edge_half_width(s1)
		var half0 := float(_route.call("road_width_at", s0)) * 0.5
		var half1 := float(_route.call("road_width_at", s1)) * 0.5
		# Four bounded lateral strips join the authoritative route surface to
		# the sampled outer apron, avoiding one large quad through uneven ground.
		var columns0: Array[Vector3] = [
			_route_point(s0, -h0, PAVEMENT_LIFT_M)["position"],
			_road_point(s0, -half0, PAVEMENT_LIFT_M)["position"],
			_road_point(s0, 0.0, PAVEMENT_LIFT_M)["position"],
			_road_point(s0, half0, PAVEMENT_LIFT_M)["position"],
			_route_point(s0, h0, PAVEMENT_LIFT_M)["position"],
		]
		var columns1: Array[Vector3] = [
			_route_point(s1, -h1, PAVEMENT_LIFT_M)["position"],
			_road_point(s1, -half1, PAVEMENT_LIFT_M)["position"],
			_road_point(s1, 0.0, PAVEMENT_LIFT_M)["position"],
			_road_point(s1, half1, PAVEMENT_LIFT_M)["position"],
			_route_point(s1, h1, PAVEMENT_LIFT_M)["position"],
		]
		for column in range(columns0.size() - 1):
			_add_quad(surface, columns0[column], columns0[column + 1], columns1[column + 1], columns1[column])
			vertex_count += 6
	surface.generate_normals()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "S03JunctionPavement"
	mesh_instance.mesh = surface.commit()
	mesh_instance.material_override = _junction_asphalt_material()
	mesh_instance.set_meta("saisies_s03_junction_ground_source", "S01Landscape._sample_baked_ground")
	mesh_instance.set_meta("saisies_s03_junction_vertex_count", vertex_count)
	parent.add_child(mesh_instance)
	return mesh_instance

func _build_center_overlay(parent: Node3D) -> MeshInstance3D:
	var stations := _station_list()
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(stations.size() - 1):
		var s0: float = stations[i]
		var s1: float = stations[i + 1]
		var a: Vector3 = _road_point(s0, -1.15, CENTER_OVERLAY_LIFT_M)["position"]
		var b: Vector3 = _road_point(s0, 1.15, CENTER_OVERLAY_LIFT_M)["position"]
		var c: Vector3 = _road_point(s1, 1.15, CENTER_OVERLAY_LIFT_M)["position"]
		var d: Vector3 = _road_point(s1, -1.15, CENTER_OVERLAY_LIFT_M)["position"]
		_add_quad(surface, a, b, c, d)
	surface.generate_normals()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "S03JunctionCenterAsphaltOverlay"
	mesh_instance.mesh = surface.commit()
	mesh_instance.material_override = _junction_asphalt_material()
	mesh_instance.set_meta("saisies_s03_junction_hides_center_marking", true)
	mesh_instance.set_meta("saisies_s03_junction_overlay_station_range_m", Vector2(STATION_FROM_M, STATION_TO_M))
	parent.add_child(mesh_instance)
	return mesh_instance

func _road_point(station: float, lateral: float, lift: float) -> Dictionary:
	# Match the same private road-surface helper used by the authoritative
	# SaisiesRoute road mesh.  The public world_at() can resolve to terrain at
	# the edge of an overridden geo route; this call keeps the overlay on the
	# actual road crown and above the existing center marks.
	var point: Vector3
	if _route.has_method("_road_point"):
		point = _route.call("_road_point", station, lateral, lift)
	else:
		point = _route.call("world_at", station, lateral, lift)
	_contact_samples.append({
		"station_m": station,
		"lateral_m": lateral,
		"ground_y": point.y - lift,
		"source": "Route._road_point_surface",
		"triangle_start": -1,
		"lift_m": lift,
	})
	return {"position": point, "ground": point - Vector3.UP * lift, "source": "Route._road_point_surface"}

func _build_edge(parent: Node3D, side: float, edge_name: String) -> Node3D:
	var stations := _station_list()
	var samples: Array[Dictionary] = []
	for station in stations:
		var half := _edge_half_width(station)
		var sample := _route_point(station, side * (half + 0.35), 0.0)
		sample["station"] = station
		sample["side"] = side
		samples.append(sample)
	var edge_root := Node3D.new()
	edge_root.name = edge_name
	parent.add_child(edge_root)

	var wall_surface := SurfaceTool.new()
	wall_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(samples.size() - 1):
		var a: Dictionary = samples[i]
		var b: Dictionary = samples[i + 1]
		var a_ground: Vector3 = a["ground"]
		var b_ground: Vector3 = b["ground"]
		var station_a: float = a["station"]
		var station_b: float = b["station"]
		var outward_a: Vector3 = Vector3(_route.call("left_at", station_a)) * side
		var outward_b: Vector3 = Vector3(_route.call("left_at", station_b)) * side
		var a_inner := a_ground - outward_a * WALL_HALF_THICKNESS_M
		var a_outer := a_ground + outward_a * WALL_HALF_THICKNESS_M
		var b_inner := b_ground - outward_b * WALL_HALF_THICKNESS_M
		var b_outer := b_ground + outward_b * WALL_HALF_THICKNESS_M
		var a_inner_top := a_inner + Vector3.UP * WALL_HEIGHT_M
		var a_outer_top := a_outer + Vector3.UP * WALL_HEIGHT_M
		var b_inner_top := b_inner + Vector3.UP * WALL_HEIGHT_M
		var b_outer_top := b_outer + Vector3.UP * WALL_HEIGHT_M
		_add_quad(wall_surface, a_inner, b_inner, b_inner_top, a_inner_top)
		_add_quad(wall_surface, b_outer, a_outer, a_outer_top, b_outer_top)
		_add_quad(wall_surface, a_inner_top, b_inner_top, b_outer_top, a_outer_top)
	if samples.size() >= 2:
		var first: Dictionary = samples[0]
		var last: Dictionary = samples[samples.size() - 1]
		var first_ground: Vector3 = first["ground"]
		var last_ground: Vector3 = last["ground"]
		var first_outward: Vector3 = Vector3(_route.call("left_at", first["station"])) * side
		var last_outward: Vector3 = Vector3(_route.call("left_at", last["station"])) * side
		_add_quad(wall_surface, first_ground - first_outward * WALL_HALF_THICKNESS_M, first_ground + first_outward * WALL_HALF_THICKNESS_M, first_ground + first_outward * WALL_HALF_THICKNESS_M + Vector3.UP * WALL_HEIGHT_M, first_ground - first_outward * WALL_HALF_THICKNESS_M + Vector3.UP * WALL_HEIGHT_M)
		_add_quad(wall_surface, last_ground + last_outward * WALL_HALF_THICKNESS_M, last_ground - last_outward * WALL_HALF_THICKNESS_M, last_ground - last_outward * WALL_HALF_THICKNESS_M + Vector3.UP * WALL_HEIGHT_M, last_ground + last_outward * WALL_HALF_THICKNESS_M + Vector3.UP * WALL_HEIGHT_M)
	wall_surface.generate_normals()
	var wall := MeshInstance3D.new()
	wall.name = "%sLowWall" % edge_name
	wall.mesh = wall_surface.commit()
	wall.material_override = _material(Color(0.53, 0.56, 0.55), 0.88, 0.0)
	wall.set_meta("saisies_s03_junction_edge_side", side)
	wall.set_meta("saisies_s03_junction_edge_ground_source", "S01Landscape._sample_baked_ground")
	edge_root.add_child(wall)

	var rail_root := Node3D.new()
	rail_root.name = "%sRail" % edge_name
	edge_root.add_child(rail_root)
	var rail_stations := _rail_station_list()
	var rail_samples: Array[Dictionary] = []
	for station in rail_stations:
		var half := _edge_half_width(station)
		var sample := _route_point(station, side * (half + 0.35), 0.0)
		sample["station"] = station
		sample["side"] = side
		rail_samples.append(sample)
	for i in rail_samples.size():
		var item: Dictionary = rail_samples[i]
		var ground: Vector3 = item["ground"]
		var post := MeshInstance3D.new()
		post.name = "Post_%02d" % i
		var post_mesh := BoxMesh.new()
		post_mesh.size = Vector3(0.13, WALL_HEIGHT_M + RAIL_UPPER_OFFSET_M + 0.12, 0.13)
		post.mesh = post_mesh
		post.material_override = _material(Color(0.34, 0.37, 0.36), 0.80, 0.55)
		rail_root.add_child(post)
		post.global_transform = Transform3D(Basis.IDENTITY, ground + Vector3.UP * (post_mesh.size.y * 0.5))
	for i in range(rail_samples.size() - 1):
		var a: Dictionary = rail_samples[i]
		var b: Dictionary = rail_samples[i + 1]
		var a_ground: Vector3 = a["ground"]
		var b_ground: Vector3 = b["ground"]
		_add_rail_segment(rail_root, a_ground, b_ground, WALL_HEIGHT_M + RAIL_LOWER_OFFSET_M, "Lower_%02d" % i)
		_add_rail_segment(rail_root, a_ground, b_ground, WALL_HEIGHT_M + RAIL_UPPER_OFFSET_M, "Upper_%02d" % i)
	edge_root.set_meta("saisies_s03_junction_edge_post_count", rail_samples.size())
	edge_root.set_meta("saisies_s03_junction_edge_rail_segment_count", max(0, rail_samples.size() - 1) * 2)
	edge_root.set_meta("saisies_s03_junction_edge_rail_station_step_m", RAIL_STEP_M)
	return edge_root

func _add_rail_segment(parent: Node3D, a: Vector3, b: Vector3, y_offset: float, node_name: String) -> void:
	var a_anchor := a + Vector3.UP * y_offset
	var b_anchor := b + Vector3.UP * y_offset
	var direction := b_anchor - a_anchor
	var length := direction.length()
	if length < 0.05:
		return
	var rail := MeshInstance3D.new()
	rail.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.10, 0.10, length)
	rail.mesh = mesh
	rail.material_override = _material(Color(0.34, 0.37, 0.36), 0.80, 0.55)
	parent.add_child(rail)
	var midpoint := (a_anchor + b_anchor) * 0.5
	rail.global_transform = Transform3D(Basis.looking_at(direction.normalized(), Vector3.UP), midpoint)

func _add_quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	# Keep top-facing pavement and wall caps visible from the camera while
	# retaining the caller's side-face winding for the vertical wall faces.
	var face_normal := (b - a).cross(c - a)
	if face_normal.y < -0.0001:
		surface.add_vertex(a)
		surface.add_vertex(c)
		surface.add_vertex(b)
		surface.add_vertex(a)
		surface.add_vertex(d)
		surface.add_vertex(c)
		return
	surface.add_vertex(a)
	surface.add_vertex(b)
	surface.add_vertex(c)
	surface.add_vertex(a)
	surface.add_vertex(c)
	surface.add_vertex(d)

func _material(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _junction_asphalt_material() -> StandardMaterial3D:
	if _junction_asphalt != null:
		return _junction_asphalt
	_junction_asphalt = StandardMaterial3D.new()
	_junction_asphalt.albedo_texture = load("res://assets/textures/asphalt_02_diff.jpg")
	_junction_asphalt.normal_enabled = true
	_junction_asphalt.normal_texture = load("res://assets/textures/asphalt_02_nor.jpg")
	_junction_asphalt.albedo_color = Color(0.78, 0.78, 0.78)
	_junction_asphalt.roughness = 0.94
	_junction_asphalt.cull_mode = BaseMaterial3D.CULL_DISABLED
	_junction_asphalt.uv1_triplanar = true
	_junction_asphalt.uv1_world_triplanar = true
	_junction_asphalt.uv1_scale = Vector3.ONE * 0.32
	return _junction_asphalt

func _has_command_line_flag(flag: String) -> bool:
	for argument in OS.get_cmdline_user_args():
		if String(argument) == flag:
			return true
	return false
