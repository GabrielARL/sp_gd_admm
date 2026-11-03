#!/usr/bin/env bash
set -euo pipefail

QUEUE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
EXPERIMENT_ROOT=$(realpath "$QUEUE_ROOT/../..")
FREEZE_ROOT="$EXPERIMENT_ROOT/freeze/2026-11-03_v1"
EXPECTED_FREEZE_MANIFEST_SHA256="59ffb0a0513466beabeaccd55225ae84c7d6e154aa67430926ca6229ed53b0d4"
RESULT_ROOT="$EXPERIMENT_ROOT/results/2026-11-03_v1"
SOURCE_ROOT="$FREEZE_ROOT/source/rq2_bounded_edge_freedom_001"
CAUSAL_ROOT="$FREEZE_ROOT/source/rq2_causal_factors_001/freeze/2026-11-01_v2"
CALIBRATION_ROOT="$FREEZE_ROOT/source/rq2_causal_factors_001/results/2026-11-01_v2/block_a_calibration_20001_20024"
PREDECESSOR_FAILURE_ROOT="$FREEZE_ROOT/source/rq2_edge_freedom_001/results/2026-11-03_v1/anchor_61497_61520"
PROJECT_ROOT=/home/gabiel/Documents/GitHub/JadeJcade-worktrees/awgn-jade-coral-20261012
ANCHOR_RESULT="$RESULT_ROOT/anchor_61497_61520"
TRANSFER_RESULT="$RESULT_ROOT/transfer_61521_61720"

exec > >(tee -a "$QUEUE_ROOT/queue.log") 2>&1

echo "$(date -u +%FT%TZ) queue_start experiment=RQ2-BOUNDED-EDGE-FREEDOM-001"
(cd "$QUEUE_ROOT" && sha256sum -c QUEUE_MANIFEST.sha256)
test -f "$FREEZE_ROOT/MANIFEST.sha256"
test "$(sha256sum "$FREEZE_ROOT/MANIFEST.sha256" | cut -d' ' -f1)" = \
  "$EXPECTED_FREEZE_MANIFEST_SHA256"
(cd "$FREEZE_ROOT" && sha256sum -c MANIFEST.sha256)
(cd "$CAUSAL_ROOT" && sha256sum -c MANIFEST.sha256)
(cd "$CALIBRATION_ROOT" && sha256sum -c MANIFEST.sha256)
(cd "$PREDECESSOR_FAILURE_ROOT" && sha256sum -c MANIFEST.sha256)
test "$(git -C "$PROJECT_ROOT" rev-parse HEAD)" = \
  "a4a4f81cec9e1a38a76ece5867b81284324f1eea"
test -z "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=no)"
test "$(sha256sum "$PROJECT_ROOT/Project.toml" | cut -d' ' -f1)" = \
  "29b094478b8b4ab89606ca4f9f4a1c8495ebe74ea473372a3b04faef6c40dc04"
test "$(sha256sum "$PROJECT_ROOT/Manifest.toml" | cut -d' ' -f1)" = \
  "c0d828e48da8b5bf0acacceacb3fdcfacd0b9b1c2b2766600d11154700016eff"
test "$(sha256sum "$PROJECT_ROOT/src/ReceiverCore.jl" | cut -d' ' -f1)" = \
  "98f03da65e8b791e132e57761e3577f46d0f97c5cf802449271838f43f8b6dd0"
test "$(sha256sum "$PROJECT_ROOT/src/core/common.jl" | cut -d' ' -f1)" = \
  "f4bb1b5aefbc800d51221f732a44532a8dd2128a260fbbb3f6d9c54adf27bba5"
test "$(sha256sum "$PROJECT_ROOT/src/core/joint_cz_projected_gradient.jl" | cut -d' ' -f1)" = \
  "c1ba501be0d13269032706f55a80dbd465938c3f4ce71679d5948fc77ecc1c4a"

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
  "$SOURCE_ROOT/test_rq2_bounded_edge_freedom_001.jl"
echo "$(date -u +%FT%TZ) phase=01_frozen_validation end"

echo "$(date -u +%FT%TZ) phase=02_anchor start"
julia --threads=1 --startup-file=no --depwarn=error \
  --project="$PROJECT_ROOT" \
  "$SOURCE_ROOT/rq2_bounded_edge_freedom_001.jl" run \
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
  "$SOURCE_ROOT/rq2_bounded_edge_freedom_001.jl" run \
  --config "$SOURCE_ROOT/config.toml" \
  --stage transfer \
  --prerequisite "$ANCHOR_RESULT/job_gate.toml" \
  --output "$TRANSFER_RESULT"
grep -q 'status = "complete_valid"' "$TRANSFER_RESULT/COMPLETED.toml"
grep -q 'status = "pass"' "$TRANSFER_RESULT/job_gate.toml"
test ! -f "$TRANSFER_RESULT/FAILURE.toml"
echo "$(date -u +%FT%TZ) phase=03_transfer end"
echo "$(date -u +%FT%TZ) queue_complete experiment=RQ2-BOUNDED-EDGE-FREEDOM-001"
