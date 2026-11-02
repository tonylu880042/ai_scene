class_name SaisiesGeography
extends RefCounted

## Shared geographic/DEM contract for the real Saisies terrain.
##
## The derived DEM is a north-up WebMercator crop.  Geographic positions are
## projected first, then converted to the nominal local metre frame used by
## the asset.  This preserves the exact metadata bounds while keeping the
## 24 km crop and the route distances in the same scene units.

const DATA_DIR := "res://assets/terrain/saisies_geo"
const METADATA_FILE := DATA_DIR + "/metadata.json"
const HEIGHT_FILE := DATA_DIR + "/height.f32"
const OPTIONAL_NEARFIELD_FILE := "res://data/saisies_geo_nearfield.json"
const EARTH_RADIUS_M := 6378137.0
const WEB_MERCATOR_MAX_LAT := 85.0511287798066
const ROUTE_HASH_CELL_M := 64.0
const NEARFIELD_GRID := 65
const NEARFIELD_SPACING_M := 8.0
const NEARFIELD_SIZE_M := 512.0
const NEARFIELD_BLEND_MARGIN_M := 64.0

var configured := false
var datum_m := 0.0
var nearfield_loaded := false
var nearfield_error := ""
var origin_lat := 0.0
var origin_lon := 0.0
var forward_east := 0.0
var forward_north := 1.0
var right_east := 1.0
var right_north := 0.0
var metadata: Dictionary = {}

var _height_grid := 0
var _height_samples := PackedFloat32Array()
var _map_size_m := 0.0
var _west_lon := 0.0
var _south_lat := 0.0
var _east_lon := 0.0
var _north_lat := 0.0
var _west_mercator_x := 0.0
var _east_mercator_x := 0.0
var _south_mercator_y := 0.0
var _north_mercator_y := 0.0
var _mercator_center_x := 0.0
var _mercator_center_y := 0.0
var _mercator_to_local_x := 1.0
var _mercator_to_local_y := 1.0
var _origin_mercator_x := 0.0
var _origin_mercator_y := 0.0
var _route_samples := PackedVector3Array()
var _route_spatial_hash: Dictionary = {}
var _route_half_width_m := 0.0
var _route_blend_outer_m := 25.0
var _route_blend_inner_m := 8.0
var _nearfield_patches: Array = []

func configure(frame: Dictionary, include_nearfield: bool = true) -> bool:
	configured = false
	metadata = {}
	nearfield_loaded = false
	nearfield_error = ""
	_nearfield_patches.clear()
	_height_samples = PackedFloat32Array()
	_route_samples = PackedVector3Array()
	_route_spatial_hash.clear()
	if not _read_frame(frame):
		return false
	if not FileAccess.file_exists(METADATA_FILE) or not FileAccess.file_exists(HEIGHT_FILE):
		push_warning("SaisiesGeography DEM package is missing")
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(METADATA_FILE))
	if not (parsed is Dictionary):
		push_warning("SaisiesGeography metadata is not a JSON object")
		return false
	metadata = parsed
	_map_size_m = float(metadata.get("size_m", 0.0))
	_height_grid = int(metadata.get("height", {}).get("grid", 0))
	var shape = metadata.get("height", {}).get("shape", [])
	if _map_size_m <= 0.0 or _height_grid < 2 or shape.size() != 2:
		push_warning("SaisiesGeography metadata has invalid DEM dimensions")
		return false
	if int(shape[0]) != _height_grid or int(shape[1]) != _height_grid:
		push_warning("SaisiesGeography DEM shape is not square")
		return false
	var bounds = metadata.get("bounds_wgs84", {})
	if not (bounds is Dictionary):
		push_warning("SaisiesGeography metadata has no WGS84 bounds")
		return false
	_west_lon = float(bounds.get("west", NAN))
	_south_lat = float(bounds.get("south", NAN))
	_east_lon = float(bounds.get("east", NAN))
	_north_lat = float(bounds.get("north", NAN))
	if not _valid_bounds():
		push_warning("SaisiesGeography metadata WGS84 bounds are invalid")
		return false
	var bytes := FileAccess.get_file_as_bytes(HEIGHT_FILE)
	_height_samples = bytes.to_float32_array()
	if _height_samples.size() != _height_grid * _height_grid:
		push_warning("SaisiesGeography height.f32 has %d values, expected %d" % [_height_samples.size(), _height_grid * _height_grid])
		return false
	for value in _height_samples:
		if not is_finite(float(value)):
			push_warning("SaisiesGeography height.f32 contains a non-finite value")
			return false
	_west_mercator_x = _mercator_x(_west_lon)
	_east_mercator_x = _mercator_x(_east_lon)
	_south_mercator_y = _mercator_y(_south_lat)
	_north_mercator_y = _mercator_y(_north_lat)
	if _east_mercator_x <= _west_mercator_x or _north_mercator_y <= _south_mercator_y:
		push_warning("SaisiesGeography projected bounds are invalid")
		return false
	_mercator_center_x = (_west_mercator_x + _east_mercator_x) * 0.5
	_mercator_center_y = (_south_mercator_y + _north_mercator_y) * 0.5
	_mercator_to_local_x = _map_size_m / (_east_mercator_x - _west_mercator_x)
	_mercator_to_local_y = _map_size_m / (_north_mercator_y - _south_mercator_y)
	_origin_mercator_x = _mercator_x(origin_lon)
	_origin_mercator_y = _mercator_y(origin_lat)
	# The local datum is defined exclusively by the coarse DEM at the frame
	# origin. Optional RGE patches are ASL overlays and must never redefine it.
	datum_m = _sample_height_asl_uv(_uv_from_mercator(_origin_mercator_x, _origin_mercator_y))
	if include_nearfield and not _load_optional_nearfield(frame):
		return false
	configured = true
	return true

func set_route_samples(points: PackedVector3Array, half_width: float) -> void:
	_route_samples = points.duplicate()
	_route_spatial_hash.clear()
	# The argument is the physical road half-width.  Keep a stable, broad
	# terrain seam around that road so a narrow route mesh cannot expose the
	# unsmoothed DEM underneath.  The seam itself remains local (8--25 m).
	_route_half_width_m = maxf(0.0, half_width)
	_route_blend_outer_m = 25.0
	_route_blend_inner_m = 8.0
	for i in range(_route_samples.size() - 1):
		var a := _route_samples[i]
		var b := _route_samples[i + 1]
		var min_x := floori(minf(a.x, b.x) / ROUTE_HASH_CELL_M) - 1
		var max_x := floori(maxf(a.x, b.x) / ROUTE_HASH_CELL_M) + 1
		var min_z := floori(minf(a.z, b.z) / ROUTE_HASH_CELL_M) - 1
		var max_z := floori(maxf(a.z, b.z) / ROUTE_HASH_CELL_M) + 1
		for cell_x in range(min_x, max_x + 1):
			for cell_z in range(min_z, max_z + 1):
				var key := Vector2i(cell_x, cell_z)
				var bucket: Array = _route_spatial_hash.get(key, [])
				bucket.append(i)
				_route_spatial_hash[key] = bucket

func world_from_latlon(lat: float, lon: float) -> Vector3:
	if not configured:
		return Vector3.ZERO
	var mercator_x := _mercator_x(lon)
	var mercator_y := _mercator_y(lat)
	var en := _en_from_mercator(mercator_x, mercator_y)
	var xz := _world_xz_from_en(en)
	return Vector3(xz.x, _sample_height_asl_world(xz) - datum_m, xz.y)

func world_from_uv(uv: Vector2) -> Vector3:
	if not configured:
		return Vector3.ZERO
	var mercator_x := lerpf(_west_mercator_x, _east_mercator_x, uv.x)
	var mercator_y := lerpf(_north_mercator_y, _south_mercator_y, uv.y)
	var en := _en_from_mercator(mercator_x, mercator_y)
	var xz := _world_xz_from_en(en)
	return Vector3(xz.x, height_world(xz), xz.y)

func latlon_from_world(xz: Vector2) -> Vector2:
	if not configured:
		return Vector2.ZERO
	var en := _en_from_world_xz(xz)
	var mercator_x := _origin_mercator_x + en.x / maxf(_mercator_to_local_x, 0.000001)
	var mercator_y := _origin_mercator_y + en.y / maxf(_mercator_to_local_y, 0.000001)
	return Vector2(_inverse_mercator_lat(mercator_y), _inverse_mercator_lon(mercator_x))

func raw_height_world(xz: Vector2) -> float:
	if not configured:
		return 0.0
	return _sample_height_asl_world(xz) - datum_m

func raw_height_world_coarse(xz: Vector2) -> float:
	## Audit-only coarse DEM sample, intentionally bypassing nearfield patches.
	if not configured:
		return 0.0
	return _sample_height_asl_uv(uv_world(xz)) - datum_m

func height_world(xz: Vector2) -> float:
	var raw := raw_height_world(xz)
	if _route_samples.size() < 2:
		return raw
	var nearest := _nearest_route(xz)
	var distance := float(nearest["distance_m"])
	if distance >= _route_blend_outer_m:
		return raw
	var blend := 1.0 - smoothstep(_route_blend_inner_m, _route_blend_outer_m, distance)
	return lerpf(raw, float(nearest["road_y"]), blend)

func uv_world(xz: Vector2) -> Vector2:
	if not configured:
		return Vector2.ZERO
	var en := _en_from_world_xz(xz)
	var mercator_x := _origin_mercator_x + en.x / maxf(_mercator_to_local_x, 0.000001)
	var mercator_y := _origin_mercator_y + en.y / maxf(_mercator_to_local_y, 0.000001)
	return _uv_from_mercator(mercator_x, mercator_y)

func raw_height_asl_world(xz: Vector2) -> float:
	if not configured:
		return 0.0
	return _sample_height_asl_world(xz)

func raw_height_asl_world_coarse(xz: Vector2) -> float:
	## Audit-only coarse ASL sample, intentionally bypassing nearfield patches.
	if not configured:
		return 0.0
	return _sample_height_asl_uv(uv_world(xz))

func nearfield_patch_count() -> int:
	return _nearfield_patches.size()

func nearfield_patch_info() -> Array:
	var result: Array = []
	for patch_variant in _nearfield_patches:
		var patch: Dictionary = patch_variant
		result.append({
			"id": patch.get("id", ""),
			"route_s_m": patch.get("route_s_m", NAN),
			"origin_world": patch.get("origin_world", Vector2.ZERO),
			"size_m": patch.get("size_m", NAN),
			"grid": patch.get("grid", 0),
			"spacing_m": patch.get("spacing_m", NAN),
			"blend_margin_m": patch.get("blend_margin_m", NAN),
			"height_file": patch.get("height_file", "")
		})
	return result

func height_grid() -> int:
	return _height_grid

func has_route_samples() -> bool:
	return _route_samples.size() >= 2

func nearest_route_world(xz: Vector2) -> Dictionary:
	if not configured or _route_samples.size() < 2:
		return {"distance_m": INF, "road_y": 0.0, "clearance_road_y": 0.0}
	return _nearest_route(xz)

func map_size_m() -> float:
	return _map_size_m

func albedo_path() -> String:
	return DATA_DIR + "/" + String(metadata.get("albedo", {}).get("file", "albedo.jpg"))

func bounds_world() -> Rect2:
	if not configured:
		return Rect2()
	var corners := [
		_world_xz_from_en(_en_from_mercator(_west_mercator_x, _north_mercator_y)),
		_world_xz_from_en(_en_from_mercator(_east_mercator_x, _north_mercator_y)),
		_world_xz_from_en(_en_from_mercator(_west_mercator_x, _south_mercator_y)),
		_world_xz_from_en(_en_from_mercator(_east_mercator_x, _south_mercator_y))
	]
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for point in corners:
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
		min_z = minf(min_z, point.y)
		max_z = maxf(max_z, point.y)
	return Rect2(Vector2(min_x, min_z), Vector2(max_x - min_x, max_z - min_z))

func _read_frame(frame: Dictionary) -> bool:
	for key in ["origin_lat", "origin_lon", "forward_east", "forward_north", "right_east", "right_north"]:
		if not frame.has(key) or not is_finite(float(frame[key])):
			push_warning("SaisiesGeography frame is missing %s" % key)
			return false
	origin_lat = float(frame["origin_lat"])
	origin_lon = float(frame["origin_lon"])
	if origin_lat < -90.0 or origin_lat > 90.0 or origin_lon < -180.0 or origin_lon > 180.0:
		push_warning("SaisiesGeography frame origin is outside WGS84")
		return false
	var forward := Vector2(float(frame["forward_east"]), float(frame["forward_north"]))
	var right := Vector2(float(frame["right_east"]), float(frame["right_north"]))
	if forward.length() < 0.5 or right.length() < 0.5:
		push_warning("SaisiesGeography frame basis is too short")
		return false
	forward = forward.normalized()
	right = right.normalized()
	if absf(forward.dot(right)) > 0.02:
		push_warning("SaisiesGeography frame basis is not orthogonal")
		return false
	forward_east = forward.x
	forward_north = forward.y
	right_east = right.x
	right_north = right.y
	return true

func _valid_bounds() -> bool:
	return is_finite(_west_lon) and is_finite(_south_lat) and is_finite(_east_lon) and is_finite(_north_lat) \
		and -180.0 < _west_lon and _west_lon < _east_lon and _east_lon <= 180.0 \
		and -90.0 < _south_lat and _south_lat < _north_lat and _north_lat < 90.0

func _load_optional_nearfield(frame: Dictionary) -> bool:
	var patch_path := OPTIONAL_NEARFIELD_FILE
	var explicit_path := false
	if frame.has("nearfield_file"):
		patch_path = _resource_path(String(frame["nearfield_file"]))
		explicit_path = true
	if patch_path.is_empty():
		return _nearfield_fail("nearfield patch path is empty") if explicit_path else true
	if not FileAccess.file_exists(patch_path):
		if explicit_path:
			return _nearfield_fail("nearfield patch file is missing: %s" % patch_path)
		return true
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(patch_path))
	if not (parsed is Dictionary):
		return _nearfield_fail("nearfield patch metadata is not a JSON object")
	if not _validate_nearfield_frame(parsed):
		return false
	if not parsed.has("patches"):
		return _nearfield_fail("nearfield patch metadata is missing patches")
	var patch_list = parsed["patches"]
	if not (patch_list is Array):
		return _nearfield_fail("nearfield patch metadata patches is not an array")
	if patch_list.is_empty():
		return _nearfield_fail("nearfield patch metadata contains no patches")
	var parsed_patches: Array = []
	var seen_ids: Dictionary = {}
	for index in range(patch_list.size()):
		var patch_variant = patch_list[index]
		if not (patch_variant is Dictionary):
			return _nearfield_fail("nearfield patch %d is not an object" % index)
		var patch: Dictionary = _parse_nearfield_patch(patch_variant, index, parsed["grid_contract"])
		if patch.is_empty():
			return false
		var patch_id := String(patch["id"])
		if seen_ids.has(patch_id):
			return _nearfield_fail("nearfield patch id is duplicated: %s" % patch_id)
		seen_ids[patch_id] = true
		for previous_variant in parsed_patches:
			var previous: Dictionary = previous_variant
			if _patches_overlap(previous, patch):
				return _nearfield_fail("nearfield patches overlap: %s and %s" % [String(previous["id"]), patch_id])
		parsed_patches.append(patch)
	_nearfield_patches = parsed_patches
	nearfield_loaded = true
	return true

func _parse_nearfield_patch(raw: Dictionary, index: int, grid_contract: Dictionary) -> Dictionary:
	for key in ["id", "center_s_m", "center_x", "center_z", "min_x", "min_z", "max_x", "max_z", "spacing_m", "grid", "row_order", "height_dtype", "height_unit", "sample_count", "height_file", "height_sha256"]:
		if not raw.has(key):
			_nearfield_fail("nearfield patch %d is missing %s" % [index, key])
			return {}
	var patch_id := String(raw["id"])
	if patch_id.is_empty():
		_nearfield_fail("nearfield patch %d has an empty id" % index)
		return {}
	var route_s := float(raw["center_s_m"])
	var center_x := float(raw["center_x"])
	var center_z := float(raw["center_z"])
	var min_x := float(raw["min_x"])
	var min_z := float(raw["min_z"])
	var max_x := float(raw["max_x"])
	var max_z := float(raw["max_z"])
	for value in [route_s, center_x, center_z, min_x, min_z, max_x, max_z]:
		if not is_finite(value):
			_nearfield_fail("nearfield patch %s contains a non-finite coordinate" % patch_id)
			return {}
	var grid := int(raw["grid"])
	var spacing := float(raw["spacing_m"])
	var contract_size := float(grid_contract["size_m"])
	var size_m := max_x - min_x
	if grid != NEARFIELD_GRID or int(grid_contract["grid"]) != NEARFIELD_GRID:
		_nearfield_fail("nearfield patch %s grid=%d, expected %d" % [patch_id, grid, NEARFIELD_GRID])
		return {}
	if not is_finite(spacing) or absf(spacing - NEARFIELD_SPACING_M) > 0.001 or absf(spacing - float(grid_contract["spacing_m"])) > 0.001:
		_nearfield_fail("nearfield patch %s spacing is invalid: %.6f" % [patch_id, spacing])
		return {}
	if not is_finite(size_m) or absf(size_m - NEARFIELD_SIZE_M) > 0.01 or absf(size_m - contract_size) > 0.01:
		_nearfield_fail("nearfield patch %s bounds size is invalid: %.6f" % [patch_id, size_m])
		return {}
	if absf(max_z - min_z - size_m) > 0.01 or absf(size_m - spacing * float(grid - 1)) > 0.01:
		_nearfield_fail("nearfield patch %s size/grid/spacing are inconsistent" % patch_id)
		return {}
	if absf(center_x - (min_x + max_x) * 0.5) > 0.01 or absf(center_z - (min_z + max_z) * 0.5) > 0.01:
		_nearfield_fail("nearfield patch %s center does not match bounds" % patch_id)
		return {}
	if String(raw["row_order"]) != String(grid_contract["row_order"]):
		_nearfield_fail("nearfield patch %s row order is incompatible" % patch_id)
		return {}
	if String(raw["height_dtype"]) != String(grid_contract["height_dtype"]):
		_nearfield_fail("nearfield patch %s height dtype is incompatible" % patch_id)
		return {}
	var declared_units := String(raw["height_unit"]).to_upper()
	if not declared_units.contains("ASL") or declared_units != String(grid_contract["height_unit"]).to_upper():
		_nearfield_fail("nearfield patch %s height file is not declared ASL" % patch_id)
		return {}
	var expected_samples := NEARFIELD_GRID * NEARFIELD_GRID
	if int(raw["sample_count"]) != expected_samples:
		_nearfield_fail("nearfield patch %s sample_count is invalid" % patch_id)
		return {}
	var blend_margin := NEARFIELD_BLEND_MARGIN_M
	if raw.has("blend_margin_m"):
		blend_margin = float(raw["blend_margin_m"])
	if not is_finite(blend_margin) or blend_margin <= 0.0 or blend_margin >= size_m * 0.5:
		_nearfield_fail("nearfield patch %s blend margin is invalid: %.6f" % [patch_id, blend_margin])
		return {}
	var height_file := String(raw["height_file"])
	if not height_file.begins_with("res://") or not FileAccess.file_exists(height_file):
		_nearfield_fail("nearfield patch %s height file is missing or not res://: %s" % [patch_id, height_file])
		return {}
	var declared_sha := String(raw["height_sha256"]).to_lower()
	if declared_sha.length() != 64 or not _is_hex_digest(declared_sha):
		_nearfield_fail("nearfield patch %s has an invalid height_sha256" % patch_id)
		return {}
	var bytes := FileAccess.get_file_as_bytes(height_file)
	var expected_bytes := expected_samples * 4
	if bytes.size() != expected_bytes:
		_nearfield_fail("nearfield patch %s has %d bytes, expected %d" % [patch_id, bytes.size(), expected_bytes])
		return {}
	if _sha256(bytes) != declared_sha:
		_nearfield_fail("nearfield patch %s height_sha256 does not match file" % patch_id)
		return {}
	var heights := bytes.to_float32_array()
	if heights.size() != expected_samples:
		_nearfield_fail("nearfield patch %s has %d height values, expected %d" % [patch_id, heights.size(), expected_samples])
		return {}
	for value in heights:
		var height := float(value)
		if not is_finite(height) or height < -1000.0 or height > 10000.0:
			_nearfield_fail("nearfield patch %s contains an invalid/no-data height" % patch_id)
			return {}
	return {
		"id": patch_id,
		"route_s_m": route_s,
		"origin_world": Vector2(min_x, min_z),
		"size_m": size_m,
		"grid": grid,
		"spacing_m": spacing,
		"blend_margin_m": blend_margin,
		"height_file": height_file,
		"height_sha256": declared_sha,
		"heights": heights
	}

func _validate_nearfield_frame(document: Dictionary) -> bool:
	if not document.has("schema_version") or int(document["schema_version"]) != 1:
		return _nearfield_fail("nearfield schema_version must be 1")
	if not document.has("datum_m") or not is_finite(float(document["datum_m"])):
		return _nearfield_fail("nearfield metadata is missing finite datum_m")
	var declared_datum := float(document["datum_m"])
	if absf(declared_datum - datum_m) > 0.001:
		return _nearfield_fail("nearfield datum %.6f differs from coarse datum %.6f" % [declared_datum, datum_m])
	if not document.has("grid_contract") or not (document["grid_contract"] is Dictionary):
		return _nearfield_fail("nearfield metadata is missing grid_contract")
	var grid_contract: Dictionary = document["grid_contract"]
	for key in ["grid", "spacing_m", "size_m", "height_dtype", "height_unit", "row_order"]:
		if not grid_contract.has(key):
			return _nearfield_fail("nearfield grid_contract is missing %s" % key)
	if int(grid_contract["grid"]) != NEARFIELD_GRID or absf(float(grid_contract["spacing_m"]) - NEARFIELD_SPACING_M) > 0.001 or absf(float(grid_contract["size_m"]) - NEARFIELD_SIZE_M) > 0.01:
		return _nearfield_fail("nearfield grid_contract dimensions are invalid")
	if String(grid_contract["height_dtype"]) != "<f4" or not String(grid_contract["height_unit"]).to_upper().contains("ASL") or String(grid_contract["row_order"]) != "z increasing rows; x increasing columns":
		return _nearfield_fail("nearfield grid_contract encoding is invalid")
	var declared_frame = document.get("geography_frame", {})
	if not (declared_frame is Dictionary):
		return _nearfield_fail("nearfield geography_frame is not an object")
	for key in ["origin_lat", "origin_lon", "forward_east", "forward_north", "right_east", "right_north", "datum_m"]:
		if not declared_frame.has(key) or not is_finite(float(declared_frame[key])):
			return _nearfield_fail("nearfield geography_frame is missing %s" % key)
		var expected := declared_datum if key == "datum_m" else float(get(key))
		if absf(float(declared_frame[key]) - expected) > 0.000001:
			return _nearfield_fail("nearfield geography_frame %s differs from runtime frame" % key)
	return true

func _is_hex_digest(value: String) -> bool:
	for character in value:
		if not (character in "0123456789abcdef"):
			return false
	return true

func _sha256(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	return hashing.finish().hex_encode()

func _patches_overlap(a: Dictionary, b: Dictionary) -> bool:
	var a_origin: Vector2 = a["origin_world"]
	var b_origin: Vector2 = b["origin_world"]
	var a_size := float(a["size_m"])
	var b_size := float(b["size_m"])
	return a_origin.x < b_origin.x + b_size and b_origin.x < a_origin.x + a_size \
		and a_origin.y < b_origin.y + b_size and b_origin.y < a_origin.y + a_size

func _resource_path(path: String) -> String:
	if path.is_empty():
		return ""
	if path.begins_with("res://"):
		return path
	if path.begins_with("/" ):
		return path
	return "res://" + path.trim_prefix("./")

func _nearfield_fail(message: String) -> bool:
	nearfield_error = message
	_nearfield_patches.clear()
	push_error("SaisiesGeography nearfield: " + message)
	return false

func _nearest_route(xz: Vector2) -> Dictionary:
	var best_distance_sq := INF
	var best_road_y := 0.0
	var clearance_road_y := INF
	if _route_samples.size() < 2:
		return {"distance_m": INF, "road_y": 0.0, "clearance_road_y": 0.0}
	var cell_x := floori(xz.x / ROUTE_HASH_CELL_M)
	var cell_z := floori(xz.y / ROUTE_HASH_CELL_M)
	var candidates: Dictionary = {}
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var bucket: Array = _route_spatial_hash.get(Vector2i(cell_x + dx, cell_z + dz), [])
			for raw_index in bucket:
				candidates[int(raw_index)] = true
	if candidates.is_empty():
		return {"distance_m": INF, "road_y": 0.0, "clearance_road_y": 0.0}
	for raw_index in candidates.keys():
		var i := int(raw_index)
		var a := _route_samples[i]
		var b := _route_samples[i + 1]
		var a_xz := Vector2(a.x, a.z)
		var b_xz := Vector2(b.x, b.z)
		var ab := b_xz - a_xz
		var t := clampf((xz - a_xz).dot(ab) / maxf(ab.length_squared(), 0.000001), 0.0, 1.0)
		var nearest := a_xz.lerp(b_xz, t)
		var distance_sq := xz.distance_squared_to(nearest)
		var segment_road_y := lerpf(a.y, b.y, t)
		if distance_sq <= _route_blend_inner_m * _route_blend_inner_m:
			clearance_road_y = minf(clearance_road_y, segment_road_y)
		if distance_sq < best_distance_sq:
			best_distance_sq = distance_sq
			best_road_y = segment_road_y
	if not is_finite(clearance_road_y):
		clearance_road_y = best_road_y
	return {"distance_m": sqrt(best_distance_sq), "road_y": best_road_y, "clearance_road_y": clearance_road_y}

func _sample_height_asl_uv(uv: Vector2) -> float:
	if _height_samples.is_empty():
		return 0.0
	var u := clampf(uv.x, 0.0, 1.0)
	var v := clampf(uv.y, 0.0, 1.0)
	var px := u * float(_height_grid - 1)
	var py := v * float(_height_grid - 1)
	var x0 := clampi(int(floor(px)), 0, _height_grid - 1)
	var y0 := clampi(int(floor(py)), 0, _height_grid - 1)
	var x1 := mini(x0 + 1, _height_grid - 1)
	var y1 := mini(y0 + 1, _height_grid - 1)
	var tx := px - float(x0)
	var ty := py - float(y0)
	var north_left := lerpf(_height_samples[y0 * _height_grid + x0], _height_samples[y0 * _height_grid + x1], tx)
	var south_left := lerpf(_height_samples[y1 * _height_grid + x0], _height_samples[y1 * _height_grid + x1], tx)
	return lerpf(north_left, south_left, ty)

func _sample_height_asl_world(xz: Vector2) -> float:
	var coarse := _sample_height_asl_uv(uv_world(xz))
	for patch_variant in _nearfield_patches:
		var patch: Dictionary = patch_variant
		if not _patch_contains(patch, xz):
			continue
		var patch_height := _sample_patch_asl(patch, xz)
		var blend := _patch_blend_weight(patch, xz)
		return lerpf(coarse, patch_height, blend)
	return coarse

func _patch_contains(patch: Dictionary, xz: Vector2) -> bool:
	var origin: Vector2 = patch["origin_world"]
	var size_m := float(patch["size_m"])
	return xz.x >= origin.x and xz.x <= origin.x + size_m and xz.y >= origin.y and xz.y <= origin.y + size_m

func _patch_blend_weight(patch: Dictionary, xz: Vector2) -> float:
	var origin: Vector2 = patch["origin_world"]
	var size_m := float(patch["size_m"])
	var margin := float(patch["blend_margin_m"])
	var edge_distance := minf(minf(xz.x - origin.x, origin.x + size_m - xz.x), minf(xz.y - origin.y, origin.y + size_m - xz.y))
	return smoothstep(0.0, margin, clampf(edge_distance, 0.0, margin))

func _sample_patch_asl(patch: Dictionary, xz: Vector2) -> float:
	var origin: Vector2 = patch["origin_world"]
	var spacing := float(patch["spacing_m"])
	var grid := int(patch["grid"])
	var heights: PackedFloat32Array = patch["heights"]
	var px := clampf((xz.x - origin.x) / spacing, 0.0, float(grid - 1))
	var pz := clampf((xz.y - origin.y) / spacing, 0.0, float(grid - 1))
	var x0 := clampi(int(floor(px)), 0, grid - 1)
	var z0 := clampi(int(floor(pz)), 0, grid - 1)
	var x1 := mini(x0 + 1, grid - 1)
	var z1 := mini(z0 + 1, grid - 1)
	var tx := px - float(x0)
	var tz := pz - float(z0)
	var north_left := lerpf(heights[z0 * grid + x0], heights[z0 * grid + x1], tx)
	var south_left := lerpf(heights[z1 * grid + x0], heights[z1 * grid + x1], tx)
	return lerpf(north_left, south_left, tz)

func _uv_from_mercator(mercator_x: float, mercator_y: float) -> Vector2:
	return Vector2(
		(mercator_x - _west_mercator_x) / maxf(_east_mercator_x - _west_mercator_x, 0.000001),
		(_north_mercator_y - mercator_y) / maxf(_north_mercator_y - _south_mercator_y, 0.000001)
	)

func _en_from_mercator(mercator_x: float, mercator_y: float) -> Vector2:
	return Vector2(
		(mercator_x - _origin_mercator_x) * _mercator_to_local_x,
		(mercator_y - _origin_mercator_y) * _mercator_to_local_y
	)

func _world_xz_from_en(en: Vector2) -> Vector2:
	return Vector2(
		en.x * right_east + en.y * right_north,
		-(en.x * forward_east + en.y * forward_north)
	)

func _en_from_world_xz(xz: Vector2) -> Vector2:
	return Vector2(
		xz.x * right_east - xz.y * forward_east,
		xz.x * right_north - xz.y * forward_north
	)

func _mercator_x(lon: float) -> float:
	return EARTH_RADIUS_M * deg_to_rad(lon)

func _mercator_y(lat: float) -> float:
	var clamped_lat := clampf(lat, -WEB_MERCATOR_MAX_LAT, WEB_MERCATOR_MAX_LAT)
	return EARTH_RADIUS_M * log(tan(PI * 0.25 + deg_to_rad(clamped_lat) * 0.5))

func _inverse_mercator_lon(mercator_x: float) -> float:
	return rad_to_deg(mercator_x / EARTH_RADIUS_M)

func _inverse_mercator_lat(mercator_y: float) -> float:
	return rad_to_deg(atan(sinh(mercator_y / EARTH_RADIUS_M)))
