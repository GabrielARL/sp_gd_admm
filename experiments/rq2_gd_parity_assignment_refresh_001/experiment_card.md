# `RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001`

Status: **registered design; Offset Split v3 completed validly and passed the
registered branch-selection rule; controller attempt `2026-10-31_v1` failed
during syntax validation, attempt `2026-11-01_v2` failed while enumerating
freeze sources, and attempt `2026-11-01_v3` completed its valid 24-case anchor
but stopped at queue packaging; the isolated operational retry is
`2026-11-01_v4`; no transfer or attribution conclusion is claimed yet**.

This identifier is an internal experiment ID, not a receiver name. ADMM and
native BP are outside this experiment. The constructed offsets are
check-associated projected-GD state; they are not BP messages.

## Research question

The native BP-versus-projected-GD result establishes a 93-case recovery gap on
the locked 6 dB cases, but it changes state, parity calculation, objective,
projection, update rule, and stopping rule simultaneously. It therefore cannot
identify a cause.

The retained offset experiments narrow the question:

- `RQ2-GD-OFFSET-SPLIT-001` tests whether offsets act through the parity
  calculation or through the interval used by the projection step.
- `RQ2-GD-OFFSET-NULL-001` finds that correct check assignment outperforms a
  permuted assignment in the compound parity-plus-projection intervention, but
  that result does not isolate parity-calculation use. Its registered trigger
  required the permuted arm to remain near control; that literal trigger
  failed and remains recorded as failed.

This experiment asks:

> When offsets are read only by the parity calculation and every arm retains
> the native `[-1,1]` projection interval, how do check assignment and repeated
> replacement of the retained offsets affect recovery?

It tests the smallest missing causal cell before any BP check-node operation is
introduced.

## Mechanism fingerprint

Every arm has the same:

- one persistent scalar `x_i` per bit;
- one persistent constructed offset `delta_(c,i)` per graph edge;
- channel, parity, and binary terms in the registered projected-GD objective;
- partial derivatives of that objective and the retained diagonal
  preconditioner;
- strict-decrease backtracking line search;
- native `[-1,1]` projection interval;
- hard-decision and syndrome calculations; and
- 30-update limit with no syndrome early stop.

All arms calculate a new as-built offset candidate after every accepted scalar
update. They also calculate the candidate obtained from one fixed within-bit
derangement plan for that frame. Two registered selectors differ:

1. which candidate is adopted as the retained offset state; and
2. whether later candidates replace the retained state or are discarded.

This shadow-candidate rule prevents calculation-versus-no-calculation from
being confounded with persistence.

## Four factorial arms

| Arm | Candidate adopted | Later accepted updates |
|---|---|---|
| `asbuilt__refreshed` | as constructed | replace retained offsets |
| `permuted__refreshed` | fixed within-bit derangement | replace retained offsets |
| `asbuilt__frozen` | as constructed | retain the first adopted offsets |
| `permuted__frozen` | fixed within-bit derangement | retain the first adopted offsets |

All four arms read the retained offsets in the parity calculation. None reads
them when forming the projection interval. Shifted readings outside `[-1,1]`
belong to the registered polynomial extension: they are measured, not clipped
and not used to reject a line-search trial.

The derangement plan is generated once from
`MersenneTwister(20261101 + frame)` in bit order and reused throughout that
frame. Degree two is swapped; degree three uses one of the two cyclic shifts;
larger degrees use rejection sampling. The plan preserves each bit's multiset
and zero sum while changing which check reads each position.

## Closest retained work and anti-duplicate decision

- `RQ2-GD-OFFSET-SPLIT-001` contains `objective1__bounds0`, but every arm
  replaces offsets after every accepted update.
- `RQ2-GD-OFFSET-NULL-001` contains assignment and frozen controls, but its
  intervention reads offsets in both the parity calculation and the projection
  interval. Its permuted and frozen modes are also mutually exclusive.
- `RQ2-GD-CHECKRULE-001` is a design note whose literal launch trigger was not
  met; it is not implemented and is not modified by this experiment.

No retained experiment crosses assignment with replacement while offsets are
read only by the parity calculation. This is a causal variant, not a duplicate
or a parameter sweep.

## Prerequisite and branch-selection rule

Attempt v3 of `RQ2-GD-OFFSET-SPLIT-001` must first satisfy all correctness and
deterministic-replay gates. For both transmitted-word equality and parity
validity, the number of cases won only by `objective1__bounds0` must exceed the
number won only by `objective0__bounds0`.

If this rule fails, the parity-calculation branch has not transferred from the
development anchor. This experiment stops before freezing or calculating a new
endpoint. The failed branch is retained; no adjacent setting is substituted.

## Operational retry amendment, 2026-11-01

Controller attempt `2026-10-31_v1` retained a final failed preflight after the
Julia test file encountered a parse error caused by a line break before an
indexing bracket. The failure occurred before freeze, anchor, transfer,
attribution, or any registered endpoint calculation. Its preflight and
controller records remain immutable.

Attempt `2026-11-01_v2` corrects that syntax defect and gives the retry its own
preflight, freeze, result, queue, controller-state, and decision records. The
controller revalidates the complete v3 evidence and recreates the registered
branch-selection decision. Its preflight passed, but source enumeration during
freeze stopped because a local variable named `split` shadowed Julia's
`split(...)` function. The attempt retained its passed preflight, partial input
table, queue configuration, and controller failure. It produced no freeze
manifest, launched no scientific service, and calculated no endpoint.

Attempt `2026-11-01_v3` renames that local variable and directly tests source
enumeration against the retained prerequisite manifest. It receives new
preflight, freeze, result, queue, controller-state, and decision records. The
scientific question, four arms, cases, endpoints, contrasts, correction
family, budgets, numerical operations, and stopping rules are unchanged. The
registered scientific service names are reused only because v1 and v2 launched
neither service and created no scientific result. Its preflight, freeze, and
24-case anchor completed validly, including deterministic replay. The retained
anchor science SHA-256 is
`ce6f238b81e7edc5d7c160837fee0b566ea026c8cb319a55553c71839fbeeb49`.
The controller then stopped before budget creation because the inventory
verifier excluded nested files named `MANIFEST.sha256` or `phase_log.tsv` by
basename even though the anchor manifest correctly bound them. No transfer or
attribution service was launched.

Attempt `2026-11-01_v4` retains every v3 record and changes the inventory rule
to exclude only the three generated files at the result root. A regression
requires same-named nested files to remain checksum-bound. The retry receives
new preflight, freeze, result, queue, controller-state, decision, anchor-unit,
and queue-unit identities. Before queue packaging, its valid anchor science
SHA-256 must equal the retained v3 anchor science SHA-256. The scientific
question, four arms, cases, endpoints, contrasts, correction family, work
budgets, numerical operations, and stopping rules remain unchanged.

## Protocol fingerprint

The numerical capsule is the immutable v3 source archived under `vendor/`.
It retains the regular `(3,6)` LDPC graph with `N=10200`, graph seed
`169616412`, known unit-gain complex AWGN at 6 dB, all-zero transmitted word,
positive LLRs favoring coded bit zero, LLR clipping to `[-20,20]`,
`x_i^(0)=tanh(ell_i/2)`, parity weight 2, binary weight 0.2, initial step 0.2,
at most 16 halvings, and one Julia, BLAS, and OpenMP thread.

The case sequence is:

1. **Anchor:** frames `20001:20024`, development only.
2. **Prospective transfer:** previously unused frames `40001:40200`.
3. **Locked attribution:** frames `30001:30200`, run only after transfer.

The locked attribution cases may locate gains and losses among the original 93
native-GD failures. They are not a new held-out confirmation because their
retained outcomes informed this design.

## Registered contrasts

For each binary endpoint, retain these paired risk differences:

```text
assignment_given_refreshed = asbuilt__refreshed - permuted__refreshed
assignment_given_frozen    = asbuilt__frozen    - permuted__frozen
refresh_given_asbuilt      = asbuilt__refreshed - asbuilt__frozen
refresh_given_permuted     = permuted__refreshed - permuted__frozen
```

On the fresh transfer cases, the descriptive interaction is

```text
asbuilt__refreshed - permuted__refreshed
- asbuilt__frozen + permuted__frozen.
```

Transmitted-word equality is primary. Parity validity is confirmatory
secondary; a valid word may still be the wrong transmitted word. The fresh
transfer stage is the only confirmatory family. Its eight pairwise tests form
one Holm family at familywise alpha 0.05. Each pair uses a two-sided exact
McNemar test and a Newcombe method-10 interval at level 0.99375. The
interaction uses a paired-case percentile bootstrap with a fixed seed and is
descriptive. The informed attribution stage reports exact case transitions
only; a favorable attribution result cannot rescue a null or reversed transfer
result.

A claim that repeated replacement is unnecessary requires the simultaneous
interval for the relevant refresh contrast to lie entirely inside `[-0.05,
+0.05]`. A nonsignificant difference alone is not evidence of equivalence.

## Correctness gates

Before interpreting an endpoint:

1. The vendored configuration and numerical sources must match their registered
   SHA-256 values.
2. Anchor and locked-attribution received samples and clipped LLRs must match
   the retained split freeze row for row. Transfer inputs are frozen before
   their first endpoint is calculated.
3. On all 24 anchor frames, `asbuilt__refreshed` must reproduce v3
   `objective1__bounds0` bit for bit: scalar and offset states, gradients,
   directions, native bounds, line-search trials, accepted steps, hard
   decisions, and syndromes. Both terminal hashes and the canonical hash of
   every compared trace field are retained per anchor frame.
4. Before the update-1 candidate is adopted, every arm must have identical
   incoming scalar and offset hashes, partial derivatives, directions,
   projection bounds, line-search trials, accepted step, scalar output, and
   both shadow-candidate hashes. The scalar states remain equal through update
   1; only the assignment selector may then choose a different retained offset
   hash.
5. Within each assignment level, refreshed and frozen arms must have the same
   full pre-adoption trace through update 2 and the same scalar state through
   update 2. Only the replacement selector may then retain or discard the new
   candidate.
6. The two permuted arms must use the same fixed plan and adopt the same first
   permuted candidate.
7. Every distinguishable within-bit assignment must be changed while its
   multiset and zero sum are preserved. At update 1, the as-built and permuted
   candidate hashes must differ, at least one edge value must move, and the
   retained-offset hashes must differ between assignment levels. This proves
   that the assignment intervention is active before an endpoint is
   interpreted.
8. Every arm must calculate both shadow candidates after every accepted
   update. The selected-candidate hash must match the registered assignment
   selector. When replacement is enabled, the retained-offset hash must equal
   that selected hash; otherwise it must equal the prior retained-offset hash.
   Frozen arms adopt exactly once. At update 2, the selected candidate must
   differ from the retained offsets in at least one edge position under each
   assignment level, and the refreshed and frozen retained-offset hashes must
   consequently differ. This proves that the replacement intervention is
   active before an endpoint is interpreted.
9. All projection lower and upper bounds must equal `-1` and `+1` exactly.
10. Offsets must remain fixed during each partial-derivative calculation and
    line search. On every scientific case, fixed-offset partial derivatives in
    all four arms must pass finite differences after the paths diverge, and
    every accepted step must decrease that arm's current objective.
11. Shifted-reading overshoot must be retained as a diagnostic and must not
    affect acceptance.
12. Independent hard decisions and syndromes must agree with the runner.
13. Primary and replay passes must have the same canonical scientific SHA-256.
14. The anchor expansion decision depends only on correctness, never on the
    observed ordering.

## Work and retained artifacts

The anchor cap is 7,200 seconds. After the anchor, the queue derives the stage
budget from the measured primary and replay frame-loop seconds per anchor case,
scales both to 200 cases, adds every measured post-loop phase scaled to 200
cases, and multiplies the result by 1.5. The derivation is retained beside the
queue. If the result exceeds the 36,000-second cap, execution stops for a
prospective amendment. The queue refuses to start while another registered
scientific service is active.

Each completed stage retains `frames.csv`, `iterations.csv`, `aggregate.csv`,
`interaction.csv`, `science.json`, `phase_log.tsv`, `progress.toml`, a primary
checkpoint, the frozen source and input manifests, and a complete checksum
manifest. The iteration table retains the proposal, bound, partial-derivative,
direction, line-search offset, and post-update state hashes used by the
pre-adoption and reference-equivalence gates. Runtime and allocation are
diagnostics, not causal endpoints.

No scientific stage runs beside another scientific service on this two-core
machine. The locked non-anchor queue accepts only manifest-listed immutable
files, its two named lock sidecars, and the exact registered telemetry paths;
every other unlisted file or symlink is a launch failure.

Both launch wrappers and their read-only verifier execute from the frozen
source tree; `RQ2_QUEUE_ROOT` points them to the attempt-specific queue data.
Before transfer, the verifier rechecks the complete freeze, the exact original
runner and configuration paths and hashes, the complete-valid anchor and its
freeze hashes, both anchor-derived budgets, the registered result-directory
scope, the exact immutable inventory, and jobs `J01` then `J02`. Copies of the
governance tools inside the locked queue are evidence copies and must equal
their frozen sources; they are not the launch trust root. The Julia runner
independently checks the same queue inventory, execution plan, source hashes,
budget identities, and predecessor handoff before calculating an endpoint.

## Attribution accounting

On the locked attribution set, report for every arm:

- original native-GD failures newly recovered;
- original native-GD successes lost;
- net change;
- original 93 failures still unresolved; and
- exact frame identities for every transition.

Do not say that an operation "accounts for" a unique number of the 93 cases
unless successes are nested and the later reverse-order test shows no material
interaction. Otherwise report a path-conditional incremental effect.

## Registered interpretation

- A positive assignment effect under both replacement levels supports check
  assignment as the next bridge mechanism.
- An assignment effect only when offsets are repeatedly replaced means
  assignment and persistence act jointly; they cannot be given additive case
  counts.
- No assignment effect after removing offset-induced projection bounds means
  the earlier compound result depended on the projection interaction and must
  not be promoted as a BP explanation.
- A material assignment-by-replacement interaction requires every later ladder
  claim to state its path and order.

## Claim boundary

A valid result concerns constructed projected-GD variants on the registered
graph, AWGN cases, initialization, and 30-update budget. It can establish
whether the constructed state acts through its check assignment, its repeated
replacement, or their interaction when offset-induced projection bounds are
absent. It cannot show that these offsets are BP messages, identify BP's full
mechanism, establish a general BER ordering, or by itself explain all 93 native
BP-only recoveries.
