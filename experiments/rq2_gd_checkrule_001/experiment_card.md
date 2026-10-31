# `RQ2-GD-CHECKRULE-001` design note: one native operation toward BP

Status: **design only; not implemented, not frozen, not to be run until the
decision rule below selects it.**

`RQ2-GD-CHECKRULE-001` is an internal experiment ID, not a receiver name.

## Decision rule

This experiment is built only if `RQ2-GD-OFFSET-NULL-001` returns a valid
held-out result in which `reference - permuted` is positive for both
confirmatory endpoints with Holm-adjusted p below 0.05 and `permuted` is
within its interval of `control`. That outcome means the retained offsets act
through their check assignment, which is the one property shared with BP's
extrinsic messages, and a rung toward BP can be built on them.

If `permuted` stays near `reference`, the retained construction is a
perturbation and this experiment is not built; the next rung starts instead
from a representation whose per-edge values are defined by an objective (the
Bethe free energy with per-edge beliefs), not from constructed offsets.

## Question

> Holding the per-edge readings `x_i + delta_(c,i)` fixed as the
> representation, what changes when the check-local operation that acts on
> those readings is replaced, one operation at a time, by BP's?

## Candidate ladder (one factor per arm)

The retained compound arm forms, for check `c` and bit `i`, the parity
gradient contribution

```text
g_(c,i) = -2 mu_p / n * (1 - prod_(j in c) r_(c,j)) * prod_(j in c, j != i) r_(c,j),
r_(c,j) = x_j + delta_(c,j).
```

Both factors already use the extrinsic product over `j != i`. BP's check
rule on the same readings, in the soft-bit domain, is the extrinsic product
alone. Three candidate arms, each changing one operation against the
retained compound arm:

| Arm | Check-local operation on the readings | Variable-side combination | Update |
|---|---|---|---|
| `compound` (retained) | parity residual times extrinsic product | sum of contributions, preconditioned step, projection | line search |
| `check_rule` | extrinsic product only (residual factor removed) | unchanged | unchanged |
| `check_rule_llr` | `2 atanh prod tanh(L_(c,j)/2)` on LLR-domain readings | unchanged | unchanged |
| `variable_rule` | unchanged | channel LLR plus incoming values, recipient excluded | unchanged |

Each arm's objective, if any, must be stated explicitly; an arm whose update
is no longer a descent direction on a declared objective is a fixed-point
iteration and must be labelled as such. The line search must be defined for
such an arm before it is run, or replaced by a fixed step registered in
advance.

## What this would and would not show

A valid result would state which single operation, on the fixed per-edge
representation, moves recovery toward BP's on the frozen cases. It would not
show that the ladder reaches BP, and it would not make the per-edge readings
BP messages.

## Preconditions before a card is frozen

1. `RQ2-GD-OFFSET-NULL-001` held-out result with the outcome named above.
2. `RQ2-NATIVE-GAP-001` six-dB and second-Es/N0 results, so that each rung
   can be placed between the native GD and native BP figures on the same
   cases.
3. An explicit objective or fixed-point statement for every arm, a
   finite-difference check for every arm with an objective, and the same
   gates as the null experiment.
