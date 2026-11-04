# Camera and temporal similarity review

Use this procedure when building a video-derived package and at the route, grey-box and final visual gates. The
goal is a traversal that resembles the reference across time; source/render review is evidence of similarity,
not a substitute for route, terrain or package validators.

## Evidence and camera

- Keep the source video and untouched reference frames private (`video/`), outside the delivered package. Record
  source dimensions, decoded PTS/time base and SHA-256; do not confuse requested and decoded times. Extract a
  section's entry, middle and exit frames, plus short runs of neighbouring frames within each review window to
  assess temporal drift. On a cut or
  discontinuous sequence, use separate windows; do not invent movement through missing footage.
- Maintain camera analysis as authoring/review evidence, for example `export/<name>/camera_analysis.json`. Record
  the renderer and output dimensions, horizontal or vertical FOV (identify which), camera height above the road,
  lateral offset, pitch, roll, yaw/lookahead, principal point and lens distortion or stabilization/crop if relevant.
  For each material parameter record value, units, source and confidence or `unknown`; a baseline is an estimate,
  not a calibrated fact. Record any time-varying pose and the interpolation used by both fixed views and traversal.
- Each checkpoint records section ID, requested and decoded video time, reference hash, candidate route distance
  `s`, traversal/pass for repeated paths, time → s source and confidence, camera revision, render hash and verdict.
  Time → s hypotheses live in the existing alignment authoring data; the canonical `route/route.json` remains the
  only source of physical route facts. `s` is horizontal distance, as in `docs/ROUTE_SCHEMA.md`.
- GPS/OSM/DEM, video and camera-model outputs are evidence with distinct uncertainty. Monocular video does not
  determine absolute scale on its own: use a defensible measured scale anchor, or mark scale provisional. Do not
  change measured elevation, grade or route scale merely to improve a rendered match. Filtering DEM noise is
  permitted only with a documented, defensible method; recompute grade from the published elevations.

## Probe and diagnose

Before decoration, render a neutral road / terrain probe at two or three consecutive identifiable bends. At the
Phase 3 grey-box gate, extend this to entry / middle / exit for every section. If no suitable package consumer exists,
use an available adapter; if none can produce a comparable view, record the visual gate as blocked rather than
claiming a pass. These probes do not require recording a video.

Compare source and render at the same image dimensions and each checkpoint's registered time → s. Preserve the
source reference unchanged. Compare, in order:

1. road edges and centre, bend direction and road exit position;
2. horizon / terrain silhouette, valley side and sky openings;
3. landmark side, relative size, position and occlusion;
4. vegetation envelope, tree-line distance, gaps and depth ordering;
5. materials, lighting and atmosphere, after structure is credible.

State the largest mismatch and test the smallest plausible cause: camera intrinsics, camera pose, time → s,
route geometry, terrain, landmark, vegetation, or appearance. Do not use pitch to hide a grade problem, FOV to
hide scale, or scenery to hide an unverified route. Recheck neighbouring windows after any change. Optical flow,
visual odometry, segmentation, monocular depth and vanishing points may generate hypotheses when available; record
their provenance and validate them against independent evidence, not as ground truth.

## Criteria, metrics and acceptance

Before scoring, document project-appropriate criteria in the existing checklist or review metadata: resolution,
which observable structural features must match in each section, acceptable errors if measurable, treatment of
cuts / occlusion, and how continuity is judged. Criteria must be specific enough to reproduce the judgement; do
not claim an arbitrary universal similarity percentage. Keep the existing 90% / 80% section checklist thresholds;
the sequence review is an additional gate, not a replacement or an average that hides a failed section.

When suitable data and tools exist, record resolution-normalized road edge distance or road-mask IoU, skyline
error, landmark reprojection error, semantic-mask overlap, and landmark drift across a window. Give units, method,
threshold and limitations. Metrics are diagnostic; no metric, global pixel error, SSIM, or checklist percentage alone
establishes visual similarity. If a metric is unavailable, record the structured visual assessment and its basis;
do not invent a score.

For each window retain review evidence and separate verdicts for package/data validation, consumer execution and
visual similarity. A visual pass requires the planned visible structural features to match at entry, middle and
exit, and no material drift, popping or inconsistent scale in the reviewed neighbouring-frame sequences. Isolated
frames do not prove motion continuity. A hidden feature is `not_verifiable`; missing reference coverage, unknown
registration, absent renders, or unavailable reviewer means `unverified`, never pass. Note explicitly when only
agent review is available rather than user sign-off.

Each correction records evidence IDs, affected parameter family, version / hashes, result and neighbouring-window
regressions. Keep rejected findings and reasons in the compact review record, respecting the skill's cleanup rules.
The final report lists accepted and unresolved sections, criteria, reproducible capture settings, package validation
and consumer checks; do not claim high similarity for a partially reviewed traversal.
