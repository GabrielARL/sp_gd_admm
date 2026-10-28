# `RQ1-UPDATE-001` experiment card

Status before execution: **approved and frozen** on 2026-10-28.

## Research question

**RQ1 — mechanism identification.** On the declared three-bit, two-check
graph, does the next trajectory depend on (i) retaining recipient-specific
variable-to-check values, (ii) applying the declared map directly rather than
taking a true gradient step on its declared objective function, or (iii) an interaction
between these two factors?

This is a controlled BP-residual gradient experiment. It is **not** the
repository's native projected-GD decoder, and it cannot by itself explain a
native BP-versus-projected-GD performance difference.

## Mechanism being isolated

The experiment crosses two factors:

1. **Variable-to-check calculation**
   - `full`: each outgoing value excludes the message from its recipient;
   - `qbar_tied`: the recipient-specific outgoing values of a bit are averaged,
     and that average is supplied to each neighboring check.
2. **Update operator**
   - `direct`: assign the next state as `F_s(u)`;
   - `true_residual_gradient`: take one gradient step on
     `R_s(u) = 0.5 ||u - F_s(u)||_2^2`.

Here `s` is either `full` or `qbar_tied`. Both variants retain the same four
check-to-variable coordinates `u`. Variable-to-check values are recomputed
inside the map and are not counted as values retained between iterations.

For each state map, the required gradient is

```text
grad R_s(u) = (I - J_s)^T (u - F_s(u)).
```

Treating `F_s(u)` as a constant while differentiating would be a relaxation or
damping update; it is not the gradient tested here.

## Method fingerprints

| Feature | Full/direct | Tied/direct | Full/gradient | Tied/gradient |
|---|---|---|---|---|
| Persistent dynamic state | four check-to-variable values | four check-to-variable values | four check-to-variable values | four check-to-variable values |
| Channel evidence | all three declared LLRs enter every map evaluation | same | same | same |
| Check operation | degree-two BP check operation | same | same | same |
| Variable operation | recipient exclusion | recipient average | recipient exclusion | recipient average |
| Update | direct map | direct map | true gradient step on `R_full` | true gradient step on `R_qbar_tied` |
| Schedule | one flooding update from frozen `u1` | same | same | same |
| Projection or clipping | none | none | none | none |
| Work budget | one update, no early stop | same | same | same |

The direct cells are message-passing updates. The gradient cells compute
partial derivatives of the declared objective function and take a gradient
step; they are not described as message passing.

## Protocol fingerprint

The parity-check matrix is

```text
H = [[1, 1, 0],
     [0, 1, 1]].
```

The check-to-variable state uses the stable edge order

```text
(b0-c0, b1-c0, b1-c1, b2-c1).
```

The channel LLR is defined as

```text
L_i = ln(P(b_i=1|y_i) / P(b_i=0|y_i)),
```

and the vector is

```text
L = (-ln(9), ln(3/2), ln(2)).
```

A positive LLR favors bit 1. The hard-decision estimate is 1 when its
a-posteriori LLR is nonnegative and 0 otherwise. A codeword is reported only
when the hard-decision estimate has zero syndrome over GF(2).

All four cells start from

```text
u1 = F_full(0),
```

the check-to-variable state after one full BP message-passing iteration from
zero check-to-variable messages. Every cell receives the same numerical `u1`,
the same `H`, the same `L`, the same edge order, and a one-update budget.

The gradient step size is frozen as

```text
alpha = (3 - sqrt(5)) / 2.
```

This is the reciprocal of the maximum eigenvalue of
`(I-J_s)^T(I-J_s)` for both state maps. The equality of the two maximum
eigenvalues is a correctness gate, not an assumption left unchecked.

## Closest retained experiment

`RQ1-STATE-002` changes only the recipient-specific component in a direct BP
message-passing update. This experiment adds the orthogonal update-operator
factor on its approved nonzero-sum calibration case. It does **not** repeat the
rejected full-scale `R3-EDGE-FIXEDPOINT-001` experiment: this bench uses one
three-bit anchor, an explicit affine map, an analytic Jacobian, a fixed
one-update budget, and no parameter sweep.

## Only causal differences

Within a row of the `2 x 2` bench, only the recipient-specific calculation is
changed. Within a column, only direct assignment versus the declared true
gradient step is changed. The graph, LLR vector, numerical starting state,
coordinates, check operation, flooding schedule, hard-decision rule, syndrome
test, and one-update budget remain fixed.

The two state maps necessarily have different fixed-point equations; that
difference is the operational state-factor intervention. Each residual
objective is tied explicitly to its own map, and its zero set must equal that
map's fixed points.

## Counterfactual prediction

The full and tied maps have different Jacobians. Therefore:

- both update rows should record a state-factor divergence;
- direct assignment and a single gradient step should record an
  update-operator divergence;
- the difference-in-differences need not be zero, because the gradient
  contains the state-map Jacobian; and
- each direct cell should reach its corresponding affine-map fixed point in
  this one-update anchor, whereas a one-step gradient cell need not.

The first coordinate checked for divergence is `b0-c0`, following the frozen
edge order. Failure of any derivative, spectrum, fixed-point, or deterministic
replay gate invalidates interpretation of the four cell outputs.

## Anchor case and stopping rule

There is one anchor case and no sweep. Each cell performs exactly one update.
There is no early stopping and no post-inspection step-size change.

## Correctness gates

The retained run must pass all of the following:

1. the configured decimal LLRs reproduce `(-ln(9), ln(3/2), ln(2))`;
2. `u1` is recomputed as `F_full(0)`;
3. each executable map agrees with its affine `J_s u + c_s` form;
4. each analytic Jacobian agrees with central finite differences;
5. each analytic objective gradient agrees with central finite differences;
6. the largest eigenvalue is `(3 + sqrt(5))/2` for both state maps and
   `alpha` is its reciprocal;
7. `R_s(u)=0` at the solved fixed point of `F_s`, and every entry of
   `u-F_s(u)` is below the frozen tolerance;
8. every hard-decision estimate and syndrome is recomputed from the stored
   post-update state; and
9. the complete equivalent-convention transform
   `ell=-L, q0=-q1, u0=-u1, x0=-x1` negates every soft quantity while
   preserving each hard-decision estimate and syndrome; and
10. two independent executions of the pure scientific calculation have the
   same canonical SHA-256 digest.

## Retained diagnostics

For every cell, retain the before and after state, variable-to-check values,
recipient averages, map output, residuals, Jacobian, objective values,
analytic gradients, update displacement, a-posteriori LLRs, hard-decision
estimate, syndrome, validity flag, primitive-operation categories, and counts
of persistent and temporary values. Also retain vector factorial contrasts,
the first divergence for every row and column, source/configuration/output
hashes, Git identity and status, runtime identity, the exact command, and the
complete validation log.

The factorial contrasts use the declared orientation

```text
state effect  = 0.5 * [(tied-direct - full-direct)
                     + (tied-gradient - full-gradient)]
update effect = 0.5 * [(full-gradient - full-direct)
                     + (tied-gradient - tied-direct)]
interaction   = (tied-gradient - tied-direct)
              - (full-gradient - full-direct).
```

Hard decisions and syndromes are listed cell by cell; they are not averaged.

## Work accounting

Algorithm-core counts remain in heterogeneous categories:

- variable-node additions;
- recipient-average additions and scalings;
- degree-two check transfers;
- residual subtractions;
- nonzero Jacobian-transpose products and accumulations;
- step-size multiplications; and
- state-update subtractions or assignments.

Finite-difference evaluations, fixed-point validation, hashing, syndrome
calculation, serialization, and rendering are diagnostic work and are excluded
from algorithm-core counts. No weighted scalar operation count or runtime
equivalence is claimed.

## Interpretation boundary

This toy-graph experiment can identify a reproducible state effect, update
effect, interaction, valid null result, or invalid run for the declared anchor.
It supplies no bit-error-rate, frame-error-rate, convergence, or code-ensemble
performance evidence. It also does not test native projected GD.
