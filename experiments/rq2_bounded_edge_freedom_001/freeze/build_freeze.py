#!/usr/bin/env python3
"""Build the immutable v1 freeze for RQ2-BOUNDED-EDGE-FREEDOM-001."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tempfile


EXPERIMENT_ID = "RQ2-BOUNDED-EDGE-FREEDOM-001"
ATTEMPT_ID = "2026-11-03_v1"
EXPERIMENT_ROOT = Path(__file__).resolve().parents[1]
EXPERIMENTS_ROOT = EXPERIMENT_ROOT.parent

CAUSAL_FREEZE = (
    EXPERIMENTS_ROOT
    / "rq2_causal_factors_001"
    / "freeze"
    / "2026-11-01_v2"
)
BLOCK_A_CALIBRATION = (
    EXPERIMENTS_ROOT
    / "rq2_causal_factors_001"
    / "results"
    / "2026-11-01_v2"
    / "block_a_calibration_20001_20024"
)
PREDECESSOR_FAILURE = (
    EXPERIMENTS_ROOT
    / "rq2_edge_freedom_001"
    / "results"
    / "2026-11-03_v1"
    / "anchor_61497_61520"
)
JADE_PROJECT = Path(
    "/home/gabiel/Documents/GitHub/JadeJcade-worktrees/awgn-jade-coral-20261012"
)
JADE_EXPECTED_HEAD = "a4a4f81cec9e1a38a76ece5867b81284324f1eea"

EXPECTED_MANIFEST_SHA256 = {
    CAUSAL_FREEZE / "MANIFEST.sha256":
        "1ae538d4101354cf57f47d5066eebe3d2954a6ff545f74ba9bb245edd2ca884d",
    BLOCK_A_CALIBRATION / "MANIFEST.sha256":
        "c8db9c80b6b1a80a07c3121d074a3aec845313b0f97f69184bdc3e4267fab492",
    PREDECESSOR_FAILURE / "MANIFEST.sha256":
        "c6baf082818187f8d38cc0b1fd9ca976c005ec7c6ddaf715d706788d9b6ed3f4",
}

EXPECTED_JADE_FILES = {
    JADE_PROJECT / "Project.toml":
        "29b094478b8b4ab89606ca4f9f4a1c8495ebe74ea473372a3b04faef6c40dc04",
    JADE_PROJECT / "Manifest.toml":
        "c0d828e48da8b5bf0acacceacb3fdcfacd0b9b1c2b2766600d11154700016eff",
    JADE_PROJECT / "src" / "ReceiverCore.jl":
        "98f03da65e8b791e132e57761e3577f46d0f97c5cf802449271838f43f8b6dd0",
    JADE_PROJECT / "src" / "core" / "common.jl":
        "f4bb1b5aefbc800d51221f732a44532a8dd2128a260fbbb3f6d9c54adf27bba5",
    JADE_PROJECT / "src" / "core" / "joint_cz_projected_gradient.jl":
        "c1ba501be0d13269032706f55a80dbd465938c3f4ce71679d5948fc77ecc1c4a",
}

OWN_FILES = (
    "README.md",
    "config.toml",
    "experiment_card.md",
    "derivation_card.md",
    "rq2_bounded_edge_freedom_001.jl",
    "test_rq2_bounded_edge_freedom_001.jl",
    "freeze/build_freeze.py",
)


class FreezeError(RuntimeError):
    """Raised when a source identity or freeze invariant does not hold."""


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
            raise FreezeError(
                f"malformed manifest line {number}: {manifest}") from error
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
    shutil.copy2(
        source_root / "MANIFEST.sha256",
        target_root / "MANIFEST.sha256",
        follow_symlinks=False,
    )
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
    (root / "MANIFEST.sha256").write_text(
        "".join(f"{sha256_file(root / name)}  {name}\n" for name in names),
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
        timespec="seconds").replace("+00:00", "Z")


def build(output: Path) -> None:
    output = output.resolve()
    if output.exists():
        raise FreezeError(f"refusing to overwrite freeze: {output}")

    for manifest, expected in EXPECTED_MANIFEST_SHA256.items():
        verify_regular(manifest)
        if sha256_file(manifest) != expected:
            raise FreezeError(f"pinned manifest digest differs: {manifest}")
        manifest_entries(manifest.parent)

    head = subprocess.check_output(
        ["git", "-C", str(JADE_PROJECT), "rev-parse", "HEAD"],
        text=True,
    ).strip()
    if head != JADE_EXPECTED_HEAD:
        raise FreezeError(
            f"registered Julia project HEAD differs: {head}")
    for path, expected in EXPECTED_JADE_FILES.items():
        verify_regular(path)
        if sha256_file(path) != expected:
            raise FreezeError(f"registered Julia project file differs: {path}")

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(
        prefix=f".{output.name}.tmp.", dir=output.parent))
    try:
        own_target = temporary / "source" / EXPERIMENT_ROOT.name
        for relative in OWN_FILES:
            copy_regular(EXPERIMENT_ROOT / relative, own_target / relative)

        copy_manifest_tree(
            CAUSAL_FREEZE,
            temporary
            / "source"
            / "rq2_causal_factors_001"
            / "freeze"
            / "2026-11-01_v2",
        )
        copy_manifest_tree(
            BLOCK_A_CALIBRATION,
            temporary
            / "source"
            / "rq2_causal_factors_001"
            / "results"
            / "2026-11-01_v2"
            / "block_a_calibration_20001_20024",
        )
        copy_manifest_tree(
            PREDECESSOR_FAILURE,
            temporary
            / "source"
            / "rq2_edge_freedom_001"
            / "results"
            / "2026-11-03_v1"
            / "anchor_61497_61520",
        )

        metadata = [
            'schema_version = "rq2-bounded-edge-freedom-001/freeze-v1"',
            f'experiment_id = "{EXPERIMENT_ID}"',
            f'attempt_id = "{ATTEMPT_ID}"',
            f'created_utc = "{utc_now()}"',
            'causal_freeze_manifest_sha256 = '
            f'"{EXPECTED_MANIFEST_SHA256[CAUSAL_FREEZE / "MANIFEST.sha256"]}"',
            'block_a_calibration_manifest_sha256 = '
            f'"{EXPECTED_MANIFEST_SHA256[BLOCK_A_CALIBRATION / "MANIFEST.sha256"]}"',
            'predecessor_failure_manifest_sha256 = '
            f'"{EXPECTED_MANIFEST_SHA256[PREDECESSOR_FAILURE / "MANIFEST.sha256"]}"',
            'new_experiment_runs_evaluated_before_freeze = false',
            'retained_compatibility_cases_previously_evaluated = true',
            'fresh_anchor_or_transfer_cases_evaluated_before_freeze = false',
            f'jade_project_expected_head = "{JADE_EXPECTED_HEAD}"',
            f'jade_project_path = "{JADE_PROJECT}"',
            'jade_project_files_hash_checked = true',
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
    resolved = args.output.resolve()
    print(
        f"freeze={resolved} "
        f"manifest_sha256={sha256_file(resolved / 'MANIFEST.sha256')}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FreezeError, OSError, ValueError) as error:
        print(f"ERROR: {error}")
        raise SystemExit(2)
