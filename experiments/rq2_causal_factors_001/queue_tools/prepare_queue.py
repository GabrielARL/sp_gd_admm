#!/usr/bin/env python3
"""Create and lock a new queue directory from one filled queue.toml."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

TOOL_ROOT = Path(__file__).resolve().parent
EXPERIMENT_ROOT = TOOL_ROOT.parent
sys.path.insert(0, str(EXPERIMENT_ROOT))

from campaign_queue import GateError, lock_queue_package  # noqa: E402


def prepare(config: Path, output: Path) -> dict[str, object]:
    config = config.resolve()
    output = output.resolve()
    if not config.is_file() or config.is_symlink():
        raise GateError(f"configuration is missing or indirect: {config}")
    if output.exists():
        raise GateError(f"refusing to overwrite queue directory: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.tmp.", dir=output.parent))
    sources = {
        "README.md": EXPERIMENT_ROOT / "README.md",
        "campaign_queue.py": EXPERIMENT_ROOT / "campaign_queue.py",
        "launch_detached.sh": TOOL_ROOT / "launch_detached.sh",
        "lock_queue_package.py": TOOL_ROOT / "lock_queue_package.py",
        "queue.toml": config,
        "run_queue.sh": TOOL_ROOT / "run_queue.sh",
    }
    try:
        for name, source in sources.items():
            if not source.is_file() or source.is_symlink():
                raise GateError(f"queue source is missing or indirect: {source}")
            shutil.copyfile(source, temporary / name)
        for name in ("launch_detached.sh", "run_queue.sh"):
            (temporary / name).chmod(0o755)
        for name in ("campaign_queue.py", "lock_queue_package.py"):
            (temporary / name).chmod(0o644)
        result = lock_queue_package(temporary)
        os.replace(temporary, output)
        result["queue_root"] = str(output)
        return result
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(prepare(args.config, args.output), sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (GateError, OSError, KeyError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)

