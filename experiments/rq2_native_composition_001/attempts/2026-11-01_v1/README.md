# Attempt `2026-11-01_v1`

Status: **terminal prelaunch freeze failure; this attempt must not be resumed.**

This was the first attempt for `RQ2-NATIVE-COMPOSITION-001`.  It fixed the
eleven-rung registry and the following seven-job order:

1. `01_switch_registry_gate`
2. `02_common_harness_gate`
3. `03_native_endpoint_and_rung_gate`
4. `04_fresh_dual_snr_anchor`
5. `05_six_db_forward_transfer`
6. `06_six_db_order_controls_and_attribution`
7. `07_second_snr_confirmation`

The immutable v1 freeze was built, but its empty-cache prelaunch validation
failed because the freeze omitted the LDPC helper input
`source/jade_project/tools/ldpc/src/randfile`.  The three archived LDPC helper
executables therefore did not constitute a self-contained frozen LDPC tool
directory when a fresh parity-check matrix had to be generated: `make-ldpc`
resolved its compiled-in relative input `src/randfile` from that directory and
reported `Can't open file of random numbers (src/randfile)`.  This is a
freeze-inventory failure, not a scientific result.

No queue was prepared or launched for v1.  No validation or scientific job
ran from the v1 freeze.  In particular, Jobs 1--7 produced no v1 evidence.
The immutable freeze and registered v1 configuration are retained untouched
as the failed prelaunch record; the missing source is repaired only in a new
v2 attempt.

## Attempt paths

- Freeze specification: `attempts/2026-11-01_v1/freeze_spec.toml`
- Planned immutable freeze: `freeze/2026-11-01_v1`
- Queue input: `attempts/2026-11-01_v1/queue.toml`
- Planned locked queue: `queue/2026-11-01_v1`
- Planned result root: `results/2026-11-01_v1`
- Planned detached unit:
  `sp-gd-rq2-native-composition-20261101-v1.service`

## Terminal disposition

Do not modify, rebuild, resume, queue, or launch v1.  The replacement attempt
is `attempts/2026-11-01_v2`, whose freeze specification adds the exact missing
`tools/ldpc/src/randfile` input.  V2 still requires a new final preflight
record after its complete source and queue test pass before its freeze can be
built.

The locked `30001:30200` cases appear only in Job 6 after the prospective 6 dB
transfer.  Job 6 must reproduce 107 native projected-GD recoveries, 200 native
exact-sum-product recoveries, and the retained net gap of 93 on those locked
cases.  Their ledger remains separate from the fresh cases, and their results
are descriptive.  Jobs 5--7 contain the fresh evidence; within Job 6, only the
`60025:60224` portion is prospective.
