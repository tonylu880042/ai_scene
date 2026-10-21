# AI Scene Player (Unity MVP)

AI Scene Package → playable Unity world. Unity is a **consumer**: it loads a package
(`export/packages/<id>/`, see `docs/AI_SCENE_PACKAGE.md`) and never generates or edits scene data.

## Open and run

1. Unity 6 (6000.0 LTS) → Hub → Add project from disk → `unity/AIScenePlayer`. Packages resolve from
   `Packages/manifest.json` (Newtonsoft JSON, Splines, Input System, Test Framework).
2. New empty scene → **AI Scene → Create Player In Scene** → Play.
3. Package: the component's `packagePath`, else `-aiscene-package <dir>` / `AISCENE_PACKAGE`, else
   `../../export/packages/weissensee_rolling_hills` relative to the project (generate it with the Python stages).

Keys: **W / S** (↑ / ↓) speed, **A / D** lateral within the road, **Space** pause, **PgUp / PgDn** ±250 m,
**Home** restart, **F1** HUD, **F3** route lines.

## What it does

| Requirement | Where |
|---|---|
| manifest.json, route.json | `AIScenePlayer` (via `AIScene.Core`) |
| route as Unity Spline | `RouteSplineBuilder` (SplineContainer, knot every 10 m). Gameplay uses the canonical `RouteData`; the spline is derived and its deviation is checked |
| geometry tiles, streaming by distance | `TileStreamer`: tiles overlapping [s − 150 m, s + 600 m], GLB parsed off the main thread by the core reader, road MeshCollider |
| environment | `EnvironmentLoader`: sun direction / colour / intensity, fog, ambient, HDR sky (decoded by the core), distant DEM terrain + water following the runner |
| vegetation, LOD, culling | `VegetationRenderer`: `Graphics.RenderMeshInstanced` per prototype and LOD, 64 m cells frustum + distance culled, per-instance prototype cull distance, `Lod.Level` from prototypes.json; placeholder meshes per category (`PlaceholderPrototypes`) |
| test player, keyboard speed | `RouteFollowerBehaviour` (core `RouteFollower`: speed along the surface, `ds = v dt / √(1 + grade²)`) |
| debug info | `DebugHud`: distance, speed (km/h, pace), elevation, **grade from route.json**, tile, streaming, vegetation counts, validation |
| route debug lines | `RouteDebugDraw`: centreline, edges, tile boundaries, start / finish, checkpoints |
| validation | `PackageValidator` (core, Unity space) at load + `RuntimeValidator` live checks |

Grade and elevation shown and used are always `route.json` samples at the player's `s`; the camera pitch is only
a view of the road ahead.

## Code layout

```
Assets/AIScene/Runtime/Core/     AIScene.Core: no UnityEngine; package models, RouteData, Frame (glTF -> Unity axes),
                                 GlbMesh reader, TileStreaming / Lod / InstanceGrid, RouteFollower, HdrImage, PackageValidator
Assets/AIScene/Runtime/Unity/    AIScene.Runtime: MonoBehaviours above
Assets/AIScene/Editor/           menu items, batch validation
Assets/AIScene/Tests/Core/       NUnit tests of the core (Unity EditMode and dotnet)
Assets/AIScene/Tests/PlayMode/   drives 1.5 km and checks what Unity built
../CoreTests/                    dotnet project compiling the core + its tests outside Unity
```

Axes: the package frame is glTF (right-handed, X east, Y up, Z south). `Handedness.NegateX` (glTFast's rule) maps
it to Unity: positions (−x, y, z), rotations (x, −y, −z, w), triangle winding reversed, texture v flipped. The
validator confirms travel-left stays Unity-left.

## Verification status

- **Verified here (no Unity editor on this machine):** the core compiles and its tests pass under .NET 10 against
  `export/packages/weissensee_rolling_hills`:

```bash
dotnet test unity/CoreTests
```

  Unity-space results: position → route distance 1.6 mm, elevation exact, world slope vs grade 0.001 pp, road
  mesh vs grade ≤ 0.13 pp, tile seams 0.03 mm, streaming lead time 33 s at 54 km/h, 29,502 vegetation instances
  ≥ 0.31 m (grass) / 1.51 m (trees) from the road edge; a tree moved onto the road and a too-short streaming
  window are both reported.
- **Not yet run in Unity:** the `AIScene.Runtime` MonoBehaviours, the HUD, GPU instancing, the sky rotation
  (`EnvironmentLoader.skyRotationOffsetDeg` if the sun disc is not behind the light) and the PlayMode test. Run
  `Window → General → Test Runner` (EditMode + PlayMode) or:

```bash
Unity -batchmode -projectPath unity/AIScenePlayer -runTests -testPlatform PlayMode -testResults playmode.xml
```

## Not in this milestone

Multiplayer, smart-trainer BLE / FTMS, treadmill integration, race ranking, production UI, structures rendering
(`structures/` is not drawn yet), real prototype meshes (placeholders by category), URP/HDRP-specific water and sky.
