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
- `route.gd` builds the route, terrain and road from a program; `course_setup.gd` applies the scene template
  and time of day from `courses.json`.
- `FoliageSpawner.gd`, `Buildings.gd`, `Pedestrians.gd`, `Gates.gd` dress the route; `hud.gd`, `minimap.gd` are the HUD.
- `stage_0*.tscn`, `MainScene_island.tscn`, `coastal_path.gd` are earlier prototype stages kept for reference.

Assets: Poly Haven (CC0).

## Alpine scene extras
- Real backdrop terrain: `python3 tools/fetch_real_terrain.py` (default: Jungfrau region, 24 km). Attribution
  required: elevation from AWS Terrain Tiles (https://registry.opendata.aws/terrain-tiles/, see its source
  attributions); orthophoto (c) swisstopo (SWISSIMAGE).
- HDRI sky: Poly Haven `kloofendal_48d_partly_cloudy_puresky` (CC0), 8K `.hdr` in `assets/hdri/`.
- Film-quality recording: `EXPORT_EXTRA=--hq tools/export_course.sh alpine summit 10 2`.
