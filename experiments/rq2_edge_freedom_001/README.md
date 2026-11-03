# Edge-copy equality relaxation

`RQ2-EDGE-FREEDOM-001` compares an equality-constrained and an
equality-relaxed optimization trajectory under the same lifted product
objective, metric, initialization, frozen offsets, strict-decrease line search,
and 30-update budget.

The experiment is an RQ2 causal diagnostic. It is not a new receiver and it
does not turn the connection-specific optimization variables into BP messages.

The 24-case anchor is run before the registered 200-case transfer. A stability
or correctness failure stops the queue without retuning or adding a rescue
operation.

## Terminal result

Attempt `2026-11-03_v1` failed closed on retained compatibility frame 20001,
update 6, before any fresh anchor case was evaluated. The registered absolute
pullback-gradient identity gate failed. The result directory records
`completed_frames = 0`; consequently this attempt provides no decoding count
and no causal evidence about equality relaxation.

The attempt is retained without tolerance changes or relaunch. Any bounded
compound-objective successor must use a new experiment ID and a new freeze.
