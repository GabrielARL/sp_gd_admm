#!/usr/bin/env bash
set -Eeuo pipefail

umask 022
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_SOURCE="${RQ2_QUEUE_ROOT:-$SCRIPT_ROOT}"
[[ -d "$QUEUE_SOURCE" ]] || {
    printf 'queue root does not exist: %s\n' "$QUEUE_SOURCE" >&2
    exit 2
}
QUEUE_ROOT="$(cd "$QUEUE_SOURCE" && pwd)"
[[ "$QUEUE_ROOT" == "$SCRIPT_ROOT" ]] || {
    printf 'run_queue.sh must execute from its own locked queue package\n' >&2
    exit 2
}
CONTROLLER="$QUEUE_ROOT/campaign_queue.py"

for command_name in python3 flock timeout nice ionice tee systemctl; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'required command is unavailable: %s\n' "$command_name" >&2
        exit 2
    }
done

python3 "$CONTROLLER" assert-fresh --queue-root "$QUEUE_ROOT" >/dev/null

exec 9>"$QUEUE_ROOT/queue.lock"
flock -n 9 || {
    printf 'another controller holds this queue lock\n' >&2
    exit 75
}

LOCK_NAME="sp-gd-scientific.lock"
RUNTIME_ROOT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$RUNTIME_ROOT"
exec 8>"$RUNTIME_ROOT/$LOCK_NAME"
flock -n 8 || {
    printf 'another cooperating scientific process holds %s\n' \
        "$RUNTIME_ROOT/$LOCK_NAME" >&2
    exit 75
}

export JULIA_NUM_THREADS=1
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1

exec > >(tee -a "$QUEUE_ROOT/queue.log") 2>&1
printf '%s starting RQ2 causal-factor queue\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 "$CONTROLLER" run --queue-root "$QUEUE_ROOT"
printf '%s RQ2 causal-factor queue complete\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

