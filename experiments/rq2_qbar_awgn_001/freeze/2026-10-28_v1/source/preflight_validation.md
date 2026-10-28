# BPGD-RQ2-QBAR-AWGN-001 preflight validation

Date: 2026-10-28 (Asia/Shanghai)

Command:

```text
JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 julia --project=/home/gabiel/Documents/GitHub/JadeJcade experiments/rq2_qbar_awgn_001/test_rq2_qbar_awgn_001.jl
```

The final pre-freeze execution passed 77 of 77 assertions in five test sets:

- registered design: 6/6;
- exact check kernel and categorical operations: 20/20;
- causal ordering, controls, stopping, and syndrome: 20/20;
- paired statistical fixtures: 7/7; and
- Jade graph, 24-frame full/native scratch-state equivalence, input freeze,
  retained-reference schema, deterministic snapshot, result writer, checksum,
  symlink, tamper, and non-overwrite gates: 24/24.

This is a preflight correctness record, not a decoding-performance result.  No
retained 24-frame tied-arm anchor or 200-frame held-out confirmation had been
executed when this record was written.  The input freeze and result manifests
hash this record and the executable test source.
