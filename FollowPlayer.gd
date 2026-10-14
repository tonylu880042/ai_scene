extends Node3D
# Keeps big background pieces (sea plane, mountains) centred on the player.

@export var player_path: NodePath
@export var snap := 0.0        # snap xz to this grid (sea: keeps vertices from swimming)
@export var base_y := 0.0
@export var y_factor := 0.0    # fraction of the player's altitude to follow (mountains: keeps them tall)
@export var route_water: NodePath  # optional Route: y = its water level at the player (+ base_y) - lakes whose level varies per section

@onready var _player: Node3D = get_node(player_path)
@onready var _route: Route = get_node_or_null(route_water)

func _process(_d: float) -> void:
	var p := _player.global_position
	var y := base_y + p.y * y_factor
	if _route and _route.curve:
		y = base_y + _route.water_level(_route.curve.get_closest_offset(_route.to_local(p)))
	global_position = Vector3(snappedf(p.x, snap) if snap > 0.0 else p.x, y,
			snappedf(p.z, snap) if snap > 0.0 else p.z)
