# Saisies whole-route Unity export — 2026-10-21

Delivery uses the existing **GLB + scatter JSON** Unity workflow. This is the
legacy engine adapter, separate from the new AI Scene Package runtime.

## Scope and frozen sources

- Whole route: **14,615.0879219891 m**, 14,616 integer-metre samples plus the exact endpoint.
- R14 geographic world and exact R36 release geometry cache.
- Selected R37 corrections: **S06 v10 foundations**, **S10 / S12 v9** geometry and dressing.
- Export assembled the disjoint corrections on one world. Later corrections changed
  earlier fitted route positions by **0 m** in their respective windows.
- All **392 frozen source files** in the v10 acceptance project verified against
  `geometry_candidate_v10/source_bundle/source_snapshot.json` before delivery.
- This export does not promote the Godot diagnostic candidates to formal visual acceptance.

## Reproduce

Use a restored v10 acceptance project from
`export/saisies/review/round37_route_diagnosis/geometry_candidate_v10/work_project.json`.
Copy the shared exporter/verifier and their legacy parent tools into that fixed project.
Keep its compiled `data/saisies_r37_acceptance_config.json` and audited assets.
Run the native Godot renderer, which can read GPU textures for GLB embedding:

```sh
godot --path FIXED_PROJECT --resolution 1920x1080 \
  --script res://tools/export_static_unity.gd -- \
  --candidate-config=res://data/saisies_r37_acceptance_config.json \
  --foundation-audit-script=res://r37_house_foundation_audit.gd \
  --out=ABSOLUTE_OUTPUT_FOLDER

python3 tools/validate_static_unity_export.py ABSOLUTE_OUTPUT_FOLDER \
  --repair-empty-buffers --normalize-opaque-alpha

godot --path FIXED_PROJECT --resolution 1920x1080 \
  --script res://tools/verify_static_unity_export.gd -- \
  ABSOLUTE_OUTPUT_FOLDER ABSOLUTE_EVIDENCE_FOLDER

python3 tools/package_static_unity.py ABSOLUTE_OUTPUT_FOLDER ABSOLUTE_EVIDENCE_FOLDER
```

The normalizer corrects two Godot 4.7 serialization cases: an unwritten zero-length
BIN header in geometry-free GLBs, and opaque material alpha above glTF's [0,1]
range. Mesh/buffer payloads remain unchanged. Synthetic tests checked binary
preservation and idempotence.

## Validation and artifact

- **30 tiles, 28,544 static mesh nodes, 339 prototypes, 13,159 scatter instances.**
- Static nodes + instances = **41,703**, equal to visible source meshes + visible
  MultiMesh instances + converted 3D labels. No scatter density reduction.
- All buffers and material images are embedded; no original asset path is needed.
- S06: **56 support parts / 19,408 contact probes**, 0 misses, max positive float **0 m**.
- Native Metal round-trip views: S06, S10, S12, START, FINISH.
- Scene package stage tests: **87 passed**. Primitive/world-transform/UV/GLB tests passed.
- Unity Editor appearance and runtime performance require target-project review;
  PBR conversion does not reproduce camera-dependent Godot material passes.

Output: `export_unity/saisies_full_r37_20261021/` and the sibling `.zip`.
Evidence: `export/saisies/review/unity_full_r37/`.
The ZIP includes Unity import instructions, scatter loader, rendered previews,
provenance, credits and SHA-256 checksums. Private reference video frames and source
snapshots are excluded. Geographic terrain is static; do not attach the legacy
runner-following `VirtualRunBackdrop` component.

## Lossless compact delivery

The initial ZIP contained 1,649 image payloads but only 84 distinct images. Shared
textures remove **1,985,963,362 bytes** from the GLB/image files without changing
geometry, image encoding or resolution. The original export stays available.

```sh
python3 tools/compact_static_unity.py ORIGINAL_FOLDER COMPACT_FOLDER
python3 tools/validate_static_unity_export.py COMPACT_FOLDER
# Repeat the native verifier above with COMPACT_FOLDER and a new evidence folder.
python3 tools/package_static_unity.py COMPACT_FOLDER COMPACT_EVIDENCE_FOLDER
```

`textures/` must remain beside the GLBs when importing the complete folder into
Unity. Relative image URIs follow the
[glTF specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#images)
and [glTFast's supported features](https://github.com/Unity-Technologies/com.unity.cloud.gltfast/blob/main/Packages/com.unity.cloud.gltfast/Documentation~/features.md).

The optimizer verifies all **61,010 retained geometry buffer views** byte-for-byte,
reverses pointer remapping to check scene/material/accessor structure, and preserves
all **31 route/instance JSON files**. Its test also covers cross-file sharing,
unchanged source files, missing-texture rejection and refusing output overwrite.
The compact artifact is `export_unity/saisies_full_r37_20261021_compact.zip`;
native evidence is under `export/saisies/review/unity_full_r37/compact_roundtrip/`.

Compact delivery: **289,625,847 bytes (about 290 MB), 87.27% smaller than the original ZIP**.
All five native round-trip views are pixel-identical to the original export; ZIP CRC passes (165 files).
