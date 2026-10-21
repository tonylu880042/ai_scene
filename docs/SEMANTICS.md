# Near-route Spatial Semantics — `semantics/semantics.json` (version 0.1)

Package layer P2. It describes **what exists around the route** in route-relative coordinates, before any final
vegetation or building is generated, so later stages place things with spatial context instead of blind scatter.
Engine-independent; no rendering.

| Piece | File |
|---|---|
| Schema | [`schemas/semantics.schema.json`](../schemas/semantics.schema.json) |
| Validation + queries (Python, stdlib) | [`tools/semantics.py`](../tools/semantics.py) |
| Producer from a sections-file scene (Python, stdlib) | [`tools/build_semantics.py`](../tools/build_semantics.py) |
| Same, Godot adapter (reference / fallback) | [`tools/export_semantics.gd`](../tools/export_semantics.gd) |
| Tests | `SemanticsTest`, `BuildSemanticsTest` in [`tools/test_scene_package.py`](../tools/test_scene_package.py) |

## 1. Coordinates

Everything is relative to the canonical route ([ROUTE_SCHEMA.md](ROUTE_SCHEMA.md)):

| Field | Meaning |
|---|---|
| `from_s`, `to_s` | longitudinal range in route distance `s` (m) |
| `lateral_offset_m` | `[min, max]`, signed horizontal distance from the **centreline**, + left / − right of travel |
| `vertical_offset_m` | `[min, max]` height relative to the road surface at the same `s` (m), or `null` if unknown |
| `side` | `left` (offsets ≥ 0), `right` (offsets ≤ 0), `both` (route surfaces spanning the centreline only) |

A zone is the box `[from_s, to_s] × lateral_offset_m` on one side. A feature whose distance to the route changes
along `s` is several consecutive zones (the producer cuts sections into pieces ≤ 100 m).
Distance beyond the road edge = `|near offset| − width_*_m(s)` from route.json; `describe()` reports both.
`extent_m` (default 150) bounds the near-route region; farther land is P5 (distant environment).

## 2. Zone

```json
{
 "id": "z0163",
 "semantic_type": "forest",
 "side": "right",
 "from_s": 836.81, "to_s": 923.26,
 "lateral_offset_m": [-60.0, -1.3],
 "vertical_offset_m": [0.2, 35.8],
 "confidence": 0.7,
 "attributes": {"density": "dense", "stems_per_ha": 234.0, "floor": "leaf_litter", "autumn_share": 0.76,
                "species": {"beech": 0.75, "spruce": 0.15, "larch": 0.05}},
 "source": {"kind": "scene_generator", "ref": "data/weissensee_sections.json S16 beech_trail", "estimated": true,
            "note": "10:02 beech forest, leaf-covered trail, slope up right, lake through the trunks"}
}
```

| Field | Rule |
|---|---|
| `semantic_type` | one of the 16 types below |
| `confidence` | 0–1: how sure the producer is that the zone exists with these bounds |
| `source.kind` | `video`, `ai`, `map`, `dem`, `gps`, `scene_generator`, `procedural`, `manual`; `ref`, `estimated`, `note` optional |
| `attributes` | type-specific, free-form; recommended keys below. Consumers ignore keys they do not know |

## 3. Semantic types

| Group | Types | Recommended attributes | Rules |
|---|---|---|---|
| Route surface | `road`, `trail`, `sidewalk`, `bridge`, `tunnel` | `section`, `surface_texture`, `kind` | the only types allowed inside the playable band; the route must be covered by one spanning the centreline at every `s` |
| Ground cover | `grass`, `water`, `open_space` (+ `road`, `trail`, `sidewalk`) | water `kind` (lake/river/sea), `edge_m`; grass `cover` | at most one ground cover per spot (no overlaps among these six) |
| Vegetation | `forest`, `vegetation_zone` | forest `density` (dense/medium/sparse), `stems_per_ha`, `species` shares, `floor`; vegetation_zone `kind` (shrubs, reeds, scattered_trees, …), `per_100m` | `forest` never on water or a road/trail/sidewalk; may overlap vegetation zones (understorey) and landform |
| Buildings | `building_zone` | `kind` (chalets, barns, village, …) | never on water, forest or a road/trail/sidewalk; may overlap grass / scattered trees |
| Landform | `slope`, `cliff` | slope `direction` (up/down), `rise_per_m` / `drop_m`; cliff `height_m` | may overlap any cover |
| Barriers | `wall`, `guardrail`, `fence` | `kind` (style) | thin strips just outside the band |

## 4. Validation (`python3 tools/semantics.py validate <package>`)

| Check | Tolerance |
|---|---|
| JSON Schema; `route_id` = route.json; unique ids | exact |
| `0 ≤ from_s < to_s ≤ total_length_m`; `min < max`; offsets within `extent_m`; confidence ≤ 1; vertical `[min, max]` | exact |
| `side` agrees with the sign of the offsets; `both` only for route surfaces spanning the centreline | 1 cm |
| no non-surface zone inside the playable band `[−width_right_m(s), width_left_m(s)]` at any route sample in its range | 1 cm |
| the route surface is described over the whole route (road/trail/sidewalk/bridge/tunnel containing offset 0) | 1 cm |
| one ground cover per spot; forest / building_zone conflicts (table above) | overlap > 1 cm in both s and lateral |

## 5. How later stages consume it

Vegetation (P3) and building (P4) generators must not choose positions on their own. For each chunk they ask:

```python
import semantics as sm
for z in sm.zones_in(sem, s0, s1, {"forest", "vegetation_zone"}):   # where may I plant in [s0, s1]?
    # sample s in [max(s0, z.from_s), min(s1, z.to_s)], u in z.lateral_offset_m,
    # density / species from z.attributes; position = route centre(s) + left(s) * u  (route.json)
sm.zones_at(sem, s, side="left")                                   # what is next to the route here?
```

Placement inside a zone is guaranteed outside the playable band and off water / roads (validator rules), so a
generator that only samples inside its zones cannot put a tree on the trail or a house in the lake. The planned
P3/P4 validators will check every instance against the zone it was drawn from.

`describe()` turns the layer into plain statements (`python3 tools/semantics.py describe <package> <s> …`):

```
At s=1250 m, dense forest begins 4.0-60.0 m right of the centreline (1.0 m beyond the trail edge; confidence 0.80).
At s=1400 m, chalets building zone runs 12.0-25.0 m left of the centreline (9.0 m beyond the trail edge; ...).
At s=1520 m, lake water begins 5.0-150.0 m left of the centreline (2.0 m beyond the trail edge; ...).
```

(the three statements from the brief, as zones in `SemanticsTest`).

## 6. Example from an existing route

`export/packages/weissensee_rolling_hills/semantics/semantics.json` (not in git), from `MainScene_weissensee.tscn`,
course `rolling_hills`, on the route.json of [ROUTE_SCHEMA §6](ROUTE_SCHEMA.md):

```bash
python3 tools/build_semantics.py data/weissensee_sections.json export/packages/weissensee_rolling_hills --sea-y=-12 --inland-slope=1 --bank-ratio=0.45 --bank-run=3 --cliff-lip=0.4 --max-dist=38 --trees-per-chunk=70 --buildings
# or, with Godot:
godot --headless --path . --script tools/export_semantics.gd -- --scene=res://scenes/MainScene_weissensee.tscn --course=rolling_hills --package=export/packages/weissensee_rolling_hills
```

Result: 804 zones — trail 82, sidewalk 4, road 4, bridge 2, water 90, grass 114, open_space 2, forest 127,
vegetation_zone 169, building_zone 12, slope 171, cliff 2, fence 19, guardrail 6 → VALID.

How the producer reads the scene (the generators' own rules, per section piece ≤ 100 m):

| Zone | From |
|---|---|
| trail / sidewalk / road | section `surface` texture (asphalt → road, concrete → sidewalk, else trail), band = max route widths in the piece; roadside car lane → extra `road` zone |
| water | `Route.water_edge_u` (nearest edge in the piece) to `extent_m`; vertical = water level − road |
| grass / open_space | section `grass` ≥ 0.25 between band and water / inland; `plaza`, `parking` sections → open_space 25 m inland |
| forest / vegetation_zone | FoliageSpawner `forest_mix`: inland band to `depth`, wooded lake bank, `lake_band` strip, `hazel` shrubs 2–9 m, `reeds` around the water line; trees < 0.3 → scattered_trees |
| slope / cliff | section `slope` × `inland_slope` (up, inland), drop to the water (down), `cliff` / `cliff_from` |
| fence / guardrail / wall | Boardwalk edge styles (`lake` / `inland`), 5 cm outside the path edge |
| building_zone | Buildings.gd chalet rules: `houses` 10–30 m inland, `barns` 15–60 m |
| bridge | landmark `footbridge` (10 m deck) |

Zones S16 (beech trail) and S30 (rock wall) as written:

```json
{"id": "z0165", "semantic_type": "trail", "side": "both", "from_s": 836.81, "to_s": 923.26, "lateral_offset_m": [-0.7, 0.7], "vertical_offset_m": [0.0, 0.0], "confidence": 0.9, "attributes": {"section": "beech_trail", "surface_texture": "brown_mud_leaves_01"}, "source": {"kind": "scene_generator", "ref": "data/weissensee_sections.json S16 beech_trail", "estimated": true}}
{"id": "z0162", "semantic_type": "slope", "side": "right", "from_s": 836.81, "to_s": 923.26, "lateral_offset_m": [-150.0, -0.7], "vertical_offset_m": [-0.1, 48.5], "confidence": 0.8, "attributes": {"direction": "up", "rise_per_m": 0.66}, "source": {"kind": "scene_generator", "ref": "data/weissensee_sections.json S16 beech_trail", "estimated": true}}
{"id": "z0169", "semantic_type": "water", "side": "left", "from_s": 836.81, "to_s": 923.26, "lateral_offset_m": [13.43, 150.0], "vertical_offset_m": [-15.0, -8.4], "confidence": 0.9, "attributes": {"kind": "lake", "edge_m": [13.4, 28.1]}, "source": {"kind": "scene_generator", "ref": "data/weissensee_sections.json S16 beech_trail", "estimated": true}}
{"id": "z0319", "semantic_type": "cliff", "side": "right", "from_s": 1883.52, "to_s": 1920.33, "lateral_offset_m": [-16.1, -2.1], "vertical_offset_m": [0.0, 26.0], "confidence": 0.8, "attributes": {"height_m": 26.0}, "source": {"kind": "scene_generator", "ref": "data/weissensee_sections.json S30 rock_wall", "estimated": true, "note": "23:12 grey limestone wall beside the trail"}}
```

**Python vs Godot.** `build_semantics.py` reproduces route.gd's cross-section from the sections file + route.json
(flags = the scene's exports) and gives the adapter's 804 zones with the same ids, s ranges, attributes and lateral
offsets (0 cm at the 1 cm snap, `BuildSemanticsTest`). The one Godot-only input to the offsets is `water_edge_u`:
route.gd's lake-bank columns bend by FastNoiseLite "knobs" on wide-bank sections (up to 1.7 m of lake edge here);
the tool ports that noise (OpenSimplex2S FBm, Godot defaults, seed 5; matches `get_noise_2d` to 1e-6).
`vertical_offset_m` is exact on the lake side, water, route surfaces, cliffs and bridges; for inland ground zones
(grass, slope, forest, building, shrubs right of a north-shore route) it uses the inland slope rule + mean cliff face
without the noise hills and the real DEM (`real_shore`, not in git), so it differs by ~1 m (buildings) to ~30 m (median)
(150 m-wide slope / grass zones). No later stage reads it yet.

**Caveat:** this producer describes the Godot scene as built (`source.kind: scene_generator`), not the video. Where
the scene differs from the video, so do the semantics (S14 "lake 1–3 m left" in the video: the scene's lake edge is
7.8 m out). A video/AI producer would write the same format with `source.kind: video` / `ai` and its own confidence.

## 7. Not in 0.1

Zones whose offsets vary continuously along `s` (use consecutive zones), polygon footprints, vertical layering
(overpasses), junction/side-road topology.
