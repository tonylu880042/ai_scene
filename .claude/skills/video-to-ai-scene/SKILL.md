---
name: video-to-ai-scene
description: Turn a reference running / riding / hiking video (plus any map, GPS or elevation data) into an engine-independent AI Scene Package - canonical route, road + terrain tiles, near-route semantics, vegetation, buildings / landmarks, distant environment and atmosphere - validated stage by stage. Route first (playable, physical grade), decoration last; stops when every section meets its gate. Unity / Godot / Web are consumers, not the output. Use when the user gives a video or route and asks for a virtual-run / ride scene, an AI scene package, or a scene "like this video". Trigger words - "video to ai scene", "AI scene package", "/video-to-ai-scene", "用這個影片建立場景包", "影片轉AI場景".
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

Layout of a package (`docs/AI_SCENE_PACKAGE.md`):

```
export/packages/<id>/
  route/route.json  manifest.json  tiles/NN/{road.glb, terrain.glb, vegetation.json, structures.json}
  semantics/semantics.json  vegetation/{zones,prototypes}.json  structures/{structures,prototypes}.json
  environment/{environment.json, distant_terrain.glb, sky.hdr}  */validation.json
```

## Phase 1 — Reference analysis

Read [references/reference-analysis.md](references/reference-analysis.md) first. In short:

1. `ffprobe` duration / time base; contact sheet every 10 s; read the whole video.
2. Cut 10–30 sections at clear environment changes, IDs S01…; one untouched reference frame each
   (`video/<name>_ref/S01.png`, with PTS and SHA-256).
3. Per section extract **structure**: bend sequence (heading change, left / right), climb / descent and any HUD
   elevation or speed, road width and surface, what is on each side and how far (water, forest edge, wall,
   guardrail, slope, cliff, buildings, open land, bridge, tunnel), vegetation type and density, landmarks (name,
   side, size, order), distant terrain and sky (open / blocked, mountains, clouds, sun side).
4. Decide the route source: is the real road identifiable (signs, place names, map match)? → Phase 2A, else 2B.
5. Write `data/<name>_sections.json` (authoring input: `video_km`, `types`, `sections`, `landmarks`, as
   `data/weissensee_sections.json`) and `data/<name>_checklist.json` (per section, per layer, only items visible in
   that frame). **Show the checklist to the user once; then it is frozen.**

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
- **Gate L0 (90 %):** route.json VALID; per-section heading change matches the checklist bend order; tightest bend
  radius ≥ ~150 m (or split the hairpin over a longer section); widths / surfaces per section plausible; start,
  finish, checkpoints placed. Per-section heading change from route.json alone:

```bash
python3 -c "import json,sys; r=json.load(open(sys.argv[1])); s=r['samples']; f=lambda v: min(range(len(s['s'])), key=lambda i: abs(s['s'][i]-v)); [print(x['id'], round(-(((s['heading_deg'][f(x['to_s'])]-s['heading_deg'][f(x['from_s'])]+180)%360-180)), 1), 'deg (+ left)') for x in r.get('sections', [])]" export/packages/<id>/route/route.json
```

## Phase 3 — Terrain reconstruction

`python3 tools/road_terrain.py build export/packages/<id> --tile-m=500` (250–500 m tiles; also validates).
Road rows sit exactly on the route; terrain starts on the road edge; hills / noise / exaggeration only beyond 3 m
(`docs/ROAD_TERRAIN.md`). Gate: VALID (no gaps, seams ≤ 1 mm, road elevation / width / slope = route, no folds,
start / middle / end probes). The L1 side-specific landform (valley left, wall of rock right) is carried by Phase 4
`slope` / `cliff` zones; the procedural terrain does not shape sides yet.

## Phase 4 — Near-route scene understanding

Zones in route coordinates: `s` range × signed lateral offset, side, vertical offset, type, confidence, source
(`docs/SEMANTICS.md`) — water, forest, slope, cliff, wall, guardrail, fence, building_zone, vegetation_zone,
open_space, bridge, tunnel, road / trail / sidewalk.

- From the analysis directly: write `semantics/semantics.json` with `source.kind: video` / `ai` and honest confidence.
- *Adapter (Godot, temporary)* for a sections-file scene:
  `godot --headless --path . --script tools/export_semantics.gd -- --scene=res://scenes/MainScene_<name>.tscn --course=<c> --package=export/packages/<id>`
  (it describes the scene as built, not the video — check where they differ).
- Review: `python3 tools/semantics.py describe export/packages/<id> <s> …` at each section's midpoint against the
  checklist's L2 side items. Gate: VALID + L2 side relations ≥ 80 %.

## Phase 5 — Vegetation distribution

`python3 tools/vegetation.py build export/packages/<id>` — zones (dense forest, sparse trees, grassland, reed bed,
roadside shrubs, rocky slope) from the semantics, prototypes, per-tile instances (`docs/VEGETATION.md`).
Distribution accuracy over per-tree reconstruction. Gate: VALID (road clearance, exclusions, ground, density ±15 %)
+ L2 vegetation items ≥ 80 %.

## Phase 6 — Buildings and landmarks

Hints for what the semantics cannot know: named landmarks (`importance: high`, exact s / side / size), furniture
(medium), filler (low) — `docs/STRUCTURES.md`.
`python3 tools/structures.py build export/packages/<id> --hints=<hints.json>` (or `--sections=data/<name>_sections.json`
to derive hints from the sections file). High-importance objects are never moved: if one fails placement, fix the
hint or the upstream layer. Gate: VALID + L3 ≥ 80 % (each landmark present, correct side, roughly right size and order).

## Phase 7 — Distant environment and atmosphere

Real mountains: `python3 tools/fetch_real_terrain.py <name> <lat> <lon> <km>` (DEM + orthophoto, attribution
required); HDRI: Poly Haven CC0 via `tools/download_assets.py`. Scene facts as `environment/hints.json`
(`docs/ENVIRONMENT.md`); *adapter (Godot, temporary):*
`godot --headless --path . --script tools/export_environment_hints.gd -- --scene=res://scenes/MainScene_<name>.tscn --course=<c> --package=export/packages/<id>`
then `python3 tools/environment.py build export/packages/<id>`. Data only (sun direction / intensity, fog density,
sky reference, cloud coverage …), never shader code. Gate: VALID + L1 distant items (mountain side / skyline, sky
opening, sun side) ≥ 90 %.

## Phase 8 — AI Scene Package

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
