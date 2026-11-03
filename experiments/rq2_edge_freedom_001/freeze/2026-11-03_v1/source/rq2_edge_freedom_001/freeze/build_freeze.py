#!/usr/bin/env python3
"""Build the immutable v1 source freeze for RQ2-EDGE-FREEDOM-001."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile


EXPERIMENT_ID = "RQ2-EDGE-FREEDOM-001"
ATTEMPT_ID = "2026-11-03_v1"
EXPERIMENT_ROOT = Path(__file__).resolve().parents[1]
EXPERIMENTS_ROOT = EXPERIMENT_ROOT.parent
NATIVE_FREEZE = (EXPERIMENTS_ROOT / "rq2_native_composition_001" /
                 "freeze" / "2026-11-01_v2")
NATIVE_ORACLE = (EXPERIMENTS_ROOT / "rq2_native_composition_001" /
                 "results" / "2026-11-01_v2" /
                 "03_native_endpoint_and_rung_gate")
TIED_ROOT = EXPERIMENTS_ROOT / "rq2_tied_scalar_edge_repro_001"
TIED_RESULT = TIED_ROOT / "results" / "2026-11-03_v1"

EXPECTED = {
    NATIVE_FREEZE / "MANIFEST.sha256":
        "02a333ed531a6b570b49f86db21ae6b4ccb6eb25e5d383e1262e1bdc0b017a5c",
    NATIVE_ORACLE / "MANIFEST.sha256":
        "face3a578fbf640a036e782c35aa6f88540162ac82afa19e2e3be84f33cd1a4f",
    TIED_RESULT / "MANIFEST.sha256":
        "695c648869e262e28309fe0734517d97b6cd7ad73a3b840858396a1d3075dedd",
    TIED_RESULT / "COMPLETED.toml":
        "231c4a035242db8a466a63ae81397909aa67368c60feeea2dc1083e65c5e1f10",
    TIED_RESULT / "job_gate.toml":
        "7bf28eec9728f2ed1f217d76be57e70a82ef99cf17d127b560049078475738fd",
}

OWN_FILES = (
    "README.md",
    "config.toml",
    "experiment_card.md",
    "rq2_edge_freedom_001.jl",
    "test_rq2_edge_freedom_001.jl",
    "freeze/build_freeze.py",
)

TIED_SOURCE_FILES = (
    "README.md",
    "config.toml",
    "reference_contract.toml",
    "rq2_tied_scalar_edge_repro_001.jl",
)


class FreezeError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_regular(path: Path) -> None:
    if not path.is_file() or path.is_symlink():
        raise FreezeError(f"source is missing, indirect, or not a file: {path}")


def manifest_entries(root: Path) -> list[tuple[str, str]]:
    manifest = root / "MANIFEST.sha256"
    verify_regular(manifest)
    entries: list[tuple[str, str]] = []
    for number, line in enumerate(
            manifest.read_text(encoding="utf-8").splitlines(), 1):
        if not line:
            continue
        try:
            digest, relative = line.split("  ", 1)
        except ValueError as error:
            raise FreezeError(f"malformed manifest line {number}: {manifest}") from error
        candidate = PurePosixPath(relative)
        if candidate.is_absolute() or ".." in candidate.parts or "." in candidate.parts:
            raise FreezeError(f"unsafe manifest path: {relative}")
        source = root / relative
        verify_regular(source)
        if sha256_file(source) != digest:
            raise FreezeError(f"manifest digest mismatch: {source}")
        entries.append((digest, relative))
    if not entries:
        raise FreezeError(f"empty manifest: {manifest}")
    return entries


def copy_manifest_tree(source_root: Path, target_root: Path) -> None:
    entries = manifest_entries(source_root)
    for _, relative in entries:
        source = source_root / relative
        target = target_root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target, follow_symlinks=False)
    target_root.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source_root / "MANIFEST.sha256",
                 target_root / "MANIFEST.sha256", follow_symlinks=False)
    manifest_entries(target_root)


def copy_regular(source: Path, target: Path) -> None:
    verify_regular(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target, follow_symlinks=False)


def write_root_manifest(root: Path) -> None:
    names = sorted(
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path != root / "MANIFEST.sha256"
    )
    (root / "MANIFEST.sha256").write_text("".join(
        f"{sha256_file(root / name)}  {name}\n" for name in names
    ), encoding="utf-8")


def make_read_only(root: Path) -> None:
    for path in sorted(root.rglob("*"), reverse=True):
        if path.is_file():
            executable = bool(path.stat().st_mode & stat.S_IXUSR)
            path.chmod(0o555 if executable else 0o444)
        elif path.is_dir():
            path.chmod(0o555)
    root.chmod(0o555)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(
        timespec="seconds").replace("+00:00", "Z")


def build(output: Path) -> None:
    output = output.resolve()
    if output.exists():
        raise FreezeError(f"refusing to overwrite freeze: {output}")
    for path, expected in EXPECTED.items():
        verify_regular(path)
        if sha256_file(path) != expected:
            raise FreezeError(f"pinned digest differs: {path}")
    manifest_entries(NATIVE_FREEZE)
    manifest_entries(NATIVE_ORACLE)
    manifest_entries(TIED_RESULT)

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.tmp.",
                                      dir=output.parent))
    try:
        own_target = temporary / "source" / EXPERIMENT_ROOT.name
        for relative in OWN_FILES:
            copy_regular(EXPERIMENT_ROOT / relative, own_target / relative)

        tied_target = temporary / "source" / TIED_ROOT.name
        for relative in TIED_SOURCE_FILES:
            copy_regular(TIED_ROOT / relative, tied_target / relative)

        copy_manifest_tree(
            NATIVE_FREEZE,
            temporary / "source" / "rq2_native_composition_001" /
            "freeze" / "2026-11-01_v2",
        )
        copy_manifest_tree(
            NATIVE_ORACLE,
            temporary / "source" / "rq2_native_composition_001" /
            "results" / "2026-11-01_v2" /
            "03_native_endpoint_and_rung_gate",
        )
        copy_manifest_tree(
            TIED_RESULT,
            temporary / "source" / TIED_ROOT.name /
            "results" / "2026-11-03_v1",
        )

        metadata = [
            'schema_version = "rq2-edge-freedom-001/freeze-v1"',
            f'experiment_id = "{EXPERIMENT_ID}"',
            f'attempt_id = "{ATTEMPT_ID}"',
            f'created_utc = "{utc_now()}"',
            f'native_freeze_manifest_sha256 = "{EXPECTED[NATIVE_FREEZE / "MANIFEST.sha256"]}"',
            f'tied_result_manifest_sha256 = "{EXPECTED[TIED_RESULT / "MANIFEST.sha256"]}"',
            'scientific_cases_evaluated_before_freeze = false',
        ]
        (temporary / "freeze_manifest.toml").write_text(
            "\n".join(metadata) + "\n", encoding="utf-8")
        write_root_manifest(temporary)
        make_read_only(temporary)
        os.replace(temporary, output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    build(args.output)
    print(f"freeze={args.output.resolve()} "
          f"manifest_sha256={sha256_file(args.output.resolve() / 'MANIFEST.sha256')}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FreezeError, OSError, ValueError) as error:
        print(f"ERROR: {error}")
        raise SystemExit(2)
