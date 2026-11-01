# Attempt 2026-11-01_v1

This is the first immutable execution package for
`RQ2-CAUSAL-FACTORS-001`.  It runs Block A completely before Block B.  Within
each block the order is retained calibration, fresh anchor, prospective fresh
transfer, then informed attribution.

The exact calibration and attribution endpoint expectations are recorded in
`endpoint_expectations.toml`.  Fresh-anchor and fresh-transfer outcomes are
not preregistered; they are admitted only by replay and endpoint-sentinel
self-consistency gates.

## Immutable and mutable paths

- Source freeze: `experiments/rq2_causal_factors_001/freeze/2026-11-01_v1`
- Filled freeze specification: `freeze_spec.toml`
- Filled queue configuration: `queue.toml`
- Locked queue package: `experiments/rq2_causal_factors_001/queue/2026-11-01_v1`
- Result parent: `experiments/rq2_causal_factors_001/results/2026-11-01_v1`
- Detached user unit: `sp-gd-rq2-causal-factors-20261101-v1.service`

The queue is single-use and fail-closed.  A failed or interrupted attempt is
retained and requires a new attempt identifier; it is not resumed or
overwritten.

## Launch command

Run only after the queue package passes `campaign_queue.py verify` and
`campaign_queue.py prelaunch`:

```sh
/home/gabiel/Documents/GitHub/sp_gd_admm-rq2-bp-gd-causal-ladder-20261101/experiments/rq2_causal_factors_001/queue/2026-11-01_v1/launch_detached.sh /home/gabiel/Documents/GitHub/sp_gd_admm-rq2-bp-gd-causal-ladder-20261101/experiments/rq2_causal_factors_001/queue/2026-11-01_v1
```

The durable status files are `progress.toml`, `queue.log`,
`status_history.tsv`, and `phase_log.tsv` in the locked queue package.
