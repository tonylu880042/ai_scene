# player_web - Rouvy-style web player prototype

The exported course video (`video.mp4`) is the bottom layer; a transparent Three.js canvas on top draws 3D running avatars standing on the trail,
locked to the video through the per-frame ground-truth camera track in `camera.json` (see `../tools/EXPORT_README.md`).
Plain HTML + ES modules, Three.js 0.170.0 from jsDelivr via an import map. No build step.

## Quick start
```
python3 player_web/fetch_assets.py          # one-off: downloads ~37 MB of CC0 avatar assets into player_web/assets/ (already present if you got this folder as is)
python3 player_web/serve.py 8000            # or: player_web/serve.sh   (serves the project root)
open "http://localhost:8000/player_web/index.html?export=../export/alpine_summit_10m"
```
Use `serve.py` rather than `python3 -m http.server`: the latter has no HTTP Range support, so seeking in the 200 MB mp4 would not work.
The page needs internet access for the Three.js CDN. Use Google Chrome (H.264).

## Controls
| key | action |
|---|---|
| Space | play / pause |
| `+` / `-` | pace faster / slower by 5 s/km (slider 4:00 - 9:00 min/km, default 6:00) |
| Left / Right | seek -5 s / +5 s |
| H | hide / show HUD + controls (clean recording) |
| R | reset the pacers to their configured offsets relative to you |
Seek bar and pace slider are in the control bar (appears when the mouse is over the video).

`video.playbackRate = user_pace_speed / camera.json.speed_mps` (6:00/km = 2.7778 m/s -> 1.0x; 4:00 -> 1.5x; 9:00 -> 0.667x).

## URL params
| param | default | meaning |
|---|---|---|
| `export` | `../export/alpine_summit_10m` | export folder (relative to `player_web/`) containing `video.mp4 camera.json route.json occluder.glb` |
| `pacers` | `5:30@-30,5:45@20,6:15@45,6:30@12,6:00@70` | up to 5 pacers `pace@offset_m` (offset relative to you at load/reset; negative = behind, i.e. starts behind and may overtake) |
| `speed` | `6:00` | initial user pace |
| `t` / `frame` | 0 | start at second / frame N. `frame=N` also pauses (no autoplay) and renders a still - handy for screenshots |
| `autoplay` | 1 | `0` = do not start playing |
| `hud` | 1 | `0` = start with the HUD hidden |
| `exposure`, `sun`, `hemi` | 0.9, 1.0, 1.0 | tuning: tone-mapping exposure, sun intensity multiplier (sun intensity = energy*PI*`sun`), hemisphere light intensity |
| `shadows` | 1 | `0` disables real shadows (blob shadows stay) |
| `occdrop` | 0.05 | metres the depth-only occluder is lowered (prevents z-fighting at the feet) |
| `debug` | off | exposes `window.__player` (scene, camera, pacers, `project()`, `renderFrame()`, `snapshot(name)`) and keeps the drawing buffer |

## How it works
**Sync.** `video.requestVideoFrameCallback` delivers `metadata.mediaTime` of the frame that is actually being presented. `frame = clamp(round(mediaTime*fps))`;
the camera is set from `camera.json` index `frame` (`position`, `quaternion`, vertical `fov_y_deg`, aspect 16:9, `near`, `far`; Godot and Three.js share Y-up, right-handed, -Z forward)
and the overlay is rendered inside that same callback, so avatars cannot lag the video. Fallbacks: `requestAnimationFrame` + `currentTime` when rVFC is missing or silent for >250 ms
(e.g. hidden tabs), and a render on the `seeked` event for paused scrubbing. The canvas is sized to the video's displayed 16:9 rectangle (letterboxed) and DPR-scaled.

**Coordinates.** Avatar at distance `s_a`: `pos = centre(s_a) + left(s_a) * lane`, `y = route y` (linear interpolation of the 1 m samples of `route.json`), yaw from `centre(s_a+1)-centre(s_a)`.
Lane stays within `road half-width - 0.22 m` (0.58 m here). When an avatar is within ~3 m of the camera (smooth ramp 4.5 m -> 1.5 m) it slides to the side of the trail opposite the camera, so the camera never goes through it
(measured minimum camera-to-body distance during an overtake: 0.95 m). Avatars more than 0.8 m behind the camera are not drawn but listed under "Behind" with their gap; avatars > 250 m ahead are hidden.

**Pacer clock.** Each pacer keeps a course distance `s_a` that advances by `v_a / playbackRate * d(mediaTime)` per presented frame, i.e. in real time it moves at its own speed `v_a` while you move at your pace;
pausing the video pauses everyone; a seek keeps every gap (R resets them). The HUD gap is `s_a - s_camera`.

**Animation / no sliding.** The Quaternius `Jog_Fwd_Loop` clip (0.917 s cycle) is retargeted at load (`retarget.js`: world-space retarget from the "DEF-" Blender rig of the Universal Animation Library to the UE-style rig of the
Universal Base Characters; hips translation scaled by the hip-height ratio). Its natural ground speed (stance-foot speed, measured at load: ~2.35 m/s) is used to drive the animation time from the avatar's *distance*:
`animTime = s_a / clipSpeed`. Feet therefore advance exactly the ground distance (no slide) and cadence is proportional to speed (6:00 pace -> ~155 steps/min; 5:30 -> ~170).

**Look.** Sun `DirectionalLight` from `sun_d*`, `sun_r/g/b`, `sun_energy` per frame (+ HemisphereLight, ACES tone mapping), real shadows onto an invisible `ShadowMaterial` ribbon along the route,
plus a radial-gradient blob shadow under every avatar. `occluder.glb` is rendered depth-only (`colorWrite:false`) before the avatars, so terrain hides avatars beyond crests (numeric check in `verify/`).
Outfits: two skin tones (supplied textures), hair meshes/colours, and shirt/shorts/socks/shoes colours painted by a small shader patch keyed on bind-pose position.

## Verification (see `verify/`, `verify_tools/`)
* `verify_foot.py <export> verify/foot_projection_input.json` - independent numpy projection of the avatar feet vs the Three.js projection (max 0.003 px) + inside-trail check + video colour check (uses ffmpeg).
* `verify_tools/*.mjs` - puppeteer-core scripts driving the installed Google Chrome (`npm i puppeteer-core`): `snap.mjs` screenshot, `foot.mjs` (collects the numbers for `verify_foot.py`), `occ.mjs` (occlusion pixel counts), `pass.mjs` (overtake clearance), `play.mjs` (real playback / rVFC rate).
* Screenshots in `verify/*.png`. `PLAYER_DEBUG=1 python3 serve.py` additionally enables `window.__player.snapshot(name)` to save a full-res composite (video + overlay) to `verify/`.

## Limitations / known issues
* Real-time DOM HUD only; to record the demo hide it with H (or `hud=0`) and screen-capture the page.
* Avatar feet follow the route centre-line height; the road cross-slope and the foliage are not modelled (grass/props do not occlude avatars). The depth occluder is lowered by 5 cm.
* The trail is only 1.6 m wide, so several pacers at similar distance overlap; give them different offsets.
* Avatars wear a painted-on top/shorts over the supplied underwear-only body (the free pack has no clothing); close-ups (< 3 m) show the stylised Quaternius look.
* Sun/ambient are fixed approximations of the Godot lighting (`exposure`, `sun`, `hemi` params) - no environment reflections, no SSAO. Real shadows use one 80 m shadow frustum that follows the camera (soft/blocky for avatars > 60 m; blob shadows cover those).
* `Jog_Fwd_Loop` only (no walk/sprint blending); very different paces (< 4:00 or > 9:00) would want other clips.
* Pacers' lane positions are fixed per pacer; two pacers can intersect when they overtake each other in the same lane.
* The headless / hidden-tab case: browsers pause video in hidden tabs; the player itself keeps working through the rAF fallback.
* Microsoft Rocketbox (stretch goal): not attempted. It ships FBX only with a Bip01 rig and no run clips, so it needs an FBX->GLB converter plus a Bip01 retargeter; the Quaternius result was already client-demo quality.
