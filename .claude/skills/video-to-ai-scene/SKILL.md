---
name: video-to-ai-scene
description: Turn a reference running / riding / hiking video (plus any map, GPS or elevation data) into an engine-independent AI Scene Package - canonical route, road + terrain tiles, near-route semantics, vegetation, buildings / landmarks, distant environment and atmosphere - validated stage by stage. Location, measured data (OSM / DEM) and an external asset library first, then time → route registration, route and terrain (playable, physical grade), decoration last; stops when every section meets its gate. Unity / Godot / Web are consumers, not the output. Use when the user gives a video or route and asks for a virtual-run / ride scene, an AI scene package, or a scene "like this video". Trigger words - "video to ai scene", "AI scene package", "/video-to-ai-scene", "用這個影片建立場景包", "影片轉AI場景".
---

# Video → AI Scene Package

Project: `/Users/tunghunglu/projects/ai_scene`. Architecture: `AGENTS.md`, `docs/ARCHITECTURE.md`,
`docs/AI_SCENE_PACKAGE.md`; each stage's format is in the doc named in its phase below.

**The output is an AI Scene Package** (`export/packages/<id>/`): route.json, road / terrain GLB tiles, semantics,
vegetation, structures, environment, manifest — engine-independent, validated. Not a Godot scene, not a Unity scene,
not a rendered video. Runtimes (Unity, owned by another team; Godot; Web) consume it; rendering, recording, runners
and Unity import are not part of this skill unless the user asks.

**Done** = every stage validator passes and every section meets its checklist gate (route / terrain 90 %, the rest
80 % — not an average over the video). Then stop and hand the per-section sheet to the user for sign-off.

## Rules

- **Priority is fixed:** route → terrain → near-route semantics → vegetation → structures → distant + atmosphere.
  Never start a phase before the previous one validates; a later phase that breaks an earlier one is reverted.
- **The route is physical.** Distance, elevation and grade drive cycling physics, trainer resistance, treadmill
  incline and race progress. Grade = rise / horizontal run from the published elevation. Visual exaggeration goes in
  route.json `visual`, never into elevation or grade.
- **Structure, not pixels.** Extract bends, sides, distances, densities, landmarks from the video. Frames are private
  references: never copied into the package, never fed to generators, no brand elements.
- **Coarse to fine, 2 rounds max.** A gate failing after 2 revision rounds: stop, list the blocked sections and items,
  ask the user. Do not loosen a frozen checklist to pass.
- **Check layout, not looks, first.** Compare section layout (sides, order, distances) against the frames; render
  only what a gate needs; no recordings unless asked.
- **Adapters are temporary.** Godot scripts below are *implementation adapters* (producers of facts during the
  migration, or consumers for rendered checks). The package must never depend on them; any producer that writes the
  same JSON is equally valid. Shared generators get new parameters; no per-scene `<name>_*.gd` pipelines.
- **Measured before estimated.** Route, water, buildings and streets come from OSM / GPS / DEM fetched in Phase 0;
  a video estimate replaces a measurement only where the frame shows the measurement is generalised (sea wall hard
  against the path), recorded per span in `source`.
- **External assets, not drawn ones.** Trees, shrubs, grass, rocks and furniture use existing or downloaded models /
  textures (Phase 0 library). Writing a mesh generator for a plant is the last resort and needs a written reason
  (nothing usable found, licence, triangle budget).
- **Whole route before any section.** No per-section refinement (one section's sand, a chapel's orientation,
  a paved edge) until every section passes the Phase 3 grey-box layout check. Gold Coast spent r5–r30 on S18/S19
  while the shoreline and the time → s registration under them were still wrong.
- **Time boxes.** Phase 0 + 1 ≤ half a day; each later gate ≤ 2 rounds. Over budget: stop and ask the user.
- **Stop at valid.** Once a stage validator passes, do not chase sub-mm / float32 / triangulation polish unless a
  validator fails or a gate item depends on it.
- **One package per milestone.** At most two package dirs per scene: the working one and the last that passed a
  gate. Copy to a new `<id>_rNN` only when a gate passes. Delete diagnostic / failed candidates once their finding
  is written down (Gold Coast left 58 package dirs).
- **Reviews keep evidence, not copies.** Freeze a version by committing and recording the commit hash + package
  file SHA-256 — never by copying source, the Godot project, packages, SDKs or toolchains into a review folder.
  A round keeps `review.json` + one comparison sheet; raw shots live in the scratchpad. When a gate passes or the
  scene is delivered, delete that scene's earlier rounds and keep only the final sheet and acceptance JSON.
  Review folders get a `.gdignore` (Godot otherwise imports them: Gold Coast reached 30 GB of review copies and a
  12 GB `.godot/imported`). No platform data (Android / iOS SDKs, export presets) in the project; Godot only.
- **One agent.** Do the work in this session; split across agents only when the user asks.

Layout of a package (`docs/AI_SCENE_PACKAGE.md`):

```
export/packages/<id>/
  route/route.json  manifest.json  tiles/NN/{road.glb, terrain.glb, vegetation.json, structures.json}
  semantics/semantics.json  vegetation/{zones,prototypes}.json  structures/{structures,prototypes}.json
  environment/{environment.json, distant_terrain.glb, sky.hdr}  */validation.json
```

## Phase 0 — Location, data and asset inventory (before building anything)

Skim the contact sheet (Phase 1 step 1) only far enough to answer these, then fetch everything once:

1. **Where is it?** Signs, place names, coastline shape, distinctive junctions → a map location, or "synthetic"
   (2B). A real place found later costs every layer built on the guess.
2. **Fetch and cache measured data** (once, into `export/<name>/osm/`, `assets/`): DEM, OSM route ways, water /
   coastline (`tools/osm_context.py fetch-water`), buildings + streets (`fetch`), skyline (`fetch-skyline`), real
   distant terrain (`tools/fetch_real_terrain.py`), HDRI (`tools/download_assets.py`). The `osm_context.py`
   commands need a package with route.json, so run them right after Phase 2; decide here which ones apply.
3. **Route topology:** loop, out-and-back, turnaround, or the same path ridden twice (Gold Coast s 2540 and s 10660
   are 4 m apart). List the repeated spans now; terrain clearance and P3/P4 exclusions depend on it.
4. **Asset library** `data/<name>_library.json` — one entry per vegetation / furniture type the video shows,
   `{"<prototype>": {"file": "assets/models/...gltf", "scale": .., "attribution": ".."}}` (format of
   `data/gold_coast_library.json`, read by `tools/build_package_assets.py <package> <library.json>`). Search order:
   `assets/models/` → Poly Haven (CC0, `tools/download_assets.py`) → OpenGameArt / Quaternius / Kenney (CC0) →
   CC-BY with attribution → procedural (with reason). Grass: Poly Haven grass models or texture cards, not
   generated tufts. Check per model: licence, triangles (tree ≤ ~3k, grass card ≤ ~200), PBR textures, size;
   convert non-glTF with Blender. `build_package_assets.py` labels every library entry `CC0` — add a `license`
   field there before using a CC-BY asset.
5. **Gate:** location decided; data cached; every vegetation / furniture type has a library entry or a written
   "procedural because …"; repeated spans listed. Tell the user the location and the asset list in a few lines.

## Phase 1 — Reference analysis and time → route registration

Read [references/reference-analysis.md](references/reference-analysis.md) first. In short:

1. `ffprobe` duration / time base; contact sheet every 10 s; read the whole video.
2. Cut 10–30 sections at clear environment changes, IDs S01…; one untouched reference frame each
   (`video/<name>_ref/S01.png`, with PTS and SHA-256).
3. Per section extract **structure**: bend sequence (heading change, left / right), climb / descent and any HUD
   elevation or speed, road width and surface, what is on each side and how far (water, forest edge, wall,
   guardrail, slope, cliff, buildings, open land, bridge, tunnel), vegetation type and density, landmarks (name,
   side, size, order), distant terrain and sky (open / blocked, mountains, clouds, sun side).
4. Route source from Phase 0: real road → Phase 2A, else 2B.
5. **Register video time to route distance** (real roads): 5–10 anchors the frame and the map both show
   (junctions, bridges, turnarounds, OSM buildings, coastline corners) → `data/<name>_route_alignment.json`
   (`time_s` + lat / lon, as `data/gold_coast_route_alignment.json`). Check every gap between anchors against a
   plausible speed; each section gets an `s` range with a confidence, unknown stays unknown. Without this, every
   later gate compares the wrong place: Gold Coast's acceptance stayed 0/24 with registration unresolved, and S03
   / S11 / S14 turned out 50–200 m off.
6. Write `data/<name>_sections.json` (authoring input: `video_km`, `types`, `sections`, `landmarks`, as
   `data/weissensee_sections.json`) and `data/<name>_checklist.json` (per section, per layer, only items visible in
   that frame). **Show the checklist and the section → s table to the user once; then both are frozen.**

Checklist layers (keys kept for `tools/section_sheet.py`): `L0` route (bend order, width, surface; grade only if the
video gives it) → Phase 2 · `L1` terrain + distant (valley / water side, slopes, mountains, sky opening) → Phases 3, 7
· `L2` near-route environment (barriers, vegetation type / density, open land) → Phases 4–5 · `L3` landmarks →
Phase 6 · `L4` details (markings, signs, materials) → Phases 6–7.

## Phase 2 — Route reconstruction (highest priority)

Goal: a valid `route/route.json` (`docs/ROUTE_SCHEMA.md`) with trajectory, distance `s`, elevation, physical grade,
heading, curvature, widths, surface, start / finish / checkpoints. **It must be playable before anything visual.**

- **2A, real road:** centreline from OSM / GPS, elevation from a DEM (IGN RGE Alti, AWS Terrain Tiles) or GPS;
  filter the elevation profile (a road is smoother than a DEM) and declare the filter in `source`. The Saisies
  builders (`tools/build_saisies_geo_route.py`, `tools/fetch_saisies_road_elevations.py`) are the reference
  implementation — Saisies-specific until generalised. Write the primary facts (s, x, z, elevation_m, widths,
  surface_type, markers by s) and finalise:
  `python3 tools/route_model.py finalize raw.json export/packages/<id>/route/route.json`
- **2B, no GPS (synthetic):** bends from the video (`"turn"` per section, degrees, + left; a list for S-bends),
  length from the course, elevation from the training program (`data/programs.json`) or HUD estimates.
  *Engine-free (default):* write `data/<name>_sections.json` (per-section `half`, `road`, `surface`, `turn`), then
  `python3 tools/build_route.py data/<name>_sections.json --course=<c> --out=export/packages/<id>/route/route.json [--bend=0.6 --start-height=0 --sea-right --road-left=.. --road-right=.. --pace=6]`
  — scripts/route.gd's centre line (sine bends when no section has `turn`), physical grade, smoothed widths and
  surface, START / FINISH gates (10 m / length − 12 m), checkpoints every 1000 m, then `finalize`; matches the
  Godot export below to < 1 mm. Options are the scene's Path3D exports after its course template is applied.
  *Fallback adapter (Godot):* copy the closest template scene to `scenes/MainScene_<name>.tscn` (templates and
  `turn` rules: [references/adapters.md](references/adapters.md)), then
  `godot --headless --path . --script tools/export_route.gd -- --scene=res://scenes/MainScene_<name>.tscn --course=<c> --out=export/packages/<id>/route/route.json`
  (writes physical elevation, runs `finalize` and a round trip).
- **Gate L0 (90 %):** route.json VALID; per-section heading change matches the checklist bend order; bend radii
  agree with the observed route type; public walkways may have small-radius bends / turnarounds. Never stretch a
  mapped hairpin to a generic 150 m radius. The full-width offset corridor must validate; widths / surfaces per section plausible; start,
  finish, checkpoints placed. Per-section heading change from route.json alone:

```bash
python3 -c "import json,sys; r=json.load(open(sys.argv[1])); s=r['samples']; f=lambda v: min(range(len(s['s'])), key=lambda i: abs(s['s'][i]-v)); [print(x['id'], round(-(((s['heading_deg'][f(x['to_s'])]-s['heading_deg'][f(x['from_s'])]+180)%360-180)), 1), 'deg (+ left)') for x in r.get('sections', [])]" export/packages/<id>/route/route.json
```

## Phase 3 — Terrain reconstruction

`python3 tools/road_terrain.py build export/packages/<id> --tile-m=500` (250–500 m tiles; also validates).
Road rows sit exactly on the route; terrain starts on the road edge; hills / noise / exaggeration only beyond 3 m
(`docs/ROAD_TERRAIN.md`). Gate: VALID (no gaps, seams ≤ 1 mm, road elevation / width / slope = route, no folds,
start / middle / end probes, plus global centre / 80%-width probes against every terrain tile). Loops and repeated
traversals use shared `tools/terrain_clearance.py`: clip P1 against foreign P0 road footprints without moving
P0. Ground consumers must query shipped triangle indices rather than reconstruct the old grid, and P3/P4 must
exclude other traversals in world space. A local no-fold result alone cannot accept a route. Tight mapped paths use shared `tools/build_osm_route.py` (explicit time/map alignment,
provenance, optional unobserved-spur removal and declared turnaround radius), then the shared terrain builder's
adjacent edge-ray reach cap. An impossible full-width corridor must fail before export, not be repaired by flipped
faces or a narrower road. Coastal brief producer: `tools/build_coastal_layers.py profiles` then
`road_terrain.py build --terrain=<profiles.json>`; read `docs/ROAD_TERRAIN.md` for the shoreline parameters. The L1 side-specific landform (valley left, wall of rock right) is carried by Phase 4
`slope` / `cliff` zones; the procedural terrain does not shape sides yet.

**Water first from OSM.** Where Phase 0 found coastline / water, take the shore from
`osm_context.py shoreline <package> <water.json> <from_s> <to_s> <out.json>` (OSM-measured edge per 2 m) and keep a
video estimate only for spans the frames prove OSM generalised. One edge distance per side per 2 m cannot draw a
narrow creek mouth: that needs a 2D water mask (not built yet — note the span, do not hand-tune profiles for it).

Extra gates before Phase 4:
- **Buildings on land:** run `osm_context.py buildings` on a scratch copy; every OSM building it drops for standing
  on P1 water marks a P1 shore error (Gold Coast lost 53 real buildings this way at r48). Fix P1, not P4.
- **Grey-box layout check:** route + terrain + water + OSM building blocks only, one shot per section at its
  registered `s` (adapter, [references/adapters.md](references/adapters.md)), against the reference frame:
  water side, road / street side, building side and order, bend direction. All sections must pass L0 + the L1
  side items here. A section that fails is a registration, route or P1 problem — fix it now, never later with
  vegetation or props.
- Then **freeze P0 + P1** (record the route / road / terrain file hashes). A later phase that needs them changed
  reopens Phase 2 / 3 explicitly and reruns Phases 4–7 on the result.

## Phase 4 — Near-route scene understanding

Zones in route coordinates: `s` range × signed lateral offset, side, vertical offset, type, confidence, source
(`docs/SEMANTICS.md`) — water, forest, slope, cliff, wall, guardrail, fence, building_zone, vegetation_zone,
open_space, bridge, tunnel, road / trail / sidewalk.

- Real road: context streets / parking from OSM first —
  `python3 tools/osm_context.py build export/packages/<id> <osm.json>` (`tiles/NN/roadside.glb`, ODbL) — then the
  video's side items for what OSM lacks (walls, guardrails, fences, verges).
- From the analysis directly: write `semantics/semantics.json` with `source.kind: video` / `ai` and honest confidence.
- For a sections-file scene (default, no Godot), on the package's route.json from Phase 2:
  `python3 tools/build_semantics.py data/<name>_sections.json export/packages/<id> [scene flags]` — the flags are
  the scene's Path3D / Foliage / Buildings exports (weissensee: `--sea-y=-12 --inland-slope=1 --bank-ratio=0.45
  --bank-run=3 --cliff-lip=0.4 --max-dist=38 --trees-per-chunk=70 --buildings`; see the tool's docstring). Same
  zones as the Godot adapter; inland `vertical_offset_m` is approximate (no DEM / noise hills).
  *Fallback (Godot adapter)*: `godot --headless --path . --script tools/export_semantics.gd -- --scene=res://scenes/MainScene_<name>.tscn --course=<c> --package=export/packages/<id>`
  (relative `--package`). Both describe the scene as built, not the video — check where they differ.
- Review: `python3 tools/semantics.py describe export/packages/<id> <s> …` at each section's midpoint against the
  checklist's L2 side items. Gate: VALID + L2 side relations ≥ 80 %.

## Phase 5 — Vegetation distribution

`python3 tools/vegetation.py build export/packages/<id>` — zones (dense forest, sparse trees, grassland, reed bed,
roadside shrubs, rocky slope) from the semantics, prototypes, per-tile instances (`docs/VEGETATION.md`).
Distribution accuracy over per-tree reconstruction. Then give the prototypes real meshes from the Phase 0 library:
`python3 tools/build_package_assets.py export/packages/<id> data/<name>_library.json` (copies the model into
`assets/library/`, records attribution; unmapped prototypes fall back to procedural boxes / cones — the package,
not only a preview adapter, must carry the real asset, so Unity gets it too). A type with no library entry goes
back to Phase 0's search, not into a new generator. Gate: VALID (road clearance, exclusions, ground, density
±15 %) + L2 vegetation items ≥ 80 % + no procedural vegetation prototype without its Phase 0 reason.

## Phase 6 — Buildings and landmarks

Real road: ordinary buildings come from OSM footprints and heights —
`python3 tools/osm_context.py buildings export/packages/<id> <osm.json> [skyline.json]` (`tiles/NN/buildings.glb`
P4, `environment/skyline_buildings.glb` P5; heights tag → levels → bounded neighbour median → type estimate).
Hints are only for what OSM and the semantics cannot know: named landmarks (`importance: high`, exact s / side / size), furniture
(medium), filler (low) — `docs/STRUCTURES.md`.
`python3 tools/structures.py build export/packages/<id> --hints=<hints.json>` (or `--sections=data/<name>_sections.json`
to derive hints from the sections file). High-importance objects are never moved: if one fails placement, fix the
hint or the upstream layer. Gate: VALID + L3 ≥ 80 % (each landmark present, correct side, roughly right size and order).

## Phase 7 — Distant environment and atmosphere

Use what Phase 0 fetched. Real mountains: `python3 tools/fetch_real_terrain.py <name> <lat> <lon> <km>` (DEM +
orthophoto, attribution required); HDRI: Poly Haven CC0 via `tools/download_assets.py`, chosen to match the
video's sky (clear midday ≠ overcast). Scene facts as `environment/hints.json`
(`docs/ENVIRONMENT.md`). *Engine-free (default):*
`python3 tools/environment_hints.py scenes/MainScene_<name>.tscn --course=<c> --package=export/packages/<id>`
— reads the .tscn text (WorldEnvironment, Sun, CourseSetup, LakeFar, RealBackdrop/RealTerrain), the course template
and the route (build_route.py), and places the sun as CourseSetup does at the start; matches the Godot adapter to
< 1e-4. With no scene, write hints.json from the video in the same format. *Fallback adapter (Godot):*
`godot --headless --path . --script tools/export_environment_hints.gd -- --scene=res://scenes/MainScene_<name>.tscn --course=<c> --package=export/packages/<id>`
(relative `--package` only; needs the scene's assets present, else it hangs). Then `python3 tools/environment.py build export/packages/<id>`. Data only (sun direction / intensity, fog density,
sky reference, cloud coverage …), never shader code. Gate: VALID + L1 distant items (mountain side / skyline, sky
opening, sun side) ≥ 90 %.

## Phase 8 — AI Scene Package

Before packaging, inspect GLBs for repeated embedded images. Prefer byte-identical shared textures when the
delivery format and consumer support them; preserve geometry, physical route data and image quality. Read
[lossless export compaction](references/adapters.md#lossless-export-compaction) for the existing legacy tool,
its limits and verification. Its flat-folder layout is not an AI Scene Package writer.

The package is complete when `manifest.json` lists every layer with status and files. Zip for hand-off:
`cd export/packages && zip -r -q <id>.zip <id> -x "*.DS_Store" "*/hints.json"`. `export/` is not in git; give the
user the path. Keep the attribution in `environment/environment.json` with the package.

## Phase 9 — Validation

```bash
python3 tools/validate_package.py export/packages/<id>
```

Runs every stage validator in order (route continuity, physical grade, road geometry, terrain connection, semantic
placement, road clearance, vegetation density, structures, environment references) and checks that every file the
manifest lists exists. Plus the engine-free tests: `python3 -m unittest tools/test_scene_package.py`.

Then the per-section sheet: scores per checklist item (1 / 0.5 / 0) in `<scratch>/scores.json`, shots from a
rendering adapter ([references/adapters.md](references/adapters.md) — rendered verification, camera alignment):
`python3 tools/section_sheet.py data/<name>_checklist.json <shots_dir> <scratch>/scores.json <out_dir>`.
All sections PASS → hand `sheet_*.png` and the package path to the user and stop.

**Optional consumer checks** (adapters, not the workflow): Godot GLB import / render, the legacy Unity zip
(`tools/export_unity.gd` + `tools/verify_unity_export.gd`) until Unity reads packages, Web player. See
[references/adapters.md](references/adapters.md).

## Known pitfalls

By layer — route, terrain, semantics, vegetation, structures, environment, adapters — in
[references/pitfalls.md](references/pitfalls.md). Read the section for the phase you are in.
