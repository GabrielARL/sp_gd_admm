# `RQ2-NATIVE-COMPOSITION-001`

Status: **registered bridge between native endpoints; no scientific result has
been produced by this registration.**

This identifier is an internal experiment ID, not a receiver name.

## Research question

Can the observed recovery difference between native projected gradient descent
and native exact sum-product be traced through an endpoint-gated sequence of
controlled interventions, and which registered operations causally change
transmitted-word recovery on prospective AWGN cases?

## Mechanisms being isolated

The registry tests the following operations in a fixed order:

1. allocation of inactive arrays with one slot for each directed edge;
2. use of assigned, frozen check-specific readings in the scalar objective;
3. compound squared parity residual versus the product-only scalar objective;
4. componentwise box projection versus no projection;
5. a declared joint handoff from scalar state to edge coordinates in which a
   bit's outgoing values are tied;
6. product-based versus exact sum-product state calculation in the directed-
   edge coordinates;
7. one tied outgoing value per bit versus a separate variable-to-check value
   for each neighboring check;
8. a gradient step on the declared residual objective versus direct
   application of the exact sum-product recurrence;
9. reading the terminal state after 30 updates versus stopping at the first
   zero syndrome under the same 30-update cap; and
10. retaining that stopping rule while increasing the cap from 30 to 80
    message-passing iterations.

The ninth transition changes only the stopping/readout rule: it compares the
update-30 terminal state with the first zero-syndrome state through update 30,
falling back to that same update-30 terminal state when no zero syndrome is
reached.  The tenth transition retains the first-zero-syndrome rule and changes
only the message-passing iteration cap from 30 to 80.

The fifth item is not an isolated mechanism.  The scalar and edge-coordinate
problems have different state coordinates, domains, and targets.  Their handoff
is therefore registered as `atomic = false` and `attributable = false`.  No
result may describe its outcome change as the effect of state alone, target
alone, domain alone, or an optimizer alone.

## Operational definition

The eleven decoder fingerprints and ten transitions are defined in
`rung_registry.toml`.  Every scientific frame is evaluated by every applicable
rung from a frozen vector of channel LLRs.  Adjacent outcome accounting records
both directions: newly recovered transmitted words and earlier recoveries
lost.  The signed adjacent changes must telescope from the first native
endpoint to the last native endpoint for each frame set.

An inactive shadow array is allocated and filled with zeros, but the native
projected-GD calculation does not read it.  The runner then performs a second,
independent projected-GD run.  The null gate requires equality of the recorded
objective-trace hash, terminal scalar floating-point bits, terminal offsets,
hard word, syndrome, accepted and requested update counts, stop status,
registered loss values, and terminal terms; both runs must also reproduce the
native projected-GD oracle.  This full recorded-trajectory and endpoint gate
separates inactive storage from later use of check-specific state.

For atomic transitions, the fingerprint validator requires every unregistered
field to remain unchanged.  The non-atomic handoff instead emits one joint
remainder.  Downstream code is required to reject any report that assigns a
single-factor recovery count to it.

## Method fingerprints

### Native projected-GD endpoint

- Persistent dynamic state: one scalar `x_i` for each coded bit.
- Objective: channel term, compound squared parity-residual term, and binary
  term with the retained native weights.
- Update: the gradient of the objective function, retained diagonal
  preconditioner, first-strict-decrease backtracking, and componentwise
  projection onto `[-1,1]`.
- Protocol: 30 requested updates or a line-search stall; no syndrome early
  stop.

### Native exact sum-product endpoint

- Dynamic state: directed variable-to-check and check-to-variable values on
  Tanner-graph edges.
- Variable-node calculation: the channel LLR plus incoming values from all
  other neighboring checks, excluding the recipient check.
- Check-node calculation: the retained exact tanh/atanh sum-product rule.
- Protocol: flooding schedule, no damping, and stopping at the first zero
  syndrome or after 80 message-passing iterations.

The scalar objective's partial derivatives and check-associated contributions
are not BP messages.

## Protocol fingerprint

- Regular `(10200,5100)` LDPC graph, variable degree 3, check degree 6, and
  graph seed `169616412`.
- All-zero transmitted word.
- Known-unit-gain post-FFT complex AWGN.
- Channel LLR convention: positive values favor coded bit zero; values are
  clipped to `[-20,20]` at decoder input.
- Fresh correctness anchor: frames `60001:60024` at 6 dB and 1.5 dB.
- Prospective 6 dB transfer: frames `60025:60224`.
- Informed 6 dB transition map: locked frames `30001:30200`.
- Fresh 1.5 dB confirmation: frames `60225:60424`.
- Every scientific stage has primary and deterministic-replay passes with one
  Julia, BLAS, and OpenMP thread.

Frames `20001:20024` are retained correctness cases used only before the fresh
anchor.  Their known outcomes cannot supply confirmatory evidence.

## Closest retained experiments

- `RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001` established the assigned/frozen
  constructed scalar state.
- `RQ2-GD-RESIDUAL-PROJECTION-BUDGET-001` supplied the parity-objective by
  projection control.
- `RQ2-BP-TARGET-STATE-UPDATE-001` supplied the control that crosses separate
  outgoing values with the update operator on the exact sum-product target.
- `RQ2-NATIVE-GAP-001` supplied the native endpoint ordering but made no causal
  attribution.

This experiment composes those controls.  It is not a renamed rerun of any one
of them.

## Only causal differences

Each transition marked atomic changes the single operation named in
`rung_registry.toml`.  The transition from
`assigned_frozen_product_unconstrained` to
`edge_product_residual_gradient_tied` is the sole registered exception and is
never eligible for a single-operation causal statement.

Job 6 completes two four-cell controls:

1. compound versus product-only scalar objective crossed with box projection
   versus no projection; and
2. one tied outgoing value per bit versus a separate variable-to-check value
   for each neighboring check, crossed with gradient descent on
   `R_s(u) = 0.5 ||u-F_s(u)||_2^2` versus direct application of `F_s`.

For the second control, `F_s` is the registered exact sum-product recurrence
under state rule `s`; the equation defines the local residual objective used
by its gradient-descent cells.

These controls test whether the effect assigned to either factor depends on
the other factor along the registered path.  They are factorial interaction
tests, not executions of the sequential ladder in reverse order, and they do
not provide a reverse bridge through the joint scalar-to-edge-coordinate
handoff.

## Counterfactual predictions

- Allocating the inactive zero arrays must not alter the supplied scalar-state
  bits or their hard decision.  Any change invalidates the harness.
- Atomic transitions may recover some failures and may also lose previous
  successes; both counts are primary evidence.
- A material interaction in either four-cell control prevents a unique
  additive allocation between its two factors.
- A nonzero outcome change across the joint handoff remains a bundled causal
  remainder.  It triggers a further factorization study rather than a
  single-factor conclusion.
- If both native endpoints reproduce, the signed adjacent changes must equal
  the measured native endpoint difference on each frame set.

No success-count direction is preregistered for a fresh frame set, and no arm
may be tuned after its outcome is observed.

## Seven-job execution and stopping rule

The immutable order is:

1. `01_switch_registry_gate`;
2. `02_common_harness_gate`;
3. `03_native_endpoint_and_rung_gate`;
4. `04_fresh_dual_snr_anchor`;
5. `05_six_db_forward_transfer`;
6. `06_six_db_order_controls_and_attribution`; and
7. `07_second_snr_confirmation`.

Jobs 1--3 are validation jobs and cannot produce a decoding-performance claim.
Job 4 is the only fixed-cap scientific timing anchor.  Its checksum-bound
frame-variant and write timing determine the wall budgets for Jobs 5--7 using
the registered target frame counts, execution-variant counts, pass ratio, and
safety factor.  A failed gate stops all later jobs.

## Correctness gates

1. The rung registry contains exactly the eleven registered IDs in order and ten
   adjacent transitions.
2. Exactly one transition is non-atomic and non-attributable: the scalar-to-
   edge-coordinate handoff that jointly changes state coordinates, domain, and
   target.
3. The shadow allocation is nonempty and zero and is never read by the
   projected-GD calculation.  A second independent run must reproduce the
   recorded objective trajectory and the registered endpoint fields described
   above.
4. The bottom endpoint reproduces the retained native projected-GD
   implementation.
5. A separate 80-update exact sum-product oracle reproduces the native BP
   endpoint.  For native recoveries, equality is checked at the first
   zero-syndrome endpoint.  For native failures, the update-80 terminal hard
   word, posterior floating-point bits, variable-to-check and check-to-variable
   floating-point bits, syndrome weight, and iteration cap must all agree.
6. Analytic partial derivatives for every declared scalar or residual
   objective agree with centered finite differences at the registered step
   and tolerance.
7. Every projection equals an independent componentwise box projection.
8. The exact sum-product check calculation agrees with local configuration
   enumeration and the retained native kernel.
9. All rungs for one frame use the frozen graph, transmitted word, noise
   realization, received samples, and channel-LLR vector registered for that
   case.
10. Independent hard decisions and syndromes agree with the runner.
11. Primary and replay scientific hashes are equal.
12. Existing result directories are never overwritten.
13. In Job 6, the locked cases reproduce 107 native projected-GD recoveries,
    200 native exact-sum-product recoveries, and a net gap of 93; their ledger
    remains separate from the fresh 6 dB ledger.

## Decoding-performance metrics

The retained per-rung outputs are terminal transmitted-word recovery, parity
validity, coded-bit errors, syndrome weight, update count, stop status,
state hash, and hard-word hash.  First transmitted-word recovery and first
parity-valid update are retained where the underlying implementation supplies
them.  Job timing is retained separately from scientific replay hashes.

A parity-valid hard-decision estimate is not automatically the transmitted
word.  Recovery and loss counts are always paired by frame.

No operation-count, allocation, peak-memory, or stored-state metric is claimed
by this campaign.  Its update counts are method-specific protocol fields, not
equal-work measurements.

## Claim boundary

A complete-valid campaign can establish causal effects for its atomic
interventions on the registered prospective cases.  It yields a complete
single-factor decomposition of the native endpoint difference only if the
native gates pass, relevant interactions are not material, and the non-atomic
handoff has no unresolved outcome contribution.  Otherwise the valid answer is
a path-conditional decomposition with an explicitly measured joint remainder.

The locked 93-case difference is descriptive attribution, not fresh causal
confirmation.  Results remain scoped to the registered graph, transmitted
word, AWGN generator, frame ranges, SNRs, decoder parameters, and work budgets.
They do not establish general BER superiority over a code ensemble.

`native_gap_accounted` is true when the signed adjacent net changes telescope
to the native endpoint gap.  This is arithmetic closure of the registered
ledger, not an independent counterfactual and not evidence that every
transition is an atomic cause.
