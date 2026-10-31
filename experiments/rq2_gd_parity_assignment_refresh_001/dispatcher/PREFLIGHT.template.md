# Preflight record for `RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001`

validation_status: not_run
validated_utc: pending
test_exit_code: pending
test_assertions_passed: pending
test_assertions_total: pending
budget_test_exit_code: pending
budget_tests_passed: pending
budget_tests_total: pending
queue_test_exit_code: pending
queue_tests_passed: pending
queue_tests_total: pending
prerequisite_evidence_sha256: pending
config_sha256: pending
card_sha256: pending
runner_sha256: pending
test_sha256: pending
budget_tool_sha256: pending
budget_test_sha256: pending
queue_status_sha256: pending
queue_lock_tool_sha256: pending
anchor_wrapper_sha256: pending
queue_wrapper_sha256: pending
queue_template_sha256: pending
queue_readme_template_sha256: pending
queue_test_sha256: pending
split_runner_sha256: pending
legacy_runner_sha256: pending
registered_endpoint_frames_executed_during_preflight: 0

This is an attempt-local, initially unexecuted record. The dispatcher creates
it exclusively for one attempt, the preflight builder finalizes it once, and
the freeze binds its exact absolute source path and SHA-256 digest. A failed
record is final and cannot be reset, overwritten, or reused by another
attempt.

The preflight performs no registered endpoint calculation. It first verifies
the checksum-bound Offset Split v3 selection evidence, then runs the Julia,
budget, and queue-governance test suites with one Julia, BLAS, and OpenMP
thread. Only a passed record permits the attempt's freeze to be created.

The retained root `preflight_validation.md` is the final failed record from
attempt v1. It is historical evidence and is never the input to a later
attempt.
