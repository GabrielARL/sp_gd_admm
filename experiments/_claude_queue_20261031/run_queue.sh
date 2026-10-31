#!/usr/bin/env bash
# Serial, fail-closed queue for RQ2-GD-OFFSET-NULL-001 and RQ2-NATIVE-GAP-001.
# Runs in its own worktree at low priority beside the split experiment's queue.
set -Eeuo pipefail
umask 022

QUEUE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="/home/gabiel/Documents/GitHub/sp_gd_admm-claude-controls-20261031"
PROJECT="/home/gabiel/Documents/GitHub/JadeJcade-worktrees/awgn-jade-coral-20261012"
NULL_ROOT="$REPO_ROOT/experiments/rq2_gd_offset_null_001"
GAP_ROOT="$REPO_ROOT/experiments/rq2_native_gap_001"
NULL_RUNNER="$NULL_ROOT/rq2_gd_offset_null_001.jl"
GAP_RUNNER="$GAP_ROOT/rq2_native_gap_001.jl"
DATE_TAG="2026-10-31"
NULL_FREEZE="$NULL_ROOT/freeze/${DATE_TAG}_v1"
NULL_ANCHOR="$NULL_ROOT/results/${DATE_TAG}_anchor_v1"
NULL_HELDOUT="$NULL_ROOT/results/${DATE_TAG}_heldout_v1"
# The native-gap attempt tag advances on a manual relaunch after a failed
# attempt; earlier attempt directories are retained untouched.
GAP_ATTEMPT="${GAP_ATTEMPT:-v1}"
GAP_FREEZE="$GAP_ROOT/freeze/${DATE_TAG}_${GAP_ATTEMPT}"
GAP_SIX="$GAP_ROOT/results/${DATE_TAG}_six_${GAP_ATTEMPT}"
GAP_PROFILE="$GAP_ROOT/results/${DATE_TAG}_profile_${GAP_ATTEMPT}"
GAP_SECOND="$GAP_ROOT/results/${DATE_TAG}_second_${GAP_ATTEMPT}"
LOG_ROOT="$QUEUE_ROOT/logs"
JOBS_ROOT="$QUEUE_ROOT/jobs"
PROGRESS="$QUEUE_ROOT/progress.toml"
QUEUE_LOG="$QUEUE_ROOT/queue.log"

export JULIA_NUM_THREADS=1
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
JULIA=(julia --startup-file=no --depwarn=error "--project=$PROJECT")

mkdir -p "$LOG_ROOT" "$JOBS_ROOT"
cd "$REPO_ROOT"

exec 9>"$QUEUE_ROOT/queue.lock"
flock -n 9 || { echo "another queue process holds the lock" >&2; exit 75; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(now_utc)" "$*" | tee -a "$QUEUE_LOG"; }

write_progress() {
    local state=$1 job=$2 job_state=$3 completed=$4 detail=$5
    local tmp="$PROGRESS.tmp"
    {
        printf 'queue_id = "CLAUDE-CONTROLS-QUEUE-2026-10-31-V1"\n'
        printf 'state = "%s"\n' "$state"
        printf 'current_job = "%s"\n' "$job"
        printf 'current_job_state = "%s"\n' "$job_state"
        printf 'jobs_completed = %s\n' "$completed"
        printf 'jobs_total = 6\n'
        printf 'detail = "%s"\n' "$detail"
        printf 'process_id = %s\n' "$$"
        printf 'updated_utc = "%s"\n' "$(now_utc)"
    } > "$tmp"
    mv "$tmp" "$PROGRESS"
}

with_budget() {
    local budget=$1; shift
    local grace=120
    timeout --signal=TERM --kill-after="${grace}s" "$((budget - grace))s" "$@"
}

COMPLETED=0
run_job() {
    local id=$1 title=$2 budget=$3; shift 3
    mkdir -p "$JOBS_ROOT/$id"
    if [[ -f "$JOBS_ROOT/$id/COMPLETED.toml" ]]; then
        log "skipping $id: already complete"; COMPLETED=$((COMPLETED + 1)); return 0
    fi
    [[ -f "$JOBS_ROOT/$id/FAILED.toml" ]] && { log "$id previously failed; refusing to continue"; exit 3; }
    log "starting $id: $title"
    write_progress running "$id" running "$COMPLETED" "$title"
    local started; started=$(now_utc)
    set +e
    with_budget "$budget" "$@" >> "$LOG_ROOT/$id.log" 2>&1
    local code=$?
    set -e
    if [[ $code -eq 0 ]]; then
        printf 'job = "%s"\ntitle = "%s"\nstarted_utc = "%s"\ncompleted_utc = "%s"\nexit_code = 0\n' \
            "$id" "$title" "$started" "$(now_utc)" > "$JOBS_ROOT/$id/COMPLETED.toml"
        COMPLETED=$((COMPLETED + 1))
        log "completed $id"
        write_progress running "$id" complete "$COMPLETED" "$title"
    else
        local class=gate_failure
        [[ $code -eq 124 || $code -eq 137 || $code -eq 143 ]] && class=interrupted
        printf 'job = "%s"\ntitle = "%s"\nstarted_utc = "%s"\nfailed_utc = "%s"\nexit_code = %s\nfailure_class = "%s"\n' \
            "$id" "$title" "$started" "$(now_utc)" "$code" "$class" > "$JOBS_ROOT/$id/FAILED.toml"
        log "FAILED $id (exit $code, $class); queue stops"
        write_progress failed "$id" failed "$COMPLETED" "$title"
        exit "$code"
    fi
}

j1() {
    "${JULIA[@]}" "$NULL_ROOT/test_rq2_gd_offset_null_001.jl" &&
    "${JULIA[@]}" "$GAP_ROOT/test_rq2_native_gap_001.jl" &&
    "${JULIA[@]}" "$NULL_RUNNER" preflight-probe &&
    "${JULIA[@]}" "$GAP_RUNNER" preflight-probe &&
    "${JULIA[@]}" "$NULL_RUNNER" freeze --output "$NULL_FREEZE" &&
    "${JULIA[@]}" "$GAP_RUNNER" freeze --output "$GAP_FREEZE"
}
j4() {
    # On a relaunch with a new attempt tag the gap experiment's authored
    # sources may have changed, so its tests and freeze are redone first.
    if [[ ! -d "$GAP_FREEZE" ]]; then
        "${JULIA[@]}" "$GAP_ROOT/test_rq2_native_gap_001.jl" &&
        "${JULIA[@]}" "$GAP_RUNNER" preflight-probe &&
        "${JULIA[@]}" "$GAP_RUNNER" freeze --output "$GAP_FREEZE" || return $?
    fi
    "${JULIA[@]}" "$GAP_RUNNER" six --freeze "$GAP_FREEZE" --output "$GAP_SIX" &&
    "${JULIA[@]}" "$GAP_RUNNER" profile --freeze "$GAP_FREEZE" --output "$GAP_PROFILE" &&
    "${JULIA[@]}" "$GAP_RUNNER" second --freeze "$GAP_FREEZE" --profile-result "$GAP_PROFILE" --output "$GAP_SECOND"
}
j6() {
    "${JULIA[@]}" "$NULL_RUNNER" verify --result "$NULL_HELDOUT" &&
    "${JULIA[@]}" "$GAP_RUNNER" verify --result "$GAP_SIX" &&
    "${JULIA[@]}" "$GAP_RUNNER" verify --result "$GAP_PROFILE" &&
    "${JULIA[@]}" "$GAP_RUNNER" verify --result "$GAP_SECOND" &&
    {
        echo "# Final summary $(now_utc)"
        for d in "$NULL_ANCHOR" "$NULL_HELDOUT" "$GAP_SIX" "$GAP_PROFILE" "$GAP_SECOND"; do
            echo; echo "## $d"; cat "$d/COMPLETED.toml"
            [[ -f "$d/aggregate.csv" ]] && { echo; cat "$d/aggregate.csv"; }
            [[ -f "$d/selection.toml" ]] && { echo; cat "$d/selection.toml"; }
        done
    } > "$QUEUE_ROOT/final_summary.md"
}

log "queue started (pid $$) in $REPO_ROOT"
write_progress running J1 running 0 "tests, preflight, freezes"
run_job J1 "tests, preflight probes, input freezes" 3600 bash -c "$(declare -f j1); $(declare -p JULIA NULL_ROOT GAP_ROOT NULL_RUNNER GAP_RUNNER NULL_FREEZE GAP_FREEZE); j1"
run_job J2 "null-control 24-case anchor, 4 arms, 2 passes" 7200 "${JULIA[@]}" "$NULL_RUNNER" anchor --freeze "$NULL_FREEZE" --output "$NULL_ANCHOR"
run_job J3 "null-control anchor verification" 600 "${JULIA[@]}" "$NULL_RUNNER" verify --result "$NULL_ANCHOR"
run_job J4 "native gap: six, profile, second (attempt $GAP_ATTEMPT)" 16200 bash -c "$(declare -f j4); $(declare -p JULIA GAP_ROOT GAP_RUNNER GAP_FREEZE GAP_SIX GAP_PROFILE GAP_SECOND); j4"
run_job J5 "null-control 200-case held-out, 4 arms, 2 passes" 36000 "${JULIA[@]}" "$NULL_RUNNER" heldout --freeze "$NULL_FREEZE" --anchor-result "$NULL_ANCHOR" --output "$NULL_HELDOUT"
run_job J6 "final verification and summary" 1200 bash -c "$(declare -f j6 now_utc); $(declare -p JULIA NULL_RUNNER GAP_RUNNER NULL_ANCHOR NULL_HELDOUT GAP_SIX GAP_PROFILE GAP_SECOND QUEUE_ROOT); j6"
write_progress complete J6 complete "$COMPLETED" "all jobs complete"
log "queue complete"
