# `RQ2-GD-OFFSET-NULL-001` null-structure controls for the retained offsets

Status before execution: **preregistered design; implementation, tests, and
input freeze must pass before any registered endpoint is calculated**.

`RQ2-GD-OFFSET-NULL-001` is an internal experiment ID, not a receiver name.
ADMM is outside this experiment. No BP arm is added. All four arms are
constructed projected-gradient variants on the protocol of
`RQ2-GD-OFFSET-SPLIT-001`, which this experiment inherits unchanged.

## Research question

`RQ2-GD-STATE-USE-001` showed that reading one retained offset
`delta_(c,i)` per Tanner-graph edge in the next projected-gradient update
raises recovery from 113/200 to 172/200 on locked 6 dB cases. That result
has been read as evidence that check-specific state helps projected GD. Two
other readings fit the same numbers:

1. **Perturbation.** Any per-edge spread of readings with the same per-bit
   multiset would help as much, because it perturbs a non-convex parity
   landscape; which check sees which reading does not matter.
2. **One-time reshaping.** Offsets built once after the first accepted update
   and never refreshed would help as much; the refresh after every accepted
   update is not what carries the effect.

This experiment asks:

> On the split experiment's frozen cases, how much of the compound arm's
> recovery survives when (a) each bit's offsets are reassigned among that
> bit's own checks after every refresh, and (b) the offsets are built once and
> never refreshed?

## Mechanism and arms

Every arm retains one scalar `x_i` per bit and one offset `delta_(c,i)` per
edge, built by the retained bounded-mean construction after an accepted
update, and fixed during the next partial-derivative calculation and line
search.

| Arm | Kernel | Parity term | Projection interval | Offsets after a refresh |
|---|---|---|---|---|
| `control` | retained split kernel (`objective0__bounds0`) | `F_0(x)` | `[-1,1]` | built, stored, never read |
| `reference` | retained split kernel (`objective1__bounds1`) | `F_delta(x)` | offset-induced | as built |
| `permuted` | copied kernel, same switches as `reference` | `F_delta(x)` | offset-induced | each bit's offsets reassigned among its checks by a random derangement |
| `frozen` | copied kernel, same switches as `reference` | `F_delta(x)` | offset-induced | built after the first accepted update only; never refreshed |

The permutation keeps every bit's multiset of offsets, its zero sum, its
projection interval, and the box membership of every reading. It changes only
which check reads which offset. With degree 3 it is one of the two cyclic
shifts, drawn from `MersenneTwister(20261101 + frame)` in bit order at every
refresh.

The frozen arm is projected GD on one fixed shifted objective from update 2
onward. Its offsets are identical to the reference arm's through the end of
update 2; its first possible divergence in `x` is update 3.

The permuted arm's first possible divergence in `x` is update 2.

## Protocol fingerprint

Inherited byte for byte from `RQ2-GD-OFFSET-SPLIT-001` (`config.toml` SHA-256
`d5f55d93…39a9`): regular `(3,6)` LDPC graph with `N=10200`, graph SHA-256
`94d94376…e2d`; known unit-gain complex AWGN at `Es/N0 = 6 dB`; channel LLRs
positive in favor of coded bit zero, clipped to `[-20,20]`; `x_i^(0) =
tanh(ell_i/2)`; `mu_p = 2`, `mu_b = 0.2`; native diagonal preconditioner;
initial step `0.2`; at most 16 halvings; 30 update attempts; no syndrome
early stop; one Julia, BLAS, and OpenMP thread.

The anchor is frames `20001:20024` and the held-out set is frames
`30001:30200`: the same frames, noise seeds, and received samples as the split
experiment. The regenerated input table must be byte-identical to the split
freeze (`input_freeze.csv` SHA-256 `739da194…b5bd`), and the regeneration
must match row for row during every stage.

The `control` and `reference` arms are executed by the retained split
runner's own `solve_variant`; the permuted and frozen arms run a copy of that
kernel with one hook each. On the anchor stage, the copy in reference mode
must reproduce the retained compound arm bit for bit on every frame.

## Closest retained experiments and anti-duplicate decision

- `RQ2-GD-STATE-USE-001`: compound arm versus control; supplies the effect
  being decomposed.
- `RQ2-GD-OFFSET-SPLIT-001`: separates parity-term use from the projection
  interval; does not test whether the check assignment or the refresh matters.
- `RQ1-STATE-002`: the analogous destroy-the-specificity control on the BP
  side (tying outgoing messages to their mean).

No retained record contains a permuted-offset or frozen-offset arm on this
protocol.

## Preregistered contrasts and predictions

For a binary endpoint `Y` on one frozen case:

```text
primary      reference - permuted      does the check assignment matter?
primary      reference - frozen        does the refresh matter?
descriptive  reference - control       the compound effect on these cases
descriptive  permuted - control
descriptive  frozen - control
```

Predictions under the two readings:

- If the compound effect is check-specific information, `permuted` falls to
  the neighbourhood of `control` and `reference - permuted` is positive.
- If the compound effect is perturbation, `permuted` stays near `reference`
  and `reference - permuted` is near zero.
- If the refresh carries the effect, `frozen` falls toward `control`.
- If a one-time reshaping suffices, `frozen` stays near `reference`.

All five contrasts are retained regardless of sign.

## Endpoints and inference

Confirmatory endpoints: equality of the hard-decision estimate to the
transmitted word, and satisfaction of every parity check. Supporting outputs:
information-word equality, bit errors, syndrome weight, wrong-valid-word
count, accepted steps, offset refreshes, permutation-moved edges, objective
values, overshoot diagnostics, runtime and allocation.

Each contrast uses paired success counts, a two-sided exact McNemar test, and
a Newcombe method-10 paired risk-difference interval. The ten tests (five
contrasts, two endpoints) form one Holm family at familywise alpha 0.05; the
simultaneous interval level is 0.995. The anchor is descriptive and is not
pooled with the held-out result.

## Work budget and stopping rule

- Four arms per case, at most 30 update attempts per arm, two scientific
  passes per stage, plus one kernel-equivalence run per anchor frame.
- Anchor wall budget 7,200 s; held-out wall budget 36,000 s. The budgets are
  generous because the queue runs at `nice 19` beside the split experiment's
  queue and is paused by a watchdog whenever that queue's frame interval
  degrades. Runtime and allocation columns are therefore contaminated by
  design and are diagnostic only.
- No parameter change, SNR change, restart, or extra case under this ID. A
  line-search stall is retained as that arm's outcome.
- Failure classes: `gate_failure` (a registered correctness gate is false:
  the stage is written `complete_invalid` and the queue stops),
  `interrupted` (wall budget or signal: the attempt directory is retained
  with its progress journal and nothing is relaunched automatically), and
  `environment` (source or freeze gate fails before calculation: nothing is
  written). Any manual relaunch uses a new attempt directory and the frozen
  command, and is recorded in the queue log.
- Marker files: `jobs/J*/COMPLETED.toml` or `FAILED.toml` in the queue
  directory; `COMPLETED.toml` in each result directory; `progress.toml`
  updated after every arm.
- Re-execution is harness-only: the queue script is the only launcher.

## Correctness gates before interpretation

1. Source gate: the split configuration, split runner, legacy runner, and the
   split freeze table match their registered hashes; the retained static
   sources pass the legacy gate.
2. Freeze gate: the regenerated input table is byte-identical to the split
   freeze and to this experiment's freeze; authored sources are unchanged.
3. On every anchor frame the copied kernel in reference mode reproduces the
   retained compound arm's terminal scalar state, offsets, and hard-decision
   estimate bit for bit.
4. All four arms have equal scalar state after update 1; `control`,
   `reference`, and `frozen` have equal offsets after update 1; `permuted`
   has the same per-bit multiset after update 1 with every edge moved.
5. `frozen` equals `reference` in scalar state through update 2 and performs
   exactly one refresh; its offsets are constant after that refresh.
6. Every scalar trial stays inside its interval; every reading stays in
   `[-1,1]`; every bit's offsets sum to zero within tolerance; offsets are
   unchanged during every partial-derivative calculation and line search.
7. Independent hard-decision and syndrome calculations agree with the kernel.
8. Both scientific passes have the same canonical scientific SHA-256; the
   checksum manifest is complete; existing outputs are never overwritten.

Failure of a predicted effect is not a correctness failure. The held-out run
is authorized after the anchor's correctness gates pass, whatever the anchor's
outcome ordering.

## Registered interpretation map

- `reference - permuted` positive with `permuted` near `control`: the gain
  requires the check-specific assignment; the extrinsic-information reading
  survives this control.
- `reference - permuted` near zero: the gain is a property of the per-edge
  spread, not of which check reads which offset; the BP analogy is not
  supported by this construction, and the next bridge should not be built on
  it.
- `reference - frozen` near zero: a one-time reshaped objective suffices; the
  refresh is not the mechanism.
- `reference - frozen` positive with `frozen` near `control`: the refresh
  after every accepted update is required.

## Claim boundary

A valid result attributes, among four constructed projected-gradient variants
on the locked graph, 6 dB sample, initialization, and 30-update budget,
whether the compound effect depends on the check assignment of the offsets
and on their refresh. It does not show that the offsets are BP messages,
reproduce BP, establish a BER or FER ordering, or explain the native BP
versus projected-GD gap. Its purpose is to decide whether the retained
construction is a legitimate rung toward BP before any further rung is built.
