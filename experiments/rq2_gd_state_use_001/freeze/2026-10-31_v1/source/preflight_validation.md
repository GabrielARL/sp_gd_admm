# `RQ2-GD-STATE-USE-001` preflight validation

validation_status: pass
test_exit_code: 0
config_sha256: 40baeef54e305f9854cd354dc07e5f368510c16f154106d8f06fcaf73e21d382
card_sha256: 4b2400eeb58ed2124ef6fd62f8e369edd4643db6f802aeba90d1cc20456df209
runner_sha256: 3a43e99e80ae5a9419cdd1aef1f8278477a55ad8c77214add74384940e564ce4
test_sha256: 6a46509608a6095c2d690ff9f809aeeb27dd0a85e1f47777ebf7b23319906095

Validated on 2026-10-31 before the source and input freeze.  The exact command
was:

```text
OMP_NUM_THREADS=1 JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 julia --depwarn=error --project=/home/gabiel/Documents/GitHub/JadeJcade-worktrees/awgn-jade-coral-20261012 experiments/rq2_gd_state_use_001/test_rq2_gd_state_use_001.jl
```

The result was `11057 passed / 11057 total` in 1 minute 32.4 seconds.  This
includes a fresh-process direct-CLI probe under Julia 1.12 with deprecation
warnings promoted to errors.

## Governance boundary

An independent validator accidentally executed three active updates on frame 1
before the freeze and saw an intermediate coded-error count.  It did not run
the registered 30-update endpoint, and the observed value was not communicated
to the primary experiment runner.  Frame 1 is quarantined.  The amended anchor
is frames 2 through 25.  The confirmation set, frames 10001 through 10200, was
not exposed.

The timing warm-up is a deterministic synthetic length-`N` LLR vector with no
channel-frame identity.  It is not part of either endpoint set.  This preflight
did not execute an active arm on any amended-anchor or confirmation frame.

## Passing gates

- The registered external source hashes, graph hash, channel variance bit
  pattern, clean JadeJcade checkout, and one-thread environment passed.
- The bounded mean projection passed the simultaneous-bound counterexamples,
  boundary targets, inactive interior cases, and randomized degrees 1, 2, 3,
  and 6 against an independent exhaustive KKT oracle.
- The zero-offset evaluator matched the archived native objective, terms, and
  partial derivatives exactly.  Retained-but-ignored offsets were an exact
  null.
- The bounded construction reproduced the registered RQ1 tree and cycle
  values when projection was inactive.
- A synthetic input confirmed equality through update 1, first nonzero offset
  consumption at update 2, independent finite differences, fixed offsets
  throughout each calculation and line search, valid check readings, and
  zero-mean retained offsets.
- Check-row and within-check local-edge relabeling preserved the canonicalized
  objective, partial derivatives, retained values, hard decision, and
  syndrome.
- Every amended-anchor control frame, 2 through 25, reproduced the archived
  native scalar path and retained deterministic terminal fields.
- Both arms report `N=10200`, `E=30600`, and a persistent `x + delta` state
  footprint of 326400 bytes.  Whole-run allocation is reported separately.
- Exact McNemar, Holm, Newcombe, checksum completeness, extra-file rejection,
  and non-overwrite fixtures passed.

Finite-difference probes use the unconstrained polynomial extension with the
retained offsets fixed.  Such probes are validation-only and may cross a local
feasibility boundary; actual updates and line-search trials remain inside the
registered check-reading box.

The controlled solver has no decoder, normalized-min-sum, pseudogradient,
list, or oracle call path.  Its corresponding structural call fields are zero;
they are not dynamic call interception counters.
