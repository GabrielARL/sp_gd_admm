#!/usr/bin/env python3
"""Verify candidate and official freezes have identical scientific payloads."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import sys
from typing import Iterable


HASH_RE = re.compile(r"^[0-9a-f]{64}$")
EXCLUDED = {
    "MANIFEST.sha256",
    "freeze_manifest.toml",
    "rq2_exact_map_update_001/preflight_validation.toml",
}


class EquivalenceError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def iter_files(root: Path) -> Iterable[str]:
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise EquivalenceError(f"symlinks are forbidden: {path}")
        if path.is_file():
            yield path.relative_to(root).as_posix()
        elif not path.is_dir():
            raise EquivalenceError(f"special filesystem entry is forbidden: {path}")


def manifest(root: Path) -> dict[str, str]:
    path = root / "MANIFEST.sha256"
    if not path.is_file() or path.is_symlink():
        raise EquivalenceError(f"missing or indirect manifest: {path}")
    listed: dict[str, str] = {}
    for number, row in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        expected, separator, relative = row.partition("  ")
        if (
            not separator
            or not HASH_RE.fullmatch(expected)
            or not relative
            or relative.startswith("/")
            or relative in listed
        ):
            raise EquivalenceError(f"malformed manifest row {number}: {path}")
        listed[relative] = expected
    actual = set(iter_files(root))
    if actual != set(listed) | {"MANIFEST.sha256"}:
        raise EquivalenceError(f"freeze inventory differs from manifest: {root}")
    for relative, expected in listed.items():
        if sha256_file(root / relative) != expected:
            raise EquivalenceError(f"freeze checksum mismatch: {root / relative}")
    return listed


def fingerprint(root: Path) -> tuple[str, int]:
    listed = manifest(root)
    rows: list[str] = []
    for relative in sorted(set(listed) - EXCLUDED):
        mode = (root / relative).stat().st_mode
        executable = "x" if mode & stat.S_IXUSR else "-"
        rows.append(f"{relative}\0{listed[relative]}\0{executable}\n")
    if not rows:
        raise EquivalenceError(f"freeze has no scientific payload: {root}")
    return hashlib.sha256("".join(rows).encode()).hexdigest(), len(rows)


def verify(candidate: Path, official: Path) -> dict[str, object]:
    candidate = candidate.resolve()
    official = official.resolve()
    if candidate == official:
        raise EquivalenceError("candidate and official freeze paths must differ")
    candidate_hash, candidate_count = fingerprint(candidate)
    official_hash, official_count = fingerprint(official)
    if candidate_count != official_count or candidate_hash != official_hash:
        raise EquivalenceError(
            "candidate and official scientific payloads differ: "
            f"candidate={candidate_hash}/{candidate_count}, "
            f"official={official_hash}/{official_count}"
        )
    return {
        "schema_version": "rq2-exact-map-update-001/source-equivalence-v1",
        "status": "equal",
        "candidate_root": str(candidate),
        "official_root": str(official),
        "scientific_payload_sha256": candidate_hash,
        "scientific_payload_file_count": candidate_count,
        "excluded_paths": sorted(EXCLUDED),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--official", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.candidate, args.official), sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (EquivalenceError, OSError, UnicodeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
