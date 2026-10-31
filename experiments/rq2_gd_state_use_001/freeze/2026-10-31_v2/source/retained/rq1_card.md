# Provisional internal experiment ID `RQ1-GD-STATE-USE-001`

Status before execution: **provisional preregistration; executable validation
required**.

This label is an internal experiment ID, not a receiver name.

## Research question

This RQ1 experiment asks whether retaining and then using check-specific values
changes the second update of the projected gradient descent algorithm on a locked
three-bit endpoint example and a preregistered cyclic confirmation.

It is a controlled two-update ablation study.  It is not an AWGN decoding-performance
experiment and makes no BER, FER, convergence-rate, or receiver-ranking claim.
ADMM is outside its scope.

## Mechanism being isolated

The native scalar endpoint retains one relaxed scalar `x_i` per bit.  The
partial derivative of the objective function for bit `i` combines the channel
and binary terms with the parity contributions from every check connected to
that bit.  During update 1,
this experiment constructs one mean-preserving value indexed by check `c` by
leaving out check `c`.  It retains or collapses the resulting check-specific
values and uses or ignores them during update 2.

The causal treatment is not extra allocation by itself.  The active cell must
both retain the check-specific distinction and use it in the next parity
calculation.

## Locked cases and physical input

The tree anchor and channel evidence are inherited from `RQ1-ENDPOINT-001`:

```text
H = [1 1 0;
     0 1 1]

L   = (-log(9), log(3/2), log(2))
ell = -L
```

The cyclic confirmation is registered before either case executes:

```text
H_cycle = [1 1 0;
           0 1 1;
           1 0 1].
```

It uses the exact channel evidence, initialization rule, objective weights,
preconditioner, initial step, backtrack limit, box, projection, two-update
intervention, hard-decision rule, and validation tolerances registered for the tree
anchor.  No parameter is fitted or changed for the cyclic graph.  The cyclic
case executes only if the tree case passes every correctness gate.  A null
active effect does not fail a correctness gate and therefore does not by itself
block the preregistered cyclic confirmation.

`L_i = log(P(bit_i=1|y_i)/P(bit_i=0|y_i))`; positive `L_i` favors bit 1.
The native JadeJcade scalar endpoint uses the bit-zero-positive coordinate
`ell = -L`.  Its initial scalar state is

```text
x_i^(0) = tanh(ell_i / 2).
```

Within each case, the graph, vector of channel LLRs, initial scalar state,
precision, objective weights, box, diagonal preconditioner, initial step,
backtracking line search with strict-decrease acceptance, projection, two-update
budget, and hard-decision rule are
fixed in every cell.  Between cases, only the preregistered third parity check
and the graph-derived bit degrees change.

## Native scalar objective and decomposition of partial derivatives of the objective function

For `n = 3`, `mu_p = 2`, and `mu_b = 0.2`, the inherited objective is

```text
F_0(x) = -ell'x/(2n)
       + mu_p/n * sum_c (1 - product_{j in c} x_j)^2
       + mu_b/n * sum_i (1 - x_i^2)^2.
```

For bit `i`, write the partial derivative of the objective function as

```text
G_i = h_i + sum_{c in N(i)} g_(c,i),

h_i = -ell_i/(2n) + 4 mu_b x_i (x_i^2 - 1)/n,

g_(c,i) = -2 mu_p/n
          * (1 - product_{j in c} x_j)
          * product_{j in c, j != i} x_j.
```

`g_(c,i)` is a check-associated contribution to a partial derivative of the
objective function.  It is not a BP message.

## Update 1: native update and check-indexed value construction

Update 1 is the native endpoint's diagonally preconditioned update of the
projected gradient descent algorithm.  It uses a backtracking line search with
strict-decrease acceptance.  Its curvature bound is

```text
kappa_i = (2 mu_p degree(i) + 8 mu_b) / n,
```

and its direction is `-G_i/kappa_i`.  Starting with step `0.2`, the backtracking line search
halves the step until the projected proposal strictly reduces `F_0`, with at
most 16 backtracks.

At the frozen state `x^(0)`, define one constructed value
`G_tilde_(i,c)` (LaTeX: `\widetilde G_{i,c}`) for every check `c` connected to
bit `i` by leaving out check `c`.  It is assembled from contributions to
partial derivatives of the objective function but is not itself a partial
derivative of the objective function `F_0`.  For `degree(i) > 1`,

```text
G_tilde_(i,c) = h_i
              + degree(i)/(degree(i)-1)
                * sum_{a in N(i), a != c} g_(a,i).
```

For `degree(i) = 1`, define `G_tilde_(i,c) = G_i`.  This is the registered
degree-one null rule; it prevents an undefined division and creates no
check-specific distinction where only one check is connected to bit `i`.

The factor `degree(i)/(degree(i)-1)` is chosen because each contribution
`g_(a,i)` appears in exactly `degree(i)-1` sums after one indexed check `c` is
left out.  Averaging the constructed values over the checks connected to bit
`i` therefore recovers
`h_i + sum_a g_(a,i) = G_i`.

Let `alpha_1` be the step accepted by the native update.  Before projection,

```text
raw_i       = x_i^(0) - alpha_1 G_i/kappa_i,
local_(c,i) = x_i^(0) - alpha_1 G_tilde_(i,c)/kappa_i,
delta_(c,i) = local_(c,i) - raw_i.
```

The first native proposal and every local proposal must lie strictly inside
`[-1,1]`; otherwise that preregistered case is invalid and its update 2 must not
execute.  These local proposals are also the check readings used by the active
update-2 objective, so this gate keeps every initial check reading inside the
registered box.  Consequently `x^(1) = raw`, and

```text
mean_{c in N(i)} G_tilde_(i,c) = G_i,
sum_{c in N(i)} delta_(c,i) = 0,
x_i^(1) + delta_(c,i) = local_(c,i).
```

These identities ensure that the intervention adds a check-specific distinction
without shifting the per-bit mean after update 1.

## Update 2: registered 2 by 2 intervention

Every cell enters update 2 with the same scalar state `x^(1)`.  The retained
state is

```text
retained:  delta_state_(c,i) = delta_(c,i)
collapsed: delta_state_(c,i) = 0.
```

The rule for whether the retained state is used is

```text
consumed: delta_effective = delta_state
ignored:  delta_effective = 0.
```

This gives four preregistered cells:

| Cell | State after update 1 | State used in update 2 |
|---|---|---|
| `collapsed__ignored` | zero in every edge slot | zero |
| `retained__ignored` | registered `delta` | zero |
| `collapsed__consumed` | zero in every edge slot | zero |
| `retained__consumed` | registered `delta` | registered `delta` |

The first three cells are controls and must have exactly equal numerical
update paths in both cases.  `retained__ignored` is the storage-only null control.
`collapsed__consumed` is the use-switch null control.  Only
`retained__consumed` is an active treatment.

Every cell physically allocates the same scalar and edge-slot arrays for this
instrumented experiment.  "Collapsed" means that zero rather than the registered
`delta` is logically retained in those edge slots; it does not mean that the
implementation allocates less memory.

For a fixed `delta_effective`, update 2 uses

```text
F_delta(x) = -ell'x/(2n)
           + mu_p/n * sum_c
               (1 - product_{i in c}(x_i + delta_effective_(c,i)))^2
           + mu_b/n * sum_i (1 - x_i^2)^2.
```

`delta_effective` is held fixed while calculating every partial derivative of
the objective function, finite difference, trial of the backtracking line
search with strict-decrease acceptance, and accepted objective value.  In
particular, an active trial is accepted only when
`F_delta(projected_trial) < F_delta(x^(1))`; `F_0(x^(1))` is never used as the
active cell's current loss.  The control cells use exactly `F_0`.  The active
objective is a local counterfactual bridge, not the native scalar endpoint's
objective and not a new decoder.

All cells use the inherited curvature bound, preconditioned direction,
backtracking line search with strict-decrease acceptance, componentwise box
projection, and one update-2 step.
The accepted step may differ in the active cell because strict decrease is
tested against that cell's registered objective.  Every check reading
`x_trial_i + delta_effective_(c,i)` at the current state, every trial of the
backtracking line search with strict-decrease acceptance, every accepted state,
and every centered finite-difference point must remain inside `[-1,1]`;
otherwise the case is invalid.

## Method fingerprints

### Native scalar control

- Persistent dynamic state: one relaxed scalar per coded bit.
- Objective: `F_0` above.
- Update: partial derivatives of the objective function, the native diagonal
  preconditioner, a backtracking line search with strict-decrease acceptance,
  and componentwise box projection.
- Schedule: one frozen scalar state vector is used for every partial derivative
  of the objective function in
  an update.

### Active cell: retain and use check-specific values

- Persistent dynamic state at the update boundary: the same scalar vector plus
  one mean-zero `delta_(c,i)` per Tanner-graph edge.
- Objective for update 2: `F_delta` with the retained `delta` held fixed.
- Update and schedule: the same preconditioner, search rule, projection, and
  frozen scalar state vector schedule as the control.
- The retained values are not BP messages.  They are a one-update
  check-specific perturbation constructed from partial derivatives of the
  objective function for the native scalar endpoint.

## Closest retained experiments and duplicate gate

- `RQ1-ENDPOINT-001` supplies and validates the graph, channel evidence,
  scalar objective, initialization, preconditioner, backtracking line search
  with strict-decrease acceptance, projection, and current-versus-archived
  native endpoint equivalence.
- `RQ1-STATE-002` removes or restores check-indexed BP
  variable-to-check information.  This experiment does not repeat that BP
  ablation study.
- `RQ1-UPDATE-001` and `RQ1-UPDATE-CYCLE-001` compare a direct BP map with a
  gradient step on a BP fixed-point residual.  This experiment does not use a
  BP fixed-point residual.
- `R3-EDGE-FIXEDPOINT-001` already tested persistent per-edge state with a
  gradient step on a BP fixed-point residual and must not be repeated.
- `R5-PAIR-LIFT-001` tested scalar state plus low-rank pair correlations.  It
  did not implement this mean-preserving intervention that retains and uses
  check-specific values.
- `RQ2-AWGN-001` tests a BP-side `qbar` intervention on locked AWGN cases.  No
  AWGN frame or long-code experiment is executed here.

## Only causal difference

At update 2, the only effective numerical difference among cells is whether a
nonzero, mean-preserving `delta_(c,i)` produced from update 1 is supplied to
the check-local parity products.  All cells calculate the check-indexed values
for aligned diagnostics.  The retention factor selects the state saved at the
update boundary; the use factor selects whether that saved state enters the
next parity calculation.

The active cell necessarily changes both the representation visible to each
check and the parity calculation that uses it.  Therefore this experiment
tests **retaining check-specific values and using them in update 2**, not
storage alone and not the native BP state representation.

## Counterfactual prediction

The three control cells are predicted to be exactly equal.  In the tree case,
bit 2 is the only intervention site at the update boundary: only its retained
`delta` values are nonzero.  Using that distinction in the next
check-local parity calculation may alter update-2 partial derivatives of the
objective function and
scalar proposals at bits 1, 2, or 3.  The
cyclic case is predicted to show an active-cell change in at least one
corresponding diagnostic.  In both cases, all scalar states and diagnostics
must be exactly equal through update 1: divergence is permitted no earlier
than update 2.
A zero active effect is retained as a valid null result; parameters may not be
changed after inspection.

## Anchor case and stopping rule

- One locked three-bit tree anchor followed conditionally by one locked
  three-bit cyclic confirmation, both using the registered vector of channel
  LLRs.
- Exactly two update attempts: native update 1, which must be accepted,
  followed by one registered update-2 attempt per cell, which may stall.
- At most 16 backtracks in the backtracking line search with strict-decrease
  acceptance per update.
- No early syndrome stopping, retuning, restart, sweep, or AWGN expansion.
- A failed update-1 validity gate prevents every update-2 cell for that case
  from running.
- The cyclic case is skipped unless the complete tree result is valid.
- A stall in the backtracking line search with strict-decrease acceptance
  during update 2 is retained as the cell outcome.

## Correctness gates

The experiment is valid only if all of the following pass:

1. The source hashes for the endpoint card, endpoint configuration, endpoint
   implementation, endpoint tests, current native runner, and archived native
   runner match the preregistered values.  The new card, configuration,
   implementation, and tests are hashed into the non-overwriting result
   manifest and copied into its source archive.
2. The tree graph, edge order, channel-evidence convention and values,
   objective weights, initialization, box, step, backtrack limit, and update-1
   rules equal the locked `RQ1-ENDPOINT-001` values; the cyclic graph differs
   only by the preregistered check `{1,3}` and graph-derived degrees.
3. Current and archived native scalar implementations agree exactly before the
   check-indexed values are constructed.
4. The independently implemented native objective, terms, and partial
   derivatives of the objective function match both endpoint implementations
   at `x^(0)`.
5. Native partial derivatives of the objective function at `x^(0)` and
   fixed-`delta` partial derivatives of the objective function at `x^(1)` for
   the zero and active `delta` values pass centered finite differences.
   `delta` remains fixed, and every finite-difference point has in-box check
   readings.
6. `G_i = h_i + sum_c g_(c,i)` at the frozen update-1 state.
7. The arithmetic mean of `G_tilde_(i,c)` equals `G_i` for every nonisolated
   bit.
8. Every degree-one bit has `G_tilde_(i,c) = G_i` and `delta_(c,i) = 0`.
9. Update 1, including its accepted step, raw proposal, projected proposal,
   objective values, and terms, matches a one-update execution of both native
   endpoint implementations.
10. Projection is inactive for the native and local update-1 proposals, and
    every initial active check reading lies strictly inside the box.  If not,
    update 2 does not execute.
11. The `delta` values sum to zero for each bit, and reconstructing
    `x^(1) + delta_(c,i)` gives every local raw proposal.
12. All four cells enter update 2 with exactly equal scalar state `x^(1)`,
    channel LLRs, objective weights, preconditioner, initial step, backtrack
    limit, box, and projection rule.
13. State hashes distinguish retained from collapsed cells, effective-state
    hashes implement the registered use rule, and the three control
    effective states are exactly zero.  The registered retained `delta` must
    be nonzero; an all-zero treatment does not execute update 2.
14. The three control cells have exactly equal objectives, partial
    derivatives, directions, trial sequences, accepted steps, proposals,
    projected states, terms, hard decisions, and syndromes.
15. Composing update 1 with each control update 2 matches a native two-update
    execution from both the current and archived scalar endpoints, including
    terminal state, objective history and terms, accepted-step count,
    evaluation count, and stop status.
16. In the active cell, `delta` remains unchanged while calculating every
    partial derivative of the objective function and throughout the
    backtracking line search with strict-decrease acceptance.
17. Every active current state, trial of the backtracking line search with
    strict-decrease acceptance, accepted state, and centered finite-difference
    point has in-box check readings.
18. Every update-2 direction uses one frozen scalar state vector, every trial
    proposal uses that direction, and every projection matches an independent
    componentwise box projection.
19. Every accepted update strictly reduces its own registered objective; a
    stalled search records all failed trials and changes no state.
20. Hard decisions and syndromes are recomputed independently from the state
    to which they are attached.
21. Reversing the check-row order, then undoing that row and edge permutation,
    preserves the native scalar states, constructed check-indexed values, all
    four update-2 outcomes, and hard decisions within tolerance; syndrome rows
    follow the registered check-row permutation.
22. Every cell in a case has exactly equal scalar states and diagnostics
    through update 1, so any divergence begins no earlier than update 2.
23. The cyclic confirmation executes only after the tree case passes every
    correctness gate and uses the exact registered settings without retuning.
24. Two independent pure calculations have the same canonical scientific
    SHA-256.
25. The retained output archives the configuration, card, implementation,
    tests, endpoint dependencies, native runners, provenance, manifest, and
    SHA-256 checksums, and an existing output directory is never overwritten.

Failure of a counterfactual prediction is not a validity failure.  No parameter
may be changed after inspecting a result under this experiment identifier.

## Retained diagnostics

For both the tree and cyclic cases, the trace retains full-precision values for:

- `x^(0)`, `h_i`, every `g_(c,i)`, `G_i`, every `G_tilde_(i,c)`, `kappa_i`,
  all update-1 trials of the backtracking line search with strict-decrease
  acceptance, `x^(1)`, every local raw proposal, and every `delta_(c,i)`;
- each cell's retained and effective state hashes, fixed objective payload,
  update-2 objective components, partial derivatives of the objective
  function, direction, trial
  sequence, raw and projected proposals, accepted step, hard-decision estimate,
  and syndrome; and
- the registered contrasts: storage-only, use-switch, active versus control,
  and the interaction between retention and use.

The hard decision is `b_i = 1` when the bit-zero-positive scalar `x_i < 0`.
The syndrome is `(H b) mod 2`.

## Decoding-performance metrics

None.  Hard decisions and syndromes are mechanism diagnostics on one toy case;
they do not establish BER, FER, convergence, or transmitted-word recovery on a
code ensemble.

## Operation, runtime, and memory metrics

The runner records method-specific primitive categories rather than one total:

- check-product and leave-one-product evaluations;
- channel, binary, and parity contribution calculations;
- preconditioner divisions;
- objective evaluations by the backtracking line search with strict-decrease
  acceptance;
- projection comparisons; and
- persistent scalar and edge-slot counts for each cell.

Serialization, hashing, source capture, tests, and rendering are diagnostic
work and are excluded from the algorithm-core counts.  Runtime is recorded only
as provenance and is not compared across cells in this toy experiment.

## Interpretation boundary

If only `retained__consumed` changes, this establishes that retaining
check-specific values and using them in update 2 can causally alter a
subsequent partial derivative of the objective function or scalar update on
the tested locked case or cases.  It does not prove
that the construction is BP, reproduce a BP trajectory, establish a decoding-
performance benefit, or uniquely explain the native BP-versus-GD gap.

If the active cell is unchanged, the registered intervention is a valid null
result.
If a later AWGN study is proposed, it requires a new preregistered experiment
card, a fixed work budget, an anchor case, and a held-out confirmation; this toy
result cannot authorize that expansion by itself.
