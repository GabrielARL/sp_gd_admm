# `RQ2-GD-STATE-USE-001` controlled AWGN ablation

Status before execution: **amended preregistered design; source freeze and
executable gates required before a registered active-arm endpoint may be
calculated**.

### Pre-freeze governance amendment

During independent code review, a validator accidentally executed three active
updates on frame 1 and observed an intermediate coded-error count.  It did not
run the registered 30-update endpoint, and the observed value was not
communicated to the primary experiment runner.  Frame 1 is nevertheless
quarantined.  The anchor is mechanically shifted from frames `1:24` to frames
`2:25`, replacing only the exposed frame with the immediately following
retained frame.  This amendment was made before source or input freeze and
before any registered endpoint was run.  The confirmation set was not exposed
and remains unchanged.

`RQ2-GD-STATE-USE-001` is an internal experiment ID, not a receiver name.
ADMM is outside this experiment.

## Research question

On the native projected-gradient backbone, does using a retained distinction
for each connected check change whether the hard-decision estimate satisfies
every parity check or equals the transmitted word?

This is the RQ2 transfer of `RQ1-GD-STATE-USE-001`.  That toy experiment
established a two-update trajectory change, but its hard-decision estimates and
syndromes did not change.  The present experiment asks whether the registered
interaction reaches a decoding outcome on a long loopy code.

## One causal difference

Both arms calculate and physically retain one bounded, mean-preserving offset
for each Tanner-graph edge after every accepted update.  The control ignores
the retained offsets in the next parity calculation.  The active arm uses
them.  No BP, normalized-min-sum, pseudogradient, word list, or oracle call is
part of either arm.

The treatment therefore tests the interaction between retaining a
check-specific distinction and making it visible to the next parity
calculation.  It does not isolate allocation or storage alone.

## Method fingerprints

### Control

- Persistent scalar state: one scalar `x_i` for bit `i`.
- Diagnostic retained state: one offset `delta_(c,i)` for each connected
  check, allocated and refreshed but ignored by the next update.
- Objective used for every update: the native fixed scalar objective `F_0`.
- Update: partial derivatives of `F_0`, the native diagonal preconditioner,
  backtracking line search, and componentwise projection onto `[-1,1]`.
- Stopping rule: 30 update attempts or the first line-search stall.

### Active arm

- Persistent state: the same scalar vector and edge-shaped offset arrays.
- Objective used during update `t+1`: `F_delta` with the offsets constructed
  after accepted update `t` held fixed through every trial.
- Update: the same preconditioner and initial step.  Scalar projection uses the
  interval implied by the fixed offsets so that every value entering a parity
  calculation remains in `[-1,1]`.
- The offsets are refreshed only after an accepted update.

The active arm is a controlled projected-gradient variant.  Because its
retained offsets change after accepted updates, it is not descent on one fixed
objective and is not BP.  The offsets are not messages.

## Native objective and check-associated contributions

For `n=10200`, parity weight `mu_p=2`, and binary weight `mu_b=0.2`,

```text
F_delta(x) = -ell'x/(2n)
           + mu_p/n * sum_c
               (1 - product_{i in c}(x_i + delta_(c,i)))^2
           + mu_b/n * sum_i (1 - x_i^2)^2.
```

The control supplies zero as the effective offset, giving `F_0`.  At a frozen
state, write the partial derivative for bit `i` as

```text
G_i = h_i + sum_{c in N(i)} g_(c,i),
```

where `h_i` contains the channel and binary contributions and `g_(c,i)` is
the contribution associated with check `c`.  For degree greater than one,

```text
G_tilde_(i,c) = h_i
              + degree(i)/(degree(i)-1)
                * sum_{a in N(i), a != c} g_(a,i).
```

The arithmetic mean of `G_tilde_(i,c)` over the checks connected to bit `i`
is `G_i`.  For degree one, the constructed value is `G_i`.

## Bounded mean-preserving construction

The toy construction assumed that the native and local proposals were strictly
inside the box.  A control-only long-code preflight, performed without an
active outcome, showed that native update 1 projects thousands of coordinates.
Copying the unbounded toy offsets would therefore make many parity inputs leave
`[-1,1]`.

After an accepted update with step `alpha`, first form the local raw proposals

```text
q_(c,i) = x_i_before - alpha * G_tilde_(i,c) / kappa_i.
```

For each bit independently, calculate the Euclidean projection of its local
proposal vector onto

```text
z_(c,i) in [-1,1]
mean_{c in N(i)} z_(c,i) = x_i_after.
```

Then retain

```text
delta_(c,i) = z_(c,i) - x_i_after.
```

This operation has no fitted coefficient.  It guarantees that the offsets sum
to zero for each bit and that every retained local value is in the box.  When
the native proposal and all local proposals are already inside the box, the
projection is inactive and the construction reduces to the registered toy
rule exactly.

During the next active update, the fixed offsets imply the scalar interval

```text
max_c(-1 - delta_(c,i)) <= x_i <= min_c(1 - delta_(c,i)).
```

The control uses zero effective offsets, so this interval is exactly
`[-1,1]` and its path must reproduce native projected gradient descent.

## Protocol fingerprint

- Known unit-gain post-FFT complex AWGN; no pilots, channel estimation, CFO,
  or ICI.
- Unit-energy QPSK and the all-zero transmitted codeword.
- Regular `(3,6)` LDPC graph with `N=10200`, `K=5100`, graph seed
  `169616412`, and graph SHA-256
  `94d94376995c6eb9e21a5859dde6354d7233f61634b5dbdc91fd70653f5f6e2d`.
- Physical `Es/N0=6 dB`.  At rate one half this is also the retained
  information-bit `Eb/N0` label.  The complex-noise variance is
  `0.251188643150958`.
- Channel LLRs are positive in favor of coded bit zero and clipped to
  `[-20,20]` before initialization.
- Initialization `x_i^(0)=tanh(ell_i/2)`, weights `mu_p=2`, `mu_b=0.2`,
  initial step `0.2`, at most 16 halvings, native curvature bound, 30 update
  attempts, and no syndrome early stop.
- One Julia thread and one BLAS/OMP thread.
- Before timing, each arm receives one untimed deterministic synthetic
  length-`N` LLR-vector warm-up with no channel-frame identity.  It is excluded
  from every outcome.  Control runs first on odd frame indices and active runs
  first on even frame indices.

The amended anchor uses frames `2:25`, with noise seed `20261012 + frame`.  The
separate confirmation set is frames `10001:10200`.  Both sets' generated unit
noise, received samples, raw and clipped channel LLRs, transmitted word, and
graph identities must be frozen before any active anchor outcome is calculated.
Only the 24 anchor cases are initially authorized to execute.

## Closest retained experiments and anti-duplicate decision

- `RQ1-GD-STATE-USE-001` is the two-update toy precursor.  It has no
  decoding-performance outcome.
- `R5-AWGN-ISOLATION-R050-001` supplies the native scalar objective, graph,
  6 dB control outcomes, and exact historical source.  It has no retained-and-
  used arm.
- `BPGD-RQ2-QBAR-AWGN-001` establishes an outcome consequence for removing a
  recipient-specific BP distinction.  It is an exact-sum-product ablation,
  not this projected-GD intervention.

The present experiment is therefore a causal RQ2 transfer rather than a new
receiver route, a parameter study, or a duplicate.

## Correctness gates before interpretation

1. The configuration, card, runner, tests, RQ1 precursor, historical native
   source, retained 6 dB table, JadeJcade project, and graph pass their
   registered source and checksum locks.
2. The freeze contains exactly 24 amended-anchor and 200 confirmation
   identities and is written before registered active endpoints.  Anchor received-sample and clipped-LLR
   hashes reproduce the retained table.
3. The control reproduces the archived native solver's scalar path bit for bit
   and reproduces every registered terminal field in the 24 retained 6 dB
   rows.
4. The bounded mean projection satisfies its box, sum, optimality, inactive-
   projection, and degree-one tests.  On the retained toy cases it reproduces
   the registered first two updates with the projection inactive.
5. Both arms have equal scalar and offset states through update 1.  At least
   one nonzero offset is consumed at update 2.
6. Independent finite differences validate every active partial derivative at
   every accepted update.  The offsets remain unchanged throughout each
   finite-difference and line-search calculation.  The diagnostic probes use
   the unconstrained polynomial extension and may cross a local feasibility
   boundary; they are not candidate states or line-search trials.
7. Every active scalar proposal is projected independently onto the interval
   induced by the fixed offsets.  Every value used by the actual update and
   line search remains in `[-1,1]`.
8. Independent hard-decision and syndrome calculations agree.  Check-row and
   local-edge relabeling preserve canonicalized results.
9. Both arms allocate the same persistent scalar and edge-shaped state arrays.
   Logical retained-state counts, the persistent-state footprint, whole-run
   allocation, runtime, and operation categories are reported separately.
10. The controlled solver source has no decoder, normalized-min-sum,
    pseudogradient, list, or oracle call path, and its structural call fields
    are zero.  Deterministic replay, checksum, and non-overwrite gates pass.

## Registered outcomes

The primary endpoint is equality of the hard-decision estimate to the
transmitted codeword.  The safety endpoint is satisfaction of every parity
check.  Wrong-valid-word count is reported separately.  Supporting
diagnostics are coded- and information-bit errors, syndrome weight, accepted
steps, fractional coordinates, objective values, offset norms, projection
activity, runtime, whole-run allocation, persistent-state footprint, and
method-specific work.

Parity validity is not treated as transmitted-word recovery.  Objective
decrease is not treated as decoding success.

## Anchor decision and stop rule

The anchor is a development gate, not confirmatory inference.  Expansion to
the already frozen 200 cases is authorized only if:

1. every correctness and provenance gate passes;
2. active-only transmitted-word recoveries exceed control-only recoveries;
3. the active parity-valid count is not lower than the control count.

If the anchor is null or reversed, retain it and stop this construction.  Do
not change the SNR, frames, objective weights, feasibility projection, step,
update budget, or stopping rule under this experiment ID.

If expansion is authorized, the anchor is not pooled into confirmation.  The
confirmation reports paired discordances for transmitted-word equality and
parity validity, two-sided exact McNemar tests with Holm correction, and 97.5%
Newcombe method-10 paired risk-difference intervals.  Both active-only and
control-only outcomes remain visible.

## Claim boundary

A favorable result would show that making this constructed retained
check-specific distinction visible to subsequent parity calculations can
improve recovery on the native projected-gradient backbone under the locked
protocol.  It would not show that the offsets are BP messages, reproduce BP,
isolate storage alone, or uniquely explain the complete native BP-versus-GD
performance difference.

A null or reversed result would reject this executable bridge.  The next
research branch would isolate the BP check calculation, parity representation
or objective, or direct BP update versus gradient step rather than tune this
construction.
