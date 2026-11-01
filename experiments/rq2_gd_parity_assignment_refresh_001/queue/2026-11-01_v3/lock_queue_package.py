#!/usr/bin/env python3
"""Create the one-time immutable checksum record for a clean queue package."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

sys.dont_write_bytecode = True

from status_report import (
    EXPERIMENT_ID,
    LOCK_NAME,
    LOCK_SCHEMA,
    MANIFEST_NAME,
    GateError,
    immutable_inventory,
    iter_files,
    queue_config,
    sha256_file,
    telemetry_inventory,
    verify_budget,
    verify_queue_package,
)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def atomic_create(path: Path, text: str) -> None:
    if path.exists():
        raise GateError(f"refusing to overwrite package metadata: {path}")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.tmp.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise GateError(f"refusing to overwrite package metadata: {path}") from error
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)


def render_toml(fields: dict[str, object]) -> str:
    rows: list[str] = []
    for key, value in fields.items():
        if isinstance(value, bool):
            rendered = "true" if value else "false"
        elif isinstance(value, int):
            rendered = str(value)
        else:
            rendered = json.dumps(str(value), ensure_ascii=True)
        rows.append(f"{key} = {rendered}")
    return "\n".join(rows) + "\n"


def assert_executable(path: Path) -> None:
    mode = path.stat().st_mode
    if not stat.S_ISREG(mode) or not mode & stat.S_IXUSR:
        raise GateError(f"registered launcher is not executable by its owner: {path.name}")


def lock_package(queue_root: Path) -> dict[str, object]:
    queue_root = queue_root.resolve()
    if not queue_root.is_dir():
        raise GateError(f"queue root does not exist: {queue_root}")
    manifest_path = queue_root / MANIFEST_NAME
    lock_path = queue_root / LOCK_NAME
    if manifest_path.exists() or lock_path.exists():
        raise GateError("queue package is already locked or partially locked")

    config = queue_config(queue_root)
    immutable = set(immutable_inventory(config))
    telemetry = telemetry_inventory(config)
    present = set(iter_files(queue_root))
    telemetry_present = present & telemetry
    if telemetry_present:
        raise GateError(
            "queue telemetry already exists before first lock: "
            + ", ".join(sorted(telemetry_present))
        )
    if present != immutable:
        raise GateError(
            "pre-lock queue inventory is not exact: "
            f"unlisted={sorted(present-immutable)}, missing={sorted(immutable-present)}"
        )

    for relative in immutable:
        path = queue_root / relative
        if path.is_symlink() or not path.is_file():
            raise GateError(f"immutable entry is not a regular file: {relative}")
    for relative in ("run_anchor_once.sh", "run_queue.sh"):
        assert_executable(queue_root / relative)

    # A malformed or cross-stage budget must never become immutable merely
    # because its bytes were listed in queue.toml.
    verify_budget(queue_root, "transfer")
    verify_budget(queue_root, "attribution")

    manifest_text = "".join(
        f"{sha256_file(queue_root / relative)}  {relative}\n"
        for relative in sorted(immutable)
    )
    atomic_create(manifest_path, manifest_text)
    try:
        lock_text = render_toml(
            {
                "schema_version": LOCK_SCHEMA,
                "experiment_id": EXPERIMENT_ID,
                "queue_id": config["queue_id"],
                "queue_manifest_sha256": sha256_file(manifest_path),
                "locked_file_count": len(immutable),
                "locked_utc": utc_now(),
            }
        )
        atomic_create(lock_path, lock_text)
        verified = verify_queue_package(queue_root)
    except Exception:
        # A failed initial lock is not an experiment attempt.  Remove only the
        # two metadata files this invocation created, leaving authored inputs.
        lock_path.unlink(missing_ok=True)
        manifest_path.unlink(missing_ok=True)
        raise
    return verified


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--queue-root", required=True, type=Path)
    args = parser.parse_args(arguments)
    result = lock_package(args.queue_root)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (GateError, OSError, KeyError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
