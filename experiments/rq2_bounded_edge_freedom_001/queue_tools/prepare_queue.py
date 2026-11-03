#!/usr/bin/env python3
"""Create a checksum-locked queue package without overwriting an attempt."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import tempfile


FILES = ("README.md", "queue.toml", "run_queue.sh", "launch_detached.sh")
FREEZE_MANIFEST_PLACEHOLDER = "__FREEZE_MANIFEST_SHA256__"
BINDING_FILES = ("queue.toml", "run_queue.sh")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def replace_freeze_manifest_placeholder(path: Path, digest: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(FREEZE_MANIFEST_PLACEHOLDER)
    if count != 1:
        raise RuntimeError(
            f"expected one freeze-manifest placeholder in {path}, found {count}"
        )
    path.write_text(
        text.replace(FREEZE_MANIFEST_PLACEHOLDER, digest),
        encoding="utf-8",
    )


def prepare(source: Path, freeze: Path, output: Path) -> None:
    source = source.resolve()
    freeze = freeze.resolve()
    output = output.resolve()
    if output.exists():
        raise RuntimeError(f"refusing to overwrite queue: {output}")
    freeze_manifest = freeze / "MANIFEST.sha256"
    if not freeze_manifest.is_file() or freeze_manifest.is_symlink():
        raise RuntimeError(
            f"freeze manifest missing or indirect: {freeze_manifest}"
        )
    freeze_manifest_sha256 = sha256_file(freeze_manifest)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(
        prefix=f".{output.name}.tmp.", dir=output.parent))
    try:
        for name in FILES:
            original = source / name
            if not original.is_file() or original.is_symlink():
                raise RuntimeError(f"queue source missing or indirect: {original}")
            shutil.copy2(original, temporary / name, follow_symlinks=False)
        for name in BINDING_FILES:
            replace_freeze_manifest_placeholder(
                temporary / name, freeze_manifest_sha256
            )
        for name in ("run_queue.sh", "launch_detached.sh"):
            (temporary / name).chmod(0o555)
        manifest = temporary / "QUEUE_MANIFEST.sha256"
        manifest.write_text(
            "".join(
                f"{sha256_file(temporary / name)}  {name}\n"
                for name in sorted(FILES)
            ),
            encoding="utf-8",
        )
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
    parser.add_argument(
        "--freeze",
        required=True,
        type=Path,
        help="built freeze root containing the top-level MANIFEST.sha256",
    )
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.source, args.freeze, args.output)
    print(f"queue={args.output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
