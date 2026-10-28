# Interrupted held-out attempt

- Experiment: `BPGD-RQ2-QBAR-AWGN-001`
- Intended phase: 200-frame held-out confirmation
- Output directory: `results/2026-10-28_heldout_v1`
- Start: approximately `2026-10-28T14:53:17+08:00`
- Interruption: approximately `2026-10-28T15:18:47+08:00`, after about 26 minutes
- Termination: intentional `SIGINT` (signal 2), process exit code 1, sent at the user's explicit request to stop

## Exact command

```text
JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 julia --project=/home/gabiel/Documents/GitHub/JadeJcade experiments/rq2_qbar_awgn_001/rq2_qbar_awgn_001.jl heldout --freeze /home/gabiel/Documents/GitHub/sp_gd_admm/experiments/rq2_qbar_awgn_001/freeze/2026-10-28_v2 --anchor-result /home/gabiel/Documents/GitHub/sp_gd_admm/experiments/rq2_qbar_awgn_001/results/2026-10-28_anchor_v2 --output /home/gabiel/Documents/GitHub/sp_gd_admm/experiments/rq2_qbar_awgn_001/results/2026-10-28_heldout_v1
```

## State at interruption

The observed stack was inside `native_phase_preflight`, through `native_decode` and JadeJcade's exact sum-product `_bp_check_sum_product!` kernel. The runner writes the retained result atomically at the end of the phase. It had emitted no `frames.csv`, endpoint table, `science.json`, `manifest.toml`, `COMPLETED.toml`, or checksum manifest before the signal.

Therefore this directory is an interrupted-attempt record, not a valid held-out result. No held-out frame outcomes were retained or exposed, and no endpoint flag may be interpreted from this attempt. The registered 200-frame confirmation remains incomplete.
