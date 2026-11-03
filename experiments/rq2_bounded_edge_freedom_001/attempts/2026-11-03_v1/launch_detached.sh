#!/usr/bin/env bash
set -euo pipefail

QUEUE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
UNIT=sp-gd-rq2-bounded-edge-freedom-20261103-v1

systemd-run --user \
  --unit="$UNIT" \
  --property=RuntimeMaxSec=5400 \
  --property=Restart=no \
  --collect \
  systemd-inhibit \
    --what=sleep:idle \
    --why="RQ2 bounded edge-copy equality relaxation" \
    --mode=block \
    "$QUEUE_ROOT/run_queue.sh"
