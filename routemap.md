# BP–GD Research Route Map

Last updated: 2026-10-28

## Destination and scope

This repository now follows two ordered research questions.

1. **RQ1 — mechanism identification.** Which operational difference, or
   combination of differences, first produces a reproducible trajectory
   divergence between belief propagation (BP) and projected gradient descent
   (GD) when the parity-check graph and vector of channel LLRs are fixed?
2. **RQ2 — causal performance consequence.** When the RQ1 mechanism is added
   or removed in a controlled variant, does it change whether the
   hard-decision estimate satisfies every parity check or equals the
   transmitted word on preregistered AWGN cases with fixed conditions under an
   explicit work budget?

A candidate mechanism must pass its operational RQ1 validity gates before it
is transferred to RQ2. A scoped RQ2 transfer may test one validated candidate
while native attribution remains open, but it cannot close the native
BP-versus-GD question by itself. A native performance ordering can locate a
difference; it cannot identify its cause because the native methods differ in
state, parity action, objective, and update rule.

ADMM is deferred. Existing ADMM pages may remain as tutorials, but their
outcomes are not evidence for either active research question.

## Evidence chain

```text
Lock the BP and projected GD method fingerprints
                         |
                         v
Locate the first native trajectory divergence
             (descriptive trace only)
                         |
                         v
Run one-mechanism-at-a-time RQ1 controls
       | retain or tie recipient-specific BP state |
       | direct BP map or true residual-gradient step |
                         |
                         v
Reproduce both native endpoints and enumerate the remaining gaps
                         |
                         v
Record the RQ1 decision and remaining confounds
                         |
                         v
Preregister one AWGN controlled variant with fixed conditions
                         |
                         v
Run the anchor, then justified confirmatory cases
                         |
                         v
State the scoped RQ2 conclusion
```

An animation may explain or help debug any stage. It is not an evidence gate
and is not required to answer either research question.

## Current status

| ID | Work item | Status | Current truth |
|---|---|---|---|
| `SCOPE-001` | Ordered RQ1 then RQ2 framing | **Included in the research commit** | Recorded in `AGENTS.md` and the repository-local skills. |
| `TRACE-001` | Native toy traces and tutorials | Exploratory | Calculations and teaching artifacts exist, but a native comparison changes several mechanisms together. |
| `ANIM-001` | Trace-driven mechanism animation | **Complete; validated explanatory output** | `rq1_mechanism_animation.html` separates controlled state/update evidence from native endpoints; `mailboxes_and_arrows.html` now has schedule-specific persistence wording. Neither is an evidence gate. |
| `RQ1-STATE-001` | A-posteriori-LLR copy control | **Superseded before execution** | Copying the a-posteriori LLR both removes recipient-specific differences and introduces the recipient check's preceding message. It cannot isolate one discarded distinction. |
| `RQ1-STATE-002` | Mean-preserving removal and restoration of recipient-specific BP state | **Complete; valid state effect** | Eligible primary and cyclic results are the v3 records. Tying changes the trajectory; reconstruction restores full BP; the degree-one graph is a null control. |
| `RQ1-UPDATE-001` | Direct BP map versus a true gradient step on the BP residual | **Complete; valid 2 x 2 control** | Tree `anchor_v2` has nonzero state, update, and interaction contrasts. This is not native projected GD. |
| `RQ1-UPDATE-CYCLE-001` | Second-graph update confirmation | **Complete; valid structural confirmation** | `confirmation_v1` reproduces nonzero state, update, and interaction contrasts without retuning; no cell is parity-valid after one update. |
| `RQ1-ENDPOINT-001` | Controlled-to-native endpoint bridge | **Complete; valid endpoint reproduction** | `endpoint_v3` reproduces native exact SP and the scalar `coral_exact_gradient` endpoint and enumerates their remaining non-equivalences. |
| `RQ1-DECISION-001` | Mechanism decision | **Partially resolved; native attribution open** | Recipient-specific variable-to-check calculation and update operator are validated candidate trajectory mechanisms; no unique native BP-versus-GD cause is established. |
| `RQ2-AWGN-001` | Preregistered paired AWGN anchor | **Complete; valid sealed descriptive anchor** | `anchor_v2` passes validation, deterministic replay, native full-arm equivalence, and the registered expansion gate. Full exact SP succeeds on 24/24 frames and persistent `qbar` tying on 0/24 for both registered endpoints. |
| `RQ2-CONFIRM-001` | Held-out paired confirmation | **Interrupted before output; not completed** | `heldout_v1` was intentionally stopped after about 26 minutes at the user's request. The atomic runner had emitted no frame, endpoint, science, or manifest files, so no held-out outcome exists. The anchor will not be pooled into a future confirmation. |
| `COMM-001` | Result-driven animation and research narrative | **Complete; validated** | `rq1_mechanism_animation.html` is driven by eligible retained traces and verified against 68 full-precision values and five source hashes. |

## Approved execution register

The user approved the complete staged program on 2026-10-28. Approval permits
execution when each scientific gate is satisfied; it does not turn a failed
gate into evidence or require mutually exclusive branches to be run.

| Approval ID | Authorized action | Dependency |
|---|---|---|
| `BPGD-APP-001` | Correct and freeze `RQ1-STATE-002` | none |
| `BPGD-APP-002` | Build and validate the deterministic state harness | `BPGD-APP-001` |
| `BPGD-APP-003` | Run the one-update state pulse | harness validity |
| `BPGD-APP-004` | Run the evidence-selected state-by-update bench | valid Gate 1 result |
| `BPGD-APP-005` | Classify the tested RQ1 mechanism | valid mechanism bench |
| `BPGD-APP-006` | Run a preregistered second-graph confirmation | classified candidate |
| `BPGD-APP-007` | Build the one-factor native-endpoint bridge | confirmed candidate |
| `BPGD-APP-008` | Freeze the paired AWGN experiment card without running it | endpoint validity |
| `BPGD-APP-009` | Run the paired AWGN anchor | frozen valid card |
| `BPGD-APP-010` | Run held-out paired confirmation | valid anchor |
| `BPGD-APP-011` | Update the route and mechanism-first report | retained evidence |
| `BPGD-APP-012` | Build or revise animation from the validated trace | validated trace |

The user separately authorized staging and a local commit on 2026-10-28 after
stopping the held-out run. Push, publication, and hosting remain outside that
authorization.

## Current artifact register

The status below distinguishes pre-existing tracked material from artifacts
included in the current research commit. A tutorial is not promoted to
experimental evidence merely because it runs.

| Artifact | Git state | Verified role and boundary |
|---|---|---|
| `sum_product_one_iteration.tex` and `.pdf` | Tracked | Six-bit BP worksheet. The source rebuilds to three pages and its rebuilt text agrees with the tracked PDF. Teaching trace only. |
| `projected_gradient_one_iteration.tex` and `.pdf` | Tracked | Six-bit parity-only projected GD worksheet. The source rebuilds to four pages and its rebuilt text agrees with the tracked PDF. Teaching trace only. |
| `bp_pg_one_iteration.html` | Tracked | Browser smoke test passes. It synchronizes native calculations but does not isolate a mechanism. |
| `three_symbols_two_checks.html` | Tracked | Embedded numerical checks pass. Its ADMM panel remains tutorial-only. |
| `six_bits_round_robin.html` | Included | Browser smoke test and embedded numerical checks pass. The checks are disjoint, so it does not test aggregation at a bit connected to multiple checks. Tutorial only. |
| `twelve_bits_round_robin.html` | Included | Browser smoke test passes, but no embedded numerical assertion set was found. Treat as unverified work in progress. |
| `mailboxes_and_arrows.html` | Included | Exploratory native BP/GD view. Its persistence wording now distinguishes the variable-then-check teaching boundary from check-first implementations, but it remains explanatory material rather than an RQ1 result. |
| `experiments/rq1_state_002/results/2026-10-28_primary_v3` | Included | Eligible state-ablation primary record; 17/17 harness tests and deterministic replay pass. State v1/v2 are superseded. |
| `experiments/rq1_state_002/results/2026-10-28_cycle_confirm_v3` | Included | Eligible cyclic state confirmation; retained config, validation, replay, and manifest checks pass. Cycle v1/v2 are superseded. |
| `experiments/rq1_update_001/retained/anchor_v2` | Included | Eligible tree 2 x 2 state-by-update record; 17/17 retained gates pass. `anchor_v1` is invalidated and excluded. |
| `experiments/rq1_update_cycle_001/retained/confirmation_v1` | Included | Eligible cyclic 2 x 2 structural confirmation; 16/16 retained gates pass. |
| `experiments/rq1_endpoint_001/results/2026-10-28_endpoint_v3` | Included | Eligible exact-SP and scalar-GD endpoint bridge; 37/37 tests, deterministic replay, and all checksum gates pass. Endpoint v1/v2 have deficient Git provenance and are excluded. |
| `experiments/rq2_qbar_awgn_001/results/2026-10-28_anchor_v1` | Included | Invalid serialization attempt, retained only as a postmortem. Integer state-snapshot keys caused a `MethodError` before any frame-level outcome was retained; all endpoint flags are excluded. |
| `experiments/rq2_qbar_awgn_001/freeze/2026-10-28_v2` | Included | Eligible immutable input and source freeze for 24 anchor plus 200 held-out identities. Input-table SHA-256 is `01a712d7c61498148aea92f54ea521101d8535b0ef56d095774b2d95bf6e8cb3`; freeze-manifest SHA-256 is `da5ac35be6daaa2a5652b1bdc28c2952c9526e74a03ab2ea72ef15de6c4c7204`. Held-out decoders were not executed while producing the freeze. |
| `experiments/rq2_qbar_awgn_001/results/2026-10-28_anchor_v2` | Included | Eligible valid sealed descriptive anchor. Full succeeds 24/24 versus tied 0/24 for parity validity and transmitted-word equality; native equivalence, validation, replay, checksums, and the registered expansion gate pass. This anchor is not pooled into held-out inference. |
| `experiments/rq2_qbar_awgn_001/results/2026-10-28_heldout_v1/INTERRUPTED.md` | Included | Audit record for the intentionally stopped held-out attempt. The process ended during native preflight before atomic output; no held-out frames or endpoints are evidence. |
| `rq1_mechanism_animation.html` and verifier | Included | Sixteen-beat explanatory animation. Sixty-eight embedded scientific values and five eligible source hashes pass automated and browser validation. |
| `mechanism_report.md` | Included | Mechanism-first RQ1/RQ2 report with the native-attribution boundary retained. |

## RQ1 route

### Gate 0 — lock the native-method fingerprints

For each method, record at the same conceptual level:

- propagated or optimized state and its dimension;
- channel evidence and LLR sign convention;
- parity representation;
- BP check-node calculation or GD parity calculation, and the global update;
- values retained for the next update and temporary values;
- flooding, frozen, sequential, or alternating schedule;
- initialization, damping, step size, penalty, and projection or clipping;
- stopping rule, hard-decision rule, and syndrome test.

The protocol record must contain the parity-check matrix, graph, full-precision
vector of channel LLRs, deterministic execution order, and every parameter.

**Gate 0 passes only when** the equations, implementation, and retained trace
agree at full precision. Independently enumerate the valid toy configurations,
check the partial derivatives used by projected GD with finite differences,
and verify every projection or clipping operation.

Throughout this route, the syndrome is `s = (H * b_hat) mod 2`, with
arithmetic over GF(2). A zero syndrome establishes parity validity; equality to
the transmitted word is tested separately when that word is registered.

### `RQ1-STATE-001` — superseded a-posteriori-LLR copy control

This control was superseded before execution. For bit \(i\), standard BP forms

```text
Q*_(i->a) = L_i + sum over b in N(i), b != a of U_(b->i),
B_i       = L_i + sum over b in N(i) of U_(b->i).
```

Sending `B_i` to every neighboring check removes the recipient-specific
differences **and** adds the recipient check's own preceding message. It is
therefore retained only as a secondary self-feedback/mean-shift diagnostic;
it is not the primary causal comparison and is not projected GD.

### `RQ1-STATE-002` — mean-preserving remove-and-restore control

At the selected BP variable-node update, first compute every standard outgoing
message `Q*_(i->a)`. Decompose the outgoing vector at each bit as

```text
qbar_i       = (1 / degree(i)) * sum over a in N(i) of Q*_(i->a)
delta_(i->a) = Q*_(i->a) - qbar_i.
```

The primary factor has two levels:

```text
recipient-specific state retained: Q_(i->a) = qbar_i + delta_(i->a)
recipient-specific state tied:     Q_(i->a) = qbar_i
```

The tied level preserves the average outgoing message and removes only its
recipient-specific component. It leaves every degree-one bit unchanged and
has `sum_a delta_(i->a) = 0` by construction.

The deterministic harness must contain five labeled variants:

1. full BP;
2. `qbar`-only tying;
3. retain `delta` in the trace but do not use it, which must equal variant 2;
4. reconstruct `qbar + delta`, which must equal variant 1; and
5. the superseded a-posteriori-LLR copy diagnostic.

The primary treatment is a **one-update pulse**. All variants fork from the
same saved full-BP state. At the variable-node update of message-passing
iteration 2, compute `Q*`, apply the selected treatment once, and then perform
the check-node update. A persistent tying treatment is a separate, labeled
follow-up and must not be substituted for this pulse.

Hold fixed the parity-check graph, channel LLR vector and sign convention,
check-node calculation, initialization, flooding schedule, damping, stopping
rule, hard-decision rule, execution order, precision, and work budget. The
first update is a negative control because its incoming `U` messages are zero.

Use these preregistered calibration cases:

```text
three-bit graph: H = [1 1 0; 0 1 1]
symmetric anchor: L = (-ln(9), ln(3/2), ln(9))
nonzero-sum anchor: L = (-ln(9), ln(3/2), ln(2))
degree-one negative control: the six-bit disjoint-check graph
```

For the symmetric anchor, standard BP is predicted to form
`Q_(2->A) = ln(27/2)` and `Q_(2->B) = ln(1/6)` at the selected update. Its
incoming messages at bit 2 sum to zero, so `qbar_2 = B_2 = ln(3/2)`; this
case alone cannot expose the confound in the copy diagnostic.

For the nonzero-sum anchor, the preregistered selected-update values are

```text
Q_(2->A) = ln(3)
Q_(2->B) = ln(1/6)
qbar_2   = -0.5 ln(2)
B_2      = -ln(3).
```

This second anchor must show that mean-preserving tying and a-posteriori-LLR
copying are different interventions before either is interpreted.

**Required validity controls:** reconstructed equals full; retained-but-unused
equals tied; all variants agree before the pulse; degree-one tying equals full;
consistent check relabeling preserves the result; deterministic replay is
byte-identical for scientific outputs; hard-decision estimates and syndromes
are recomputed independently; and a structural witness demonstrates that two
outgoing vectors with the same mean but different `delta` can give different
next check inputs.

**Required retained output:** full-precision messages, `qbar`, `delta`,
a-posteriori LLRs, hard-decision estimates, syndromes, exact first divergence,
configuration and source hashes, runtime identity, command, validation log,
and output hashes. Rounded display values must never feed a calculation.

**Gate 1 branches:**

- **state effect:** tying changes the predicted trajectory while reconstruction
  reproduces full BP;
- **copy-only effect:** only the copy diagnostic changes the trajectory, so
  investigate self-feedback or mean shift rather than lost recipient-specific
  state;
- **null state effect:** retain the null result and proceed to the update-rule
  comparison; or
- **invalid:** a correctness control fails, so repair only the validity fault
  and make no mechanism claim.

**Retained Gate 1 result — state effect.** Eligible primary and cycle records
are the v3 directories. On the nonzero-sum tree, full BP gives `000/00` and
the tied branch gives `001/01` at the selected snapshot; the first divergence
is the transmitted variable-to-check message `b1->c0`. Reconstruction equals
full BP, retained-but-unused `delta` equals tying, and the degree-one graph is
a null control. The cyclic record confirms a trajectory change. A one-update
pulse can later rejoin full BP on the tree, so this is not yet a convergence or
performance result.

### `RQ1-UPDATE-001` — BP update equation versus gradient step

Run this only after `RQ1-STATE-002` is recorded and its Gate 1 branch is
selected from retained evidence.

Initialize the same variable-to-check and check-to-variable message coordinates
with the same numerical values, then declare the same BP update equations or
fixed-point target. Compare:

1. applying the BP update map directly; and
2. taking a true gradient step on the explicitly stated objective function
   `R(m) = 0.5 ||m - F_BP(m)||_2^2` for that target.

Here `m` collects the declared message coordinates and `F_BP` is the declared
BP update map.

The required gradient is

```text
grad R(m) = (I - J_F_BP(m))^T (m - F_BP(m)).
```

Holding `F_BP(m)` fixed while differentiating gives a relaxation or damping
experiment, not this gradient hypothesis. Verify the implemented gradient by
central finite differences and register its step size before execution.

If Gate 1 found a state effect, run the following `2 x 2` mechanism bench:

| Update | Recipient-specific component retained | Component tied |
|---|---:|---:|
| direct BP map | cell 1 | cell 2 |
| true gradient step on `R` | cell 3 | cell 4 |

If Gate 1 found no state effect, compare the two updates first with full state.
Classify a state effect, update effect, interaction, valid null, or invalid run.
The four cells must use the same coordinates, target, channel evidence,
initialization, schedule, stopping rule, and declared work budget.

Hold the state representation, target equations, initialization, schedule,
projection or clipping, stopping rule, and declared work budget fixed as far as
the hypothesis permits.

**Required output:** residual and state traces, the first recorded update where
the variants differ, hard-decision estimates, syndromes, categories of
primitive operations, and the number of values retained between iterations.

**Gate 2 passes only when** the objective function and its derivatives are
verified, its zero set is related explicitly to the BP fixed points, and the
anchor is not retuned after inspection. This gradient control is not native
projected GD and cannot alone explain a native BP-versus-GD performance gap.

**Retained Gate 2 result — state, update, and interaction contrasts.** Tree
`anchor_v2` passes every derivative, spectrum, sign-transform, fixed-point,
decision, syndrome, and replay gate. The state, update, and interaction norms
are respectively `1.465181905609834`, `1.071596172705627`, and
`1.484908686870001`; only full/direct gives syndrome `00` after one update.
Cycle `confirmation_v1`, using the transferred step size, gives nonzero norms
`2.130829937421622`, `1.190807282140601`, and
`2.1595188093747844`; no cell is parity-valid after one update. These are
local vector contrasts, not rankings of decoder importance or equal-work
comparisons. The invalid tree `anchor_v1` is excluded.

### `RQ1-ENDPOINT-001` — controlled-to-native bridge

After the mechanism bench, connect its controlled endpoints to native BP and
the repository's native projected GD one factor at a time. Audit, in order,
channel-evidence use, check-node or parity computation, objective and feasible
set, projection or clipping, schedule, and stopping rule. An endpoint must
reproduce its native method before the mechanism-bench result is used to
explain a native BP-versus-GD performance difference.

The current projected-GD teaching example initializes from the channel LLRs
but then optimizes a parity-only objective, while BP reintroduces each channel
LLR in its variable-node calculation. Treat this as a known native-method
confound to test, not as an already established culprit.

**Retained endpoint result.** `endpoint_v3` passes 37/37 tests and all source,
finite-difference, projection, frozen-state, prefix, provenance, replay, and
checksum gates. The BP lane reproduces JadeJcade's native exact sum-product
decoder, not its normalized-min-sum decoder. The scalar lane reconstructs
`coral_exact_gradient` through separate parity-base, channel, binary, step,
preconditioner, line-search, and stopping rungs. Current and archived native
scalar endpoints agree bit-for-bit; the composed ladder agrees within
`6.661338147750939e-16`. Endpoint v1/v2 are excluded because their Git
provenance capture was defective.

### `RQ1-DECISION-001` — mechanism gate

RQ1 can close only when a candidate mechanism has:

- an executable operational definition;
- a prediction registered before execution;
- a reproduced first divergence under the locked protocol;
- checks independent of rounded display values; and
- a conclusion limited to the tested graph, channel evidence, schedule, and
  parameters.

The decision may identify recipient-specific outgoing state, the update rule,
their interaction, or an unresolved result. If the first two controls are
inconclusive, test channel-evidence use, check-node calculation, parity
representation, objective or feasible set, and projection one factor at a
time. Do not manufacture a single culprit from an inconclusive outcome.

**Retained RQ1 decision — partially resolved, native attribution open.** The
recipient-specific variable-to-check calculation and direct-versus-residual-
gradient update are validated candidate trajectory mechanisms on the declared
tree and cycle. They do not identify a unique native BP-versus-projected-GD
cause. The BP-residual gradient is not native projected GD, and no controlled
bridge makes BP's `qbar` dynamically equivalent to the native scalar state.

## RQ2 route

### `RQ2-AWGN-001` — preregistered AWGN anchor

After RQ1, add or remove only the identified mechanism in one controlled
variant. Lock, as far as the mechanism permits:

- parity-check matrix and graph;
- transmitted word;
- received samples or exact noise realization;
- vector of channel LLRs, sign convention, and hashes;
- random seed and method execution order;
- initialization and all algorithm parameters;
- stopping rule, hard-decision rule, and syndrome test;
- explicit operation, runtime, and memory budgets.

Register the predicted diagnostic and decoding change before execution. Retain
an outcome with no observed difference; if the run is invalid, record why.

The primary questions are whether the hard-decision estimate:

1. satisfies every parity check; and
2. equals the transmitted word.

Supporting outputs are bit-error rate and frame-error rate with their exact
decoded-bit and tested-frame denominators, syndrome, trajectory values,
stopping reason, runtime, categories of primitive operations, the number of
values retained between iterations, and measured memory. A lower objective is
only a diagnostic and does not establish decoding success.

**Gate 3 passes only when** the case replays deterministically, before/after
snapshots are aligned, and parity validity is checked separately from equality
with the transmitted word.

**Retained Gate 3 anchor.** The valid sealed `2026-10-28_anchor_v2` record
matches the native full exact-SP state bit-for-bit on all 24 frames and passes
all correctness, input-freeze, provenance, checksum, and replay checks. For
both parity validity and equality to the transmitted word, full exact SP is
24/24 and persistent `qbar` tying is 0/24: all 24 pairs are full-only
discordances and the risk difference, full minus tied, is `1`. The registered
two-sided 97.5% Newcombe method-10 interval is
`[0.7552068689185257, 1]`; the exact two-sided McNemar p-value is
`1.1920928955078125e-7`, and the Holm-adjusted value across the two endpoints
is `2.384185791015625e-7`. Full stopped in 14--44 message-passing iterations
(mean `18.2083`); every tied run reached the 80-iteration cap. The registered
counts and validation checks—not the descriptive interval or p-values—make
the expansion gate pass.

This 24-frame anchor is descriptive and is never pooled with the held-out
set. It shows a recovery consequence of recipient-specific variable-to-check
values within the locked exact-SP recurrence; it does not identify the unique
cause of the native BP-versus-projected-GD performance gap.

**Reporting invariant.** Endpoint flags are void unless the sealed record has
`status = valid`, `validation_passed = true`, and a passed deterministic
replay. A failed or incompletely serialized run cannot contribute a
parity-validity or transmitted-word-equality result even if a partial file
contains such a field.

### `RQ2-CONFIRM-001` — confirmatory cases

The valid AWGN anchor now authorizes the preregistered 200 frozen held-out
noise realizations. Preserve seeds, hashes, denominators, failures, and
stopping reasons. The first held-out attempt was intentionally interrupted
after about 26 minutes, during native preflight, before the atomic runner wrote
any frame or endpoint output. It is incomplete and contributes no outcome. A
future complete run must pass validation and its in-run deterministic replay
before it is reportable. Do not substitute or pool the descriptive anchor.

The retained report must state the tested code, cases, changed mechanism, work
budget, metric, and denominator. Do not generalize a toy case or a small fixed
set to a code ensemble without ensemble evidence.

## Separate complexity track

Asymptotic graph traversal alone does not answer RQ1 or RQ2. Record separately:

- work required by the algorithm versus diagnostic and rendering work;
- declared categories of primitive operations;
- costs of nonlinear functions and projection or clipping;
- values retained between updates and measured memory;
- runtime after a stated warm-up and repetition protocol.

Equal animation beats, graph traversals, or raw iteration counts do not imply
equal work. Do not combine heterogeneous operations into one scalar without a
stated weighting model.

## Communication route

`rq1_mechanism_animation.html` is optional explanatory output downstream of
the executable RQ1 controls. Its verifier enforces the following rules:

1. distinguish prior check-to-variable messages that feed the next BP update
   from old variable-to-check values that are recomputed;
2. show GD partial derivatives as temporary calculations rather than traveling
   messages;
3. drive every displayed value from the same executable trace used by the RQ1
   assertions; and
4. end with the boundary that a toy animation does not establish error rate,
   convergence, complexity, or performance across a code ensemble.

The retained animation has 16 synchronized beats, 68 full-precision values,
and five eligible source hashes. Automated evidence, wording, and headless-
browser checks pass. `mailboxes_and_arrows.html` also records the schedule-
specific distinction between the teaching harness's variable-then-check
boundary and Jade's native check-first boundary.

## Experiment record required for every run

```text
ID:
research question:
question:
mechanism being changed:
operational definition:
method fingerprints:
protocol fingerprint:
closest retained experiment:
only implemented difference:
prediction registered before execution:
expected diagnostic change:
anchor and stopping rule:
correctness checks:
decoding outcomes:
operation, runtime, and memory measures:
run status: planned | running | complete | invalid
outcome: observed difference | no observed difference
```

## Decision record

- **2026-10-28:** The active program is BP versus projected GD: RQ1 identifies
  a mechanism, then RQ2 tests its decoding consequence.
- **2026-10-28:** ADMM is deferred from both active questions.
- **2026-10-28:** Animation is optional explanatory material, not an evidence
  gate. At that decision point, the next required artifact was the executable
  `RQ1-STATE-002` control; that control is now complete.
- **2026-10-28:** Existing conversational predictions are not experimental
  results until reproduced by a retained executable trace and validation log.
- **2026-10-28:** `RQ1-STATE-001` was superseded before execution because its
  a-posteriori-LLR copy changed both recipient-specific state and self-feedback.
- **2026-10-28:** `BPGD-APP-001` through `BPGD-APP-012` were approved. Only the
  evidence-selected branches will run; scientific validity gates remain active.
- **2026-10-28:** Eligible state v3 results select the state-effect branch;
  reconstruction restores full BP and the degree-one control remains null.
- **2026-10-28:** The tree and cycle 2 x 2 controls find nonzero state, update,
  and interaction trajectory contrasts. These are BP-residual controls, not
  native projected-GD results or importance rankings.
- **2026-10-28:** Endpoint v3 reproduces exact sum-product BP and the native
  scalar `coral_exact_gradient` endpoint. Native attribution remains open
  because their representations, parity calculations, objectives, updates,
  projections, and stopping behavior are still not one common mechanism.
- **2026-10-28:** RQ1 is partially resolved. The exact-SP full-versus-`qbar`-
  tied AWGN transfer may test one candidate's recovery consequence, but cannot
  alone explain the native BP-versus-GD performance difference.
- **2026-10-28:** RQ2 anchor v1 is invalid because integer-key scientific-state
  serialization failed before frame-level output was retained. Its endpoint
  flags are void. The v2 repair changes serialization and validation only.
- **2026-10-28:** The sealed RQ2 anchor v2 passes Gate 3. Full exact SP is
  24/24 and persistent `qbar` tying is 0/24 for both registered endpoints,
  with 24 full-only discordances. This descriptive anchor authorizes but is
  not pooled with the held-out confirmation. Native BP-versus-projected-GD
  attribution remains open.
- **2026-10-28:** The user stopped the first 200-frame held-out attempt after
  about 26 minutes. It ended during native preflight before atomic science
  output, so no held-out result exists and the confirmation remains incomplete.
- **2026-10-28:** The user explicitly authorized staging and committing all
  research artifacts, including invalidated and interrupted audit records, to
  `main`. Push and publication were not authorized by that instruction.
