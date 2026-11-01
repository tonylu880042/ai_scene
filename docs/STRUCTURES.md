# Near-route Buildings and Landmarks stage (P4)

Visual and spatial identity near the playable route: buildings, landmarks and route furniture as engine-neutral
objects (route-relative placement + world transform + prototype), never Godot nodes or Unity prefabs.

| Piece | File |
|---|---|
| Stage (build + validate, Python stdlib) | [`tools/structures.py`](../tools/structures.py) |
| Tests | `StructuresTest` in [`tools/test_scene_package.py`](../tools/test_scene_package.py) |

```bash
python3 tools/structures.py build export/packages/weissensee_rolling_hills --sections=data/weissensee_sections.json
```

```bash
python3 tools/structures.py validate export/packages/weissensee_rolling_hills
```

For a localized addition to an already validated package, `append-hints` retains the existing P4 object records and
prototype catalog, then rebuilds the per-tile P4 indexes with the added point hints:

```bash
python3 tools/structures.py append-hints export/packages/<candidate> --hints=data/<local-hints>.json
python3 tools/build_package_assets.py export/packages/<candidate> --only=<new-prototype-id>
python3 tools/structures.py validate export/packages/<candidate>
```

`--only` writes just the named structure mesh and updates that prototype's asset reference; it does not rebuild other
prototype meshes or vegetation. It is intended for one new procedural structure prototype after a focused P4 append.

OSM buildings (`python3 tools/osm_context.py buildings <package> <osm.json> [skyline.json]`): footprints within
200 m of the route are extruded into `tiles/NN/buildings.glb` (materials `facade_osm`, `roof_osm`, `roof_tile_osm`;
UV in metres, COLOR_0 tint). Height: OSM `height`, else `building:levels` × 3.1 m, else the median of measured OSM
neighbours within 120 m (only for plain footprints >= 150 m², capped at 6 levels), else a per-class estimate. Small
houses (<= 2 levels, < 400 m²) get an estimated pyramid hip roof. Base = lowest P1 terrain under the footprint − 0.3 m;
footprints whose P1 surface is all below water level are dropped (P1 outranks P4; the list is kept as shoreline
evidence), as are footprints within 1 m of the P0 road. Low, video-estimated `coastal_apartment_*` objects with an OSM
footprint within 60 m are removed as superseded, and P3 instances inside footprints are removed. With a skyline file
(`fetch-skyline`), measured towers >= 25 m at 200–1500 m go to `environment/skyline_buildings.glb` (P5). Stats and
provenance: `manifest.layers.P4_structures.osm_buildings`, `manifest.layers.P5_distant.skyline_buildings`.

## 1. Order and inputs

route → road/terrain → semantics → vegetation → **structures**. `build` refuses to run unless all earlier
layers exist and validate. Objects come from:

| Source | Objects |
|---|---|
| route.json `start`, `finish` | `race_landmark` gates (high), spanning the road at the exact `s` |
| route.json `checkpoints` | `sign` (medium) on the dry side, 0.8 m beyond the edge |
| semantics `fence` / `guardrail` / `wall` zones | linear `fence` / `guardrail` / `retaining_wall` (medium), consecutive pieces merged |
| semantics `bridge` / `tunnel` zones | `bridge` (deck over its zone, at least the road width) / two `tunnel_portal`s (high) |
| semantics `building_zone` | generic `house` / `hut` (low) from reusable prototypes, spaced along the zone |
| landmark hints | anything else: named landmarks (high), furniture (medium / low) |

**Hints** are the engine-neutral input from video / AI analysis (`--hints=file.json`, a list):

```json
{"semantic_type": "church", "importance": "high", "name": "St. Test chapel", "s": 750, "side": "right",
 "edge_offset_m": 10, "dimensions_m": [12, 15, 20], "confidence": 0.8, "source": {"kind": "video", "ref": "t=1:00"}}
```

`edge_offset_m` = gap between the road edge and the object; or give `lateral_offset_m` directly. `--sections=` derives
hints from a scene sections file: landmarks `bench` / `picnic` (medium), the section named `inn` (high, named from
its note), `parking` (lodge, medium), `lamps` spacing (low lamps on the inland edge). Lake side = the side of the
semantics' water zones.

## 2. Importance

| Level | Meaning | Placement rule | Prototype |
|---|---|---|---|
| `high` | recognisable spatial identity: named landmarks, race gates, bridges, tunnel portals | exactly at its anchor (`anchor` recorded, validator allows ≤ 1 m); if the spot is not allowed it is **kept and reported**, never moved or dropped | unique (`landmark_<name>`, `unique: true`) or route-defined |
| `medium` | notable furniture and edges: benches, signs, fences, guardrails, lodges | may slide ≤ 15 m along the route to find a free spot, else skipped (listed in `skipped_hints`) | reusable |
| `low` | generic fill: houses, barns, lamps | placed only where it fits, else skipped | reusable, size varied by scale |

Runtimes may thin, LOD or swap low-importance objects freely; high-importance ones keep their position, size and
prototype.

## 3. Output

```
structures/structures.json      every object (canonical record) + skipped hints
structures/prototypes.json      prototype definitions
tiles/NN/structures.json        per tile: point / spanning objects grouped by prototype (instancing), linear polylines
structures/validation.json      last validation report
manifest.json                   layers.P4_structures; tiles[].files.structures; tiles[].structures = count per type
```

### Object

```json
{"object_id": "st0019", "semantic_type": "commercial_building", "importance": "high", "name": "Ronacherfels inn",
 "placement": "point", "s": 3959.89, "lateral_offset_m": -13.5, "side": "right",
 "transform": {"position": [3769.422, 110.987, 222.854], "rotation": [0.0, 0.974839, 0.0, 0.22291], "scale": [1.0, 1.0, 1.0]},
 "dimensions_m": {"width": 22.0, "height": 12.0, "depth": 12.0}, "foundation_drop_m": 1.849,
 "prototype": "landmark_ronacherfels_inn", "confidence": 0.7, "on_road": false,
 "source": {"kind": "scene_generator", "ref": "data/weissensee_sections.json S64 inn", "estimated": true, "note": "49:32 Ronacherfels inn, car park"},
 "anchor": {"s": 3959.89, "lateral_offset_m": -13.5},
 "footprints_route": [[3948.89, 3970.89, -19.5, -7.5]]}
```

| Field | Meaning |
|---|---|
| `placement` | `point` (one footprint, faces the road), `spanning` (over the road: gates, bridges, portals; `on_road: true`), `linear` (barrier along a polyline) |
| `s`, `lateral_offset_m`, `side` | route-relative anchor (linear: start; plus `from_s`, `to_s`) |
| `transform` | world position (base on the lowest terrain corner; on-road objects at road height), rotation quaternion, scale. Local frame: +Y up, **+Z front**, +X right. Point objects face the road; gates and portals face the oncoming runner |
| `dimensions_m` | approximate size: `width` (along the road for point objects), `height`, `depth`; linear: `length`, `height`, `thickness`, `post_spacing` |
| `footprints_route` | `[from_s, to_s, lateral_min, lateral_max]` boxes the object occupies (gate: its two legs) |
| `foundation_drop_m` | terrain height difference under the footprint (a runtime adds a plinth) |
| `polyline` (linear) | `s`, `lateral_offset_m`, world `points` every ≤ 5 m, each on the terrain |
| `attributes` | e.g. `kind`, `checkpoint`, `clear_ground_cover` (runtime hides grass under the footprint) |

### Prototypes

```json
{"id": "house_chalet", "semantic_type": "house", "placement": "point", "dimensions_m": [12.0, 9.0, 9.0], "reference_assets": ["Buildings._chalet"]}
{"id": "fence_boards", "semantic_type": "fence", "placement": "linear", "profile_m": {"height": 1.35, "thickness": 0.06, "post_spacing": 2.0}, "reference_assets": ["Boardwalk boardfence"]}
{"id": "landmark_ronacherfels_inn", "semantic_type": "commercial_building", "placement": "point", "dimensions_m": [22.0, 12.0, 12.0], "unique": true, "description": "Ronacherfels inn"}
```

`dimensions_m` = `[width X, height Y, depth Z]`. Types supported: house, commercial_building, station, hut, church,
bridge, tunnel_portal, retaining_wall, guardrail, fence, sign, lamp, bench, monument, race_landmark. No meshes yet:
`reference_assets` name today's Godot generators; each runtime maps prototype ids to its own assets.

The reusable `fence_timber_rail` linear prototype describes dark timber posts with two horizontal rails. The Godot
adapter maps that prototype to its preview geometry; existing `fence_rail`, `fence_boards`, and `fence_lattice`
rendering keeps its previous behavior.

### Per-tile file

```json
{"version": "0.1", "tile": "09", "from_s": 4500.0, "to_s": 5000.0, "layout": "data: px py pz qx qy qz qw sx sy sz per instance ...",
 "groups": [{"proto": "barn_timber", "semantic_type": "hut", "count": 4, "data": [4261.179, 105.245, 526.526, 0.0, 0.992699, 0.0, 0.120616, 0.96, 0.96, 0.911, "..."], "object_id": ["st0051", "..."]}],
 "linear": [{"object_id": "st0005", "proto": "fence_rail", "points": [[4360.852, 113.317, 481.828], "..."]}]}
```

Same 10-float transform layout as vegetation (instancing-ready); scale = object size / prototype size.

## 4. Validation

| Against | Check |
|---|---|
| fields | object_id, semantic_type, s, lateral_offset_m, transform, dimensions_m, prototype, confidence, source, importance present; known type / importance; prototype exists with the same type; unit quaternion |
| importance | high: named or unique prototype (bridges / portals by type), anchored, ≤ 1 m from the anchor |
| road boundaries | off-road footprints outside the band + clearance (buildings 2 m, furniture 0.3 m); not on road / trail / sidewalk zones; gate legs outside the band; bridge deck covers the band over its length |
| terrain | point objects: footprint over terrain, base on the lowest corner (5 cm), drop ≤ 4 m (buildings) / 1 m (furniture); linear polylines on the terrain (5 cm) and outside the band |
| vegetation | no tree / shrub / rock instance under a footprint (+0.2 m); buildings not inside forest zones |
| water | no footprint in water (bridges excepted) |
| tunnels / bridges | nothing but portals / bridges inside tunnel / bridge zones; bridges match a semantic bridge zone, portals a tunnel end (0.5 m) |
| each other | footprints of point / spanning objects do not overlap each other or linear barriers |
| tiles | every object listed exactly once in the per-tile files; group arrays match counts |

### Rigid foundation support policy

The default rigid-base rule is a physical 5 cm limit: the base anchor must remain within 0.05 m of the
lowest sampled ground point. A `foundation_support` attribute does not grant its own tolerance. A local
level-pad exception is accepted only for a candidate-only structure with a nonempty source kind and
reference, `source.estimated = true` (GPS/video and other provenance are allowed), and a finite
`pad_top_y_m` within 1 cm of the object base. No OSM identity field grants this exception. Its
`p1_tile` must name a terrain tile; the tile, pad height and object center must match an estimated
`manifest.p1_local_support_patches` entry with a finite polygon, nonempty provenance and method. Its
declared gap is finite, nonnegative and at most 0.05 m; penetration is finite, nonnegative and at most
0.02 m. Invalid claims are reported and use the default 5 cm base-to-minimum-ground check. A data record
cannot turn its own height or gap value into permission to float.

Prototype mesh support sampling accepts `.glb` and static `.gltf` triangle POSITION data, including external
buffers and node transforms. Unsupported or malformed mesh data produces a validation error.

## 5. Test package result

`export/packages/weissensee_rolling_hills`: 65 objects → VALID, 0 hints skipped.

| Type | high | medium | low |
|---|---|---|---|
| race_landmark (START, FINISH gates) | 2 | | |
| bridge (footbridges) | 2 | | |
| commercial_building (Ronacherfels inn; lodge) | 1 | 1 | |
| sign (km checkpoints) | | 4 | |
| bench (3 benches, 1 picnic table) | | 4 | |
| fence / guardrail | | 8 / 6 | |
| house (chalets) / hut (barns) | | | 13 / 12 |
| lamp (village) | | | 12 |

Worst anchor offset 0 m, ground error 0.5 mm, position error 1 mm. The first build was INVALID and the validator
was right: the START and FINISH gate legs stood on the board fences beside the path, and the last footbridge was
narrower than the widening path; the gates now set their legs outside any barrier and bridges span the road
over their whole length (semantics producer fixed too).

## 6. Not in 0.1

Meshes for prototypes (planned `assets/prototypes.glb`), building footprints rotated off the road direction,
jetties and viewing decks (structures in water), distant scenery (P5).


Shared placement also probes each point object's route-relative footprint at <= 1 m spacing against the physical
road corridors of other traversals. The category clearance still applies. This complements semantic exclusions
and actual indexed terrain lookup; it prevents a building under / across another leg of the route from passing
merely because it lies outside its authoring leg's road band. High-importance anchors are never silently moved.
