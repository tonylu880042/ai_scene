# Col des Saisies — scene record

Scene-specific authoring files, Godot scenes, scripts, reviews and tools are indexed in `source_files.sha256`; paths are relative to the repository root and remain in their existing locations to preserve references. Shared code is outside this index. Verify the recorded source bytes from the repository root with `shasum -a 256 -c scene_records/saisies/source_files.sha256`.

Current local development records include `docs/saisies_r37_progress.md` and `export/saisies/review/round37_route_diagnosis/`. R37 is representative-section development, not a completed whole-route release; read the recorded progress and acceptance documents for the latest limitations. `export/`, external `assets/` and private `video/` are intentionally ignored by Git, so local previews, cached geometry, external materials and reference footage are not delivered by this commit. This source index alone does not guarantee a reproducible build or working preview on another machine.
