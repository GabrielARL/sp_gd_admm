# `RQ1-ENDPOINT-001` deterministic endpoint bridge

Status before execution: **approved design; executable validation required**.

## Research purpose

This experiment connects the controlled BP state/update bench to two separately
defined native endpoints:

1. exact sum-product BP; and
2. the retained `coral_exact_gradient` scalar projected-gradient endpoint from
   `R5-AWGN-ISOLATION-R050-001`.

It is a deterministic mechanism bridge on one three-bit graph.  It is not an
AWGN performance experiment and makes no BER, FER, convergence-rate, or
receiver-ranking claim.  ADMM is outside its scope.

## Frozen physical input

The parity-check graph is

```text
H = [1 1 0;
     0 1 1].
```

The physical channel evidence uses the repository's bit-one-positive
convention throughout the controlled bench:

```text
L = (-log(9), log(3/2), log(2)),
L_i = log(P(bit_i=1|y_i) / P(bit_i=0|y_i)).
```

JadeJcade's native code uses a bit-zero-positive coordinate.  The bridge must
therefore apply the full coordinate change

```text
ell = -L,  x_Jade = -x_teaching,
q_Jade = -Q_teaching,  r_Jade = -U_teaching.
```

Relabeling the convention without negating the values is forbidden.

## One executable ladder

The runner records nine ordered cards.  Cards 3--9 share one scalar-state
fingerprint, and adjacent cards may change only the registered field.

1. **`RQ1-CONVENTION-001` — coordinate validation.**  Verify the complete sign
   transformation, hard-decision invariance, syndrome invariance, parity-
   residual invariance, and gradient chain rule.
2. **`RQ1-ENDPOINT-BP-001` — exact-SP reproduction.**  Compare the controlled
   flooding recurrence with JadeJcade's actual exact sum-product check function
   and `_bp_decode_sum_product` endpoint.  Normalized min-sum is not called.
3. **`RQ1-ENDPOINT-PG-BASE-001` — parity-only base.**  Reproduce the teaching
   projected-gradient proposal after the sign change and the exact positive
   objective rescaling.  With `mu_p=2`, `n=3`, and teaching step `0.25`, the
   equivalent normalized step is `0.25*n/mu_p = 0.375`.
4. **`RQ1-BRIDGE-CHANNEL-001` — channel-evidence reuse.**  Change only the
   channel-term weight from zero to one.  The same channel LLR vector enters
   every objective and gradient evaluation.
5. **`RQ1-BRIDGE-BINARY-001` — binary term.**  Change only the binary-penalty
   weight from zero to `0.2`.
6. **`RQ1-BRIDGE-STEP-001` — fixed step.**  Change only the fixed step from
   `0.375` to the endpoint's initial step `0.2`.
7. **`RQ1-BRIDGE-PRECOND-001` — diagonal direction.**  Change only the direction
   rule from the negative gradient to the endpoint curvature-bound direction.
8. **`RQ1-BRIDGE-LINESEARCH-001` — strict-decrease search.**  Change only the
   line-search mode from no search to the endpoint's first-strict-decrease
   halving rule, with at most 16 backtracks.
9. **`RQ1-ENDPOINT-PG-001` — native termination and composition.**  Change only
   the termination policy from one update to 30 requested updates or a native
   line-search stall.  The composed trace must match both the current native
   implementation and the archived R050 no-fixed-bit implementation.

The product-parity calculation, one-scalar-per-bit state, box, projection,
frozen full-gradient schedule, graph, channel evidence, precision, and hard-
decision rule remain fixed across cards 3--9.

## Method fingerprints

### Exact sum-product endpoint

- Persistent dynamic state: one directed variable-to-check value and one
  directed check-to-variable value per Tanner-graph edge.
- Channel evidence: reintroduced in every variable-node calculation.
- Check calculation: exact tanh/atanh sum-product.
- Schedule: flooding, without damping.
- Endpoint stopping: zero syndrome or the declared iteration limit.

### Exact-gradient scalar endpoint

- Persistent dynamic state: one relaxed scalar in `[-1,1]` per coded bit.
- Objective:

```text
-ell'x/(2n)
+ mu_p/n * sum_c (1 - product_{i in c} x_i)^2
+ mu_b/n * sum_i (1 - x_i^2)^2.
```

- Update: partial derivatives of that objective, a diagonally preconditioned
  descent direction, strict-decrease backtracking, and componentwise projection
  onto the box.
- Endpoint settings: `mu_p=2`, `mu_b=0.2`, initial step `0.2`, at most 16
  backtracks, and 30 requested updates.
- It calls neither BP nor a pseudogradient.

The BP check-to-variable values are messages.  The scalar objective's partial
derivatives and check-associated contributions are not messages.

## Validity gates

The bridge is valid only if all of the following pass:

1. the configuration reproduces the symbolic LLR values;
2. sign-converted BP states, hard decisions, syndromes, parity residuals, and
   scalar gradients agree with the original coordinates;
3. exact-SP messages agree with local configuration enumeration and the native
   exact-sum-product endpoint, with no active LLR clipping;
4. the archived runner has its registered SHA-256;
5. current and archived no-fixed-bit native scalar outputs are identical before
   downstream bridge cards execute;
6. every scalar objective gradient passes centered finite differences;
7. the teaching and normalized parity-only projected proposals agree after
   inverse sign mapping;
8. every projected coordinate equals an independent box projection and records
   its raw proposal and active set;
9. every update uses one frozen input state for all partial derivatives;
10. adjacent scalar fingerprints differ only in their registered field;
11. the one-update line-search trace is a prefix of the native-termination
    trace;
12. the composed terminal state, objective history, terms, accepted-step count,
    evaluation count, and stop status match both native scalar implementations;
13. two independent pure calculations have the same canonical scientific
    SHA-256; and
14. an existing output directory is never overwritten.

If the archived/current native comparison fails, the runner must retain an
invalid result containing that mismatch and execute no downstream ladder card.
No parameter may be changed after inspecting a result.

## Interpretation boundary and duplicate gate

`RQ1-UPDATE-001`'s full-state residual-gradient cell is a bounded transfer of
the already retained `R3-EDGE-FIXEDPOINT-001` mechanism, not a new receiver.
This bridge does not rerun that long-code route.  It also does not rerun or tune
the R050 AWGN curve, odd-set projected parity, trained restarts, adjacent scalar
weights, or larger scalar step budgets.  The only new causal toy ablation is
the registered channel-evidence-reuse card; the remaining scalar cards expose
and validate the exact endpoint composition.
