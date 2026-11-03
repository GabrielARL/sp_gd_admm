# Tied scalar-to-edge reproduction gate

Experiment ID: `RQ2-TIED-SCALAR-EDGE-REPRO-001`

Status: **approved and preregistered; this document was written before any
implementation run or frame evaluation.**

The title is project-defined wording approved by the user. The experiment ID
is an internal identifier, not a receiver name.

## Purpose

The registered ladder from native projected gradient descent (GD) to native
belief propagation (BP) contains one non-atomic handoff:

```text
assigned_frozen_product_unconstrained
    -> edge_product_residual_gradient_tied
```

That handoff simultaneously changes the state coordinates, target, and update
operator. Its outcome change therefore cannot be attributed to any one of
those operations. This gate introduces auxiliary variables after the scalar
lower endpoint and constrains each auxiliary variable to equal its source
scalar. It asks one question only:

> Does actively reading a stored value on every edge of the Tanner graph,
> while constraining every stored value to equal its source scalar at every evaluation,
> reproduce the scalar lower endpoint bit-for-bit?

This is a correctness and equivalence gate. It is not a decoder-performance
comparison and it does not estimate bit error rate (BER).

## Exact lower endpoint

The reference is rung 5 of `RQ2-NATIVE-COMPOSITION-001`,
`assigned_frozen_product_unconstrained`. It is not native projected GD.
Native projected GD has already been given an inactive edge-array null control;
repeating that control would not factor the unresolved rung-5-to-rung-6
handoff.

For each retained case, both arms begin after the registered common update 1.
That update supplies:

- one scalar `x_i` for each coded bit;
- the assigned, frozen check-specific offsets `delta_(c,i)`;
- the update-1 trace and endpoint hashes.

Updates 2 through 30 retain the objective `J_scalar` shown below. No projection
operator constrains a coordinate to the box after update 1. For partial
derivative `g_i` and retained curvature bound `kappa_i`, the direction remains
`d_i = -g_i/kappa_i`. The retained backtracking line search tests
`alpha_k = 0.2 * 2^(-k)` for `k = 0,...,16`, accepts the first trial satisfying
`J_scalar(x + alpha_k d) < J_scalar(x)`, and stops if no tested step satisfies
that inequality. The total budget remains 30 requested updates.

With code length `n`, channel LLR `L_i`, parity weight `w_p`, binary weight
`w_b`, and `N(c)`, the set of variable nodes neighboring check `c` in the
Tanner graph, the retained scalar objective is

```math
J_scalar(x; delta)
 = -1/(2n) sum_i L_i x_i
   - (2 w_p/n) sum_c prod_{j in N(c)} (x_j + delta_(c,j))
   + (w_b/n) sum_i (1 - x_i^2)^2.
```

## Auxiliary variables under equality constraints

Let `E` be the edge set of the Tanner graph. The treatment stores one active
auxiliary variable `z_(c,i)` for every `(c,i)` in `E`:

```math
z_(c,i) = x_i.
```

The treatment objective is

```math
J_tied(x,z; delta)
 = -1/(2n) sum_i L_i x_i
   - (2 w_p/n) sum_c prod_{j in N(c)} (z_(c,j) + delta_(c,j))
   + (w_b/n) sum_i (1 - x_i^2)^2,
subject to z_(c,i) = x_i for every (c,i) in E.
```

Unlike the earlier inactive shadow arrays, `z` is the treatment's authoritative
persistent state and the parity calculation must read it. At each state
boundary, a temporary scalar vector is reconstructed by selecting the first
incident copy in the frozen adjacency order; no copies are averaged. Each
accepted temporary scalar is then broadcast back to every incident edge by
direct assignment. The copies are never independently optimized and are not
BP variable-to-check or check-to-variable messages.

The partial derivative used to update scalar `x_i` is the channel contribution,
the binary contribution, and, for every neighboring check `c`, the partial
derivative with respect to `z_(c,i)`, summed over `c in N(i)`:

```math
g_i
 = -L_i/(2n)
   + (4 w_b/n) x_i (x_i^2 - 1)
   + sum_{c in N(i)} partial J_tied / partial z_(c,i).
```

The implementation must visit checks, check slots, and scalar accumulations in
the reference evaluator's order. This ordering is part of the bit-for-bit
reproduction contract, not a mathematical claim that floating-point addition
is associative.

## The one changed operation

| Field | Reference arm | Tied-copy arm |
|---|---|---|
| Persistent working state | `x_i` for coded bit `i`, plus frozen offsets | `z_(c,i)` on each connected check and bit, all copies with the same `i` constrained equal, plus frozen offsets |
| Values used in the parity term | `x_i` | `z_(c,i)`, subject to `z_(c,i) = x_i` |
| Objective | `J_scalar` | the same objective written using the auxiliary variables and equality constraints |
| Scalar partial derivative | retained evaluator | for every neighboring check, compute `partial J_tied / partial z_(c,i)`, then sum in retained order |
| Update and line search | `d_i = -g_i/kappa_i`; accept the first tested strict decrease | unchanged |
| Projection | none | none |
| Update budget and stopping | updates 2--30 or stop when no tested line-search step decreases the objective | unchanged |

The treatment changes only the representation from which the product for each
check is read. It does not allow copies sharing `i` to differ, change the target,
replace the update operator, change initialization, or add a BP arm.

## Mechanism fingerprint

- Graph state: one auxiliary variable on every edge of the Tanner graph; all
  `z_(c,i)` with the same `i` are constrained to the single value `x_i`.
- Check calculation: negative product term using the active tied auxiliary
  variables and the assigned frozen offsets.
- Scalar update calculation: partial derivatives of the declared objective,
  `d_i = -g_i/kappa_i`, and the retained backtracking line search.
- Information retained across updates: accepted tied edge copies and frozen
  offsets; the temporary scalar is discarded after every accepted update.
- Information deliberately absent: when forming a variable-to-check message,
  BP excludes the incoming check-to-variable message on the edge to the
  receiving check; this recipient exclusion is absent here. The exact
  tanh/atanh check rule, direct recurrence application, and syndrome early
  stopping are also absent.

## Protocol fingerprint

- Repository source endpoint: commit
  `fc98ddde9803869dfb5e62c3810da631a51af27e`.
- LDPC graph: regular `(10200,5100)`, variable degree 3, check degree 6, graph
  seed `169616412`.
- Transmitted word: all zeros.
- Channel: complex additive white Gaussian noise (AWGN) at 6 dB, with channel
  gain fixed to 1 after the fast Fourier transform (FFT).
- Decoder input: the retained vectors of clipped channel LLRs; positive values
  favor coded bit zero.
- Correctness cases only: frames `20001:20024`.
- Passes: primary and deterministic replay, with one Julia, BLAS, and OpenMP
  thread.
- For every frame, digest gates verify equality of the graph, transmitted word,
  transmitted symbols, sampled complex noise vector before SNR scaling,
  received samples, raw channel LLRs,
  clipped channel LLRs, common update-1 scalar state, and frozen offsets across
  the two arms.

These retained cases are suitable for an implementation gate because their
outcomes are already known. They cannot supply new confirmatory performance
evidence.

## Required equality gates

For every current-state evaluation and every trial evaluation, require bitwise
equality of the stored `Float64` representations of:

1. every active auxiliary variable and its source scalar;
2. channel, parity, binary, and total objective values;
3. every `partial J_tied / partial z_(c,i)` and the resulting scalar partial
   derivative after summing over `c in N(i)`;
4. every direction `d_i = -g_i/kappa_i`;
5. every raw trial scalar, evaluated trial loss, accepted step, and trial
   count;
6. every accepted scalar state and frozen-offset state;
7. update acceptance, effective update count, stop status, hard-decision
   estimate, syndrome, number of coded bit errors, and transmitted-word recovery;
8. the complete recorded trace and terminal scientific hash.

The primary and replay passes must also have equal scientific hashes. As a
supporting derivative test, use the symmetric five-point stencil with the
registered perturbation `h = 10^(-6)` and compare its value with each analytical
partial derivative. This numerical test cannot replace the exact reproduction
gates.

## Decision rule

**Pass:** all required equalities hold on all 24 frames in both passes, all
input identities pass, and the primary and replay scientific hashes agree.

**Fail:** any mismatch stops the queue. Preserve the first mismatching frame,
update, trial, field, reference bits, and treatment bits. Do not weaken an
exact gate to a tolerance after observing the mismatch.

No edge-freedom, target, update-rule, or initialization experiment may be
launched by this queue. Those require a separate preregistration after this
gate passes.

## Counterfactual prediction

Because the equality constraint forbids stored values sharing `i` from
differing, the tied-copy arm should reproduce the scalar reference
bit-for-bit. A pass establishes that coordinate replication by itself does not
alter this endpoint. A fail identifies an implementation or floating-point
ordering difference; it does not establish that allowing those stored values
to differ improves decoding.

## Contribution to the causal explanation

If the gate passes, the later handoff can begin from an executable lower
endpoint whose state is stored on edges of the Tanner graph and proven equal
to its scalar source. A subsequent study can then release one operation at a
time--allowing copies sharing `i` to differ, changing the target,
update rule, or initialization--without bundling the coordinate change into
every comparison.

The gate alone does not explain the recovery difference between native BP and
native projected gradient descent. It creates an executable lower endpoint
with proven equality for the later causal factorization.

## Closest retained attempts and non-duplication gate

- `shadow_edge_state` allocates arrays that the scalar calculation never
  reads. This treatment requires the parity calculation to read the tied edge
  copies.
- `assigned_frozen_product_unconstrained` is the reference being reproduced,
  not a new treatment result.
- `edge_product_residual_gradient_tied` changes the target and update operator
  together with the state coordinates. This gate retains the scalar target and
  update operator.
- `RQ2-DIRECT-CHECK-MAP-001` tests a direct map over values stored on graph
  edges and did not pass its retained validation gate. It is not the scalar
  objective written with auxiliary variables under equality constraints and is
  not evidence for this gate.
- Echo-GD retains independently updated values for each connected check and
  bit. This gate forbids such independent history.

Therefore the gate is not a renamed rerun of an existing mechanism fingerprint.

## Artifacts required before launch

The launch package must contain a checksum-bound source freeze, configuration,
runner, unit tests, retained-input identity manifest, queue contract, progress
record, append-only phase log, and result manifest. It must refuse to overwrite
an existing result directory and must stop before any future experiment if a
gate fails.
