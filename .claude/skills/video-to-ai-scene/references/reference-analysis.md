# Phase 1 — Reference analysis (evidence and structure)

The reference video is evidence, not material. Extract structure (where things are, in what order, how big, how
dense) into the sections file and a frozen checklist; keep frames only as private, untouched references.

## Reading the video

1. `ffprobe -v error -show_entries stream=time_base,r_frame_rate,avg_frame_rate,nb_frames -show_entries format=duration "$V"`.
   Do not assume seconds × integer fps is a frame: CFR can be 24000/1001; VFR needs real PTS.
2. Contact sheet every 10 s (3 × 6 grid, time labels), read it end to end:
   `ffmpeg -i "$V" -vf "fps=1/10,scale=480:-1" <scratch>/f_%04d.jpg`, then tile with PIL.
3. Cut sections at clear environment changes — usually 10–30 for a run / ride, by content, not a fixed count.
   One sections entry = one checked section = one ID (S01, S02 … in order); maps, shots and sheets use that ID.
4. Where a bend, landmark or wall end is unclear, look at neighbouring frames first at low resolution, then extract
   only the full-resolution frames you need. Seeing a wall in a frame does not give its geographic extent.

## Reference frames (private)

Per section one **untouched** frame `video/<name>_ref/S01.png` (`video/` is not in git). Record per ID:
requested time, zero-based frame index, decoded PTS + time base, size, path, SHA-256. Extract by index:

```bash
ffmpeg -i input.mp4 -vf 'select=eq(n\,120),showinfo' -frames:v 1 S01.png
```

Keep the showinfo log. Also plan entry, middle and exit checkpoints for each section's continuous sequence; retain
their decoded PTS, hashes and time → s confidence as described in [camera and temporal review](camera-temporal-review.md).
Never crop / repaint / recolour the reference in place; derived crops are separate files.
Frames never go into the package or into generators.

## What to extract (per section)

| Layer | Extract | Becomes |
|---|---|---|
| Route | heading change and bend order (left / right, S-bends), straight runs, climbs / descents, road width class, surface (asphalt, gravel, dirt, boardwalk …), junctions | sections `turn`, `half`, `surface`; route.json |
| Elevation | HUD altitude / speed if shown (estimates, mark them), visible gradient | elevation profile source note |
| Near route | per side: water, forest edge distance, wall / guardrail / fence, slope up / down, cliff, buildings, open land, bridge, tunnel | semantics zones (side, offset, confidence) |
| Vegetation | species groups (broadleaf / conifer / mixed / palms), density class, understorey, grass / reeds / shrubs | forest / vegetation_zone attributes |
| Landmarks | name if readable, type, side, approximate size, order relative to bends and other landmarks | structure hints (importance high for recognisable ones) |
| Distant | mountains (side, height class), valley, large water, sky openness, clouds, sun side, haze | environment hints, real-terrain choice |

Label every statement as observed, inferred or unknown. HUD altitude, estimated speed × time and thumbnails are not
GPS. If the road is identifiable (signs, place names, distinctive junctions), match it on a map before inventing
geometry — Phase 2A.

## Time → route registration (real roads)

Every later gate compares a frame at time t with the package at distance s; get this mapping right before Phase 2.

1. Pick 5–10 anchors spread over the video that both the frame and the map show unambiguously: junctions,
   bridges (both sides water), turnarounds, a street meeting the path, an OSM building or coastline corner.
   One anchor per 2–4 min at least; more where the path bends or repeats.
2. Write them to `data/<name>_route_alignment.json` (`anchors: [{time_s, lat, lon, turnaround?}]`).
3. Between anchors, `s` is interpolated by time: check each gap's speed (Δs / Δt) against the activity (run
   2–4 m/s, ride 4–10 m/s) and that `s` only increases. An implausible gap means a wrong anchor, not a fast rider.
4. For each section, read the side items off OSM at its registered `s` (street right? water left? buildings?)
   and compare with the frame. A mismatch here is a registration error: move the anchor (searching only between
   its neighbours) before anything is built on it. Record rejected positions and why.
5. Each section gets `from_s` / `to_s` and a confidence (anchored / interpolated / unknown). Show the table to the
   user with the checklist.

For a repeated traversal (out-and-back, same park path twice), say for each section which pass it is; OSM
features near one pass also stand near the other.

## The checklist (frozen)

`data/<name>_checklist.json`, per section, per layer, 2–5 items **visible in that section's frame**:

```json
{"S05": {"time": "04:30", "ref": "video/<name>_ref/S05.png",
  "L0": ["right bend, then left"], "L1": ["valley on the right", "dark wooded slope opposite"],
  "L2": ["metal guardrail right", "grass slope left", "sparse trees"], "L3": ["one timber farmhouse right"],
  "L4": ["white dashed centre line"]}}
```

Off-frame things go in a "not verifiable in this frame" note, not into items. Show the checklist to the user once;
afterwards it is frozen: no deleting or softening items to pass a gate. Scoring per item: match 1 / partly 0.5 / no 0.

## Evidence records per review round

One `review.json` per round, next to one comparison sheet — nothing else is kept. Version = existing git commit hash,
dirty state and hashes of relevant changed source / input files + package id + SHA-256 of the package files; commit
only when asked. Never keep a copied source / project / package
snapshot. Camera settings, renderer; per ID the reference SHA, render SHA, sizes, outputs and errors; technical and visual verdicts kept separately (not_reviewed, needs_revision,
accepted); who reviewed (an agent review is not human approval); rejected candidates and failed measurements with
reasons. A partial success is not a pass.
