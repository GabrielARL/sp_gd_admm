#!/usr/bin/env python3
"""Create the one-time checksum lock for a prepared queue package."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from campaign_queue import GateError, lock_queue_package


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--queue-root", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(lock_queue_package(args.queue_root.resolve()), sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (GateError, OSError, KeyError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
