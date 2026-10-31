# `RQ2-GD-OFFSET-SPLIT-001` preflight validation

validation_status: pass
validated_utc: 2026-10-31T02:27:23Z
test_exit_code: 0
test_assertions_passed: 1089
test_assertions_total: 1089
config_sha256: d5f55d93a4ff20bd680082f80f24169d5a3f80d4fe6facb5dea76c8fe38e39a9
card_sha256: 551c068c18357d4f53482fcbbdf2013e5049bf15b8d0a1b495345fab10435b69
runner_sha256: 70cf7cf14c3d1184f8ecb65d1689da6cfdae1eb9272b3227055a434af1585860
test_sha256: c70187cd2858c23efe93e15492f50ad0ac037e7068d152945a7f18dd68fcf1e0
prior_result_locks_passed: true
prohibited_call_audit_passed: true
registered_endpoint_frames_executed_during_preflight: 0

No registered anchor or held-out endpoint was executed.  The passing focused
suite used synthetic fixtures, generated registered input identities without
calling the solver on them, and compared the two diagonal cells against the
exposed retained frame 2.  The record above locks the exact command,
environment, source hashes, and assertion count before source and input
freeze.

## Execution boundary

The required focused-test command is:

```text
OMP_NUM_THREADS=1 JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 \
julia --depwarn=error \
  --project=/home/gabiel/Documents/GitHub/JadeJcade-worktrees/awgn-jade-coral-20261012 \
  experiments/rq2_gd_offset_split_001/test_rq2_gd_offset_split_001.jl
```

The preflight may use synthetic fixtures and the exposed
`RQ2-GD-STATE-USE-001` anchor solely for regression checks.  It must not
calculate an endpoint for frames `20001:20024` or `30001:30200` before those
inputs and the executable source have been frozen.

## Gates that must pass before freeze

### Configuration and provenance

- Parse `config.toml` and verify schema
  `rq2-gd-offset-split-001/v1`, internal experiment ID, four exact arm IDs,
  Boolean factor values, frame ranges, 6 dB channel, graph hash, all-zero
  transmitted word, 30-update budget, and one-thread environment.
- Verify every source and retained-result SHA-256 in `[sources]`.
- Verify that the new card, configuration, runner, and tests are archived by
  hash, and that an existing freeze or result directory cannot be overwritten.
- Verify that neither the runner nor an arm update path contains a decoder,
  BP, normalized-min-sum, pseudogradient, word-list, or oracle call.

### Four-arm factor implementation

- Verify the exact factor table:

  | Arm | Objective reads offsets | Projection uses offset-induced interval |
  |---|---:|---:|
  | `objective0__bounds0` | false | false |
  | `objective1__bounds0` | true | false |
  | `objective0__bounds1` | false | true |
  | `objective1__bounds1` | true | true |

- Verify that all arms allocate equal scalar and edge-shaped persistent arrays,
  run the same bounded-mean offset construction, and refresh offsets only
  after an accepted update.
- Verify exact equality of all four arms through update 1 and equal `x` and
  `delta` at the entrance to update 2.
- Verify that objective selection and interval selection are independent:
  changing `O` cannot change the interval function, and changing `P` cannot
  change the objective evaluator.

### Numerical correctness

- With `O=0`, verify objective components and partial derivatives exactly
  against the archived native implementation.
- With `O=1`, verify partial derivatives by an independent centered finite
  difference with offsets fixed.
- With `P=0`, verify the interval is exactly `[-1,1]`; with `P=1`, verify each
  endpoint against an independent intersection calculation.
- Verify independently that the projection step is applied separately and
  correctly to every scalar.
- Test the bounded-mean construction at simultaneous bounds, boundary targets,
  inactive interior cases, degree one, and randomized degrees two, three, and
  six against an independent KKT oracle.
- Verify that offsets remain unchanged through each calculation of partial
  derivatives and line-search trial and that each accepted trial strictly
  decreases its arm's registered fixed-offset objective.
- Verify all scalar states and trials remain in `[-1,1]`.
- For `objective1__bounds0`, deliberately exercise a shifted reading outside
  `[-1,1]` and verify that it is neither clipped nor rejected and that count
  and maximum-overshoot diagnostics are exact.
- For both `P=1` arms, verify every shifted reading remains in `[-1,1]`.
- Verify independent hard-decision and syndrome calculations and invariance to
  check-row and local-edge relabeling.

### Retained-regression controls

- On the exposed prior anchor, require `objective0__bounds0` to reproduce the
  archived control scalar path, objective history, accepted steps, hard
  decision, and syndrome bit for bit.
- On the same exposed cases, require `objective1__bounds1` to reproduce the
  archived compound arm path bit for bit.
- These regression cases are implementation controls only.  They are not
  pooled with the new anchor or held-out result and cannot authorize a
  scientific claim.

### Protocol, inference, and persistence

- Generate and verify exactly 224 frozen input rows: frames `20001:20024` and
  `30001:30200`.  Confirm no overlap with each other or the prior experiment.
- Verify received-sample, raw-LLR, clipped-LLR, transmitted-word, graph, and
  noise identities by independent regeneration before accepting the freeze.
- Test all four paired-success tables, exact McNemar calculations, Newcombe
  method-10 intervals, the eight-test Holm correction, and the fixed-seed
  paired-case bootstrap on synthetic fixtures with independently known
  answers.
- Verify cyclic arm-order balance: each arm occupies each execution position
  six times in the anchor and fifty times in the held-out set.
- Verify timed and traced terminal hashes agree for every arm.
- Verify `progress.toml` is written atomically after every completed frame,
  distinguishes `primary` and `replay`, and is excluded from the scientific
  hash.  A partial attempt cannot be resumed or overwritten; any manual
  relaunch must use the same immutable freeze and a new attempt directory.
- Verify two pure scientific calculations produce the same canonical SHA-256,
  checksum completeness passes, extra output files are rejected, and the
  output cannot be overwritten.

## Expansion rule

The held-out run is enabled only when every correctness, provenance, freeze,
and deterministic-replay gate passes.  It is enabled regardless of whether
the anchor effects are positive, null, reversed, or interacting.  No outcome
direction is a gate, and no parameter may be changed after an anchor outcome
is inspected.

## Locked preflight record fields

The signed record at the top of this file contains:

```text
validation_status: pass | fail
validated_utc:
test_exit_code:
test_assertions_passed:
test_assertions_total:
config_sha256:
card_sha256:
runner_sha256:
test_sha256:
prior_result_locks_passed:
prohibited_call_audit_passed:
registered_endpoint_frames_executed_during_preflight: 0
```

Only a `pass` record with zero registered endpoint frames executed may be
archived into the source and input freeze.
