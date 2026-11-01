#!/usr/bin/env bash
set -Eeuo pipefail

umask 022
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_SOURCE="${RQ2_QUEUE_ROOT:-$SCRIPT_ROOT}"
[[ -d "$QUEUE_SOURCE" ]] || { printf 'queue root does not exist: %s\n' "$QUEUE_SOURCE" >&2; exit 2; }
QUEUE_ROOT="$(cd "$QUEUE_SOURCE" && pwd)"
[[ "$QUEUE_ROOT" == "$SCRIPT_ROOT" ]] || { printf 'run_queue.sh must execute from its locked queue package\n' >&2; exit 2; }
CONTROLLER="$QUEUE_ROOT/campaign_queue.py"

for command_name in python3 flock nice ionice tee systemctl; do
    command -v "$command_name" >/dev/null 2>&1 || { printf 'required command is unavailable: %s\n' "$command_name" >&2; exit 2; }
done

python3 "$CONTROLLER" assert-fresh --queue-root "$QUEUE_ROOT" >/dev/null
exec 9>"$QUEUE_ROOT/queue.lock"
flock -n 9 || { printf 'another controller holds this queue lock\n' >&2; exit 75; }

RUNTIME_ROOT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$RUNTIME_ROOT"
exec 8>"$RUNTIME_ROOT/sp-gd-scientific.lock"
flock -n 8 || { printf 'another cooperating scientific process holds the global lock\n' >&2; exit 75; }

export JULIA_NUM_THREADS=1 OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1 BLIS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1
exec > >(tee -a "$QUEUE_ROOT/queue.log") 2>&1
printf '%s starting exact-map update queue\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 "$CONTROLLER" run --queue-root "$QUEUE_ROOT"
printf '%s exact-map update queue complete\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

