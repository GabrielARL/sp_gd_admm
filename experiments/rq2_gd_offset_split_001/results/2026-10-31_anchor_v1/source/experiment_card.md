# `RQ2-GD-OFFSET-SPLIT-001` four-arm AWGN ablation

Status before execution: **preregistered design only; implementation,
preflight, source freeze, and input freeze must pass before any registered
endpoint is calculated**.

`RQ2-GD-OFFSET-SPLIT-001` is an internal experiment ID, not a receiver name.
ADMM is outside this experiment.  This experiment does not add a BP arm.

## Research question

The retained result `RQ2-GD-STATE-USE-001` showed that jointly using one
retained offset `delta_(c,i)` per Tanner-graph edge in both

1. the parity term of the objective function, through `x_i + delta_(c,i)`;
   and
2. the interval used by the projection step

changed the projected-gradient trajectory and improved recovery on its locked
200-case AWGN sample.  Because both operations changed together, that result
did not identify which operation produced the recovery difference.

This follow-up asks:

> When the retained scalar and edge-shaped state, graph, received samples,
> channel LLRs, initialization, update budget, and all other declared rules are
> held fixed, what are the separate and joint effects of using the retained
> offsets in the parity calculation and using them to restrict the interval
> for the projection step?

This is a causal decomposition of the constructed projected-gradient
intervention.  It is not a native BP-versus-projected-GD comparison.

## Mechanism and state held fixed

Every arm retains:

- one scalar `x_i` for bit `i`; and
- one bounded, mean-zero offset `delta_(c,i)` for each Tanner-graph edge.

Every arm calculates and refreshes the offsets with the same bounded-mean
construction after an accepted scalar update.  The offsets are fixed during
the next calculation of partial derivatives and throughout every trial of its
backtracking line search.  The two experimental factors change only where
those already-retained offsets are read.

For `n = 10200`, parity weight `mu_p = 2`, and binary weight `mu_b = 0.2`,
define

```text
F_delta(x) = -ell'x/(2n)
           + mu_p/n * sum_c
               (1 - product_{i in c}(x_i + delta_(c,i)))^2
           + mu_b/n * sum_i (1 - x_i^2)^2.
```

Setting every effective offset to zero gives the native scalar objective
`F_0(x)`.

When the interval factor is enabled, bit `i` is projected into

```text
max_c(-1 - delta_(c,i)) <= x_i <= min_c(1 - delta_(c,i)).
```

When it is disabled, bit `i` is projected into the native interval
`[-1,1]`.

## Registered four-arm design

The factor `O` specifies whether the parity calculation reads the retained
offsets.  The factor `P` specifies whether the projection step uses
the interval induced by those offsets.

| Arm ID | `O`: parity calculation | `P`: interval used by projection |
|---|---|---|
| `objective0__bounds0` | `F_0(x)` | `[-1,1]` |
| `objective1__bounds0` | `F_delta(x)` | `[-1,1]` |
| `objective0__bounds1` | `F_0(x)` | offset-induced interval |
| `objective1__bounds1` | `F_delta(x)` | offset-induced interval |

`objective0__bounds0` is the native projected-gradient control.
`objective1__bounds1` is the compound intervention tested in
`RQ2-GD-STATE-USE-001`.  The two other arms are the missing single-operation
counterfactuals.

All four arms must have exactly equal scalar states, retained offsets,
partial-derivative vectors, and accepted scalar updates through update 1.  At
the start of update 2, they must again read exactly equal `x` and `delta`
states.  The registered factors may first change a calculation at update 2.

## Domain caveat for `objective1__bounds0`

The objective-only arm uses shifted readings `x_i + delta_(c,i)` while
projecting `x_i` only into `[-1,1]`.  A shifted reading can consequently leave
`[-1,1]`.

This arm must not silently clip a shifted reading, replace the objective,
activate the offset-induced interval, or be discarded because an overshoot
occurs.  Any such action would add a third intervention.  Instead, the arm
uses the declared polynomial expression for `F_delta`, keeps every scalar
`x_i` in `[-1,1]`, and records for every current state, line-search trial, and
accepted state:

- the number of shifted readings outside `[-1,1]`; and
- the maximum distance beyond either endpoint.

Shifted readings are required to remain in `[-1,1]` in both arms with `P=1`.
The `O=1,P=0` measurements must be reported beside its outcome.  If overshoot
is material, the conclusion must state that parity-objective use alone was
tested without the local-value feasibility restriction supplied by the other
factor.

## Protocol fingerprint

- Known unit-gain post-FFT complex AWGN; no pilots, channel estimation, CFO,
  or ICI.
- Unit-energy QPSK and the all-zero transmitted word.
- Regular `(3,6)` LDPC graph with `N=10200`, `K=5100`, graph seed
  `169616412`, and graph SHA-256
  `94d94376995c6eb9e21a5859dde6354d7233f61634b5dbdc91fd70653f5f6e2d`.
- Physical `Es/N0 = 6 dB`; complex-noise variance
  `0.251188643150958`.
- Channel LLRs are positive in favor of coded bit zero and clipped to
  `[-20,20]` before initialization.
- Initialization `x_i^(0) = tanh(ell_i/2)`, weights `mu_p=2`, `mu_b=0.2`,
  native diagonal preconditioner, initial step `0.2`, at most 16 halvings,
  30 update attempts, and no syndrome early stop.
- One Julia thread and one BLAS/OMP thread.
- Each arm receives one untimed deterministic synthetic length-`N` LLR-vector
  warm-up with no channel-frame identity.  Warm-up output is excluded from
  every endpoint.
- The four starting positions are balanced by a deterministic cyclic arm
  order over frame index.  An arm starts in each position equally often in
  both the 24-case and 200-case sets.

The development anchor is frames `20001:20024`.  The held-out set is frames
`30001:30200`.  Both use noise seed `20261012 + frame`.  They are disjoint
from each other and from every case in `RQ2-GD-STATE-USE-001`.

The generated unit noise, received samples, raw and clipped channel LLRs,
transmitted word, and graph identity for all 224 cases must be frozen before
any registered endpoint is calculated.  The held-out set remains disabled
until the anchor passes every correctness and provenance gate.  Outcome
direction is not an expansion gate: a null, reversed, or interacting anchor
still proceeds to the held-out set when correctness passes.

## Closest retained experiments and anti-duplicate decision

- `RQ2-GD-STATE-USE-001` compared only `O=0,P=0` with `O=1,P=1`.  Its
  favorable result is the compound effect being decomposed here.
- `RQ1-GD-STATE-USE-001` crossed retention with subsequent use on two toy
  graphs.  It did not separate parity-objective use from the interval used by
  projection and supplied no long-code recovery outcome.
- `R5-AWGN-ISOLATION-R050-001` supplies the native scalar control, graph, and
  AWGN protocol, but has no retained-offset counterfactual.

No retained source, result, branch, or attempt record contains the two missing
single-operation arms under this locked long-code protocol.  This experiment
is therefore a causal refinement of the retained bridge, not a new receiver
route, parameter study, or duplicate.

## Preregistered causal contrasts

For a binary endpoint `Y_OP` on one frozen case, where `O,P` are zero or one,
the four simple effects are

```text
objective use with native interval:       tau_O|P0 = mean(Y_10 - Y_00)
objective use with induced interval:      tau_O|P1 = mean(Y_11 - Y_01)
induced interval with native objective:   tau_P|O0 = mean(Y_01 - Y_00)
induced interval with shifted objective:  tau_P|O1 = mean(Y_11 - Y_10).
```

The fifth contrast is the interaction

```text
tau_OP = mean(Y_11 - Y_10 - Y_01 + Y_00).
```

The two contrasts against `Y_00`, `tau_O|P0` and `tau_P|O0`, are the primary
single-operation contrasts.  The two contrasts conditioned on the other
factor and the interaction determine whether a factor acts consistently or
only in combination.  All five contrasts are retained regardless of sign.

## Endpoints and inference

The two registered confirmatory endpoints are:

1. equality of the hard-decision estimate to the transmitted word; and
2. satisfaction of every parity check.

Information-word equality, coded- and information-bit errors, syndrome
weight, wrong-valid-word count, accepted steps, fractional coordinates,
objective components, offset norms, overshoot diagnostics, runtime,
allocation, and method-specific work are supporting outputs.

For each endpoint, the four pairwise simple-effect comparisons use paired
success counts, two-sided exact McNemar tests, and Newcombe method-10 paired
risk-difference intervals.  The eight pairwise tests, four contrasts for each
of two endpoints, form one family and receive Holm correction at familywise
alpha `0.05`.  The registered simultaneous interval confidence level is
`0.99375`.

The interaction is calculated case by case from the complete four-arm outcome
vector.  Its uncertainty is a paired-case percentile bootstrap: resample the
complete four-arm vector as one unit, use seed `20261031`, perform `100000`
resamples, and report a two-sided 95% interval.  This interaction interval is
descriptive and is not an additional pass/fail gate.

Parity validity is not treated as equality to the transmitted word.  Objective
decrease is not treated as decoding success.

## Work budget and stopping rule

- Exactly four arms per case and at most 30 update attempts per arm.
- Anchor: 24 cases, 96 arm runs, at most 2,880 arm updates per scientific
  pass.
- Held-out: 200 cases, 800 arm runs, at most 24,000 arm updates per scientific
  pass.
- Exactly two scientific passes, `primary` and `replay`; the second pass
  verifies the canonical scientific hash and is not a new sample.
- At most one untimed synthetic warm-up per arm and one timed execution per
  arm and case, as declared in the configuration.
- No SNR sweep, parameter sweep, restart, extra frame, change in objective
  weight, offset construction, initial step, update budget, or stopping rule
  is permitted under this experiment ID.
- A line-search stall is retained as that arm's outcome.  No extra budget is
  granted after a stall.
- Anchor wall-clock service budget: 1,800 seconds.  Held-out wall-clock
  service budget: 18,000 seconds.  The queue does not restart automatically.
  A technically interrupted attempt is retained; any manual relaunch must use
  the immutable frozen command and a new attempt directory, without changing
  the scientific protocol.

## Correctness gates before interpretation

1. The configuration, card, runner, tests, prior experiment sources and
   retained results, native source, JadeJcade project, and graph pass their
   registered source and checksum locks.
2. The input freeze contains exactly the 24 registered anchor identities and
   200 registered held-out identities and is complete before either endpoint
   set executes.  The two ranges are disjoint and do not overlap the prior
   experiment.
3. Every arm physically allocates one length-`N` scalar array and the same
   edge-shaped offset arrays.  Every arm uses the same offset construction and
   refresh rule; only the two registered Boolean factors differ.
4. All four arms are bitwise equal through update 1.  At update 2 they enter
   with bitwise-equal `x` and `delta`, and at least one retained offset is
   nonzero.
5. On the exposed regression cases, `objective0__bounds0` reproduces the
   archived native control path bit for bit and `objective1__bounds1`
   reproduces the archived compound arm path bit for bit.
6. With `O=0`, the objective, components, and partial derivatives equal the
   native `F_0` implementation.  With `O=1`, independent finite differences
   validate the partial derivatives while `delta` remains fixed.
7. With `P=0`, the projection interval is exactly `[-1,1]`.  With `P=1`, it
   equals an independently calculated intersection of the intervals induced
   by the retained offsets.  Every projected scalar agrees with an independent
   componentwise calculation.
8. The bounded-mean offset construction passes its box, sum, optimality,
   inactive-projection, boundary, and degree-one checks against an independent
   oracle.
9. The offsets remain unchanged throughout every calculation of partial
   derivatives and line-search trial and are refreshed only after an accepted
   update.  Every accepted update strictly reduces that arm's registered
   fixed-offset objective.
10. Every scalar state and scalar trial remains in `[-1,1]`.  Every shifted
    reading remains in `[-1,1]` for `P=1`.  For `O=1,P=0`, every overshoot is
    retained and reported without clipping or changing the arm.
11. Independent hard-decision and syndrome calculations agree with the
    recorded endpoints.  Check-row and local-edge relabeling preserve
    canonicalized results.
12. All arms report zero decoder, BP, normalized-min-sum, pseudogradient,
    word-list, and oracle calls.  Diagnostic validation code is not reachable
    from an arm's update path.
13. The one-thread environment, deterministic warm-up, balanced four-arm
    execution order, trace-free timing path, and equality of timed and traced
    terminal states pass.
14. Both pure scientific passes have the same canonical scientific SHA-256.
    The checksum manifest is complete, extra files are rejected, an existing
    output is never overwritten, and the progress record is written
    atomically after each completed frame.

Failure of a predicted scientific effect is not a correctness failure.  The
held-out run is authorized after the correctness gates pass, regardless of
the anchor's outcome ordering.

## Registered interpretation map

- If `O=1,P=0` improves recovery while `O=0,P=1` does not, use of the offsets
  in the parity calculation is sufficient under the native interval on this
  protocol.
- If `O=0,P=1` improves recovery while `O=1,P=0` does not, the changed
  projection interval is sufficient with the native objective on this
  protocol.
- If both single-operation arms improve recovery, both mechanisms have
  separable effects; their conditional effects and interaction determine how
  they combine.
- If neither single-operation arm improves recovery but `O=1,P=1` does, the
  evidence supports a coupled intervention rather than either operation alone.
- If the compound arm does not reproduce its favorable ordering on the new
  held-out sample, report failed transfer; do not select a nearby SNR or tune
  the construction.

## Claim boundary

A valid result can causally attribute the outcome difference among the four
constructed projected-gradient variants under the locked graph, 6 dB AWGN
sample, initialization, and 30-update budget.  It can show whether the prior
compound effect is associated with parity-objective use, the interval used by
projection, both, or their interaction.

It cannot show that the offsets are BP messages, reproduce BP, prove a
general BER or FER ordering, establish equal computational complexity, or
uniquely explain the complete performance difference between native BP and
native projected GD.  A later bridge must still hold the resulting
representation fixed while changing one native calculation or update operator
at a time.
