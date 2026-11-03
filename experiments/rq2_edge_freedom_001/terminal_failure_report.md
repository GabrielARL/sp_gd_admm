# Terminal failure report

Experiment: `RQ2-EDGE-FREEDOM-001`

Attempt: `2026-11-03_v1`

Status: terminal compatibility-gate failure

The queue passed its frozen-source checks and began the retained compatibility
stage. It stopped on frame 20001 at update 6 with:

```text
constrained pullback-gradient gate failed on frame 20001 update 6
```

No fresh case was evaluated. The planned anchor range `61497:61520` and
contingent transfer range `61521:61720` therefore remain outcome-unexposed.
The failure is numerical-protocol evidence only: a fixed absolute identity
tolerance was not maintained along the unboxed product trajectory. It is not
a decoder outcome and does not show that independently evolving edge copies
help or harm recovery.

The experiment remains immutable. The fixed tolerance will not be loosened,
the unboxed trajectory will not be rescued, and the attempt will not be
restarted under this ID. A bounded compound-objective successor must first
reproduce its own scalar lower endpoint and must use a new card, source freeze,
result directory, and experiment ID.
