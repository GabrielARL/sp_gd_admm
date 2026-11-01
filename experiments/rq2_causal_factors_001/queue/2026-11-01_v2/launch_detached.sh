#!/usr/bin/env bash
set -Eeuo pipefail

umask 022
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_SOURCE="${1:-$SCRIPT_ROOT}"
[[ -d "$QUEUE_SOURCE" ]] || {
    printf 'queue root does not exist: %s\n' "$QUEUE_SOURCE" >&2
    exit 2
}
QUEUE_ROOT="$(cd "$QUEUE_SOURCE" && pwd)"
[[ "$QUEUE_ROOT" == "$SCRIPT_ROOT" ]] || {
    printf 'launcher must be invoked from the queue package it launches\n' >&2
    exit 2
}

for command_name in python3 systemd-run; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'required command is unavailable: %s\n' "$command_name" >&2
        exit 2
    }
done

python3 "$QUEUE_ROOT/campaign_queue.py" prelaunch \
    --queue-root "$QUEUE_ROOT" >/dev/null
UNIT="$(python3 "$QUEUE_ROOT/campaign_queue.py" unit-name \
    --queue-root "$QUEUE_ROOT")"
UNIT_BASE="${UNIT%.service}"

systemd-run --user --unit="$UNIT_BASE" --collect \
    --property=Type=exec --property=Restart=no \
    --setenv="RQ2_QUEUE_ROOT=$QUEUE_ROOT" \
    "$QUEUE_ROOT/run_queue.sh"
printf 'launched %s; read %s and %s for durable status\n' \
    "$UNIT" "$QUEUE_ROOT/progress.toml" "$QUEUE_ROOT/queue.log"

