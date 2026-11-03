# Tied scalar-to-edge reproduction gate

This directory implements the preregistered correctness gate in
`experiment_card.md`. It reproduces the retained
`assigned_frozen_product_unconstrained` endpoint using authoritative, exactly
tied values stored on Tanner-graph check--bit connections.

The gate uses retained frames `20001:20024` only. It produces no new BER or
decoder-ranking evidence and cannot launch an edge-freedom treatment.

Run the unit tests with the frozen native-composition Julia project:

```sh
JULIA_NUM_THREADS=1 OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 \
  julia --threads=1 --startup-file=no --project=../rq2_native_composition_001/freeze/2026-11-01_v2/source/jade_project \
  test_rq2_tied_scalar_edge_repro_001.jl
```

The scientific queue is built from `attempts/2026-11-03_v1/` and refuses to
overwrite an existing freeze, queue, or result directory.
