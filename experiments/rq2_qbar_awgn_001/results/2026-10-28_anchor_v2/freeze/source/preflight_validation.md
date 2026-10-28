# BPGD-RQ2-QBAR-AWGN-001 preflight validation

Date: 2026-10-28 (Asia/Shanghai)

Command:

```text
JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 julia --project=/home/gabiel/Documents/GitHub/JadeJcade experiments/rq2_qbar_awgn_001/test_rq2_qbar_awgn_001.jl
```

The final v2 pre-freeze execution passed 85 of 85 assertions in six test sets:

- registered design: 6/6;
- canonical integer-key snapshot serialization and tamper sensitivity: 6/6;
- exact check kernel and categorical operations: 20/20;
- causal ordering, controls, stopping, and syndrome: 20/20;
- paired statistical fixtures: 7/7; and
- Jade graph, 24-frame full/native scratch-state equivalence, input freeze,
  retained-reference schema, deterministic snapshot, result writer, checksum,
  symlink, tamper, and non-overwrite gates: 26/26.

This is a preflight correctness record, not a decoding-performance result.  No
retained valid 24-frame tied-arm anchor or 200-frame held-out confirmation had
been executed when this v2 record was written.  Anchor v1 was invalidated by a
pre-outcome integer-key serialization error and exposed no frame outcomes.  The
v2 input freeze and result manifests hash this record and the executable test
source.
