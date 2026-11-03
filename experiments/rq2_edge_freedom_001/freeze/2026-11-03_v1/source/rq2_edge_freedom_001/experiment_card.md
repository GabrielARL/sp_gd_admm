# Edge-copy equality relaxation

Experiment ID: `RQ2-EDGE-FREEDOM-001`

Status: **approved and preregistered before implementation or evaluation of the
registered fresh cases.** The experiment ID is an internal identifier, not a
receiver name.

## Research question

RQ2 asks whether an operational mechanism that differentiates belief
propagation (BP) from projected gradient descent (GD) changes valid-codeword
recovery and transmitted-word recovery when the parity-check graph, vector of
channel log-likelihood ratios (LLRs), and declared protocol are fixed.

This experiment asks one narrower question:

> Under one explicit lifted product objective and metric, does relaxing the
> equality constraint among the stored values attached to the same coded bit
> change the decoding trajectory or terminal hard-decision estimate?

This is not a native BP-versus-GD comparison. The stored values in this study
are optimization variables, not BP variable-to-check or check-to-variable
messages.

## Required lower-endpoint gate

`RQ2-TIED-SCALAR-EDGE-REPRO-001` passed its 24 retained correctness cases. Its
active values stored on Tanner-graph check--bit connections reproduced
`assigned_frozen_product_unconstrained` bit-for-bit, including every accepted
state, partial derivative of the objective function, strict-decrease line
search decision, hard-decision estimate, syndrome, and terminal trace. The
primary and replay scientific SHA-256 was
`bd9e134dc3c8694d77032a0010d9316f84d8e796e9566d971c526ee212a1d4e9`.

The present queue must recheck that sealed prerequisite before any fresh case
is evaluated.

## Common lifted objective

Let `E` be the Tanner-graph edge set, `N(i)` the checks joined to coded bit
`i`, and `d_i = |N(i)|`. The persistent state contains one scalar
`z_(c,i)` for every `(c,i)` in `E`. Define

```math
m_i(z) = \frac{1}{d_i}\sum_{c\in N(i)} z_{(c,i)}.
```

The implementation evaluates this mean as a canonical copy plus the mean of
the deviations from that copy. Consequently `m_i(Bx)` is bit-for-bit equal to
`x_i` when every stored copy is tied to `x_i`; no floating-point averaging
drift is introduced on the constrained manifold.

With code length `n`, channel LLR `L_i`, parity weight `w_p`, binary weight
`w_b`, the assigned frozen check-specific offset `delta_(c,i)`, and `N(c)`,
the bits joined to check `c`, both arms use

```math
J_lift(z; delta)
 = -\frac{1}{2n}\sum_i L_i m_i(z)
   -\frac{2w_p}{n}\sum_c \prod_{j\in N(c)}
       \left(z_{(c,j)} + \delta_{(c,j)}\right)
   +\frac{w_b}{n}\sum_i \left(1-m_i(z)^2\right)^2.
```

For the broadcast map `B`, which copies one scalar `x_i` to every incident
check--bit connection,

```math
J_lift(Bx; delta) = J_scalar(x; delta).
```

The edge-coordinate metric is diagonal:

```math
M_(c,i) = kappa_i/d_i,
```

where `kappa_i` is the retained scalar curvature bound. Therefore the metric
of any tied direction is preserved:

```math
(Bv)^T M (Bv) = \sum_i kappa_i v_i^2.
```

The sum of the edge partial derivatives for bit `i` must equal the scalar
partial derivative on the tied manifold. Under the diagonal metric, the mean
of the free edge directions at the first treatment update must equal the
retained scalar preconditioned direction, while their within-bit deviations
may differ.

## Arms and the only causal difference

| Field | Equality-constrained arm | Equality-relaxed arm |
|---|---|---|
| Persistent state | one `z_(c,i)` per connected check and bit | same |
| Objective | `J_lift` | same |
| Metric | `M_(c,i)=kappa_i/d_i` | same |
| Feasible set | `z_(c,i)=z_(c',i)` for every pair of checks joined to bit `i` | equality constraint removed |
| Direction | constrained metric gradient, broadcast per bit | free metric gradient per check--bit connection |
| Line search | `alpha_k=0.2*2^(-k)`, `k=0,...,16`; first strict decrease | same |
| Projection after update 1 | none | none |
| Initialization | common update-1 state broadcast to all incident connections | same |
| Check-specific offsets | assigned at common update 1 and frozen | same |
| Hard decision | threshold `m_i(z)` | same |
| Update budget | 30 attempted updates | same |

The treatment is therefore the relaxation of the edge-copy equality
constraint under this declared lifted objective and metric. The result must not
be shortened to "edge state alone" because the lifted off-manifold objective
and metric are part of the operational definition.

## Method fingerprint

- State dimension: one persistent scalar for every check--bit connection.
- Channel evidence: clipped channel LLRs; positive values favor coded bit zero.
- Parity calculation: a negative product term using the persistent value on
  each participating connection and its assigned frozen offset.
- Update operator: preconditioned partial derivatives of `J_lift` with a
  strict-decrease backtracking line search.
- Persistent information: accepted connection-specific values and the frozen
  offsets.
- Discarded information: temporary products, partial derivatives, trial
  states, and line-search values after each accepted update.
- Deliberately absent BP operations: recipient exclusion in the
  variable-to-check update, the tanh/atanh check-node calculation, direct
  recurrence application, and syndrome-based early stopping.

## Protocol fingerprint

- Source endpoint: local commit `10ca9a2`, which seals the passed tied gate.
- LDPC graph: regular `(10200,5100)`, variable degree 3, check degree 6, graph
  seed `169616412`.
- Transmitted word: all zeros.
- Channel: complex additive white Gaussian noise (AWGN) at 6 dB, channel gain
  fixed to 1 after the fast Fourier transform.
- Anchor cases: fresh frames `61497:61520`.
- Contingent transfer cases: fresh frames `61521:61720`, registered now but not
  available to the anchor implementation for tuning.
- Passes: primary and deterministic replay; one Julia, BLAS, and OpenMP thread.
- Input gates: graph, transmitted word, transmitted symbols, sampled unit-noise
  vector, received samples, raw channel LLRs, clipped channel LLRs, common
  update-1 state, and frozen offsets.

The frame ranges were searched across the local repository refs and worktrees
before registration. No prior card or result reserved these boundaries.

## Counterfactual prediction

At the first update after the common state, the constrained and relaxed arms
must have the same mean direction for each coded bit. The relaxed arm should
also produce nonzero within-bit directional spread for at least one bit. If
connection-specific freedom matters under this lifted objective and metric,
the subsequent trajectories or terminal recovery outcomes will differ. The
direction and size of the recovery effect are not preregistered.

## Anchor and stopping rule

The 24-case anchor is a correctness and numerical-stability gate, not a tuning
set. It passes only if all correctness gates below pass in both scientific
passes, every case remains finite, the equality-relaxed arm stays below the
registered absolute-state safety limit, and the primary and replay scientific
hashes agree. The 200-case transfer launches automatically only after that
gate passes. No parameter may be changed between the anchor and transfer.

The product-only lifted objective is not coercive in every equality-relaxed
direction. The queue therefore records the maximum absolute state and
within-bit spread at every update. If a nonfinite value appears or the
registered absolute-state limit is exceeded, the arm stops and the anchor is
retained as a stability failure. No box, consensus penalty, clipping rescue,
or post-hoc step-size change is allowed under this experiment ID.

## Correctness gates

1. Recheck the sealed tied-gate manifest, completion status, scientific hash,
   source commit, and frozen source identities.
2. On retained compatibility cases, require the equality-constrained arm to
   reproduce the sealed scalar/tied lower endpoint bit-for-bit.
3. On the tied manifold, require `J_lift(Bx)=J_scalar(x)` bit-for-bit and require
   the sum of edge partial derivatives to agree with the scalar partial
   derivative within the registered numerical tolerance.
4. Check the analytical edge partial derivatives with a symmetric five-point
   finite-difference stencil on registered sampled connections.
5. At the treatment boundary, require equal objective values, state means,
   hard-decision estimates, syndromes, and frozen offsets before equality is
   relaxed.
6. At the first treatment direction, require the registered mean-direction
   identity and nonzero within-bit directional spread.
7. Require every accepted step in each arm to strictly decrease the same
   `J_lift` objective.
8. Require primary and replay scientific hashes to match and refuse result
   overwrite or automatic restart.

## Measurements

At each requested update retain, separately for both arms:

- objective components and total objective;
- accepted step and line-search trial count;
- maximum analytical finite-difference error on registered checks;
- maximum absolute persistent value and maximum within-bit spread;
- mean-state and persistent-state hashes;
- coded-bit errors, syndrome weight, parity validity, and transmitted-word
  recovery.

Also retain per-frame paired outcome differences, requested and accepted
updates, elapsed time, and persistent-state count. Runtime and stored-state
counts are diagnostics; they are not combined into a scalar complexity score.

## Decision and claim boundary

The claim-bearing contrast is equality-relaxed minus equality-constrained on
paired fresh cases. Report both directions of discordance and an exact paired
interval. A changed outcome supports only the causal statement that relaxing
edge-copy equality changes recovery under this lifted objective, metric,
initialization, offset state, graph, channel, and update budget. A null result
does not prove that recipient-specific BP messages are irrelevant. A stability
failure shows that this unregularized relaxation is not a usable decoder; it
must not be rescued or promoted under this experiment ID.

## Closest retained experiments and non-duplication gate

- `RQ2-TIED-SCALAR-EDGE-REPRO-001` proves the constrained lower endpoint. It
  forbids independently evolving copies and contains no fresh performance
  contrast.
- `edge_product_residual_gradient_tied` changes the target and update operator
  together with the state coordinates. This experiment keeps one lifted
  objective, one metric, and one line-search rule across both arms.
- Block B crosses tied versus recipient-specific state for an exact
  sum-product state map. It does not optimize `J_lift` and cannot answer this
  product-objective equality-relaxation question.
- The retained ECHO-GD offset experiment changes freely optimized offsets and
  was a negative development result. Here the offsets remain assigned and
  frozen; the optimized variables are the connection-specific values.

No retained attempt has this mechanism and protocol fingerprint. This is a
new ablation, not a renamed rerun.
