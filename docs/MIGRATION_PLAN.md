# Migration Plan — from Godot scenes to the AI Scene Package

Status: **proposed** (2026-10-21). Target architecture: [ARCHITECTURE.md](ARCHITECTURE.md). Format:
[AI_SCENE_PACKAGE.md](AI_SCENE_PACKAGE.md).

Principles: preserve working functionality; migrate one component at a time; every phase ends with the existing
scenes and the current Unity export still working; no Godot generator rewrites until the package writer and
validator exist and can prove a change did not regress P0/P1.

## 1. Classification

| Label | Meaning |
|---|---|
| **KEEP** | Stays as is; already fits the architecture (input data, tooling, Godot-only rendering) |
| **REFACTOR** | Stays, but its internals must be restructured to meet the architecture (e.g. separate route model from mesh building) |
| **ADAPT** | Internals stay; it gets an output path into the package (or reads the package) |
| **REPLACE** | A new component takes over its role; the old one keeps working until the replacement is validated, then retires |
| **RETIRE** | Frozen: no new features, not part of the package pipeline; deleted only after its replacement reaches parity and the user agrees |

### 1.1 Shared Godot generators (`scripts/`)

| Component | Class | Notes |
|---|---|---|
| `route.gd` (Route) | **REFACTOR** | Mixes P0 (centreline, widths, sections), P1 (elevation, terrain columns, water) and mesh building in one class. Issues against the new rules: (a) elevation = ∫ program incline × `grade_scale` (default 1.5, "visual exaggeration") — grade is tied to a treadmill program and the road is steeper than the program says; (b) physical elevation only via the new `elevation_at(s)` (the rendered road stays ×`grade_scale`); (c) sections are `video_km` fractions stretched to the course length; (d) road widths are per-row arrays with no surface type or corridor. Target: a route-model part that can be sampled into the canonical route (heading, curvature, grade, widths, surface, checkpoints) and a terrain/mesh part that consumes it. Keep the public API (`pos_at`, `left_at`, `ground_y`, `half_left/right`, `section_at`, `landmarks`) stable so every other script keeps working. |
| `FoliageSpawner.gd` | **REPLACE** (for the package) | P3 package output now comes from `tools/vegetation.py` (zones → instances, engine-neutral). FoliageSpawner stays the Godot preview's renderer; later it can draw `tiles/*/vegetation.json` instead of placing its own (its placement rules are captured as semantics by `tools/export_semantics.gd`). `export_unity.gd`'s MultiMesh read-back retires with it. |
| `Buildings.gd` | **REPLACE** (for the package) | P4 package output now comes from `tools/structures.py` (records with importance, footprints, prototypes). Buildings.gd stays the Godot preview's builder; its mesh recipes (`_chalet`, `_barn`) are the reference for the `house_chalet` / `barn_timber` prototypes. No change to how houses look. |
| `Boardwalk.gd`, `AlpineProps.gd`, `WinterProps.gd` | **ADAPT** | P2/P4. Walls, quays, railings, snow poles, power lines: tag P2 features into `roadside.json`, P4 objects into `structures.json`. |
| `real_terrain.gd`, `mountain_ring.gd` | **ADAPT** | P5. Real DEM backdrops: done — `tools/environment.py` meshes the same DEM with the same placement into `environment/distant_terrain.glb` (follow_runner). Open: procedural `mountain_ring.gd` backdrops, world-anchored georeferenced terrain. |
| `course_setup.gd` + `data/courses*.json` | **ADAPT** | P6: done — `tools/export_environment_hints.gd` reads the placed sun / fog / time of day; `environment.json` stores them as data (relative intensities, linear colours, sun rule relative to the route). |
| `Gates.gd` | **ADAPT** | Start/finish become canonical checkpoints; gates are P4 visuals placed at those `s` values. Godot finish behaviour unchanged. |
| `coastal_path.gd` | **RETIRE** | Early prototype path, superseded by `route.gd`. |
| `player_controller.gd`, `hud.gd`, `minimap.gd`, `FollowPlayer.gd`, `FootstepSoundPlayer.gd`, `render_quality.gd` | **RETIRE** | Godot preview runtime. Frozen, kept working for authoring/preview; the production runtime is Unity. |
| `Pedestrians.gd` | **RETIRE** | People are runtime content, out of package scope. Stays in the Godot preview. |
| `track_exporter.gd` | **KEEP** | Video + camera ground truth for the web player (separate product). Later: take `incline` from the package grade instead of the program. |
| `shaders/` | **KEEP** | Godot reference renderer only. Not contract data; the exporter converts to plain PBR as today. |

### 1.2 Scenes and data

| Component | Class | Notes |
|---|---|---|
| `scenes/MainScene*.tscn` (coast, alpine, garda, winter, weissensee) | **KEEP** | Authoring templates and reference renders. Each becomes a package source. |
| `scenes/legacy/` | **RETIRE** | Already unmaintained. |
| `data/programs.json` | **KEEP** | Training programs. In the new model they *generate* synthetic elevation profiles; they never override route grade. |
| `data/*_sections.json` (garda, winter, weissensee) | **ADAPT** | Authoring input stays in `video_km`; the package writer converts to metre `s` ranges. |
| `data/*_checklist.json` + frozen reference frames | **KEEP** | Acceptance evidence (P2–P6 visual; P0 bend order). |

### 1.3 Export, validation and Unity hand-off (`tools/`)

| Component | Class | Notes |
|---|---|---|
| `tools/export_unity.gd` | **REFACTOR** | Becomes the Godot package writer (`tools/export_package.gd`): reuse its glTF export, material conversion (`_terrain_mesh`, `_gltf_safe`), instance gathering and tiling; split tiles per layer; write canonical `route.json`, `manifest.json`, layer JSONs, `licences.json`. Unity-specific parts (copying `.cs`, Unity README, NegateX notes) move to the Unity adapter. `export_unity.gd` keeps producing today's layout until the Unity side reads packages, then retires. |
| `route.json` writer (`_write_route`) | **REPLACE** | By the canonical route (§4 of the package doc). Today's fields map: x/y/z → samples; `half_left/right` → widths; `water_y` → terrain water; `backdrop_yaw` → distant follow yaw. |
| `environment.json` | **REPLACE** | By `environment/environment.json` (done) + `manifest.json`. |
| `tools/unity/VirtualRunScatter.cs`, `VirtualRunBackdrop.cs`, `README_UNITY.md` | **ADAPT** | Become the reference Unity adapter that reads a package (axis conversion, instancing, backdrop follow). Unity team owns the production importer. |
| `tools/verify_unity_export.gd` | **REPLACE** | By (1) `tools/validate_package.py` — engine-free schema + invariant checks; (2) a Godot package reader that renders a package for visual comparison. |
| `tools/dump_route.gd`, `tools/plot_route.py`, `tools/check_route_turns.gd` | **ADAPT** | Read the canonical route; add elevation/grade/curvature plots to `plot_route.py` (P0/P1 review without rendering). |
| `tools/section_sheet.py`, `tools/check_frozen.py` | **KEEP** | Per-section scoring sheets; frozen-checklist guard. |
| `tools/download_assets.py`, `tools/fetch_real_terrain.py`, `tools/real_shore.py` | **KEEP** | Input acquisition (assets, DEM, orthophoto). Licence info feeds `licences.json`. |
| `tools/export_course.sh`, `tools/verify_export.py`, `player_web/`, `tools/rocketbox_to_glb.gd` | **KEEP** | Video export + web player with avatars: separate product, untouched. |
| `tools/blender_scene.py`, `tools/blender_real_band.py`, `tools/runway_clip.py`, `tools/frames_to_mp4.py`, `tools/splice_highlights.py` | **RETIRE** | Not part of the pipeline (the skill already excludes Blender/Runway/recordings unless asked). Files stay. |

### 1.4 Col des Saisies (all of it is currently **untracked in git**)

The Saisies work holds the most valuable P0/P1 code in the repo (real OSM centreline, IGN RGE Alti road elevations,
geographic frame, provenance and `estimated` flags) and also the largest parallel pipeline (~75 `saisies_*.gd`
scripts, ~35 scenes, ~30 data files, ~60 tools, per-round review modules) — the pattern the skill forbids.

| Component | Class | Notes |
|---|---|---|
| Geo acquisition: `fetch_saisies_geography.py`, `fetch_saisies_road_elevations.py`, `fetch_saisies_nearfield.py`, `build_saisies_geo_route.py`, `build_saisies_geo_buildings.py`, `build_saisies_geo_forest.py` | **ADAPT** | Generalise into a shared "OSM + DEM → canonical route" builder for any real road. This is the P0/P1 reference implementation. |
| `data/saisies_geo_route.json`, `saisies_geo_road_elevations.json`, other `saisies_geo_*.json` | **KEEP** | Source data with provenance. |
| `saisies_geography.gd`, `saisies_geo_route.gd` | **ADAPT** | Feed the Saisies package route. Convert their route-forward frame (`x = right, z = −forward`) to the package ENU frame. Review the runtime profile (80 m box filter, grade limited to −18 … +3 %) and declare it in `profile`; the +3 % cap may hide real short climbs. |
| `saisies_geo_*` environment scripts, `saisies_release_*` | **ADAPT** | Export the R36 release candidate through the package writer: the first georeferenced package. |
| `saisies_route.gd`, `saisies_camera.gd`, `saisies_trees.gd`, `saisies_roadside_chalets.gd` | **REFACTOR** | Base classes / helpers still used by the geo scripts (`SaisiesGeoRoute extends SaisiesRoute`, geo camera extends `SaisiesCamera`, release forest loads `saisies_trees.gd`). Fold what is generic into the shared generators before retiring the rest. |
| v1/v2 scenes and their scripts (`saisies_environment.gd`, `saisies_landscape.gd`, `saisies_village*.gd`, `saisies_upper/lower_scenery.gd`, `saisies_runtime.gd`, `MainScene_saisies*.tscn` non-geo, `data/saisies_route*.json`, `saisies_scene_map.json`) | **RETIRE** | Superseded by the geo version. |
| Per-round review modules (`saisies_s01_*` … `saisies_s04_*`, `saisies_r37_*`, review controllers, `run_saisies_*.command/.py`, review scenes, `data/saisies_s0*_*.json`, `docs/saisies_revision_round*.md`, `docs/saisies_s0*_*.md`) | **RETIRE** | Their accepted results (S01–S03) are carried by the release; no new rounds in this form. |
| `skills/video-scene-reconstruction/` | **RETIRE** | Its evidence contract, rendered-acceptance and Saisies lessons are merged into `.claude/skills/video-to-ai-scene/references/`; `scripts/make_comparisons.py` is still referenced from there (move it before deleting). |

### 1.5 Workflow documents

| Component | Class | Notes |
|---|---|---|
| `.claude/skills/video-to-virtual-run/SKILL.md` | **REFACTOR** → **RETIRE** after review | Rewritten as `.claude/skills/video-to-ai-scene/` (2026-10-21): output = AI Scene Package, phases 1–9 route-first, Godot scripts marked as temporary adapters, lessons moved to `references/pitfalls.md` / `adapters.md`, whole-package check `tools/validate_package.py`. The old skill stays until the new one is reviewed; both currently match "video to scene" requests. |
| `README.md` | **ADAPT** | Link `AGENTS.md` and the architecture docs; trim Saisies round history to a pointer. |
| `tools/EXPORT_README.md`, `tools/unity/README_UNITY.md` | **ADAPT** | Point to the package format once the writer exists. |

## 2. Phases

Each phase is small, ends with everything that worked before still working, and has one verifiable outcome.

| Phase | Work | Done when |
|---|---|---|
| 0 | These documents | Reviewed and agreed (open decisions in §3 answered) |
| 1 | **Done for `Route` (2026-10-21):** route model + validator (`tools/route_model.py`, [ROUTE_SCHEMA.md](ROUTE_SCHEMA.md)), Godot producer/consumer (`tools/export_route.gd`, `scripts/route_data.gd`), road + terrain tiles (`tools/road_terrain.py`, [ROAD_TERRAIN.md](ROAD_TERRAIN.md)). Near-route semantics (`tools/semantics.py`, `tools/build_semantics.py`; Godot fallback `tools/export_semantics.gd`, [SEMANTICS.md](SEMANTICS.md)). Vegetation (`tools/vegetation.py`, [VEGETATION.md](VEGETATION.md)). Structures (`tools/structures.py`, [STRUCTURES.md](STRUCTURES.md)). Distant environment + atmosphere (`tools/environment.py`, `tools/export_environment_hints.gd`, [ENVIRONMENT.md](ENVIRONMENT.md)). Open: `SaisiesGeoRoute` producer | Weissensee, winter and Saisies-geo produce P0/P1-only packages that pass the validator; existing scenes unchanged |
| 2 | Update the `video-to-virtual-run` skill to P0–P6 and the package deliverable | Skill describes package output; route/elevation/grade review uses `plot_route.py` profiles |
| 3 | Refactor `export_unity.gd` into `export_package.gd`: per-layer tiles, instances, structures, roadside, distant, atmosphere, licences | Full package for one scene passes validation; `export_unity.gd` output unchanged |
| 4 | Godot package reader (reference renderer) | A package renders in Godot and matches the source scene at the section checkpoints |
| 5 | Reference Unity adapter reads the package (hand-off to the Unity team) — **MVP started 2026-10-21:** `unity/AIScenePlayer` (route, streamed tiles, instanced vegetation, environment, test player, HUD, validation; engine-free core verified with `dotnet test unity/CoreTests`, Unity layer not yet run in an editor) | Unity team confirms import; `export_unity.gd` retires |
| 6 | `route.gd` refactor (route model vs mesh build; surface types; build the Godot road from route.json) | All five template scenes regenerate with identical P2–P6 placement and validated P0/P1 |
| 7 | Saisies consolidation: shared OSM+DEM route builder, release exported as package, round modules frozen | Saisies package passes validation; no Saisies-only generator remains in the active path |

## 3. Open decisions (need the user)

1. ~~`grade_scale` = 1.5~~ — **decided:** physical grade = program grade; the 1.5× is recorded in route.json `visual`
   and only the Godot renderer (and optionally visual terrain relief) uses it.
2. ~~Distance definition~~ — **decided:** `s` is horizontal distance (identical in physical and exaggerated space);
   surface distance is `ds · sqrt(1 + grade²)` in the runtime.
3. **Package frame.** Proposed X east / Y up / Z south with optional WGS84 origin (glTF-compatible). Today Saisies
   uses a route-forward frame and the generic scenes start along +X.
4. **Saisies in git.** None of the Saisies files are committed. Commit (or archive) the current state before any
   migration work touches them.
5. **Real-road routes.** Proposed: when a video's road can be identified, P0/P1 come from OSM/GPS + DEM and the video
   only confirms bend order and roadside features (reverses the current skill rule that geo data is backdrop-only).
