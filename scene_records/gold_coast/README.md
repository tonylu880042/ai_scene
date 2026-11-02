# Gold Coast Broadwater — scene record

Scene-specific authoring and review configuration is indexed in `source_files.sha256`; paths are relative to the repository root. Shared generators and adapters stay in `tools/` and `scripts/` and are versioned separately. Verify the recorded source bytes from the repository root with `shasum -a 256 -c scene_records/gold_coast/source_files.sha256`.

Latest local artifact: `export/packages/gold_coast_broadwater_p1_turns_r54/`. Unity technical handoff: `export/deliveries/gold_coast_r54_unity_handoff/`. `export/` is intentionally ignored by Git; these paths are local artifact locations, not Git-tracked deliverables. The ZIP has its own checksums and must be shared separately.

Status: technical validation stages pass, but full acceptance is blocked; visual and Unity Editor acceptance remain pending. Coordinates, elevation and building details contain estimates. See the artifact's `acceptance.json`, `CREDITS.md` and handoff README for details. This folder is an index, not a self-contained regeneration kit; raw OSM and external asset inputs are not committed.
