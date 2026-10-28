---
name: sp-gd-admm-writing
description: "Write or revise reader-visible explanations for the repository's ordered BP–GD research questions: first identify the differentiating mechanism, then test its causal performance consequence. Use for papers, notes, animations, captions, and reports. Keep ADMM outside the current causal questions unless the user explicitly reopens it; do not use for code-only or mechanical formatting changes."
---

# Mechanism-first BP–GD writing

Explain why the trajectories differ before reporting which output is better.
Apply `$sp-gd-admm-terminology` first whenever technical wording changes.

Organize current research claims in this order:

1. **RQ1:** identify and operationally define the mechanism that differentiates
   BP from projected GD;
2. **RQ2:** test whether changing that mechanism changes decoding performance
   under a controlled counterfactual.

Do not infer the RQ1 mechanism from the performance ordering that RQ2 is meant
to explain. ADMM may appear in an existing tutorial, but it is not evidence for
either current question and must not enter their conclusions.

## Build the explanation

Use this causal order when the evidence supports it:

1. State the controlled coding case and the observed difference.
2. Explain what each method stores between updates.
3. Show how one parity check acts on that state.
4. Identify the first point where the trajectories diverge.
5. Connect that divergence to a measured diagnostic.
6. State the decoding or engineering consequence within the tested scope.

For an RQ1-only result, stop after operationally identifying the divergence and
label its performance consequence as untested. Use steps 5 and 6 only when an
RQ2 ablation supplies the required evidence.

Describe every method at the same conceptual level: evidence entering, retained
state, parity action, update schedule, stopping condition, and hard-decision
rule. Do not give one method only equations and another only intuition.

## Separate observations from explanations

Use direct language for values reproduced from code or retained results. Label
a proposed cause as a hypothesis until an aligned experiment or ablation tests
it. Do not write a generic native BP-versus-GD ordering as a causal result, and
do not pull ADMM into the current conclusion. A narrow ordering is acceptable
only when its metric, tested case, budget, and denominator are stated. If
different metrics favor different methods, say that there is no single best
method.

Summation of neighboring partial derivatives is the correct gradient operation
for the stated scalar objective. Describe cancellation as an observed
diagnostic, not as information loss or the culprit, until a controlled
representation or update ablation demonstrates the claimed consequence.

Keep these distinctions explicit:

- objective decrease versus decoding success;
- parity validity versus recovery of the transmitted word;
- synchronized animation beats versus equal complexity; and
- a mechanism demonstration versus error-rate evidence across cases.

## Keep artifacts synchronized

Before calling a document or animation complete, verify that equations, source
code, tables, captions, visible states, and narration describe the same update
order and numerical snapshot. Preserve full-precision calculations internally
and round only for display. If evidence is missing, use a visible verification
note in a working draft rather than polishing a hypothesis into a result.

End with the narrow practical consequence established by the data, including
the compared methods, graph or dataset, budget, metric, and denominator when
needed. Do not introduce a new project-defined receiver name, acronym, or
stronger scientific claim without the user's approval.
