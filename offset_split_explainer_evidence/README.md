# Offset Split explainer evidence

These are byte-for-byte snapshots of the small retained artifacts used by
`offset_split_explainer.html` and `verify_offset_split_explainer.py`. They make
the explainer verifiable without another worktree. `MANIFEST.sha256` pins every
snapshot; these files are evidence copies, not a new scientific run.

- `compound_case_set_A.csv`: `RQ2-GD-STATE-USE-001`, held-out v2 aggregate.
- `offset_split_case_set_B.csv`, `offset_split_interaction_case_set_B.csv`, and
  `offset_split_COMPLETED.toml`: `RQ2-GD-OFFSET-SPLIT-001`, held-out v3.
- `offset_reassignment_case_set_B.csv`: `RQ2-GD-OFFSET-NULL-001`, held-out v1.
- `native_gap_case_set_B.csv`: `RQ2-NATIVE-GAP-001`, 6 dB v2 aggregate.
- `assignment_refresh_transfer_case_set_C.csv`,
  `assignment_refresh_transfer_interaction_case_set_C.csv`, and
  `assignment_refresh_transfer_COMPLETED.toml`:
  `RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001`, v4 prospective transfer on 200 fresh
  cases (`aggregate.csv`, `interaction.csv`, `COMPLETED.toml`).
- `assignment_refresh_attribution_case_set_B.csv`,
  `assignment_refresh_attribution_interaction_case_set_B.csv`,
  `assignment_refresh_attribution_COMPLETED.toml`, and
  `assignment_refresh_attribution_frames_case_set_B.csv`: the same experiment's
  v4 locked attribution on case set B (`aggregate.csv`, `interaction.csv`,
  `COMPLETED.toml`, `frames.csv`).
- `native_gap_frames_case_set_B.csv`: `RQ2-NATIVE-GAP-001`, 6 dB v2
  `frames.csv`, the attribution's native-GD reference; the checker recomputes
  the native-GD transition accounting case by case from it.

The HTML keeps the original worktree paths in its collapsed provenance record.

## Provenance boundary for the completed campaign

The original snapshot files listed above remain byte-pinned by
`MANIFEST.sha256`. The completed Block A and Block B campaigns, the exact-map
2-by-2 experiment, and the native-composition experiment are not duplicated in
this directory. Instead, the HTML and its verifier identify each retained
artifact by its repository-relative path and expected SHA-256 digest, then
verify that artifact in place before accepting the page's reported results.

No experiment was rerun to update the explainer, and no completed-campaign
artifact was copied into this evidence directory. The proposed atomic bridge is
a plan for the next experiment; it is not completed evidence and must not be
read as a result.
