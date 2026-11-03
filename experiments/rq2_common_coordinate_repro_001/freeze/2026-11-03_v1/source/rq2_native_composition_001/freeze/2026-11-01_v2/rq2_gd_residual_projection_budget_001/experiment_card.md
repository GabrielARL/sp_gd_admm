# `RQ2-GD-RESIDUAL-PROJECTION-BUDGET-001`

Status: **registered implementation block; no result is claimed until the
calibration gate and deterministic replay pass.**

This identifier is an internal experiment ID, not a receiver name. This block
operationalizes the objective-and-projection portion of the amended causal
ladder. It supersedes only the `compound` and `check_rule` cells proposed in
the design-only `RQ2-GD-CHECKRULE-001` card. It does not implement that card's
confounded LLR-domain or variable-rule cells.

## Research question

Among cases not recovered by the retained constructed projected-GD variant,
does recovery change when we remove either:

1. the parity residual multiplier from the check-associated partial
   derivatives of the objective function; or
2. the projection of the persistent scalar state onto `[-1,1]`?

A longer update budget is scored from the same trajectories. It is an
explicitly reopened budget control, not a new mechanism and not a generic
step-size sweep.

## Mechanism being isolated

All four arms begin with the exact same update 1 from the retained
`asbuilt__frozen` construction. That update produces one scalar `x_i` for each
bit and one constructed offset `delta_(c,i)` for each graph edge. The offsets
are then frozen for the remaining update attempts.

For check `c`, define

```text
r_(c,j) = x_j + delta_(c,j),
P_c     = product over j in c of r_(c,j).
```

The compound parity term is

```text
F_compound,parity = (mu_p / n) sum_c (1 - P_c)^2.
```

Its check-associated partial derivative contains the parity residual
`(1-P_c)` times the leave-one-out product. The product-only parity term is the
explicit objective

```text
F_product,parity = -(2 mu_p / n) sum_c P_c.
```

Its check-associated partial derivative is the same scaled leave-one-out
product without the residual multiplier. The channel and binary terms, frozen
offset state, diagonal preconditioner, initial step, strict-decrease
backtracking rule, hard-decision rule, and syndrome calculation are unchanged.

This is still gradient descent on a declared objective. The product-only arm
is not BP and its check-associated partial derivatives are not messages.

## Atomic 2-by-2 block

| Arm | Parity term | Trial-state operator from update 2 onward |
|---|---|---|
| `compound__box` | squared parity residual | project each scalar onto `[-1,1]` |
| `product_only__box` | negative check product | project each scalar onto `[-1,1]` |
| `compound__unconstrained` | squared parity residual | no projection |
| `product_only__unconstrained` | negative check product | no projection |

Update 1 is common and boxed in every arm. Therefore the first possible
factorial divergence is update 2. The common update also fixes the exact
constructed offsets before either intervention begins.

## Protocol fingerprint

- Regular `(3,6)` LDPC graph with `n=10200`, `k=5100`, and graph seed
  `169616412`.
- Known-unit-gain complex AWGN at 6 dB with the retained noise-seed rule.
- All-zero transmitted word; positive LLRs favor coded bit zero; clipped LLRs
  are initialized as `x_i^(0)=tanh(ell_i/2)`.
- Parity weight 2, binary weight 0.2, initial step 0.2, at most 16 halvings,
  and the retained diagonal preconditioner.
- Ninety update attempts or the first line-search stall. There is no syndrome
  early stop. Outcomes are scored after update attempts 30 and 90, and the
  first update at which parity validity or transmitted-word equality occurs is
  retained as a diagnostic.
- No step-size, weight, SNR, or iteration sweep is allowed.

The ordered stages are:

1. calibration frames `20001:20024`, which must reproduce the retained v4
   `asbuilt__frozen` endpoint for `compound__box` at update 30;
2. fresh correctness anchor frames `50001:50024`;
3. fresh transfer frames `50025:50224`; and
4. locked attribution frames `30001:30200`, used only to map transitions among
   the already-known native gap cases.

## Only causal differences

Within each parity level, the only registered change is box projection versus
no projection from update 2 onward. Within each projection level, the only
registered change is the compound parity term versus the product-only parity
term. Update 30 versus update 90 is a readout from one trajectory; it does not
launch a separately tuned decoder.

## Counterfactual predictions

- If the residual multiplier is responsible for some remaining failures, a
  product-only arm changes transmitted-word recovery while its corresponding
  projection rule is held fixed.
- If projection is responsible, the unconstrained arm changes recovery while
  its parity term is held fixed.
- If the factorial interaction is material, neither factor receives a unique
  additive case count; the conclusion must remain path-conditional.
- If outcomes change only between updates 30 and 90, the registered evidence
  supports a budget effect, not a newly identified representation or
  check-calculation mechanism.

## Correctness gates

1. The included retained v4 runner and v4 configuration match their registered
   SHA-256 values. The v4 anchor frames, completion record, and checksum
   manifest are copied from the retained v4 result into the attempt freeze,
   hash-pinned there, and read only from that frozen copy during execution.
2. Every arm uses exactly the same update-1 scalar state and frozen offset
   state.
3. `compound__box` at update 30 matches the retained `asbuilt__frozen`
   calibration row exactly in scalar-state hash, frozen-offset hash,
   hard-decision hash, coded-bit errors, syndrome weight, parity validity, and
   transmitted-word equality.
4. Analytic partial derivatives pass independent five-point finite differences
   for both objectives on toy tests and at registered scientific updates 2,
   30, and 90 whenever those updates are reached.
5. Every accepted line-search trial strictly decreases that arm's declared
   fixed-offset objective.
6. Independent hard decisions and syndromes agree with the implementation.
7. Primary and replay passes have the same canonical scientific hash.
8. Every stage regenerates three endpoint sentinels on the same frames: native
   projected GD at 30 updates, the v4 assigned/frozen variant at 30 updates,
   and native exact sum-product BP with its 80-message-passing-iteration cap.
   Their counts and canonical hard-decision-table hash are retained. Fresh
   stage outcomes are not expansion gates. On the locked attribution cases,
   the registered transmitted-word and parity-valid counts are respectively
   `107`, `167`, and `200` for native GD, v4, and BP.

The result wrapper follows the umbrella `RQ2-CAUSAL-FACTORS-001` campaign
contract. `endpoint_gate.toml` contains only the Block A identity, frame/input
digests, three success counts, three hard-word digests, and replay-sentinel
fields required by that controller. `COMPLETED.toml` binds the science and
endpoint files to the equal primary/replay scientific hashes. The checksum
manifest covers all immutable result artifacts, including the primary
checkpoint and timing record, while excluding only `MANIFEST.sha256` and the
mutable `progress.toml` and `phase_log.tsv` telemetry files.

## Metrics and claim boundary

The primary metric is transmitted-word equality. Parity validity is a
confirmatory secondary metric; a parity-valid word can still be the wrong
transmitted word. Supporting metrics include coded-bit errors, syndrome
weight, first-valid update, first-exact update, accepted steps, line-search
trials, and finite-difference error.

A valid result concerns these four constructed gradient-descent arms on the
registered graph, AWGN cases, objectives, and budgets. It does not establish
that product-only gradient descent is BP, does not isolate recipient-specific
state or BP's direct update operator, and does not by itself give a unique
cause for every one of the 93 native-GD failures.
