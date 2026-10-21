# Road and Terrain stage (P0 road surface + P1 terrain)

Builds engine-neutral road and terrain geometry from [`route.json`](ROUTE_SCHEMA.md) only — no engine, no scene.
Code: [`tools/road_terrain.py`](../tools/road_terrain.py) (stdlib Python). Tests:
[`tools/test_scene_package.py`](../tools/test_scene_package.py).

```bash
python3 tools/road_terrain.py build export/packages/weissensee_rolling_hills --tile-m=500
```

```bash
python3 tools/road_terrain.py validate export/packages/weissensee_rolling_hills
```

`build` refuses an invalid route.json, writes the tiles + `manifest.json`, then validates (`validation.json`).

## 1. Generation order

1. **Route centreline** — the route samples (`x, y, z` with physical `y`).
2. **Boundaries** — left/right edge at `±width_*_m` along `left = (−cos h, 0, −sin h)`.
3. **Playable surface** — one row of 3 vertices per route sample (right edge, centre, left edge), all at the
   route's `y`: flat across, exactly the route grade along. One glTF primitive per `surface_type`
   (material `road_<surface_type>`).
4. **Terrain** — one grid per side, starting **on** the road edge vertex and running outward
   (`columns_m`: 0, 0.6, 2, 5, 10, 20, 35, 60, 100, 150 m beyond the edge).

Vegetation, buildings and props are not generated here.

## 2. Physical route vs visual terrain

| Physical route (from route.json, never changed) | Visual terrain (`manifest.visual_terrain`) |
|---|---|
| distance `s`, elevation, grade, heading, curvature, widths, surface | hills (2-octave value noise, `hill_amplitude_m`, `hill_wavelength_m`, `seed`) |
| road mesh = samples + lateral offsets at route height | `vertical_exaggeration` (defaults to route `visual.vertical_exaggeration`) multiplies the relief only |
| terrain edge vertex = road edge vertex | relief is 0 within `flat_band_m` (3 m) of the edge, full from `blend_to_m` (60 m) |
| | verge drops `shoulder_drop_m` (5 cm) over the first 0.6 m (drainage look) |

Terrain height at offset `d` beyond the edge: `y_road − shoulder_drop · smoothstep(0, 0.6, d) +
relief(x, z) · smoothstep(flat_band, blend_to, d)`. Relief depends only on world `(x, z)`, so neighbouring tiles
agree on their shared row. On the inside of a bend the terrain reach is limited to
`max_inner_reach_of_radius` (0.7) × radius so offset rows never cross (fold).

## 3. Package layout written

```
<package>/
  route/route.json          input (authoritative)
  manifest.json             layers, visual_terrain parameters, tile index
  tiles/NN/road.glb         playable surface for from_s..to_s
  tiles/NN/terrain.glb      ground from the road edges outward
  validation.json           last validation report
```

GLB: glTF 2.0, one node per file whose `translation` is the tile `origin` (vertices are local → float32 keeps
sub-millimetre precision far from the world origin). Attributes: `POSITION`, `NORMAL`, `TEXCOORD_0` (road:
`(u, s)` metres; terrain: world `(x, z)` metres), and per vertex `_ROUTE_S` (route distance of the row) and
`_ROUTE_U` (lateral offset, + left) — glTF application-specific attributes that runtimes may use for player
positioning on the mesh or ignore. Materials are PBR intent by name; runtimes substitute their own.

The road mesh is suitable as a collision mesh as is (closed strip, front faces up, no gaps between rows or tiles).
Player positioning and progress still come from route.json (`s`, lateral offset), not from the mesh.

### Tile record (`manifest.tiles[]`)

```json
{
 "id": "03", "from_s": 1500.0, "to_s": 2000.0,
 "bounds": {"min": [1393.15, 1.52, 267.334], "max": [1985.393, 67.711, 617.079]},
 "origin": [1433, 26, 434],
 "files": {"road": "tiles/03/road.glb", "terrain": "tiles/03/terrain.glb"},
 "road": {"surfaces": [{"surface_type": "dirt", "from_s": 1500.0, "to_s": 2000.0}],
          "width_left_m": [0.45, 0.7], "width_right_m": [0.45, 0.7], "grade_percent": [1.0, 5.0], "rows": 501}
}
```

Tiles split at sample distances closest to multiples of `--tile-m` (default 500 m; 250–500 recommended); a last
tile shorter than a quarter joins the previous one. Neighbouring tiles share the boundary row (`to_s` of one =
`from_s` of the next), so the seam is the same vertices on both sides.

## 4. Validation

| Check | Tolerance |
|---|---|
| route.json valid ([ROUTE_SCHEMA §4](ROUTE_SCHEMA.md)) | — |
| tiles cover `0 … total_length_m`, contiguous (no road gaps / overlaps) | 1e-6 m |
| every route sample in a tile has a road row; every row pair has its triangles | exact |
| road vertex = route centre + `left · u` (horizontal) | 1 cm |
| road elevation = route `y` | 1 cm |
| road edge offsets = `width_left_m` / `width_right_m` | 1 cm |
| road slope between rows = route grade | 0.5 pp |
| road and terrain triangles face up (no flips, no folded terrain) | exact |
| terrain meets the road edge at road height; no terrain vertex inside the road band | 1 cm |
| geometry inside the tile's recorded bounding box | 1 mm |
| seams: shared boundary rows identical in both tiles (road and terrain) | 1 mm |
| probes at start (s = 0, start.s), middle (L/2), end (finish.s, L): road height under the route point at −0.8·width_right, 0, +0.8·width_left = route `y`; mesh grade over 5 m = route grade | 1 cm / 0.5 pp |

The probes find the road triangle under a point (as a runtime would for collision / player placement), independent
of the `_ROUTE_*` attributes.

## 5. Test packages (generated, in `export/packages/`, not in git)

| Package | Source | Length | Tiles | Result |
|---|---|---|---|---|
| `weissensee_rolling_hills` | `MainScene_weissensee.tscn`, course `rolling_hills` (dirt / gravel / asphalt / concrete, widths 0.45–4 m, grade 0–5 %) | 5000 m | 10 × 500 m | VALID — max road error 0.00002 m position, 0.0000 m elevation / width, slope ≤ 0.13 pp, seams ≤ 0.00003 m, 20/20 start/middle/end probes OK |
| `alpine_summit` | `MainScene_alpine.tscn`, course `summit` (trail, grade 0–8 %) | 7500 m | 15 × 500 m | VALID — slope ≤ 0.05 pp, seams ≤ 0.00003 m, 20/20 probes OK |

The slope residual (≤ 0.13 pp) is at program grade changes, where the chord between two rows differs from the
central-difference grade at the rows; elevation itself matches exactly.

Both road and terrain GLBs import without errors in Godot's glTF importer (`GLTFDocument`).
