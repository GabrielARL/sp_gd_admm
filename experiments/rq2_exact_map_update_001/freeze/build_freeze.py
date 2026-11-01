#!/usr/bin/env python3
"""Build an immutable exact-map freeze from the verified predecessor payload."""

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
from typing import Any, Iterable

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore[no-redef]


EXPERIMENT_ID = "RQ2-EXACT-MAP-UPDATE-001"
SPEC_SCHEMA = "rq2-exact-map-update-001/freeze-spec-v1"
FREEZE_SCHEMA = "rq2-exact-map-update-001/freeze-v1"
RESERVED = {"MANIFEST.sha256", "freeze_manifest.toml"}
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
REQUIRED_ARCHIVES = {
    "rq2_exact_map_update_001/preflight_validation.toml",
    "rq2_exact_map_update_001/exact_map_update.jl",
    "rq2_exact_map_update_001/test_exact_map_update.jl",
    "rq2_exact_map_update_001/config.toml",
    "rq2_exact_map_update_001/experiment_card.md",
    "source/native_composition.jl",
    "source/jade_project/Project.toml",
    "source/jade_project/Manifest.toml",
    "source/jade_project/src/JadeJcade.jl",
    "source/jade_project/tools/ldpc/make-ldpc",
    "source/jade_project/tools/ldpc/make-gen",
    "source/jade_project/tools/ldpc/print-pchk",
    "source/jade_project/tools/ldpc/src/randfile",
    "rq2_bp_target_state_update_001/rq2_bp_target_state_update_001.jl",
}


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
    ):
        raise FreezeError(f"unsafe archive path: {value!r}")
    return value


def iter_files(root: Path) -> Iterable[str]:
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise FreezeError(f"symlinks are forbidden: {path}")
        if path.is_file():
            yield path.relative_to(root).as_posix()
        elif not path.is_dir():
            raise FreezeError(f"special filesystem entry is forbidden: {path}")


def parse_manifest(path: Path) -> dict[str, str]:
    if not path.is_file() or path.is_symlink():
        raise FreezeError(f"missing or indirect manifest: {path}")
    listed: dict[str, str] = {}
    for number, row in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        expected, separator, relative = row.partition("  ")
        if not separator or not HASH_RE.fullmatch(expected):
            raise FreezeError(f"malformed manifest row {number}: {path}")
        relative = safe_relative(relative)
        if relative in listed:
            raise FreezeError(f"duplicate manifest path: {relative}")
        listed[relative] = expected
    if not listed:
        raise FreezeError(f"empty manifest: {path}")
    return listed


def quoted(value: object) -> str:
    return json.dumps(str(value), ensure_ascii=True)


def load_spec(path: Path) -> tuple[str, Path, str, list[dict[str, str]]]:
    with path.open("rb") as handle:
        spec: dict[str, Any] = tomllib.load(handle)
    required = {
        "schema_version", "experiment_id", "attempt_id", "predecessor",
        "overlays",
    }
    if set(spec) != required:
        raise FreezeError("freeze specification has unexpected top-level fields")
    if spec["schema_version"] != SPEC_SCHEMA or spec["experiment_id"] != EXPERIMENT_ID:
        raise FreezeError("freeze specification schema or experiment ID mismatch")
    attempt_id = spec["attempt_id"]
    if not isinstance(attempt_id, str) or not re.fullmatch(
        r"[A-Za-z0-9_.-]{1,128}", attempt_id
    ):
        raise FreezeError(f"unsafe attempt_id: {attempt_id!r}")

    predecessor = spec["predecessor"]
    if not isinstance(predecessor, dict) or set(predecessor) != {
        "root", "manifest_sha256"
    }:
        raise FreezeError("predecessor fields differ from schema")
    raw_root = Path(str(predecessor["root"]))
    predecessor_root = raw_root if raw_root.is_absolute() else path.parent / raw_root
    predecessor_root = predecessor_root.resolve()
    if not predecessor_root.is_dir() or predecessor_root.is_symlink():
        raise FreezeError(f"predecessor freeze is missing or indirect: {predecessor_root}")
    predecessor_digest = str(predecessor["manifest_sha256"])
    if not HASH_RE.fullmatch(predecessor_digest):
        raise FreezeError("predecessor manifest_sha256 is invalid")

    raw_overlays = spec["overlays"]
    if not isinstance(raw_overlays, list) or not raw_overlays:
        raise FreezeError("freeze specification must list overlays")
    labels: set[str] = set()
    archives: set[str] = set()
    overlays: list[dict[str, str]] = []
    for index, raw in enumerate(raw_overlays):
        if not isinstance(raw, dict) or set(raw) != {"label", "path", "archive_as"}:
            raise FreezeError(f"overlays[{index}] fields differ from schema")
        label = str(raw["label"])
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", label) or label in labels:
            raise FreezeError(f"unsafe or duplicate overlay label: {label!r}")
        labels.add(label)
        archive_as = safe_relative(str(raw["archive_as"]))
        if archive_as in RESERVED:
            raise FreezeError(f"overlay cannot replace freeze metadata: {archive_as}")
        if not archive_as.startswith("rq2_exact_map_update_001/"):
            raise FreezeError("new overlays must remain under rq2_exact_map_update_001/")
        if archive_as in archives:
            raise FreezeError(f"duplicate overlay archive path: {archive_as}")
        archives.add(archive_as)
        original_raw = Path(str(raw["path"]))
        original = original_raw if original_raw.is_absolute() else path.parent / original_raw
        if not original.is_file() or original.is_symlink():
            raise FreezeError(f"overlay is missing, indirect, or not a file: {original}")
        overlays.append({
            "label": label,
            "path": str(original.resolve()),
            "archive_as": archive_as,
        })
    return attempt_id, predecessor_root, predecessor_digest, overlays


def verify_predecessor(root: Path, expected_manifest_sha256: str) -> dict[str, str]:
    manifest_path = root / "MANIFEST.sha256"
    if sha256_file(manifest_path) != expected_manifest_sha256:
        raise FreezeError("predecessor manifest digest differs from registration")
    listed = parse_manifest(manifest_path)
    actual = set(iter_files(root))
    if actual != set(listed) | {"MANIFEST.sha256"}:
        raise FreezeError("predecessor inventory differs from its manifest")
    for relative, expected in listed.items():
        if sha256_file(root / relative) != expected:
            raise FreezeError(f"predecessor checksum mismatch: {relative}")
    if "freeze_manifest.toml" not in listed:
        raise FreezeError("predecessor manifest omits freeze metadata")
    return listed


def build_freeze(spec_path: Path, output: Path) -> dict[str, object]:
    spec_path = spec_path.resolve()
    output = output.resolve()
    if output.exists():
        raise FreezeError(f"refusing to overwrite freeze: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    attempt_id, predecessor_root, predecessor_digest, overlays = load_spec(spec_path)
    predecessor = verify_predecessor(predecessor_root, predecessor_digest)
    payload_paths = sorted(set(predecessor) - RESERVED)
    if set(source["archive_as"] for source in overlays) & set(payload_paths):
        raise FreezeError("overlay would overwrite a predecessor payload file")

    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.tmp.", dir=output.parent))
    records: list[dict[str, object]] = []
    try:
        for index, relative in enumerate(payload_paths, 1):
            original = predecessor_root / relative
            target = temporary / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, target)
            executable = bool(original.stat().st_mode & stat.S_IXUSR)
            target.chmod(0o555 if executable else 0o444)
            records.append({
                "label": f"predecessor_{index:04d}",
                "original_path": str(original),
                "archived_relative_path": relative,
                "sha256": sha256_file(target),
                "executable": executable,
            })
        for source in overlays:
            original = Path(source["path"])
            target = temporary / source["archive_as"]
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, target)
            executable = bool(original.stat().st_mode & stat.S_IXUSR)
            target.chmod(0o555 if executable else 0o444)
            records.append({
                "label": source["label"],
                "original_path": str(original),
                "archived_relative_path": source["archive_as"],
                "sha256": sha256_file(target),
                "executable": executable,
            })

        archived = {str(record["archived_relative_path"]) for record in records}
        if not REQUIRED_ARCHIVES.issubset(archived):
            raise FreezeError(
                "freeze misses required archives: "
                + repr(sorted(REQUIRED_ARCHIVES - archived))
            )
        rows = [
            f"schema_version = {quoted(FREEZE_SCHEMA)}",
            f"experiment_id = {quoted(EXPERIMENT_ID)}",
            f"attempt_id = {quoted(attempt_id)}",
            f"created_utc = {quoted(utc_now())}",
            f"source_spec_sha256 = {quoted(sha256_file(spec_path))}",
            f"predecessor_root = {quoted(predecessor_root)}",
            f"predecessor_manifest_sha256 = {quoted(predecessor_digest)}",
            f"predecessor_payload_file_count = {len(payload_paths)}",
            f"overlay_file_count = {len(overlays)}",
            f"file_count = {len(records)}",
        ]
        for record in records:
            rows.extend([
                "", "[[sources]]",
                f"label = {quoted(record['label'])}",
                f"original_path = {quoted(record['original_path'])}",
                f"archived_relative_path = {quoted(record['archived_relative_path'])}",
                f"sha256 = {quoted(record['sha256'])}",
                f"executable = {'true' if record['executable'] else 'false'}",
            ])
        metadata = temporary / "freeze_manifest.toml"
        metadata.write_text("\n".join(rows) + "\n", encoding="utf-8")
        metadata.chmod(0o444)
        files = sorted(iter_files(temporary))
        checksum = temporary / "MANIFEST.sha256"
        checksum.write_text(
            "".join(
                f"{sha256_file(temporary / relative)}  {relative}\n"
                for relative in files
            ),
            encoding="utf-8",
        )
        checksum.chmod(0o444)
        os.replace(temporary, output)
        return {
            "freeze_root": str(output),
            "attempt_id": attempt_id,
            "predecessor_payload_file_count": len(payload_paths),
            "overlay_file_count": len(overlays),
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
    print(json.dumps(build_freeze(args.spec, args.output), sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FreezeError, OSError, KeyError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
