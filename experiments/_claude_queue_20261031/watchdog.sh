#!/usr/bin/env bash
# Pauses my queue (SIGSTOP) whenever Codex's split queue slows down or memory
# runs low, and resumes it (SIGCONT) afterwards.  It never signals Codex's unit.
set -u
MY_UNIT="sp-gd-claude-controls-20261031.service"
CODEX_UNIT="sp-gd-rq2-offset-split-20261031.service"
CODEX_RESULTS="/home/gabiel/Documents/GitHub/sp_gd_admm-rq1-gd-state-use-20261030/experiments/rq2_gd_offset_split_001/results"
LOG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/watchdog.log"
PAUSE_THRESHOLD=45      # seconds per Codex frame before I yield (baseline ~29 s)
STALL_THRESHOLD=120     # seconds without a Codex frame while it reports running
PAUSE_SECONDS=90
MIN_AVAILABLE_MB=1200
POLL=15

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }
resume() { systemctl --user kill --signal=SIGCONT "$MY_UNIT" 2>/dev/null || true; }
pause() { systemctl --user kill --signal=SIGSTOP "$MY_UNIT" 2>/dev/null || true; }

codex_progress_file() {
    # The most recently modified progress journal under Codex's results.
    ls -t "$CODEX_RESULTS"/*/progress.toml 2>/dev/null | head -1
}

last_key=""; last_change=$(date +%s); interval=0
log "watchdog started"
while true; do
    if ! systemctl --user is-active --quiet "$MY_UNIT"; then
        log "my queue is no longer active; exiting"; exit 0
    fi
    if ! systemctl --user is-active --quiet "$CODEX_UNIT"; then
        resume; log "Codex's queue is no longer active; resuming mine and exiting"; exit 0
    fi
    now=$(date +%s)
    file=$(codex_progress_file)
    status=""; key=""
    if [[ -n "$file" && -f "$file" ]]; then
        status=$(grep -E '^status' "$file" | head -1 | sed 's/.*= *"\?\([a-z_]*\)"\?/\1/')
        fc=$(grep -E '^frames_completed' "$file" | head -1 | tr -dc '0-9')
        pass=$(grep -E '^pass' "$file" | head -1 | sed 's/.*= *"\?\([a-z_]*\)"\?/\1/')
        key="$file:$pass:$fc"
    fi
    if [[ "$key" != "$last_key" ]]; then
        [[ -n "$last_key" ]] && interval=$((now - last_change))
        last_key=$key; last_change=$now
    fi
    since=$((now - last_change))
    available=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    # A static journal while Codex's process already holds a full core is a
    # phase without progress writes, not a frame slowed by my load.
    codex_pid=$(grep -E '^process_id' "${file:-/dev/null}" 2>/dev/null | tr -dc '0-9')
    codex_cpu=$(ps -o pcpu= -p "${codex_pid:-0}" 2>/dev/null | tr -dc '0-9.' | cut -d. -f1)
    reason=""
    [[ $interval -gt $PAUSE_THRESHOLD ]] && reason="codex frame interval ${interval}s"
    [[ "$status" == "running" && $since -gt $STALL_THRESHOLD && ${codex_cpu:-0} -lt 90 ]] && \
        reason="codex frame running for ${since}s at ${codex_cpu:-0}% cpu"
    [[ ${available:-9999} -lt $MIN_AVAILABLE_MB ]] && reason="available memory ${available} MB"
    if [[ -n "$reason" ]]; then
        log "pausing my queue for ${PAUSE_SECONDS}s: $reason"
        pause; sleep "$PAUSE_SECONDS"; resume
        log "resumed"
        interval=0; last_change=$(date +%s)
    fi
    sleep "$POLL"
done
