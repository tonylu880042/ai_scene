# Adapters — producers and consumers around the package

Adapters are implementation conveniences. The package and its validators never depend on them; anything that
writes the same JSON / GLB is an equal producer, anything that reads the package is a consumer.

## Producer adapters (Godot, temporary, during migration)

The current synthetic-route generators live in Godot (`scripts/route.gd` and friends). Until engine-free builders
exist for 2B routes, author in a template scene and export facts from it:

| Template | Kind | Sections file |
|---|---|---|
| `scenes/MainScene.tscn` | coastal harbour path | — |
| `scenes/MainScene_alpine.tscn` | alpine trail, cloud sea | — |
| `scenes/MainScene_garda.tscn` | lake shore, cliffs, tunnels (`sea_right`) | `data/garda_sections.json` + `real_shore` |
| `scenes/MainScene_winter.tscn` | snow road, farms | `data/winter_sections.json` |
| `scenes/MainScene_weissensee.tscn` | lakeside forest trail, boardwalk | `data/weissensee_sections.json` + `real_shore` |

Copy the closest to `scenes/MainScene_<name>.tscn` (never edit an existing scene). New needs = new parameters of the
shared scripts (`route.gd`, `FoliageSpawner.gd`, `Buildings.gd`, `Boardwalk.gd`, …), not `<name>_*.gd` pipelines.

- **Bends:** per section `"turn"` (degrees over the section, + left / − right; a list splits the section into eased
  bends). One section with `turn` switches the whole route to turns. Load prints the tightest radius; < ~150 m folds
  the inside terrain — split hairpins over longer sections.
- **Grade:** route.gd follows the treadmill program; `grade_scale` (1.5) exaggerates only the rendered road.
  `tools/export_route.gd` writes the physical elevation (`Route.elevation_at`) and records the exaggeration in
  `visual`.

| Adapter | Writes |
|---|---|
| `tools/export_route.gd` | `route/route.json` (+ finalize + round trip through `scripts/route_data.gd`) |
| `tools/export_semantics.gd` | `semantics/semantics.json` from the scene's generator rules (`source.kind: scene_generator`); fallback / reference for the default engine-free `tools/build_semantics.py` |
| `tools/export_environment_hints.gd` | `environment/hints.json` (sun, sky, fog, real-terrain placement, water) |
| `tools/dump_route.gd` + `tools/plot_route.py` | top-down route map per section (L0 picture; route.json heading changes are the engine-free check) |

Engine-free data producers that stay: `tools/fetch_real_terrain.py` (DEM + orthophoto), `tools/real_shore.py`,
`tools/download_assets.py` (Poly Haven CC0), the Saisies OSM / DEM builders (to be generalised).

## Rendered verification (consumer adapter)

Validators prove geometry and data. Checklist layers L1–L4 still need eyes on a picture of the same place:

- Render at each section's registered entry / middle / exit s, at the estimated reference camera height and pose.
  A section midpoint alone is insufficient for temporal acceptance. The precise procedure is in
  [camera and temporal review](camera-temporal-review.md).
  Today the renderable target is the Godot source scene or the legacy Unity export rebuilt in Godot:
  `godot --path . --script tools/verify_unity_export.gd -- export_unity/<name> <scratch>/S05.png <s>` (windowed,
  not headless). A package renderer is planned (MIGRATION_PLAN phase 4).
- Reference frame and render side by side at the same size, labelled with ID / time / version;
  `tools/make_comparisons.py` pairs them and records hashes (it does not judge).
  If sizes differ, fix the capture, never stretch.
- Order of judgement: bend / road exit and edge line → landmark side, size, occlusion → distant ridges and sky
  opening → canopy and verges → materials and light. More trees is not a better forest; correct OSM / DEM is not a
  correct time anchor or camera.
- Keep three verdicts apart: runs (loads, tours to the end), geometry / data (validators), looks like the frame
  (reviewer). A technical PASS never upgrades to a visual pass; an unrendered section is not accepted.

## Camera alignment

- Camera: 1.65 m above the route surface and vertical FOV 75° are initial estimates only, not calibrated defaults;
  test and adjust with video evidence. Record uncertainty, motion and stabilization as applicable.
- Time → distance: real roads use the registration anchors
  ([reference-analysis.md](reference-analysis.md#time--route-registration-real-roads)); synthetic routes map
  time to `s` through the section boundaries (`video_km` share of the route). Moving one anchor moves the
  interpolation of its neighbours: recheck monotonicity and adjacent sections.
- Fixed views and the tour must use the same pose interpolation.
- Before full scenes, align with a cheap route-only / grey-model probe on two or three consecutive recognisable
  bends; only then build one representative section fully, then extend.
- Grade is a route property, camera pitch a projection; never tune one to fake the other.

## Export validation (consumer adapters)

- **Godot GLB import:** `GLTFDocument.append_from_file` on `tiles/*/road.glb`, `terrain.glb`,
  `environment/distant_terrain.glb` returns OK (images included).
- **Legacy Unity zip** (until Unity reads packages; Unity import is the other team's): windowed
  `godot --path . --script tools/export_unity.gd -- --course=<c> --out=export_unity/<name>`, check with
  `tools/verify_unity_export.gd`, zip `export_unity/<name>`. Remind: glTFast import, `VirtualRunScatter.cs`
  NegateX vs NegateZ, skybox rotation, keep the attribution in `README_UNITY.md`. The package's 10-float instance
  layout is the same as the legacy one.
- **Web player** (`player_web/`, video + camera.json from `tools/export_course.sh`) is a separate product;
  `tools/check_frozen.py` catches stalled movie-writer frames.

## Lossless export compaction

When delivering GLB tiles, check for repeated embedded images before zipping. Identical images can be extracted
once into shared texture files, with each GLB using a relative image URI. This preserves the original image bytes,
encoding and resolution; it does not decimate geometry, remove instances or change distance, elevation or grade.
Keep the original export and write a separate compact candidate.

In the `ai_scene` repository, `tools/compact_static_unity.py` implements SHA-256 image sharing for the **legacy
flat export folder**: root-level GLBs, each with one embedded BIN buffer and embedded PNG/JPEG images. It does not
handle already-external images, texture extensions or compressed/custom buffer views; an unsupported input needs
an explicit adapter, not ignored assertions. Run it with normal Python (not `python -O`). The destination must not
exist and must be outside the source folder.

```bash
python3 -m unittest tools/test_compact_static_unity.py
python3 tools/compact_static_unity.py ORIGINAL_FOLDER COMPACT_FOLDER
```

Before accepting the candidate:

- Inspect `OPTIMIZATION.json`: retained geometry buffer views are byte-verified and scene/material/accessor
  structure is checked after index remapping. Independently compare route and instance JSON hashes and counts
  against the original; image files must match the original embedded payload hashes.
- Validate the complete output, including relative texture paths. Render original and compact exports with the
  same frozen project, camera poses, renderer, resolution and settings; compare decoded pixels at representative
  sections and start/finish. Record differences; do not claim pixel identity without checking. A Godot round trip
  does not establish Unity Editor compatibility or appearance.
- Rebuild validation reports and SHA-256 checksums after compaction; package GLBs **together with `textures/`**,
  metadata, licences and provenance. Check ZIP CRC, file inventory and checksums after extraction; exclude private
  video frames and source snapshots. A compact GLB is no longer a standalone file.
- Report actual original/compact ZIP bytes and `100 * (1 - compact_bytes / original_bytes)`; distinguish this from
  the GLB-plus-texture byte savings in `OPTIMIZATION.json`. Savings depend on duplication; 90% is not a target or
  guarantee. File-size savings do not establish an FPS improvement.

**Existing Saisies reproduction only** (commands from the project root; absolute output/evidence paths):

```bash
python3 tools/validate_static_unity_export.py COMPACT_FOLDER
godot --path FIXED_PROJECT --resolution 1920x1080 \
  --script res://tools/verify_static_unity_export.gd -- \
  COMPACT_FOLDER NEW_COMPACT_EVIDENCE_FOLDER
python3 tools/package_static_unity.py COMPACT_FOLDER NEW_COMPACT_EVIDENCE_FOLDER
```

The fixed project needs the verifier and its parent script/shader dependencies. The current static validator
asserts the Saisies route length; the packager requires Saisies audit/terrain files and writes R37 provenance.
Reuse them only for that matching export. Other routes need their own validated packaging path and truthful
provenance. Details and frozen-source restoration: `docs/saisies_unity_export.md`.

**AI Scene Package boundary:** do not run this flat-folder tool on `export/packages/<id>/`. It does not traverse
`tiles/NN/` or maintain manifest/layer references. Shared textures in a package need a package-aware writer,
correct GLB-relative URIs to `assets/textures/`, and compatible validators/readers. Keep the validated embedded
assets until that path exists; then rerun `python3 tools/validate_package.py export/packages/<id>` and consumer
checks before delivery.

Observed Saisies result (2026-10-21): 1,649 image payloads shared as 84 unique files; ZIP **2,274,776,542 →
289,625,847 bytes (87.27% smaller)**. The existing record reports five pixel-identical native round-trip views and
passing ZIP CRC; Unity Editor review remains pending. This is a case result, not a universal preset.

## Godot adapter mechanics

- Node order: `CourseSetup` first, nodes that read the route curve after `Path3D`; typed Node exports become null in
  instanced scenes → `NodePath` + `get_node`.
- Front faces are clockwise in Godot (glTF: counter-clockwise); verify with a known up-facing face and real culling.
- User args come after `--` (`OS.get_cmdline_user_args()`); test that a flag is actually read, not ignored.
- MultiMesh data differs between headless (Dummy) and native GPU: headless checks authored records only; bake /
  read back natively. `export_unity.gd` and textured captures need a window.
- HDR textures: lossless import (`compress_to=0`); HDRI sun leaking into ambient → `hdri_sky.gdshader` `ambient_clamp`.
  Real mountains need camera far ≥ 30 km.
- Capture: confirm non-black output, size, file and errors; one unique writable log per process. On Metal, repeated
  `frame_post_draw` waits once stalled — a few `process_frame` + `RenderingServer.force_draw()` + viewport readback
  worked there (an environment-specific workaround, not a rule).
- Performance numbers only from completed measurements (scene, warm-up, renderer, resolution, frame count).
