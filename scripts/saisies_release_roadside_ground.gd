class_name SaisiesReleaseRoadsideGround
extends RefCounted

## Independent contact audit for the release roadside children.
##
## Sampling is deliberately based on world XZ points.  A ready
## SaisiesGeoLandscape is queried through its indexed triangle sampler, and
## the returned world-space triangle vertices are verified before they count as
## visible-mesh proof.  A finite spatial cache remains for standalone scenes
## that expose only MeshInstance3D terrain.  It never converts an object's
## position back into a route station.  Missing points are reported and
## skipped; they never become a claimed proof.

const CONTACT_TOLERANCE_M := 0.45
const BOTTOM_EPSILON_M := 0.08
const MAX_POINTS_PER_NODE := 12
const VISIBLE_TRIANGLE_BIN_M := 24.0
const VISIBLE_TRIANGLE_QUERY_RADIUS_BINS := 1

var _route: Node
var _terrain: Node
var _sample_cache: Dictionary = {}
var _visible_triangles: Array[Dictionary] = []
var _visible_triangle_bins: Dictionary = {}
var _visible_query_bins: Dictionary = {}
var _visible_cache_ready := false

func configure(route: Node, terrain: Node) -> void:
	_route = route
	_terrain = terrain

func run(root: Node) -> Dictionary:
	var records: Array[Dictionary] = []
	var misses: Array[Dictionary] = []
	var candidate_count := 0
	var candidates: Array[Dictionary] = []
	var contact_points: Array[Vector3] = []
	if root != null:
		for child in root.find_children("*", "", true, false):
			var node := child as Node3D
			if node == null or not _is_contact_candidate(node):
				continue
			candidate_count += 1
			var points := _contact_points(node)
			candidates.append({
				"node": node,
				"points": points,
				"support_kind": _support_kind(node),
				"support_expectation": _support_expectation(node),
			})
			for point in points:
				if is_finite(point.x) and is_finite(point.y) and is_finite(point.z):
					_append_unique(contact_points, point)
			for query_point in _contact_query_points(node):
				if is_finite(query_point.x) and is_finite(query_point.y) and is_finite(query_point.z):
					_append_unique(contact_points, query_point)
	# Build the finite cache before sampling so every contact report is tied to
	# the visible terrain/shoulder meshes even when the landscape convenience
	# sampler is available.  The cache walks the landscape owner and its world
	# parent because gravel shoulders are authored beside (not under) the
	# SaisiesGeoLandscape node.
	_prepare_visible_mesh_cache(contact_points)
	if root == null:
		return _summary(records, misses, candidate_count)
	for candidate in candidates:
		var node: Node3D = candidate["node"]
		var points: Array[Vector3] = candidate["points"]
		var support_kind := String(candidate.get("support_kind", "mesh_bottom"))
		var support_expectation: Dictionary = candidate.get("support_expectation", {})
		if points.is_empty():
			misses.append({"path": String(node.get_path()), "support_kind": support_kind, "reason": "no supported contact footprint"})
			continue
		var sampled_for_node := 0
		for point in points:
			var sample := _sample_world(point)
			if sample.is_empty():
				misses.append({"path": String(node.get_path()), "point": point, "reason": "no visible terrain/shoulder triangle"})
				continue
			sampled_for_node += 1
			var clearance := float(point.y) - float(sample["ground_y"])
			var support_evaluation := _classify_support(clearance, support_expectation)
			records.append({
				"path": String(node.get_path()),
				"node_name": String(node.name),
				"support_kind": support_kind,
				"actual_support_mesh": bool(node.get_meta("saisies_release_support_mesh", false)) or bool(node.get_meta("saisies_release_rock_support_mesh", false)),
				"actual_support_vertex_index_count": int(node.get_meta("saisies_release_support_bottom_vertex_count", node.get_meta("saisies_release_rock_support_vertex_count", 0))),
				"support_expectation": String(support_expectation.get("kind", "surface_contact")),
				"point": point,
				"ground_y": float(sample["ground_y"]),
				"clearance_m": clearance,
				"support_pass": bool(support_evaluation["support_pass"]),
				"support_embedding_class": String(support_evaluation["support_embedding_class"]),
				"declared_foundation_depth_m": float(support_expectation.get("declared_foundation_depth_m", 0.0)),
				"source": String(sample["source"]),
				"triangle_start": int(sample.get("triangle_start", -1)),
				"barycentric": sample.get("barycentric", Vector3.ZERO),
				"triangle_a": sample.get("a", Vector3.ZERO),
				"triangle_b": sample.get("b", Vector3.ZERO),
				"triangle_c": sample.get("c", Vector3.ZERO),
				"sample_proof": String(sample.get("sample_proof", "")),
			})
		if sampled_for_node == 0:
			misses.append({"path": String(node.get_path()), "support_kind": support_kind, "reason": "all supported contact points missed visible terrain"})
	return _summary(records, misses, candidate_count)

func _summary(records: Array[Dictionary], misses: Array[Dictionary], candidate_count: int) -> Dictionary:
	var max_abs_clearance := 0.0
	var min_clearance := INF
	var max_clearance := -INF
	var positive_float_count := 0
	var over_embedded_count := 0
	var expected_embedding_count := 0
	var support_failure_count := 0
	var min_declared_foundation_depth := INF
	var max_declared_foundation_depth := -INF
	var source_counts: Dictionary = {}
	var support_kind_counts: Dictionary = {}
	for record in records:
		var clearance := float(record.get("clearance_m", NAN))
		if not is_finite(clearance):
			continue
		max_abs_clearance = maxf(max_abs_clearance, absf(clearance))
		min_clearance = minf(min_clearance, clearance)
		max_clearance = maxf(max_clearance, clearance)
		var embedding_class := String(record.get("support_embedding_class", "supported"))
		if embedding_class == "positive_float":
			positive_float_count += 1
		elif embedding_class == "over_embedded":
			over_embedded_count += 1
		elif embedding_class == "expected_embedding":
			expected_embedding_count += 1
		if not bool(record.get("support_pass", false)):
			support_failure_count += 1
		var declared_depth := float(record.get("declared_foundation_depth_m", 0.0))
		if declared_depth > 0.0:
			min_declared_foundation_depth = minf(min_declared_foundation_depth, declared_depth)
			max_declared_foundation_depth = maxf(max_declared_foundation_depth, declared_depth)
		var source := String(record.get("source", "unknown"))
		source_counts[source] = int(source_counts.get(source, 0)) + 1
		var support_kind := String(record.get("support_kind", "unknown"))
		support_kind_counts[support_kind] = int(support_kind_counts.get(support_kind, 0)) + 1
	var supported := records.size() > 0
	var visible_sample_count := 0
	var visible_direct_sample_count := 0
	var fallback_sample_count := 0
	for record in records:
		if String(record.get("source", "")).begins_with("visible_mesh:"):
			visible_sample_count += 1
			if String(record.get("source", "")).begins_with("visible_mesh:direct:"):
				visible_direct_sample_count += 1
		else:
			fallback_sample_count += 1
	# The terrain sampler fallback is useful for diagnostics, but cannot prove
	# that the visible release mesh actually supports the roadside geometry.
	var ground_proof := supported and visible_sample_count > 0 and fallback_sample_count == 0 and misses.is_empty()
	var ground_pass := ground_proof and support_failure_count == 0
	return {
		"candidate_count": candidate_count,
		"sample_count": records.size(),
		"miss_count": misses.size(),
		"records": records,
		"misses": misses,
		"source_counts": source_counts,
		"support_kind_counts": support_kind_counts,
		"ground_proof": ground_proof,
		"ground_pass": ground_pass,
		"min_clearance_m": 0.0 if records.is_empty() else min_clearance,
		"max_clearance_m": 0.0 if records.is_empty() else max_clearance,
		"max_abs_clearance_m": max_abs_clearance,
		"positive_float_count": positive_float_count,
		"over_embedded_count": over_embedded_count,
		"expected_embedding_count": expected_embedding_count,
		"support_failure_count": support_failure_count,
		"foundation_burial_range_m": {
			"min": 0.0 if min_declared_foundation_depth == INF else min_declared_foundation_depth,
			"max": 0.0 if max_declared_foundation_depth == -INF else max_declared_foundation_depth,
		},
		"contact_tolerance_m": CONTACT_TOLERANCE_M,
		"visible_triangle_cache_count": _visible_triangles.size(),
		"visible_triangle_bin_count": _visible_triangle_bins.size(),
		"visible_query_bin_count": _visible_query_bins.size(),
		"visible_sample_count": visible_sample_count,
		"visible_direct_sample_count": visible_direct_sample_count,
		"fallback_sample_count": fallback_sample_count,
		"visible_triangle_cache_mode": "landscape_indexed_direct" if _terrain != null and _terrain.has_method("sample_mesh_triangle") else "spatial_mesh_cache",
	}

func _is_contact_candidate(node: Node3D) -> bool:
	var name := String(node.name)
	if name.begins_with("SaisiesUpperFarm_") or name.begins_with("SaisiesUpperPowerPole_"):
		return true
	if name == "SaisiesUpperGuardPost" or name.begins_with("SaisiesUpperGuardPost"):
		return true
	if ((name.begins_with("SaisiesS08RightParapet") or name.begins_with("SaisiesS09StoneBlock")) and not _is_wall_cap_visual(name)) or name == "SaisiesS08LeftCutSlope":
		return true
	if name.begins_with("SaisiesLowerChalet_") or name == "SaisiesLowerWoodShed" or name == "SaisiesLowerJunctionKiosk" or name == "SaisiesLowerSpeedLimit50":
		return true
	if name == "SaisiesLowerContinuousRockCut" or name.begins_with("SaisiesLowerContinuousRockCut_") or name.begins_with("SaisiesLowerRailPosts"):
		return true
	if name.begins_with("SaisiesLowerJunction") and not _is_junction_paint_visual(name):
		return true
	return false

func _is_junction_paint_visual(name: String) -> bool:
	return name == "SaisiesLowerJunctionEdge" or name == "SaisiesLowerJunctionGiveWayLine" or name == "SaisiesLowerJunctionCentreMark"

func _is_wall_cap_visual(name: String) -> bool:
	return name.begins_with("SaisiesS08RightParapetCap") or name.begins_with("SaisiesS09StoneCap")

func _support_kind(node: Node3D) -> String:
	var name := String(node.name)
	if name.begins_with("SaisiesLowerRailPosts"):
		return "rail_post_boxmesh_bottom"
	if name.begins_with("SaisiesLowerContinuousRockCut"):
		return "rock_actual_footline_vertices"
	if name.begins_with("SaisiesUpperPowerPole"):
		return "pole_mast_actual_bottom_vertices"
	if name.begins_with("SaisiesUpperFarm_") or name.begins_with("SaisiesLowerChalet_"):
		return "foundation_actual_bottom_vertices"
	if name == "SaisiesLowerWoodShed" or name == "SaisiesLowerJunctionKiosk":
		return "base_actual_bottom_vertices"
	if name == "SaisiesLowerSpeedLimit50" or name == "SaisiesLowerJunctionSigns":
		return "sign_mast_actual_bottom_vertices"
	if name == "SaisiesLowerJunctionBranch":
		return "junction_branch_actual_bottom_vertices"
	return "mesh_actual_bottom_vertices"

func _support_expectation(node: Node3D) -> Dictionary:
	var name := String(node.name)
	if name.begins_with("SaisiesUpperFarm_") and node.has_meta("saisies_farm_foundation_burial_m"):
		return {
			"kind": "foundation",
			"declared_foundation_depth_m": maxf(float(node.get_meta("saisies_farm_foundation_burial_m")), 0.0),
		}
	return {"kind": "surface_contact", "declared_foundation_depth_m": 0.0}

func _classify_support(clearance: float, expectation: Dictionary) -> Dictionary:
	var declared_depth := maxf(float(expectation.get("declared_foundation_depth_m", 0.0)), 0.0)
	if clearance > CONTACT_TOLERANCE_M:
		return {"support_pass": false, "support_embedding_class": "positive_float"}
	if clearance < -CONTACT_TOLERANCE_M:
		if declared_depth > 0.0 and clearance >= -(declared_depth + CONTACT_TOLERANCE_M):
			return {"support_pass": true, "support_embedding_class": "expected_embedding"}
		return {"support_pass": false, "support_embedding_class": "over_embedded"}
	return {"support_pass": true, "support_embedding_class": "supported"}

func _contact_points(node: Node3D) -> Array[Vector3]:
	var name := String(node.name)
	if name.begins_with("SaisiesLowerRailPosts"):
		# Warm every post footprint before the repair pass; the audit itself may
		# still sample only a bounded representative subset.
		return _multimesh_bottom_points(node as MultiMeshInstance3D, false)
	# Use the first direct MeshInstance as the authored support part.  Descendant
	# roofs, crossarms and signs are visual parts, not terrain support points.
	if name.begins_with("SaisiesUpperFarm_") or name.begins_with("SaisiesUpperPowerPole") or name.begins_with("SaisiesLowerChalet_") or name == "SaisiesLowerWoodShed" or name == "SaisiesLowerJunctionKiosk" or name == "SaisiesLowerSpeedLimit50" or name == "SaisiesLowerJunctionSigns":
		return _first_direct_mesh_bottom_points(node)
	if name.begins_with("SaisiesLowerContinuousRockCut"):
		if bool(node.get_meta("saisies_release_rock_support_mesh", false)):
			return _rock_support_mesh_points(node as MeshInstance3D)
		# Warm the visible triangle query bins with every authored toe before the
		# repair pass.  The audit path may cap this to a representative subset,
		# but fitting must be able to sample the complete rock footprint.
		return _rock_footline_points(node as MeshInstance3D, false)
	if name == "SaisiesS08LeftCutSlope":
		# _build_cut_slope emits each quad as a,b,c,a,c,d.  Its actual support
		# ring is the inner a/d edge, not the global local-Y minimum.
		return _cut_slope_inner_toe_points(node as MeshInstance3D, false)
	if name == "SaisiesLowerJunctionBranch" and bool(node.get_meta("saisies_release_junction_branch_draped", false)):
		return _junction_branch_bottom_points(node as MeshInstance3D)
	if node is MeshInstance3D:
		if bool(node.get_meta("saisies_release_support_mesh", false)):
			return _support_mesh_bottom_points(node as MeshInstance3D)
		return _mesh_bottom_points(node as MeshInstance3D)
	# A generic authored root is sampled from actual child mesh bottom vertices.
	var points: Array[Vector3] = []
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mesh_child := child as MeshInstance3D
		if bool(mesh_child.get_meta("saisies_release_support_mesh", false)):
			for point in _support_mesh_bottom_points(mesh_child):
				_append_unique(points, point)
				if points.size() >= MAX_POINTS_PER_NODE:
					break
			if points.size() >= MAX_POINTS_PER_NODE:
				break
			continue
		for point in _mesh_bottom_points(mesh_child):
			_append_unique(points, point)
			if points.size() >= MAX_POINTS_PER_NODE:
				break
		if points.size() >= MAX_POINTS_PER_NODE:
			break
	return points

func _contact_query_points(node: Node3D) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if String(node.name) != "SaisiesLowerJunctionBranch":
		return points
	var mesh_instance := node as MeshInstance3D
	if mesh_instance == null or mesh_instance.mesh == null:
		return points
	var bounds := mesh_instance.get_aabb()
	for z_index in range(13):
		var z_fraction := float(z_index) / 12.0
		var local_z := lerpf(bounds.position.z, bounds.end.z, z_fraction)
		for x_index in range(3):
			var x_fraction := float(x_index) / 2.0
			var local_x := lerpf(bounds.position.x, bounds.end.x, x_fraction)
			points.append(mesh_instance.global_transform * Vector3(local_x, 0.0, local_z))
	return points

func _first_direct_mesh_bottom_points(node: Node3D) -> Array[Vector3]:
	for child in node.get_children():
		var mesh_child := child as MeshInstance3D
		if mesh_child != null:
			if bool(mesh_child.get_meta("saisies_release_support_mesh", false)):
				return _support_mesh_bottom_points(mesh_child)
			return _mesh_bottom_points(mesh_child)
	return []

func _junction_branch_bottom_points(mesh_instance: MeshInstance3D) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if mesh_instance == null or mesh_instance.mesh == null or mesh_instance.mesh.get_surface_count() == 0:
		return points
	var arrays := mesh_instance.mesh.surface_get_arrays(0)
	if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
		return points
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	# _build_draped_branch_mesh stores each sampled top/bottom pair adjacent;
	# selecting the odd member keeps the support audit on actual lower vertices
	# even when the branch follows a steep terrain slope.
	for index in range(1, vertices.size(), 2):
		_append_unique(points, mesh_instance.global_transform * vertices[index])
	return _limit_points(points, MAX_POINTS_PER_NODE)

func _mesh_bottom_points(mesh_instance: MeshInstance3D) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if mesh_instance == null or mesh_instance.mesh == null:
		return points
	# AABB corners are bounds, not necessarily mesh vertices.  In particular a
	# turned/curved rock strip can have corners hundreds of metres from any
	# authored support.  Use the actual indexed face vertices and classify the
	# bottom in mesh-local Y so rotated boxes retain their full bottom face.
	var faces := mesh_instance.mesh.get_faces()
	if faces.is_empty():
		return points
	var local_min_y := INF
	for local in faces:
		local_min_y = minf(local_min_y, local.y)
	for local in faces:
		if local.y > local_min_y + BOTTOM_EPSILON_M:
			continue
		_append_unique(points, mesh_instance.global_transform * local)
		if points.size() >= MAX_POINTS_PER_NODE:
			break
	return points

func _support_mesh_bottom_points(mesh_instance: MeshInstance3D) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if mesh_instance == null or mesh_instance.mesh == null or mesh_instance.mesh.get_surface_count() == 0:
		return points
	var arrays := mesh_instance.mesh.surface_get_arrays(0)
	if arrays.size() <= Mesh.ARRAY_VERTEX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
		return points
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var count := clampi(int(mesh_instance.get_meta("saisies_release_support_bottom_vertex_count", 0)), 0, vertices.size())
	for index in range(count):
		var world := mesh_instance.global_transform * vertices[index]
		if is_finite(world.x) and is_finite(world.y) and is_finite(world.z):
			_append_unique(points, world)
	return _limit_points(points, MAX_POINTS_PER_NODE)

## Fit a solid support mesh to the visible terrain cache without changing its
## authored top profile.  The replacement mesh stores the actual fitted bottom
## vertices first, so later audits read those vertices rather than a metadata
## claim.  The mesh is rebuilt in the instance's original local space, so its
## authored Node3D transform remains valid for route-side clearance checks.
func fit_mesh_bottom_to_sampler(mesh_instance: MeshInstance3D, embed_depth_m := 0.03, allow_parent_lift := false) -> bool:
	if mesh_instance == null or mesh_instance.mesh == null:
		return false
	var data := _mesh_face_data(mesh_instance)
	var local_vertices: Array[Vector3] = data.get("vertices", [])
	var face_indices: PackedInt32Array = data.get("indices", PackedInt32Array())
	if local_vertices.is_empty() or face_indices.is_empty():
		return false
	var local_min_y := INF
	for local in local_vertices:
		local_min_y = minf(local_min_y, local.y)
	var bottom_indices: Array[int] = []
	for index in range(local_vertices.size()):
		if local_vertices[index].y <= local_min_y + BOTTOM_EPSILON_M:
			bottom_indices.append(index)
	if bottom_indices.is_empty():
		return false
	if bottom_indices.size() >= local_vertices.size():
		return false
	var world_transform := mesh_instance.global_transform
	var world_vertices := _world_vertices(world_transform, local_vertices)
	var fitted_bottom_y: Dictionary = {}
	var required_parent_lift := 0.0
	for index in bottom_indices:
		var point: Vector3 = world_vertices[index]
		var sample := _sample_world(Vector3(point.x, 0.0, point.z))
		if sample.is_empty() or not sample.has("ground_y"):
			return false
		var target_y := float(sample["ground_y"]) - maxf(float(embed_depth_m), 0.0)
		fitted_bottom_y[index] = target_y
		var corresponding_top_y := _corresponding_top_y(local_vertices, world_vertices, bottom_indices, index)
		if not is_finite(corresponding_top_y):
			return false
		if target_y >= corresponding_top_y - 0.01:
			required_parent_lift = maxf(required_parent_lift, target_y - corresponding_top_y + 0.02)
	if required_parent_lift > 0.0:
		if not allow_parent_lift:
			return false
		var parent := mesh_instance.get_parent() as Node3D
		if parent == null:
			return false
		# Lift the complete chalet/foundation parent in world Y.  All roof and
		# facade parts retain their authored local offsets while the foundation
		# is then refit against the same visible terrain samples.
		parent.global_position.y += required_parent_lift
		world_transform = mesh_instance.global_transform
		world_vertices = _world_vertices(world_transform, local_vertices)
		fitted_bottom_y.clear()
		for index in bottom_indices:
			var point: Vector3 = world_vertices[index]
			var sample := _sample_world(Vector3(point.x, 0.0, point.z))
			if sample.is_empty() or not sample.has("ground_y"):
				return false
			var target_y := float(sample["ground_y"]) - maxf(float(embed_depth_m), 0.0)
			var corresponding_top_y := _corresponding_top_y(local_vertices, world_vertices, bottom_indices, index)
			if not is_finite(corresponding_top_y) or target_y >= corresponding_top_y - 0.01:
				return false
			fitted_bottom_y[index] = target_y
	for index in fitted_bottom_y.keys():
		world_vertices[int(index)].y = float(fitted_bottom_y[index])
	var uvs: PackedVector2Array = data.get("uvs", PackedVector2Array())
	var colors: PackedColorArray = data.get("colors", PackedColorArray())
	return _replace_mesh_world_vertices(mesh_instance, local_vertices, face_indices, world_vertices, bottom_indices, uvs, colors)

func _world_vertices(world_transform: Transform3D, local_vertices: Array[Vector3]) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for local in local_vertices:
		result.append(world_transform * local)
	return result

func _corresponding_top_y(local_vertices: Array[Vector3], world_vertices: Array[Vector3], bottom_indices: Array[int], bottom_index: int) -> float:
	# A global top_world_min_y would invert a sloped foundation at its uphill
	# corner; compare each bottom footprint against its nearest authored top.
	var bottom_local: Vector3 = local_vertices[bottom_index]
	var nearest_top_distance := INF
	var corresponding_top_y := -INF
	for top_index in range(local_vertices.size()):
		if bottom_indices.has(top_index):
			continue
		var top_local: Vector3 = local_vertices[top_index]
		var top_distance := Vector2(top_local.x - bottom_local.x, top_local.z - bottom_local.z).length_squared()
		if top_distance < nearest_top_distance:
			nearest_top_distance = top_distance
			corresponding_top_y = world_vertices[top_index].y
	return corresponding_top_y

## Correct only positive rock-toe vertices selected by the actual authored
## footline ring.  High rock faces remain untouched; a mesh vertex is lowered
## only when the route-ground-selected toe point visibly floats above the
## indexed terrain sample.
func fit_rock_footline_to_sampler(mesh_instance: MeshInstance3D, embed_depth_m := 0.03) -> bool:
	if mesh_instance == null or mesh_instance.mesh == null:
		return false
	# Repair every authored toe vertex.  The audit path deliberately samples a
	# bounded/evenly-spaced subset, but fitting only that subset would leave
	# unsampled positive floats in the rendered rock.
	var footline := _rock_footline_points(mesh_instance, false)
	if footline.is_empty():
		return false
	var data := _mesh_face_data(mesh_instance)
	var local_vertices: Array[Vector3] = data.get("vertices", [])
	var face_indices: PackedInt32Array = data.get("indices", PackedInt32Array())
	var uvs: PackedVector2Array = data.get("uvs", PackedVector2Array())
	var colors: PackedColorArray = data.get("colors", PackedColorArray())
	if local_vertices.is_empty() or face_indices.is_empty():
		return false
	var world_transform := mesh_instance.global_transform
	var world_vertices: Array[Vector3] = []
	var changed_indices: Array[int] = []
	var footline_indices: Array[int] = []
	for index in range(local_vertices.size()):
		var point: Vector3 = world_transform * local_vertices[index]
		world_vertices.append(point)
		for toe in footline:
			if point.distance_squared_to(toe) > 0.0001:
				continue
			footline_indices.append(index)
			var sample := _sample_world(Vector3(point.x, 0.0, point.z))
			if sample.is_empty() or not sample.has("ground_y"):
				return false
			var ground_y := float(sample["ground_y"])
			if point.y > ground_y + CONTACT_TOLERANCE_M:
				world_vertices[index].y = ground_y - maxf(float(embed_depth_m), 0.0)
				changed_indices.append(index)
			break
	if changed_indices.is_empty():
		# A sampled toe with no positive clearance already satisfies the
		# correction pass; report success without replacing an unchanged mesh.
		return true
	var replaced := _replace_mesh_world_vertices(mesh_instance, local_vertices, face_indices, world_vertices, footline_indices, uvs, colors)
	if replaced:
		mesh_instance.set_meta("saisies_release_rock_support_mesh", true)
		mesh_instance.set_meta("saisies_release_rock_support_vertex_count", footline_indices.size())
	return replaced

## Fit the actual inner toe ring emitted by UpperScenery._build_cut_slope.
## SurfaceTool writes each quad as a,b,c,a,c,d, so the route-ground a/d
## vertices are identified by their visible route support height rather than a
## global local-Y minimum that can select an unrelated end of the sloped strip.
func fit_cut_slope_inner_to_sampler(mesh_instance: MeshInstance3D, embed_depth_m := 0.03) -> bool:
	if mesh_instance == null or mesh_instance.mesh == null:
		return false
	var data := _mesh_face_data(mesh_instance)
	var local_vertices: Array[Vector3] = data.get("vertices", [])
	var face_indices: PackedInt32Array = data.get("indices", PackedInt32Array())
	var uvs: PackedVector2Array = data.get("uvs", PackedVector2Array())
	var colors: PackedColorArray = data.get("colors", PackedColorArray())
	var toe_indices := _cut_slope_inner_toe_indices(mesh_instance, local_vertices)
	if local_vertices.is_empty() or face_indices.is_empty() or toe_indices.is_empty():
		return false
	var world_transform := mesh_instance.global_transform
	var world_vertices := _world_vertices(world_transform, local_vertices)
	var changed_indices: Array[int] = []
	for index in toe_indices:
		var point: Vector3 = world_vertices[index]
		var sample := _sample_world(Vector3(point.x, 0.0, point.z))
		if sample.is_empty() or not sample.has("ground_y"):
			return false
		var ground_y := float(sample["ground_y"])
		if point.y > ground_y + CONTACT_TOLERANCE_M:
			world_vertices[index].y = ground_y - maxf(float(embed_depth_m), 0.0)
			changed_indices.append(index)
	if changed_indices.is_empty():
		mesh_instance.set_meta("saisies_release_support_mesh", true)
		mesh_instance.set_meta("saisies_release_support_bottom_vertex_count", toe_indices.size())
		return true
	var replaced := _replace_mesh_world_vertices(mesh_instance, local_vertices, face_indices, world_vertices, toe_indices, uvs, colors)
	if replaced:
		mesh_instance.set_meta("saisies_release_support_mesh", true)
		mesh_instance.set_meta("saisies_release_support_bottom_vertex_count", toe_indices.size())
	return replaced

func _cut_slope_inner_toe_points(mesh_instance: MeshInstance3D, limit_for_audit := true) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if mesh_instance == null or mesh_instance.mesh == null:
		return points
	var data := _mesh_face_data(mesh_instance)
	var local_vertices: Array[Vector3] = data.get("vertices", [])
	for index in _cut_slope_inner_toe_indices(mesh_instance, local_vertices):
		var world := mesh_instance.global_transform * local_vertices[index]
		_append_unique(points, world)
	return _limit_points(points, MAX_POINTS_PER_NODE) if limit_for_audit else points

func _cut_slope_inner_toe_indices(mesh_instance: MeshInstance3D, local_vertices: Array[Vector3]) -> Array[int]:
	var indices: Array[int] = []
	if mesh_instance == null or local_vertices.is_empty():
		return indices
	var world_vertices := _world_vertices(mesh_instance.global_transform, local_vertices)
	for index in range(world_vertices.size()):
		var point: Vector3 = world_vertices[index]
		var support_y := _route_support_y(point)
		if is_finite(support_y) and absf(point.y - support_y) <= CONTACT_TOLERANCE_M:
			indices.append(index)
	return indices

func _mesh_face_data(mesh_instance: MeshInstance3D) -> Dictionary:
	var source_vertices: Array[Vector3] = []
	var source_uvs := PackedVector2Array()
	var source_colors := PackedColorArray()
	var indices := PackedInt32Array()
	if mesh_instance == null or mesh_instance.mesh == null:
		return {"vertices": source_vertices, "indices": indices, "uvs": source_uvs, "colors": source_colors}
	var arrays := mesh_instance.mesh.surface_get_arrays(0) if mesh_instance.mesh.get_surface_count() > 0 else []
	if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
		var packed_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vertex in packed_vertices:
			source_vertices.append(vertex)
		if arrays.size() > Mesh.ARRAY_TEX_UV and arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
			source_uvs = arrays[Mesh.ARRAY_TEX_UV]
		if arrays.size() > Mesh.ARRAY_COLOR and arrays[Mesh.ARRAY_COLOR] is PackedColorArray:
			source_colors = arrays[Mesh.ARRAY_COLOR]
		if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
			indices = arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			for index in range(source_vertices.size()):
				indices.append(index)
		return {"vertices": source_vertices, "indices": indices, "uvs": source_uvs, "colors": source_colors}
	var faces := mesh_instance.mesh.get_faces()
	for local in faces:
		source_vertices.append(local)
		indices.append(source_vertices.size() - 1)
	return {"vertices": source_vertices, "indices": indices, "uvs": source_uvs, "colors": source_colors}

func _replace_mesh_world_vertices(mesh_instance: MeshInstance3D, local_vertices: Array[Vector3], face_indices: PackedInt32Array, world_vertices: Array[Vector3], support_indices: Array[int], source_uvs := PackedVector2Array(), source_colors := PackedColorArray()) -> bool:
	if mesh_instance == null or local_vertices.is_empty() or face_indices.is_empty() or world_vertices.size() != local_vertices.size():
		return false
	# The release support meshes are single-surface authored solids.  Refuse a
	# multi-surface replacement rather than silently dropping a secondary UV or
	# material stream when rebuilding the fitted geometry.
	if mesh_instance.mesh == null or mesh_instance.mesh.get_surface_count() != 1:
		return false
	var order: Array[int] = []
	for index in support_indices:
		if index >= 0 and index < local_vertices.size() and not order.has(index):
			order.append(index)
	for index in range(local_vertices.size()):
		if not order.has(index):
			order.append(index)
	var remap: Dictionary = {}
	for new_index in range(order.size()):
		remap[order[new_index]] = new_index
	# Keep the node's authored transform.  World-space fitted vertices are
	# converted back through that same transform instead of flattening the node
	# to identity (which would make its origin a misleading route sample).
	var instance_inverse := mesh_instance.global_transform.affine_inverse()
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	for old_index in order:
		vertices.append(instance_inverse * world_vertices[old_index])
		if source_uvs.size() == local_vertices.size():
			uvs.append(source_uvs[old_index])
		if source_colors.size() == local_vertices.size():
			colors.append(source_colors[old_index])
	var indices := PackedInt32Array()
	for old_index in face_indices:
		indices.append(int(remap[int(old_index)]))
	var normals := _normals_from_faces(vertices, indices)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	if uvs.size() == vertices.size():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	if colors.size() == vertices.size():
		arrays[Mesh.ARRAY_COLOR] = colors
	var source_material: Material = mesh_instance.mesh.surface_get_material(0) if mesh_instance.mesh.get_surface_count() > 0 else null
	var replacement := ArrayMesh.new()
	replacement.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if replacement.get_surface_count() <= 0:
		return false
	if source_material != null:
		replacement.surface_set_material(0, source_material)
	mesh_instance.mesh = replacement
	mesh_instance.set_meta("saisies_release_support_mesh", true)
	mesh_instance.set_meta("saisies_release_support_bottom_vertex_count", mini(support_indices.size(), order.size()))
	return true

func _normals_from_faces(vertices: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	for face_start in range(0, indices.size(), 3):
		if face_start + 2 >= indices.size():
			break
		var a := vertices[indices[face_start]]
		var b := vertices[indices[face_start + 1]]
		var c := vertices[indices[face_start + 2]]
		var normal := (c - a).cross(b - a)
		if normal.length_squared() <= 0.000001:
			continue
		normal = normal.normalized()
		normals[indices[face_start]] += normal
		normals[indices[face_start + 1]] += normal
		normals[indices[face_start + 2]] += normal
	for index in range(normals.size()):
		normals[index] = Vector3.UP if normals[index].length_squared() <= 0.000001 else normals[index].normalized()
	return normals

func _rock_footline_points(mesh_instance: MeshInstance3D, limit_for_audit := true) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if mesh_instance == null or mesh_instance.mesh == null:
		return points
	var faces := mesh_instance.mesh.get_faces()
	if faces.is_empty():
		return points
	var world_vertices: Array[Vector3] = []
	for local in faces:
		var world := mesh_instance.global_transform * local
		if is_finite(world.x) and is_finite(world.y) and is_finite(world.z):
			_append_unique(world_vertices, world)
	# The authored cliff toe is the actual route-ground vertex ring.  Identify
	# that ring from the route support height rather than a global Y minimum,
	# because the route can descend substantially across one long rock cut.
	for point in world_vertices:
		var support_y := _route_support_y(point)
		if is_finite(support_y) and absf(point.y - support_y) <= CONTACT_TOLERANCE_M:
			_append_unique(points, point)
	if points.is_empty():
		# Standalone scenes may not expose route projection helpers.  Keep the
		# fallback tied to actual mesh vertices, never synthetic AABB corners.
		var min_y := INF
		for point in world_vertices:
			min_y = minf(min_y, point.y)
		for point in world_vertices:
			if point.y <= min_y + BOTTOM_EPSILON_M:
				_append_unique(points, point)
	return _limit_points(points, MAX_POINTS_PER_NODE) if limit_for_audit else points

func _rock_support_mesh_points(mesh_instance: MeshInstance3D) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if mesh_instance == null or mesh_instance.mesh == null or mesh_instance.mesh.get_surface_count() == 0:
		return points
	var arrays := mesh_instance.mesh.surface_get_arrays(0)
	if arrays.size() <= Mesh.ARRAY_VERTEX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
		return points
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var count := clampi(int(mesh_instance.get_meta("saisies_release_rock_support_vertex_count", 0)), 0, vertices.size())
	for index in range(count):
		var world := mesh_instance.global_transform * vertices[index]
		if is_finite(world.x) and is_finite(world.y) and is_finite(world.z):
			_append_unique(points, world)
	return _limit_points(points, MAX_POINTS_PER_NODE)

func _route_support_y(point: Vector3) -> float:
	if _route == null or not _route.has_method("distance_for_position") or not _route.has_method("pos_at") or not _route.has_method("left_at") or not _route.has_method("ground_y"):
		return NAN
	var station := clampf(float(_route.call("distance_for_position", point)), 0.0, float(_route.get("length_m")))
	var center: Vector3 = _route.call("pos_at", station)
	var left: Vector3 = _route.call("left_at", station)
	var lateral := left.dot(point - center)
	return float(_route.call("ground_y", station, lateral))

func _limit_points(points: Array[Vector3], limit: int) -> Array[Vector3]:
	if points.size() <= limit:
		return points
	var limited: Array[Vector3] = []
	for index in range(limit):
		var fraction := float(index) / float(maxi(limit - 1, 1))
		var source_index := clampi(int(round(fraction * float(points.size() - 1))), 0, points.size() - 1)
		_append_unique(limited, points[source_index])
	return limited

func _multimesh_bottom_points(instance: MultiMeshInstance3D, limit_for_audit := true) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if instance == null or instance.multimesh == null:
		return points
	var mesh := instance.multimesh.mesh
	if mesh == null:
		return points
	var faces := mesh.get_faces()
	if faces.is_empty():
		return points
	var local_min_y := INF
	for local in faces:
		local_min_y = minf(local_min_y, local.y)
	var count := instance.multimesh.instance_count if not limit_for_audit else mini(instance.multimesh.instance_count, MAX_POINTS_PER_NODE)
	for index in range(count):
		var instance_transform := instance.multimesh.get_instance_transform(index)
		var bottom: Array[Vector3] = []
		for local in faces:
			if local.y > local_min_y + BOTTOM_EPSILON_M:
				continue
			var world := instance.global_transform * instance_transform * local
			_append_unique(bottom, world)
		if bottom.is_empty():
			continue
		var support := Vector3.ZERO
		for point in bottom:
			support += point
		_append_unique(points, support / float(bottom.size()))
	return points

## Extend every generated guard-post instance to the sampled visible ground.
## The beam remains at its authored top because the post's Y scale grows by the
## required delta while its center drops by half that delta.
func fit_rail_post_multimesh_to_sampler(instance: MultiMeshInstance3D, embed_depth_m := 0.03) -> bool:
	if instance == null or instance.multimesh == null or instance.multimesh.mesh == null:
		return false
	if instance.multimesh.instance_count <= 0:
		return false
	var faces := instance.multimesh.mesh.get_faces()
	if faces.is_empty():
		return false
	var local_min_y := INF
	var local_max_y := -INF
	for local in faces:
		local_min_y = minf(local_min_y, local.y)
		local_max_y = maxf(local_max_y, local.y)
	var local_height := local_max_y - local_min_y
	if not is_finite(local_height) or local_height <= 0.0001:
		return false
	for index in instance.multimesh.instance_count:
		var local_transform := instance.multimesh.get_instance_transform(index)
		var world_transform := instance.global_transform * local_transform
		var world_y_axis := world_transform.basis.y
		var world_y_length := world_y_axis.length()
		if world_y_length <= 0.0001 or absf(world_y_axis.normalized().dot(Vector3.UP)) < 0.98:
			return false
		var current_bottom_y := INF
		var current_top_y := -INF
		var target_bottom_y := INF
		for local in faces:
			var world := world_transform * local
			if local.y <= local_min_y + BOTTOM_EPSILON_M:
				current_bottom_y = minf(current_bottom_y, world.y)
				var sample := _sample_world(Vector3(world.x, 0.0, world.z))
				if sample.is_empty() or not sample.has("ground_y"):
					return false
				target_bottom_y = minf(target_bottom_y, float(sample["ground_y"]) - maxf(float(embed_depth_m), 0.0))
			if local.y >= local_max_y - BOTTOM_EPSILON_M:
				current_top_y = maxf(current_top_y, world.y)
		if not is_finite(current_bottom_y) or not is_finite(current_top_y) or not is_finite(target_bottom_y):
			return false
		var delta := current_bottom_y - target_bottom_y
		if delta <= 0.001:
			continue
		var current_height := current_top_y - current_bottom_y
		if current_height <= 0.0001:
			return false
		var new_height := current_height + delta
		var scale_ratio := new_height / current_height
		var new_basis := Basis(world_transform.basis.x, world_y_axis.normalized() * (world_y_length * scale_ratio), world_transform.basis.z)
		var new_origin := world_transform.origin + Vector3.DOWN * (delta * 0.5)
		var desired_world := Transform3D(new_basis, new_origin)
		var desired_local := instance.global_transform.affine_inverse() * desired_world
		instance.multimesh.set_instance_transform(index, desired_local)
	# A valid post group is a successful fit even when its authored bottom was
	# already within tolerance; callers use false only for an actual sampling or
	# basis failure.
	return true

func _sample_world(point: Vector3) -> Dictionary:
	if not (is_finite(point.x) and is_finite(point.y) and is_finite(point.z)):
		return {}
	# Direct indexed queries are cheap and must use the exact contact XZ.  Do
	# not reuse a neighbouring cached point across a triangle boundary.
	if _terrain != null and _terrain.has_method("sample_mesh_triangle"):
		return _sample_landscape(point)
	var key := Vector2i(floori(point.x * 2.0), floori(point.z * 2.0))
	# The landscape index already resolves the owning visible triangle in O(1).
	# Use it first so a 769x769 DEM never gets expanded into a million-triangle
	# get_faces() cache just to answer a handful of roadside contact points.  Do
	# not reuse a neighbouring half-metre sample here: fitted wall/foundation
	# vertices can cross a triangle boundary after their outward shift.
	var sample := _sample_landscape(point)
	if sample.is_empty():
		sample = _sample_visible_mesh(point)
	_sample_cache[key] = sample
	return sample

## Public cache-backed sampler for release geometry that must conform to the
## plain baked terrain Node3D.  It exposes the same triangle proof shape as
## SaisiesGeoLandscape without requiring that optional script on the terrain.
func sample_mesh_triangle(xz: Vector2) -> Dictionary:
	var sample := _sample_world(Vector3(xz.x, 0.0, xz.y))
	if sample.is_empty() or not sample.has("ground_y"):
		return {}
	return {
		"height": float(sample["ground_y"]),
		"triangle_start": int(sample.get("triangle_start", -1)),
		"barycentric": sample.get("barycentric", Vector3.ZERO),
		"a": sample.get("a", Vector3.ZERO),
		"b": sample.get("b", Vector3.ZERO),
		"c": sample.get("c", Vector3.ZERO),
	}

func _sample_landscape(point: Vector3) -> Dictionary:
	if _terrain == null or not _terrain.has_method("sample_mesh_triangle"):
		return {}
	var raw: Variant = _terrain.call("sample_mesh_triangle", Vector2(point.x, point.z))
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var sample := raw as Dictionary
	if not sample.has("height") or not is_finite(float(sample["height"])):
		return {}
	var a_variant: Variant = sample.get("a", null)
	var b_variant: Variant = sample.get("b", null)
	var c_variant: Variant = sample.get("c", null)
	if a_variant is Vector3 and b_variant is Vector3 and c_variant is Vector3:
		var a: Vector3 = a_variant
		var b: Vector3 = b_variant
		var c: Vector3 = c_variant
		var weights := _barycentric_xz(Vector2(point.x, point.z), a, b, c)
		if weights.x >= -0.0005 and weights.y >= -0.0005 and weights.z >= -0.0005:
			var interpolated_y := a.y * weights.x + b.y * weights.y + c.y * weights.z
			# The returned height must agree with the returned visible triangle.
			# This guards against treating a convenience DEM height as mesh proof.
			if is_finite(interpolated_y) and absf(interpolated_y - float(sample["height"])) <= 0.05:
				return {
					"ground_y": interpolated_y,
					"source": "visible_mesh:direct:%s" % String(_terrain.name),
					"triangle_start": int(sample.get("triangle_start", -1)),
					"barycentric": weights,
					"a": a,
					"b": b,
					"c": c,
					"sample_proof": "indexed_visible_triangle_vertices",
				}
	# A sampler result without visible triangle vertices remains diagnostic only.
	return {
		"ground_y": float(sample["height"]),
		"source": "terrain_height_sampler_fallback",
		"triangle_start": int(sample.get("triangle_start", -1)),
		"barycentric": sample.get("barycentric", Vector3.ZERO),
	}

func _prepare_visible_mesh_cache(contact_points: Array[Vector3]) -> void:
	if _visible_cache_ready:
		return
	_visible_cache_ready = true
	_visible_triangles.clear()
	_visible_triangle_bins.clear()
	_visible_query_bins.clear()
	if _terrain == null:
		return
	# SaisiesGeoLandscape.sample_mesh_triangle is backed by the indexed visible
	# mesh and returns its world-space triangle vertices.  Do not call get_faces()
	# on the full DEM in this mode; the lower route sits beyond the first 100k
	# triangles and a truncated cache would produce false misses.
	if _terrain.has_method("sample_mesh_triangle"):
		return
	# Every contact query is padded by one 24 m bin.  This deliberately covers
	# the sub-metre outward wall correction before the helper resamples the
	# fitted support vertices at their exact XZ positions.
	for point in contact_points:
		var center_bin := _visible_triangle_bin(point.x, point.z)
		for dz in range(-VISIBLE_TRIANGLE_QUERY_RADIUS_BINS, VISIBLE_TRIANGLE_QUERY_RADIUS_BINS + 1):
			for dx in range(-VISIBLE_TRIANGLE_QUERY_RADIUS_BINS, VISIBLE_TRIANGLE_QUERY_RADIUS_BINS + 1):
				_visible_query_bins[Vector2i(center_bin.x + dx, center_bin.y + dz)] = true
	if _visible_query_bins.is_empty():
		return
	var roots: Array[Node] = [_terrain]
	var parent := _terrain.get_parent()
	if parent != null:
		roots.append(parent)
	var seen: Dictionary = {}
	for root in roots:
		if root == null:
			continue
		for child in root.find_children("*", "MeshInstance3D", true, false):
			var instance := child as MeshInstance3D
			if instance == null or instance.mesh == null:
				continue
			var instance_path := String(instance.get_path())
			if seen.has(instance_path):
				continue
			seen[instance_path] = true
			var name := String(instance.name)
			if not (name.contains("SaisiesGeoTerrain") or name.contains("SaisiesGeoGravelShoulders") or name.contains("Shoulder")):
				continue
			var faces := instance.mesh.get_faces()
			var triangle_count := faces.size() / 3
			for triangle in range(triangle_count):
				var start := triangle * 3
				var a: Vector3 = instance.global_transform * faces[start]
				var b: Vector3 = instance.global_transform * faces[start + 1]
				var c: Vector3 = instance.global_transform * faces[start + 2]
				var min_x := minf(a.x, minf(b.x, c.x))
				var max_x := maxf(a.x, maxf(b.x, c.x))
				var min_z := minf(a.z, minf(b.z, c.z))
				var max_z := maxf(a.z, maxf(b.z, c.z))
				var min_bin := _visible_triangle_bin(min_x, min_z)
				var max_bin := _visible_triangle_bin(max_x, max_z)
				var intersects_query := false
				for z in range(min_bin.y, max_bin.y + 1):
					for x in range(min_bin.x, max_bin.x + 1):
						if _visible_query_bins.has(Vector2i(x, z)):
							intersects_query = true
							break
					if intersects_query:
						break
				if not intersects_query:
					continue
				var triangle_index := _visible_triangles.size()
				_visible_triangles.append({"a": a, "b": b, "c": c, "start": start, "source": name})
				_register_visible_triangle_bins(triangle_index, a, b, c, min_bin, max_bin)

func _sample_visible_mesh(point: Vector3) -> Dictionary:
	var query := Vector2(point.x, point.z)
	var center_bin := _visible_triangle_bin(point.x, point.z)
	var candidate_indices: Dictionary = {}
	for dz in range(-VISIBLE_TRIANGLE_QUERY_RADIUS_BINS, VISIBLE_TRIANGLE_QUERY_RADIUS_BINS + 1):
		for dx in range(-VISIBLE_TRIANGLE_QUERY_RADIUS_BINS, VISIBLE_TRIANGLE_QUERY_RADIUS_BINS + 1):
			var key := Vector2i(center_bin.x + dx, center_bin.y + dz)
			for triangle_index in _visible_triangle_bins.get(key, []):
				candidate_indices[triangle_index] = true
	var best: Dictionary = {}
	for triangle_index in candidate_indices:
		var triangle: Dictionary = _visible_triangles[int(triangle_index)]
		var a: Vector3 = triangle["a"]
		var b: Vector3 = triangle["b"]
		var c: Vector3 = triangle["c"]
		var weights := _barycentric_xz(query, a, b, c)
		if weights.x < -0.0005 or weights.y < -0.0005 or weights.z < -0.0005:
			continue
		var sample := {
			"ground_y": a.y * weights.x + b.y * weights.y + c.y * weights.z,
			"source": "visible_mesh:%s" % String(triangle["source"]),
			"triangle_start": int(triangle["start"]),
			"barycentric": weights,
			"a": a,
			"b": b,
			"c": c,
			"sample_proof": "spatial_visible_triangle_cache",
		}
		if best.is_empty() or float(sample["ground_y"]) > float(best["ground_y"]):
			best = sample
	return best

func _visible_triangle_bin(x: float, z: float) -> Vector2i:
	return Vector2i(floori(x / VISIBLE_TRIANGLE_BIN_M), floori(z / VISIBLE_TRIANGLE_BIN_M))

func _register_visible_triangle_bins(triangle_index: int, a: Vector3, b: Vector3, c: Vector3, min_bin := Vector2i.ZERO, max_bin := Vector2i.ZERO) -> void:
	var min_x := minf(a.x, minf(b.x, c.x))
	var max_x := maxf(a.x, maxf(b.x, c.x))
	var min_z := minf(a.z, minf(b.z, c.z))
	var max_z := maxf(a.z, maxf(b.z, c.z))
	if min_bin == Vector2i.ZERO and max_bin == Vector2i.ZERO:
		min_bin = _visible_triangle_bin(min_x, min_z)
		max_bin = _visible_triangle_bin(max_x, max_z)
	for z in range(min_bin.y, max_bin.y + 1):
		for x in range(min_bin.x, max_bin.x + 1):
			var key := Vector2i(x, z)
			if not _visible_query_bins.is_empty() and not _visible_query_bins.has(key):
				continue
			var indices: Array = _visible_triangle_bins.get(key, [])
			indices.append(triangle_index)
			_visible_triangle_bins[key] = indices

func _barycentric_xz(point: Vector2, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 := Vector2(b.x - a.x, b.z - a.z)
	var v1 := Vector2(c.x - a.x, c.z - a.z)
	var v2 := point - Vector2(a.x, a.z)
	var denominator := v0.cross(v1)
	if absf(denominator) < 0.000001:
		return Vector3(-1.0, -1.0, -1.0)
	var weight_b := v2.cross(v1) / denominator
	var weight_c := v0.cross(v2) / denominator
	var weight_a := 1.0 - weight_b - weight_c
	return Vector3(weight_a, weight_b, weight_c)

func _append_unique(points: Array[Vector3], point: Vector3) -> void:
	for existing in points:
		if existing.distance_squared_to(point) < 0.0025:
			return
	points.append(point)

