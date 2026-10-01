# Virtual Run - alpine trail scene for Unity

Exported from the Godot project with `tools/export_unity.gd`. Scene only (no runners).
Coordinates are metres, Y up, world space; every tile lines up with the others and with `route.json`.

## Files
| File | What |
|---|---|
| `tile_XX.glb` | trail surface (dirt) + meadow ribbon + unique props (signposts, hut, cairns, start/finish gates) for one stretch of the route |
| `tile_XX_instances.json` | position / rotation / scale of every repeated object in that stretch (trees, grass clumps, flowers, rocks, pebbles, roots, fence posts/rails) |
| `prototypes.glb` | each repeated object's mesh + materials, once (child nodes named like the `proto` field in the JSON) |
| `backdrop.glb` | real terrain around the start (Jungfrau region: AWS Terrain Tiles + swisstopo SWISSIMAGE) and the sun light |
| `sky.hdr` | HDRI sky (Poly Haven, CC0) |
| `environment.json` | sun direction / colour, fog, ambient, tonemapping, camera, tile list |
| `route.json` | centre line every 1 m (x, y, z) and the trail half-widths |
| `VirtualRunScatter.cs` | Unity component that places the repeated objects |

## Import (Unity 2022.3 LTS or Unity 6, URP or HDRP)
1. Package Manager -> add `com.unity.cloud.gltfast` (glTFast).
2. Copy this folder into `Assets/`. glTFast imports every `.glb` as a prefab.
3. Drag all `tile_XX.glb` and `backdrop.glb` into the scene at position 0,0,0 (do not move or rotate them).
4. Drag `prototypes.glb` into the scene and **disable** it.
5. Add an empty GameObject with `VirtualRunScatter`: set `Prototypes` to the disabled prototypes object and add every
   `tile_XX_instances.json` to `Instance Files`. Keep `Conversion = NegateX` when the tiles were imported with glTFast.
   Check once that trees stand on the meadow next to the trail; if they are mirrored, switch to `NegateZ`.
6. Sky: create a material with `Skybox/Panoramic`, assign `sky.hdr` (Texture Shape 2D, HDR), set it in
   Lighting -> Environment. Rotate the skybox until the bright sun in the photo sits where the directional light
   comes from (start around `-sky.yaw_deg` from environment.json).
7. Light: the sun comes in with `backdrop.glb`; set its intensity/colour from `environment.json` (`sun`), soft shadows on.
   Ambient: sky. Fog: exponential, density/colour from `environment.json`. Post-processing: tonemapping (Neutral/ACES;
   the Godot look used AgX), exposure ~1.15, saturation ~1.25.
8. Camera: height 1.65 m above the route, vertical FOV 75, far clip 30 km (the real mountains are ~12 km away).

## Not exported (Godot-only shaders)
- Ray-marched cloud sea below the trail (`environment.json.cloud_sea`): use a Unity volumetric cloud layer
  (HDRP Volumetric Clouds) or a cloud-sea asset, ~17 m below the runner.
- Wind sway on grass, the ragged dirt/grass edge of the trail (exported as a clean dirt band), steep-slope rock blend.

## Credits / licences (keep with the product)
- Terrain elevation: AWS Terrain Tiles (see https://registry.opendata.aws/terrain-tiles/ for source attributions).
- Orthophoto: (c) swisstopo, SWISSIMAGE.
- Plants, rocks, textures, HDRI: Poly Haven (CC0).
