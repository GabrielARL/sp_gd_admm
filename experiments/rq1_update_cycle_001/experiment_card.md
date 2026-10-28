# `RQ1-UPDATE-CYCLE-001` frozen experiment card

Status before execution: **approved and frozen** on 2026-10-28.

## Research question and role

This is the separately retained second-graph confirmation for RQ1. It asks
whether the state factor, update-operator factor, and their interaction found
on the three-bit tree remain nonzero after transferring the controlled bench
to a four-bit cycle.

It is a controlled BP-residual gradient experiment. It is not native projected
GD, an error-rate experiment, or evidence that one decoder is generally better.

## Controlled factors

The `2 x 2` bench crosses:

1. `full`, which supplies a different variable-to-check value to each
   neighboring check, versus `qbar_tied`, which supplies their average to both
   neighboring checks; and
2. `direct`, which assigns `F_s(u)`, versus `true_residual_gradient`, which
   takes one gradient step on
   `R_s(u)=0.5||u-F_s(u)||_2^2` using
   `(I-J_s)^T(u-F_s(u))`.

Both state variants retain the same eight check-to-variable coordinates. The
variable-to-check values and their averages are temporary values within an
update. The gradient cells compute partial derivatives of the stated objective
function; they are not described as message passing.

## Frozen graph, evidence, and coordinate order

The parity-check matrix is

```text
H = [[1, 1, 0, 0],
     [0, 1, 1, 0],
     [0, 0, 1, 1],
     [1, 0, 0, 1]].
```

The fourth row is linearly dependent over GF(2), and all four checks have
degree two. The check-to-variable state uses the bit-major order already used
for this cycle by `RQ1-STATE-002`:

```text
(b0-c0, b0-c3, b1-c0, b1-c1,
 b2-c1, b2-c2, b3-c2, b3-c3).
```

The channel LLR is

```text
L_i = ln(P(b_i=1|y_i) / P(b_i=0|y_i)),
L = (-ln(9), ln(3/2), ln(2), ln(3)).
```

A nonnegative a-posteriori LLR gives hard-decision bit 1; a negative value
gives bit 0. The syndrome is `(H b-hat) mod 2` over GF(2). A hard-decision
estimate is called a codeword only when all four syndrome entries are zero.

All four cells start at `u1=F_full(0)`, use a flooding update from that frozen
state, perform exactly one update, and have no early stopping, projection, or
clipping.

## Transferred step size

The step size is transferred without inspection or cycle-specific retuning:

```text
alpha = (3 - sqrt(5)) / 2.
```

It was selected for `RQ1-UPDATE-001`. This confirmation does not claim that it
is the reciprocal of the largest eigenvalue on the cycle. The executable run
must retain the cycle-specific spectrum and state whether the transferred step
lies in the interval `0 < alpha < 2/lambda_max` for each state map.

## Preregistered prediction

Before executing the four cells, the following vector predictions are frozen:

- the state contrast is nonzero;
- the update-operator contrast is nonzero; and
- the difference-in-differences is nonzero.

No hard-decision estimate, syndrome, parity-validity outcome, or relative
objective decrease is predicted. Those quantities will be calculated only
after this card and `config.json` are frozen.

The contrast orientation is

```text
state = 0.5 * [(tied-direct - full-direct)
             + (tied-gradient - full-gradient)]

update = 0.5 * [(full-gradient - full-direct)
              + (tied-gradient - tied-direct)]

interaction = (tied-gradient - tied-direct)
            - (full-gradient - full-direct).
```

## Fixed-point validation

The cycle can make `I-J_s` singular. The run must therefore determine the
rank, consistency, and nullity of each affine fixed-point system rather than
assuming a unique solution. For every consistent system it must retain one
particular solution and a basis for the nullspace, then verify both

```text
(I-J_s)u = c_s
```

and

```text
(I-J_s)n = 0
```

for every retained nullspace vector `n`. This establishes the relation between
zeros of `R_s` and fixed points of `F_s` for this graph.

## Correctness gates

The run is interpretable only if all gates pass:

1. the matrix, bit-major edge order, channel LLRs, bit-1-positive convention,
   starting state, one-update budget, and transferred `alpha` match the frozen
   configuration;
2. each executable map agrees with an independently constructed affine form;
3. analytic Jacobians agree with central finite differences;
4. analytic gradients agree with central finite differences;
5. the rank, consistency, particular solution, and nullspace basis of each
   fixed-point system pass the declared tolerances;
6. the complete sign transform
   `ell=-L, q0=-q1, u0=-u1, x0=-x1` preserves every cell's hard-decision
   estimate and syndrome;
7. the degree-two check calculation agrees with independent enumeration of
   its valid local binary assignments;
8. hard-decision estimates and syndromes recompute from retained post-update
   states;
9. the three preregistered vector contrasts exceed the frozen nonzero
   tolerance; and
10. two executions of the pure scientific calculation have identical
    canonical SHA-256 digests.

Any failed gate produces a retained invalid pilot and no confirmation claim.

## Retained diagnostics and work accounting

Retain the before and after states, variable-to-check values, averages, map
outputs, residuals, analytic Jacobians and gradients, objective values,
a-posteriori LLRs, hard-decision estimates, syndromes, fixed-point-system
diagnostics, spectra, sign-transform checks, local parity-enumeration checks,
factorial contrasts, first divergences, primitive-operation categories,
persistent and temporary value counts, hashes, exact command, runtime, and Git
identity and status.

Algorithm-core categories remain separate: variable-node additions,
recipient-average additions and scalings, degree-two check transfers, residual
subtractions, nonzero Jacobian-transpose products and accumulations, step-size
multiplications, and assignments or state-update subtractions. Finite
differences, rank calculations, local enumeration, hard decisions, syndromes,
hashing, and serialization are diagnostic work. No weighted scalar operation
count or runtime-equivalence claim is made.

## Interpretation boundary

Passing this confirmation shows only that the declared state factor,
update-operator factor, and interaction produce nonzero one-update trajectory
contrasts on this four-bit cycle as well as on the earlier three-bit tree. A
valid hard-decision estimate is not evidence of transmitted-word recovery
because no transmitted word is registered. The native BP-versus-projected-GD
performance question remains outside this experiment.
