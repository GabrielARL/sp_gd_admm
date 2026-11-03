# Derivation: bounded tied and free edge coordinates

This card derives the two arms of `RQ2-BOUNDED-EDGE-FREEDOM-001`. It also
records why the equality-constrained arm is the Block-A `compound__box`
endpoint and why the equality-relaxed arm changes only one feasible-set
constraint.

## 1. Broadcast and mean maps

For coded bit `i`, let `N(i)` be its incident checks and `d_i=|N(i)|`. The
broadcast map `B` copies one scalar per bit onto every incident edge:

```math
(Bx)_(c,i) = x_i.
```

The fixed edge-to-bit readout is

```math
m_i(z) = (1/d_i) sum_{c in N(i)} z_(c,i).
```

Therefore `m(Bx)=x`. Numerically, the implementation uses the first incident
copy plus the mean of deviations from it in frozen incident-edge order. When
the copies are tied, every deviation is exactly zero, so the returned
`Float64` bits equal the source scalar bits.

## 2. Lifted compound objective

For each check `c`, define

```math
P_c(z,delta) = prod_{j in N(c)} [z_(c,j)+delta_(c,j)].
```

The lifted objective is

```math
J_lift(z;delta)
 = -1/(2n) sum_i L_i m_i(z)
   + (w_p/n) sum_c [1-P_c(z,delta)]^2
   + (w_b/n) sum_i [1-m_i(z)^2]^2.
```

Substituting `z=Bx` gives

```math
J_lift(Bx;delta)
 = -1/(2n) sum_i L_i x_i
   + (w_p/n) sum_c [1-prod_{j in N(c)}(x_j+delta_(c,j))]^2
   + (w_b/n) sum_i (1-x_i^2)^2,
```

which is the retained Block-A compound objective.

The feasible edge box is

```math
-1 <= z_(c,i) <= 1.
```

It does not clamp `z_(c,i)+delta_(c,i)`. On the tied manifold this box reduces
to `-1 <= x_i <= 1`, exactly the Block-A scalar box. Bounding the
offset-adjusted reading would instead impose an offset-dependent scalar
interval and would fail to reproduce the lower endpoint.

## 3. Edge partial derivatives

Write the channel-plus-binary scalar contribution at bit `i` as

```math
h_i(m)
 = -L_i/(2n) + (4w_b/n)m_i(m_i^2-1).
```

Because `partial m_i/partial z_(c,i)=1/d_i`, and because only check `c` uses
`z_(c,i)` in its parity product,

```math
g_(c,i) := partial J_lift/partial z_(c,i)
 = h_i(m)/d_i
   - (2w_p/n)(1-P_c)
       prod_{j in N(c),j!=i}[z_(c,j)+delta_(c,j)].
```

On the tied manifold,

```math
sum_{c in N(i)} g_(c,i)
 = h_i(x)
   - (2w_p/n) sum_{c in N(i)} (1-P_c)
       prod_{j in N(c),j!=i}[x_j+delta_(c,j)],
```

which is the Block-A scalar partial derivative. In operator notation this is
the pullback identity

```math
B^T grad_z J_lift(Bx) = grad_x J_compound(x).
```

## 4. One metric for both arms

Let `kappa_i` be the retained scalar curvature bound. Define the diagonal edge
metric

```math
M_(c,i) = kappa_i/d_i.
```

For any tied direction `Bv`,

```math
(Bv)^T M(Bv)
 = sum_i sum_{c in N(i)} (kappa_i/d_i)v_i^2
 = sum_i kappa_i v_i^2.
```

Thus restricting the edge metric to tied directions recovers the scalar
preconditioner exactly.

For the equality-relaxed arm, the free direction is

```math
p_(c,i) = -g_(c,i)/(kappa_i/d_i)
         = -d_i g_(c,i)/kappa_i.
```

At a tied state, its mean is

```math
(1/d_i) sum_{c in N(i)} p_(c,i)
 = -(1/kappa_i) sum_{c in N(i)} g_(c,i),
```

which is the constrained scalar direction. The edge directions may still have
nonzero within-bit spread. That spread is the first operational expression of
the registered treatment.

## 5. Projection and line search

The constrained feasible set is

```math
C_tied = {z: -1<=z_(c,i)<=1 and z_(c,i)=z_(c',i)
          for all c,c' in N(i)}.
```

Under the declared metric, projecting a tied trial onto `C_tied` is equivalent
to clamping the corresponding scalar to `[-1,1]` and broadcasting it. The
relaxed feasible set is

```math
C_free = {z: -1<=z_(c,i)<=1},
```

whose projection is a componentwise clamp. Hence the free set is obtained by
removing only the equality constraints:

```math
C_tied subset C_free.
```

Both arms test the same ordered steps

```math
alpha_k = 0.2 * 2^(-k),  k=0,...,16,
```

and accept the first projected trial that strictly decreases `J_lift`. They
stop if none of those trials decreases the objective.

## 6. Hard decision and private-check diagnostics

Both arms form one hard decision per coded bit from the fixed mean:

```math
hat b_i = 1 if m_i(z)<0, and 0 otherwise.
```

The syndrome and transmitted-word comparison use only this single coherent
hard word. To detect a failure mode in which different checks become
individually satisfied using inconsistent edge coordinates, the result also
retains:

```math
R_private = sqrt(mean_c [1-P_c(z,delta)]^2),
R_mean    = sqrt(mean_c [1-P_c(Bm(z),delta)]^2),
```

the within-bit edge spread, and the count of edge hard signs that disagree
with the mean hard decision. It also records, separately, whether each check's
hard parity is satisfied by the signs of its private readings
`z_(c,j)+delta_(c,j)`, whether it is satisfied by the coherent mean hard word,
and whether those two flags disagree. For these diagnostics, a value greater
than or equal to zero maps to `+1`, a negative value maps to `-1`, and the
check is satisfied when its sign product is `+1`. These are observations of
the two trajectories, not extra penalties or update rules.

## 7. Exact reproduction versus roundoff diagnostics

The lower endpoint is defined by the retained Block-A operation order. The
constrained arm must reproduce that trajectory bit-for-bit; no tolerance can
substitute for this gate.

An independent lifted evaluator checks the mathematical identities above. If
`h_i` is the channel-plus-binary contribution and `q_(c,i)` are the
check-associated contributions, it uses the prospectively registered
roundoff criterion

```math
|g_i - [h_i + sum_c q_(c,i)]|
 <= 128 eps(Float64)
    max(1, |g_i|, |h_i| + sum_c |q_(c,i)|).
```

For the first-direction identity, the corresponding scale is
`max(1, |p_i|, (1/d_i)sum_c|p_(c,i)|)`. The result retains the raw maximum
error and the maximum error divided by its registered bound for both
identities. Five-point finite differences use the separate mixed bound
`5e-8 max(1, |analytic|, |numerical|)` and likewise retain raw and normalized
maxima.

This criterion belongs only to the new bounded experiment. It does not amend
the fixed absolute gate that terminated `RQ2-EDGE-FREEDOM-001`.

## 8. Interpretation limit

The derivation proves that equality removal is the only declared mathematical
difference between the two new arms. It does not prove that either arm is BP,
that equality freedom must improve recovery, or that this factor explains the
complete native BP-versus-projected-GD difference. Those are empirical and
larger causal questions outside this card.
