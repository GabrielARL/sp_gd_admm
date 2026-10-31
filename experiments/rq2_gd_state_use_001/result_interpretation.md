# `RQ2-GD-STATE-USE-001` terminal result

## Eligibility and provenance

The eligible terminal record is
`results/2026-10-31_heldout_v2`. It has `status = complete_valid`, all 15
registered correctness gates pass, and its two complete scientific passes
produce the same SHA-256:

```text
d4ba7a7a131e854e24399c3cc154bd891b16654a1b4834d1993838cf2d18601b
```

All 39 files named by the result checksum manifest verify. The held-out result
contains 200 paired cases, 400 arm-level frame records, and 12,000 accepted
update records. It uses the source and input freeze in
`freeze/2026-10-31_v2` and the expansion-authorizing development result in
`results/2026-10-31_anchor_v2`.

The main held-out artifact hashes are:

```text
completion record  3099cce2f59f1a964031cf3ce329d1b39d0324224e8321827cf36d8c4ebbdda0
science file       2ae5f7f636edbf6753529213993b7301535b23d916f465a3b7e1bf7ee9075a64
aggregate table    93b8cfc089e93a426720bad3d0713b0d27cf17e3015c799694976b3b21be5ad9
result manifest    b3361fb5ff5d865ec86a51a8c89cb46a9ff8ffbe2babde2f639ba2aa74582428
checksum manifest  07b11ca649f544f5c07bfffaa4a97050709756236aa900cec6f983f38ea1e463
```

## Controlled question

Both arms use the same native projected-gradient scalar backbone. After each
accepted update, both arms calculate and retain the same type of bounded,
mean-zero check-specific offset for every Tanner-graph edge. The control
does not use those offsets in the next update: it evaluates the unshifted
parity objective and projects each scalar into `[-1,1]`. The active arm uses
the offsets in both the shifted parity objective, through readings
`x_i + delta_(c,i)`, and the induced scalar feasibility interval that keeps
all such readings in `[-1,1]`. The graph, received samples, channel LLRs,
initialization, objective weights, preconditioner, backtracking procedure,
componentwise projection procedure, 30-update budget, and hard-decision rule
are fixed pairwise; the objective inputs and resulting projection bounds are
the registered treatment.

This tests subsequent use of equally retained offsets through both the parity
objective and its induced scalar feasibility interval. It does not separately
isolate retention, parity-objective use, or projection. The offsets are not BP
messages, and neither arm calls BP, normalized min-sum, a pseudogradient, a
word list, or an oracle.

## Development anchor

The 24-case v2 development anchor is `complete_valid`, passes deterministic
replay, and is scientifically byte-identical to the v1 anchor. For both
transmitted-word equality and parity validity, active/control successes were
19/11, with 8 active-only, 0 control-only, 11 both, and 5 neither. The anchor
authorized the already frozen confirmation set. It is not pooled with the
held-out result.

## Held-out result

| Endpoint | Active successes | Control successes | Active only | Control only | Active minus control | 97.5% Newcombe interval | Exact McNemar p | Holm-adjusted p |
|---|---:|---:|---:|---:|---:|---|---:|---:|
| Transmitted-word equality | 172/200 | 113/200 | 59 | 0 | 0.295 | [0.2206105421, 0.3667643089] | 3.469446952e-18 | 6.938893904e-18 |
| Parity validity | 172/200 | 113/200 | 59 | 0 | 0.295 | [0.2206105421, 0.3667643089] | 3.469446952e-18 | 6.938893904e-18 |

Information-word equality is a supporting endpoint: active/control successes
were 183/143, with 40 active-only, 0 control-only, 143 both, and 17 neither.
Neither arm produced a wrong valid word on these cases.

## Mechanism timing and diagnostics

The treatment becomes visible at the registered boundary:

- Through update 1, all 200 pairs have identical scalar state, partial
  derivative vector, accepted scalar update, and retained offsets.
- At update 2, both arms enter with the same scalar state and the same retained
  offsets. The control does not use the offsets; the active arm uses them in
  both its parity objective and its induced scalar feasibility interval. All
  200 partial-derivative vectors and accepted scalar updates then differ.
- From update 3 onward, both the scalar states and the refreshed offsets have
  diverged in all 200 pairs.

Every arm-level run accepts all 30 requested updates. All registered box,
mean-preservation, finite-difference, independent-syndrome, source, replay,
and structural-zero-call checks pass. Mean terminal coded-bit errors are 0.22
for active and 0.73 for control; mean information-bit errors are 0.10 and
0.365, respectively.

Both arms retain 40,800 persistent `Float64` values: 10,200 scalar values and
30,600 check-specific offsets. This is a 326,400-byte persistent-state
footprint in each arm, not total process memory. In the retained implementation,
median timed execution is 5.543 seconds for active and 0.582 seconds for
control; median allocation within the timed solver boundary is about 2.752 GB
and 229 MB. These are implementation-specific work measurements for this
constructed intervention, not an asymptotic-complexity result or an optimized
decoder comparison. The timed boundary excludes input generation, validation,
hashing, and serialization.

## Causal interpretation

This is valid favorable held-out evidence. Under the locked graph, 6 dB AWGN
cases, initialization, and 30-update budget, using the constructed retained
check-specific distinction in the next optimization update improves
transmitted-word recovery and parity validity relative to calculating and
retaining the same distinction but not using it. In the active arm, that use
jointly changes the parity objective and the induced scalar feasibility
interval.

The result rules out graph traversal alone as a sufficient explanation for
this controlled difference. The two arms traverse the same Tanner graph and
retain the same number and shape of persistent values. What changes is whether
the next optimization update can use the check-specific distinction through
the parity objective and its induced projection bounds; that changes the
partial derivatives of the objective function, the accepted scalar trajectory,
and ultimately the hard-decision outcome.

This narrows the BP-versus-projected-GD research question but does not close
native attribution. It does not show that these offsets are BP messages,
reproduce BP, isolate storage alone, or uniquely explain the complete native
BP-versus-projected-GD performance gap. It also does not separate the effect of
the shifted parity objective from the effect of its induced projection bounds.
The active arm is a constructed projected-gradient variant whose offsets are
refreshed after accepted updates; it is not descent on one fixed objective.

## Superseded and failed attempts

- Before freeze, original anchor frame 1 was quarantined after an independent
  validator accidentally ran three active updates and observed an intermediate
  coded-error count. The anchor was mechanically shifted to frames 2:25; the
  confirmation frames were not exposed.
- The v1 held-out command completed its first in-memory calculation but failed
  while attaching the nested Newcombe inference object. No held-out output
  directory or eligible endpoint record was written. The v2 repair changed
  only the result-container type and added direct inference-assembly tests.
- The first v2 service attempt was terminated by signal 15 when its process was
  tied to a tool-session lifetime. It wrote no held-out result. The eligible
  run used the same immutable v2 freeze and valid anchor in a detached user
  service and completed without changing the scientific protocol.

## Next registered branch

Stop and retain this construction; do not tune its SNR, objective weights,
offset construction, projection, step, update budget, cases, or stopping rule
under this experiment ID. The next native-attribution experiment should hold
one representation fixed while changing one calculation or update operator at
a time. The first split should separate offset use in the parity objective from
offset use in the scalar feasibility interval. Its broader purpose is to
determine how much of the native BP-versus-projected-GD gap is attributable to
using a check-specific distinction, rather than to the BP check calculation,
the projected-GD objective, or the scalar update operator.
