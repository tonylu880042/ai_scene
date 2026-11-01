# Known pitfalls, by pipeline layer

Lessons from the Godot scenes (coast, alpine, garda, winter, weissensee) and the Saisies reconstruction, placed at
the layer where they now apply. Adapter-only mechanics are in [adapters.md](adapters.md).

## Route (Phase 2)

- **Heading signs.** route.json: heading = compass bearing clockwise from north (−Z); curvature + = left. Godot
  `atan2(-x, -z)` is positive to the left. Cross-check any turn with `future_tangent · current_left > 0` = left.
  A tool that labelled a left bend "right" cost the Saisies S13 rounds.
- **Distance to the route** is the nearest *horizontal* segment. A 3D nearest with y = 0 picked another road
  section and reported 64 m clearance for an object touching the road.
- **Grade is physical.** Never exaggerate it for looks (that is `visual`); filter DEM noise in the elevation profile,
  not in grade; state grade limits / filters in `source`. Saisies clamped its profile to −18 … +3 %: check that a cap
  is not hiding real climbs.
- **Mirrored scenes.** route.gd's "left" is the seaward side; with `sea_right` it is travel-right.
  `tools/export_route.gd` swaps widths for that case.
- **Hairpins.** A bend radius below ~150 m folds offset terrain on the inside; split it over a longer section. The
  road/terrain stage clamps the inside reach and its validator flags folds.
- **Time anchors.** Use one canonical manifest of section times (S09 was once described at 360 s while its frame
  was at 330 s). Changing an anchor shifts neighbours.
- **Synthetic vs real.** OSM / DEM geometry does not make the time → distance mapping or camera right; if the public
  road does not match the video's bend sequence, keep the uncertainty and re-check the route, not the landmarks.

## Terrain (Phase 3)

- Ground height is the **displayed terrain triangle**, not a DEM interpolation or an intended function.
- **First-person slope clearance:** a clear road centre can still have a 2 m-high foreign bank just outside its
  edge. Probe the verge as well as the band; use shared P1 transition planes (`road_transition_m`,
  `road_max_bank_grade`) and preserve P0 elevation / grade. Regenerate objects on the changed ground.
- **Camera through the inside of a bend:** fixed 8 m lookahead can aim through nearby terrain on narrow hairpins.
  Shorten the rendering camera's lookahead according to curvature; do not stretch the route or raise the road.
- Terrain never above the road inside the band; it starts on the road edge vertex (shared position, not "close").
- Tiles share their boundary row; a seam is the same vertices twice, never a re-sampled neighbour.
- Do not flatten valleys or move mountains to hide an undiagnosed projection / camera error.

## Near-route semantics (Phase 4)

- A zone is a box with constant offsets: a feature whose distance changes along s is several consecutive zones.
- Take widths from every route sample in the zone (integer s) and its ends; a 1 m stride from a fractional start
  missed samples and let grass "intrude" into the band.
- Round offsets to the nearest centimetre, not outward: outward rounding made neighbours overlap by 2 cm.
- A scene-generator producer describes the scene as built (Weissensee S14: lake 7.8 m away in the scene, 1–3 m in the
  video). Mark the source; do not present it as video evidence.

## Vegetation (Phase 5)

- Nothing on the walkable band (`|lateral| < width + clearance`); large rocks ≥ 2 m off the path.
- A trunk origin on the ground does not prove the roots touch it (rendered check at the adapter: sample the
  indexed woody root bounds after the full transform, on the displayed triangle).
- Test exclusions with a small margin (1 cm) so rounding the written values cannot cross into water.
- Counting trees is not judging a forest: compare canopy height / width / overlap, forest-edge openings and the
  negative space of sky and valley.

## Buildings and landmarks (Phase 6)

- A generic mountain road instead of the recognisable start buildings failed Saisies S01: check landmark name, side,
  size and order before detail.
- Gate legs must clear barriers beside the path; bridges must span the road over their whole length (the path can
  widen inside the bridge's range).
- High-importance objects are never moved to make validation pass; fix the hint or the upstream layer.
- Rails / beams follow full 3D end points, posts local Y up; check uphill, downhill and a bend (rendered adapter).
- A rock wall needs foot, embedding, closed ends and relief joined to the slope, or it reads as a concrete wall.

## Distant environment and atmosphere (Phase 7)

- Real backdrops on synthetic routes follow the runner at the lake level and turn with the route direction smoothed
  over ±300 m; without that they stay at the start and their edges float later on.
- The shore side of a real DEM is often sunk where the near band takes over; the validator checks the runner is
  never inside the distant terrain.
- HDRI: the sun is where the photo has it — elevation fixed by the image, the sky rotated to the sun azimuth;
  record `sun_in_image`, not an engine yaw parameter. HDR files are large (4K ≈ 18 MB, 8K ≈ 75 MB).
- Store data (directions, relative intensities, densities, coverage), never shader code or engine settings.

## Process

- Coarse to fine: layout of the route and two or three bends first, one representative section complete, then
  extend. Many Saisies rounds went into trees, ground contact and rock while time → distance and camera were still
  wrong, so detail accumulated on the wrong stretch.
- Gold Coast (r3 → r50, 58 package dirs, acceptance 0/24): registration unresolved and the shoreline estimated
  from the video, while S18/S19 got 25 rounds of sand, chapel, paved-edge and triangulation work. One day of
  measured data and external assets (OSM streets / buildings / water, HDRI, PBR textures, CC0 palms) then moved
  the look more than the 47 rounds before it. Measured data and the asset library belong in Phase 0.
- Procedural plants (box / cone palms, generated Norfolk pines, grass tufts) look worse than any CC0 model and
  each costs a round of tuning. Real assets wired only into a preview adapter (`package_preview.gd`
  `PROTOTYPE_LIBRARY`) do not reach Unity; put them in the package via the library file.
- Change one controlled thing per candidate; keep rejected candidates and why.
- Freeze a version before testing; tests and shots from the same version.
- macOS `sed -i ''`; prefer Python for edits. Commit only when asked; never push `assets/`, `export*/`, `video/`.
