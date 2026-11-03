# Registered bounded-recurrence residual under the tied common coordinate

Experiment ID: `RQ2-COMMON-COORDINATE-TARGET-001`

Status: **design-audited prospective card only. No implementation, source
freeze, fresh case, queue, service, or scientific run is authorized by this
card.** The experiment ID is an internal identifier, not a receiver name.

`Target` in the internal ID means the calculation used to define the
objective. The reader-facing description is **objective-calculation change**.

## Why this rung is needed

The complete native composition reaches native exact sum-product belief
propagation (BP) from native projected gradient descent (GD), but its scalar-
to-directed-edge handoff changes the persistent state, the calculation being
applied, and the update operator together. That handoff cannot support a
single-mechanism claim.

`RQ2-COMMON-COORDINATE-REPRO-001` subsequently validated on retained frames
`20001:20024` that both native trajectories can be represented exactly with
values in `[-1,1]` stored on the Tanner-graph edge set. It established a
retained-case numerical interface, not common state semantics. The present
prospective rung uses only the tied projected-GD side of that interface and
asks whether changing the objective calculation changes recovery while the
projected-GD update protocol remains fixed.

## Research question

> Under one tied bounded state and one fixed projected-GD update protocol,
> does replacing the native compound objective with the normalized full
> residual of the registered bounded-coordinate recurrence change the
> trajectory or the terminal hard-decision estimate?

The treatment is a constructed projected-descent arm on a declared objective.
It uses ordinary partial derivatives on smooth regions and the registered
generalized-derivative selection at clamp kinks. It is not BP: it does not
retain recipient-specific state, directly apply the BP map, or use BP's
syndrome-based stopping rule.

## Single registered intervention

The two arms differ only in the objective calculation and the partial
derivatives of that objective.

| Field | Control | Treatment |
|---|---|---|
| Persistent decoder state | one scalar `x_i` for bit `i` | same |
| Edge view | tied copies `z_(i->c)=x_i` | same |
| Objective | native compound projected-GD objective | normalized full registered-recurrence residual restricted to tied state |
| Direction | negative preconditioned native partial derivatives | negative preconditioned treatment partial derivatives |
| Initialization | `x_i^(0)=tanh(L_i/2)` | same |
| Equality constraint | all copies for bit `i` are equal | same |
| Box | componentwise `[-1,1]` | same |
| Preconditioner | frozen native diagonal preconditioner | same |
| Line search | first finite strict decrease in the arm's declared objective | same rule |
| Attempt budget | 30 requested update attempts or first stall | same |
| Syndrome early stop | absent | absent |
| Hard decision | bit one exactly when `x_i<0` | same |

Accepted steps and later states may differ because each arm evaluates its own
registered objective. Such differences are consequences of the intervention,
not additional protocol changes.

## Tied state geometry

Let `n` be the number of coded bits and let `E` be the set of directed
variable-to-check edge slots. For edge `e=(i->c)`, let
`d_i=|N(i)|`. Define the replication matrix `B` and diagonal weight `W` by

```math
(Bx)_{i\to c}=x_i,
\qquad
W_{(i\to c),(i\to c)}=\frac{1}{d_i}.
```

Define

```math
C=B^{\mathsf T}W,
\qquad
P=BC.
```

The implementation must verify

```math
B^{\mathsf T}WB=I_n,
\quad
CB=I_n,
\quad
P^2=P,
\quad
P^{\mathsf T}W=WP.
```

Thus `B` is an isometry from the scalar state into the weighted tied-edge
space, `C` averages incident edge values for each bit, and `P` is the
`W`-orthogonal projection onto the tied manifold. The persistent state remains
`x`; the edge view `Bx` has no independent degrees of freedom. These tied edge
values are optimization variables, not BP messages.

## Control objective

The control is the exact native projected-GD objective reproduced by
`RQ2-COMMON-COORDINATE-REPRO-001`. With channel log-likelihood ratios `L_i`,
parity weight `w_p=2`, binary weight `w_b=0.2`, and check neighbourhood
`N(c)`,

```math
J_{\mathrm{GD}}(x)
=-\frac{1}{2n}\sum_i L_i x_i
 +\frac{w_p}{n}\sum_c
    \left(1-\prod_{j\in N(c)}x_j\right)^2
 +\frac{w_b}{n}\sum_i(1-x_i^2)^2.
```

Its objective components, partial derivatives, accumulation order,
preconditioned direction, raw and projected trials, acceptance decisions,
accepted states, stop status, hard-decision estimate, and syndrome must
reproduce the retained native implementation bit-for-bit before the treatment
is eligible for any fresh case.

## Registered bounded-coordinate recurrence

The treatment uses the validated common-coordinate recurrence directly. It
must never reconstruct an LLR with `2*atanh(z)`, because the registered clips
make that transformation non-invertible.

Let `eta=tanh(10)`. For a bounded variable-to-check edge vector `z`, define

```math
p_{c\to i}(z)
=\prod_{j\in N(c)\setminus\{i\}}z_{j\to c},
```

```math
U_{c\to i}(z)
=\operatorname{clip}\!\left(
2\operatorname{atanh}\!\left[
\operatorname{clip}(p_{c\to i}(z),-\eta,\eta)
\right],-20,20\right),
```

```math
\Lambda_i(z)
=L_i+\sum_{d\in N(i)}U_{d\to i}(z),
\qquad
q^+_{i\to c}(z)=\Lambda_i(z)-U_{c\to i}(z),
```

```math
\Phi_{i\to c}(z)
=\tanh\!\left(
\frac{\operatorname{clip}(q^+_{i\to c}(z),-20,20)}{2}
\right).
```

Here `L_i` is the retained clipped decoder LLR. The implementation must form
`Lambda_i` by starting from `L_i`, adding every incident `U` in retained edge
order, and only then subtracting the recipient's `U`. A direct leave-one-out
sum is algebraically equal but is not guaranteed to be Float64-bit equal.
Products, sums, and edge visits follow the retained adjacency and slot order.
On states reachable by native bounded BP, this is the exact validated native
recurrence. Projected GD may produce `x_i=+/-1`, while the BP transform produces
`|z_e|<=eta<1`. The raw-`z`, product-clamped calculation above is therefore
registered as a frozen saturated extension over the rest of `[-1,1]^E`. The
name `Phi` refers to this complete registered recurrence: native-exact on the
BP-reachable subdomain and extended elsewhere. The implementation must not add
a per-edge input clip. Every evaluation records whether any `|x_i|>eta` and
which registered clamps are active.

## Treatment objective

Define the full recipient-specific residual at the tied state,

```math
r(x)=Bx-\Phi(Bx).
```

The treatment objective is the mean weighted squared residual per coded bit,

```math
H_{\mathrm{tie}}(x)
=\frac{1}{2n}r(x)^{\mathsf T}Wr(x).
```

The `1/d_i` edge weights prevent a bit from receiving more objective weight
only because it has more incident checks. The factor `1/n` matches the native
objective's extensive normalization: both objectives are `O(1)`, their
partial derivatives are `O(1/n)`, and the inherited preconditioned direction
remains `O(1)`. The factor is frozen before implementation and may not be
tuned. Division by `|E|` is forbidden because `W` already averages the
incident edges of each bit.

Where the registered clamps are differentiable,

```math
\nabla H_{\mathrm{tie}}(x)
=\frac{1}{n}B^{\mathsf T}
\left(I-J_\Phi(Bx)\right)^{\mathsf T}
W\left[Bx-\Phi(Bx)\right].
```

The native diagonal entries

```math
\kappa_i=\frac{2w_p d_i+8w_b}{n}
```

remain a frozen inherited preconditioner in both arms. They are not claimed to
be curvature bounds for `H_tie`.

## Why the residual is not averaged first

Let

```math
\psi(x)=C\Phi(Bx).
```

Then the weighted orthogonal decomposition is

```math
\frac{1}{2n}\|Bx-\Phi(Bx)\|_W^2
=\frac{1}{2n}\|x-\psi(x)\|_2^2
 +\frac{1}{2n}\|(I-P)\Phi(Bx)\|_W^2.
```

Using only the first term would silently discard the recipient-specific
disagreement produced by the registered recurrence. It would create a different,
mean-target experiment and would force a later release of the tied state to
change both state freedom and objective. Therefore `P` may be used for
geometry checks and diagnostics, but `Phi(Bx)` must not be projected before
the treatment residual is formed.

## Fixed update protocol

For either objective `F` in `{J_GD,H_tie}`, calculate a direction-input vector
`g(F,x)` from the frozen current state. For the control and for treatment
points in a smooth region, `g` is the ordinary partial-derivative vector. At a
treatment clamp kink, it uses the registered generalized-derivative selection
defined below. Set

```math
d_i=-\frac{g_i(F,x)}{\kappa_i}.
```

Try, in order,

```math
\alpha_b=0.2\,2^{-b},\qquad b=0,1,\ldots,16,
```

with

```math
x_{\mathrm{trial}}=\Pi_{[-1,1]^n}(x+\alpha_b d).
```

Accept the first finite trial whose own arm objective is strictly lower than
the current value. If none passes, retain the current state and stop with a
line-search stall. Otherwise continue until 30 requested update attempts.
Both arms calculate the direction simultaneously from the frozen
current state. Neither arm stops early on a valid syndrome.

## Derivative convention

The implementation uses a registered generalized-derivative selection for
each clamp: one in its strict interior and zero outside or exactly on its
boundary. The zero selected at a kink is an algorithmic convention, not an
ordinary partial derivative. Consequently, the treatment is ordinary gradient
descent only on smooth regions; at a kink it uses this prospectively fixed
selection within the otherwise unchanged projected-descent machinery.

Symmetric finite differences are permitted only at deterministic points that
have a registered positive margin from every product and LLR clamp boundary
and from the state-box boundary `|x_i|=1`. At a registered map-clamp boundary,
test the zero selection from the active, clipped outward side and separately
record the nonmatching inward slope that exposes the kink. At `x_i=+/-1`, use
an inward constrained directional check; test the box projection itself as a
separate operator. The analytic vector-Jacobian product must also pass
independent dot-product tests at states and along directions with positive
kink margin. A derivative implementation from the earlier
check-to-variable LLR-state experiment may not be reused unchanged because the
present input coordinate and transformation chain differ.

## Protocol fingerprint

- Graph: regular `(10200,5100)` LDPC code, variable degree 3, check degree 6,
  graph seed `169616412`.
- Transmitted word: all zeros.
- Channel evidence: complex additive white Gaussian noise with unit channel
  gain after the fast Fourier transform; raw and clipped channel LLRs are
  retained and positive values favor coded bit zero.
- Compatibility cases: retained frames `20001:20024` at 6 dB only. They are
  validation cases and cannot support performance inference.
- Intended confirmatory strata: 6 dB and 1.5 dB, with a descriptive 24-case
  anchor and a paired 200-case transfer at each level.
- Fresh frame ranges: deliberately **unassigned** in this design-only card.
  Allocation, source freeze, and explicit launch approval are required before
  implementation may evaluate a fresh case.
- Threads: one Julia, BLAS, and OpenMP thread.
- Passes: primary and deterministic replay.
- Arm order: after frame ranges are assigned, the first frame in each anchor
  and transfer runs control first, the next runs treatment first, and this
  outer order alternates by frame ordinal. Each arm starts from an independently
  regenerated copy of the verified input and initialization. Objective
  evaluations within an arm retain the registered arithmetic order.

The transfer expansion gate may read only source identity, input identity,
finite-value, geometry, derivative, active-use, projection, completion, and
deterministic-replay fields from the anchor. It may not depend on recovery
counts, contrast direction, effect size, p-value, interval, syndrome weight,
or coded-bit errors. No parameter may change between anchor and transfer.

Input identity covers the graph and adjacency order, transmitted bits and
symbols, sampled complex noise before SNR scaling, received samples, raw
channel LLRs, and clipped channel LLRs.

## Required pre-run gates

Every gate fails closed. Preserve the first mismatch and evaluate no fresh
case after a compatibility failure.

1. **Source and predecessor identity.** Pin the source tree and verify the
   complete-valid common-coordinate result, including science SHA-256
   `c9398e5bb2c82e1d0f4cf6df1d0c8bdf21aee7ad7150719cfc1c8bba0c65244d`.
2. **Native control reproduction.** Reproduce the control bit-for-bit on all
   24 compatibility frames in primary and replay passes, including every
   registered objective, partial derivative, trial, decision, state, hard
   word, syndrome, and stop field.
3. **Geometry identities.** Verify `B'WB=I`, `CB=I`, `P^2=P`, and
   `P'W=WP`, plus exact equality among all tied copies at initialization,
   every objective evaluation, every projected trial, and every accepted
   state.
4. **Recurrence primal oracle.** Reproduce the validated common-coordinate
   `Phi` values in retained edge order. Forbid inverse reconstruction,
   per-edge input clipping, raw-product/LLR addition, and a projected or
   averaged target.
5. **Independent treatment derivation.** Verify the objective decomposition,
   an independently calculated primal residual, vector-Jacobian dot products,
   and the analytic treatment partial derivatives.
6. **Finite differences and kinks.** Before any retained case, create and
   freeze `numerical_gate_registry.toml`. It must contain the exact synthetic
   point seeds, long-code coordinate and direction IDs, number of checks,
   finite-difference step sizes, absolute and relative tolerances, minimum
   product-clamp, LLR-clamp, and state-box margins, vector-Jacobian dot-product
   tolerances, outward map-clamp perturbations, and inward state-box
   perturbations. Pass those deterministic checks plus separate projection
   checks. The registry may be calibrated only with synthetic points; retained
   or fresh outcomes may not set its values.
7. **Active-use and poison checks.** Prove that the treatment reads the full
   recipient-specific output before tied pullback. Perturb one intended edge
   input and verify the registered affected and unaffected outputs.
8. **Projection and line search.** Verify the common direction scaling,
   trial order, componentwise box projection, finite-value test, strict
   decrease, first-accepted trial, stall behavior, and 30-attempt cap.
9. **Off-domain-extension accounting.** Record every evaluation containing
   `|x_i|>eta` and all active-clamp counts; silently clipping tied inputs is a
   gate failure.
10. **Outcome boundary.** Verify the common hard-decision and syndrome
    calculation, no syndrome early stop, and no treatment access to the
    transmitted word.
11. **Fresh-case seal.** Register nonoverlapping frame ranges before building
    a freeze and prove that neither implementation nor its tests evaluated
    them before the immutable freeze was created.
12. **Replay.** Require primary and replay scientific, frame-table, and
    iteration-table hashes to agree.

A line-search stall with finite registered values is a decoder outcome, not a
harness failure. A nonfinite value, derivative failure, source mismatch,
control mismatch, use of an averaged target, untied state, input-identity
failure, or replay mismatch makes the attempt `complete_invalid`.

## Work and memory accounting

The 30-attempt cap is a common update budget, not an equal-work budget. For
each arm and case, record separately:

- requested and accepted updates;
- current-state objective-and-direction evaluations;
- line-search objective-only evaluations and projections;
- calls to the native compound evaluator;
- treatment calls to `Phi` and to its vector-Jacobian product;
- counts of products, `tanh`, `atanh`, clips, scalar accumulations, and edge
  reads under a declared counting rule; and
- persistent values retained between updates, peak temporary values, elapsed
  time, and allocated bytes.

Runtime and allocation diagnostics use one Julia, BLAS, and OpenMP thread.
Before fresh cases, warm up each arm once on retained frame 20001, exclude the
warm-up, then measure five full decoder repetitions per arm with alternating
outer order. Run allocation measurement separately from timing, invoke garbage
collection before rather than inside each measured repetition, and report the
five values plus median and interquartile range. These diagnostics do not
enter the recovery decision rule. No result may claim equal computational work
or equal memory from the common attempt cap.

## Measurements and inference for a later approved run

For every arm, case, and requested update, retain objective value, partial-
derivative norm, preconditioned-direction norm, raw and projected trial
hashes, accepted step, trial count, state hash, hard-decision hash, syndrome
weight, coded-bit errors, stop status, transmitted-word recovery, and parity
validity. For the treatment also retain both terms of the orthogonal residual
decomposition, active-clamp counts, and visits with `|x_i|>eta`.

The paired 200-case transmitted-word-recovery risk difference is primary in
each SNR stratum. Use two-sided exact McNemar tests and Holm control at
familywise `alpha=0.05` over the two SNR-level primary contrasts. Report a
two-sided 97.5% paired Newcombe method-10 interval for each risk difference so
the two intervals have Bonferroni simultaneous 95% coverage. Report raw and
Holm-adjusted p-values, discordant-pair counts, risk differences, and
intervals. Anchors are descriptive and cannot enter this family.

For the finite registered cases, the paired difference is the causal effect
of the registered intervention on those cases whether or not it is
statistically significant. Inferential evidence for a nonzero effect in an SNR
stratum requires both a Holm-adjusted two-sided p-value below 0.05 and its
simultaneous interval to exclude zero. Generalization remains bounded to the
registered graph, channel generator, SNR, budgets, and case-sampling rule.
Objective magnitudes from the two arms must not be compared as if they were
the same physical quantity merely because both are normalized.

## Counterfactual prediction and decision rule

- A nonzero paired recovery contrast is the finite-registered-case,
  path-conditional causal effect of replacing the objective calculation under
  the fixed tied-state and projected-GD update protocol. The inferential claim
  additionally requires the registered familywise decision rule above.
- A zero contrast does not prove that the BP calculation is irrelevant under
  recipient-specific state or direct map application.
- A change in accepted steps, clamp activity, or state trajectory is an
  expected downstream consequence and must be reported rather than treated as
  a protocol mismatch.

## Anti-duplication gate

- `RQ2-COMMON-COORDINATE-REPRO-001` validates the coordinate interface but
  changes no objective.
- `RQ2-TIED-SCALAR-EDGE-REPRO-001` reproduces a different unboxed
  product-only construction.
- `RQ2-BOUNDED-EDGE-FREEDOM-001` removes edge-copy equality and found that
  generic edge freedom was harmful under its compound objective. The present
  card keeps equality fixed.
- `RQ2-BP-TARGET-STATE-UPDATE-001` and `RQ2-EXACT-MAP-UPDATE-001` operate on
  recipient-specific check-to-variable LLR state. They already establish an
  interaction between residual-gradient descent and direct map application;
  this card does not reclaim that result.
- `RQ2-DIRECT-CHECK-MAP-001` deliberately mixed correlation-domain products
  with an LLR-domain update. Its formal `complete_invalid` status came from a
  failed registered update-one Float64 structural-equality gate. Both facts
  make it ineligible as a substitute for the registered bounded recurrence
  here.
- `RQ2-NATIVE-COMPOSITION-001` identifies the bundled state-target-update
  handoff. The present experiment constructs a separate common-coordinate
  path that isolates an objective-calculation change, addressing one component
  of that unresolved bundle; it is not a literal insertion between the old
  rungs.

No existing local ref or worktree has the same fingerprint: tied common
bounded state, native projected-GD update protocol, and a full residual of the
registered bounded-coordinate recurrence calculated before any tied
projection.

## Permitted conclusion

If every gate passes, a later result may say only:

> Under the registered tied common bounded state and native projected-GD
> update protocol, replacing the native compound objective calculation with
> the normalized full residual of the registered bounded-coordinate
> recurrence--native-exact on the BP-reachable subdomain and using the frozen
> saturated extension elsewhere--changed recovery by the measured paired
> amount.

It may not say that the treatment is BP, that the BP check rule alone caused
the change, that the native BP endpoint was reproduced, or that the complete
native BP-versus-projected-GD performance gap was decomposed. Releasing
recipient-specific state and replacing gradient descent with direct map
application remain separate later rungs.

## Explicit blockers before implementation or launch

1. Assign and seal fresh frame ranges for both SNR strata.
2. Implement the primal map and an independently testable vector-Jacobian
   product.
3. Freeze the fully numeric derivative/kink gate registry using synthetic
   points only.
4. Pass the derivation, exact control-reproduction, active-use, finite-
   difference, projection, input, and replay tests on retained cases.
5. Create a new immutable source freeze and measured wall-budget derivation.
6. Obtain explicit approval for implementation/freeze and, separately, for
   launching scientific cases.

Until all six are closed, no queue or service may exist for this experiment.
