# Terminal result: bounded edge-copy equality relaxation

Experiment ID: `RQ2-BOUNDED-EDGE-FREEDOM-001`

Status: **complete-valid**. The immutable v1 queue completed at 21:20 CST on
3 November 2026. No scientific process remains active.

## Controlled intervention

Both arms used the same bounded compound objective, edge box, metric,
preconditioner, update-1 initialization, assigned frozen offsets,
strict-decrease line search, mean readout, graph, channel log-likelihood ratios,
cases, and 30-update budget. The equality-relaxed arm changed one operation:
it removed the constraint that the three edge optimization variables attached
to each coded bit remain equal.

These edge quantities are optimization variables, not belief-propagation (BP)
variable-to-check or check-to-variable messages.

## Validation

- The frozen test suite passed 121/121 assertions.
- The equality-constrained implementation reproduced the retained
  `compound__box` lower endpoint exactly on all 24 compatibility frames.
- Treatment-boundary, finite-difference, projection, finite-value, box,
  strict-decrease, and deterministic-replay gates passed.
- Every arm completed 30 accepted updates on every fresh case.
- The anchor and confirmatory-transfer result manifests verify completely.

## Recovery result

The registered contrast is equality-relaxed minus equality-constrained.

| Cases | Equality constrained | Equality relaxed | Relaxed only | Constrained only |
|---|---:|---:|---:|---:|
| Anchor, 24 frames | 22/24 | 0/24 | 0 | 22 |
| Confirmatory transfer, 200 frames | 164/200 | 0/200 | 0 | 164 |

On the confirmatory transfer, the transmitted-word-recovery risk difference
was -0.82. Its two-sided 95% Newcombe method-10 interval was
`[-0.8670537414, -0.7579540490]`, and the exact two-sided McNemar p-value was
`8.5528470723e-50`. Parity validity gave the same counts and is a descriptive
confirmatory result, not a second causal decision gate.

## What changed inside the relaxed arm

The equality-relaxed arm remained finite, stayed inside the registered box,
and strictly decreased the declared objective. Nevertheless, it formed
check-local edge values that did not describe one coherent hard-decision
estimate:

- its maximum within-bit edge spread was 2.0 on all 200 transfer cases;
- it had 86--175 edge signs per case that disagreed with the sign of the mean
  readout;
- its check-local residual RMS ranged from 0.0364 to 0.0674, whereas the
  residual RMS after replacing each edge value by its bit mean ranged from
  0.1813 to 0.2651; and
- 34--107 checks per case changed hard-parity status when evaluated from the
  coherent mean readout instead of their private edge values.

The relaxed arm reached a lower objective and more coded-bit errors than the
constrained arm on every one of the 200 transfer cases. Its mean objective was
`-3.98456` versus `-3.98139`, while its mean coded-bit errors were 28.17 versus
0.25. Objective decrease therefore did not imply recovery of the transmitted
word in this construction.

## Causal conclusion and boundary

Removing edge-copy equality alone causally reduced recovery under this bounded
compound objective, metric, initialization, frozen-offset construction,
mean readout, graph, channel, and 30-update budget. The result rules out the
hypothesis that independently evolving check-specific optimization variables
are, by themselves, the missing ingredient that makes BP outperform native
projected gradient descent.

It does not show that recipient-specific BP messages are harmful. BP retains
directed messages and applies its variable-node and check-node calculations;
the relaxed arm instead performs gradient steps on the declared compound
objective. The result neither establishes BP equivalence nor decomposes the
complete native BP-versus-projected-GD performance gap.

## Provenance

- Anchor scientific hash:
  `3756ba02fe8470190bb02854d75a4f7f6777eed8ef42f0206eeea4bcbb9f4cc4`.
- Transfer scientific hash:
  `0d744c3e4cee906392c81d6bb6d418f2b715ea7a0a8ba7d5f278c1930fba7dc9`.
- Queue log SHA-256:
  `aa4d95ae8fd82d8f7faabeaf4e8a6370849cf7a9c324f3dbb8a7d6193b000daf`.
- Anchor result-manifest SHA-256:
  `514c1acf98af8ef1b8f2cfafd4531bd25332f447f22f0adcd28feb1e93fdee58`.
- Transfer result-manifest SHA-256:
  `b9bee43af509e508579a70d7b4376c6d31caeae44e24ce3ba69732e30eafce97`.

