# Attempt `2026-11-01_v1`

Status: **official freeze built and queue package locked; dependency controller
armed; scientific successor not yet launched.**

This four-job successor runs only after the frozen native-composition campaign
finishes successfully:

1. `01_validation_reproduction_gate` — 24 retained validation cases;
2. `02_fresh_dual_snr_anchor` — 48 fresh cases and the timing anchor;
3. `03_six_db_transfer` — 200 fresh 6 dB cases;
4. `04_second_snr_confirmation` — 200 fresh 1.5 dB cases.

Every case runs four registered arms in fixed order:
`true_gradient__armijo`, `map_minus_state__armijo`,
`true_gradient__unit`, and `map_minus_state__unit`. Each job performs a
primary pass and deterministic replay. Jobs 3 and 4 receive wall budgets
derived from Job 2's measured seconds per case-arm and write the derivation
under `queue/2026-11-01_v1/budgets/` with safety factor 1.5.

The immutable freeze copies the complete verified predecessor v2 payload
without its old top-level manifest metadata, then adds this experiment under
`rq2_exact_map_update_001/`. It never mutates or overwrites the predecessor.

The preflight records 80 passing runner unit checks reported for the final
source, 16 passing queue-controller tests, official static freeze validation,
and candidate-to-official scientific-source hash equivalence. The final
preflight is checksum-bound in `queue.toml`; the official freeze and locked
queue must never be edited. Any later validation failure invalidates v1 and
requires a new attempt.

No full-frame decoder result is part of preflight while the predecessor owns
the global scientific lock. The queued validation-only Job 1 is the mandatory
end-to-end 24-case primary/replay gate. The fail-closed controller cannot start
Jobs 2--4 unless Job 1 completes and its artifacts pass verification.

The non-scientific dependency controller launched at
`2026-11-01T14:43:30Z` as
`rq2-exact-map-update-controller-20261101-v1.service`. It waits read-only for
the native-composition v2 service, then requires its locked completion,
progress, freeze, preflight, and all seven results to validate before invoking
`sp-gd-rq2-exact-map-update-20261101-v1.service` exactly once. Controller
telemetry is under `dispatcher/state/2026-11-01_v1/`.
