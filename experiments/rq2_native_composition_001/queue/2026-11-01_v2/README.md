# RQ2 bridge from native projected GD to native BP

`RQ2-NATIVE-COMPOSITION-001` is the endpoint-spanning experiment that connects
the repository's native projected-gradient decoder to its native exact
sum-product decoder.  It does not assume that an observed native-method
ordering identifies a cause.  Instead, it executes a preregistered sequence of
decoder variants, checks both native endpoints, and records the outcome change
between adjacent variants on every coded frame.

The campaign is registered as exactly seven jobs.  A job may start only after
all gates from its predecessor pass.  Failure, interruption, a pre-existing
output directory, or a deterministic-replay mismatch stops the queue; it is
never resumed or silently retuned.

## Why this experiment is needed

The retained 6 dB attribution set contains a native recovery difference of 93
of 200 cases: native projected GD recovered 107 transmitted words and native
exact sum-product recovered 200.  That set located the difference but could
not identify its cause because the native methods change state coordinates,
parity calculation, objective, projection, update operator, budget, and
stopping rule together.

The forward registry places the completed GD-side and BP-side controls into one
ordered executable composition:

```text
native projected GD
  -> inactive arrays with one slot per directed edge     [exact null]
  -> assigned/frozen compound objective with box
  -> assigned/frozen product-only objective with box
  -> assigned/frozen product-only objective, no box
  -> tied edge coordinates; gradient descent on the product-map residual
                                                            [joint handoff]
  -> tied edge coordinates; gradient descent on the exact sum-product residual
  -> separate outgoing values; gradient descent on that residual
  -> direct exact sum-product; read the terminal state after 30 updates
  -> direct exact sum-product; stop at first zero syndrome, cap 30
  -> native exact sum-product; stop at first zero syndrome, cap 80
```

The scalar-to-edge-coordinate handoff is deliberately marked **non-atomic**.  It
changes state coordinates, domain, and target together because no equality-
preserving adapter between those declared scalar and edge-coordinate problems is
currently available.  The queue may measure the outcome change across this
handoff, but it must call the change a joint remainder.  It must not assign the
change to one factor.  A nonzero joint remainder means that this campaign has
not completed a single-factor decomposition of the native gap.

The inactive-shadow rung has a stronger null gate than a single endpoint
comparison.  With the zero shadow allocated but never read, the runner performs
a second independent projected-GD run and requires the recorded objective
trajectory, terminal scalar bits, terminal offsets, hard word, syndrome,
update counts and status, registered losses, and terminal terms to agree.  Both
runs must also reproduce the native projected-GD oracle.

## The seven jobs

| Order | Job ID | Role |
|---:|---|---|
| 1 | `01_switch_registry_gate` | Validate the exact eleven-rung registry, the ten adjacent transitions, and the non-atomic claim boundary. |
| 2 | `02_common_harness_gate` | Run toy and implementation gates: derivatives, projection, exact local check calculation, zero shadow allocation without reading it, output schemas, and deterministic replay. |
| 3 | `03_native_endpoint_and_rung_gate` | Exercise every rung on retained frames `20001:20024`; require native endpoint reproduction and every registered adjacent-difference gate before any fresh case is read. |
| 4 | `04_fresh_dual_snr_anchor` | Run frames `60001:60024` at 6 dB and 1.5 dB.  Outcomes are unknown and cannot gate on direction.  The measured timing sets later wall budgets. |
| 5 | `05_six_db_forward_transfer` | Run all eleven forward rungs prospectively on frames `60025:60224` at 6 dB. |
| 6 | `06_six_db_order_controls_and_attribution` | Complete the two registered 2-by-2 controls on the prospective 6 dB cases, then map transitions descriptively on locked frames `30001:30200`. |
| 7 | `07_second_snr_confirmation` | Run the eleven-rung forward composition on fresh frames `60225:60424` at 1.5 dB. |

Job 6 adds exactly two variants that are not on the shortest forward path:
`assigned_frozen_compound_unconstrained` completes the parity-objective by
projection control, and `exact_sp_direct_tied_fixed30` completes the control
that crosses separate outgoing values with the update operator.  These four-cell
comparisons test interaction within the GD-side and BP-side blocks.  They show
whether attribution along the registered path depends on the paired factor;
they do not execute the sequential ladder in reverse order.  They also do not
turn the non-atomic scalar-to-edge-coordinate handoff into an atomic
comparison.

Job 6 keeps two evidence groups separate.  The `60025:60224` cases remain the
fresh prospective 6 dB group.  The locked `30001:30200` group must reproduce
the retained endpoint counts exactly: 107 native projected-GD recoveries, 200
native exact-sum-product recoveries, and a net gap of 93.  Those locked counts
are a gate and descriptive transition map, not fresh confirmation.

## The exact sum-product endpoint oracle

The direct exact sum-product recurrence is also run for 80 updates as a
separate endpoint oracle.  Its update-30 terminal state supplies the fixed-30
rung.  Its first zero-syndrome state within 30 updates supplies the next rung;
if none occurs, that rung uses the update-30 terminal state.  The following
transition changes only the cap from 30 to 80.

Thus `exact_sp_direct_full_fixed30` to
`exact_sp_direct_full_stop30` isolates the stopping/readout rule while holding
the recurrence and 30-update cap fixed.  The next transition to
`native_exact_sum_product` retains first-zero-syndrome stopping and isolates
the iteration cap, 30 versus 80.

When native BP reaches zero syndrome, the oracle's first zero-syndrome endpoint
must agree with it in the stopping update, hard word, posterior floating-point
bits, and both variable-to-check and check-to-variable arrays.  When native BP
does not reach zero syndrome by update 80, the two update-80 terminal states
must instead agree bit-for-bit in the hard word, posterior, both directed
arrays, and syndrome weight.  Thus a native failure is gated as carefully as a
native recovery.

## Recorded outputs

For each rung and frame, the campaign records terminal transmitted-word
recovery, parity validity, coded-bit errors, syndrome weight, update count,
stop status, state hash, and hard-word hash.  It records first
transmitted-word recovery and first parity-valid update where the underlying
implementation supplies them.  Job timing is recorded separately.  The
campaign does not promise line-search, operation-count, allocation,
peak-memory, or stored-state metrics.

## What a completed campaign can claim

For an atomic adjacent transition, a paired outcome change is causal for that
registered intervention on the prospective coded frames only if all endpoint,
correctness, replay, and input-identity gates pass.  A unique additive case
count additionally requires no material factorial interaction and no
path-conditioned recovery/loss pattern.  Otherwise the campaign reports the
effect along its declared path.

The result field `native_gap_accounted` means only that the signed adjacent net
changes add arithmetically to the difference between the two native endpoints.
That telescoping identity is a consistency check.  It is not independent
causal evidence and does not make the non-atomic handoff attributable.

The locked `30001:30200` cases are used only to describe how the previously
known 93-case difference moves through the rungs.  They cannot confirm a
causal effect.  The fresh 6 dB and 1.5 dB cases supply the prospective evidence.
Even a complete-valid result remains scoped to this LDPC graph, channel model,
SNRs, frame ranges, decoder settings, and work budgets; it is not a general BER
claim over a code ensemble.

## Files

- `experiment_card.md`: scientific question, controls, gates, and claim limit.
- `config.toml`: code, channel, frame, and validation settings read by the
  runner.
- `rung_registry.toml`: exact ordered decoder fingerprints and transition
  atomicity.
- `campaign_registration.toml`: immutable seven-job order and expansion gates.
- `attempts/2026-11-01_v1/`: first-attempt freeze and queue specifications.

No result is claimed merely because these files exist.  A scientific result
requires a checksum-bound freeze, a locked queue package, complete primary and
replay passes, endpoint equality, and a result manifest.
