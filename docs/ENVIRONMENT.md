# Distant Environment (P5) and Atmosphere (P6) — `environment/environment.json`

The last stage. It describes what lies beyond the near route (distant terrain, mountains, large water, skyline)
and the atmosphere (HDR sky, sun, ambient, fog, clouds, weather, time of day) as **data**. How a runtime renders
it — HDRP / URP volumes and sky, Godot shaders — is not stored: no shader code, shader parameters or engine
settings are canonical scene data.

| Piece | File |
|---|---|
| Stage (build + validate, Python stdlib) | [`tools/environment.py`](../tools/environment.py) |
| Scene facts from a Godot scene | [`tools/export_environment_hints.gd`](../tools/export_environment_hints.gd) |
| Tests | `EnvironmentTest` in [`tools/test_scene_package.py`](../tools/test_scene_package.py) |

```bash
godot --headless --path . --script tools/export_environment_hints.gd -- --scene=res://scenes/MainScene_weissensee.tscn --course=rolling_hills --package=export/packages/weissensee_rolling_hills
```

```bash
python3 tools/environment.py build export/packages/weissensee_rolling_hills
```

## 1. Order and inputs

route → road/terrain → semantics → vegetation → structures → **environment**: `build` refuses to run unless every
earlier layer exists and validates. Its input is `environment/hints.json` — plain scene facts (sun vector and
energy, HDRI file and where its sun is, fog values, real-terrain placement, water planes, water level below the
road along the route). `export_environment_hints.gd` reads them from a Godot scene after `CourseSetup` has placed
the sun; a video / AI analysis can write the same file. The hints are input, not package data.

Existing capabilities kept:

| Today (Godot) | In the package |
|---|---|
| `tools/fetch_real_terrain.py` DEM + orthophoto, `real_terrain.gd` placement (rotation, height offset, anchor, sunk side) | `environment/distant_terrain.glb`: the same DEM meshed (≤ 256² vertices) and placed exactly as `real_terrain.gd` does, orthophoto embedded |
| `FollowPlayer` + `Route.backdrop_yaw` (backdrop follows the runner at the lake level, turns with the route) | `distant.anchors.follow_runner` samples (pivot height, yaw) every 25 m |
| `LakeFar` 40 km plane at the water level | `distant.water[]` plane, level offset, appearance colours |
| Poly Haven HDRI + `hdri_sun_u` / `hdri_sun_elev` | `environment/sky.hdr` + `sky.sun_in_image` (where the sun is in the photo) |
| `CourseSetup` sun rule (fixed angle left of the run direction, HDRI elevation) and time-of-day phases | `sun.azimuth_mode: relative_to_route`, `left_of_travel_deg`, `time_of_day` |
| `WorldEnvironment` fog / ambient / tonemap | `fog`, `ambient`, `grading` (as intent) |

## 2. environment.json

```json
{
 "version": "0.1", "route_id": "mainscene_weissensee_rolling_hills",
 "distant": {
  "anchors": {"follow_runner": {"s": [0.0, 25.0, 50.0, "..."], "pivot_y_offset_m": [-4.773, -4.607, -4.227, "..."], "yaw_deg": [0.0, -0.308, -0.563, "..."],
              "rule": "pivot = (runner x, route y(s) + pivot_y_offset_m(s), runner z), rotated yaw_deg(s) about +Y (counter-clockwise from above); linear in s between samples"}},
  "terrain": [{"id": "weissensee", "kind": "real_dem", "file": "environment/distant_terrain.glb", "anchor": "follow_runner",
               "frame": "pivot-local metres: x east / z south at yaw 0, y relative to the pivot",
               "grid": 206, "size_m": 16000.0, "height_range_m": [-600.0, 1180.1],
               "material": {"base_color": "orthophoto (embedded texture)", "roughness": 1.0},
               "source": {"kind": "dem", "ref": "assets/terrain/weissensee (tools/fetch_real_terrain.py)", "lat": 46.715, "lon": 13.37,
                          "placement": {"rotation_deg": 165.0, "height_offset": 525.9, "anchor": [3152.0, 1123.0], "sink_west_of": 1660.0, "sink_axis_deg": 84.7}},
               "attribution": ["dem", "s2"]}],
  "water": [{"id": "lakefar", "kind": "lake", "geometry": {"type": "plane", "size_m": [40000.0, 40000.0]}, "anchor": "follow_runner",
             "level_offset_m": -0.08, "appearance": {"deep_color_linear": [0.00232, 0.09463, 0.17887], "shallow_color_linear": [0.01341, 0.31855, 0.2957], "roughness": 0.12}}],
  "skyline": {"at_s": 0.0, "eye_height_above_pivot_m": 6.423, "columns": ["bearing_deg", "elevation_deg", "distance_m"],
              "samples": [[0.0, 19.92, 2072.0], [2.0, 20.42, 2012.0], "... every 2 deg"]}
 },
 "atmosphere": {
  "sun": {"direction_to_sun": [0.310525, 0.681998, -0.662157], "elevation_deg": 43.0, "azimuth_deg": 25.125,
          "azimuth_mode": "relative_to_route", "left_of_travel_deg": 75.0, "elevation_source": "hdri",
          "color_linear": [1.0, 0.89001, 0.74841], "intensity_relative": 1.5},
  "sky": {"type": "hdri", "file": "environment/sky.hdr", "projection": "equirectangular",
          "source": {"kind": "polyhaven", "name": "kloofendal_43d_clear_puresky_4k"},
          "sun_in_image": {"u": 0.6005, "elevation_deg": 43.0}, "align": "rotate the panorama about +Y so its sun lies at sun.azimuth_deg",
          "intensity_relative": 1.0, "attribution": ["polyhaven"]},
  "ambient": {"source": "sky", "intensity_relative": 1.4},
  "fog": {"model": "exponential", "density_per_m": 0.00035, "color_linear": [0.34239, 0.52252, 0.78741], "visibility_m": 11177,
          "aerial_perspective": 0.8, "sun_scatter": 0.15, "sky_affect": 0.05},
  "clouds": [{"kind": "sky_dome", "coverage": 0.05, "source": "HDRI"}],
  "weather": {"condition": "clear", "precipitation": "none", "visibility_m": 11177, "mist_episodes": null},
  "time_of_day": {"phase_start": 0.35, "phase_end": 0.6, "convention": "0 sunrise, 0.5 noon, 1 sunset", "approx_local_time": ["10:12", "13:12"]},
  "grading": {"tonemap_hint": "agx", "exposure_ev": 0.0, "saturation": 1.3, "contrast": 1.1, "bloom": true, "note": "look intent; runtimes may restyle"}
 },
 "attribution": [{"id": "dem", "text": "Terrain elevation: AWS Terrain Tiles ..."}, {"id": "s2", "text": "Orthophoto: Sentinel-2 cloudless ... CC BY 4.0"},
                 {"id": "polyhaven", "text": "HDRI: Poly Haven (https://polyhaven.com), CC0"}],
 "source": {"kind": "scene_generator", "ref": "res://scenes/MainScene_weissensee.tscn", "course": "rolling_hills"}
}
```

### Field notes

| Field | Meaning |
|---|---|
| `distant.anchors.follow_runner` | for synthetic routes that borrow real mountains: the distant scene moves with the runner (pivot at the water level below the road) and turns with the route direction smoothed over ±300 m (`yaw_deg`, recomputable from route.json). Georeferenced routes use `anchor: world` instead (static geometry in the package frame) |
| `terrain[].kind` | `real_dem` (DEM + orthophoto); `frame` says how the GLB's coordinates relate to the anchor |
| `water[]` | large water bodies: `plane` geometry, level relative to the anchor (follow: the pivot), appearance as colours / roughness, not a water shader |
| `skyline` | horizon elevation per bearing from the start (eye 1.65 m above the road): a compact description of the mountains, for runtimes (sky occlusion, far LOD) and for checking against the reference video |
| `sun.direction_to_sun` | unit vector in the package frame at `s = 0`; `azimuth_mode: relative_to_route` = the sun stays `left_of_travel_deg` left of the run direction (keeps a low sun in view, as the Godot scenes do); `world` = fixed |
| `intensity_relative` | sun / sky / ambient strength relative to a standard clear day (1.0); physically based runtimes map it to their units (e.g. lux) |
| `sky.sun_in_image` | where the photographed sun is in the HDRI (`u` across the panorama, elevation); each runtime rotates its sky so that sun lies at `sun.azimuth_deg` |
| `fog` | exponential extinction per metre, colour, `visibility_m = 3.912 / density`; `aerial_perspective`, `sun_scatter`, `sky_affect` are 0–1 intents |
| `clouds[]` | `sky_dome` (coverage from the HDRI), `cloud_sea` (layer below the route: `top_below_route_m`, `thickness_m`), coverage 0–1 |
| `weather` | condition (clear / partly_cloudy / overcast), precipitation, visibility, mist episodes (density base + extra) |
| `time_of_day` | course phase range (0 sunrise … 1 sunset) and an approximate local time for a 12 h day |
| colours | linear RGB (converted from the scene's sRGB) |

## 3. Validation (`python3 tools/environment.py validate <package>`)

| Group | Check |
|---|---|
| references | `route_id` matches; manifest points to environment.json; every referenced file exists (`sky.hdr` is Radiance `#?`, the terrain is a GLB with vertices, an embedded orthophoto and up-facing triangles); every attribution id used is listed |
| anchoring | follow_runner only for non-georeferenced routes; samples from 0 to `total_length_m`, increasing, equal lengths; `yaw_deg` = the route's smoothed direction from route.json (0.1°) |
| near-route clearance | the distant terrain under the runner stays ≥ 0.5 m below the road along the whole route; follow-runner water stays below the road |
| sun / sky | unit direction; elevation / azimuth match it; relative_to_route sun is `left_of_travel_deg` left of the start heading (1°); elevation = the HDRI sun when it comes from the HDRI (1°); `sun_in_image.u` in [0, 1] |
| fog / clouds / weather / time | 0 ≤ density ≤ 0.05 /m; visibility matches density (1 %); coverage in [0, 1]; 0 ≤ phase_start ≤ phase_end ≤ 1; colours finite and ≥ 0; skyline rows `[0..360, -90..90, distance]` |

## 4. Test package result

`export/packages/weissensee_rolling_hills`: distant terrain from the Weissensee DEM (16 km, 206² vertices, Sentinel-2
orthophoto, 3.9 MB GLB, imports in Godot with its texture), the 40 km far lake, the clear-sky Kloofendal HDRI
(18 MB), sun 43° at bearing 25° (75° left of the start heading), fog visibility 11.2 km → VALID. The yaw recomputed
from route.json agrees with Godot's `backdrop_yaw` to 0.12° (1 m vs 2 m sampling); the distant terrain stays 540 m
below the runner (its shore side is sunk, as in Godot, where the near band takes over). Skyline: the mountains
across the lake rise to 23° at bearings 18–28°, ~2 km away.

## 5. Not in 0.1

Procedural backdrops (`mountain_ring.gd` rings and valley floor of the winter scene), georeferenced world-anchored
distant terrain (Saisies), a real sun position from date / latitude, time-varying weather, a water mesh for near-route
lakes (they are planes following the runner).
