# Shared edge-value trajectory reproduction gate

This directory implements the validation-only gate registered in
`experiment_card.md`. It tests whether native projected GD and native exact
sum-product BP can each be reproduced while their persistent state is exposed
as values in `[-1,1]` stored on Tanner-graph edges.

The two meanings remain distinct: GD stores tied copies of its one scalar per
bit, while BP stores recipient-specific transformed variable-to-check
messages. Both parity/check calculations actively read the stored edge values.

Only retained frames `20001:20024` may be evaluated. The job creates no new BER
or FER evidence, makes no equal-work claim, and cannot launch a downstream
ladder arm.

Run the toy and source-gate tests with the frozen native-composition project:

```sh
JULIA_NUM_THREADS=1 OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 \
  julia --threads=1 --startup-file=no --history-file=no \
  --project=../rq2_native_composition_001/freeze/2026-11-01_v2/source/jade_project \
  test_rq2_common_coordinate_repro_001.jl
```

The scientific runner refuses to overwrite an output directory, writes the
primary checkpoint before replay, preserves the first exact mismatch, and
marks any failed gate `complete_invalid`. Scientific mode also refuses to run
from the live worktree: it verifies this study's immutable root manifest and
must be launched from the built freeze.

Raw GD line-search proposals are compared as scalar diagnostics. Only the
box-projected proposals enter the bounded edge-value interface; each projected
proposal is copied to its incident edges and collapsed back exactly before its
objective is evaluated.
