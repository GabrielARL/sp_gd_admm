# BP--GD mechanism report

Last updated: 2026-10-28

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
tying did so on none. This anchor passed its registered expansion gate, but it
is descriptive, is not pooled with the held-out set, and does not close native
BP-versus-projected-GD attribution.

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
| `RQ2-AWGN-001` anchor | `experiments/rq2_qbar_awgn_001/results/2026-10-28_anchor_v2` | Valid sealed descriptive anchor: full exact SP succeeds on 24/24 frames and persistent `qbar` tying on 0/24 for both registered endpoints. |

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

The anchor is descriptive only and will not be pooled into held-out inference.
Its gate authorizes the preregistered 200-frame held-out confirmation, which is
still incomplete. The first manifest-bound attempt was intentionally stopped
after about 26 minutes, during native preflight, before the atomic runner wrote
any frame, endpoint, science, or manifest output. It contributes no held-out
outcome. A future complete result must pass validation and its in-run
deterministic replay before it is reportable.

As a reporting invariant, parity-validity and transmitted-word-equality flags
are void unless the sealed result simultaneously records `status = valid`,
`validation_passed = true`, and a passed deterministic replay. This prevents a
failed or partially serialized attempt from becoming endpoint evidence.

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
