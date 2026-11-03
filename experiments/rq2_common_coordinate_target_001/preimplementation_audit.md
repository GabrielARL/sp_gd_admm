# Preimplementation audit

Experiment: `RQ2-COMMON-COORDINATE-TARGET-001`

Audit status: **mathematical and anti-duplication design passes; the numeric
gate registry, implementation, and launch remain blocked.**

## Decision

The proposed experiment is a nonduplicate causal candidate. Its one
registered intervention is the objective calculation, including the partial
derivatives calculated from that objective. The claim is path-conditional to
the tied state and projected-GD update protocol.

No code, freeze, fresh input, queue, or service was created during this audit.

## Atomicity audit

| Item | Fixed or changed? | Audit result |
|---|---|---|
| Scalar persistent state `x` | fixed | pass |
| Tied broadcast `z=Bx` | fixed | pass |
| Edge-copy equality | fixed | pass |
| Initialization | fixed | pass |
| Box projection | fixed | pass |
| Diagonal preconditioner | fixed | pass |
| Trial step sequence | fixed | pass |
| Strict-decrease acceptance rule | fixed | pass |
| 30-attempt/stall rule | fixed | pass |
| No syndrome early stop | fixed | pass |
| Hard-decision and syndrome rules | fixed | pass |
| Objective and its partial derivatives | changed | intended intervention |
| Accepted step and later trajectory | may change downstream | not a second intervention |

The inherited diagonal entries are described as a fixed preconditioner in the
treatment, not as a proved curvature bound for the new objective.

## Anti-circularity and duplicate audit

The local attempt ledger, refs, worktrees, and retained result cards were
searched before this design was accepted.

| Closest work | Why this is not a repeat |
|---|---|
| `RQ2-COMMON-COORDINATE-REPRO-001` | validates the numerical interface; it performs no objective intervention |
| `RQ2-TIED-SCALAR-EDGE-REPRO-001` | reproduces an unboxed product-only construction, not the native compound objective |
| `RQ2-BOUNDED-EDGE-FREEDOM-001` | releases equality and found 164/200 constrained versus 0/200 relaxed; this design keeps equality |
| `RQ2-BP-TARGET-STATE-UPDATE-001` | uses recipient-specific check-to-variable LLR state and does not reproduce native projected GD |
| `RQ2-EXACT-MAP-UPDATE-001` | already isolates residual-gradient versus direct-map application on another state; this design must not reclaim that result |
| `RQ2-DIRECT-CHECK-MAP-001` | deliberately mixes bounded products with LLR-domain addition; its formal invalidation came from the failed update-one Float64 structural gate, and it cannot be reused |
| `RQ2-NATIVE-COMPOSITION-001` | exposes the unresolved bundled state-target-update handoff; this design constructs a separate common-coordinate path for one component rather than inserting a literal rung into that ladder |

Fingerprint search found no prior experiment with all three of: the validated
common bounded coordinate, tied state throughout, and the normalized full
registered-recurrence residual under the native projected-GD update protocol.

## Design choices resolved

- The treatment uses the full edge residual before any tied projection.
- The residual is weighted by `1/d_i` and normalized by `1/n`.
- The registered bounded recurrence is defined directly; it is native-exact on
  the BP-reachable subdomain, uses the frozen saturated extension elsewhere,
  and uses no inverse transform.
- The existing raw-`z`, product-clamped recurrence is the frozen extension on
  all of `[-1,1]^E`.
- Clamp derivative conventions and kink tests are explicit.
- The control must be an exact common-coordinate reproduction of native
  projected GD, bit-for-bit.
- The treatment is not described as BP or as message passing.

## Launch blockers

| Blocker | Status |
|---|---|
| Fresh frame ranges assigned and sealed for both SNR strata | open |
| Exact alternating arm order and input checksums frozen | open |
| Anchor-to-transfer gate encoded without outcome fields | open |
| Fully numeric derivative/kink gate registry frozen | open |
| Implementation exists | open |
| Independent primal and vector-Jacobian tests pass | open |
| Native control reproduction passes on 24 retained cases | open |
| Treatment finite-difference and kink tests pass | open |
| Active-use, poison, projection, input, and replay gates pass | open |
| Immutable freeze and measured wall budget exist | open |
| Work, runtime, persistent/temporary value, and allocation counters exist | open |
| Explicit implementation/freeze approval | open |
| Explicit scientific launch approval | open |

Because these blockers are open, the card is not launchable and must not be
placed behind an automatic dispatcher.

The anchor may authorize transfer only through correctness, identity,
finite-value, derivative, active-use, projection, completion, and replay
fields. Recovery direction, magnitude, significance, syndrome weight, and
coded-bit errors are forbidden from the expansion gate. The 30-attempt cap is
not an equal-work claim.

## Fail-closed conditions

Stop before fresh cases if any of the following occurs: native-control
mismatch; geometry failure; untied copies; averaged target; inverse LLR
reconstruction; per-edge input clipping; raw-product/LLR unit mixing;
derivative or kink-test failure; nonfinite scientific value; altered
preconditioner, projection, line search, initialization, or budget; input
identity failure; fresh-case exposure before freeze; or replay mismatch.

## Claim audit

The strongest later claim permitted is a causal effect of changing the
objective calculation under this fixed constructed path. The design cannot,
by itself, identify the BP check rule alone, reproduce native BP, or finish
the complete native BP-versus-projected-GD decomposition.
