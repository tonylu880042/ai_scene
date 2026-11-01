# AI Scene Package — format proposal

Status: **draft, schema_version 0.1** (2026-10-21). Nothing writes or reads this format yet; see
[MIGRATION_PLAN.md](MIGRATION_PLAN.md) for the order in which it gets implemented. System context:
[ARCHITECTURE.md](ARCHITECTURE.md).

The AI Scene Package is the contract between scene generation and game runtimes. It is engine-independent:
open file formats, one documented coordinate frame, explicit units, no engine node paths, shader names or axis
conventions as contract data.

## 1. Layout

```
<package_id>/
  manifest.json              package identity, frame, layer index, tile index, provenance summary
  route/
    route.json               P0 + P1 profile: canonical route samples, sections, checkpoints, surfaces
  terrain/                   P1
    terrain.json             tiles, water bodies, heightfield metadata
    heightfield.f32          optional: far-terrain heightfield (float32 LE, row-major, north row first)
  semantics/                 P2
    semantics.json           near-route spatial semantics: route-relative zones (docs/SEMANTICS.md)
  vegetation/                P3
    zones.json               vegetation distribution zones
    prototypes.json          prototype definitions
  structures/                P4
    structures.json          buildings, landmarks, route furniture (docs/STRUCTURES.md)
    prototypes.json          reusable + unique landmark prototypes
  environment/               P5 + P6 (docs/ENVIRONMENT.md)
    environment.json         distant terrain / water / skyline + sun, sky, ambient, fog, clouds, weather, time of day
    distant_terrain.glb      real DEM backdrop with orthophoto
    sky.hdr                  HDRI sky
  tiles/
    <NN>/road.glb            P0 road surface mesh for this stretch
    <NN>/terrain.glb         P1 ground mesh (and near water)
    <NN>/roadside.glb        P2 walls, guardrails, fences, kerbs; OSM context streets / car parks (tools/osm_context.py)
    <NN>/structures.json     P4 instancing groups + barrier polylines (docs/STRUCTURES.md)
    <NN>/buildings.glb       P4 OSM building footprints extruded (UV metres, COLOR_0 wall tint; tools/osm_context.py)
    <NN>/vegetation.json     P3 vegetation instances per prototype (docs/VEGETATION.md)
    <NN>/instances.json      P4 repeated props (posts, signs) per prototype
  assets/
    prototypes.glb           every repeated mesh once (node name = prototype id)
    textures/                only if not embedded in .glb
  licences.json              attribution / licence per external source and asset
  validation.json            last validator report (written by the validator, not by hand)
```

A runtime can load only `manifest.json` + `route/` + `tiles/*/road.glb` + `tiles/*/terrain.glb` (P0–P1) and still
be physically correct. Every other layer is optional for a runtime and may be `absent` in the manifest.

## 2. Conventions

| Item | Convention |
|---|---|
| Units | metres, seconds; angles in degrees; grade in percent; curvature in 1/m |
| World frame | right-handed, **X = east, Y = up, Z = south** (so north = −Z). Matches glTF (Y up, right-handed), so meshes need no conversion inside the package |
| Georeference | optional `manifest.frame.origin` = WGS84 lat/lon + ellipsoidal or orthometric altitude of the world origin; local tangent plane (ENU) at that origin. Synthetic routes: `origin: null`, "north" is still −Z |
| Elevation | `elevation_m` = altitude of the road surface (above sea level when georeferenced, else above the start). World `y = elevation_m − frame.origin.altitude_m` |
| Heading | compass bearing of travel, degrees clockwise from north (−Z), range [0, 360) |
| Left / right | relative to the direction of travel. Unit `left` vector = horizontal, perpendicular to heading, pointing left |
| Transforms | position (x, y, z) + rotation quaternion (x, y, z, w) + scale (x, y, z) in the world frame; no shear |
| Colours | linear RGB floats unless a field says `srgb` |
| Mesh assets | glTF 2.0 binary (`.glb`), PBR metallic-roughness; `COLOR_0` multiplies base colour; material names are semantic (`road_asphalt`, `terrain_grass`, `guardrail_steel`) so runtimes can substitute shaders |
| Interpolation | linear in `s` between route samples; heading by the shortest angle |
| JSON numbers | positions to 1 mm, angles to 0.01°, grade to 0.01 % |

Engine adapters convert from this frame (e.g. Unity glTFast negates X; the adapter must convert positions,
quaternions and headings with the same rule). The package never stores engine-converted values.

## 3. manifest.json

```json
{
  "schema_version": "0.1",
  "package_id": "saisies_d218b_descent",
  "title": "Col des Saisies descent (D218B)",
  "created_utc": "2026-10-21T00:00:00Z",
  "generator": {"name": "ai_scene/godot", "version": "<git describe>", "scene": "res://scenes/MainScene_saisies_geo.tscn"},
  "frame": {"origin": {"lat": 45.7577436, "lon": 6.5378919, "altitude_m": 1644.92, "altitude_ref": "orthometric"}},
  "route": {"file": "route/route.json", "length_m": 14615.1, "closed": false},
  "layers": {
    "P0_route":      {"status": "complete", "files": ["route/route.json", "tiles/*/road.glb"]},
    "P1_terrain":    {"status": "complete", "files": ["terrain/terrain.json", "tiles/*/terrain.glb"]},
    "P2_semantics":  {"status": "partial",  "files": ["semantics/semantics.json", "tiles/*/roadside.glb"]},
    "P3_vegetation": {"status": "generated", "files": ["vegetation/zones.json", "vegetation/prototypes.json", "tiles/*/vegetation.json"]},
    "P4_structures": {"status": "generated", "files": ["structures/structures.json", "structures/prototypes.json", "tiles/*/structures.json"]},
    "P5_distant":    {"status": "generated", "files": ["environment/environment.json", "environment/distant_terrain.glb"]},
    "P6_atmosphere": {"status": "generated", "files": ["environment/environment.json", "environment/sky.hdr"]}
  },
  "tiles": [{"id": "00", "from_s": 0.0, "to_s": 750.0, "bounds": [[-120, 1580, -900], [640, 1660, 40]]}],
  "prototypes": "assets/prototypes.glb",
  "licences": "licences.json"
}
```

`status`: `complete | partial | absent`. `bounds`: world AABB `[min, max]` of everything in the tile.

## 4. Route (P0, with the P1 elevation profile) — `route/route.json`

**Implemented — authoritative spec: [ROUTE_SCHEMA.md](ROUTE_SCHEMA.md)** (schema `schemas/route.schema.json`,
validator `tools/route_model.py`). In short: columnar samples every `sample_interval_m` with `s` (horizontal metres),
`x, y, z` (`y` = physical elevation − datum), `elevation_m`, `grade_percent`, `heading_deg`, `curvature` (+ left),
`width_left_m`, `width_right_m`, `surface_type`; route-level `route_id`, `version`, `coordinate_system`, `units`,
`total_length_m`, `sample_interval_m`, `start`, `finish`, `checkpoints`, optional `sections`, `visual`, `source`.

Decisions taken while implementing (they supersede the earlier draft of this section):
- `s` is **horizontal** distance (same in physical and exaggerated space; matches all producers).
- Grade is the exact derivative of the published elevation; noisy sources are filtered in the elevation profile,
  so there is no separate grade smoothing field.
- Visual height exaggeration lives in `visual` and never changes `y`, `elevation_m` or `grade_percent`.
- Corridor widths, banking, lanes and junctions are deferred (not in 0.1). `video_sync` is deferred too.

Runtimes use `sample(s)` (linear interpolation, heading by the shortest angle), `s → world` and
`world → (s, lateral offset)` by the nearest horizontal centreline segment.

**Road and terrain geometry built from the route: [ROAD_TERRAIN.md](ROAD_TERRAIN.md)** (`tools/road_terrain.py`):
`tiles/NN/road.glb` + `tiles/NN/terrain.glb` with tile records in `manifest.json`.

## 5. Terrain (P1) — `terrain/terrain.json`

```json
{
  "tiles": "tiles/*/terrain.glb",
  "corridor_rule": "terrain meets the road edge at road height; never above the road surface inside the corridor",
  "heightfield": {"file": "terrain/heightfield.f32", "origin_xz": [-12000, -12000], "cell_m": 31.25,
                  "cols": 769, "rows": 769, "y_offset_m": 0.0, "use": "far terrain beyond the tiles"},
  "water": [{"id": "lake", "mesh": "tiles/*/terrain.glb#water", "level_m": [[0.0, 929.4], [5200.0, 929.4]],
             "material": "water_lake"}],
  "provenance": {"kind": "dem", "ref": "AWS Terrain Tiles z12", "licence": "see licences.json", "estimated": false}
}
```

- Near terrain is meshes (route-aligned tiles) because cliffs, cuttings and embankments are not heightfields.
- `water.level_m` = `[[s, level], …]` (piecewise linear along the route) for water seen from the route.
- Terrain material classes (`terrain_grass`, `terrain_rock`, `terrain_sand`, `terrain_snow`, …) carry tint in
  `COLOR_0`, as the current export does.

## 6. Near-route spatial semantics (P2) — `semantics/semantics.json`

**Implemented — authoritative spec: [SEMANTICS.md](SEMANTICS.md)** (schema `schemas/semantics.schema.json`,
validator and queries `tools/semantics.py`). Zones are boxes in route coordinates: `from_s`..`to_s` ×
`lateral_offset_m` `[min, max]` (signed from the centreline, + left), with `side`, `vertical_offset_m`,
`semantic_type` (road, trail, sidewalk, grass, forest, water, cliff, slope, wall, guardrail, fence, building_zone,
vegetation_zone, bridge, tunnel, open_space), `confidence`, `source` and type-specific `attributes`.

Rules: only route surfaces inside the playable band; the route surface described everywhere; one ground cover per
spot; no forest or buildings on water or roads. P3 vegetation and P4 structures are generated **from** these zones
(`zones_in` / `zones_at`) and validated against them; roadside geometry (walls, guardrails) goes to
`tiles/*/roadside.glb` when that stage exists.

Context streets (`tools/osm_context.py fetch|build <package> <osm.json>`): OSM vehicular roads, parking aisles and
car parks within the shipped terrain, written to `tiles/*/roadside.glb` (materials `context_asphalt`,
`lane_marking`). Plan geometry is OSM-measured, widths come from tags or per-class estimates, heights are draped on
P1 terrain + 0.04 m. Quads within 0.6 m of the P0 road footprint are dropped, P0/P1 bytes never change, and P3
instances standing on context asphalt are removed. Provenance and counts: `manifest.layers.P2_corridor.context_streets`.

## 7. Vegetation (P3)

**Implemented — authoritative spec: [VEGETATION.md](VEGETATION.md)** (`tools/vegetation.py`). Generated only from the
route, the terrain tiles and the semantics: `vegetation/zones.json` (distribution zones with prototype mix and
density per ha, one per vegetating semantic zone), `vegetation/prototypes.json` (engine-neutral prototype
definitions: category, size, spacing, clearance, LOD hints) and `tiles/NN/vegetation.json` (instances grouped by
prototype: 10-float transforms as before, plus `s`, `lateral_offset_m` and the density region). Exclusions: the
playable band + clearance, road surfaces, buildings, water, tunnels, bridges, barriers.

## 8. Buildings, landmarks, props (P4)

**Implemented — authoritative spec: [STRUCTURES.md](STRUCTURES.md)** (`tools/structures.py`). Generated after
vegetation from route.json (race gates, checkpoint signs), the semantics (barriers, bridges, tunnel portals, generic
houses in building zones) and landmark hints (named landmarks, furniture): `structures/structures.json` (every object:
`object_id`, `semantic_type`, `importance` high / medium / low, `s`, `lateral_offset_m`, world `transform`,
`dimensions_m`, `prototype`, `confidence`, `source`, route footprints, polylines for barriers),
`structures/prototypes.json` (reusable and unique landmark prototypes) and `tiles/NN/structures.json` (instancing
groups + polylines per tile). High-importance objects are anchored and never moved; validation covers road
boundaries, terrain, vegetation, water, tunnels / bridges and overlaps.

## 9–10. Distant environment (P5) and atmosphere (P6) — `environment/environment.json`

**Implemented — authoritative spec: [ENVIRONMENT.md](ENVIRONMENT.md)** (`tools/environment.py`, scene facts from
`tools/export_environment_hints.gd`). One file with `distant` (terrain meshes such as the real DEM backdrop in
`environment/distant_terrain.glb`, large water planes, skyline, follow-runner anchoring for synthetic routes / world
anchoring for georeferenced ones) and `atmosphere` (sun direction / colour / intensity, HDR sky reference
`environment/sky.hdr` with the sun's position in the image, ambient, fog density and visibility, cloud layers,
weather, time of day, grading intent), plus attribution. Data only: no shader code or engine settings; Unity
(HDRP / URP) and Godot implement them their own way.

## 11. Provenance and licences

Every layer's JSON has a `provenance` object: `kind` (`gps | osm | dem | orthophoto | video | ai | program |
procedural | manual`), `ref`, `licence`, `estimated` (bool), optional `confidence` (0–1) and `note`.
`licences.json` lists every external data source and asset with its attribution text; runtimes must ship it.
Private reference video frames are never part of a package.

## 12. Validation

Engine-free validators write `validation.json`. A package that fails any P0/P1 check is not deliverable.

| Layer | Validator | Checks |
|---|---|---|
| Route | `tools/route_model.py validate` | [ROUTE_SCHEMA.md §4](ROUTE_SCHEMA.md) |
| Road + terrain tiles | `tools/road_terrain.py validate` | [ROAD_TERRAIN.md §4](ROAD_TERRAIN.md) |
| Near-route semantics | `tools/semantics.py validate` | [SEMANTICS.md §4](SEMANTICS.md) |
| Vegetation | `tools/vegetation.py validate` | [VEGETATION.md §4](VEGETATION.md) |
| Structures | `tools/structures.py validate` | [STRUCTURES.md §4](STRUCTURES.md) |
| Distant environment + atmosphere | `tools/environment.py validate` | [ENVIRONMENT.md §3](ENVIRONMENT.md) | instances / footprints outside the road band unless `on_road`; referenced files exist; licence entries present |

## 13. Relation to today's Unity export

| Today (`tools/export_unity.gd`) | Package |
|---|---|
| `tile_XX.glb` (road + terrain + walls + houses mixed) | split into `tiles/NN/road.glb`, `terrain.glb` (meshes) and `structures.json` (objects → prototypes) |
| `tile_XX_instances.json` | `tiles/NN/instances.json` (same 10-float layout) |
| `prototypes.glb` | `assets/prototypes.glb` |
| `route.json` (x, y, z, half_left/right, water_y, backdrop_yaw; horizontal `s`) | `route/route.json` (canonical samples); `water_y` → terrain water, `backdrop_yaw` → distant |
| `environment.json` (Godot energy, AgX, tile list) | `environment/environment.json` (data, relative intensities) + `manifest.json` |
| `backdrop.glb`, `water.glb`, `sky.hdr` | `environment/distant_terrain.glb`, `distant.water[]`, `environment/sky.hdr` |
| `VirtualRunScatter.cs`, `VirtualRunBackdrop.cs`, `README_UNITY.md` | not in the package: Unity adapter (reads the package) |
