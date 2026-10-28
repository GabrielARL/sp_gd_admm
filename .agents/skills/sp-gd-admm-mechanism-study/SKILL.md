---
name: sp-gd-admm-mechanism-study
description: Design, run, and interpret controlled experiments that first identify what differentiates BP from projected gradient descent and then test whether that mechanism causes their decoding-performance difference. Use for BP–GD examples, algorithm changes, parameter studies, performance comparisons, and causal claims. The current scope defers ADMM unless the user explicitly opens a later research question; do not use for presentation-only edits.
---

# BP–GD mechanism study

The current research program has two ordered questions:

1. **RQ1 — mechanism identification:** Which operational difference in state
   representation, check-local parity action, persistence, or update rule
   produces the first reproducible trajectory divergence between BP and
   projected GD when the parity-check graph and vector of channel LLRs are
   fixed?
2. **RQ2 — causal performance consequence:** Does the mechanism isolated in
   RQ1 causally change valid-codeword recovery and transmitted-word recovery on
   preregistered locked AWGN cases when it is added or removed in a
   one-mechanism-at-a-time bridge ablation with an explicit work budget?

RQ1 identifies and operationally defines a candidate mechanism. RQ2 requires a
counterfactual or ablation that changes that mechanism while holding the other
declared factors fixed as far as the hypothesis permits. Do not answer both
questions from a native BP-versus-GD ordering, reduce the result to a winner
ranking, or attribute every difference to the optimizer.

ADMM is outside the current two questions. Existing ADMM tutorials may remain,
but do not use an ADMM outcome to establish a BP–GD mechanism and do not design
an ADMM ablation unless the user explicitly opens a later question.

A scoped BP–GD ordering is allowed when the metric, tested case, budget, and
denominator are explicit. If the ordering changes with the metric, state that
there is no single best method.

## Fingerprint before comparing

For each method, record:

- optimized or propagated state and its dimension;
- channel evidence or data term and LLR sign convention;
- parity representation or feasible set;
- check-local operation and global update operator;
- persistent state and what is discarded;
- frozen, flooding, serial, or alternating schedule;
- initialization, scaling, damping, step size, penalty, and projection rules;
- stopping rule, hard-decision rule, and validity test.

For RQ1, explicitly compare these candidate distinctions:

- one relaxed value per bit versus recipient-specific directed-edge state;
- summation of neighboring partial derivatives versus recipient exclusion in
  a variable-to-check update;
- a smooth parity contribution versus the BP check-node operation;
- check-associated derivative contributions recomputed and discarded while the
  relaxed bit variables persist, versus directed-edge messages retained for
  the next message-passing iteration;
- and differences in objective or feasible set that prevent a clean
  representation-only conclusion.

Separately record the protocol: parity-check matrix and graph, transmitted word
or payload, exact received samples or vector of channel LLRs, random seed and
noise realization, all parameters, iteration and runtime budgets, method
execution order, and metric denominators.

## Ask one causal question at a time

A native-method comparison may hold the graph and evidence fixed while the
methods retain different objectives, states, and constraints. Such a comparison
describes behavior and may locate the first trajectory divergence, but it does
not by itself answer RQ1 or isolate an optimizer effect. To answer RQ1, define
the candidate mechanism in an executable way. To answer RQ2, align the target
and constraints where possible or construct an explicit ablation ladder that
changes that mechanism one step at a time.

Summing check-associated partial derivatives is the correct gradient operation
for a scalar objective. A small summed derivative or cancellation ratio is a
diagnostic, not proof of harmful information loss. Establish a state-loss claim
only with a counterfactual representation or update that retains the relevant
check-specific quantities and changes the registered outcome.

The retained three-bit belief-coordinate control shows that projected gradient
can reproduce the sum-product posterior on a tree when it uses bit and check
beliefs with exact marginalization constraints. Therefore, do not formulate
RQ1 as "why BP works but gradient descent cannot." The unresolved distinction
is the interaction among representation, constraints, persistence, and the
executable update operator.

Classify new work as a reproduction, transfer, parameter study, or ablation
study. Search retained source and outputs before coding so a renamed or
rescheduled duplicate is not reported as a new result. Give an ablation study
one preregistered anchor case before any sweep; retain a failed anchor and do
not retune it post hoc under the same hypothesis.

Use this experiment card:

```text
research question: RQ1 or RQ2
question:
mechanism being isolated:
operational definition of the mechanism:
method fingerprints:
protocol fingerprint:
closest retained experiment:
only causal difference:
counterfactual prediction:
predicted diagnostic change:
anchor case and stopping rule:
correctness gates:
decoding-performance metrics:
operation, runtime, and memory metrics:
```

## Preserve aligned diagnostics

At the same declared snapshot, retain:

- BP: variable-to-check messages, check-to-variable messages, bit LLRs, hard
  decision, and syndrome;
- projected GD: objective components, partial derivatives, unconstrained step,
  projection or clipping, hard decision, and syndrome;
- both methods: bit errors, whether the estimate is a valid codeword, whether it
  equals the transmitted word, elapsed time, and allocated or peak memory when
  available.

Do not equate a lower objective or a valid codeword with recovery of the
transmitted word. Do not compare raw iteration counts as equal work. Report
method-specific operations, runtime, and stored-state count or memory usage
separately.

## Account for computational work

Before making a complexity comparison, declare:

- which work is part of the algorithm core and which is only diagnostic or
  rendering work;
- primitive-operation categories for each method;
- how nonlinear functions and projection or clipping internals are counted;
- which persistent values enter stored-state or memory accounting; and
- the runtime warm-up, repetition, and timing protocol.

Report heterogeneous categories separately unless a weighting model has been
stated and justified. A shared visual panel is acceptable, but do not collapse
method-specific work into one scalar merely because both methods traverse the
same graph.

## Validate the mechanism

- For toy BP examples, independently enumerate valid local configurations or
  exact marginals.
- Check projected-GD derivatives by finite differences and verify every
  projection or clipping step.
- For alternating updates, index before-update and after-update states
  explicitly, and attach every residual and hard decision to the state from
  which it was actually calculated.
- Verify displayed values from the executable model rather than copying rounded
  worksheet text back into calculations.

Scope every conclusion to the tested graph, observations, parameters, budgets,
and metric denominator. An animation is a mechanism demonstration unless a
separate experiment supplies decoding-performance evidence.
