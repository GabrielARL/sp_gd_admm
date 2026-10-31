#!/usr/bin/env bash
set -Eeuo pipefail

umask 022

QUEUE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="/home/gabiel/Documents/GitHub/sp_gd_admm-rq1-gd-state-use-20261030"
EXPERIMENT_ROOT="$REPO_ROOT/experiments/rq2_gd_offset_split_001"
ATTEMPT_ROOT="$EXPERIMENT_ROOT/attempts/2026-10-31_v3/rq2_gd_offset_split_001"
PROJECT_ROOT="/home/gabiel/Documents/GitHub/JadeJcade-worktrees/awgn-jade-coral-20261012"
CONFIG="$ATTEMPT_ROOT/config.toml"
RUNNER="$ATTEMPT_ROOT/rq2_gd_offset_split_001.jl"
TEST="$ATTEMPT_ROOT/test_rq2_gd_offset_split_001.jl"
STATUS="$QUEUE_ROOT/status_report.py"
FREEZE="$EXPERIMENT_ROOT/freeze/2026-10-31_v3"
ANCHOR="$EXPERIMENT_ROOT/results/2026-10-31_anchor_v3"
HELDOUT="$EXPERIMENT_ROOT/results/2026-10-31_heldout_v3"
LOG_ROOT="$QUEUE_ROOT/logs"
JOBS_ROOT="$QUEUE_ROOT/jobs"
V2_UNIT="sp-gd-rq2-offset-split-v2-20261031.service"

export JULIA_NUM_THREADS=1
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

cd "$REPO_ROOT"

COMPLETED_JOBS=0
CURRENT_JOB=""
QUEUE_FINISHED=0
QUEUE_STARTED=0

acquire_queue_lock() {
    exec 9>"$QUEUE_ROOT/queue.lock"
    flock -n 9 || {
        printf 'another queue process holds %s\n' "$QUEUE_ROOT/queue.lock" >&2
        return 75
    }
}

check_queue_package() {
    (
        cd "$QUEUE_ROOT"
        sha256sum --strict --check QUEUE_MANIFEST.sha256
    ) || return $?
    python3 "$STATUS" assert-queue-lock --queue-root "$QUEUE_ROOT" || return $?
}

verify_queue_package() {
    (
        cd "$QUEUE_ROOT"
        sha256sum --strict --check QUEUE_MANIFEST.sha256
    ) || return $?
    python3 "$STATUS" assert-queue-lock --queue-root "$QUEUE_ROOT" \
        --require-record || return $?
}

run_with_wall_budget() {
    local budget=$1
    shift
    local termination_grace=120
    local term_after

    (( budget > termination_grace )) || {
        printf 'registered wall budget %s must exceed %s-second termination grace\n' \
            "$budget" "$termination_grace" >&2
        return 2
    }
    term_after=$((budget - termination_grace))
    printf 'TERM after %s seconds; KILL no later than the registered %s-second wall budget\n' \
        "$term_after" "$budget"
    timeout --signal=TERM --kill-after="${termination_grace}s" "${term_after}s" "$@"
}

assert_v2_inactive() {
    local state
    local main_pid
    if ! state="$(systemctl --user show "$V2_UNIT" \
        --property=ActiveState --value)"; then
        printf 'cannot determine the v2 unit state; refusing v3 launch\n' >&2
        return 2
    fi
    if ! main_pid="$(systemctl --user show "$V2_UNIT" \
        --property=MainPID --value)"; then
        printf 'cannot determine the v2 unit PID; refusing v3 launch\n' >&2
        return 2
    fi
    if [[ "$state" != "inactive" && "$state" != "failed" ]] ||
       [[ "$main_pid" != "0" ]]; then
        printf 'v2 is not terminal: state=%s MainPID=%s; the v3 queue never signals it\n' \
            "${state:-unknown}" "${main_pid:-unknown}" >&2
        return 2
    fi
}

queue_update() {
    python3 "$STATUS" update-queue \
        --queue-root "$QUEUE_ROOT" \
        --state "$1" \
        --job-id "$2" \
        --job-state "$3" \
        --completed "$4" \
        --exit-code "$5" \
        --detail "$6"
}

queue_marker() {
    python3 "$STATUS" write-marker \
        --queue-root "$QUEUE_ROOT" \
        --job-id "$1" \
        --state "$2" \
        --exit-code "$3" \
        --detail "$4"
}

on_exit() {
    local exit_code=$?
    if [[ "$exit_code" -ne 0 && "$QUEUE_STARTED" -eq 1 && \
          "$QUEUE_FINISHED" -eq 0 ]]; then
        if [[ -n "$CURRENT_JOB" && \
              ! -e "$JOBS_ROOT/$CURRENT_JOB/COMPLETED.toml" && \
              ! -e "$JOBS_ROOT/$CURRENT_JOB/FAILED.toml" ]]; then
            queue_marker "$CURRENT_JOB" failed "$exit_code" \
                "queue stopped during $CURRENT_JOB" || true
        fi
        queue_update "failed" "$CURRENT_JOB" "failed" "$COMPLETED_JOBS" \
            "$exit_code" "queue stopped after a failed job" || true
        python3 "$STATUS" queue-terminal \
            --queue-root "$QUEUE_ROOT" \
            --state failed \
            --exit-code "$exit_code" \
            --detail "queue stopped after $CURRENT_JOB" || true
    fi
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

run_job() {
    local job_id=$1
    local title=$2
    local function_name=$3
    local log_path="$LOG_ROOT/$job_id.log"
    local exit_code

    CURRENT_JOB="$job_id"
    verify_queue_package || return $?
    queue_marker "$job_id" started 0 "$title" || return $?
    queue_update running "$job_id" running "$COMPLETED_JOBS" -1 "$title" || return $?
    printf '%s starting %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_id" "$title"

    if { "$function_name" && verify_queue_package; } >"$log_path" 2>&1; then
        COMPLETED_JOBS=$((COMPLETED_JOBS + 1))
        queue_marker "$job_id" complete 0 "$title" || return $?
        queue_update running "$job_id" complete "$COMPLETED_JOBS" 0 "$title" || return $?
        printf '%s completed %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_id"
        return 0
    else
        exit_code=$?
        queue_marker "$job_id" failed "$exit_code" "$title" || \
            printf 'warning: failed to write %s terminal marker\n' "$job_id" >&2
        queue_update failed "$job_id" failed "$COMPLETED_JOBS" \
            "$exit_code" "$title" || \
            printf 'warning: failed to write %s queue status\n' "$job_id" >&2
        printf '%s failed %s with exit code %s; see %s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_id" "$exit_code" "$log_path" >&2
        return "$exit_code"
    fi
}

job_j01() {
    assert_v2_inactive || return $?
    printf 'Verifying RQ2-OPTIMIZE-001, preflight, freeze, and one-off anchor\n'
    python3 "$STATUS" assert-optimization --queue-root "$QUEUE_ROOT" || return $?
    python3 "$STATUS" assert-preflight --queue-root "$QUEUE_ROOT" || return $?
    julia --startup-file=no --depwarn=error --project="$PROJECT_ROOT" \
        "$RUNNER" preflight-probe --config "$CONFIG" || return $?
    python3 "$STATUS" assert-freeze --freeze "$FREEZE" \
        --expected-input-sha256 \
        739da19436f5f3371333ad04585be4c9cd934506c9a66892776b146105b5a5bd \
        || return $?
    python3 "$STATUS" assert-result --result "$ANCHOR" --stage anchor \
        --require-expansion --expected-science-sha256 \
        2062fce292d4b41cf93c6dd86afdb6855345b52ff1408d9c89c7318e25b20d46 \
        || return $?
    python3 "$STATUS" assert-budget --queue-root "$QUEUE_ROOT" || return $?
    printf 'The v3 anchor is an implementation-equivalence gate, not new evidence\n'
    printf 'No endpoint direction is used as an expansion gate\n'
}

job_j02() {
    local budget
    assert_v2_inactive || return $?
    budget="$(python3 "$STATUS" get-budget --queue-root "$QUEUE_ROOT" --stage heldout)" || return $?
    printf 'Running held-out set with wall budget %s seconds\n' "$budget"
    run_with_wall_budget "$budget" \
        julia --startup-file=no --depwarn=error --project="$PROJECT_ROOT" \
        "$RUNNER" heldout --config "$CONFIG" --freeze "$FREEZE" \
        --anchor-result "$ANCHOR" --output "$HELDOUT"
}

job_j03() {
    printf 'Verifying held-out embedded replay record and checksums\n'
    python3 "$STATUS" assert-result --result "$HELDOUT" --stage heldout || return $?
    python3 "$STATUS" write-final --queue-root "$QUEUE_ROOT" \
        --anchor "$ANCHOR" --heldout "$HELDOUT" || return $?
}

main() {
    local required
    acquire_queue_lock || return $?
    for required in "$CONFIG" "$RUNNER" "$TEST" "$STATUS" \
                    "$QUEUE_ROOT/derive_budget.py" \
                    "$QUEUE_ROOT/budget_derivation.toml" \
                    "$QUEUE_ROOT/queue.toml" "$QUEUE_ROOT/README.md" \
                    "$QUEUE_ROOT/run_anchor_once.sh" \
                    "$QUEUE_ROOT/QUEUE_MANIFEST.sha256"; do
        [[ -f "$required" ]] || {
            printf 'required file is missing: %s\n' "$required" >&2
            return 2
        }
    done
    [[ ! -e "$QUEUE_ROOT/progress.toml" ]] || {
        printf 'queue progress already exists; refusing a second launch\n' >&2
        return 2
    }
    [[ ! -e "$QUEUE_ROOT/QUEUE_COMPLETED.toml" && \
       ! -e "$QUEUE_ROOT/QUEUE_FAILED.toml" ]] || {
        printf 'a terminal queue marker already exists; refusing a second launch\n' >&2
        return 2
    }
    for required in "$FREEZE" "$ANCHOR"; do
        [[ -d "$required" ]] || {
            printf 'required v3 predecessor is missing: %s\n' "$required" >&2
            return 2
        }
    done
    [[ ! -e "$HELDOUT" ]] || {
        printf 'registered held-out output already exists; refusing overwrite: %s\n' "$HELDOUT" >&2
        return 2
    }

    # The controller stops v2 only after reporting exact anchor equality.
    # This queue is deliberately fail-closed and never signals v2 itself.
    assert_v2_inactive || return $?

    mkdir -p "$LOG_ROOT" "$JOBS_ROOT" || return $?
    check_queue_package || return $?
    QUEUE_STARTED=1
    python3 "$STATUS" lock-queue-package --queue-root "$QUEUE_ROOT" || return $?
    verify_queue_package || return $?
    queue_update running "" queued 0 -1 "serial queue initialized" || return $?

    run_job J01 "V3 source, freeze, anchor-equality, checkpoint, phase, and budget gates" job_j01 || return $?
    run_job J02 "Four-arm 200-case v3 held-out execution" job_j02 || return $?
    run_job J03 "Held-out replay/checkpoint/checksum and final summary" job_j03 || return $?

    CURRENT_JOB=""
    verify_queue_package || return $?
    queue_update complete "" complete "$COMPLETED_JOBS" 0 \
        "all three jobs completed" || return $?
    python3 "$STATUS" queue-terminal \
        --queue-root "$QUEUE_ROOT" \
        --state complete \
        --exit-code 0 \
        --detail "all three jobs completed" || return $?
    QUEUE_FINISHED=1
    printf '%s queue complete\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

main "$@"
