# Course export (video + ground-truth camera data)

## Run

```
tools/export_course.sh <coast|alpine> <course> <start_min> <minutes>
tools/export_course.sh alpine summit 10 2        # -> export/alpine_summit_10m/
python3 tools/verify_export.py export/alpine_summit_10m [--frames 0,3600,7100]
```

Output folder `export/<scene>_<course>_<startmin>m/`:
`video.mp4` (1920x1080, 60 fps, H.264 yuv420p, CRF 26 (env CRF; 20 gives ~50 Mbit/s on this noisy foliage), no audio, faststart), `camera.json`, `route.json`, `occluder.glb`, `godot.log`.

Internally: `godot --path . <scene> --write-movie _tmp.avi --fixed-fps 60 -- --course=.. --start-min=.. --no-hud --export-dir=<dir> --export-minutes=N`.
`track_exporter.gd` (node `TrackExporter` in both scenes) is inactive without `--export-dir`. It forces the root viewport to 1920x1080
(the movie writer records the root viewport; `--resolution` does not change it). Extra debug flag `--export-markers` adds magenta
unshaded spheres every 5 m on the centre line (used by `verify_export.py --markers`; env `EXPORT_EXTRA=--export-markers EXPORT_SUFFIX=_markers` with the driver).

Frame i of video.mp4 (time i/60 s) == index i of every array in camera.json. The pose is sampled in a `_process` with the
highest priority number, i.e. after all other nodes, so it is exactly what is rendered for that frame (measured timing offset: 0 frames).

## camera.json
```
{ "version":1, "scene":"alpine", "course":"summit", "fps":60, "width":1920, "height":1080,
  "fov_y_deg":75, "near":0.05, "far":4000, "speed_mps":2.7778, "start_time":<course s at frame 0>, "frame_count":N,
  "frames": { "t","s","px","py","pz","qx","qy","qz","qw","incline","sun_dx","sun_dy","sun_dz","sun_r","sun_g","sun_b","sun_energy": [N numbers each] } }
```
- Godot world space (Y up, right-handed, camera looks down local -Z) == Three.js conventions. fov is VERTICAL, aspect 16:9.
- t = course time (s); s = horizontal distance along route (m) of the camera; p = Camera3D global position; q = global orientation quaternion (xyzw).
- incline = programme incline % at t. sun_d* = unit vector pointing TOWARD the sun; sun colour/energy from the DirectionalLight3D.
- Three.js: `camera.position.set(px,py,pz); camera.quaternion.set(qx,qy,qz,qw); camera.fov = fov_y_deg; camera.aspect = 16/9`.
  Pixel-centre convention: Godot pixel index (x,y) centre = NDC of (x+0.5, y+0.5) as usual.

## route.json
`{ "version":1, "step":1.0, "length", "road_left", "road_right", "s":[0..floor(length)], "x","y","z":[centre line, y = trail surface], "lx","lz":[unit horizontal LEFT vector] }`
Centre line sampled every 1 m over the whole route (interpolate linearly for fractional s). Left of travel = +left vector;
trail spans from -road_right to +road_left along it (alpine: 0.8 each).

## occluder.glb
Route road + terrain meshes (no textures, world space, Y up) for chunks covering the recorded s range plus ~400 m ahead
(plus one 50 m chunk margin), exported with GLTFDocument. Render depth-only (colorWrite=false) before avatars.
Painted-line meshes and foliage/props are not included (trees do not occlude avatars).

## verify_export.py
Extracts frames, projects route points (s+2 .. s+80 m) with camera.json, writes `<dir>/verify/overlay_<frame>.png`
(red dots = centre line, cyan rings = trail edges at +10 m). With `--markers` (folder exported with `--export-markers`) it
compares projected marker positions against detected magenta blobs and prints pixel error.
