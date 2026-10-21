# AGENTS.md — ai_scene

ai_scene turns a reference video, geographic data and AI analysis into an **AI Scene Package**: an
engine-independent description of a route and its environment that game runtimes (Unity first) load for
cycling, running and racing.

```
Reference Video / Geographic Data / AI Analysis
  → Route and Terrain Reconstruction
  → Environment Reconstruction
  → AI Scene Package          ← the contract
  → Game Runtime (Unity; Godot as reference renderer)
```

Read before changing anything:

| Document | What it covers |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Stages, system boundaries, who owns what, invariants |
| [docs/AI_SCENE_PACKAGE.md](docs/AI_SCENE_PACKAGE.md) | The package format: canonical route, layers, coordinates, validation |
| [docs/ROUTE_SCHEMA.md](docs/ROUTE_SCHEMA.md) | Canonical `route.json` (implemented): fields, derivation formulas, validation |
| [docs/ROAD_TERRAIN.md](docs/ROAD_TERRAIN.md) | Road + terrain tiles built from route.json (implemented) |
| [docs/SEMANTICS.md](docs/SEMANTICS.md) | Near-route spatial semantics: route-relative zones that P3/P4 must consume (implemented) |
| [docs/VEGETATION.md](docs/VEGETATION.md) | Vegetation zones, prototypes and per-tile instances from the semantics (implemented) |
| [docs/STRUCTURES.md](docs/STRUCTURES.md) | Buildings, landmarks and route furniture with importance levels (implemented) |
| [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) | Distant terrain / water / skyline and atmosphere as data in environment.json (implemented) |
| [docs/MIGRATION_PLAN.md](docs/MIGRATION_PLAN.md) | KEEP / REFACTOR / ADAPT / REPLACE / RETIRE for every existing component, and the phase order |
| [unity/AIScenePlayer/README.md](unity/AIScenePlayer/README.md) | Unity runtime MVP that consumes a package (core tests: `dotnet test unity/CoreTests`) |
| [README.md](README.md) | How to run the existing Godot scenes |
| [.claude/skills/video-to-ai-scene/SKILL.md](.claude/skills/video-to-ai-scene/SKILL.md) | Video → AI Scene Package workflow (phases 1–9, adapters, pitfalls) — pending review |
| [.claude/skills/video-to-virtual-run/SKILL.md](.claude/skills/video-to-virtual-run/SKILL.md) | Previous Godot-centred workflow, kept until the new skill is reviewed |

## Rules

1. **Priority order is fixed.** P0 Route/Road geometry → P1 Terrain/Elevation → P2 Near-road structure →
   P3 Vegetation → P4 Buildings/Landmarks/Props → P5 Distant environment → P6 Atmosphere/Visuals.
   A lower-priority change must never degrade a higher-priority layer. Road and terrain accuracy beat visual similarity.
2. **The road is the gameplay backbone.** Route distance, elevation and grade are physical data used by cycling
   physics, trainer resistance, treadmill incline and race progress. Never scale, exaggerate or smooth grade for looks.
3. **The package is the contract.** Neither Godot nor Unity types, node paths, axes or file formats define it.
   Engine-specific conversion lives in engine adapters, never in the package.
4. **Preserve working functionality.** Existing Godot scenes, generators and the Unity export keep working until a
   replacement is validated. No large rewrites; migrate one component at a time (see MIGRATION_PLAN phases).
5. **Shared generators, not per-scene pipelines.** New needs become parameters of shared scripts
   (`route.gd`, `FoliageSpawner.gd`, `Buildings.gd`, …), not new `<scene>_*.gd` files.
6. **Provenance on every layer.** Record the source (DEM, OSM, GPS, video estimate, procedural) and whether a value
   is measured or estimated.

## Practicalities

- Godot 4.7 (`godot` on PATH), Python 3 (+ Pillow/numpy), ffmpeg. macOS: `sed -i ''`; prefer Python for edits.
- Not in git: `assets/`, `video/`, `export/`, `export_unity/`. Reference video frames are private: never ship them,
  never feed them into generated assets.
- Whole-package check: `python3 tools/validate_package.py export/packages/<id>`; stage tests (no engine): `python3 -m unittest tools/test_scene_package.py`.
- Commit only when asked.
