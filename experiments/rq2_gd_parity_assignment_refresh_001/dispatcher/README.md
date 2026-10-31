# Safe conditional dispatcher for steps 1--5

This directory contains the approved, single-attempt dispatcher for
`RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001`. It does exactly five things:

1. watches the existing v3 service with read-only `systemctl --user show`;
2. after v3 is inactive, requires every registered terminal file, runs the
   hash-pinned v3 result checker, and binds the decision to the exact result
   files;
3. applies the registered rule: `objective1__bounds0` must have more paired
   treatment-only successes than `objective0__bounds0` has reference-only
   successes for both transmitted-word equality and parity validity;
4. only if that rule passes, runs the prepared assignment-by-replacement
   factorial in order: preflight, freeze, 24-case anchor, budget/package lock,
   200-case prospective transfer, then 200-case locked attribution; and
5. retains a hash-bound bridge handoff and stops. It does not choose or launch
   a later BP--projected-GD bridge.

The scientific purpose is narrow. The v3 rule decides whether the
parity-calculation branch transferred beyond its development anchor. The
factorial then separates correct check assignment, repeated replacement of the
constructed offsets, and their interaction while every arm keeps the native
`[-1,1]` projection interval. The result can identify the next mechanism to
register; it cannot by itself explain the full native BP performance gap.

## Attempt history

### Retained failed controller attempt

- Controller unit: `rq2-followup-controller-20261031.service`
- Configuration: `controller_2026-10-31_v1.toml`
- Controller state: `../controller/2026-10-31_v1/`
- Intended factorial attempt: `2026-10-31_v1`
- Outcome: Julia preflight failed before freeze and before any registered
  endpoint calculation.

### Retained failed freeze attempt

- Controller unit: `rq2-followup-controller-20261101-v2.service`
- Configuration: `controller_2026-11-01_v2.toml`
- Controller state: `../controller/2026-11-01_v2/`
- Factorial attempt: `2026-11-01_v2`
- Preflight: `../preflight/2026-11-01_v2/preflight_validation.md`
- Outcome: preflight passed, then source enumeration stopped during freeze
  before a freeze manifest, scientific service, or endpoint calculation.

### Registered operational retry

- Controller unit: `rq2-followup-controller-20261101-v3.service`
- Configuration: `controller_2026-11-01_v3.toml`
- Controller state: `../controller/2026-11-01_v3/`
- Factorial attempt: `2026-11-01_v3`
- Preflight: `../preflight/2026-11-01_v3/preflight_validation.md`
- Anchor unit:
  `sp-gd-rq2-parity-assignment-refresh-anchor-20261031.service`
- Serial transfer-plus-attribution unit:
  `sp-gd-rq2-parity-assignment-refresh-20261031.service`

The controller has no automatic-resume path. Any durable controller state or
any existing freeze, result, queue, or bridge-handoff path makes the attempt
fail closed. A failed or interrupted scientific attempt requires a new attempt
ID and new scientific unit names. An operational failure before any scientific
unit is launched may retain the unlaunched registered scientific unit names,
provided their absence and the absence of all scientific results are verified
and recorded.

The delayed dispatcher programs are SHA-256 pinned in the production
configuration and rechecked immediately before successor execution. Each
attempt receives its own preflight record. The preflight independently
rechecks the complete v3 result and runs the Julia, budget, and
queue-governance suites. A passed record belongs only to its attempt and is
bound into that attempt's freeze; a failed record is final. The frozen wrappers
then recheck the source, inputs, preflight, anchor, budgets, queue package, job
order, and result manifests. Both scientific stages require their two passes
to have the same canonical hash.

## Terminal outcomes

- `UNSELECTED.toml`: v3 completed validly, but the registered two-endpoint rule
  did not pass. No factorial path is created.
- `FAILED.toml`: a prerequisite, hash, test, unit, budget, result, or inventory
  gate failed. No automatic retry occurs.
- `SELECTED.toml`: the v3 rule passed and the complete registered factorial
  pipeline finished validly.
- `BRIDGE_REGISTRATION_REQUIRED.toml`: exact factorial evidence is retained,
  `automatic_bridge_launch_allowed = false`, and the next bridge must receive
  its own card, runner, tests, freeze, valid anchor, and manifest.

The controller's `progress.toml`, `status_history.tsv`, and `logs/pipeline.log`
provide durable observation. The factorial queue has its own progress, phase,
and job records. Reading these files or using `systemctl --user show` is safe;
do not start a second copy of this attempt.
