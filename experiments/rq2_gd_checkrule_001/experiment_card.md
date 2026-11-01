# `RQ2-GD-CHECKRULE-001`: superseded design note

Status: **superseded before execution on 2026-11-01.** No result may be
reported under this design.

The original card proposed changing projected GD toward BP through three
arms called `check_rule`, `check_rule_llr`, and `variable_rule`. The completed
assignment/refresh control showed that this is not an atomic ladder:

- the retained GD readings leave `[-1,1]`, so applying `atanh` also requires
  a separately declared domain or clipping intervention;
- recipient exclusion requires persistent check-to-variable state that the GD
  construction does not retain;
- replacing a declared objective's partial derivatives by a BP update
  calculation makes the existing descent line search undefined; and
- the old launch trigger required a null outcome that did not occur.

Running the old card would therefore change state, calculation, domain, and
update operator together. It is retained only as the provenance of the
question.

## Promoted tests

The user's 2026-11-01 authorization to test factors 1--6 is implemented as
two controlled factorial blocks and a conditional composition:

1. `RQ2-GD-RESIDUAL-PROJECTION-BUDGET-001` crosses the compound parity
   objective with an explicit product-only objective and crosses box
   projection with no projection. The same trajectories are scored after 30
   and 90 requested updates and by first parity-valid/first exact-word time.
   This isolates the check-polynomial shape, projection, update budget, and
   their interactions inside the frozen-offset GD path.
2. `RQ2-BP-TARGET-STATE-UPDATE-001` crosses full recipient-specific BP state
   with mean-preserving tying and crosses direct application of the sum-product
   map with gradient descent on the declared residual objective
   `R(u) = 0.5 ||u - F(u)||^2`. This isolates recipient-specific state, update
   operator, and their interaction on a common exact-SP target.
3. `RQ2-CAUSAL-FACTORS-001` is the campaign controller. It requires native
   projected GD, the retained assigned/frozen bridge, and native exact
   sum-product endpoint gates, then runs the two blocks. A common executable
   endpoint composition is conditional on those results and is not silently
   chosen by the queue.

The six requested tests are therefore represented as:

| Requested factor | Registered comparison |
|---|---|
| 1. recipient-specific formation/state | full versus mean-preserving tied BP target |
| 2. check calculation | compound versus product-only GD objective |
| 3. update operator | direct BP map versus gradient descent on the residual objective |
| 4. projection | box versus unconstrained GD update |
| 5. budget/stopping | the same trajectory at update 30 and 90, plus shadow first-hit times |
| 6. interactions/order | both factorial interactions; reverse-order composition is conditional |

Factor 5 is an explicitly reopened artifact control, not a new generic
step-budget search. Earlier long-budget scalar-GD evidence remains part of the
interpretation. No arm may be tuned after its outcome is observed.

## Claim boundary

The known `30001:30200` cases, including the 33 unresolved by the retained
assigned/frozen bridge, are an informed attribution set. Results on them are
descriptive paired accounting, not fresh confirmation. Every arm runs on all
200 cases so that recoveries and losses are both visible. Causal confirmation
requires the preregistered fresh transfer set. An additive statement such as
"factor X accounts for N cases" is permitted only if endpoint reproduction
passes and the reverse-order/interaction check shows no material path
dependence; otherwise increments must be reported as path-conditional.
