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

## Small-radius paths and coastal terrain

The shared builder preflights the entire road corridor before writing tiles. A concave cell may use the other
quadrilateral diagonal; a crossing offset corridor raises an error rather than reversing / removing triangles.
Terrain reach is also capped at the intersection of adjacent road-edge outward rays. This can be less than the
old 0.6 m minimum verge on the inside of a narrow hairpin. Neither operation edits the canonical route or widths.
`curvature_window_m` optionally changes the conservative curvature window (default: the 150 m terrain extent).
Short coastal paths may use 3 m together with the exact ray cap; every resulting tile must still validate.

`--terrain=<json>` accepts the normal terrain options plus `coast_profiles`: records with `from_s`, `to_s`,
`side` (`left` / `right` / `both`), `water_edge_m` (from centreline), `water_level_m`, optional `bank_width_m`,
`sand_width_m` and provenance. The authored bank descends outside the road edge to 0.8 m below the water level.
An explicit narrow seawall can descend within the procedural relief's 3 m flat band. The edge stays exactly on the
road; the road GLB is byte-identical with or without the coastal profile. This is an estimated shoreline model,
not a DEM replacement. Profiles and their provenance remain in `manifest.visual_terrain`.

Experimental `coastal_waterline_anchors` inserts roots of the existing coast-height function inside each
row's existing reach, retains the authored columns, and connects neighboring roots through local
retessellation. Tile endpoints use splits on the legacy cross-section instead of changing the shared
boundary height; these are reported separately from water-level roots. No road, grade or reach is changed.
`coastal_exact_sand_boundary` splits the authored `abs(u) > water_edge_m - sand_width_m` material band in
local route coordinates, restores barycentric actual positions, and checks actual float32 face validity.
Support primitives keep their indices/materials. Both options default false.

The Gold Coast r35b experiment rebuilds only terrain46/49 and records that scope explicitly; it does not
enable the options globally in a copied manifest. It passes technical seams and serialized-face checks,
but remains **unadopted**: retaining legacy endpoint cross-sections beside refined interior roots produces
visible waterline-width steps against legacy neighbors. Shared mesh continuity below 1 mm is insufficient
to establish shoreline-contour continuity. See
`export/gold_coast/review/coastal_sampling_r35b_luna6/parent_review.md` before using these options.

R36 adds optional `coastal_waterline_anchor_range_m: [start_s, end_s]` and
`coastal_waterline_anchor_seam_mode: "analytic_level"`. The range gates root creation independently of
the coast-height profiles; it must fit inside the route and requires `coastal_waterline_anchors: true`.
The seam mode keeps endpoint roots at water level in both adjacent tile copies, so a connected rebuild
does not alternate between refined interior contours and coarse endpoint contours. Its default remains
`"preserve_cross_section"`; anchor generation and exact sand classification still default false.
Every affected neighbor must use the same endpoint policy. Check outer boundaries and profile transitions
as well as interior seams; stopping a rebuild at the next legacy boundary can relocate the defect.

Gold Coast's retained local r36 rebuild covers tiles44–52, with roots limited to11206.2812–13104.7827m.
The boundary at11000m remains outside the root range and retains its old cross-section. All nine default
rebuilds first reproduce the retained base terrain and roads byte-for-byte. Sol's actual serialized contour
and native boundary guards confirm the cross-tile width steps are removed. Existing abrupt authored
profile changes and a small terminal spur remain separate unresolved issues; whole-scene acceptance is
still0/24. See `export/gold_coast/review/coastal_sampling_r36_luna6/parent_review.md` for the retained scope.

R38 adds `coastal_waterline_capped_exit: true` (default false), requiring waterline anchors, an explicit anchor range and `analytic_level` seam mode. For an analytic root reachable in one row but beyond the adjacent row cap, the generator solves where the existing profile reaches water level on the original cap edge. It constrains the existing zipper triangles along root→cap exit, interpolates XZ/S/U on their original edges, and puts only new cut points at the existing water level. Original grid positions remain, including original unused records when a level split is required. Positive fragments survive regardless of area; negative winding raises an error. Only identical active profiles are joined; profile corners are not blended. Roads, grade, reach and water-level parameters are unchanged.

Gold Coast r38 changes terrain49/52 at six transitions and removes the terminal beak after20 native comparisons and159 Python checks. The separate repeated-corridor water opening remains unresolved. Partial rebuild provenance records full effective options and transplanted tiles: compare enabled against the same full disabled generation to identify a new flag's delta, then byte-check the approved frozen-package scope. An older partial package need not equal an unrelated full regeneration outside that scope. Evidence: `export/gold_coast/review/capped_waterline_r38_luna6/parent_review.md`.

An opt-in `overlap_priority: true` coast profile may also declare a finite `max_distance_m`. The terrain stage
uses only that profile's own generated coast triangles as a world-space P1 surface envelope for overlapping
terrain from other route spans. It clips the envelope to the profile s/lateral limits and actual own-terrain
coverage, leaves a 2 cm vertical separation by default, and conservatively omits envelope facets that intersect
a foreign P0 road footprint plus the configured safety clearance. No other profile participates by default;
water itself does not fill missing P1 geometry. The report is stored in `manifest.coastal_ownership`.
Where only a local camera view supports ownership, optional `ownership_from_s` / `ownership_to_s` bounds further
restrict the profile's envelope along the owner's route; they do not alter the authored shoreline profile itself.
The bounds and provenance should identify the evidence-backed view window, and keep adjacent route spans outside
the override unless they have their own evidence.

`tools/build_coastal_layers.py profiles` derives this input from a timestamped coastal section brief and an
already finalised route. Its `semantics` mode runs only after P0/P1 validate, producing P2 zones and P4 hints.

### Global road clearance (loops / revisited paths)

`tools/terrain_clearance.py` indexes every physical road triangle in world XZ. Each terrain triangle is clipped
against nonadjacent road footprints wherever it would lie within 2 cm below, or above, the foreign road plane.
Lower ground underneath a bridge may remain. Road vertices, distance, elevation, widths and grade are unchanged.
Clip intersections interpolate `_ROUTE_S` / `_ROUTE_U`; terrain is now indexed topology, not an implicit full grid.
Only zero-area clip-boundary contacts at float32 precision are omitted, never folded road triangles.

Validation checks every canonical row at the centre and 80% of both half-widths against **all** terrain tiles.
`validation.json.global_road_clearance` reports blocked probes, maximum height excess and the offending source
traversal. The 1 cm road-clearance tolerance is independent of the unchanged 1 mm seam tolerance. Seam comparison
uses actual boundary polylines / holes; differently subdivided collinear boundaries need not have equal vertex counts.
A clipped seam vertex is compared to the interpolated canonical elevation at its exact `s`, not the next sample.

Regression fixtures in `tools/test_terrain_clearance.py` cover two nearby legs at different elevations, injected
occluding terrain, a tree through another traversal and a building footprint occupying another road. Ground and
object consumers must read shipped indices; reconstructing the old grid would incorrectly fill the clipped holes.

### Grade transitions outside the road

Optional `road_transition_m` (default 0; Gold Coast: 8 m) builds reference planes outward from each physical road
edge. `road_max_bank_grade` is the dimensionless **cross-slope limit for visual P1 banks** (0.25 = 25%); it does
not limit, smooth or exaggerate the canonical route's longitudinal grade. Near a different traversal, a high
terrain polygon is split at the transition boundaries and lowered onto those planes. Low terrain and water are
not raised. Each source road edge stays pinned, with a 0.6 m weight band beyond it; inside-bend extent is still
limited to valid terrain reach. Physical road geometry always takes precedence where edges compete.

`manifest.tiles[].bank_transition` records modified triangle counts / lowering. Sampling only the road centre is
insufficient for first-person viewing: also inspect the verge at edge + 0.05, 0.5, 1.5 and 3 m and render the steepest
climbs, descents and tight turns. Vegetation / structures must be regenerated after this P1 change.

The shared preview camera shortens its 8 m lookahead on tight bends (approximately 0.25 rad of heading change,
minimum 0.75 m). This prevents its gaze from cutting across the inside terrain while keeping its position exactly
1.65 m above the canonical route. `godot --headless --path . --script tools/test_package_camera.gd` is a
self-contained bend / grade camera regression; it creates and deletes its own temporary fixture.

### Optional neighboring-road preview loading

The reference preview accepts `--spatial-geometry-radius-m=150`; its default is0. Logical station-window terrain
and scenery retain their original loading rules. Only additional manifest-referenced **road** meshes are loaded
by horizontal distance to tile bounds. Additional terrain can conceal an already-correct shoreline, so it is not
included. No extra vegetation or structures are scattered.

The Godot-only `scripts/package_road_mask.gd` subtracts active road footprints from those extra roads. It clips in
a per-triangle local frame and interpolates source-local mesh positions/attributes, avoiding large-world float32
slivers. Active logical road meshes/materials and every package file remain unchanged. Membership changes remask
cached originals; unchanged membership reuses the result. The preview explicitly uses0.35m display-ownership
tolerance for the sampled reverse-traversal profile discrepancies, not a physical elevation correction or proof
that overlapping paths share a real-world layer. Separate3m levels and varying-height crossings have fixtures.

This remains opt-in because synchronous tile changes still have material latency. Fixed-view native evidence and
remaining source/scene limitations are recorded in `docs/gold_coast_world.md`; a passing renderer fixture does not
establish source correspondence, physical road-level identity, FPS, or full-scene visual acceptance.

### Material-only local terrain classification

`python3 tools/road_terrain.py materials <package> <authoring.json>` applies optional P1 appearance overrides
without rebuilding terrain. Each authored band is grounded in already-shipped owner-terrain triangles, limited by
route `s`, side, and lateral interval. The default `boundary_mode: "centroid"` classifies target triangle centroids
in world XZ and only regroups terrain primitives/material indices; positions, normals, route attributes, bounds,
and indexed triangle topology remain unchanged. No road mesh/material is touched. A missing owner surface is an
error; omitted overrides are a no-op. Provenance belongs to authoring data and the manifest records the rebuild
command and counts.

Opt-in `boundary_mode: "exact"` (alias `"exact_triangle_clip"`) clips the owner mask at its route-relative bounds
and splits target faces at the projected world-XZ boundary. It preserves the original vertex prefix and
barycentrically interpolates new vertex attributes on the original piecewise-planar surface. Topology therefore
changes; serialized surface/coverage differences must be quantified separately from legacy byte-equality checks.
Correctly wound nonzero float32 facets survive regardless of area; collapsed or precision-flipped fragments are
accounted for explicitly. Road geometry, physical route/elevation/grade, and authored support-skirt materials
remain unchanged. The r30b S19 apron example is `data/gold_coast_s19_paved_boundary_r30b.json`; its estimated extent
and provenance do not establish source-time/camera registration or whole-scene visual acceptance.

The S18 sand authoring file is `data/gold_coast_s18_sand.json`: a video-estimated/procedural appearance band on
the right from s=8823–8900 m, lateral 1.2–7 m. This starts just outside the 1.2 m canonical road half-width and
does not alter the existing coastal height profile, ownership mask, or shoreline geometry. See the review
evidence linked from `docs/gold_coast_world.md`; the source frame remains private local evidence and is not a
texture or package asset.
# Visual appearance overrides

The Godot `PackagePreview` adapter can optionally apply authored visual material overrides to selected route-s intervals and existing road `surface_type` values for review. These overrides are renderer-only and do not change package surface classification, gameplay friction, or road/terrain geometry. The S17–S19 Gold Coast compacted-sand probe is recorded in `docs/gold_coast_world.md` and `export/gold_coast/review/s17_s19_sand_material_luna6/`; it is not yet a portable package material contract.


### Estimated local land continuity (explicit opt-in)

`tools.road_terrain.apply_land_infill(package_dir, authoring)` appends estimated P1 within authored convex
world-XZ ROIs. `schema_version: 1`, `estimated: true`, an estimated provenance/rationale, a target tile, a
material and a bounded `boundary_supported_idw` height rule are required. The default complement excludes
all manifest-referenced serialized P1 and P0 footprints; it is not a water-plane fill or an inferred surveyed
land mask. Current example: `data/gold_coast_shore_infill_r42c.json`. No existing build/CLI default invokes it.

Boundary heights prefer the target owner/layer and use explicit foreign fallback IDs only when allowed.
Unsupported interior/decomposition vertices use bounded deterministic inverse-square IDW; their heights remain
estimated. Cross-owner disagreements are diagnostic and never averaged. New normals are recomputed on the
patch. Original terrain attributes/oriented faces remain exact prefixes, and route/road/grade are untouched.
The manifest records input hashes, support selection, source/packed/emitted areas and nonzero float32
collapse/intersection ledgers. Neither area sums nor finite positive faces establish visual seam acceptance.

Optional `route_attribute_chart: {"kind": "target_road_affine", "max_distance_m": 0.02}` corrects only
appended terrain S/U near the target road. Distance selects a target-road face; unrestricted barycentrics
are evaluated at the original XZ point, without snapping positions or clamping U. This is the road mesh's
piecewise affine chart, not an exact inverse of the interpolated analytic heading frame. It never copies a
foreign traversal's S/U. Gold Coast R42c fixes297 such records;7technical stages pass, while source acceptance
and remaining visible openings are still unresolved. Its frozen review is under
`export/gold_coast/review/shore_metadata_r42c_luna6/`.

The Godot reference adapter disables lossy mesh compression when loading `road.glb` and `terrain.glb`, retaining
default imports for other assets. Controlled direct imports show millimetre coordinate changes from default
compression in sampled faces; disabling it leaves only ordinary engine float32 world arithmetic. This is
an adapter precision policy, not a change to package coordinates or physical grade. See the official
[GLTFDocument import flag](https://docs.godotengine.org/en/stable/classes/class_gltfdocument.html#enum-gltfdocument-importflags)
and `tools/test_package_gltf_precision.gd`. No Unity Editor verification is implied.

An explicit region `terrain_coverage_owner_ids` can restrict P1 subtraction and terrain support to a
declared current visit. P0 subtraction and road support still include every package owner. This requires
`support_owner_policy` declaring selected terrain/all-package P0/excluded foreign terrain and provenance
for the coverage choice. Omission preserves the original all-P1 complement. R44 uses owners47–52;
its intentional overlap with foreign03 P1 is about0.660615m² in serialized face-pair intersections.
This policy does not enable global terrain loading or copy foreign route attributes.

Optional `height_rule.terrain_support_chart.kind: canonical_route_local` resolves conflicting selected
same-owner/layer P1 hits only when their height spread exceeds the existing2mm limit. At unchanged XZ,
serialized face S/U must match the target canonical polyline projection within explicit station/lateral
windows (R44:1m/0.05m); route branches separated by5m station require a centerline-distance margin
greater than20mm. Selected hits still satisfy2mm. A missing chart match fails unless an existing P0
support permits the declared road fallback; ambiguous branches fail. Sole or already-consistent P1
support retains its actual face height, recording off-chart deltas without an IDW replacement.
The default build is unchanged. These are estimated local continuity choices, not repaired physical
survey data. Frozen R44 evidence: `export/gold_coast/review/visit_shore_r44_luna6/`.

`height_rule.support_edge_sample_spacing_m` optionally adds height-support samples by linear interpolation
along existing selected P1 and all-package P0 triangle edges. Zero or omission retains the original vertex-only
support pool; a positive finite spacing must not exceed `max_estimated_support_distance_m`. Edge samples do
not change the fill footprint, original faces, direct-hit support, or the road exclusion. Reverse copies of
the same edge are deduplicated, distinct S/U charts remain separate, and inconsistent same-chart heights
fail the existing mismatch bound. In edge-sampling mode an IDW estimate requires the configured number of
distinct support records within the existing distance bound. These interpolants derive from the existing
mesh; they are not independent measurements. R47 uses a 1 m spacing for two estimated Gold Coast land
patches. The previous R44 authoring reproduces its 280 package files byte-for-byte with this option omitted.
Distinct chart records can still both be chosen by the current same-owner IDW neighbor pool: the direct-hit
chart selector does not filter interior IDW samples. A read-only R47 audit found 11 of 95 pre-emission IDW
vertices whose four samples span at least 5 m in station, with maximum sample-height spread 0.941 m. This
indicates an unresolved branch-attribution risk, not proof that each resulting estimated height is wrong;
see `export/gold_coast/review/shore_idw_r52_sol/parent_review.md`.

### OSM-measured shoreline spans (partial P1 rebuild)

`python3 tools/osm_context.py fetch-water <package> <water.json>` caches OSM `natural=coastline` / `natural=water`.
`python3 tools/osm_context.py shoreline <package> <water.json> <from_s> <to_s> <out.json>` replaces every coast
profile inside the span, on both sides, with 2 m chunks whose `water_edge_m` is the first OSM water along the route
normal (0.5 m steps, median of 3); chunks with no water within 150 m become land (no profile). Profiles outside the
span keep their values (straddling ones are clipped). The bank / underwater shape stays the estimated profile model.
OSM coastlines are generalised: near video-evidenced seawalls (e.g. S02, 2.4 m) they can be several metres off, so
use a span only where OSM is corroborated (here: OSM buildings standing on estimated P1 water).

Rebuild procedure (Gold Coast r49): run `road_terrain.py build --tile-m=250` with the package's own
`visual_terrain` as a control and confirm the target tiles reproduce byte-for-byte; rebuild with the new profiles,
confirm only the target tiles' `terrain.glb` changed and every `road.glb` is identical, transplant those tiles, then
`python3 tools/vegetation.py resettle <package> <tiles>` and `python3 tools/structures.py resettle <package> <tiles>`
re-ground P3 / low-medium P4 on the new terrain and drop what now stands on water (high-importance objects are never
moved). Provenance: `manifest.osm_shoreline_partial_rebuild`. Evidence: `export/gold_coast/review/osm_shoreline_r49/`.

Optional `water_far_m` on a coast profile makes it a **water band** (creek / channel): water from `water_edge_m` to
`water_far_m`, land rising again beyond it over `bank_width_m`, sand on both banks. Without it a profile is unchanged.
`shoreline` sets it from the first OSM water interval and smooths near/far edges over 5 chunks (10 m) so the waterline
does not flip between terrain columns; banks still cannot be finer than the 15–25 m column spacing at 20–60 m.
Where an original two-sided (bridge) profile covers a route above 5 m (deck and ramps), the estimated open-water
profile is kept: terrain follows the deck height, so a narrow measured band would form a trench under the bridge.
`coastal_exact_sand_boundary` rejects water bands.

After the P1 transplant, `osm_context.semantics_from_coast` rebuilds P2 grass / water / vegetation_zone per 10 m inside
the spans from the shipped profiles (grass to the water, water to the band's far edge, grass beyond; tree zones keep
their video species / density and reach at most 40 m or 1 m short of the water), `vegetation.regenerate` refreshes
only the P3 zones derived from replaced semantic zones (new zone ids appended; all other instances untouched),
`structures.resettle` also drops low / medium point objects now in P2 water, and `vegetation.remove_in_boxes` clears
P3 instances under P4 footprints. Gold Coast r50 applies this to s 2260–2740, 5090–5690, 6890–7485 and 10260–10990
(tiles 09, 10, 20–22, 27–29, 41–43; every road.glb identical); evidence `export/gold_coast/review/osm_shoreline_r50/`.
