# ai_scene Architecture

Status: **proposed** (2026-10-21). Describes the target system and how today's code maps onto it.
Format details are in [AI_SCENE_PACKAGE.md](AI_SCENE_PACKAGE.md); the step-by-step path is in
[MIGRATION_PLAN.md](MIGRATION_PLAN.md).

## 1. System definition

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ INPUTS                                                                        │
│  Reference video · Geographic data (OSM, DEM, GPS/GPX, orthophoto)            │
│  AI analysis (frame segmentation, section/landmark extraction, checklists)    │
│  Authoring parameters (sections files, programs, templates)                   │
└──────────────┬────────────────────────────────────────────────────────────────┘
               ▼
┌───────────────────────────────┐   P0 route / road geometry
│ ROUTE & TERRAIN RECONSTRUCTION│   P1 terrain / elevation
└──────────────┬────────────────┘
               ▼
┌───────────────────────────────┐   P2 near-road spatial structure
│ ENVIRONMENT RECONSTRUCTION    │   P3 vegetation · P4 buildings / landmarks / props
│                               │   P5 distant environment · P6 atmosphere
└──────────────┬────────────────┘
               ▼
┌───────────────────────────────┐   engine-independent, versioned, validated
│ AI SCENE PACKAGE  (contract)  │
└──────┬───────────────┬────────┘
       ▼               ▼
┌─────────────┐  ┌──────────────────────────┐
│ Unity       │  │ Godot (reference renderer│
│ production  │  │ / validation, temporary) │
│ runtime     │  └──────────────────────────┘
└─────────────┘
```

The package is the only thing that crosses the line between *scene generation* (left of the package) and
*game runtimes* (right of it). Generators may be written in any tool; runtimes may be any engine. Neither side
may require knowledge of the other's internals.

## 2. Priority order

| P | Layer | Owns | Accuracy source of truth |
|---|---|---|---|
| P0 | Route / road geometry | centreline, distance, heading, curvature, width, boundaries, surface, start/finish/checkpoints | GPS/GPX or OSM road geometry when available; video bend sequence otherwise |
| P1 | Terrain / elevation | route elevation profile and grade; ground surface around the route | DEM (e.g. IGN RGE Alti, AWS Terrain Tiles), GPS altitude, video HUD estimates, or a training program for synthetic routes |
| P2 | Near-road spatial structure | what borders the road on each side: shoulders, verges, ditches, walls, guardrails, cliffs, drop-offs, water edges, fences, junctions | video + map data |
| P3 | Vegetation distribution | species, density, placement of trees/shrubs/grass | video + land cover |
| P4 | Buildings / landmarks / props | individual structures and their placement | video + map footprints |
| P5 | Distant environment | backdrop mountains, far terrain, skyline, far water | DEM + orthophoto |
| P6 | Atmosphere / visual enhancement | sky, sun, fog, time of day, colour grading, post effects | video look |

Rules:

1. **Build in order, gate in order.** A layer is worked on only when every higher-priority layer meets its
   acceptance criteria for that section. A change to a lower layer that breaks a higher one is reverted.
2. **Accuracy beats similarity.** P0/P1 are judged by geometric and physical correctness (distance, elevation,
   grade, curvature, width), not by how a frame looks. Visual similarity is the acceptance criterion only for
   P2–P6, and never at the cost of P0/P1.
3. **Lower layers adapt to higher ones.** Terrain is shaped to the road (not the road draped on noisy terrain);
   vegetation and buildings are placed on the terrain and outside the road corridor; atmosphere never changes
   geometry.

## 3. The road is the gameplay backbone

The same route serves three products; all of them read the route, not the rendered scene:

| Product | Reads | Uses it for |
|---|---|---|
| Cycling | `s`, `grade`, `surface`, `curvature` | physics (gravity, rolling resistance), smart-trainer resistance |
| Running | `s`, `grade` | treadmill incline, pace/effort, difficulty |
| Racing | `s`, checkpoints, start, finish, lateral boundaries | progress, splits, ranking, lane/position limits |

Consequences:

- **Grade is physical.** It is the slope of the real (or designed) route surface: rise over horizontal run, from
  the canonical elevation profile. It is not a terrain shading property and not a visual effect. The rendered road
  surface must have the same slope the package reports.
- **Device mapping is a runtime concern.** Clamping to a treadmill's incline range, trainer-specific smoothing,
  "difficulty %" scaling, and safety limits belong to the runtime / device layer. The package stores the true grade
  only.
- **Distance is canonical.** Every runtime measures progress with the package's `s`. Two clients at the same `s`
  are at the same place.

## 4. Responsibilities and boundaries

### 4.1 Scene generation (upstream of the package)

| Component | Responsibility | Must not |
|---|---|---|
| Input acquisition | Fetch/cache DEM, OSM, orthophoto, GPS; extract video frames; record licences and hashes | Ship private video frames |
| AI analysis | Segment the video into sections, extract bends, roadside features, vegetation types, landmarks; produce a frozen checklist | Change a frozen checklist to pass acceptance |
| Route reconstruction (P0) | Produce the canonical centreline with distance, heading, curvature, widths, surface, checkpoints | Depend on terrain or visuals |
| Terrain reconstruction (P1) | Produce the elevation profile, grade, and ground surface consistent with the road | Put the ground above the road surface inside the corridor; inject noise into the road profile |
| Environment reconstruction (P2–P6) | Produce roadside structure, vegetation, buildings, backdrop, atmosphere as layer data + assets | Move or reshape the road; place objects in the road corridor |
| Package writer | Serialise all layers into the package format with provenance; run the validator | Emit engine-specific data (node paths, engine axes, shader names) as contract data |

Godot is currently the generator for all of the above (procedural scripts in `scripts/`). That is allowed as long
as its output goes through the package writer.

### 4.2 AI Scene Package (the contract)

- Engine-independent: open formats only (JSON, glTF 2.0 binary, PNG/JPEG/KTX2/EXR/HDR, raw float32 heightfields).
- Versioned (`schema_version`), self-describing (manifest), validated by an engine-free validator.
- Defines one world coordinate frame, units (metres, degrees, percent where stated) and interpolation rules.
- Carries provenance and confidence per layer.
- Layered by priority, so a runtime can load P0–P1 alone (e.g. a trainer app with a minimal view) and still be
  physically correct.

See [AI_SCENE_PACKAGE.md](AI_SCENE_PACKAGE.md).

### 4.3 Game runtimes (downstream of the package)

| Runtime | Role | Owns |
|---|---|---|
| Unity (production) | Primary runtime for cycling / running / racing | Package importer (axis conversion, glTF import, instancing, streaming, LOD), gameplay, avatars, physics, device control, networking, rendering quality |
| Godot (temporary) | Procedural generator, authoring environment, reference renderer, validation environment | Generators that write packages; a reader that renders a package for comparison against the video and against Unity |

Runtimes must not write back into the package or extend its meaning privately. Runtime-specific needs that
affect the contract become proposals to the package schema.

Unity-side work is owned by another team; this repository delivers the package plus reference adapter scripts
(`tools/unity/`) and documentation.

## 5. Invariants (checked by the validator)

1. `s` starts at 0 at the start line, increases strictly, and ends at the finish (`length_m`).
2. Centreline positions, heading, curvature and `s` are mutually consistent within tolerance.
3. `grade` equals the derivative of `elevation` over horizontal distance (with the declared smoothing), within tolerance.
4. Terrain height under the road corridor equals the road surface (within tolerance); terrain never rises
   above the road surface inside the corridor.
5. No vegetation, building or prop footprint intersects the drivable/runnable corridor
   (`-width_right … +width_left`), except objects flagged as on-road (gates, markings, crossings).
6. Checkpoints, sections and landmarks reference `s` values inside `[0, length_m]`.
7. Every external asset is present, glTF-valid, and has a licence/attribution record.

## 6. Current state vs target (summary)

| Topic | Today | Target |
|---|---|---|
| Route definition | `route.gd`: heading from sine bends or sections' `turn`; elevation = integral of a treadmill program's incline × `grade_scale` (1.5, visual exaggeration); `s` horizontal. Saisies: real OSM/DEM centreline with lat/lon, per-scene scripts | One canonical route per package with physical grade; any generator may produce it |
| Grade | Program incline (%) is the source; road geometry is 1.5× steeper | Grade is measured from the route surface; programs only *generate* synthetic profiles |
| Sections | Normalised `video_km` stretched to the course length | Ranges in metres of `s` |
| Unity delivery | `tools/export_unity.gd` → tiles + instances + `route.json` (x, y, z, half widths) + `environment.json` | Same assets reorganised into the layered package with canonical route and provenance |
| Validation | Godot rebuild of the export (`verify_unity_export.gd`), visual checklists | Engine-free schema + invariant validator, then visual comparison in Godot reference renderer |
| Coordinates | Godot/glTF Y-up; route starts along +X (generic) or route-forward frame (Saisies) | Package frame: X east, Y up, Z south (glTF-compatible), optional georeference |

## 7. Out of scope for the package

People, vehicles, avatars, HUD, audio, device protocols, network/racing state, and any engine runtime script.
These are runtime content. (Existing Godot preview features such as `Pedestrians.gd` and the HUD stay as they are
but are not exported.)
