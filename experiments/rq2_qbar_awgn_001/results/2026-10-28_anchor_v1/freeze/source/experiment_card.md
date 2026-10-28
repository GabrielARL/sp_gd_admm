# `BPGD-RQ2-QBAR-AWGN-001` exact-SP state ablation

Status before execution: **approved, frozen design; executable gates required**.

## Question and scope

This RQ2 experiment asks whether retaining BP's recipient-specific
variable-to-check distinctions changes valid-codeword recovery or transmitted-
word recovery.  It is a candidate-mechanism ablation inside exact sum-product
BP.  It is not projected gradient descent, and even a positive result cannot by
itself attribute the native BP-versus-projected-GD performance difference.
ADMM is outside the experiment.

This is the registered `RQ2-AWGN-001` transfer study authorized by
`BPGD-APP-009`, not a new RQ1 mechanism claim.  Its closest retained experiment
is `RQ1-STATE-002`: that study uses a selected one-update pulse on toy graphs,
whereas this card uses persistent tying in a long-code AWGN decoder.  The
retained Jade AWGN table supplies only anchor received-sample and clipped-LLR
identities; it contains neither this exact-SP full arm nor a `qbar`-tied arm.
Therefore those rows are not a prior execution of this ablation.  Repeating
this graph, frame set, SNR, treatment, and outcome contract under another name
would be a duplicate rather than a new experiment.

## Only causal intervention

For bit `i` and neighboring check `a`, both arms compute

```text
Qstar[i->a] = L[i] + sum_{b in N(i), b != a} U[b->i]
qbar[i]     = mean_a Qstar[i->a]
delta[i->a] = Qstar[i->a] - qbar[i].
```

The full arm retains `Qstar[i->a]`.  The tied arm writes the same `qbar[i]`
into every outgoing edge slot.  Both arms allocate and compute `Qstar`, `qbar`,
`delta`, `Q`, and `U` with the same code path.  The single treatment branch
selects which already-computed value is consumed by the next check update.
Tying begins after check iteration 1, so its first possible effect is on check
iteration 2.  Check-to-variable messages remain edge-specific in both arms.

The physical edge-shaped arrays are deliberately retained in both arms.  This
tests information content rather than an implementation-level memory saving.
The logical independent state count and actual allocated storage are reported
separately.

## Locked protocol

- Known unit-gain post-FFT complex AWGN, without pilots, channel estimation,
  CFO, or ICI.
- Unit-energy QPSK and the all-zero transmitted codeword.
- Regular `(3,6)` LDPC graph with `N=10200`, `K=5100`, graph seed
  `169616412`, and graph SHA-256
  `94d94376995c6eb9e21a5859dde6354d7233f61634b5dbdc91fd70653f5f6e2d`.
- Physical `Es/N0 = 1.5 dB`.
- Channel LLRs are positive in favor of coded bit zero and clipped to
  `[-20,20]` before either arm receives them.
- Exact JadeJcade tanh/atanh sum-product check calculation, flooding schedule,
  no damping, and identical channel initialization.
- Both arms stop at the first zero-syndrome hard-decision estimate or after 80
  message-passing iterations.  The stopping rule and cap are fixed; realized
  iteration count is a treatment-mediated outcome and is reported as work.
  The claim is therefore same kernel per executed iteration and the same
  maximum-work policy, not equal realized work.
- One Julia thread and one BLAS thread.

Before timing, frame 1 executes one untimed full and one untimed tied warm-up.
Full runs first on odd frame indices and tied runs first on even frame indices.
Kernel timing includes the exact-SP calculation, `Qstar`, `qbar`, `delta`,
retained `Q`, `U`, hard decisions, and syndrome calculation.  It excludes
trace hashing, serialization, input generation, and native validation.
Allocated bytes use this same trace-free kernel boundary.  Replay covers
scientific states, categorical work, hashes, and gates, but not runtime or
allocated bytes.

The anchor uses frames `1:24`, whose noise seeds are `20261012 + frame` and
whose received-sample and clipped-LLR hashes must reproduce the retained AWGN
reference.  The held-out set is fixed before the anchor at frames
`10001:10200`.  Its input identities are frozen, but no held-out decoder is run
until the anchor expansion gate passes and the next approved action is
triggered.

## Required pre-run gates

1. Relevant JadeJcade source files, its project environment, HEAD, loaded
   package path, graph, Julia version, and thread counts match `config.toml`.
2. The input-freeze command writes all anchor and held-out received-sample,
   raw-LLR, clipped-LLR, channel-statistic, noise, transmitted-word, and symbol
   hashes before science.  Anchor `received_sha256` and clipped-LLR hashes
   reproduce the retained reference; its two receiver rows must agree for each
   frame.  The retained table does not certify the new raw-LLR, word, symbol,
   channel-statistic, or noise hashes, which are frozen by this experiment.
3. The frozen manifest hashes the experiment card, configuration, runner,
   tests, Jade source files, and the input table.  The anchor refuses any later
   source change.
4. Exact check-to-variable values agree with independent even-parity local
   configuration enumeration for degrees 2 through 6.
5. The local full mode reproduces JadeJcade's native exact-SP posterior values
   bit for bit, hard-decision estimate, syndrome, validity, and stopping
   iteration.
6. A shadow arm that computes diagnostics but selects `Qstar` reproduces the
   full arm exactly.
7. Reconstructing `Qstar` from `qbar + delta` remains within the registered
   floating-point tolerance and preserves the hard-decision estimate,
   syndrome, validity, and stopping iteration.
8. The iteration-1 check replies, posterior values, hard-decision estimate,
   syndrome, `Qstar`, `qbar`, and `delta` are identical between full and tied
   arms.  A nonzero `delta` must change only the retained `Q` used by check
   iteration 2.
9. A degree-one negative control gives zero `delta` and identical full/tied
   trajectories.
10. Check-order and local-edge relabeling preserve the decoded result after
    canonical reindexing.
11. An independent syndrome calculation agrees at every recorded iteration.
12. Every output directory is new, every retained artifact is checksummed, and
    an independent replay reproduces the scientific trace.

## Anchor expansion gate

The 200-frame held-out confirmation is permitted only when all correctness and
provenance gates pass, native/full equivalence holds on all 24 frames, the full
arm recovers 24 of 24 transmitted syndrome-zero words, and at least one paired
endpoint is discordant with the net direction favoring the full arm.  An
endpoint is either parity validity or equality to the transmitted word.

If the anchor fails, its artifacts remain retained.  No SNR point, weighted
mean, iteration budget, stopping rule, or frame set may be changed under this
attempt ID.

## Registered outcomes and work

For each arm and frame retain parity validity, transmitted-word equality,
wrong-valid-word status, coded-bit errors, syndrome weight, stopping iteration,
posterior and hard-word hashes, and per-iteration `Q`, `U`, `Qstar`, `qbar`,
`delta`, posterior, and hard-decision hashes.  Retain full-precision compressed
state snapshots for anchor frame 1 at iterations 1, 2, and the terminal state.

Work categories are reported separately: check updates, outgoing check
messages, tanh evaluations, multiplications, atanh evaluations, input clamps,
variable-edge additions and subtractions, per-bit mean reductions and
divisions, state assignments, hard comparisons, and syndrome XORs.  Runtime,
allocated bytes, physical state bytes, and logical state counts are separate
diagnostics.  No heterogeneous work categories are collapsed into one scalar.

## Held-out inference, frozen but not yet executed

The anchor is never pooled into held-out inference.  The held-out report uses
paired `2x2` counts for transmitted-word equality and parity validity,
two-sided exact McNemar tests with Holm correction, and 97.5% intervals from
Newcombe's score/Wilson method 10 for paired proportions, including its
continuity-corrected correlation estimate, for the full-minus-tied risk
difference.  The 97.5% level is the registered two-endpoint interval
multiplicity rule; Holm applies separately to the p-values.  For an endpoint,
a directional retention claim requires a positive difference, the 97.5%
interval lower bound above zero, and the Holm-adjusted exact McNemar p-value
below 0.05.  A reversed effect falsifies the registered direction even if it
is nonzero.

The retained state snapshot is UTF-8 CSV.  Every floating value is written in
17-digit decimal and as its exact `0x`-prefixed IEEE-754 `UInt64` bit pattern,
then compressed deterministically by GNU gzip 1.10 with `-n` (no timestamp or
original filename).  `Base.summarysize` is reported only as a heap-reachability
estimate for the identical physically allocated state tuples; it is neither
peak memory nor measured allocation.

## Claim boundary

A passing held-out result would establish only that discarding the declared
recipient-specific variable-to-check component changed recovery within this
locked exact-SP recurrence.  The tied arm still uses the exact BP check
calculation and edge-specific check-to-variable messages.  Native projected GD
also differs in representation, parity calculation, objective, update,
projection, initialization, and stopping, so the larger attribution remains
open.
