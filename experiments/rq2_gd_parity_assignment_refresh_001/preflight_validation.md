# Preflight record for `RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001`

validation_status: not_run
validated_utc: pending
test_exit_code: pending
test_assertions_passed: pending
test_assertions_total: pending
budget_test_exit_code: pending
budget_tests_passed: pending
budget_tests_total: pending
queue_test_exit_code: pending
queue_tests_passed: pending
queue_tests_total: pending
prerequisite_evidence_sha256: pending
config_sha256: pending
card_sha256: pending
runner_sha256: pending
test_sha256: pending
budget_tool_sha256: pending
budget_test_sha256: pending
queue_status_sha256: pending
queue_lock_tool_sha256: pending
anchor_wrapper_sha256: pending
queue_wrapper_sha256: pending
queue_template_sha256: pending
queue_readme_template_sha256: pending
queue_test_sha256: pending
split_runner_sha256: ddd2cc8ce258ebdd2c43a8c305bebd280e6dd609d3872eec039158b29a407ce4
legacy_runner_sha256: 12272ccdcdde6b600073299caa4ada07953164dac65aecda98fc5dac1ba6b3cd
registered_endpoint_frames_executed_during_preflight: 0

Status on 2026-10-31: **implementation prepared; the 13 queue-governance tests
and four budget-derivation tests pass, while Julia validation and scientific
execution remain blocked until `RQ2-GD-OFFSET-SPLIT-001` attempt v3 has
finished**.

## Anti-duplicate audit

The audit searched the published union at commit
`4bbb2d737a92186c776ff8786b065323981f2196`, all local branches and worktrees,
and retained experiment cards and runners.

- Offset Split contains the required `objective1__bounds0` calculation, but
  replaces offsets after every accepted update.
- Offset Null changes assignment or replacement in the compound
  `objective1__bounds1` calculation. It has no permuted-and-frozen arm.
- No retained arm crosses assignment with replacement while offsets are read
  only by the parity calculation.

The new experiment is therefore classified as a causal variant, not a renamed
or rescheduled duplicate.

## Frozen numerical capsule prepared for validation

| Source | SHA-256 |
|---|---|
| v3 split runner | `ddd2cc8ce258ebdd2c43a8c305bebd280e6dd609d3872eec039158b29a407ce4` |
| v3 split configuration | `27378985792f1cd963292a0b6986424b1994b42da1ef17bf9bf2b279c5bc346c` |
| v3 split tests | `c989908e6fe09966102e9f4e15d079e1fe2b431c617371de349d00d1d5111c99` |
| v3 retained numerical runner | `12272ccdcdde6b600073299caa4ada07953164dac65aecda98fc5dac1ba6b3cd` |
| retained split input table | `739da19436f5f3371333ad04585be4c9cd934506c9a66892776b146105b5a5bd` |
| native-gap six-dB frame table | `a724bbcf3637d92ba61d5d086a28d8c6bc3e804da00459c153782859fb5ab9e7` |

These sources are copied under `vendor/` and are not read from the active v3
process. The result prerequisite itself is not frozen yet because v3 has not
published a complete held-out result.

## Dynamic gates still required

After the active v3 service terminates:

1. verify v3 completion, deterministic replay, checksums, and the registered
   parity-calculation branch-selection rule;
2. run the new focused test suite with one Julia, BLAS, and OpenMP thread;
3. rerun and record the queue-governance and budget-derivation suites after
   the final source hash is fixed;
4. require the custom as-built/refreshed trajectory to equal v3
   `objective1__bounds0` on the test case;
5. freeze all 424 anchor, transfer, and attribution inputs before calculating
   the first new endpoint;
6. run the 24-case anchor and require every correctness gate and exact replay;
7. derive the transfer wall budget from the anchor phase log before launching
   the 200 fresh transfer cases; and
8. run the locked attribution cases only after transfer completion.

No test, freeze, anchor, transfer, or attribution result is claimed by this
preflight record.
