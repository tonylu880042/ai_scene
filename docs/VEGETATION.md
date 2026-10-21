# Vegetation Distribution stage (P3)

Semantic distribution first, instances second. Engine-independent: no MultiMesh, no GameObjects — zones,
prototype definitions and per-tile instance lists that any runtime can draw (Unity: GPU instancing + LOD per
prototype; Godot: MultiMesh or anything else).

| Piece | File |
|---|---|
| Stage (build + validate, Python stdlib) | [`tools/vegetation.py`](../tools/vegetation.py) |
| Tests | `VegetationTest` in [`tools/test_scene_package.py`](../tools/test_scene_package.py) |

```bash
python3 tools/vegetation.py build export/packages/weissensee_rolling_hills
```

```bash
python3 tools/vegetation.py validate export/packages/weissensee_rolling_hills
```

## 1. Order and inputs

`route.json` → road/terrain tiles → `semantics.json` → **vegetation**. `build` refuses to run unless all three exist
and pass their validators. It reads only package files: route samples, `tiles/*/terrain.glb` (ground height of the
mesh actually shipped) and the semantic zones. Rebuilding road/terrain rewrites `manifest.json`; run vegetation
again afterwards.

## 2. Output

```
vegetation/zones.json          vegetation distribution zones (from semantics), with mix, density, counts
vegetation/prototypes.json     prototype definitions (category, size, spacing, clearance, LOD hints)
tiles/NN/vegetation.json       per-tile instances, grouped by prototype
vegetation/validation.json     last validation report
manifest.json                  layers.P3_vegetation; tiles[].files.vegetation; tiles[].vegetation = count per category
```

### Vegetation zones (`zones.json`)

One per vegetating semantic zone, same route-relative box (`from_s`, `to_s`, `lateral_offset_m`, `side`), plus `kind`
and a `mix` of prototypes with densities:

```json
{"id": "v0074", "kind": "dense_forest", "semantic_zone": "z0125", "side": "left",
 "from_s": 641.21, "to_s": 671.98, "lateral_offset_m": [1.85, 37.4],
 "mix": [{"prototype": "conifer_spruce", "density_per_ha": 151.05, "free_area_ha": 0.1048, "target_count": 16, "count": 16},
         {"prototype": "deciduous_broadleaf", "density_per_ha": 35.96, "free_area_ha": 0.1048, "target_count": 4, "count": 4},
         {"prototype": "conifer_larch", "density_per_ha": 11.99, "free_area_ha": 0.1048, "target_count": 1, "count": 1},
         {"prototype": "fern", "density_per_ha": 400.0, "instanced_within_m": 20.0, "free_area_ha": 0.0597, "target_count": 24, "count": 24}],
 "confidence": 0.7, "source": {"kind": "scene_generator", "ref": "data/weissensee_sections.json S11 spruce_gravel", "estimated": true}}
```

| Zone kind | From semantics | Mix |
|---|---|---|
| `dense_forest` / `medium_forest` / `sparse_forest` | `forest` (`density`, `stems_per_ha`, `species`) | trees by species share (beech/birch → deciduous, spruce/fir/pine/larch → conifer, palm → tropical), ferns near the road |
| `sparse_trees` | `vegetation_zone` kind `scattered_trees` | trees at `stems_per_ha` (default 30) |
| `roadside_shrubs` | `vegetation_zone` kind `shrubs` | shrubs from `per_100m` |
| `reed_bed` | `vegetation_zone` kind `reeds` | reed clumps on the land side (water is excluded) |
| `grassland` | `grass` (`cover`) | grass clumps 2500/ha × cover, flowers 200/ha × cover (both within 25 m of the road edge), a few small rocks |
| `rocky_slope` | `cliff` | boulders 40/ha, small rocks 150/ha, shrubs 30/ha |

`density_per_ha` is the distribution; instances realise it on the zone's **free area** (the box minus exclusions,
measured with a 24 × 24 probe grid). `instanced_within_m` limits per-instance output of small plants to a band beyond
the road edge; the density still describes the whole zone, so a runtime may scatter the rest itself.

### Prototypes (`prototypes.json`)

```json
{"id": "deciduous_broadleaf", "category": "deciduous_tree", "height_m": [12.0, 28.0], "scale": [0.75, 1.15],
 "footprint_radius_m": 0.5, "min_spacing_m": 2.5,
 "lod": {"lod_distances_m": [40, 120, 300], "billboard_from_m": 300, "cull_distance_m": 1200},
 "reference_assets": ["FoliageSpawner._make_beech", "island_tree_02"]}
```

Categories: `grass`, `shrub`, `deciduous_tree`, `conifer`, `tropical_tree`, `flowers`, `rocks`, `ground_cover`.
Prototypes in 0.1: grass_clump, reed_clump, meadow_flowers, fern, shrub_broadleaf, deciduous_broadleaf,
conifer_spruce, conifer_larch, tropical_palm (defined, not used by any zone yet), rock_small, rock_boulder.
`reference_assets` name what the Godot scenes use today; prototypes carry no meshes yet — each runtime maps ids
to its own meshes / LOD groups (`assets/prototypes.glb` from the package writer is the planned shared source).

### Instances (`tiles/NN/vegetation.json`)

```json
{"version": "0.1", "tile": "03", "from_s": 1500.0, "to_s": 2000.0,
 "layout": "data: px py pz qx qy qz qw sx sy sz per instance, package frame (= glTF axes); s / lateral_offset_m route-relative; zone indexes zone_refs",
 "zone_refs": ["v0149", "v0154"],
 "groups": [{"proto": "conifer_larch", "category": "conifer", "count": 85,
             "data": [1472.673, 24.738, 466.548, 0.0, 0.60049, 0.0, -0.79963, 0.943, 0.943, 0.943, "..."],
             "s": [1545.714, "..."], "lateral_offset_m": [-21.702, "..."], "zone": [0, "..."]}]}
```

Per instance: world position, orientation (yaw about +Y as a quaternion), uniform scale (10 floats in `data`, the
same layout as today's `tile_XX_instances.json`, so `tools/unity/VirtualRunScatter.cs` can read the groups as is),
plus route-relative `s`, `lateral_offset_m` and the density region (`zone` → `zone_refs` → `zones.json`).
Grouped by prototype per tile = one GPU-instanced batch per prototype and tile; instances are assigned to the
tile whose `from_s ≤ s < to_s`.

## 3. Exclusions

An instance of category *c* may not stand:

| Where | Rule |
|---|---|
| on the playable road | `|lateral| < width(s) + clearance(c)`; clearance: grass / flowers / ground cover 0.3 m, rocks 0.5 m, shrubs 1.0 m, trees 1.5 m |
| on other road surfaces | inside `road` / `trail` / `sidewalk` zones, widened by the same clearance |
| inside buildings | inside `building_zone` (whole zone: no gardens in 0.1) |
| in water | inside `water` (no aquatic plants in 0.1; reed beds keep to the bank) |
| inside tunnels, on bridges | inside `tunnel` / `bridge` zones |
| on / across barriers | on a `wall` / `guardrail` / `fence` strip (±0.1 m); for trees, shrubs and rocks also anywhere between the road edge and 0.5 m beyond the barrier |
| off the terrain | no terrain triangle under it (e.g. beyond the clamped inside of a tight bend) |

Generation tests exclusions with a 1 cm margin so rounding the written values cannot cross a boundary.
Placement inside a zone is uniform random (seeded per zone and prototype: deterministic); trees, shrubs and
boulders use dart throwing with `min_spacing_m` so distribution is even rather than clumped.

## 4. Validation

| Check | Tolerance |
|---|---|
| zones reference existing semantic zones and prototypes; groups match prototypes / categories; arrays match `count` | exact |
| every instance inside its tile's `s` range and inside its density region (zone box) | 1 mm |
| no instance in an exclusion (§3), recomputed from route.json + semantics.json | exact |
| world position = route centre(s) + left(s) · lateral | 2 cm |
| height = terrain mesh (`terrain.glb` triangle under the point) | 5 cm |
| unit quaternion, positive scale within the prototype's range | 1e-3 |
| realised / target density per zone and prototype (target = density × free area, zones expecting ≥ 20) | ±15 % |
| density cap per category (trees 1500/ha, shrubs 3000, grass 20000, …) | exact |

## 5. Test package result

`export/packages/weissensee_rolling_hills` (route, road/terrain, semantics from the earlier stages):

- 412 vegetation zones: dense_forest 74, medium_forest 51, sparse_forest 2, sparse_trees 72, roadside_shrubs 84,
  grassland 114, reed_bed 13, rocky_slope 2.
- 29,502 instances over 10 tiles (2.4 MB): grass 17,641, ground_cover 4,652, deciduous 2,483, conifer 2,400,
  flowers 1,388, shrubs 713, rocks 225.
- Closest instance beyond the road edge per category: grass 0.31 m, flowers 0.36 m, ferns 0.61 m, rocks 1.01 m,
  trees 1.51 m, shrubs 2.0 m. Position error 1.3 mm, ground error 0.8 mm, density realised/target 0.977–1.023 → VALID.
- Build + validate ≈ 5 s.

## 6. Not in 0.1

Prototype meshes in the package, aquatic plants, gardens inside building zones, slope-aligned orientation for
ground cover, area correction for curvature (zones are measured in ds × du; on a bend of radius R the true area
differs by the factor 1 − u/R on the inside).
