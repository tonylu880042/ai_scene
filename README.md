# Coastal Virtual Run (Godot 4)

First-person virtual-run scene for treadmill sessions: a generated coastal harbour path at a fixed pace
(6:00 min/km), with the route's elevation following one of 12 treadmill programs (`programs.json`).

## Run
1. Fetch the CC0 assets (Poly Haven models and textures, ~100 MB): `python3 tools/download_assets.py`
2. Open the folder in Godot 4.3+ (developed on 4.7) and let it import, or from a terminal:

```bash
godot --path . -- --course=speed_lab
```

Options after `--`: `--course=<name>` (see `programs.json`), `--start-min=N`, `--quit-at-end`, `--no-hud`
(scene only: no text, minimap or gate banner text).

Keys: Tab auto/manual run, WASD + mouse in manual mode, F1 hide HUD, F11 fullscreen, Esc release mouse.

## Layout
- `scenes/` - `MainScene.tscn` (coastal harbour), `MainScene_alpine.tscn`, `MainScene_garda.tscn` (Lake Garda), `Player.tscn`;
  `scenes/legacy/` holds the earlier prototype stages (kept for reference, no longer maintained).
- `scripts/` - `route.gd` builds the route, terrain and road from a program; `course_setup.gd` applies the scene template
  and time of day; `FoliageSpawner.gd`, `Boardwalk.gd`, `Buildings.gd`, `AlpineProps.gd`, `Pedestrians.gd`, `Gates.gd`
  dress the route; `hud.gd`, `minimap.gd` are the HUD.
- `shaders/` - terrain, trail, grass, water, sky and cloud shaders.
- `data/` - `programs.json` (treadmill programs), `courses*.json` (scene template per course), `garda_sections.json`
  (Garda scene sections and landmarks along the reference video).
- `tools/` - asset/terrain fetchers, Unity export (`export_unity.gd`, `unity/`), course recording and older experiments.
- `assets/`, `video/` (private references) and the outputs `export/`, `export_unity/` are not in git.

Assets: Poly Haven (CC0).

## Alpine scene extras
- Real backdrop terrain: `python3 tools/fetch_real_terrain.py` (default: Jungfrau region, 24 km). Attribution
  required: elevation from AWS Terrain Tiles (https://registry.opendata.aws/terrain-tiles/, see its source
  attributions); orthophoto (c) swisstopo (SWISSIMAGE).
- HDRI sky: Poly Haven `kloofendal_48d_partly_cloudy_puresky` (CC0), 8K `.hdr` in `assets/hdri/` (fetched by `tools/download_assets.py`).
- Film-quality recording: `EXPORT_EXTRA=--hq tools/export_course.sh alpine summit 10 2`.
