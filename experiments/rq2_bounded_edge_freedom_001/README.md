# RQ2 bounded edge freedom

`RQ2-BOUNDED-EDGE-FREEDOM-001` is the bounded successor to the terminally
failed `RQ2-EDGE-FREEDOM-001` attempt.

The sequence is fail-closed:

1. reproduce Block-A `compound__box` bit-for-bit on retained frames
   `20001:20024`;
2. compare equality-constrained and equality-relaxed edge optimization
   variables on the unexposed 24-case anchor `61497:61520`;
3. launch the preregistered 200-case transfer `61521:61720` only if the anchor
   and deterministic replay pass every gate.

Both arms use the same compound squared-residual objective, edge box, metric,
preconditioner, common update 1, assigned frozen offsets, strict-decrease line
search, hard-decision readout, and 30-update budget. The only intervention is
removal of the equality constraints among edge coordinates attached to the
same coded bit.

The edge box constrains `z_(c,i)` to `[-1,1]`; the parity calculation reads
`z_(c,i)+delta_(c,i)` without clamping that offset-adjusted reading. This
choice is required for the tied arm to reproduce the scalar Block-A feasible
set.

No result from this experiment may be described as BP equivalence or as a
complete decomposition of the native BP-versus-projected-GD gap. The edge
quantities are optimization variables, not BP messages.

The experiment card and derivation card are the prospective scientific
contract. Implementation, tests, freeze, queue, and result artifacts must be
added without changing that contract after fresh outcomes are observed.

The queue uses the same registered and hash-checked Julia project as Block A:
`/home/gabiel/Documents/GitHub/JadeJcade-worktrees/awgn-jade-coral-20261012`.
The copied project inside the source freeze is provenance material; it is not
substituted as a different runtime environment.
