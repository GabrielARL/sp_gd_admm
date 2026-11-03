# Shared edge-value trajectory reproduction gate

Experiment ID: `RQ2-COMMON-COORDINATE-REPRO-001`

Status: **approved and prospectively registered before implementation and
before evaluation of any retained case.**

The experiment ID is an internal identifier, not a receiver name.

## Classification and purpose

This is a retained-case validation and exact trajectory-reproduction gate for
the later causal ladder. It is not an ablation, a decoder-performance
comparison, or a new estimate of bit error rate (BER) or frame error rate
(FER).

The gate asks one question:

> Can native projected gradient descent (GD) and native exact sum-product
> belief propagation (BP) each be reproduced while exposing their persistent
> state as values in `[-1,1]` stored on the Tanner-graph edge set, without
> changing either native numerical trajectory, schedule, method-specific
> iteration cap, stopping rule, or hard-decision rule?

The gate isolates no causal mechanism. It validates an interface required to
change one operation at a time in a later, separately registered ladder.

## Shared edge-value interface

`Common bounded coordinate` is project-specific shorthand for the direct
definition below: both lanes store values in `[-1,1]` on the Tanner-graph edge
set. It is not a receiver name, an established algorithm name, or a claim that
the values have the same semantics in GD and BP.

Let `E` be the edge set of the retained Tanner graph. The shared numeric
interface is

```math
z_{c,i}\in[-1,1], \qquad (c,i)\in E.
```

The coordinate has a different method-specific meaning in the two lanes.

### Projected-GD lane

Native projected GD retains one scalar `x_i` for bit `i`. Its edge-coordinate
view is a direct tied copy,

```math
z_{c,i}=x_i \quad\text{for every }c\in N(i).
```

All copies belonging to bit `i` must remain exactly equal. They are not BP
messages and are not independently optimized. The native compound objective,
partial derivatives that form its objective-function gradient, diagonal
curvature preconditioner, strict-decrease backtracking, componentwise box
projection, initialization, update budget, stall rule, hard-decision rule, and
syndrome calculation remain unchanged. The parity calculation must actively
read the tied edge copies in the native check-slot order; channel and binary
terms read the exactly collapsed scalar state. Every accepted scalar state is
broadcast to its incident copies by direct assignment.

### BP lane

Native exact sum-product BP retains directed variable-to-check messages
`Q_(i->c)` and check-to-variable messages `U_(c->i)` in the log-likelihood
ratio (LLR) domain. Its persistent bounded variable-to-check coordinate is

```math
z^{(t)}_{i\to c}
=\tanh\!\left(\frac{\operatorname{clip}(Q^{(t)}_{i\to c},-20,20)}{2}\right).
```

Unlike GD's tied copies, these values remain recipient-specific. Define
`eta = tanh(10)`. One BP message-passing iteration is reproduced as

```math
m^{(t)}_{c\to i}
=\prod_{j\in N(c)\setminus i}z^{(t-1)}_{j\to c},
```

```math
U^{(t)}_{c\to i}
=\operatorname{clip}\!\left(
2\operatorname{atanh}\!\left(
  \operatorname{clip}(m^{(t)}_{c\to i},-\eta,\eta)
\right),-20,20\right),
```

```math
\Lambda_i^{(t)}=L_i+\sum_{c\in N(i)}U^{(t)}_{c\to i},
\qquad
Q^{(t)}_{i\to c}=\Lambda_i^{(t)}-U^{(t)}_{c\to i},
```

```math
z^{(t)}_{i\to c}
=\tanh\!\left(\frac{\operatorname{clip}(Q^{(t)}_{i\to c},-20,20)}{2}\right).
```

Products, sums, and edge visits must follow the retained native adjacency
order. `Q` must be recorded before its transformation to `z`; the runner must
not reconstruct `Q` with `2*atanh(z)`, because clipping makes that round trip
non-invertible and not bit-reversible.

### Initial coordinate equality

The retained channel LLRs are clipped to `[-20,20]`. Therefore both lanes begin
with

```math
z^{(0)}_{c,i}=x_i^{(0)}
=\tanh\!\left(\frac{L_i}{2}\right).
```

This is an exact initialization identity in the frozen implementation. It does
not make later GD tied copies and BP recipient-specific messages semantically
interchangeable.

## Method fingerprints

### Native projected GD and its coordinate reproduction

- Persistent decoder state: one scalar `x_i` for each coded bit.
- Channel evidence: retained clipped channel LLR vector; positive values favor
  coded bit zero.
- Parity representation: native smooth compound parity contribution.
- Update: sum the applicable partial derivatives into each scalar coordinate,
  apply the retained diagonal preconditioner and strict-decrease backtracking,
  then project every trial coordinate onto `[-1,1]`.
- Weights: parity weight `w_p=2.0` and binary weight `w_b=0.2`.
- Curvature bound:
  `kappa_i=(2*w_p*degree(i)+8*w_b)/10200`.
- Line search: initial step `0.2`, at most 16 backtracks, and accept only a
  finite trial whose objective is strictly smaller than the current value.
- Schedule: calculate the full scalar direction from the frozen current state,
  then update all scalar coordinates simultaneously.
- Initialization: `x_i^(0)=tanh(L_i/2)`.
- Budget and stopping: at most 30 requested gradient-update attempts or the
  first line-search stall; no syndrome early stop.
- Hard decision and validity: bit `i` is one exactly when `x_i<0`; evaluate the
  syndrome over GF(2).
- Coordinate reproduction: direct tied edge copies actively supply the parity
  products but add no independent degrees of freedom.

### Native exact sum-product BP and its coordinate reproduction

- Persistent decoder state: directed variable-to-check and check-to-variable
  LLR messages.
- Channel evidence: the same retained clipped channel LLR vector listed above.
- Check calculation: native exact tanh/atanh check-node operation with the
  retained clamp and native check-slot order.
- Variable calculation: channel LLR plus check-to-variable messages, excluding
  the intended recipient when forming a variable-to-check message.
- Schedule: flooding message-passing iterations with zero damping.
- Initialization: `Q^(0)_(i->c)=L_i` and `U^(0)_(c->i)=0`.
- Budget and stopping: stop at the first valid syndrome or after 80
  message-passing iterations.
- Hard decision and validity: bit `i` is one exactly when its a-posteriori LLR
  is negative; evaluate the syndrome over GF(2).
- Coordinate reproduction: persist the transformed variable-to-check state
  `z`; calculate temporary products `m`, exact `U`, `Lambda`, and exact `Q` in
  the native floating-point order.

## Protocol fingerprint

- Code and graph: regular `(10200,5100)` LDPC code, variable degree 3, check
  degree 6, graph seed `169616412`.
- Transmitted word: all zeros.
- Channel: complex additive white Gaussian noise (AWGN) at 6 dB, channel gain
  fixed to 1 after the fast Fourier transform (FFT), with registered noise
  variance `0.251188643150958`.
- Decoder evidence: retained raw and clipped channel LLR vectors; positive LLR
  favors coded bit zero.
- Validation cases only: retained frame IDs `20001:20024`.
- No frame ID or noise realization outside the retained set and no performance
  inference.
- Passes: primary and deterministic replay.
- Threads: one Julia, BLAS, and OpenMP thread.
- Execution order: GD native reference, GD coordinate reproduction, BP native
  reference, BP coordinate reproduction for each retained case.

Input identity gates cover the graph, adjacency order, transmitted bits,
transmitted symbols, sampled complex noise before SNR scaling, received
samples, raw channel LLRs, and clipped channel LLRs.

## Retained oracle binding

Before evaluating a case, the runner must verify the retained
`RQ2-NATIVE-COMPOSITION-001` v2 Job-03 artifact tree at
`results/2026-11-01_v2/03_native_endpoint_and_rung_gate`:

- `COMPLETED.toml`: `dad9a542b39049cd5635eed41572f78e18a45d00486688f8fcb12f64ba58e22b`;
- `job_gate.toml`: `e7ebae26eb91269eaf2a450ef6bad3736d68fcceaf5cee76ec950d3e728ecc09`;
- `science.json`: `6f7039e1172a81f4e6e641d6aaf9a0554b66ab856689ad2009d2188fc04a34eb`;
- `frames.csv`: `3d401dbe7abcd5807755fe4b0ded6e92952e716c8b57c26972dc228272fdeed2`;
- `iterations.csv`: `6775f27af9d219bd6a521b618da4c4159255bd09d9e951548635c1b2c3089af2`.

That retained result binds the validated endpoints, tables, and prior
mathematical checks. Its CSV tables do not contain every directed-message or
line-search value. Therefore the new runner must calculate and compare the
full within-run trajectories; retained table hashes cannot substitute for the
new exact gates.

## Required correctness gates

Stop at the first failed gate, preserve the first mismatch with its frame,
iteration or trial, field, reference bits, and reproduced bits, and mark the
run `complete_invalid`. Do not weaken an exact gate after observing a failure.

1. **Frozen-source and input identity.** Verify every registered source digest,
   graph digest, retained-case digest, and input identity before evaluating the
   two reproductions.
2. **Native projected-GD oracle.** Reproduce the retained native endpoint and
   retained trace oracle before testing the coordinate view.
3. **GD edge-value equality and active use.** At initialization, every
   current-state evaluation, every raw and projected line-search trial, and
   every accepted state, require exact IEEE-754 equality for tied copies,
   objective components, total objective, check-associated partial
   derivatives, accumulated scalar partial derivatives, preconditioned
   direction, trial loss, acceptance decision, step, accepted state,
   hard-decision estimate, syndrome, status, and terminal trace hash. The
   maximum spread among copies belonging to one bit must be exactly zero. The
   parity kernel must receive `z_(c,i)` while scalar `x_i` is unavailable to its
   check products. An active-read counter must equal 61,200 per objective
   evaluation--one forward and one reverse read of every edge slot--and a
   focused poison test must hold `x` fixed, perturb one edge copy, and show that
   exactly the intended check calculation changes.
4. **Native BP LLR oracle.** Reproduce the retained exact sum-product endpoint
   and direct LLR-domain trajectory before testing the bounded coordinate.
5. **BP edge-value equality and active use.** For every message-passing
   iteration, require exact IEEE-754 equality of each transformed check input,
   temporary product, calculated `U`, a-posteriori LLR, newly calculated `Q`,
   hard-decision estimate, syndrome, stop iteration, and terminal `Q` and `U`.
   Require `z` to equal the registered transform of the just-recorded `Q`
   exactly. Verify every temporary product independently in the retained
   check-slot order. The check kernel must receive `z_(i->c)` with `Q`
   unavailable and must not reconstruct `Q`. An active-read counter must equal
   153,000 per check phase, and a focused poison test must hold `Q` fixed,
   perturb one `z` value, and show that the return value on that same edge is
   unchanged while the other five outgoing values from that check change.
6. **Replay equality.** Primary and replay scientific, frame-table, and
   iteration-table hashes must agree.
7. **Evidence boundary.** Assert that exactly 24 retained cases were evaluated,
   that no frame ID or noise realization outside `20001:20024` was evaluated,
   and that no BER or FER inference is emitted.

The already complete-valid native-composition Job 03 binds the retained
derivative and exact-check enumeration gates. This study does not rerun or
retune those tolerance-based diagnostics; its new scientific gates are the
exact trajectory and active-use gates above. A failure of a source, retained
oracle, exact trajectory, active-use, or replay gate makes this job invalid.

## Counterfactual prediction and decision rule

Prediction: both native decoders will reproduce exactly in the registered
bounded edge coordinate on all 24 retained cases in both passes.

**Pass:** all seven gate groups pass and the replay hashes equal their primary
counterparts.

**Fail:** any mismatch stops the queue and preserves the first failure. No
downstream ladder arm launches automatically.

## Closest retained work and anti-duplication gate

- `RQ2-NATIVE-COMPOSITION-001` supplies the native projected-GD and exact-BP
  endpoint oracles; it does not expose both trajectories through this bounded
  edge interface.
- `RQ2-TIED-SCALAR-EDGE-REPRO-001` proves a tied edge representation for a
  constructed lower endpoint, not native projected GD and exact BP together.
- `RQ2-BOUNDED-EDGE-FREEDOM-001` releases edge freedom for a constructed boxed
  objective; it does not reproduce the native pair in this coordinate.
- `RQ2-EXACT-MAP-UPDATE-001` compares application rules for an exact map; it is
  not a coordinate-equivalence gate.
- A direct-check-map design that mixes a raw bounded check output with an
  LLR-domain variable update is, by definition, outside this reproduction
  gate and must not be substituted for the registered recurrence.
- A check-average or `qbar` view discards recipient-specific BP distinctions
  and cannot satisfy this gate.

## Permitted conclusion

A pass permits only this claim:

> On retained frames `20001:20024`, native projected GD and native exact
> sum-product BP were each reproduced using values in `[-1,1]` stored on the
> Tanner-graph edge set, with exact native-trajectory and replay gates.

It does not show that the two methods have the same state semantics, objective,
check calculation, update operator, schedule, work, memory, or stopping rule.
It does not explain the native recovery gap. It establishes the validated
edge-value interface from which a later one-operation-at-a-time ladder can be
registered.

Runtime and memory measurements, if emitted, are implementation diagnostics
only. This gate makes no equal-work, equal-operation-count, or equal-memory
claim: in particular, the BP reproduction may cache transformed edge values
where the native kernel reevaluates the transformation.

