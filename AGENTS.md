# Repository objective

The current research program compares belief propagation (BP) and projected
gradient descent (GD) through two ordered questions.

## Research Question 1 — mechanism identification

What mechanism, or combination of mechanisms, differentiates BP from projected
GD? Operationally, identify which difference in state representation,
check-local parity action, persistence, or update rule produces the first
reproducible trajectory divergence when the parity-check graph and vector of
channel LLRs are fixed. Do not infer this mechanism from a native-method
performance ordering.

## Research Question 2 — causal performance consequence

Does the mechanism identified in Research Question 1 causally change
valid-codeword recovery and transmitted-word recovery on preregistered locked
AWGN cases? Answer this with a one-mechanism-at-a-time bridge ablation that adds
or removes the candidate mechanism while holding the declared graph, vector of
channel LLRs, protocol, and other algorithmic choices fixed as far as the
hypothesis permits. Declare an explicit work budget.

ADMM is deferred from these two questions. Existing ADMM examples may remain as
mechanism tutorials, but ADMM outcomes or ablations do not answer the current
BP–GD questions. Do not reintroduce ADMM into the causal study unless the user
explicitly opens a later research question.

## Mandatory skill usage

- Use `$sp-gd-admm-terminology` whenever reader-visible HTML, TeX, captions,
  labels, tables, or explanations name or compare BP, GD, or ADMM quantities.
- Use `$sp-gd-admm-mechanism-study` before designing, implementing, running, or
  interpreting an experiment for either BP–GD research question.
- Use `$sp-gd-admm-writing` when turning a trace or experiment into a tutorial,
  slide, paper section, caption, or report. Apply the terminology skill first.

## Evidence boundary

Toy graphs and synchronized animations explain mechanisms. They do not by
themselves establish bit-error rate, frame-error rate, convergence, complexity,
or superiority on a code ensemble. Keep generated PDFs synchronized with their
TeX sources, and edit source files rather than generated artifacts.
