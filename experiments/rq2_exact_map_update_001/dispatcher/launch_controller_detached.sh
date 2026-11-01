#!/usr/bin/env bash
set -Eeuo pipefail

readonly DISPATCHER_DIR="/home/gabiel/Documents/GitHub/sp_gd_admm-rq2-bp-gd-causal-ladder-20261101/experiments/rq2_exact_map_update_001/dispatcher"
readonly WORKDIR="/home/gabiel/Documents/GitHub/sp_gd_admm-rq2-bp-gd-causal-ladder-20261101"
readonly CONTROLLER="$DISPATCHER_DIR/dependency_dispatcher.py"
readonly CONFIG="$DISPATCHER_DIR/controller_2026-11-01_v1.toml"
readonly UNIT="rq2-exact-map-update-controller-20261101-v1"

[[ -f "$CONTROLLER" && ! -L "$CONTROLLER" ]] || {
    printf 'controller is missing or indirect: %s\n' "$CONTROLLER" >&2
    exit 2
}
[[ -f "$CONFIG" && ! -L "$CONFIG" ]] || {
    printf 'attempt configuration is missing or indirect: %s\n' "$CONFIG" >&2
    exit 2
}
[[ "$UNIT" != sp-gd-* ]] || {
    printf 'controller unit must not use the scientific sp-gd prefix\n' >&2
    exit 2
}

exec /usr/bin/systemd-run --user --unit="$UNIT" --collect \
    --property=Type=exec --property=Restart=no \
    --working-directory="$WORKDIR" \
    /usr/bin/python3 "$CONTROLLER" --config "$CONFIG"
