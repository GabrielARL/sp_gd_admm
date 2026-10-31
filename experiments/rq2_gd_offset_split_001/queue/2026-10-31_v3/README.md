# RQ2-OPTIMIZE-001 v3 execution package

This directory governs the v3 implementation/observability successor of
`RQ2-GD-OFFSET-SPLIT-001`.  V1 and v2 remain immutable.  V3 uses the isolated
source capsule at
`experiments/rq2_gd_offset_split_001/attempts/2026-10-31_v3`.

The anchor is run once, concurrently with the still-active single-threaded v2
hash phase, by `run_anchor_once.sh` in the transient unit
`sp-gd-rq2-offset-split-v3-anchor-20261031.service`.  This is deliberately a
one-off anchor rather than the held-out queue, because the held-out wall budget
must be derived from the completed anchor before the queue package is locked.
The first corrected runtime sample showed that the inherited 1,680-second
anchor `TERM` deadline would fire before completion.  With no science artifact
yet written, the anchor-only wrapper was prospectively changed to `TERM` after
3,480 seconds and hard termination no later than 3,600 seconds.  This does not
change the held-out derivation below.

After exact anchor equality is reported and the controller stops v2, the
locked held-out queue is launched as
`sp-gd-rq2-offset-split-v3-20261031.service`.  Its pinned launch command is:

```text
systemd-run --user --unit=sp-gd-rq2-offset-split-v3-20261031.service \
  --property=WorkingDirectory=/home/gabiel/Documents/GitHub/sp_gd_admm-rq1-gd-state-use-20261030 \
  --property=Environment=JULIA_NUM_THREADS=1 \
  --property=Environment=OMP_NUM_THREADS=1 \
  --property=Environment=OPENBLAS_NUM_THREADS=1 \
  --property=Nice=5 --property=Restart=no \
  --property=KillMode=control-group --property=TimeoutStopSec=120 \
  --property=StandardOutput=append:/home/gabiel/Documents/GitHub/sp_gd_admm-rq1-gd-state-use-20261030/experiments/rq2_gd_offset_split_001/queue/2026-10-31_v3/queue.log \
  --property=StandardError=append:/home/gabiel/Documents/GitHub/sp_gd_admm-rq1-gd-state-use-20261030/experiments/rq2_gd_offset_split_001/queue/2026-10-31_v3/queue.log \
  /usr/bin/bash /home/gabiel/Documents/GitHub/sp_gd_admm-rq1-gd-state-use-20261030/experiments/rq2_gd_offset_split_001/queue/2026-10-31_v3/run_queue.sh
```

The preregistered derivation is:

```text
F = (primary frame_loop seconds + replay frame_loop seconds) / (24 * 2)
P24 = sum of measured post-loop phase seconds across both anchor passes,
      plus primary_checkpoint and write_result
E200 = F * 200 * 2 + P24 * (200 / 24)
B = ceil(1.5 * E200)
```

`B` is the held-out queue wall budget.  The queue sends `TERM` 120 seconds
before `B` and reserves those 120 seconds for termination.  `B` may not exceed
the frozen 36,000-second safety cap.  The anchor has no held-out bootstrap, so
this projection retains that limitation explicitly.

The numerical inputs and final budget fields below are populated from the
locked v3 anchor `phase_log.tsv` only after the completed anchor
`science.json` equals the registered v1/v2 SHA-256
`2062fce292d4b41cf93c6dd86afdb6855345b52ff1408d9c89c7318e25b20d46`.
The held-out queue package is not locked or launched before that gate.

## Derived values

- anchor science SHA-256: `2062fce292d4b41cf93c6dd86afdb6855345b52ff1408d9c89c7318e25b20d46`
- phase-log SHA-256: `3daae9cd3da0e11a908c8a8955030deb35535c4e114569e726816976f626fba1`
- primary frame-loop: `903.035652858` seconds
- replay frame-loop: `449.370550596` seconds
- anchor seconds per frame per pass: `28.175129238625`
- primary iteration-table hash: `0.222612771` seconds
- replay iteration-table hash: `0.257836261` seconds
- total iteration-table hash: `0.480449032` seconds
- anchor post-loop total: `15.515547608` seconds
- projected 200-frame frame-loop: `11270.051695450` seconds
- projected 200-frame post-loop: `129.296230067` seconds
- projected held-out wall time before safety: `11399.347925517` seconds
- safety factor: `1.5`
- absolute safety cap: `36000` seconds
- held-out wall budget: `17100` seconds
- TERM after: `16980` seconds

The numerical substitution is

```text
F = (903.035652858 + 449.370550596) / (24 * 2)
  = 28.175129238625 seconds per frame per pass
P24 = 15.515547608 seconds
E200 = F * 200 * 2 + P24 * (200 / 24)
     = 11399.347925517 seconds
B = ceil(1.5 * E200) = 17100 seconds
TERM = B - 120 = 16980 seconds
```

