#!/usr/bin/env bash
set -euo pipefail

DISPATCH_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
UNIT=sp-gd-bp-gd-next-campaigns-20261103-v1

systemd-run --user \
  --unit="$UNIT" \
  --property=RuntimeMaxSec=14400 \
  --property=Restart=no \
  --collect \
  systemd-inhibit --what=sleep:idle \
  --why="Sequential BP-GD causal and decoder-development campaigns" \
  --mode=block "$DISPATCH_ROOT/run_dispatcher.sh"
