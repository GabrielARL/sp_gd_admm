# COMM-CORE-STORY-001 — term split for the Core story

Role: explanatory bookkeeping for the Core story mode of
`rq1_mechanism_animation.html`. This is not an experiment. It runs no decoder,
changes no protocol and adds no performance evidence.

## What it derives

The eligible endpoint trace
`experiments/rq1_endpoint_001/results/2026-10-28_endpoint_v3/trace.json`
(SHA-256 `c47e200c5be707b66e9fc454ee221671c4eb36771aedac6e143719b6a679e2f9`)
records each accepted update of the native scalar `coral_exact_gradient`
endpoint: the frozen state `x`, the full gradient, the preconditioned direction
and the projected proposal. It does not record how the parity part of the
gradient splits by check.

`build_core_story_trace.py` recomputes, for all 30 accepted updates of rung 6
(`RQ1-ENDPOINT-PG-001`):

- each check's reading of the frozen `x`, its residual `r_c = 1 - prod x_j`
  and its partial-derivative terms `g_{c,i}`;
- the channel term `-(w_ch/(2n)) ell_i` and the binary term
  `(4 w_bin/n) x_i (x_i^2 - 1)`;
- the curvature-bound preconditioner `D_i = (2 w_par deg_i + 8 w_bin)/n`, the
  step, the raw proposal and the box projection;
- the hard-decision estimate `b_hat_i = 1 if x_i < 0` and its syndrome before
  and after each update.

## Gates

The output is `status = valid` only if all of the following hold:

- the source trace has the registered SHA-256 and `validation_passed = true`;
- every recomposed gradient, direction, raw proposal and projected proposal
  equals the retained vector bit for bit, in the floating-point order of
  `rq1_endpoint_001.jl`;
- each update starts from the previous projected proposal;
- every per-term partial derivative agrees with a central finite difference
  within `2e-8`, the endpoint card's tolerance;
- the parity-only, parity-plus-channel and full initial gradients of rungs 0,
  1 and 2 are reproduced bit for bit;
- the hard-decision rule agrees with the bit-1-positive rule on `L`.

`test_build_core_story_trace.py` repeats these checks, confirms determinism and
requires the retained output to equal a fresh derivation byte for byte.

## Boundary

The derived terms only restate retained updates. Their signs and magnitudes
(for example, opposite-signed check terms at the shared bit) are diagnostics of
one three-bit example. They are not evidence about information loss,
convergence, error rate or computational work.
