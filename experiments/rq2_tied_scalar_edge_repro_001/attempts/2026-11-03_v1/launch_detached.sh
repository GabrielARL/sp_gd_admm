#!/usr/bin/env bash
set -euo pipefail

QUEUE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
UNIT=sp-gd-rq2-tied-scalar-edge-repro-20261103-v1

if systemctl --user list-unit-files --no-legend "${UNIT}.service" | grep -q .; then
  echo "refusing to reuse existing unit ${UNIT}.service" >&2
  exit 2
fi
if systemctl --user is-active --quiet "${UNIT}.service"; then
  echo "unit already active: ${UNIT}.service" >&2
  exit 2
fi

systemd-run --user \
  --unit="$UNIT" \
  --property=RuntimeMaxSec=3600 \
  --property=Restart=no \
  --collect \
  "$QUEUE_ROOT/run_queue.sh"

