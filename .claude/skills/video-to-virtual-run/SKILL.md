---
name: video-to-virtual-run
description: Turn a reference running/hiking video into a Godot virtual-run scene, render a course with realistic pacer avatars running on it (web player), and export the scene to Unity (glTF tiles + instances). Use when the user gives a video (file in video/ or a path) and asks to build a scene like it, simulate runners on it, or convert it for Unity3D. Trigger words - "用這個影片建立場景", "video to scene", "虛擬跑步場景", "轉成 unity", "/video-to-virtual-run".
---

# Video -> Godot scene -> runners -> Unity

Project: `/Users/tunghunglu/projects/ai_scene` (Godot 4.7, `godot` on PATH; ffmpeg; Python 3 + Pillow/numpy;
node + puppeteer-core in the session scratchpad for browser checks). Two reference scenes already exist and are the
templates: `MainScene.tscn` (coastal harbour) and `MainScene_alpine.tscn` (alpine trail - the most complete one).

Arguments: `<video path>` and optionally a scene name (default: video file stem, snake_case) and a course
(default `summit`; courses live in `programs.json`, scene templates per course in `courses*.json`).

Work in this order and show the user rendered evidence (contact sheets / screenshots) at each phase - never
claim a look you have not rendered and viewed.

## Phase 1 - Analyse the video (structure, not copying)
1. Probe it, then sample one frame every 1-2 minutes into contact sheets (3x6 grid, timestamp labels):
   `ffmpeg -i "$V" -vf "fps=1/120,scale=640:-1" /tmp/vf/f_%03d.jpg` then tile with PIL. Read the sheets.
2. Write down the scene recipe: path type/width/surface, what is left/right of the path (water, cloud sea, slope,
   road), vegetation (species, density, colours), rocks, fences/railings, signs/buildings, sky/weather/fog,
   time of day, distant landforms, camera height and motion. Note the probable real location if obvious.
3. The video is a private reference only: never ship its frames, never feed it to generators, never copy
   unique branded elements. Keep `video/` git-ignored.

## Phase 2 - Build the Godot scene
Start from the closest template (copy it to `MainScene_<name>.tscn`; never edit the existing scenes destructively).
Knobs that already exist - prefer them over new code:
- `route.gd` (`Path3D` node): `alpine_trail`, `trail_half`, `width_jitter`, `edge_blend`, `groove_depth`, `bump_amp`,
  `wiggle`, `micro_relief`, `hill_height`, `inland_slope`, `side_slope`, `alpine_start/range`, `sea_y`.
  Coastal mode: `road_left/right`, `bank_*`, `grass_bank`.
- `courses_<name>.json` per-course templates (copy `courses_alpine.json`) applied by `course_setup.gd`
  (`courses_file`, `tod` time-of-day range, `fog`/mist episodes, `hdri_sky` + `hdri_sun_u/elev`).
- `FoliageSpawner.gd`: `meadow_clumps`, `clump_scale`, `fir_models`, `tree_cluster`, `fir_tint`, `conifer_*`,
  `rocks_per_chunk`, `rock_scale_mult`, `flower_*`, `fence_*`, `trail_pebbles/roots`.
- `AlpineProps.gd` (signposts, hut, cairns), `Buildings.gd` (coastal huts, pier...), `Gates.gd` (start/finish).
- Sky: Poly Haven HDRI via `hdri_sky.gdshader` (pick one matching weather; find the sun pixel and set
  `hdri_sun_u/elev`); procedural fallback `alpine_sky.gdshader`.
- Distant real terrain: `python3 tools/fetch_real_terrain.py <name> <lat> <lon> <km>` then a `RealTerrain` node
  (`real_terrain.gd`) - use the video's real location when known.
- Cloud sea: `cloud_volume.gdshader` (ray-marched). Water: `ocean_water.gdshader`. Grass: `grass.gdshader`.
- New CC0 assets: Poly Haven API (`https://api.polyhaven.com/files/<id>`); add them to `tools/download_assets.py`.
Verify with real renders (not headless) and view them:
`godot --path . res://MainScene_<name>.tscn --write-movie /tmp/x/f.png --fixed-fps 60 --quit-after 62 -- --course=<c> --start-min=<m> --no-hud --hq`
Compare side by side with the reference contact sheet; iterate on the biggest differences first.

## Phase 3 - Render a course clip + camera track
- `EXPORT_EXTRA=--hq CRF=20 tools/export_course.sh <coast|alpine|...> <course> <start_min> <minutes>`
  (add a `case` line for a new scene). Output `export/<scene>_<course>_<m>m/`: video.mp4 + camera.json +
  route.json + occluder.glb (contract: `tools/EXPORT_README.md`).
- It must pass `tools/check_frozen.py` (run automatically) and `python3 tools/verify_export.py <dir>` (centre-line
  overlay on the trail). Tell the user to keep the Godot window visible while recording.

## Phase 4 - Runners on the scene (web player)
- `python3 player_web/serve.py 8765` (Range support), open
  `http://localhost:8765/player_web/index.html?export=../export/<dir>` in Chrome (`open -a "Google Chrome" ...`).
  Realistic avatars (Microsoft Rocketbox, MIT) are the default; `&avatars=quaternius` for CC0 stylised ones;
  `&pacers=5:30@6,6:00@12` sets pace@gap; `&hud=0`, `&frame=N` for stills.
- Verify with headless Chrome screenshots (`player_web/verify_tools/snap.mjs`, `play.mjs`) and look at them: feet on
  the trail, no floating, playback advancing (~60 rVFC/s). New Rocketbox characters: `tools/rocketbox_to_glb.gd`.

## Phase 5 - Unity export
- `godot --path . --script tools/export_unity.gd -- --course=<c> --out=export_unity/<name>` (windowed, not
  headless; options `--from-m --to-m --tile-m --grass --flowers`). Scene only - no avatars.
- Verify: `godot --path . --script tools/verify_unity_export.gd -- export_unity/<name> /tmp/v.png <s_metres>` at
  start / middle / end and view the PNGs.
- Zip: `cd export_unity && zip -r -q VirtualRun_<Name>_Unity.zip <name> -x "*.DS_Store"`, give the user the path.
  Remind them: glTFast import, `VirtualRunScatter.cs` (NegateX vs NegateZ check), skybox rotation, cloud sea must be
  rebuilt in Unity, keep the attribution lines from `README_UNITY.md`.

## Pitfalls already solved - do not reintroduce
- Godot's AVI movie writer stops at 4 GB -> recording goes through PNG frames + `tools/frames_to_mp4.py` (segmented
  image-sequence encode; image2pipe dropped frames). macOS stops drawing a covered window -> frozen frames
  (exporter sets always-on-top; `check_frozen.py` fails the export).
- HDRI sun leaking into ambient made sections glow white -> `ambient_clamp` in `hdri_sky.gdshader` (AT_CUBEMAP_PASS).
- HDR textures must import lossless (`detect_3d/compress_to=0` in the .import) or the sky bands.
- PNG-sourced MP4s need explicit bt709 tags or Safari/Chrome hardware decoders stall.
- Typed Node exports set from .tscn on instanced scenes came back null -> use `NodePath` exports + `get_node`.
  Nodes that read the route's curve must come after `Path3D`; `CourseSetup` must be first.
- Plants/rocks must keep clear of the walked surface (use `route.half_left/right(s)`); big boulders keep 2 m+.
- Camera: head-bob off (users get dizzy); only `wander_amp`/`breathe_amp` (tiny) for a human line.
- macOS `sed -i` needs `''`; prefer Python for edits. Commit only when the user asks; never push `assets/`, `export*/`,
  `video/`, `runway/`.
