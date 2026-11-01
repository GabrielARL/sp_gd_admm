# RQ2-EXACT-MAP-UPDATE-001

Research question: RQ2.

Question: When one persistent check-to-variable value is retained per
Tanner-graph edge and the exact sum-product map is fixed, is the recovery
difference caused by transforming the
fixed-point residual with the Jacobian transpose, by the step rule, or by their
interaction?

Mechanisms being isolated: update direction and step rule.

Operational definition: every cell retains one check-to-variable value per
Tanner-graph edge. Every variable-to-check value contains the channel LLR plus
the incoming check-to-variable values from the other neighboring checks, with
the recipient check excluded. The exact tanh-atanh sum-product calculation
defines the map `F(u)`. The registered residual objective is

`R(u) = 0.5 ||u - F(u)||_2^2`.

The direction factor has two levels:

- `true_gradient` uses `-(I-J_F(u))' (u-F(u))`, the negative gradient of
  `R`;
- `map_minus_state` uses `F(u)-u`, the fixed-point displacement before any
  Jacobian-transpose transformation.

The step factor has two levels:

- `armijo` uses the registered backtracking line search and accepts only a
  finite trial with a negative directional derivative, strict objective
  decrease, and the inequality recorded in `config.toml`;
- `unit` fixes `alpha=1`. For `map_minus_state__unit`, no Jacobian or residual
  gradient is evaluated and the next edge state is assigned exactly to `F(u)`.
  For `true_gradient__unit`, the next edge state is assigned to
  `u-gradient(R(u))`.

Method fingerprints: the four cells use the regular `(10200,5100)` LDPC graph,
the declared vector of channel LLRs, the exact sum-product map with a separate
outgoing variable-to-check value for each recipient check, zero initial
check-to-variable values, 30 attempted updates, the same hard-decision and
syndrome calculations, and no outcome-altering early stop. The cells differ
only in registered direction and step factors. This experiment does not run
the repository's native projected-GD decoder.

Protocol fingerprint: variable degree 3, check degree 6, graph seed 169616412,
all-zero transmitted word, known-unit-gain post-FFT complex AWGN, and channel
LLRs clipped to `[-20,20]`, where positive values favor coded bit zero. The
fresh anchor uses frames 60425--60448 at both 6 dB and 1.5 dB. The 6 dB
transfer uses frames 60449--60648. The 1.5 dB confirmation uses frames
60649--60848. Each job is independently replayed.

Closest retained experiment: `RQ2-BP-TARGET-STATE-UPDATE-001` supplies the
retained residual-gradient trajectory whose exact sum-product map uses a
separate outgoing variable-to-check value for each recipient check, and
the direct exact-map trajectory. `RQ2-NATIVE-COMPOSITION-001` supplies the
fresh-frame boundary immediately before this experiment. The present study is
a follow-up ablation, not another native-method scoreboard.

Only causal differences: within the four-cell table, the selected direction
and the selected step rule. Persistent state, recipient exclusion, exact
sum-product calculation, initialization, update budget, hard-decision rule,
and validity calculation remain fixed.

Counterfactual predictions:

1. If the Jacobian-transpose transformation is decisive, changing
   `true_gradient` to `map_minus_state` will change transmitted-word recovery
   while the step level is held fixed.
2. If the step rule is decisive, changing the backtracking line search to the
   unit step will change recovery while the direction is held fixed.
3. If neither factor has an additive explanation, the paired difference for
   one factor will depend on the level of the other factor; this is reported as
   the two-by-two interaction rather than assigned to either factor alone.

Predicted diagnostic change: `map_minus_state__unit` must reproduce direct
application of `F` exactly. The other three cells may differ in objective
increase count, non-descent stalls, selected step size, or nonfinite behavior.
In particular, direct exact-map updates are allowed to increase `R`; the
registered backtracking line search is not.

Anchor case and stopping rule: validation-only frames 20001--20024 reproduce
the retained trajectories before fresh evidence is interpreted. Every cell
then performs exactly 30 attempted updates. A valid syndrome and recovery of
the all-zero transmitted word are shadow diagnostics and never stop a cell.
If `true_gradient__unit` produces a nonfinite gradient, state, or objective,
that cell enters an absorbing failure: the last finite state is retained only
as an unscored diagnostic and the remaining attempts are marked failed.

Correctness gates: the frozen Block-B runner and Jade sources must match their
registered hashes; analytic residual gradients and Jacobian-vector adjoints
must pass finite-difference checks; `true_gradient__armijo` must reproduce the
retained full residual-gradient trajectory; and the fixed-30
`map_minus_state__unit` cell must reproduce the first 30 updates of a separate
retained direct-map oracle. That oracle continues for at most 80 updates solely
for its first-valid snapshot to be compared bit-for-bit with native exact
sum-product. A native decode that first becomes valid after update 30 therefore
does not invalidate the fixed-30 science cell. Every direct unit assignment
must equal the already calculated `F(u)` exactly. The separately reported
floating-point diagnostic evaluates the algebraic expression `u+(F(u)-u)` and
may expose roundoff without changing the assigned state. Hard decisions and
syndrome weights must agree with independent recomputation. Primary and replay
scientific and table hashes must match.

Decoding-performance metrics: the primary paired outcome is transmitted-word
recovery at the terminal state after exactly 30 attempted updates. Terminal
parity validity, coded-bit errors, and syndrome weight are also retained. First
exact-word and first parity-valid updates are shadow diagnostics only and do
not replace the terminal outcome. A parity-valid hard-decision estimate is
distinguished from recovery of the transmitted word. A cell in absorbing
failure is not counted as a recovered case even if its last finite diagnostic
state happened to equal the transmitted word.

Inference: the four registered paired atomic contrasts are the direction
change under the backtracking line search, the direction change under the unit
step, the step change under the true-gradient direction, and the step change under the
map-minus-state direction. Each SNR in each job forms its own family. Each
contrast receives a two-sided exact McNemar test and a 98.75% Newcombe paired
score interval; the four p-values are adjusted by Holm at familywise
`alpha=0.05`. Cases and evidence are not pooled across SNRs or jobs. The
per-case difference-in-differences is retained. If any case has a nonzero
interaction, additive attribution to separate direction and step contributions
is forbidden under the registered conservative rule.

Operation, runtime, and memory metrics: attempted and accepted updates,
objective evaluations, line-search backtracks, non-descent stalls, objective
increases, absorbing failures, and elapsed time are retained separately. Raw
update counts are not asserted to represent equal computational work.

Interpretation boundary: this experiment can causally separate direction,
step rule, and their interaction while the exact sum-product map keeps a
separate outgoing variable-to-check value for each recipient check. It cannot
show that all differences between native projected GD and
native BP have been removed, because their native objective, domain,
projection, state representation, and stopping rules remain distinct outside
this bridge.
