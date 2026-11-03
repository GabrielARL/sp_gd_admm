#!/usr/bin/env python3
"""Create a checksum-locked queue package for attempt 2026-11-03_v1."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import stat
import tempfile


FILES = ("README.md", "queue.toml", "run_queue.sh", "launch_detached.sh")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def prepare(source: Path, output: Path) -> None:
    source = source.resolve()
    output = output.resolve()
    if output.exists():
        raise RuntimeError(f"refusing to overwrite queue: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.tmp.", dir=output.parent))
    try:
        for name in FILES:
            original = source / name
            if not original.is_file() or original.is_symlink():
                raise RuntimeError(f"queue source missing or indirect: {original}")
            shutil.copy2(original, temporary / name, follow_symlinks=False)
        for name in ("run_queue.sh", "launch_detached.sh"):
            (temporary / name).chmod(0o555)
        manifest = temporary / "QUEUE_MANIFEST.sha256"
        manifest.write_text("".join(
            f"{sha256_file(temporary / name)}  {name}\n" for name in sorted(FILES)
        ), encoding="utf-8")
        manifest.chmod(0o444)
        for name in ("README.md", "queue.toml"):
            (temporary / name).chmod(0o444)
        os.replace(temporary, output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.source, args.output)
    print(f"queue={args.output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

