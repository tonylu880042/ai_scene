class_name SaisiesGeoVillageProps
extends "res://scripts/saisies_village_props.gd"

## Geographic S01 planter/flag props.
## The authored v2 prop geometry is retained; only its route anchors and local
## support offsets are resolved against the displayed GeoLandscape mesh.

@export var landscape_path: NodePath

var landscape: Node3D
var _geo_build_attempts := 0
var _geo_contact_fallback_count := 0

func _ready() -> void:
	route = get_node_or_null(route_path) as SaisiesRoute
	if route == null and get_parent() != null:
		route = get_parent().get_node_or_null("Route") as SaisiesRoute
	_resolve_landscape()
	if not _geo_dependencies_ready():
		call_deferred("_try_geo_build")
		return
	_build()

func _try_geo_build() -> void:
	if props_ready:
		return
	_resolve_landscape()
	if _geo_dependencies_ready():
		_build()
		return
	_geo_build_attempts += 1
	if _geo_build_attempts < 96:
		call_deferred("_try_geo_build")
	else:
		push_error("SaisiesGeoVillageProps could not resolve a ready route and GeoLandscape")

func _geo_dependencies_ready() -> bool:
	return route != null and route.route_ready() and landscape != null and landscape.has_method("sample_mesh_triangle") and bool(landscape.get("landscape_ready"))

func _resolve_landscape() -> void:
	if landscape != null:
		return
	if landscape_path != NodePath():
		landscape = get_node_or_null(landscape_path)
	if landscape == null and get_parent() != null:
		landscape = get_parent().get_node_or_null("Landscape")

func _build() -> void:
	if props_ready or not _geo_dependencies_ready():
		return
	_geo_contact_fallback_count = 0
	super._build()
	if props_ready:
		set_meta("saisies_geo_village_props_ground_source", "Landscape.sample_mesh_triangle")
		set_meta("saisies_geo_village_props_contact_fallback_count", _geo_contact_fallback_count)
		set_meta("saisies_geo_village_props_actual_mesh_contact", _geo_contact_fallback_count == 0)

func _sample_mesh(point: Vector3) -> Dictionary:
	if landscape == null or not landscape.has_method("sample_mesh_triangle"):
		return {}
	var sampled = landscape.call("sample_mesh_triangle", Vector2(point.x, point.z))
	return sampled if sampled is Dictionary else {}

func _sample_height(point: Vector3) -> float:
	var sampled := _sample_mesh(point)
	if sampled.has("height") and is_finite(float(sampled["height"])):
		return float(sampled["height"])
	return NAN

func _anchor(parent: Node3D, s: float, u: float, node_name: String) -> Node3D:
	var anchor := Node3D.new()
	anchor.name = node_name
	var distance := clampf(s, from_m, to_m)
	var route_point := route.pos_at(distance) + route.left_at(distance) * u
	var contact_y := _sample_height(route_point)
	if not is_finite(contact_y):
		contact_y = route.ground_y(distance, u)
		_geo_contact_fallback_count += 1
	anchor.position = Vector3(route_point.x, contact_y, route_point.z)
	anchor.basis = Basis.looking_at(route.tangent_at(distance), Vector3.UP)
	anchor.set_meta("route_distance_m", distance)
	anchor.set_meta("route_lateral_m", u)
	anchor.set_meta("saisies_geo_contact_source", "landscape.sample_mesh_triangle" if is_finite(_sample_height(route_point)) else "route.ground_y_fallback")
	anchor.set_meta("saisies_geo_contact_height_m", contact_y)
	var sampled := _sample_mesh(route_point)
	if sampled.has("triangle_start"):
		anchor.set_meta("saisies_geo_contact_triangle_start", int(sampled["triangle_start"]))
		anchor.set_meta("saisies_geo_contact_barycentric", sampled.get("barycentric", Vector3.ZERO))
	parent.add_child(anchor)
	return anchor

func _ground_offset_for_local_point(anchor: Node3D, local_point: Vector3) -> float:
	var world_point: Vector3 = anchor.global_transform * local_point
	var target_y := _sample_height(world_point)
	if not is_finite(target_y):
		var sample_s := route.distance_for_position(world_point)
		var route_point := route.pos_at(sample_s)
		var lateral := (world_point - route_point).dot(route.left_at(sample_s))
		target_y = route.ground_y(sample_s, lateral)
		_geo_contact_fallback_count += 1
	var local_up_y := maxf(anchor.global_transform.basis.y.y, 0.001)
	return (target_y - world_point.y) / local_up_y

