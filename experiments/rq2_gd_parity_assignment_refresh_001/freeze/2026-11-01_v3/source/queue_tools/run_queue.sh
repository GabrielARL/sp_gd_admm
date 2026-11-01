#!/usr/bin/env bash
set -Eeuo pipefail

# Locked serial chain: fresh transfer first, then attribution only after the
# transfer has a complete-valid checksum-bound result.  This script never
# signals another scientific unit and never resumes an interrupted attempt.

umask 022

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${RQ2_QUEUE_ROOT:-}" ]] || {
    printf 'RQ2_QUEUE_ROOT must name the locked attempt directory\n' >&2
    exit 2
}
QUEUE_ROOT_SOURCE="$RQ2_QUEUE_ROOT"
[[ -d "$QUEUE_ROOT_SOURCE" ]] || {
    printf 'attempt-specific queue root does not exist: %s\n' \
        "$QUEUE_ROOT_SOURCE" >&2
    exit 2
}
QUEUE_ROOT="$(cd "$QUEUE_ROOT_SOURCE" && pwd)"
[[ "$QUEUE_ROOT" != "$SCRIPT_ROOT" ]] || {
    printf 'the locked attempt directory must be separate from frozen tools\n' >&2
    exit 2
}
# Trust code only beside this frozen wrapper; RQ2_QUEUE_ROOT supplies data.
STATUS="$SCRIPT_ROOT/status_report.py"
MANIFEST="$QUEUE_ROOT/QUEUE_MANIFEST.sha256"
GLOBAL_LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sp-gd-scientific.lock"

for command_name in python3 julia timeout nice ionice flock tee; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'required command is unavailable: %s\n' "$command_name" >&2
        exit 2
    }
done

verify_launch() {
    python3 "$STATUS" verify-queue-launch --queue-root "$QUEUE_ROOT" >/dev/null
}

resolve_path() {
    python3 "$STATUS" resolve-path --queue-root "$QUEUE_ROOT" --key "$1"
}

write_progress() {
    local state=$1
    local job_id=$2
    local jobs_completed=$3
    local detail=$4
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
        printf 'schema_version = "rq2-gd-parity-assignment-refresh-001/queue-progress-v1"\n'
        printf 'experiment_id = "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001"\n'
        printf 'state = "%s"\n' "$state"
        printf 'current_job = "%s"\n' "$job_id"
        printf 'jobs_completed = %s\n' "$jobs_completed"
        printf 'jobs_total = 2\n'
        printf 'updated_utc = "%s"\n' "$timestamp"
        printf 'detail = "%s"\n' "$detail"
    } >"$QUEUE_ROOT/progress.toml"
    if [[ ! -e "$QUEUE_ROOT/status_history.tsv" ]]; then
        printf 'utc\tstate\tjob\tjobs_completed\tdetail\n' \
            >"$QUEUE_ROOT/status_history.tsv"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$timestamp" "$state" "$job_id" "$jobs_completed" "$detail" \
        >>"$QUEUE_ROOT/status_history.tsv"
}

write_job_marker() {
    local job_id=$1
    local state=$2
    local exit_code=$3
    local detail=$4
    local directory="$QUEUE_ROOT/jobs/$job_id"
    local marker
    case "$state" in
        started) marker="$directory/STARTED.toml" ;;
        complete) marker="$directory/COMPLETED.toml" ;;
        failed) marker="$directory/FAILED.toml" ;;
        *) printf 'unsupported job marker state: %s\n' "$state" >&2; return 2 ;;
    esac
    mkdir -p "$directory"
    [[ ! -e "$marker" ]] || {
        printf 'refusing to overwrite job marker: %s\n' "$marker" >&2
        return 2
    }
    {
        printf 'schema_version = "rq2-gd-parity-assignment-refresh-001/queue-job-v1"\n'
        printf 'experiment_id = "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001"\n'
        printf 'job_id = "%s"\n' "$job_id"
        printf 'state = "%s"\n' "$state"
        printf 'exit_code = %s\n' "$exit_code"
        printf 'recorded_utc = "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'detail = "%s"\n' "$detail"
    } >"$marker"
}

write_terminal() {
    local state=$1
    local exit_code=$2
    local marker
    if [[ "$state" == complete ]]; then
        marker="$QUEUE_ROOT/QUEUE_COMPLETED.toml"
    else
        marker="$QUEUE_ROOT/QUEUE_FAILED.toml"
    fi
    [[ ! -e "$marker" ]] || return 0
    {
        printf 'schema_version = "rq2-gd-parity-assignment-refresh-001/queue-terminal-v1"\n'
        printf 'experiment_id = "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001"\n'
        printf 'state = "%s"\n' "$state"
        printf 'exit_code = %s\n' "$exit_code"
        printf 'recorded_utc = "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$marker"
}

CURRENT_JOB=""
COMPLETED_JOBS=0
QUEUE_STARTED=0
QUEUE_FINISHED=0

on_exit() {
    local exit_code=$?
    if [[ "$exit_code" -ne 0 && "$QUEUE_STARTED" -eq 1 && "$QUEUE_FINISHED" -eq 0 ]]; then
        set +e
        if [[ -n "$CURRENT_JOB" && \
              ! -e "$QUEUE_ROOT/jobs/$CURRENT_JOB/COMPLETED.toml" && \
              ! -e "$QUEUE_ROOT/jobs/$CURRENT_JOB/FAILED.toml" ]]; then
            write_job_marker "$CURRENT_JOB" failed "$exit_code" \
                "queue stopped during $CURRENT_JOB"
        fi
        write_progress failed "$CURRENT_JOB" "$COMPLETED_JOBS" \
            "serial queue stopped after a failed gate or job"
        write_terminal failed "$exit_code"
    fi
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

run_with_budget() {
    local stage=$1
    shift
    local term_after grace wall
    read -r term_after grace wall < <(
        python3 "$STATUS" verify-budget --queue-root "$QUEUE_ROOT" \
            --stage "$stage" --format shell
    )
    [[ "$term_after" =~ ^[0-9]+$ && "$grace" == 120 && "$wall" =~ ^[0-9]+$ ]] || {
        printf 'invalid parsed %s budget: term=%s grace=%s wall=%s\n' \
            "$stage" "$term_after" "$grace" "$wall" >&2
        return 2
    }
    (( term_after + grace == wall && wall <= 36000 )) || {
        printf 'invalid %s timeout identity\n' "$stage" >&2
        return 2
    }
    printf '%s: TERM after %s seconds; KILL by %s seconds\n' \
        "$stage" "$term_after" "$wall"
    timeout --signal=TERM --kill-after="${grace}s" "${term_after}s" \
        nice -n 19 ionice -c 3 "$@"
}

run_job() {
    local job_id=$1
    local stage=$2
    shift 2
    local log="$QUEUE_ROOT/logs/$job_id.log"
    local result
    local exit_code
    if [[ "$stage" == transfer ]]; then
        result="$TRANSFER"
    elif [[ "$stage" == attribution ]]; then
        result="$ATTRIBUTION"
    else
        printf 'unsupported scientific queue stage: %s\n' "$stage" >&2
        return 2
    fi
    CURRENT_JOB="$job_id"
    verify_launch
    python3 "$STATUS" assert-unit-guard --queue-root "$QUEUE_ROOT" --mode queue \
        >/dev/null
    write_job_marker "$job_id" started 0 "$stage stage"
    write_progress running "$job_id" "$COMPLETED_JOBS" "$stage stage"
    printf '%s starting %s (%s)\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_id" "$stage"
    if {
        run_with_budget "$stage" "$@" &&
        python3 "$STATUS" verify-result --result "$result" --stage "$stage" &&
        verify_launch
    } >"$log" 2>&1; then
        COMPLETED_JOBS=$((COMPLETED_JOBS + 1))
        write_job_marker "$job_id" complete 0 "$stage complete-valid"
        write_progress running "$job_id" "$COMPLETED_JOBS" "$stage complete-valid"
        printf '%s completed %s (%s)\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_id" "$stage"
        return 0
    else
        exit_code=$?
        write_job_marker "$job_id" failed "$exit_code" "$stage failed"
        printf '%s failed %s (%s), exit=%s; see %s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_id" "$stage" \
            "$exit_code" "$log" >&2
        return "$exit_code"
    fi
}

main() {
    local required
    verify_launch
    for required in "$STATUS" "$MANIFEST"; do
        [[ -f "$required" ]] || {
            printf 'required locked queue file is missing: %s\n' "$required" >&2
            return 2
        }
    done

    REPO_ROOT="$(resolve_path repository_root)"
    PROJECT_ROOT="$(resolve_path project_root)"
    CONFIG="$(resolve_path config)"
    RUNNER="$(resolve_path runner)"
    FREEZE="$(resolve_path freeze)"
    ANCHOR="$(resolve_path anchor_result)"
    TRANSFER="$(resolve_path transfer_result)"
    ATTRIBUTION="$(resolve_path attribution_result)"
    BUDGET_TRANSFER="$(resolve_path budget_transfer)"
    BUDGET_ATTRIBUTION="$(resolve_path budget_attribution)"

    for required in "$REPO_ROOT" "$PROJECT_ROOT" "$CONFIG" "$RUNNER" \
                    "$FREEZE" "$ANCHOR" "$BUDGET_TRANSFER" \
                    "$BUDGET_ATTRIBUTION"; do
        [[ -e "$required" ]] || {
            printf 'required queue input is missing: %s\n' "$required" >&2
            return 2
        }
    done
    [[ ! -e "$TRANSFER" && ! -e "$ATTRIBUTION" ]] || {
        printf 'refusing to resume or overwrite a scientific output\n' >&2
        return 2
    }
    for required in progress.toml status_history.tsv queue.log \
                    QUEUE_COMPLETED.toml QUEUE_FAILED.toml logs jobs; do
        [[ ! -e "$QUEUE_ROOT/$required" ]] || {
            printf 'prior queue telemetry exists; use a new attempt directory: %s\n' \
                "$QUEUE_ROOT/$required" >&2
            return 2
        }
    done

    python3 "$STATUS" verify-result --result "$ANCHOR" --stage anchor \
        --require-expansion >/dev/null
    python3 "$STATUS" verify-budget --queue-root "$QUEUE_ROOT" \
        --stage transfer >/dev/null
    python3 "$STATUS" verify-budget --queue-root "$QUEUE_ROOT" \
        --stage attribution >/dev/null
    python3 "$STATUS" assert-unit-guard --queue-root "$QUEUE_ROOT" --mode queue \
        >/dev/null

    exec 9>"$QUEUE_ROOT/queue.lock"
    flock -n 9 || {
        printf 'another controller holds this queue lock\n' >&2
        return 75
    }
    mkdir -p "$(dirname "$GLOBAL_LOCK")"
    exec 8>"$GLOBAL_LOCK"
    flock -n 8 || {
        printf 'another cooperating scientific process holds %s\n' \
            "$GLOBAL_LOCK" >&2
        return 75
    }
    python3 "$STATUS" assert-unit-guard --queue-root "$QUEUE_ROOT" --mode queue \
        >/dev/null

    mkdir -p "$QUEUE_ROOT/logs" "$QUEUE_ROOT/jobs"
    exec > >(tee -a "$QUEUE_ROOT/queue.log") 2>&1
    QUEUE_STARTED=1
    write_progress running "" 0 "serial queue initialized"

    export JULIA_NUM_THREADS=1
    export OMP_NUM_THREADS=1
    export OPENBLAS_NUM_THREADS=1
    export MKL_NUM_THREADS=1
    export BLIS_NUM_THREADS=1
    export VECLIB_MAXIMUM_THREADS=1

    cd "$REPO_ROOT"
    run_job J01 transfer \
        julia --threads=1 --startup-file=no --depwarn=error \
        --project="$PROJECT_ROOT" "$RUNNER" transfer --config "$CONFIG" \
        --freeze "$FREEZE" --anchor-result "$ANCHOR" \
        --budget-record "$BUDGET_TRANSFER" --queue-manifest "$MANIFEST" \
        --output "$TRANSFER"
    verify_launch

    run_job J02 attribution \
        julia --threads=1 --startup-file=no --depwarn=error \
        --project="$PROJECT_ROOT" "$RUNNER" attribution --config "$CONFIG" \
        --freeze "$FREEZE" --transfer-result "$TRANSFER" \
        --budget-record "$BUDGET_ATTRIBUTION" --queue-manifest "$MANIFEST" \
        --output "$ATTRIBUTION"
    verify_launch

    CURRENT_JOB=""
    write_progress complete "" "$COMPLETED_JOBS" \
        "transfer and attribution completed"
    write_terminal complete 0
    QUEUE_FINISHED=1
    printf '%s serial queue complete\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

main "$@"
