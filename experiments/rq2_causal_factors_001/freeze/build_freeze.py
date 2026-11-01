#!/usr/bin/env python3
"""Build a new checksum-locked RQ2 causal-factor source freeze."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tempfile
from typing import Any

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore[no-redef]


EXPERIMENT_ID = "RQ2-CAUSAL-FACTORS-001"
SPEC_SCHEMA = "rq2-causal-factors-001/freeze-spec-v1"
FREEZE_SCHEMA = "rq2-causal-factors-001/freeze-v1"
RESERVED = {"MANIFEST.sha256", "freeze_manifest.toml"}


class FreezeError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_relative(value: str) -> str:
    candidate = PurePosixPath(value)
    if (
        not value
        or candidate.is_absolute()
        or value != candidate.as_posix()
        or "." in candidate.parts
        or ".." in candidate.parts
        or value in RESERVED
    ):
        raise FreezeError(f"unsafe archive_as value: {value!r}")
    return value


def quoted(value: object) -> str:
    return json.dumps(str(value), ensure_ascii=True)


def load_spec(path: Path) -> tuple[str, list[dict[str, str]]]:
    with path.open("rb") as handle:
        spec: dict[str, Any] = tomllib.load(handle)
    if set(spec) != {"schema_version", "experiment_id", "attempt_id", "sources"}:
        raise FreezeError("freeze specification has unexpected top-level fields")
    if spec["schema_version"] != SPEC_SCHEMA or spec["experiment_id"] != EXPERIMENT_ID:
        raise FreezeError("freeze specification schema or experiment ID mismatch")
    attempt_id = spec["attempt_id"]
    if not isinstance(attempt_id, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", attempt_id):
        raise FreezeError(f"unsafe attempt_id: {attempt_id!r}")
    raw_sources = spec["sources"]
    if not isinstance(raw_sources, list) or not raw_sources:
        raise FreezeError("freeze specification must list at least one source")
    labels: set[str] = set()
    archives: set[str] = set()
    sources: list[dict[str, str]] = []
    for index, raw in enumerate(raw_sources):
        if not isinstance(raw, dict) or set(raw) != {"label", "path", "archive_as"}:
            raise FreezeError(f"sources[{index}] fields differ from the registered schema")
        label = str(raw["label"])
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", label) or label in labels:
            raise FreezeError(f"unsafe or duplicate source label: {label!r}")
        labels.add(label)
        archive_as = safe_relative(str(raw["archive_as"]))
        if archive_as in archives:
            raise FreezeError(f"duplicate archive path: {archive_as}")
        archives.add(archive_as)
        original_raw = Path(str(raw["path"]))
        original = original_raw if original_raw.is_absolute() else path.parent / original_raw
        if not original.is_file() or original.is_symlink():
            raise FreezeError(f"source is missing, indirect, or not a file: {original}")
        sources.append(
            {
                "label": label,
                "path": str(original.resolve()),
                "archive_as": archive_as,
            }
        )
    return attempt_id, sources


def build_freeze(spec_path: Path, output: Path) -> dict[str, object]:
    spec_path = spec_path.resolve()
    output = output.resolve()
    if output.exists():
        raise FreezeError(f"refusing to overwrite freeze: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    attempt_id, sources = load_spec(spec_path)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.tmp.", dir=output.parent))
    records: list[dict[str, object]] = []
    try:
        for source in sources:
            original = Path(source["path"])
            target = temporary / source["archive_as"]
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, target)
            executable = bool(original.stat().st_mode & stat.S_IXUSR)
            target.chmod(0o555 if executable else 0o444)
            records.append(
                {
                    "label": source["label"],
                    "original_path": str(original),
                    "archived_relative_path": source["archive_as"],
                    "sha256": sha256_file(target),
                    "executable": executable,
                }
            )
        manifest_rows = [
            f"schema_version = {quoted(FREEZE_SCHEMA)}",
            f"experiment_id = {quoted(EXPERIMENT_ID)}",
            f"attempt_id = {quoted(attempt_id)}",
            f"created_utc = {quoted(utc_now())}",
            f"source_spec_sha256 = {quoted(sha256_file(spec_path))}",
            f"file_count = {len(records)}",
        ]
        for record in records:
            manifest_rows.extend(
                [
                    "",
                    "[[sources]]",
                    f"label = {quoted(record['label'])}",
                    f"original_path = {quoted(record['original_path'])}",
                    f"archived_relative_path = {quoted(record['archived_relative_path'])}",
                    f"sha256 = {quoted(record['sha256'])}",
                    f"executable = {'true' if record['executable'] else 'false'}",
                ]
            )
        freeze_manifest = temporary / "freeze_manifest.toml"
        freeze_manifest.write_text("\n".join(manifest_rows) + "\n", encoding="utf-8")
        freeze_manifest.chmod(0o444)
        files = sorted(
            path.relative_to(temporary).as_posix()
            for path in temporary.rglob("*")
            if path.is_file()
        )
        checksum_text = "".join(
            f"{sha256_file(temporary / relative)}  {relative}\n" for relative in files
        )
        checksum_path = temporary / "MANIFEST.sha256"
        checksum_path.write_text(checksum_text, encoding="utf-8")
        checksum_path.chmod(0o444)
        os.replace(temporary, output)
        return {
            "freeze_root": str(output),
            "attempt_id": attempt_id,
            "source_count": len(records),
            "manifest_sha256": sha256_file(output / "MANIFEST.sha256"),
        }
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(arguments)
    result = build_freeze(args.spec, args.output)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FreezeError, OSError, ValueError, KeyError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)

