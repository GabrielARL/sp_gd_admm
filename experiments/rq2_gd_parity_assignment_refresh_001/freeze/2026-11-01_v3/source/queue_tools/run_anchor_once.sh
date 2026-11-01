#!/usr/bin/env bash
set -Eeuo pipefail

# One-off development anchor.  The 7,200-second cap includes the 120-second
# termination reserve: TERM at 7,080 seconds, KILL at most 120 seconds later.

umask 022

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_ROOT_SOURCE="${RQ2_QUEUE_ROOT:-$SCRIPT_ROOT}"
[[ -d "$QUEUE_ROOT_SOURCE" ]] || {
    printf 'attempt-specific queue root does not exist: %s\n' \
        "$QUEUE_ROOT_SOURCE" >&2
    exit 2
}
QUEUE_ROOT="$(cd "$QUEUE_ROOT_SOURCE" && pwd)"
# The checker is intentionally loaded beside this frozen wrapper.  Before the
# anchor, QUEUE_ROOT contains an attempt-specific queue.toml but cannot yet be
# a locked package because its two budgets derive from the anchor measurement.
STATUS="$SCRIPT_ROOT/status_report.py"
GLOBAL_LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sp-gd-scientific.lock"

for command_name in python3 julia timeout nice ionice flock; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'required command is unavailable: %s\n' "$command_name" >&2
        exit 2
    }
done
[[ -f "$STATUS" ]] || {
    printf 'missing read-only queue checker: %s\n' "$STATUS" >&2
    exit 2
}

resolve_path() {
    python3 "$STATUS" resolve-path --queue-root "$QUEUE_ROOT" --key "$1"
}

REPO_ROOT="$(resolve_path repository_root)"
PROJECT_ROOT="$(resolve_path project_root)"
CONFIG="$(resolve_path config)"
RUNNER="$(resolve_path runner)"
FREEZE="$(resolve_path freeze)"
ANCHOR="$(resolve_path anchor_result)"

for required in "$REPO_ROOT" "$PROJECT_ROOT" "$CONFIG" "$RUNNER" "$FREEZE"; do
    [[ -e "$required" ]] || {
        printf 'required anchor input is missing: %s\n' "$required" >&2
        exit 2
    }
done
[[ ! -e "$ANCHOR" ]] || {
    printf 'refusing to overwrite anchor output: %s\n' "$ANCHOR" >&2
    exit 2
}

python3 "$STATUS" verify-anchor-launch --queue-root "$QUEUE_ROOT" >/dev/null
python3 "$STATUS" assert-unit-guard --queue-root "$QUEUE_ROOT" --mode anchor
mkdir -p "$(dirname "$GLOBAL_LOCK")"
exec 8>"$GLOBAL_LOCK"
flock -n 8 || {
    printf 'another cooperating scientific process holds %s\n' "$GLOBAL_LOCK" >&2
    exit 75
}
# Close the service-scan/lock race for all wrappers that honor this contract.
python3 "$STATUS" assert-unit-guard --queue-root "$QUEUE_ROOT" --mode anchor

export JULIA_NUM_THREADS=1
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1

cd "$REPO_ROOT"
printf '%s starting bounded one-off anchor\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'TERM after 7080 seconds; hard stop no later than the 7200-second cap\n'
timeout --signal=TERM --kill-after=120s 7080s \
    nice -n 19 ionice -c 3 \
    julia --threads=1 --startup-file=no --depwarn=error \
    --project="$PROJECT_ROOT" "$RUNNER" anchor --config "$CONFIG" \
    --freeze "$FREEZE" --output "$ANCHOR"
printf '%s anchor process completed\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 "$STATUS" verify-result --result "$ANCHOR" --stage anchor \
    --require-expansion
