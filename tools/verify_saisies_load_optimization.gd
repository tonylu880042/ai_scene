extends SceneTree

## Compare two profile_saisies_load.gd snapshots.
##
## Geometry and authored tree records must remain byte-equivalent at their
## independent digests. Timing is reported per phase, with an optional
## --require-improvement flag for the optimization turn.
##
##   godot --headless --path . --script \
##     res://tools/verify_saisies_load_optimization.gd -- \
##     --before=/tmp/saisies_round13_baseline.json \
##     --after=/tmp/saisies_round14_after.json \
##     --output=/tmp/saisies_round14_comparison.json --require-improvement

var _before_path := ""
var _after_path := ""
var _output_path := "/tmp/saisies_load_comparison.json"
var _require_improvement := false
var _errors: Array[String] = []

func _initialize() -> void:
	_parse_arguments()
	call_deferred("_run")

func _parse_arguments() -> void:
	var all_args := OS.get_cmdline_args()
	all_args.append_array(OS.get_cmdline_user_args())
	for raw_arg in all_args:
		var arg := String(raw_arg)
		if arg.begins_with("--before="):
			_before_path = arg.substr(9)
		elif arg.begins_with("--after="):
			_after_path = arg.substr(8)
		elif arg.begins_with("--output="):
			_output_path = arg.substr(9)
		elif arg == "--require-improvement":
			_require_improvement = true

func _run() -> void:
	var before := _read_json(_before_path)
	var after := _read_json(_after_path)
	if before.is_empty() or after.is_empty():
		_fail("both --before and --after snapshots are required")
		_finish({"status": "fail", "errors": _errors})
		return
	var report := _compare(before, after)
	_finish(report)

func _read_json(path: String) -> Dictionary:
	if path.is_empty():
		return {}
	var absolute := _globalize_path(path)
	if not FileAccess.file_exists(absolute):
		_fail("snapshot is missing: %s" % absolute)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(absolute))
	if not (parsed is Dictionary):
		_fail("snapshot is not a JSON object: %s" % absolute)
		return {}
	return parsed

func _compare(before: Dictionary, after: Dictionary) -> Dictionary:
	var equivalence: Dictionary = {}
	var timing: Dictionary = {}
	var before_inputs: Dictionary = before.get("input_hashes", {})
	var after_inputs: Dictionary = after.get("input_hashes", {})
	var before_geometry_status := String(before.get("geometry_validation_status", "unsupported"))
	var after_geometry_status := String(after.get("geometry_validation_status", "unsupported"))
	var geometry_verified := before_geometry_status == "verified" and after_geometry_status == "verified"
	equivalence["scene_path"] = _same_field(before, after, "scene_path")
	equivalence["input_hashes"] = before_inputs == after_inputs
	equivalence["geometry_validation"] = geometry_verified
	equivalence["geometry_records"] = geometry_verified and _same_field(before, after, "geometry_records_sha256")
	equivalence["tree_records"] = _same_field(before, after, "tree_records_sha256")
	equivalence["counts"] = _same_counts(before.get("counts", {}), after.get("counts", {}))
	for key in equivalence.keys():
		if not bool(equivalence[key]):
			_fail("equivalence failed: %s" % key)
	if not geometry_verified:
		_fail("geometry validation is unsupported in before/after snapshot (before=%s after=%s)" % [before_geometry_status, after_geometry_status])

	var before_timings: Dictionary = before.get("timings_ms", {})
	var after_timings: Dictionary = after.get("timings_ms", {})
	for key in ["resource_load", "instantiate", "add_child", "scene_ready_signal", "full_scene_actual_ready", "total_until_snapshot"]:
		var before_value := float(before_timings.get(key, -1.0))
		var after_value := float(after_timings.get(key, -1.0))
		var delta := after_value - before_value if before_value >= 0.0 and after_value >= 0.0 else NAN
		var improvement_pct := -delta / before_value * 100.0 if is_finite(delta) and before_value > 0.0 else NAN
		timing[key] = {
			"before_ms": before_value,
			"after_ms": after_value,
			"delta_ms": delta,
			"improvement_percent": improvement_pct,
		}

	var phase_report := _compare_phase_instrumentation(before, after)
	var improved_keys: Array[String] = []
	for key in timing.keys():
		if is_finite(float(timing[key].get("delta_ms", NAN))) and float(timing[key]["delta_ms"]) < 0.0:
			improved_keys.append(String(key))
	var full_ready_delta := float(timing.get("full_scene_actual_ready", {}).get("delta_ms", NAN))
	var full_scene_actual_ready_decreased := is_finite(full_ready_delta) and full_ready_delta < 0.0
	var before_native := not bool(before.get("headless", true))
	var after_native := not bool(after.get("headless", true))
	var both_native := before_native and after_native
	var first_nonblack_gate: Dictionary = {
		"required": both_native,
		"applicable": false,
		"passed": not both_native,
		"reason": "headless_or_mixed_run",
	}
	if both_native:
		var before_first := _first_image_record(before)
		var after_first := _first_image_record(after)
		var before_first_elapsed := float(before_first.get("elapsed_ms", -1.0))
		var after_first_elapsed := float(after_first.get("elapsed_ms", -1.0))
		var first_measurements_valid: bool = before_first.get("status", "") == "measured" and after_first.get("status", "") == "measured" \
			and before_first.get("measurement_scope", "") == "after_full_scene_actual_ready" and after_first.get("measurement_scope", "") == "after_full_scene_actual_ready" \
			and bool(before_first.get("found", false)) and bool(after_first.get("found", false)) \
			and bool(before_first.get("resolution_match", false)) and bool(after_first.get("resolution_match", false)) \
			and before_first_elapsed >= 0.0 and after_first_elapsed >= 0.0
		first_nonblack_gate["applicable"] = first_measurements_valid
		first_nonblack_gate["passed"] = first_measurements_valid and after_first_elapsed < before_first_elapsed
		first_nonblack_gate["before_elapsed_ms"] = before_first_elapsed
		first_nonblack_gate["after_elapsed_ms"] = after_first_elapsed
		first_nonblack_gate["delta_ms"] = after_first_elapsed - before_first_elapsed if first_measurements_valid else NAN
		first_nonblack_gate["reason"] = "measured_1920x1080" if first_measurements_valid else "native_first_nonblack_missing_or_resolution_mismatch"
	var measured_improvement := full_scene_actual_ready_decreased and bool(first_nonblack_gate["passed"])
	var improvement_gate := {
		"full_scene_actual_ready_decreased": full_scene_actual_ready_decreased,
		"native_first_nonblack": first_nonblack_gate,
		"passed": measured_improvement,
	}
	if _require_improvement:
		if not full_scene_actual_ready_decreased:
			_fail("--require-improvement requires full_scene_actual_ready to decrease")
		if both_native and not bool(first_nonblack_gate["passed"]):
			_fail("--require-improvement requires 1920x1080 first_nonblack elapsed to decrease for both native snapshots")

	return {
		"schema_version": 1,
		"status": "pass" if _errors.is_empty() else "fail",
		"errors": _errors.duplicate(),
		"before": {"label": before.get("label", ""), "scene_path": before.get("scene_path", "")},
		"after": {"label": after.get("label", ""), "scene_path": after.get("scene_path", "")},
		"equivalence": equivalence,
		"timing": timing,
		"instrumented_phase_timing": phase_report,
		"improved_top_level_timings": improved_keys,
		"measured_improvement": measured_improvement,
		"improvement_gate": improvement_gate,
		"first_nonblack": {
			"before": _first_image_record(before),
			"after": _first_image_record(after),
		},
		"complete_scene_first_image": {
			"before": _first_image_record(before),
			"after": _first_image_record(after),
		},
		"script_hashes": {
			"before": before.get("script_hashes", {}),
			"after": after.get("script_hashes", {}),
		},
	}

func _first_image_record(snapshot: Dictionary) -> Dictionary:
	var complete: Dictionary = snapshot.get("complete_scene_first_image_1920x1080", {})
	if complete is Dictionary and not complete.is_empty():
		return complete
	var legacy: Dictionary = snapshot.get("first_nonblack_1920x1080", {})
	return legacy if legacy is Dictionary else {}

func _compare_phase_instrumentation(before: Dictionary, after: Dictionary) -> Dictionary:
	var before_instrumentation: Dictionary = before.get("instrumentation", {})
	var after_instrumentation: Dictionary = after.get("instrumentation", {})
	var result: Dictionary = {}
	for module_name in ["Geography", "Landscape", "Forest"]:
		var before_module: Dictionary = before_instrumentation.get(module_name, {})
		var after_module: Dictionary = after_instrumentation.get(module_name, {})
		var before_phases: Dictionary = before_module if module_name == "Geography" else before_module.get("phases", {})
		var after_phases: Dictionary = after_module if module_name == "Geography" else after_module.get("phases", {})
		var module_result: Dictionary = {}
		for phase in before_phases.keys():
			if not after_phases.has(phase):
				continue
			var before_value := float(before_phases[phase])
			var after_value := float(after_phases[phase])
			module_result[String(phase)] = {
				"before_ms": before_value,
				"after_ms": after_value,
				"delta_ms": after_value - before_value,
			}
		result[module_name] = module_result
	return result

func _same_field(before: Dictionary, after: Dictionary, field: String) -> bool:
	return before.get(field, null) == after.get(field, null)

func _same_counts(before: Dictionary, after: Dictionary) -> bool:
	for key in [
		"node_count",
		"node3d_count",
		"mesh_instance_count",
		"multimesh_instance_count",
		"multimesh_instance_total",
		"geometry_instance_count",
		"collision_shape_count",
		"camera_count",
		"light_count",
		"unique_mesh_resource_count",
		"unique_multimesh_resource_count",
		"mesh_vertex_total",
		"mesh_index_total",
		"mesh_triangle_total",
		"mesh_surface_total",
		"multimesh_mesh_instance_total",
	]:
		if before.get(key, null) != after.get(key, null):
			return false
	return true

func _finish(report: Dictionary) -> void:
	var output := _globalize_path(_output_path)
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		_fail("could not write comparison report: %s" % output)
	else:
		file.store_string(JSON.stringify(_canonical_variant(report), "\t"))
		file.store_line("")
		file.close()
	var status := "PASS" if _errors.is_empty() else "FAIL"
	var eq: Dictionary = report.get("equivalence", {})
	var timing: Dictionary = report.get("timing", {})
	print("SAISIES LOAD VERIFY %s geometry=%s trees=%s counts=%s full_ready_delta_ms=%s total_delta_ms=%s report=%s" % [
		status,
		"PASS" if bool(eq.get("geometry_records", false)) else "FAIL",
		"PASS" if bool(eq.get("tree_records", false)) else "FAIL",
		"PASS" if bool(eq.get("counts", false)) else "FAIL",
		str(timing.get("full_scene_actual_ready", {}).get("delta_ms", "n/a")),
		str(timing.get("total_until_snapshot", {}).get("delta_ms", "n/a")),
		output,
	])
	quit(0 if _errors.is_empty() else 1)

func _fail(message: String) -> void:
	_errors.append(message)
	push_error("SAISIES LOAD VERIFY: " + message)

func _globalize_path(path: String) -> String:
	return ProjectSettings.globalize_path(path) if path.begins_with("res://") else path

func _canonical_variant(value: Variant) -> Variant:
	if value == null or value is bool or value is int or value is float or value is String:
		return value
	if value is Array:
		var array_values: Array = []
		for item in value:
			array_values.append(_canonical_variant(item))
		return array_values
	if value is Dictionary:
		var keys: Array[String] = []
		for key in value.keys():
			keys.append(String(key))
		keys.sort()
		var dictionary_values: Dictionary = {}
		for key in keys:
			dictionary_values[key] = _canonical_variant(value[key])
		return dictionary_values
	return str(value)
