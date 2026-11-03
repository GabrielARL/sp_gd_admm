# RQ2-BP-TARGET-STATE-UPDATE-001

Research question: RQ2.

Question: On the same graph and with the same exact sum-product check kernel,
what changes when (i) the recipient-specific variable-to-check values are
retained or replaced by their per-bit arithmetic mean, and (ii) each declared
state map is applied directly or approached by gradient descent on its own
fixed-point residual?

Mechanisms being isolated: recipient-specific state and update operator.

Operational definition: the persistent state `u` contains one
check-to-variable value per Tanner-graph edge. For state level `full`, the
variable-to-check value sent toward check `c` contains the channel LLR and the
incoming check-to-variable values from the other neighboring checks, excluding
`c`. For state level `qbar_tied`, all outgoing variable-to-check values for one
bit are replaced by their arithmetic mean immediately before the same exact
sum-product check calculation. The direct operator applies `u <- F_s(u)`. The
gradient operator takes a true gradient step on

`R_s(u) = 0.5 ||u - F_s(u)||_2^2`,

using `(I-J_F_s(u))' (u-F_s(u))` and a preregistered Armijo line search.

Method fingerprints: all four cells use the same graph, channel LLR vector,
exact tanh-atanh check calculation, all-zero initial edge state, hard-decision
rule, and 30 attempted updates. `F_full` and `F_qbar_tied` differ at the
registered state-map factor. Within either state level, the direct and
residual-gradient operators use the same `F_s`. This is not the repository's
native projected-GD decoder.

Protocol fingerprint: regular `(10200,5100)` LDPC graph, variable degree 3,
check degree 6, graph seed 169616412, known-unit-gain AWGN at 6 dB, and channel
LLRs clipped to `[-20,20]`, where positive values favor coded bit zero.

Closest retained experiments: `RQ1-UPDATE-001` supplies the toy fixed-point
operator control. `BPGD-RQ2-QBAR-AWGN-001` supplies the exact sum-product
recipient-specific versus tied-state intervention. This experiment promotes
their crossed mechanism to the long code; it is not a renamed native
BP-versus-projected-GD comparison.

Only causal differences: the recipient-specific versus mean-tied
variable-to-check calculation and the direct versus residual-gradient update
operator. The objective used by the gradient cells is explicit and is checked
by finite differences.

Counterfactual prediction: if recipient-specific addressing and direct map
application interact, the effect of tying the outgoing values will differ
between the direct and residual-gradient rows of the factorial.

Predicted diagnostic change: tying first changes the check inputs after
recipient-specific outgoing values diverge. Replacing the direct map by a
gradient step changes the trajectory immediately unless the residual-gradient
step happens to equal the direct displacement.

Anchor case and stopping rule: every arm executes exactly 30 update attempts;
syndrome validity never stops an arm. The first parity-valid and first exact
all-zero hard-decision updates are retained as shadow diagnostics. Calibration
uses frames 20001--20024; fresh anchor uses 50001--50024; fresh transfer uses
50025--50224; locked attribution uses 30001--30200.

Correctness gates: exact check calculation is reused from JadeJcade; analytic
Jacobian-vector adjoints and residual gradients must pass coordinate and
directional finite-difference checks; deterministic replay must match; and the
first-valid snapshot of `full__direct` must equal native exact sum-product in
hard word, posterior bits, both directed edge-state arrays, syndrome, and
stopping iteration.

Decoding-performance metrics: transmitted-word recovery, parity validity,
coded-bit errors, syndrome weight, first exact-word update, and first
parity-valid update. A valid hard-decision estimate is distinguished from
recovery of the transmitted word.

Operation, runtime, and memory metrics: update attempts, accepted gradient
steps, line-search evaluations, and stalls are recorded separately. Runtime is
diagnostic and is excluded from scientific replay hashes. Raw iteration counts
are not asserted to represent equal computational work.

Interpretation boundary: this factorial isolates two operations while holding
the graph and exact sum-product check kernel fixed. Its interaction is
path-conditional bridge evidence. By itself it cannot uniquely allocate the
complete native BP-versus-projected-GD performance gap, because the native
projected-GD objective, domain, and projection are not present in this block.
