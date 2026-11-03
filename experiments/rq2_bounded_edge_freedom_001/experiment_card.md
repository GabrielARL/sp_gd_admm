# Bounded edge-copy equality relaxation

Experiment ID: `RQ2-BOUNDED-EDGE-FREEDOM-001`

Status: **prospectively registered before implementation or evaluation of the
registered fresh cases.** This is an internal experiment identifier, not a
receiver name.

## Why this successor is needed

`RQ2-EDGE-FREEDOM-001` asked whether independently evolving edge optimization
variables change recovery under an unbounded product-only objective. Its first
attempt failed closed on retained compatibility frame 20001, update 6, at the
registered pullback-gradient identity gate. It evaluated zero fresh cases and
therefore supplied no recovery count or causal evidence. That attempt remains
unchanged; its absolute tolerance will not be relaxed and its experiment ID
will not be reused.

The product-only equality-relaxed objective was also noncoercive. The present
successor therefore begins from the retained, bounded Block-A
`compound__box` endpoint. It asks the same narrow representation question in a
numerically bounded construction whose scalar lower endpoint already has a
valid retained implementation.

## Research question

> Under the bounded compound objective, does removing only the equality
> constraint among edge optimization variables attached to the same coded bit
> change the trajectory or the terminal hard-decision estimate?

This is not a native belief propagation (BP) versus projected gradient descent
(GD) comparison. The persistent edge quantities below are optimization
variables, not BP variable-to-check or check-to-variable messages.

## Required lower-endpoint reproduction

Before any fresh case is evaluated, the equality-constrained arm must reproduce
the retained Block-A `compound__box` trajectory bit-for-bit on compatibility
frames `20001:20024`, through requested update 30. Equality is required for the
common update-1 state and frozen offsets, every accepted scalar state, all
objective components and partial derivatives of the objective function, every
line-search decision, terminal hard-decision estimate, syndrome, stop status,
and complete trace.

The constrained implementation uses the retained Block-A evaluation and
accumulation order on the tied manifold, then broadcasts the accepted scalar
to its incident edge coordinates. The independently written lifted evaluator
is checked as a diagnostic; it does not replace the bit-for-bit lower-endpoint
gate.

## Common bounded compound objective

Let `E` be the Tanner-graph edge set, `N(i)` the checks joined to coded bit
`i`, `d_i = |N(i)|`, and `N(c)` the bits joined to check `c`. The persistent
state stores one scalar edge optimization variable `z_(c,i)` for each
`(c,i) in E`. Define the fixed readout

```math
m_i(z) = (1/d_i) sum_{c in N(i)} z_(c,i).
```

The numerical implementation evaluates this arithmetic mean as the first
incident copy plus the mean of the deviations from that copy, in frozen
incident-edge order. Thus `m_i(Bx)` is bit-for-bit equal to `x_i` when the
broadcast map `B` assigns `z_(c,i)=x_i` for every incident check.

With code length `n`, channel log-likelihood ratio `L_i`, parity weight `w_p`,
binary weight `w_b`, and the assigned frozen check-specific offset
`delta_(c,i)`, both arms use

```math
J_lift(z; delta)
 = -1/(2n) sum_i L_i m_i(z)
   + (w_p/n) sum_c [1 - prod_{j in N(c)}
       (z_(c,j) + delta_(c,j))]^2
   + (w_b/n) sum_i [1 - m_i(z)^2]^2.
```

Every edge optimization variable is constrained to `[-1,1]`. The box applies
to `z_(c,i)`, not to the offset-adjusted parity reading
`z_(c,i)+delta_(c,i)`. On the tied manifold,

```math
J_lift(Bx; delta) = J_compound(x; delta),
```

and the edge box is exactly the scalar box used by Block A. Clamping the
offset-adjusted reading would change the lower endpoint and is forbidden.

## Metric and partial derivatives

Let `kappa_i` be the retained scalar curvature bound. Both arms use the same
diagonal edge metric

```math
M_(c,i) = kappa_i/d_i.
```

For `P_c = prod_{j in N(c)}(z_(c,j)+delta_(c,j))`, the edge partial derivative
is

```math
partial J_lift / partial z_(c,i)
 = (1/d_i)[-L_i/(2n) + (4w_b/n)m_i(z)(m_i(z)^2-1)]
   - (2w_p/n)(1-P_c)
       prod_{j in N(c), j != i}(z_(c,j)+delta_(c,j)).
```

On the tied manifold, summing these edge partial derivatives over `c in N(i)`
equals the Block-A scalar partial derivative. The induced metric on tied
directions is the retained scalar metric:

```math
(Bv)^T M (Bv) = sum_i kappa_i v_i^2.
```

Consequently, before projection, the mean of the free edge directions equals
the constrained scalar direction at the treatment boundary. This identity is
a registered diagnostic, not a claim that the trajectories remain equal after
the equality constraint is removed.

## Arms and the single causal change

| Field | Equality-constrained arm | Equality-relaxed arm |
|---|---|---|
| Persistent state | one `z_(c,i)` per connected check and bit | same |
| Objective | `J_lift` restricted to tied copies | `J_lift` |
| Metric | `M_(c,i)=kappa_i/d_i` | same |
| Box | every `z_(c,i)` in `[-1,1]` | same |
| Equality constraint | all copies attached to bit `i` must be equal | removed |
| Direction | constrained metric gradient, one value broadcast per bit | free metric gradient per edge coordinate |
| Projection | tied box projection, equivalent to scalar clamp | componentwise edge-coordinate clamp |
| Line search | `alpha_k=0.2*2^(-k)`, `k=0,...,16`; first strict decrease | same |
| Initialization | common Block-A update-1 state broadcast to incident edges | same |
| Offsets | assigned at update 1 and frozen | same |
| Hard decision | threshold the fixed mean `m_i(z)` | same |
| Budget | 30 requested updates | same |

The intervention is only removal of the equality constraints. The objective,
box, metric, preconditioner, initialization, frozen offsets, line-search rule,
hard-decision readout, cases, and work budget remain fixed.

The 30-update endpoint is primary. A 90-update readout is deliberately absent:
the retained scalar `compound__box` arm already reaches a ceiling on the
earlier 200 fresh cases at that budget, so it would obscure rather than sharpen
the registered equality-release contrast.

## Method fingerprint

- State dimension: one persistent scalar for every Tanner-graph edge.
- Channel and binary terms: evaluated from the fixed mean of incident copies.
- Parity calculation: squared parity residual using the edge coordinate local
  to each check and its assigned frozen offset.
- Update operator: metric-preconditioned partial derivatives of the declared
  objective, componentwise or tied box projection, and strict-decrease
  backtracking.
- Persistent information: accepted edge coordinates and frozen offsets.
- Discarded information: temporary products, partial derivatives, directions,
  trial states, and line-search values after each accepted update.
- Operations deliberately absent: BP recipient exclusion, the BP tanh/atanh
  check-node calculation, direct recurrence application, and syndrome-based
  early stopping.

## Protocol fingerprint

- Source parent: local commit
  `ccdbdfbf6d977c61efdef3f6ee73494cdbf4b061`, which records the terminal
  failure of the unbounded predecessor.
- Scalar lower endpoint: Block-A `compound__box` from
  `RQ2-GD-RESIDUAL-PROJECTION-BUDGET-001`.
- LDPC graph: regular `(10200,5100)`, variable degree 3, check degree 6, graph
  seed `169616412`.
- Transmitted word: all zeros.
- Channel: complex additive white Gaussian noise at 6 dB, with unit channel
  gain after the fast Fourier transform.
- Compatibility cases: retained frames `20001:20024`; no performance
  inference is allowed from them.
- Anchor cases: frames `61497:61520`.
- Contingent transfer cases: frames `61521:61720`.
- Passes: primary and deterministic replay, with one Julia, BLAS, and OpenMP
  thread.

The anchor and transfer ranges were registered by the failed predecessor, but
that attempt stopped before evaluating any fresh frame. Reusing the still
unexposed ranges avoids outcome-adaptive case selection. The transfer cases
must remain unavailable to implementation decisions until the anchor passes.

## Prospective numerical diagnostics

The failed predecessor's fixed absolute gate is not edited or reinterpreted.
This new bounded experiment prospectively registers the following roundoff
criterion for the scalar pullback partial derivative `g_i`, its
channel-plus-binary contribution `h_i`, and its check-associated contributions
`q_(c,i)`:

```math
|g_i - [h_i + sum_c q_(c,i)]|
 <= 128 eps(Float64)
    max(1, |g_i|, |h_i| + sum_c |q_(c,i)|).
```

The analogous direction scale is
`max(1, |p_i|, (1/d_i) sum_c |p_(c,i)|)`. This scale-aware criterion is
applied to the independent lifted-objective, pullback-gradient, and
first-direction diagnostics. Record both the maximum raw error and the maximum
error divided by its registered bound. Exact Block-A trajectory reproduction
remains bit-for-bit and is not weakened to this tolerance.

Analytical edge partial derivatives are also checked using a symmetric
five-point finite-difference stencil at registered updates 2 and 30. Its
registered mixed threshold is
`5e-8 max(1, |analytic|, |numerical|)`.

## Correctness and launch gates

1. Verify the frozen Block-A source, calibration completion record, result
   manifest, and input identities against their registered SHA-256 values.
2. Reproduce `compound__box` bit-for-bit on all 24 compatibility frames in
   both scientific passes.
3. On every checked tied state, require exact tied copies and exact objective
   and state readout; require the independent pullback and direction identities
   to satisfy the registered scale-aware diagnostic.
4. Require five-point finite differences to pass for the lifted analytical
   edge partial derivatives.
5. At the treatment boundary, require equal persistent states, means,
   objectives, frozen offsets, hard-decision estimates, and syndromes before
   the equality constraint is removed.
6. Require nonzero within-bit directional spread in the relaxed arm at the
   first treatment direction; otherwise the registered intervention was not
   operational on the case.
7. Require every accepted trial in both arms to remain inside the edge box and
   strictly decrease the same `J_lift` objective.
8. Refuse overwrite and automatic restart. Preserve the first failing field
   and stop before any fresh case if a compatibility gate fails.
9. Run the 24-case anchor in primary and replay passes. Launch the 200-case
   transfer automatically only if every anchor gate passes and both scientific
   hashes agree. No parameter may change between anchor and transfer.

## Measurements

For each arm and requested update, retain:

- channel, compound-parity, binary, and total objective values;
- accepted step, line-search trial count, and stop status;
- state, mean-state, frozen-offset, hard-word, and syndrome hashes;
- maximum absolute edge coordinate and maximum within-bit spread;
- coded-bit errors, syndrome weight, parity validity, and transmitted-word
  recovery;
- root-mean-square private-check residual
  `sqrt(mean_c (1-P_c)^2)`;
- the same residual after replacing each edge coordinate by its fixed mean;
- the number of check-local hard parity decisions satisfied by the signs of
  `z_(c,j)+delta_(c,j)`, the number satisfied by the coherent mean hard word,
  and the number of checks on which those two satisfaction flags disagree;
- the count of edge hard signs that disagree with the mean hard decision;
- raw and normalized maxima for the pullback, mean-direction, and
  finite-difference diagnostics.

The last three measurements distinguish small private-check residuals from a
single coherent word estimate. They are diagnostics, not additional treatment
factors. Runtime and persistent-state counts are reported separately and are
not combined into a scalar complexity score.

For these sign diagnostics, a value greater than or equal to zero maps to
`+1`, and a negative value maps to `-1`. A check's hard parity is satisfied
exactly when the product of its mapped signs is `+1`; this fixes the zero tie
convention before evaluation.

## Decision rule and claim boundary

The primary endpoint is paired transmitted-word recovery at requested update
30. Parity validity is confirmatory; a parity-valid word can be the wrong
transmitted word. Report both directions of paired discordance, the paired
recovery difference, and an exact paired interval. Do not force an additive
case attribution when the per-case outcomes disagree in both directions.

A changed outcome supports only this statement:

> Removing edge-copy equality changes recovery for this bounded compound
> objective, metric, initialization, frozen-offset construction, graph,
> channel, hard-decision readout, and 30-update budget.

A null outcome means equality freedom did not change recovery under this
registered construction. It does not show that recipient-specific BP state is
irrelevant. Neither outcome establishes BP equivalence, identifies the total
native BP-versus-projected-GD gap, or turns these edge optimization variables
into BP messages.

## Non-duplication boundary

- `RQ2-EDGE-FREEDOM-001` used an unbounded product-only objective and failed
  before any fresh case. This successor uses the squared parity residual and a
  declared edge box; it does not relaunch or repair the old ID.
- `RQ2-TIED-SCALAR-EDGE-REPRO-001` reproduces an unbounded product-only scalar
  endpoint and never allows edge copies to differ.
- Block A compares parity-objective shape and scalar box projection while
  retaining one scalar per bit. It supplies the lower endpoint but does not
  release edge-copy equality.
- Block B crosses recipient-specific BP state with the exact sum-product map.
  It does not optimize this bounded compound objective.
- The retained ECHO-GD development result freely optimizes offsets. Here the
  offsets are assigned once and frozen; only the edge optimization variables
  are released.

This is therefore a bounded successor with a distinct mechanism fingerprint,
not a renamed rerun.
