# Invalidated pilot — excluded from evidence

Validity status: **invalidated before interpretation**.

This pilot used the numerical vector
`(-ln(9), ln(3/2), ln(2))` while declaring the opposite LLR sign convention
from `RQ1-STATE-002`. That mismatch changes the hard-decision interpretation
and prevents this run from serving as evidence for the approved controlled
comparison.

The JSON files and their hashes are retained unchanged for auditability. Do not
use any trajectory, hard decision, syndrome, factorial contrast, or
classification in this directory as evidence. The corrected run uses
`L = ln(P(1)/P(0))`, for which a positive LLR favors bit 1, and includes an
explicit complete-sign-transform invariance gate.
