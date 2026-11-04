# Route Domain Model — `route.json` (version 0.1)

The canonical, engine-independent description of a playable route. It is the spatial backbone of the AI Scene
Package: road geometry, terrain, exclusion zones, buildings, player movement and race progress all reference
route distance `s`. Package context: [AI_SCENE_PACKAGE.md](AI_SCENE_PACKAGE.md).

| Piece | File |
|---|---|
| Schema (structure, JSON Schema 2020-12) | [`schemas/route.schema.json`](../schemas/route.schema.json) |
| Derivation, validation, legacy conversion (Python, stdlib only) | [`tools/route_model.py`](../tools/route_model.py) |
| Producer: Godot `Route` (Path3D) → route.json | [`tools/export_route.gd`](../tools/export_route.gd) |
| Consumer: route.json → Godot | [`scripts/route_data.gd`](../scripts/route_data.gd) (`RouteData`) |
| Tests | [`tools/test_scene_package.py`](../tools/test_scene_package.py) |

## 1. Physical facts only

The route stores what the route **is**, not what any game does with it:

| Route says | Cycling runtime may | Running runtime may | Racing runtime may |
|---|---|---|---|
| `grade_percent = 7` | gravity term, smart-trainer resistance | treadmill incline (clamped to its range), effort model | — |
| `surface_type = gravel` | rolling resistance | footing / pace model | — |
| `s`, `checkpoints`, `finish` | distance ridden | distance run | progress, splits, ranking |
| `width_left_m / width_right_m` | lateral limits | lateral limits | overtaking room, boundaries |

Device clamping, smoothing for hardware lag, difficulty scaling and safety limits belong to the runtime.

**Physical vs visual.** `elevation_m` and `grade_percent` are physical. A renderer that exaggerates height for looks
(today's Godot scenes: `grade_scale` 1.5, alpine `micro_relief`) is described in `visual` and never changes
`elevation_m`, `y` or `grade_percent`.

## 2. Route-level fields

| Field | Meaning |
|---|---|
| `route_id` | stable id (string) |
| `version` | schema version, `"0.1"` |
| `coordinate_system` | `handedness: right`, `up: +Y`, `east: +X`, `north: -Z` (glTF-compatible); `elevation_datum_m`; `elevation_reference` `msl` (real routes) or `route_local` (synthetic); `origin` `{lat, lon, altitude_m}` or `null` |
| `units` | `length: m`, `angle: deg`, `grade: percent`, `curvature: 1/m` |
| `total_length_m` | = last `s` |
| `sample_interval_m` | uniform step between samples (the last interval may be shorter) |
| `closed` | loop route (laps are a runtime concern) |
| `start`, `finish` | `{id, s, position, name?}`; `0 ≤ start.s < finish.s ≤ total_length_m` (run-in / run-out allowed) |
| `checkpoints` | `[{id, s, position, name?}]`, strictly between start and finish, increasing |
| `sections` (optional) | `[{id, from_s, to_s, type?}]` contiguous over `0 … total_length_m` (environment / review units) |
| `visual` (optional) | `{vertical_exaggeration, relief_amplitude_m, note}`: how a legacy renderer distorts height. Not physical |
| `source` (optional) | producer, scene, inputs, provenance notes |

## 3. Samples (columnar arrays, one entry per sample)

| Field | Unit | Definition |
|---|---|---|
| `s` | m | **horizontal** distance along the centreline from the first sample; `s[0] = 0`, strictly increasing, uniform step |
| `x`, `y`, `z` | m | centreline on the road surface; `y = elevation_m − elevation_datum_m` (physical, never exaggerated) |
| `elevation_m` | m | physical road-surface elevation |
| `grade_percent` | % | `100 · Δelevation / Δhorizontal distance` (+ uphill in travel direction) |
| `heading_deg` | deg | compass bearing of travel, clockwise from north (−Z), `[0, 360)` |
| `curvature` | 1/m | horizontal curvature, **+ = turning left**, radius = 1/\|curvature\| |
| `width_left_m`, `width_right_m` | m | centreline to the edge of the usable surface on each side, `(0, 100]` |
| `surface_type` | enum | `asphalt concrete cobblestone gravel dirt grass boardwalk sand snow ice unknown` |

Why horizontal `s`: it is the same in physical and in any visually exaggerated space, it is what grade is defined
over, and it matches every existing producer (Godot `Route`, Saisies, GPX tools). A runtime that needs distance
along the slope uses `ds_surface = ds · sqrt(1 + (grade_percent/100)²)` (+0.5 % at 10 %).

### Derived fields are a pure function of `s, x, z, elevation_m`

With `lo = max(i−1, 0)`, `hi = min(i+1, n−1)` (central differences, one-sided at the ends):

```
grade_percent[i] = 100 · (elevation_m[hi] − elevation_m[lo]) / (s[hi] − s[lo])
heading_deg[i]   = atan2(x[hi] − x[lo], −(z[hi] − z[lo]))   in degrees, mod 360
curvature[i]     = −radians(wrap180(heading_deg[hi] − heading_deg[lo])) / (s[hi] − s[lo])
```

So any producer can be checked by recomputing them, and integrating grade over `s` gives back the elevation gain.
Noisy sources (DEM) are filtered **in the elevation profile** before publishing (declare the filter in `source`);
grade is then the exact derivative — there is no separate grade smoothing.

Interpolation between samples: linear in `s` for every number; heading by the shortest angle; `surface_type` from
the nearer sample. Left boundary point = centre + `left · width_left_m`, right = centre − `left · width_right_m`,
with `left = (−cos h, 0, −sin h)` for heading `h`.

## 4. Validation (`tools/route_model.py validate`)

| Group | Checks |
|---|---|
| Structure | JSON Schema (`schemas/route.schema.json`); all sample arrays the same length; finite numbers |
| Distance continuity | `s[0] = 0`; strictly increasing; uniform step (last ≤ step); `total_length_m = s[-1]`; horizontal distance between consecutive points = Δs (1 cm + 0.2 %) — no centreline gaps |
| Elevation continuity | `y = elevation_m − datum` (1 mm); no step steeper than 40 % between samples |
| Derived fields | grade (0.02 pp), heading (0.02°), curvature (1e-4 1/m) equal the formulas above; \|grade\| ≤ 40 % |
| Widths | `0 < width ≤ 100` on both sides |
| Start / finish | `0 ≤ start.s < finish.s ≤ total_length_m`; checkpoints ordered strictly between them; unique ids; every marker `position` = the route at its `s` (1 cm) |
| Sections | contiguous, cover `0 … total_length_m`, non-empty |

## 5. Producers and conversion

| From | Command | Notes |
|---|---|---|
| Godot `Route` (Path3D) | `godot --headless --path . --script tools/export_route.gd -- --scene=res://scenes/MainScene_weissensee.tscn --course=rolling_hills --out=export/packages/<id>/route/route.json` | writes the primary facts, runs `route_model.py finalize`, then a round trip through `RouteData` against the live `Route` (positions/elevation within 5 mm). Elevation = `Route.elevation_at(s)` (program grade, unscaled); widths = `half_left/half_right`; surface from the section / trail texture; start/finish from the `Gates` node; a checkpoint every `--checkpoint-every-m` (1000) |
| Legacy `route.json` (`tools/export_unity.gd`) | `python3 tools/route_model.py legacy old.json new.json --route-id=<id> --exaggeration=1.5 --surface=asphalt` | legacy `y` is the rendered road: elevation = rise / exaggeration. Legacy samples stop at `floor(length)`; `water_y`/`backdrop_yaw` are not route data |
| Primary facts from any tool | `python3 tools/route_model.py finalize raw.json [out.json]` | raw needs `route_id`, `sample_interval_m`, samples `s x z elevation_m width_left_m width_right_m surface_type`; markers by `s` only |

`scripts/route.gd` is unchanged in behaviour; it only gained `elevation_at(s)` (physical elevation, tracked next to
the rendered height). `Path3D` stays: `RouteData.make_curve()` builds the same flat curve from a route.json.

## 6. Example (generated)

`export/packages/weissensee_rolling_hills/route/route.json`, from `MainScene_weissensee.tscn`, course
`rolling_hills` (5001 samples, 386 KB). Arrays are cut to three samples at s = 1500 m; lists are shortened with `"..."`:

```json
{
 "route_id": "mainscene_weissensee_rolling_hills",
 "version": "0.1",
 "coordinate_system": {"handedness": "right", "up": "+Y", "east": "+X", "north": "-Z",
                       "elevation_datum_m": 0.0, "elevation_reference": "route_local", "origin": null},
 "units": {"length": "m", "angle": "deg", "grade": "percent", "curvature": "1/m"},
 "total_length_m": 5000.0,
 "sample_interval_m": 1.0,
 "closed": false,
 "start": {"id": "start", "name": "START gate", "s": 10.0, "position": [9.8346, 0.0, 1.8108]},
 "finish": {"id": "finish", "name": "FINISH gate", "s": 4988.0, "position": [4724.7183, 113.34, 407.5638]},
 "checkpoints": [{"id": "cp01", "name": "1.0 km", "s": 1000.0, "position": [956.748, 7.4001, 283.5207]}, "..."],
 "sections": [{"id": "S01", "from_s": 0.0, "to_s": 41.2088, "type": "board_path"},
              {"id": "S02", "from_s": 41.2088, "to_s": 109.8901, "type": "plaza"}, "..."],
 "visual": {"vertical_exaggeration": 1.5, "relief_amplitude_m": 0.0,
            "note": "the Godot scene draws the road at start_height + vertical_exaggeration * (elevation_m - start_height) + relief; not physical"},
 "source": {"producer": "tools/export_route.gd (scripts/route.gd)", "scene": "res://scenes/MainScene_weissensee.tscn",
            "course": "rolling_hills", "pace_min_per_km": 6.0,
            "grade": "treadmill program incline, eased over ~20 m (data/programs.json)",
            "widths": "Route.half_left / half_right (paved edge incl. any roadside lane)"},
 "samples": {
  "s": [1500.0, 1501.0, 1502.0],
  "x": [1433.3104, 1434.2744, 1435.2384],
  "y": [26.4799, 26.4899, 26.4999],
  "z": [434.0927, 434.3586, 434.6245],
  "elevation_m": [26.4799, 26.4899, 26.4999],
  "grade_percent": [1.0, 1.0, 1.0],
  "heading_deg": [105.466, 105.42, 105.375],
  "curvature": [0.000807, 0.000789, 0.0008],
  "width_left_m": [0.6, 0.6, 0.6],
  "width_right_m": [0.6, 0.6, 0.6],
  "surface_type": ["dirt", "dirt", "dirt"]
 }
}
```

Validator output for the full file: `5000.0 m, 5001 samples, grade 0.00..5.00 %, elevation 0.0..113.3 m -> VALID`;
Godot round trip: max error 0.0005 m. The Godot scene renders the same route 1.5× taller (170 m of climb); the
physical climb is 113 m and the grade is the program's 0 / 1 / 5 %.

## 7. Not in 0.1

Corridor (shoulder) widths, road camber/banking, lanes, junction graphs, timing-gate widths. Add when a runtime needs them.

### Preview-only artistic bends

`tools/reshape_preview_route.py` can create an explicitly estimated preview route from authored lateral bend spans. It recalculates horizontal arc length, resamples at one metre, samples South Tyrol DTM at the new geographic positions, applies the declared 7 m elevation measurement filter, and derives grade from the resulting distance/elevation without grade clamping. It remaps markers and sections and records the original-to-new station mapping in `reshape_report.json`. The DTM is not a surveyed road surface, its vertical datum is unverified, and the resulting preview is not approved training data. Road/terrain generation, clearance checks and stage validation must be repeated; a valid route JSON alone is not a passed P1 gate.
