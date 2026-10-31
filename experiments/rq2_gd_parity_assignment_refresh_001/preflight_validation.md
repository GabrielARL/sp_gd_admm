# Preflight record for `RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001`

validation_status: fail
validated_utc: 2026-10-31T16:35:33Z
test_exit_code: 1
test_assertions_passed: 0
test_assertions_total: 0
budget_test_exit_code: 0
budget_tests_passed: 4
budget_tests_total: 4
queue_test_exit_code: 0
queue_tests_passed: 13
queue_tests_total: 13
prerequisite_evidence_sha256: 3c685f79ea4e0e79fb7504f547bfd5e818128c75d6e15a931d1288defa732e5e
config_sha256: 27a438d5fba1377fc2412fed94f0fafb4df7721a27404168a400039278c0a531
card_sha256: 4caf3ba402268192c3dac39f624c76eb323b70d402637b6b58b2762c96582c92
runner_sha256: ddc8cd0695cbda830e67239712d4acc302d788c81b4eb4edb209a5d4a04a8268
test_sha256: 01b59170b5330faa5071f48c5dbc242f72397bd9f956d3a76443921cf6c11674
budget_tool_sha256: 1d3110ef9c6e9fe60e502c69fe6e3aa86c58eddba0a6132c9a904842f405f030
budget_test_sha256: 717e972fb6b589505183016ec7963afe9958abc6a532681b93b2758e76a05d49
queue_status_sha256: 918434ad094008fd0ec1b551ffef3e2eb21bb9b122838df58e1053d23244b35a
queue_lock_tool_sha256: 72d7f1d0034902fe2618aaa921aa10212a516ec902936d42ca055e57f1a46c12
anchor_wrapper_sha256: 6f083c26651342ac3729b3f33b3c39e4a88c74404fe27d32f26106a6b2fa62fe
queue_wrapper_sha256: b7a8eb2dc87d05f9b881b88071b2f58d718e8055553c26c7cdd67551fb6952a1
queue_template_sha256: 484a97c8472365fb4508afbf8477af245527e8bb9dde15b8254e80736f7eb8a8
queue_readme_template_sha256: 0f2bbb14e5d7596b1d7ebee986f3a46e41b4c3a358b2e06f29d04c4b65d2810b
queue_test_sha256: 5f0a15f27bd75d41082d6ee792b95432b6592a45fe115b6658c6c6a5cd4c0d0e
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
