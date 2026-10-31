# `RQ2-NATIVE-GAP-001` native BP and native projected GD on the same frozen cases

Status before execution: **preregistered design; implementation, tests, and
input freeze must pass before any registered endpoint is calculated**.

`RQ2-NATIVE-GAP-001` is an internal experiment ID, not a receiver name. ADMM
is outside this experiment. No receiver is tuned. The Es/N0 profile is
descriptive and selects one second confirmatory operating point by a rule
fixed here.

## Research question

The RQ2 chain measures BP's state ablation at 1.5 dB
(`BPGD-RQ2-QBAR-AWGN-001`) and projected GD's constructed interventions at
6 dB (`RQ2-GD-STATE-USE-001`, `RQ2-GD-OFFSET-SPLIT-001`), with no BP arm in
the GD experiments. The native gap that the chain is meant to explain has not
been measured on any shared set of cases.

> On the split experiment's frozen held-out cases at 6 dB, and at one lower
> Es/N0 where BP is not saturated, how often do native exact sum-product BP
> and native projected GD recover the transmitted word and satisfy every
> parity check?

This is a scoped performance ordering. It locates the difference; it cannot
identify its cause, because the two native methods differ in state, parity
action, objective, and update rule at once.

## Methods

- **BP:** JadeJcade exact tanh-atanh sum-product, flooding schedule, no
  damping, at most 80 message-passing iterations, stop at the first zero
  syndrome; hard-decision estimate `bit_i = 1` iff the posterior LLR is
  negative. The kernel is the one used by `BPGD-RQ2-QBAR-AWGN-001`; its
  implementation is textually identical between JadeJcade `57599f7` and the
  worktree `a4a4f81` that the GD experiments use.
- **GD:** the split experiment's `objective0__bounds0` arm, executed by the
  retained split runner: `x_i^(0) = tanh(ell_i/2)`, `mu_p = 2`, `mu_b = 0.2`,
  native preconditioner, initial step 0.2, at most 16 halvings, 30 update
  attempts, projection into `[-1,1]`, no syndrome early stop.

Both methods decode the same clipped channel LLR vector of each case. The
channel generator is the retained one; the six-dB identities must equal the
split freeze row for row.

## Stages and protocol

| Stage | Frames | Es/N0 | Purpose |
|---|---|---|---|
| `six` | `30001:30200` | 6.0 dB | the gap on the split experiment's held-out cases |
| `profile` | `20001:20024` | 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 5.0, 6.0 dB | descriptive recovery profile of both methods; selects the second Es/N0 |
| `second` | `30001:30200` | selected | the gap where BP is not saturated |

A frame's unit noise is seeded by its frame index, so the same noise draw is
used at every Es/N0 and only its scale changes. The complex-noise variance is
`10^(-Es/N0 / 10)`; at 6 dB it equals the retained value
`0.251188643150958`.

Selection rule for the second Es/N0: the highest grid value below 6 dB at
which BP recovers at most 20 of the 24 profile frames. If BP exceeds 20 at
every grid value, the lowest grid value (1.5 dB) is used and the saturation
flag is set in the profile result. The rule is applied by the runner from the
profile result's `selection.toml`; nothing is chosen by hand.

## Closest retained experiments and anti-duplicate decision

- `BPGD-RQ2-QBAR-AWGN-001`: BP at 1.5 dB on frames `1:24` and `10001:10200`;
  reports full BP 200/200. Different frames and Es/N0 from the GD chain.
- `R5-AWGN-ISOLATION-R050-001` (archived JadeJcade run): native receivers on
  an Es/N0 sweep with their own frame indices.
- No retained record places exact sum-product BP and the split control on
  frames `30001:30200` or `20001:20024`.

## Endpoints and inference

Confirmatory endpoints on `six` and `second`: transmitted-word equality and
parity validity, BP minus GD, paired success counts, two-sided exact McNemar
tests, Newcombe method-10 intervals at 97.5%, Holm over the two endpoints at
familywise alpha 0.05. Supporting outputs: information-word equality, bit
errors, wrong-valid-word count, BP iterations, GD accepted steps, runtime and
allocation (diagnostic only; contaminated by concurrent load).

The profile stage reports counts per Es/N0 without tests. It also checks the
1.5 dB BP figure retained from the qbar experiment on 24 fresh frames; a
disagreement with the expectation of near-saturation there is reported as an
observation, not acted on.

## Work budget and stopping rule

- Two methods per case; two scientific passes per stage; one synthetic
  warm-up per method; one timed execution per method and case.
- Wall budgets: 5,400 s per stage. No restart, no extra frame, no change of
  iteration cap or step rule under this ID.
- Failure classes and markers as in `RQ2-GD-OFFSET-NULL-001`: `gate_failure`,
  `interrupted`, `environment`; `COMPLETED.toml` per result directory;
  `jobs/J*/COMPLETED.toml` or `FAILED.toml` in the queue directory.
- Re-execution is harness-only.

## Correctness gates before interpretation

1. Source gate on the split configuration, runners, freeze table, and anchor
   frames table; retained static sources pass the legacy gate.
2. Freeze gate: regenerated identities equal the freeze row for row; six-dB
   identities equal the split freeze.
3. The BP kernel's validity flag equals an independent syndrome calculation
   on every case.
4. On the profile stage at 6 dB, the GD hard-decision estimate equals the
   split anchor's `objective0__bounds0` estimate on every frame.
5. Both scientific passes have the same canonical scientific SHA-256.

## Claim boundary

A valid result states, for these frozen cases and these two Es/N0 values,
how often each native method recovers the word and satisfies every check, and
the paired difference between them. It does not attribute the difference to
any mechanism, does not establish a general BER or FER ordering, and does not
compare computational complexity.
