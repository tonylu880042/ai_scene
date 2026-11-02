# Gold Coast S19 r17 P4 workflow

The older entry `export/gold_coast/review/s19_landmarks_luna6/build_candidate.py` is preserved as delivered,
but it raises when its expected P4 checks find blockers and refuses an existing destination. Use this
maintained r17 entry instead:

```sh
python3 export/gold_coast/review/s19_workflow_r17_luna6/build_candidate.py
```

It reads frozen r13 as its source and writes only
`export/packages/gold_coast_broadwater_s19_workflow_r17_luna6`. It records `package_id`, P4 validation
findings and route projections in `R17_BUILD_REPORT.json`; expected P4 findings mark `acceptance.json`
blocked and still leave a complete candidate/report. The output carries a `.managed_candidate.json` owner marker. Rebuilds are
allowed only for that marked candidate, use a temporary sibling, and replace it after a successful build.
An unmarked directory, a source/ancestor path or a symlink path is rejected. A failed rebuild keeps the
previous candidate intact. A per-destination nonblocking lock rejects a concurrent cooperating build. Before
replacement the workflow compares the original destination identity and tree fingerprint, including the exact
owner-marker bytes and identity; a destination that appears or changes while the stage is being built is left
in place and the stage is discarded. The final stage rename uses an OS no-replace rename so a late-created
destination cannot be overwritten; rollback also uses no-replace. Once the callback returns, a recorded
stage device/inode allows cleanup after later failures only while that same directory remains at the stage path.
If the callback raises, its final path identity cannot establish ownership: any file, directory, or symlink there
(including a broken symlink) is preserved, and the original exception includes an absolute-path note identifying
the retained stage. This includes interruption exceptions such as `KeyboardInterrupt` and `SystemExit`. This
fail-closed case avoids deleting a directory the callback may have substituted; the caller can inspect or
remove that path.
A successful stage rename transfers ownership to the
published destination immediately, so final cleanup never follows the old stage pathname, which may already
refer to a retained backup or another actor's directory. This identity check protects against pathname
replacement between workflow steps; it cannot make concurrent arbitrary filesystem writes race-free. Every
prior output is retained at its
candidate-specific UUID backup path. The durable report and returned report include
`previous_output_backup`: `none` with a null path on the first build, or `retained_unverified` with the
absolute path on a rebuild. Retained backups are deliberately not described as verified or cleaned because
an arbitrary process can replace a backup path after an identity check. This coordinates cooperating
workflow runs, but cannot prevent arbitrary non-cooperating processes from writing to these paths.

The script is a review-only S19 reproduction entry over the shared transaction/finalization helper in
`tools/candidate_workflow.py`. Changes to common asset sampling and validation remain in
`tools/structures.py`; it does not create a separate scene pipeline or alter r13/r15/r16 output.
