# BP--GD mechanism report

Last updated: 2026-10-31

## Outcome first

RQ1 is **partially resolved; native attribution remains open**.

On the locked three-bit tree and four-bit cycle, removing the
recipient-specific component of BP's variable-to-check values changes the next
trajectory at the values supplied to the checks. Restoring that component
reproduces full BP. In a separate BP-residual control, replacing direct map
assignment by one true gradient step also changes the trajectory, and the two
factors have a nonzero difference-in-differences on both graphs.

These results establish two validated candidate trajectory mechanisms:

1. whether a bit supplies different variable-to-check values to different
   recipient checks; and
2. whether the declared map is applied directly or approached by a gradient
   step on its squared fixed-point residual.

They do **not** establish one unique cause of the native BP-versus-projected-GD
performance difference. The gradient control uses BP edge coordinates and a BP
fixed-point residual; it is not the repository's native projected-GD decoder.
The native methods still differ in scalar versus directed-edge state, parity
calculation, objective function, channel-evidence use, projection, update rule,
and stopping behavior.

The sealed 24-frame RQ2 anchor supplies a first long-code consequence for the
state candidate inside the locked exact-SP recurrence: full exact SP recovered
a parity-valid transmitted word on all 24 frames, whereas persistent `qbar`
tying did so on none. The canonical one-thread Linux confirmation reproduced
the direction on all 200 frozen held-out frames: full exact SP recovered the
parity-valid transmitted word on 200/200 frames and persistent `qbar` tying on
0/200. It passes validation, checksums, and deterministic replay. The earlier
four-thread Windows transfer has byte-identical scientific tables and state
snapshot and now serves as cross-platform corroboration. This exact-SP result
still does not close native BP-versus-projected-GD attribution.

A separate projected-GD transfer now gives valid favorable held-out evidence
for a related state-use question. Both arms calculate and retain the same type,
shape, and construction of bounded, mean-zero check-specific offsets, but only
the active arm uses them in the next update through both the parity objective
and its induced scalar feasibility interval. On 200 frozen 6 dB cases,
active/control transmitted-word and parity-valid successes are 172/113, with
59 active-only and 0 control-only pairs. Every pair is identical through
update 1; at update 2, both arms enter with the same scalar state and retained
offsets, but all 200 partial-derivative vectors and accepted scalar updates
diverge when only the active arm uses the offsets in that joint way. This
establishes a causal consequence for the constructed joint-use intervention
on the projected-gradient backbone. It does not make the offsets BP messages,
separate parity-objective use from projection-bound use, or uniquely explain
the native performance gap.

## What was isolated

For each bit $i$, the standard BP variable-node calculation was decomposed as

```text
Q*_(i->a)   = L_i + sum over b != a of U_(b->i)
qbar_i      = mean over a of Q*_(i->a)
delta_(i->a)= Q*_(i->a) - qbar_i.
```

The state intervention changed only the value consumed by the next check
calculation:

```text
full: Q_(i->a) = qbar_i + delta_(i->a)
tied: Q_(i->a) = qbar_i.
```

Both branches fork from the same check-to-variable values and use the same
check-to-variable message coordinates. Their next check-to-variable messages
can differ after the altered variable-to-check messages are consumed.
Therefore the isolated mechanism is the **recipient-specific
variable-to-check calculation**, not a reduction in allocated memory and not a
proof that `qbar` is the native GD relaxed-bit variable.

The update intervention crossed that state factor with

```text
direct:   u_next = F_s(u)
gradient: u_next = u - alpha (I - J_s)^T (u - F_s(u)),
```

where $s$ is the full or tied map. Each gradient cell uses the objective
$R_s(u)=\tfrac12\lVert u-F_s(u)\rVert_2^2$. Because changing the state map also
changes this residual objective and its Jacobian, a nonzero interaction is
expected and is not an importance ranking.

## Retained evidence

| Experiment | Eligible retained result | Main observation |
|---|---|---|
| `RQ1-STATE-002` primary | `experiments/rq1_state_002/results/2026-10-28_primary_v3` | Tying first changes `Q` at the registered iteration; reconstruction restores full BP; the degree-one graph is a null control. |
| `RQ1-STATE-002` cycle | `experiments/rq1_state_002/results/2026-10-28_cycle_confirm_v3` | The same state intervention changes the cycle trajectory. |
| `RQ1-UPDATE-001` | `experiments/rq1_update_001/retained/anchor_v2` | State, update, and interaction vector contrasts are all nonzero; only full/direct has syndrome `00` after the one-update budget. |
| `RQ1-UPDATE-CYCLE-001` | `experiments/rq1_update_cycle_001/retained/confirmation_v1` | All three vector contrasts are again nonzero; no cell is parity-valid after one update. |
| `RQ1-ENDPOINT-001` | `experiments/rq1_endpoint_001/results/2026-10-28_endpoint_v3` | Exact SP and `coral_exact_gradient` reproduce their native endpoints; the scalar-GD rungs differ one factor at a time. |
| `RQ1-GD-STATE-USE-001` | `experiments/rq1_gd_state_use_001` | Two-update toy precursor: retaining and using constructed check-specific offsets changes the scalar trajectory but not the toy hard decision or syndrome. |
| `RQ2-AWGN-001` anchor | `experiments/rq2_qbar_awgn_001/results/2026-10-28_anchor_v2` | Valid sealed descriptive anchor: full exact SP succeeds on 24/24 frames and persistent `qbar` tying on 0/24 for both registered endpoints. |
| `RQ2-CONFIRM-001` canonical | `experiments/rq2_qbar_awgn_001/results/2026-10-30_heldout_canonical_linux_v2` | Valid one-thread Linux confirmation: full exact SP succeeds on 200/200 frozen held-out frames and persistent `qbar` tying on 0/200 for both registered endpoints. |
| `RQ2-GD-STATE-USE-001` anchor | `experiments/rq2_gd_state_use_001/results/2026-10-31_anchor_v2` | Valid development anchor: active/control transmitted-word and parity-valid successes are 19/11, with 8 active-only and 0 control-only pairs. |
| `RQ2-GD-STATE-USE-001` held-out | `experiments/rq2_gd_state_use_001/results/2026-10-31_heldout_v2` | Valid 200-case confirmation: active/control transmitted-word and parity-valid successes are 172/113, with 59 active-only and 0 control-only pairs. |

The eligible evidence hashes are:

```text
state primary-v3 manifest  789aa3169cee64d74842a5f61bb894d215bca59f1f4e6778bf1fcb11afa77913
state cycle-v3 manifest    b053b56763d1887f65b400e98e4e1916d531b05a22648beb8a6dd6f140036a96
update tree payload        7dd166387313a6701c59d89aceec321133c771c33a4ddfcf9e96bcdb377ab2a8
update cycle payload       9c2c97b8994014bdccf3c1d259a76a43cb63293ca1964d468bfce51aed7f94c2
endpoint scientific trace c47e200c5be707b66e9fc454ee221671c4eb36771aedac6e143719b6a679e2f9
endpoint-v3 manifest       391a726e1485bc4610f5730b9978288b30e8e58a47e6c18f725de8fd5b2a6e83
RQ2 input freeze-v2        01a712d7c61498148aea92f54ea521101d8535b0ef56d095774b2d95bf6e8cb3
RQ2 freeze-v2 manifest     da5ac35be6daaa2a5652b1bdc28c2952c9526e74a03ab2ea72ef15de6c4c7204
RQ2 base science / replay  5147b5e1d0ddee175defa4dc7777667a2a981bc1a0404281935fcdc33679bc99
RQ2 science file           4bae20789e7ae5a67944e9109997a4390348c50c575e38736a1ec56e9fe79cc4
RQ2 manifest               e9d39519c3febff30250bfc21629cc5f4b6f3331e72f9b05f519ec62677b22b4
RQ2 completion record      14d719210453aad01de46560dda58b2580e830cb1bf08bbe1ef7e05642430c20
RQ2 canonical replay       71b865a7ac33667620a4c809e56f1bd60e8eb41c9de5c24c6bbe978f56c99d99
RQ2 canonical science      5b16e8b42513b13a626956a70465394def908bf5297e5ad37faa7657e3f40574
RQ2 canonical manifest     049c982c002b46ec77ff1c756139d5ca7e2a76774985cfd5ca40ae1a4d41a096
RQ2 canonical completion   582ab3c8a9e6e8dbe3ba9cd987bef7ce6b6ba26b6fc2457a7057bcee544017dd
RQ2-GD input freeze        53f515fda963da468e973568f503d1f0792cf161873d447826c5b4b7b182bee8
RQ2-GD freeze manifest     6f5494e3006abc7822132cc6b72ec4ae53940f02595496f4f8e156f3377612ef
RQ2-GD freeze checksums    80b494d883834b3fe6dd5412e2edf1b8966799848bfb269033fd2af412fdcaba
RQ2-GD anchor science      beb8517b8bb95c2d988728641942806d8292904a6fe186963029237fcf9e6bfa
RQ2-GD held-out replay     d4ba7a7a131e854e24399c3cc154bd891b16654a1b4834d1993838cf2d18601b
RQ2-GD held-out science    2ae5f7f636edbf6753529213993b7301535b23d916f465a3b7e1bf7ee9075a64
RQ2-GD held-out manifest   b3361fb5ff5d865ec86a51a8c89cb46a9ff8ffbe2babde2f639ba2aa74582428
RQ2-GD completion record   3099cce2f59f1a964031cf3ce329d1b39d0324224e8321827cf36d8c4ebbdda0
RQ2-GD result checksums    07b11ca649f544f5c07bfffaa4a97050709756236aa900cec6f983f38ea1e463
```

State primary/cycle `v1` and `v2` are superseded by `v3`, which adds the
explicit iteration-one collapse control, directional message labels, and
stricter replay and validation gates without changing the scientific values.
The update `anchor_v1` is excluded because its declared LLR sign convention
was opposite to the numerical vector, changing the hard-decision
interpretation.
Endpoint `v1` and `v2` retain the same scientific trace but are excluded because
their Git provenance capture failed. The versions named in the table are the
eligible records.

The RQ2 `anchor_v1` attempt is also excluded. Its canonical serializer raised
a `MethodError` on integer state-snapshot keys before any frame-level outcome
was retained. The authorized v2 repair changed only integer-key
serialization, added regression and tamper checks, and retained the same
frozen graph, channel cases, recurrence, intervention, and decision gates.

The rejected full-scale `R3-EDGE-FIXEDPOINT-001` attempt also remains excluded.
The bounded toy residual-gradient control diagnoses an update mechanism; it
does not revive that rejected receiver route.

## Numerical mechanism results

### Three-bit tree

The registered nonzero-sum channel evidence was

```text
L = (-ln(9), ln(3/2), ln(2)),
```

with $L_i=\log(P(b_i=1\mid y_i)/P(b_i=0\mid y_i))$. At the selected variable
calculation, full BP supplies `ln(3)` and `ln(1/6)` from the shared bit to its
two checks, whereas tying supplies `-0.5 ln(2)` to both. Full BP produces the
hard-decision estimate `000` with syndrome `00`; the tied branch produces
`001` with syndrome `01` at that snapshot.

Here the syndrome is $s=(H\hat b)\bmod 2$, with all arithmetic over GF(2).

The one-update factorial bench gives:

| Cell | Hard-decision estimate | Syndrome |
|---|---|---|
| full/direct | `000` | `00` |
| full/residual-gradient | `001` | `01` |
| tied/direct | `001` | `01` |
| tied/residual-gradient | `001` | `01` |

Its Euclidean vector-contrast norms are:

```text
state       1.465181905609834
update      1.071596172705627
interaction 1.484908686870001
```

### Four-bit cycle

The transferred step size was not retuned. The cycle confirms nonzero vector
contrasts:

```text
state       2.130829937421622
update      1.190807282140601
interaction 2.1595188093747844
```

All four hard-decision estimates have nonzero syndrome after the one-update
budget. This confirms a trajectory mechanism, not a decoding advantage.

### Control behavior that limits the claim

- The iteration-one collapse is an explicit no-op because all outgoing values
  from a bit are initially equal.
- The degree-one six-bit graph is a null control because every `delta` is zero.
- Retaining but ignoring `delta` equals the tied branch.
- Reconstructing `qbar + delta` equals full BP.
- On the tree, a one-update pulse can rejoin full BP one update later;
  persistent tying remains different. A snapshot effect is therefore not by
  itself a convergence or error-rate result.

## Native endpoint bridge

The bridge prevents two substitutions that would otherwise invalidate the
comparison:

- the BP endpoint is exact sum-product, not the normalized-min-sum decoder
  used by the older AWGN plot; and
- the projected-GD endpoint is specifically `coral_exact_gradient`, not the
  BP-residual gradient control.

The exact-SP endpoint matches JadeJcade's native exact decoder on the tree. On
the scalar lane, the parity-only teaching step matches the product-parity
kernel after the registered sign and objective-scale conversion. The bridge
then adds channel evidence, the binary penalty, native step size, diagonal
preconditioning, strict-decrease line search, and the 30-step stopping rule in
separate rungs. The current and archived exact-gradient CORAL endpoints match
each other bit-for-bit. The composed ladder matches their final state and
objective trace within a maximum absolute difference of
`6.661338147750939e-16`, with the same accepted-step count, evaluation count,
and status.

This bridge verifies what the two native endpoints are. It does not turn the
BP mean `qbar` into the GD scalar state or make the check calculation and GD
partial derivatives equivalent.

## RQ1 decision

> **RQ1 is partially resolved, with native attribution still open.** On the
> declared degree-two tree and cycle with fixed parity-check matrix, channel
> LLR vector, starting check-to-variable state, schedule, and check operation,
> removing BP's recipient-specific variable-to-check component causes the
> first reproducible divergence at the values supplied to the checks;
> reconstructing that component restores full BP exactly. In a separate
> BP-residual control, changing the recipient-specific calculation and changing
> direct map assignment to one true residual-gradient step each produce
> nonzero one-update trajectory contrasts, with a nonzero
> difference-in-differences, on both graphs. These are validated candidate
> trajectory mechanisms. They do not identify a unique native
> BP-versus-projected-GD mechanism or explain its performance difference.

## RQ2 transfer test

The approved long-code test transfers only the recipient-specific-state
candidate into an exact-SP decoder. It compares full exact SP with persistent
`qbar` tying while holding fixed the parity-check matrix and graph hash,
all-zero transmitted word, frame and noise seed, received samples, channel-LLR
vector, sign convention and hashes, initialization, stopping rule, and
80-iteration maximum budget. Both arms compute `Q*`, `qbar`, `delta`, and
edge-shaped arrays; only the variable-to-check message consumed by the next
check differs.

This test can answer:

> Within the locked exact sum-product recurrence, does discarding
> recipient-specific variable-to-check information change parity-valid or
> transmitted-word recovery?

Even a positive answer cannot establish that this mechanism alone explains
the native BP-versus-projected-GD gap. The tied arm still uses exact BP check
calculations, check-to-variable messages, and no gradient objective or box
projection.

### Retained descriptive anchor

The sealed `2026-10-28_anchor_v2` record has `status = valid`,
`validation_passed = true`, and a passed deterministic replay. The full arm
also matches the native exact-SP states bit-for-bit on all 24 frames. Its two
registered endpoints have the same paired outcome table:

| Endpoint | Full success | Persistent-`qbar` success | Full-only discordance | Risk difference, full minus tied |
|---|---:|---:|---:|---:|
| Parity validity | 24/24 | 0/24 | 24 | 1 |
| Equality to the transmitted word | 24/24 | 0/24 | 24 | 1 |

For each endpoint, the registered two-sided 97.5% Newcombe paired-proportion
method-10 interval is `[0.7552068689185257, 1]`. The exact two-sided McNemar
p-value is `1.1920928955078125e-7`, and its Holm-adjusted value across the two
endpoints is `2.384185791015625e-7`. These interval and p-values are
descriptive for the anchor; the registered counts and validation checks
satisfy the expansion rule. The full arm stopped after 14--44 message-passing
iterations, with mean `18.2083`, while every tied run reached the 80-iteration
cap.

The anchor is descriptive only and is not pooled into held-out inference. Its
gate authorized the preregistered 200-frame held-out confirmation. The first
manifest-bound attempt was intentionally stopped after about 26 minutes,
during native preflight, before the atomic runner wrote any frame, endpoint,
science, or manifest output. It contributes no held-out outcome.

### Retained canonical held-out confirmation

The `2026-10-30_heldout_canonical_linux_v2` record evaluates all 200 frozen
held-out frames under the registered one-thread Linux protocol. It has
`status = valid`, `validation_passed = true`, passes native full-state
equivalence, every frame and checksum gate, and deterministic replay. Its two
scientific passes both produce SHA-256
`71b865a7ac33667620a4c809e56f1bd60e8eb41c9de5c24c6bbe978f56c99d99`.
Its registered endpoints agree:

| Endpoint | Full success | Persistent-`qbar` success | Full-only discordance | Risk difference, full minus tied |
|---|---:|---:|---:|---:|
| Parity validity | 200/200 | 0/200 | 200 | 1 |
| Equality to the transmitted word | 200/200 | 0/200 | 200 | 1 |

For each endpoint, the registered two-sided 97.5% Newcombe method-10 interval
is `[0.96534624278665548, 1]`. The exact two-sided McNemar p-value is
`1.2446030555722283e-60`, and its Holm-adjusted value across the two endpoints
is `2.4892061111444567e-60`. Full exact SP stopped after 12--70
message-passing iterations, with mean `18.485`; every tied run reached the
80-iteration cap. The run used one Julia thread, one BLAS/OMP thread, and GNU
gzip 1.10 as registered. All 57 checksum entries verify.

The earlier `2026-10-28_heldout_parallel_windows_v1` transfer used four Julia
threads and GNU gzip 1.14. Its frames, aggregate table, iteration table, and
deterministic compressed state snapshot are byte-identical to the canonical
Linux result. It is cross-platform corroboration; the canonical Linux record
is the confirmatory result.

As a reporting invariant, endpoint flags are evidence only when the record's
registered terminal-valid status and correctness fields pass, deterministic
replay passes, and its manifest/checksum gates pass. For the exact-SP anchor
and canonical confirmation these fields are `status = valid` and
`validation_passed = true`; the projected-GD experiment uses its own
registered `complete_valid` and `correctness_passed` fields. This prevents a
failed or partially serialized attempt from becoming endpoint evidence.

## Projected-GD check-specific-state-use transfer

`RQ2-GD-STATE-USE-001` asks a different controlled question on the native
projected-gradient scalar backbone. Both arms calculate and physically retain
one bounded, mean-zero check-specific offset for every Tanner-graph edge after
each accepted update. The control does not use those offsets in the next
update: it evaluates the unshifted parity objective and projects each scalar
into `[-1,1]`. The active arm holds the offsets fixed through the
partial-derivative calculation and line search, uses the shifted readings
`x_i + delta_(c,i)` in the parity objective, and projects each scalar into the
intersection of the intervals that keep those readings in `[-1,1]`. It
refreshes the offsets only after an accepted update.

The graph, received samples, channel LLRs, initialization, objective weights,
preconditioner, backtracking procedure, componentwise projection procedure,
hard-decision rule, and 30-update budget are fixed pairwise. The objective
inputs and resulting projection bounds are the registered treatment. Neither
arm calls BP, normalized min-sum, a pseudogradient, a word list, or an oracle.
The treatment therefore tests subsequent use of equally retained offsets
through both the parity objective and its induced scalar feasibility interval;
it does not separately isolate retention, parity-objective use, or projection.

Before freeze, original anchor frame 1 was quarantined after an independent
validator accidentally ran three active updates and observed an intermediate
coded-error count. The endpoint was not run and the value was not communicated
to the primary runner. The anchor was mechanically shifted from frames 1:24 to
2:25; confirmation frames 10001:10200 remained untouched. The v2 freeze holds
the same 224 input identities as v1, with byte-identical input table SHA-256
`53f515fda963da468e973568f503d1f0792cf161873d447826c5b4b7b182bee8`.

The v2 development anchor is `complete_valid`, passes deterministic replay,
and is scientifically byte-identical to v1. Active/control transmitted-word
and parity-valid successes are 19/11, with 8 active-only and 0 control-only
pairs. This authorized the already frozen confirmation and is not pooled with
it.

The eligible held-out record has `status = complete_valid`; all 15 correctness
gates and all 39 checksum entries pass. Its first and replay scientific hashes
both equal
`d4ba7a7a131e854e24399c3cc154bd891b16654a1b4834d1993838cf2d18601b`.
The registered confirmatory endpoints are:

| Endpoint | Active successes | Control successes | Active only | Control only | Active minus control | 97.5% Newcombe interval | Exact McNemar p | Holm-adjusted p |
|---|---:|---:|---:|---:|---:|---|---:|---:|
| Transmitted-word equality | 172/200 | 113/200 | 59 | 0 | 0.295 | [0.2206105421, 0.3667643089] | 3.469446952e-18 | 6.938893904e-18 |
| Parity validity | 172/200 | 113/200 | 59 | 0 | 0.295 | [0.2206105421, 0.3667643089] | 3.469446952e-18 | 6.938893904e-18 |

Information-word equality is supporting output: active/control successes are
183/143, with 40 active-only and 0 control-only pairs. Neither arm produces a
wrong valid word.

The trajectory locates the controlled causal boundary. All 200 pairs have
identical scalar state, partial-derivative vector, accepted scalar update, and
retained offsets through update 1. At update 2, both arms enter with the same
scalar state and retained offsets, but only the active arm uses those offsets
in its parity objective and induced scalar feasibility interval. Every
partial-derivative vector and accepted scalar update then differs. From update
3 onward, both the scalar state and refreshed offsets differ in all 200 pairs.
The decoding-outcome difference therefore follows a registered joint-use
divergence, not a different Tanner-graph traversal.

Each arm retains 40,800 `Float64` values across updates: 10,200 scalar values
and 30,600 check-specific offsets, for a 326,400-byte persistent-state
footprint. This is not total process allocation. In this constructed
implementation, median timed execution is 5.543 seconds for active and 0.582
seconds for control; median allocation within the timed solver boundary is
about 2.752 GB and 229 MB. That boundary excludes input generation, validation,
hashing, and serialization. These are implementation-specific work
measurements, not an asymptotic-complexity result or an optimized decoder
comparison.

The first v1 held-out command failed while attaching the nested Newcombe
inference object and wrote no eligible held-out result. The repair changes only
the result-container type and adds direct inference-assembly tests. A first v2
service was later terminated by signal 15 when tied to a tool-session lifetime
and also wrote no result. The eligible detached-service run uses the same
immutable v2 freeze, valid anchor, and scientific protocol.

> **Scoped causal conclusion.** Under the locked graph, 6 dB AWGN cases,
> initialization, and 30-update budget, using the constructed retained
> check-specific distinction jointly in the parity objective and its induced
> scalar feasibility interval improves transmitted-word recovery and parity
> validity relative to calculating and retaining the same distinction but not
> using it. This rules out graph traversal alone as a sufficient explanation
> for this controlled contrast. It does not show that the offsets are BP
> messages, reproduce BP, isolate retention, separate parity-objective use
> from projection-bound use, or uniquely explain the complete native
> BP-versus-projected-GD performance difference. Native attribution therefore
> remains open.

Stop this construction without tuning. The next registered bridge should hold
one representation fixed while changing one calculation or update operator at
a time. Its first split should separate use of the offsets in the parity
objective from use in the scalar feasibility interval before moving on to the
BP check calculation and scalar update operator.

## `RQ2-GD-OFFSET-SPLIT-001` terminal execution boundary

This experiment is the authorized causal bridge from
`RQ2-GD-STATE-USE-001`. It holds the retained scalar and check-specific offset
state fixed across four constructed projected-GD arms, then independently
switches whether those offsets are read by the parity calculation and whether
they restrict the interval used by the projection step. Its purpose is to
separate the two operations that changed together in the retained compound
intervention; it is not a new receiver route or a native BP comparison.

The serial queue reached a terminal execution failure on 31 October 2026.
Jobs J01--J03 completed: the focused tests, source and input freeze, 24-case
development anchor, embedded-replay record, correctness gates, and anchor
checksums passed. J04, the 200-case held-out execution, was terminated with
exit code 124 after the registered service sent `TERM` at 17,880 seconds,
leaving the 120-second termination grace inside the 18,000-second wall-clock
budget. J05 did not run.

The anchor is `complete_valid`, passes deterministic replay, and authorizes
held-out execution, but it remains development-only. During J04 the primary
200-case calculation finished only in process memory. The replay journal
reached 124 complete cases and three of four arms on case 30125 when the
process terminated. No held-out `frames.csv`, `aggregate.csv`, `science.json`,
completion record, result manifest, or checksum manifest was written. The
partial in-memory calculation is lost and is not admissible held-out evidence;
the stale result journal's `status = running` is overridden by the terminal
queue and J04 failure records.

The J04 log reports 210,954,672,931 allocations and 112,061 garbage
collections, and the termination stack was inside the bounded-mean offset
construction during replay. This is evidence of severe allocation pressure in
this implementation and explains why execution feasibility must be addressed.
It does not identify one routine as the sole runtime cause, isolate either
registered factor, or provide a decoding-performance mechanism: the long
post-primary inference, bootstrap, hashing, and replay interval was not
instrumented finely enough for that attribution.

> **Scientific boundary.** `RQ2-GD-OFFSET-SPLIT-001` produced no eligible
> held-out endpoint and therefore no causal answer about parity-calculation use,
> projection-bound use, or their interaction. The favorable retained result
> from `RQ2-GD-STATE-USE-001` remains a joint-use effect; this failed execution
> neither confirms nor contradicts a decomposition of that effect.

At the time of this terminal record, no relaunch or successor was authorized.
A cap-only successor required a prospective protocol amendment, new attempt
and output directories, and explicit approval because it changes the
queue-level wall-clock stopping rule. An optimized successor would require a
new source freeze, preflight, and bit-for-bit scientific-equivalence evidence
before execution. Either path must preserve this failed attempt.

### Approved cap-only v2 successor

The user subsequently approved the prospective amendment `RQ2-AMEND-001` and
its launch as `RQ2-LAUNCH-001`. The v2 successor changes one protocol field:
the held-out queue-level wall-clock service budget increases from 18,000 to
36,000 seconds. `TERM` is sent at 35,880 seconds, with 120 seconds reserved
inside that budget for termination.

The per-arm projected-GD stopping rule remains at most 30 update attempts or
the first line-search stall. The scientific runner, graph, frame identities,
seeds, received samples, channel LLRs, four arms, retained-offset construction,
parity calculations, partial-derivative calculations, projection steps,
endpoints, inference, one-thread environment, and two scientific passes remain
unchanged. V2 uses new freeze, anchor, held-out, and queue directories; it does
not resume the v1 journal. The v2 freeze must reproduce the 224 input rows byte
for byte, and the v2 anchor must reproduce the v1 anchor science file exactly
before held-out execution.

This is an approved execution amendment, not causal evidence. The mechanism
question remains unanswered until the new held-out result and all registered
gates complete.

### Implementation-equivalent v3 successor

The v2 held-out primary pass completed all 200 cases and then entered the
legacy iteration-table hash without first publishing a scientific result. It
was deliberately stopped only after a v3 anchor reproduced the registered
v1/v2 anchor science file exactly. The resulting v2 J04 exit code 143 records
an operational retirement, not a decoding outcome; v2 supplies no held-out
causal evidence.

`RQ2-OPTIMIZE-001` changes the hash input construction from
`sha256(codeunits(s))` to
`sha256(Vector{UInt8}(codeunits(s)))`. The byte sequence and digest are
unchanged. V3 also writes phase-level progress, appends phase start/end times,
and checkpoints the primary frames, iterations, and science record before
replay. Those changes improve execution observability and recoverability; they
are not changes to the graph, cases, four arms, partial-derivative
calculations, projection steps, endpoints, inference, or update budget.

The corrected v3 anchor is `complete_valid` and its `science.json` SHA-256 is
`2062fce292d4b41cf93c6dd86afdb6855345b52ff1408d9c89c7318e25b20d46`,
exactly matching v1 and v2. Its primary and replay iteration-table hashes took
`0.222612771` and `0.257836261` seconds. Measured anchor phase times project a
200-case held-out wall time of `11399.347925517` seconds; applying the frozen
1.5 safety factor gives a 17,100-second wall budget, with `TERM` after 16,980
seconds and 120 seconds reserved for termination.

At the publication snapshot, the held-out v3 unit
`sp-gd-rq2-offset-split-v3-20261031.service` is still running. Its mutable
progress journal, phase log, queue log, and incomplete result directory are
therefore not frozen into this commit. The completed anchor and locked v3
execution package are retained, but no v3 held-out causal conclusion exists
until both scientific passes and every result gate complete.

## Complexity boundary

The graph sweeps in these variants are linear in the number of edges for a
fixed maximum check degree, but this does not make their work or storage
identical. Exact sum-product uses nonlinear check calculations and directed
messages; scalar GD forms partial derivatives, applies projections, and may
perform backtracking evaluations. The retained experiments therefore list
primitive-operation categories, persistent values, temporary values, runtime,
and allocated bytes separately instead of collapsing them into one nominal
`O(E)` statement.

## Communication boundary

The animation is explanatory output. It must show the first validated
divergence, use `Q` for variable-to-check values and `U` for check-to-variable
values, and show GD partial derivatives as temporary calculations. It is not
evidence for convergence, BER, FER, ensemble behavior, or equal computational
work.

`offset_split_explainer.html` is likewise explanatory output. Its completed
counts and contrasts point to retained result files, while its v3 execution
panel is explicitly a 21:26 CST, 31 October 2026 observer snapshot. The panel
must not be read as a completed offset-split result or as evidence that the
constructed offsets are BP messages.
