extends Node3D
# Keeps big background pieces (sea plane, mountains) centred on the player.

@export var player_path: NodePath
@export var snap := 0.0        # snap xz to this grid (sea: keeps vertices from swimming)
@export var base_y := 0.0
@export var y_factor := 0.0    # fraction of the player's altitude to follow (mountains: keeps them tall)

@onready var _player: Node3D = get_node(player_path)

func _process(_d: float) -> void:
	var p := _player.global_position
	global_position = Vector3(snappedf(p.x, snap) if snap > 0.0 else p.x, base_y + p.y * y_factor,
			snappedf(p.z, snap) if snap > 0.0 else p.z)
