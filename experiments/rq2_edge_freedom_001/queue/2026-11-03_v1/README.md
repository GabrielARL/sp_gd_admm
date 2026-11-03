# Attempt `2026-11-03_v1`

This attempt runs the frozen unit and retained-compatibility gates, the fresh
24-case anchor, and then the preregistered 200-case transfer only if the anchor
is complete-valid. Outcome direction is not an expansion gate.

The budget uses the completed tied gate and Block A campaign as conservative
anchors. The tied two-arm correctness gate took 66 seconds for 24 cases and
two passes; the four-arm Block A 200-case campaign took about 1,878 seconds.
Allowing for the lifted edge state, finite-difference samples, compilation,
hashing, and result writing gives a 5,400-second queue budget. Runtime is a
diagnostic and does not enter the causal comparison.

The queue is fail-closed, single-threaded, checksum-bound, non-overwriting, and
has no automatic restart or numerical rescue.
