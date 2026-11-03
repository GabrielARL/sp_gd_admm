#!/usr/bin/env bash
set -euo pipefail

QUEUE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
EXPERIMENT_ROOT=$(realpath "$QUEUE_ROOT/../..")
FREEZE_ROOT="$EXPERIMENT_ROOT/freeze/2026-11-03_v1"
RESULT_ROOT="$EXPERIMENT_ROOT/results/2026-11-03_v1"
SOURCE_ROOT="$FREEZE_ROOT/source/rq2_tied_scalar_edge_repro_001"
NATIVE_ROOT="$FREEZE_ROOT/source/rq2_native_composition_001/freeze/2026-11-01_v2"
PROJECT_ROOT="$NATIVE_ROOT/source/jade_project"

exec > >(tee -a "$QUEUE_ROOT/queue.log") 2>&1

echo "$(date -u +%FT%TZ) queue_start"
(cd "$QUEUE_ROOT" && sha256sum -c QUEUE_MANIFEST.sha256)
(cd "$FREEZE_ROOT" && sha256sum -c MANIFEST.sha256)
(cd "$NATIVE_ROOT" && sha256sum -c MANIFEST.sha256)

if [[ -e "$RESULT_ROOT" ]]; then
  echo "refusing to overwrite result: $RESULT_ROOT" >&2
  exit 2
fi

export JULIA_NUM_THREADS=1
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

LOCK_ROOT=${XDG_RUNTIME_DIR:-/tmp}
exec 9>"$LOCK_ROOT/sp-gd-scientific.lock"
flock -n 9 || {
  echo "another scientific queue holds $LOCK_ROOT/sp-gd-scientific.lock" >&2
  exit 3
}

echo "$(date -u +%FT%TZ) phase=01_frozen_validation start"
julia --threads=1 --startup-file=no --depwarn=error \
  --project="$PROJECT_ROOT" \
  "$SOURCE_ROOT/test_rq2_tied_scalar_edge_repro_001.jl"
echo "$(date -u +%FT%TZ) phase=01_frozen_validation end"

echo "$(date -u +%FT%TZ) phase=02_tied_reproduction_gate start"
julia --threads=1 --startup-file=no --depwarn=error \
  --project="$PROJECT_ROOT" \
  "$SOURCE_ROOT/rq2_tied_scalar_edge_repro_001.jl" run \
  --config "$SOURCE_ROOT/config.toml" \
  --output "$RESULT_ROOT"
test -f "$RESULT_ROOT/COMPLETED.toml"
test ! -f "$RESULT_ROOT/FAILURE.toml"
echo "$(date -u +%FT%TZ) phase=02_tied_reproduction_gate end"
echo "$(date -u +%FT%TZ) queue_complete"

