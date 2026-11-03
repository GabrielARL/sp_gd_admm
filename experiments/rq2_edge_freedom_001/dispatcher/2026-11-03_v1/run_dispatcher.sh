#!/usr/bin/env bash
set -uo pipefail

DISPATCH_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
EDGE_QUEUE=/home/gabiel/Documents/GitHub/sp_gd_admm-rq2-edge-freedom-20261103/experiments/rq2_edge_freedom_001/queue/2026-11-03_v1/run_queue.sh
TRANSFER_QUEUE=/home/gabiel/Documents/GitHub/sp_gd_admm-rq3-compound-box-transfer-20261103/experiments/dev_compound_box_transfer_001/queue/2026-11-03_v1/run_queue.sh
PROGRESS="$DISPATCH_ROOT/progress.toml"

exec > >(tee -a "$DISPATCH_ROOT/dispatcher.log") 2>&1

write_progress() {
  local status=$1
  local job=$2
  local exit_code=$3
  local temporary="$PROGRESS.tmp"
  {
    printf 'schema_version = "bp-gd-next-campaigns/dispatcher-v1"\n'
    printf 'status = "%s"\n' "$status"
    printf 'current_job = "%s"\n' "$job"
    printf 'last_exit_code = %s\n' "$exit_code"
    printf 'updated_utc = "%s"\n' "$(date -u +%FT%TZ)"
  } > "$temporary"
  mv "$temporary" "$PROGRESS"
}

run_queue() {
  local name=$1
  local path=$2
  local code
  write_progress running "$name" 0
  echo "$(date -u +%FT%TZ) dispatcher_job_start job=$name"
  timeout --foreground --signal=TERM --kill-after=30s 5400s "$path"
  code=$?
  if [[ $code -eq 0 ]]; then
    echo "$(date -u +%FT%TZ) dispatcher_job_complete job=$name"
  else
    echo "$(date -u +%FT%TZ) dispatcher_job_failed job=$name exit_code=$code" >&2
  fi
  return "$code"
}

for required in "$EDGE_QUEUE" "$TRANSFER_QUEUE"; do
  if [[ ! -x "$required" ]]; then
    echo "missing or non-executable queue: $required" >&2
    write_progress failed preflight 2
    exit 2
  fi
done

overall=0
run_queue rq2_edge_freedom "$EDGE_QUEUE" || overall=1
run_queue dev_compound_box_transfer "$TRANSFER_QUEUE" || overall=1

if [[ $overall -eq 0 ]]; then
  write_progress complete all 0
  echo "$(date -u +%FT%TZ) dispatcher_complete"
else
  write_progress complete_with_failure all 1
  echo "$(date -u +%FT%TZ) dispatcher_complete_with_failure" >&2
fi
exit "$overall"
