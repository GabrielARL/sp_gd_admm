#!/usr/bin/env python3
"""Build the immutable source and retained-oracle freeze for this gate."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile


EXPERIMENT_ID = "RQ2-COMMON-COORDINATE-REPRO-001"
ATTEMPT_ID = "2026-11-03_v1"
EXPERIMENT_ROOT = Path(__file__).resolve().parents[1]
EXPERIMENTS_ROOT = EXPERIMENT_ROOT.parent
UPSTREAM_FREEZE = (
    EXPERIMENTS_ROOT / "rq2_native_composition_001" /
    "freeze" / "2026-11-01_v2"
)
UPSTREAM_RESULT = (
    EXPERIMENTS_ROOT / "rq2_native_composition_001" /
    "results" / "2026-11-01_v2" / "03_native_endpoint_and_rung_gate"
)

EXPECTED = {
    UPSTREAM_FREEZE / "MANIFEST.sha256":
        "02a333ed531a6b570b49f86db21ae6b4ccb6eb25e5d383e1262e1bdc0b017a5c",
    UPSTREAM_FREEZE / "freeze_manifest.toml":
        "625062ddac3a35cca89f22ab372868cabbcb9381e6b5983ef928e193346f3da7",
    UPSTREAM_RESULT / "MANIFEST.sha256":
        "face3a578fbf640a036e782c35aa6f88540162ac82afa19e2e3be84f33cd1a4f",
    UPSTREAM_RESULT / "science.json":
        "6f7039e1172a81f4e6e641d6aaf9a0554b66ab856689ad2009d2188fc04a34eb",
    UPSTREAM_RESULT / "frames.csv":
        "3d401dbe7abcd5807755fe4b0ded6e92952e716c8b57c26972dc228272fdeed2",
    UPSTREAM_RESULT / "iterations.csv":
        "6775f27af9d219bd6a521b618da4c4159255bd09d9e951548635c1b2c3089af2",
    UPSTREAM_RESULT / "COMPLETED.toml":
        "dad9a542b39049cd5635eed41572f78e18a45d00486688f8fcb12f64ba58e22b",
    UPSTREAM_RESULT / "job_gate.toml":
        "e7ebae26eb91269eaf2a450ef6bad3736d68fcceaf5cee76ec950d3e728ecc09",
}

OWN_FILES = (
    "README.md",
    "config.toml",
    "experiment_card.md",
    "reference_contract.toml",
    "rq2_common_coordinate_repro_001.jl",
    "terminology_ledger.txt",
    "test_rq2_common_coordinate_repro_001.jl",
    "freeze/build_freeze.py",
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
        manifest.read_text(encoding="utf-8").splitlines(), 1
    ):
        if not line:
            continue
        try:
            digest, relative = line.split("  ", 1)
        except ValueError as error:
            raise FreezeError(
                f"malformed manifest line {number}: {manifest}"
            ) from error
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
    shutil.copy2(
        source_root / "MANIFEST.sha256",
        target_root / "MANIFEST.sha256",
        follow_symlinks=False,
    )
    manifest_entries(target_root)


def write_root_manifest(root: Path) -> None:
    files = sorted(
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path.name != "MANIFEST.sha256"
    )
    for path in root.rglob("MANIFEST.sha256"):
        if path.parent != root:
            files.append(path.relative_to(root).as_posix())
    files = sorted(set(files))
    (root / "MANIFEST.sha256").write_text(
        "".join(
            f"{sha256_file(root / relative)}  {relative}\n"
            for relative in files
        ),
        encoding="utf-8",
    )


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
        timespec="seconds"
    ).replace("+00:00", "Z")


def build(output: Path) -> None:
    output = output.resolve()
    if output.exists():
        raise FreezeError(f"refusing to overwrite freeze: {output}")
    for path, expected in EXPECTED.items():
        verify_regular(path)
        if sha256_file(path) != expected:
            raise FreezeError(f"pinned upstream digest differs: {path}")
    manifest_entries(UPSTREAM_FREEZE)
    manifest_entries(UPSTREAM_RESULT)

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(
        prefix=f".{output.name}.tmp.", dir=output.parent
    ))
    try:
        own_target = temporary / "source" / EXPERIMENT_ROOT.name
        for relative in OWN_FILES:
            source = EXPERIMENT_ROOT / relative
            verify_regular(source)
            target = own_target / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target, follow_symlinks=False)

        freeze_target = (
            temporary / "source" / "rq2_native_composition_001" /
            "freeze" / "2026-11-01_v2"
        )
        result_target = (
            temporary / "source" / "rq2_native_composition_001" /
            "results" / "2026-11-01_v2" /
            "03_native_endpoint_and_rung_gate"
        )
        freeze_target.mkdir(parents=True)
        result_target.mkdir(parents=True)
        copy_manifest_tree(UPSTREAM_FREEZE, freeze_target)
        copy_manifest_tree(UPSTREAM_RESULT, result_target)

        metadata = [
            'schema_version = "rq2-common-coordinate-repro-001/freeze-v1"',
            f'experiment_id = "{EXPERIMENT_ID}"',
            f'attempt_id = "{ATTEMPT_ID}"',
            f'created_utc = "{utc_now()}"',
            f'upstream_freeze_manifest_sha256 = "{EXPECTED[UPSTREAM_FREEZE / "MANIFEST.sha256"]}"',
            f'upstream_result_manifest_sha256 = "{EXPECTED[UPSTREAM_RESULT / "MANIFEST.sha256"]}"',
            'performance_inference_allowed = false',
        ]
        (temporary / "freeze_manifest.toml").write_text(
            "\n".join(metadata) + "\n", encoding="utf-8"
        )
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
    print(
        f"freeze={args.output.resolve()} "
        f"manifest_sha256={sha256_file(args.output.resolve() / 'MANIFEST.sha256')}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
