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
