---
name: sp-gd-admm-terminology
description: Audit and select reader-visible terminology for BP, projected gradient descent, and ADMM decoding examples in this repository. Use when editing HTML, TeX, captions, labels, tables, or explanations that compare the methods; do not use for code identifiers or styling-only changes.
---

# BP, GD, and ADMM terminology

Keep the three methods comparable without pretending that their internal
quantities are the same.

## Name each mechanism precisely

- BP retains directed variable-to-check messages and check-to-variable
  messages. Call a completed BP round a message-passing iteration.
- Projected GD retains relaxed bit variables. It computes partial derivatives
  of the objective function, takes a gradient step, and projects onto its stated
  box or feasible set. Do not call this message passing.
- ADMM retains shared bit variables, per-check replica variables, and scaled
  dual variables. Name the parity-polytope projection and the primal and dual
  residuals. Do not relabel replica or dual updates as BP messages.
- Use `hard-decision estimate` for thresholded relaxed values. Reserve
  `codeword` for a binary vector that satisfies every parity check.
- Write the syndrome as `(H b-hat) mod 2` or state that arithmetic is over
  GF(2). A parity-polytope point may be fractional and is not necessarily a
  codeword.

## State the comparison basis

Name exactly what is shared: for example, the parity-check matrix, transmitted
bits, received samples, noise realization, or vector of channel LLRs and its sign
convention. Do not use `matched inputs`, `common inputs`, `same inputs`, or
`identical inputs` without immediately listing the quantities whose equality
was verified.

A shared graph and shared channel evidence do not imply a shared objective.
Equal animation duration does not imply equal arithmetic, state, memory, or
computational complexity. Use method-specific progress labels rather than one
shared message or edge-transfer count.

A shared visual component may contain separate method-specific counters. Do
not label animation beats, displayed values, or kernel calls as computational
complexity. Before using `operation count`, declare the counted primitives,
whether projection internals and diagnostic work are included, and any
weighting or cost model.

## Distinguish presentation from scheduling

Say that the checks are `shown one after another` when an animation displays
them in that order while both checks use a frozen iteration state. Describe an
algorithm as sequential or round-robin only when later updates actually consume
earlier in-place updates. Define what one iteration means for each method before
comparing iteration counts.

## Review changed text

Check every new technical phrase in reader-visible source. Apply
`$uwa-literature-terminology` to validate the complete phrase in its intended
meaning and report unsupported expressions and extraction gaps. Internal
checklist field names need to be clear and consistent, but are not themselves
claims that a phrase is established in the literature. If the literature
search is unavailable, mark unfamiliar reader-visible terminology for review
rather than inventing a replacement. Terminology evidence does not validate an
equation or scientific claim.

Before finalizing, search changed reader-visible files for ambiguous comparison
wording:

```bash
rg -n -i 'matched[ -]inputs?|input[ -]matched|common inputs|same inputs|identical[ -]inputs?|edge transfers?|gradient messages?' FILE...
```

Do not introduce a new project-defined receiver name or acronym without the
user's approval. Established abbreviations such as BP, GD, and ADMM are not new
project names.
