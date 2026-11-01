# Attempt `2026-11-01_v2`

Status: **immutable seven-job queue launched at `2026-11-01T13:31:54Z`.**

This replacement attempt preserves the eleven-rung registry and the fixed
seven-job order:

1. `01_switch_registry_gate`
2. `02_common_harness_gate`
3. `03_native_endpoint_and_rung_gate`
4. `04_fresh_dual_snr_anchor`
5. `05_six_db_forward_transfer`
6. `06_six_db_order_controls_and_attribution`
7. `07_second_snr_confirmation`

V1 terminated before queue preparation because its immutable freeze omitted
`source/jade_project/tools/ldpc/src/randfile`.  V2 adds that exact LDPC helper
input alongside `make-ldpc`, `make-gen`, and `print-pchk`; all other scientific
sources and the seven-job contract remain unchanged.

## Attempt paths

- Freeze specification: `attempts/2026-11-01_v2/freeze_spec.toml`
- Planned immutable freeze: `freeze/2026-11-01_v2`
- Queue input: `attempts/2026-11-01_v2/queue.toml`
- Planned locked queue: `queue/2026-11-01_v2`
- Planned result root: `results/2026-11-01_v2`
- Planned detached unit:
  `sp-gd-rq2-native-composition-20261101-v2.service`

## Launch record

The final preflight binds the exact sources that passed 105/105 Julia tests
and 17/17 Python queue tests.  The immutable v2 freeze contains all four LDPC
runtime inputs.  Before launch, frozen Job 3 was run against an empty temporary
cache: it rebuilt the LDPC artifacts, completed all 24 endpoint cases and the
replay, and passed the hardened result verifier with science hash
`6f7039e1172a81f4e6e641d6aaf9a0554b66ab856689ad2009d2188fc04a34eb`.
That temporary validation is not campaign evidence; the official queue reruns
Job 3.

The locked queue launched as
`sp-gd-rq2-native-composition-20261101-v2.service`.  Durable status is in
`queue/2026-11-01_v2/progress.toml` and `queue.log`; outputs are written under
`results/2026-11-01_v2/`.  Automatic restart, resume, and overwrite remain
disabled.  A failed or interrupted immutable job requires another attempt ID.

The locked `30001:30200` cases appear only in Job 6 after the prospective 6 dB
transfer.  Job 6 must reproduce 107 native projected-GD recoveries, 200 native
exact-sum-product recoveries, and the retained net gap of 93 on those locked
cases.  Their ledger remains separate from the fresh cases, and their results
are descriptive.  Jobs 5--7 contain the fresh evidence; within Job 6, only the
`60025:60224` portion is prospective.
