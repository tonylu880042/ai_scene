extends Node3D

## Lightweight runtime gate for the static release geometry cache.
## It exposes the same readiness/count contract as ReleaseForest so the
## release controller can toggle the cache without loading its builders.

@export var cache_path: NodePath = NodePath("ReleaseGeometryCache")
@export var enable_refinement := true

var _cache: Node3D

func _ready() -> void:
	process_priority = -210
	call_deferred("_publish_cache_state")

func _process(_delta: float) -> void:
	if _cache != null and is_instance_valid(_cache):
		_cache.visible = enable_refinement
	_publish_cache_state()

func _publish_cache_state() -> void:
	if _cache == null:
		_cache = get_node_or_null(cache_path) as Node3D
	if _cache == null:
		set_meta("saisies_release_forest_ready", false)
		set_meta("saisies_release_forest_enabled", false)
		return
	_cache.visible = enable_refinement
	var ready := bool(_cache.get_meta("saisies_release_cache_ready", false))
	set_meta("saisies_release_forest_ready", ready)
	set_meta("saisies_release_forest_enabled", enable_refinement)
	set_meta("saisies_release_forest_count", int(_cache.get_meta("saisies_release_cache_multimesh_instance_total", 0)))
	set_meta("saisies_release_forest_instance_count", int(_cache.get_meta("saisies_release_cache_multimesh_instance_total", 0)))
	var terminal_geometry_count := int(_cache.get_meta("saisies_release_cache_terminal_geometry_count", 0))
	set_meta("saisies_release_terminals_ready", ready and terminal_geometry_count > 0)
	set_meta("saisies_release_terminals_enabled", enable_refinement)
	set_meta("saisies_release_terminals_geometry_count", terminal_geometry_count)
	set_meta("saisies_release_terminals_label_count", int(_cache.get_meta("saisies_release_cache_label_node_count", 0)))
	set_meta("saisies_release_terminals_cache_source", "native_baked_terminal_geometry" if terminal_geometry_count > 0 else "")
	for key in [
		"station_end_m", "finish_station_m", "start_sign_station_m",
		"arrival_extension_start_m", "arrival_extension_end_m", "arrival_road_rows_m",
		"authored_terrace_bounds", "finish_arch_clear_width_m",
		"finish_arch_centerline_clear", "label_texts", "geometry_nodes", "ground_source"
	]:
		var cache_key := "saisies_release_cache_terminals_%s" % key
		if _cache.has_meta(cache_key):
			set_meta("saisies_release_terminals_%s" % key, _cache.get_meta(cache_key))
	set_meta("saisies_release_cache_gpu_hash_sha256", String(_cache.get_meta("saisies_release_cache_gpu_hash_sha256", "")))
	set_meta("saisies_release_cache_visibility_policy", String(_cache.get_meta("saisies_release_cache_visibility_policy", "")))
	set_meta("saisies_release_cache_gate_ready", ready)
