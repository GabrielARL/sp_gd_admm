# `RQ1-STATE-002` experiment card

Retained traces use schema `rq1-state-002/v2`. Each undirected edge slot has
separate variable-to-check and check-to-variable labels so the direction of a
BP message is explicit in every diagnostic.

## Scope

- **Research question:** RQ1 — mechanism identification.
- **Question:** Does replacing the different directed messages that one bit
  sends to its neighboring checks by their mean change the next sum-product
  trajectory?
- **Study type:** ablation study with one preregistered anchor, one calibration
  case, and one negative control.
- **Performance boundary:** this experiment identifies a trajectory mechanism.
  It does not establish bit-error rate, frame-error rate, convergence, or a
  BP-versus-GD performance ordering.

## Mechanism and intervention

After the standard variable-node update, let

```text
qbar_i       = average over checks a adjacent to i of Q*_(i->a)
delta_(i->a) = Q*_(i->a) - qbar_i .
```

The full branch sends `qbar_i + delta_(i->a)`.  The collapsed branch sends
`qbar_i` on every edge adjacent to bit `i`.  The check-node update, channel
LLRs, graph, sign convention, flooding schedule, initialization, number of
message-passing iterations, hard-decision rule, and syndrome calculation are
unchanged.

In the primary treatment, the change is applied only in message-passing
iteration 2.  All branches start from the same saved check-to-variable state.
The change is applied after the standard variable-node update and before the
check-node update.  Later iterations return to the standard variable-node
update.

A persistent collapse is retained as a separate diagnostic treatment.  It is
not substituted for the primary pulse.

## Branches

1. `full`: send the standard directed variable-to-check messages.
2. `qbar_collapse`: replace each bit's directed messages by their mean.
3. `delta_shadow_ignored`: retain each delta in the trace but send only the
   mean; this must equal `qbar_collapse`.
4. `qbar_delta_reconstruct`: reconstruct the standard directed messages from
   the mean and deltas; this must equal `full`.
5. `posterior_copy_diagnostic`: send the current a-posteriori LLR on every
   adjacent edge.  This changes more than the registered mechanism and is used
   only to check whether copying introduces self-feedback or also changes the
   mean.

Fractions record each binary64 value exactly only to verify that every group of
deltas sums to zero and that mean plus delta reconstructs the original binary64
message.  The check-node calculations use binary64 values in every branch.

## Method fingerprint

- **Propagated state:** one check-to-variable value per directed edge enters a
  message-passing iteration; one variable-to-check value per directed edge is
  formed before the check-node update.
- **Channel evidence:** `L_i = ln(P(b_i=1|y_i)/P(b_i=0|y_i))`; positive values
  favour bit 1.
- **Parity representation:** every row of the declared binary parity-check
  matrix imposes even parity.
- **Check-local operation:** the sum-product check-node update.  Degree-two
  checks use its exact identity `U_(a->i) = Q_(j->a)`; higher-degree checks use
  the equivalent tanh/atanh form.
- **Schedule:** flooding.
- **Initialization:** every check-to-variable message is zero.
- **Damping:** none.
- **Hard decision:** bit 1 when the a-posteriori LLR is nonnegative, otherwise
  bit 0.
- **Validity test:** `(H b_hat) mod 2`, independently checked by XOR.

Every branch uses the BP check-node update.  None of the control branches is
projected gradient descent.

## Protocol fingerprint

### Preregistered anchor: `symmetric_tree`

```text
H = [1 1 0; 0 1 1]
L = (-ln 9, ln(3/2), ln 9)
```

Prediction for iteration 2: the full branch sends `ln(13.5)` and `ln(1/6)`
from the shared bit to the two checks, while the collapsed branch sends
`ln(3/2)` on both edges.  The full branch is predicted to produce hard-decision
estimate `111` with syndrome `00`; the collapsed branch is predicted to produce
`011` with syndrome `10`.

### Calibration: `nonzero_sum_tree`

```text
H = [1 1 0; 0 1 1]
L = (-ln 9, ln(3/2), ln 2)
```

Prediction for the shared bit in iteration 2:

```text
Q*_(2->A) = ln 3
Q*_(2->B) = ln(1/6)
qbar_2    = -(ln 2)/2
B_2       = -ln 3
```

Thus the branch that sends the mean and the branch that copies the current
a-posteriori LLR are numerically distinct in this case.

### Negative controls

- Message-passing iteration 1, because all incoming check-to-variable messages
  are zero. The executable validation requires every iteration-1 delta to be
  exactly zero and the expanded per-bit mean to be bitwise identical to the
  standard variable-to-check vector.
- The retained six-bit, two-check graph, because every bit has degree one and
  therefore every delta is zero.
- `delta_shadow_ignored` must be identical to `qbar_collapse`.
- `qbar_delta_reconstruct` must be identical to `full`.
- Consistently reversing the check-row labels must preserve the trajectory for
  every bit and permute edge- and check-indexed values according to the same
  relabeling.
- Repeated execution with the retained configuration must reproduce the trace
  hashes, and replay succeeds only when every recomputed and recorded scientific
  validation flag is true.

### Structural witness

Two constructed variable-to-check vectors use the neutral edge-slot order
`(b0-c0, b1-c0, b1-c1, b2-c1)`, whose variable-to-check labels are
`(b0->c0, b1->c0, b1->c1, b2->c1)`:

```text
Q_left  = (0.75, 1.50, 0.50, -0.25)
Q_right = (0.75, 0.50, 1.50, -0.25)
```

They have the same per-bit means `(0.75, 1.00, -0.25)` but opposite deltas at
the shared bit. The next check-node update therefore differs on the
check-to-variable messages `c0->b0` and `c1->b2`. This is an explicit
structural check that the mean alone does not determine the next check outputs;
it is not a decoding-performance result.

### Separately configured cyclic confirmation

The confirmation graph is not part of the three primary controls and is not
used to tune them. Its retained JSON configuration is consumed directly by the
`--config` run path; scientific command-line overrides are rejected, and replay
checks that the file hash and effective fields agree:

```text
H = [1 1 0 0; 0 1 1 0; 0 0 1 1; 1 0 0 1]
L = (-ln 9, ln(3/2), ln 2, ln 3)
```

Every bit and check has degree two, and the fourth check is linearly dependent.
Its fixed budget is two message-passing iterations, with the change applied in
iteration 2.  The full branch is predicted to end at hard-decision estimate
`1101` with syndrome `0110`; the collapsed branch is predicted to end at
`0111` with syndrome `1001`.  This case checks whether the registered state
change still produces a trajectory difference on a graph with a cycle.  It
does not test decoding performance.

## Stopping rule and correctness gates

The fixed budget is three message-passing iterations, with the intervention in
iteration 2.  No early stopping or post-inspection retuning is used.

The run is valid only if all of the following pass:

- every branch has the same hash for the saved state;
- neutral edge slots, variable-to-check labels, and check-to-variable labels
  agree in every trace record, and first-divergence labels match their stage;
- all pre-intervention trajectories are identical;
- the iteration-1 mean-collapse negative control is bitwise identical to the
  standard variable-to-check vector;
- a consistent check-row relabeling preserves the trajectory for every bit and
  applies the expected permutation to edge- and check-indexed values;
- the equal-mean, different-delta witness changes the next check inputs;
- the shadow and reconstruction controls match their required branches;
- every delta group has exact zero sum in the validation representation;
- the check-node formula agrees with independent enumeration of local valid
  configurations;
- hard decisions and syndromes agree with independent calculations;
- the registered anchor and calibration values agree within `1e-12`; and
- deterministic replay reproduces every retained trace hash, verifies the
  retained configuration against the effective configuration, and rejects a
  trace unless all recomputed and recorded scientific validation flags pass.

## Retained diagnostics

For every iteration and branch, retain the incoming check-to-variable values,
standard and transmitted variable-to-check values, mean and delta decomposition,
a-posteriori LLRs before and after the check-node update, hard-decision estimate,
syndrome, first divergence from full BP, configuration, source hashes, and
result hashes. The schema records a neutral slot label plus separate
variable-to-check and check-to-variable labels for every edge-indexed vector.

Operation counts, runtime, memory, decoding performance, and native projected-GD
behavior are outside this experiment's claim.
