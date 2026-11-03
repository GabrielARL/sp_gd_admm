#!/usr/bin/env bash
set -euo pipefail

QUEUE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
EXPERIMENT_ROOT=$(realpath "$QUEUE_ROOT/../..")
FREEZE_ROOT="$EXPERIMENT_ROOT/freeze/2026-11-03_v1"
RESULT_ROOT="$EXPERIMENT_ROOT/results/2026-11-03_v1"
SOURCE_ROOT="$FREEZE_ROOT/source/rq2_edge_freedom_001"
NATIVE_ROOT="$FREEZE_ROOT/source/rq2_native_composition_001/freeze/2026-11-01_v2"
PROJECT_ROOT="$NATIVE_ROOT/source/jade_project"
ANCHOR_RESULT="$RESULT_ROOT/anchor_61497_61520"
TRANSFER_RESULT="$RESULT_ROOT/transfer_61521_61720"

exec > >(tee -a "$QUEUE_ROOT/queue.log") 2>&1

echo "$(date -u +%FT%TZ) queue_start experiment=RQ2-EDGE-FREEDOM-001"
(cd "$QUEUE_ROOT" && sha256sum -c QUEUE_MANIFEST.sha256)
(cd "$FREEZE_ROOT" && sha256sum -c MANIFEST.sha256)
(cd "$NATIVE_ROOT" && sha256sum -c MANIFEST.sha256)

export JULIA_NUM_THREADS=1
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

LOCK_ROOT=${XDG_RUNTIME_DIR:-/tmp}
exec 9>"$LOCK_ROOT/sp-gd-scientific.lock"
flock -n 9 || {
  echo "another scientific queue holds $LOCK_ROOT/sp-gd-scientific.lock" >&2
  exit 3
}

if [[ -e "$RESULT_ROOT" ]]; then
  echo "refusing to overwrite result root: $RESULT_ROOT" >&2
  exit 2
fi
mkdir -p "$RESULT_ROOT"

echo "$(date -u +%FT%TZ) phase=01_frozen_validation start"
julia --threads=1 --startup-file=no --depwarn=error \
  --project="$PROJECT_ROOT" \
  "$SOURCE_ROOT/test_rq2_edge_freedom_001.jl"
echo "$(date -u +%FT%TZ) phase=01_frozen_validation end"

echo "$(date -u +%FT%TZ) phase=02_anchor start"
julia --threads=1 --startup-file=no --depwarn=error \
  --project="$PROJECT_ROOT" \
  "$SOURCE_ROOT/rq2_edge_freedom_001.jl" run \
  --config "$SOURCE_ROOT/config.toml" \
  --stage anchor \
  --output "$ANCHOR_RESULT"
grep -q 'status = "complete_valid"' "$ANCHOR_RESULT/COMPLETED.toml"
grep -q 'status = "pass"' "$ANCHOR_RESULT/job_gate.toml"
test ! -f "$ANCHOR_RESULT/FAILURE.toml"
echo "$(date -u +%FT%TZ) phase=02_anchor end"

echo "$(date -u +%FT%TZ) phase=03_transfer start"
julia --threads=1 --startup-file=no --depwarn=error \
  --project="$PROJECT_ROOT" \
  "$SOURCE_ROOT/rq2_edge_freedom_001.jl" run \
  --config "$SOURCE_ROOT/config.toml" \
  --stage transfer \
  --prerequisite "$ANCHOR_RESULT/job_gate.toml" \
  --output "$TRANSFER_RESULT"
grep -q 'status = "complete_valid"' "$TRANSFER_RESULT/COMPLETED.toml"
grep -q 'status = "pass"' "$TRANSFER_RESULT/job_gate.toml"
test ! -f "$TRANSFER_RESULT/FAILURE.toml"
echo "$(date -u +%FT%TZ) phase=03_transfer end"
echo "$(date -u +%FT%TZ) queue_complete experiment=RQ2-EDGE-FREEDOM-001"
