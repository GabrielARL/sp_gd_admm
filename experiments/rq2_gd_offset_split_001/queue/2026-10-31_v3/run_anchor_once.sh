#!/usr/bin/env bash
set -Eeuo pipefail

umask 022

REPO_ROOT="/home/gabiel/Documents/GitHub/sp_gd_admm-rq1-gd-state-use-20261030"
EXPERIMENT_ROOT="$REPO_ROOT/experiments/rq2_gd_offset_split_001"
ATTEMPT_ROOT="$EXPERIMENT_ROOT/attempts/2026-10-31_v3/rq2_gd_offset_split_001"
PROJECT_ROOT="/home/gabiel/Documents/GitHub/JadeJcade-worktrees/awgn-jade-coral-20261012"
CONFIG="$ATTEMPT_ROOT/config.toml"
RUNNER="$ATTEMPT_ROOT/rq2_gd_offset_split_001.jl"
FREEZE="$EXPERIMENT_ROOT/freeze/2026-10-31_v3"
ANCHOR="$EXPERIMENT_ROOT/results/2026-10-31_anchor_v3"

export JULIA_NUM_THREADS=1
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

cd "$REPO_ROOT"

[[ ! -e "$ANCHOR" ]] || {
    printf 'refusing to overwrite v3 anchor: %s\n' "$ANCHOR" >&2
    exit 2
}

(
    cd "$FREEZE"
    sha256sum --strict --check MANIFEST.sha256
)

actual_input_sha256="$(sha256sum "$FREEZE/input_freeze.csv" | awk '{print $1}')"
expected_input_sha256="739da19436f5f3371333ad04585be4c9cd934506c9a66892776b146105b5a5bd"
[[ "$actual_input_sha256" == "$expected_input_sha256" ]] || {
    printf 'v3 input freeze differs: expected %s, found %s\n' \
        "$expected_input_sha256" "$actual_input_sha256" >&2
    exit 2
}

printf '%s starting isolated v3 anchor beside v2\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
timeout --signal=TERM --kill-after=120s 3480s \
    julia --startup-file=no --depwarn=error --project="$PROJECT_ROOT" \
    "$RUNNER" anchor --config "$CONFIG" --freeze "$FREEZE" --output "$ANCHOR"
printf '%s completed isolated v3 anchor\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
