#!/usr/bin/env bash
set -Eeuo pipefail

umask 022

QUEUE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="/home/gabiel/Documents/GitHub/sp_gd_admm-rq1-gd-state-use-20261030"
EXPERIMENT_ROOT="$REPO_ROOT/experiments/rq2_gd_offset_split_001"
PROJECT_ROOT="/home/gabiel/Documents/GitHub/JadeJcade-worktrees/awgn-jade-coral-20261012"
CONFIG="$EXPERIMENT_ROOT/config.toml"
RUNNER="$EXPERIMENT_ROOT/rq2_gd_offset_split_001.jl"
TEST="$EXPERIMENT_ROOT/test_rq2_gd_offset_split_001.jl"
STATUS="$QUEUE_ROOT/status_report.py"
FREEZE="$EXPERIMENT_ROOT/freeze/2026-10-31_v2"
ANCHOR="$EXPERIMENT_ROOT/results/2026-10-31_anchor_v2"
HELDOUT="$EXPERIMENT_ROOT/results/2026-10-31_heldout_v2"
LOG_ROOT="$QUEUE_ROOT/logs"
JOBS_ROOT="$QUEUE_ROOT/jobs"
CONFLICT_UNIT="sp-gd-claude-controls-20261031.service"

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

wait_for_external_scientific_queue() {
    local poll_seconds=60
    local detail
    if ! systemctl --user is-active --quiet "$CONFLICT_UNIT"; then
        return 0
    fi
    detail="waiting for existing scientific workload $CONFLICT_UNIT"
    queue_update waiting "" waiting "$COMPLETED_JOBS" -1 "$detail" || return $?
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$detail"
    while systemctl --user is-active --quiet "$CONFLICT_UNIT"; do
        sleep "$poll_seconds"
        queue_update waiting "" waiting "$COMPLETED_JOBS" -1 "$detail" || return $?
    done
    printf '%s external scientific workload is terminal; starting v2 jobs\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
    printf 'Verifying the prospective cap-only amendment and preserved v1 evidence\n'
    python3 "$STATUS" assert-amendment --queue-root "$QUEUE_ROOT" || return $?
    printf 'Running focused tests\n'
    julia --startup-file=no --depwarn=error --project="$PROJECT_ROOT" "$TEST" || return $?
    printf 'Verifying locked preflight record and retained source gate\n'
    python3 "$STATUS" assert-preflight --queue-root "$QUEUE_ROOT" || return $?
    julia --startup-file=no --depwarn=error --project="$PROJECT_ROOT" \
        "$RUNNER" preflight-probe --config "$CONFIG" || return $?
    printf 'Freezing the registered source and 224 input identities\n'
    julia --startup-file=no --depwarn=error --project="$PROJECT_ROOT" \
        "$RUNNER" freeze --config "$CONFIG" --output "$FREEZE" || return $?
    python3 "$STATUS" assert-freeze --freeze "$FREEZE" \
        --expected-input-sha256 \
        739da19436f5f3371333ad04585be4c9cd934506c9a66892776b146105b5a5bd \
        || return $?
}

job_j02() {
    local budget
    budget="$(python3 "$STATUS" get-budget --queue-root "$QUEUE_ROOT" --stage anchor)" || return $?
    printf 'Running anchor with wall budget %s seconds\n' "$budget"
    run_with_wall_budget "$budget" \
        julia --startup-file=no --depwarn=error --project="$PROJECT_ROOT" \
        "$RUNNER" anchor --config "$CONFIG" --freeze "$FREEZE" --output "$ANCHOR"
}

job_j03() {
    printf 'Verifying anchor embedded replay record, correctness, and checksums\n'
    python3 "$STATUS" assert-result --result "$ANCHOR" --stage anchor \
        --require-expansion --expected-science-sha256 \
        2062fce292d4b41cf93c6dd86afdb6855345b52ff1408d9c89c7318e25b20d46 \
        || return $?
    printf 'The v2 anchor is a provenance rebind and is not pooled as new evidence\n'
    printf 'No endpoint direction is used as an expansion gate\n'
}

job_j04() {
    local budget
    budget="$(python3 "$STATUS" get-budget --queue-root "$QUEUE_ROOT" --stage heldout)" || return $?
    printf 'Running held-out set with wall budget %s seconds\n' "$budget"
    run_with_wall_budget "$budget" \
        julia --startup-file=no --depwarn=error --project="$PROJECT_ROOT" \
        "$RUNNER" heldout --config "$CONFIG" --freeze "$FREEZE" \
        --anchor-result "$ANCHOR" --output "$HELDOUT"
}

job_j05() {
    printf 'Verifying held-out embedded replay record and checksums\n'
    python3 "$STATUS" assert-result --result "$HELDOUT" --stage heldout || return $?
    python3 "$STATUS" write-final --queue-root "$QUEUE_ROOT" \
        --anchor "$ANCHOR" --heldout "$HELDOUT" || return $?
}

main() {
    local required
    acquire_queue_lock || return $?
    for required in "$CONFIG" "$RUNNER" "$TEST" "$STATUS" \
                    "$QUEUE_ROOT/queue.toml" "$QUEUE_ROOT/README.md" \
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
    for required in "$FREEZE" "$ANCHOR" "$HELDOUT"; do
        [[ ! -e "$required" ]] || {
            printf 'registered output already exists; refusing overwrite: %s\n' "$required" >&2
            return 2
        }
    done

    mkdir -p "$LOG_ROOT" "$JOBS_ROOT" || return $?
    check_queue_package || return $?
    QUEUE_STARTED=1
    python3 "$STATUS" lock-queue-package --queue-root "$QUEUE_ROOT" || return $?
    verify_queue_package || return $?
    wait_for_external_scientific_queue || return $?
    queue_update running "" queued 0 -1 "serial queue initialized" || return $?

    run_job J01 "Amendment whitelist, focused tests, preflight, and v2 freeze" job_j01 || return $?
    run_job J02 "Four-arm 24-case v2 anchor provenance rebind" job_j02 || return $?
    run_job J03 "Anchor replay/correctness/checksum and v1-science equality gate" job_j03 || return $?
    run_job J04 "Four-arm 200-case held-out execution" job_j04 || return $?
    run_job J05 "Held-out replay-record/checksum and final summary" job_j05 || return $?

    CURRENT_JOB=""
    verify_queue_package || return $?
    queue_update complete "" complete "$COMPLETED_JOBS" 0 \
        "all five jobs completed" || return $?
    python3 "$STATUS" queue-terminal \
        --queue-root "$QUEUE_ROOT" \
        --state complete \
        --exit-code 0 \
        --detail "all five jobs completed" || return $?
    QUEUE_FINISHED=1
    printf '%s queue complete\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

main "$@"
