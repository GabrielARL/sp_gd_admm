#!/usr/bin/env python3
"""Create and lock one non-resumable factorial experiment attempt.

The attempt has three preparation boundaries.  ``create_attempt_preflight``
creates one attempt-local preflight from a hash-pinned template.  ``initialize``
then requires that record to have passed and creates only the attempt-specific
``queue.toml`` needed by the frozen anchor wrapper.  After a complete-valid
anchor, ``finalize`` derives both registered budgets, copies the exact
immutable governance inventory from the freeze, locks the queue package, and
verifies it through the frozen read-only checker.

Neither boundary overwrites an existing path.  A failed or interrupted attempt
is therefore retained and a new attempt ID is required.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
from typing import Any, Callable, Sequence

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # pragma: no cover - registered host has tomllib
    import tomli as tomllib  # type: ignore[no-redef]


EXPERIMENT_ID = "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001"
EXPERIMENT_RELATIVE = Path("experiments/rq2_gd_parity_assignment_refresh_001")
QUEUE_SCHEMA = "rq2-gd-parity-assignment-refresh-001/queue-v1"
ATTEMPT_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
PREFLIGHT_TEMPLATE_NAME = "PREFLIGHT.template.md"
PREFLIGHT_TEMPLATE_SHA256 = (
    "23a35c7bd7941eccd658d723d864f2fbf1c2184fc09bc9d2c5a90065d073dd62"
)

REGISTERED_EXECUTION: dict[str, object] = {
    "anchor_wall_budget_seconds": 7200,
    "anchor_term_after_seconds": 7080,
    "termination_grace_seconds": 120,
    "maximum_nonanchor_wall_budget_seconds": 36000,
    "julia_threads": 1,
    "omp_threads": 1,
    "blas_threads": 1,
    "nice": 19,
    "ionice_class": "idle",
    "scientific_unit_pattern": "sp-gd-*.service",
    "anchor_unit_name":
        "sp-gd-rq2-parity-assignment-refresh-anchor-20261031.service",
    "queue_unit_name":
        "sp-gd-rq2-parity-assignment-refresh-20261031.service",
}

IMMUTABLE_SOURCE_MAP = {
    "README.md": "QUEUE_PACKAGE_README.template.md",
    "derive_budget.py": "derive_budget.py",
    "lock_queue_package.py": "lock_queue_package.py",
    "run_anchor_once.sh": "run_anchor_once.sh",
    "run_queue.sh": "run_queue.sh",
    "status_report.py": "status_report.py",
}
EXPECTED_IMMUTABLE = {
    "README.md",
    "budget_attribution.toml",
    "budget_transfer.toml",
    "derive_budget.py",
    "lock_queue_package.py",
    "queue.toml",
    "run_anchor_once.sh",
    "run_queue.sh",
    "status_report.py",
}


class PreparationError(RuntimeError):
    """An attempt preparation gate failed."""


@dataclass(frozen=True)
class AttemptPaths:
    repo_root: Path
    experiment_root: Path
    preflight: Path
    freeze: Path
    anchor_result: Path
    transfer_result: Path
    attribution_result: Path
    queue_root: Path
    project_root: Path
    config: Path
    runner: Path

    def as_dict(self) -> dict[str, str]:
        return {name: str(getattr(self, name)) for name in self.__dataclass_fields__}


CommandRunner = Callable[..., subprocess.CompletedProcess[str]]


def load_toml(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        return tomllib.load(handle)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run_checked(
    command: Sequence[str],
    *,
    command_runner: CommandRunner = subprocess.run,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    completed = command_runner(
        [str(value) for value in command],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        env=env,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise PreparationError(
            f"command failed ({completed.returncode}): "
            f"{' '.join(str(value) for value in command)}"
            + (f"\n{detail}" if detail else "")
        )
    return completed


def validate_attempt_id(attempt_id: str) -> str:
    if not ATTEMPT_PATTERN.fullmatch(attempt_id):
        raise PreparationError(
            "attempt ID must match [A-Za-z0-9][A-Za-z0-9_.-]{0,63}"
        )
    return attempt_id


def authored_paths(repo_root: Path, attempt_id: str) -> AttemptPaths:
    attempt_id = validate_attempt_id(attempt_id)
    repo_root = repo_root.resolve()
    experiment_root = repo_root / EXPERIMENT_RELATIVE
    config = experiment_root / "config.toml"
    runner = experiment_root / "rq2_gd_parity_assignment_refresh_001.jl"
    split_config = (
        experiment_root / "vendor/rq2_gd_offset_split_001/config.toml"
    )
    for required in (repo_root, experiment_root, config, runner, split_config):
        if not required.exists() or required.is_symlink():
            raise PreparationError(f"missing or indirect authored input: {required}")
    experiment = load_toml(config)
    if experiment.get("experiment_id") != EXPERIMENT_ID:
        raise PreparationError("authored configuration has the wrong experiment ID")
    if experiment.get("queue_plan") != REGISTERED_EXECUTION:
        raise PreparationError("authored queue plan differs from the registered plan")
    project_raw = str(
        load_toml(split_config).get("sources", {}).get("jade_project_repo", "")
    )
    project_root = Path(project_raw)
    if not project_root.is_absolute() or not project_root.is_dir() or project_root.is_symlink():
        raise PreparationError(
            f"registered Julia project root is unavailable or indirect: {project_root}"
        )
    return AttemptPaths(
        repo_root=repo_root,
        experiment_root=experiment_root,
        preflight=(
            experiment_root
            / "preflight"
            / attempt_id
            / "preflight_validation.md"
        ),
        freeze=experiment_root / "freeze" / attempt_id,
        anchor_result=experiment_root / "results" / f"{attempt_id}_anchor",
        transfer_result=experiment_root / "results" / f"{attempt_id}_transfer",
        attribution_result=experiment_root / "results" / f"{attempt_id}_attribution",
        queue_root=experiment_root / "queue" / attempt_id,
        project_root=project_root,
        config=config,
        runner=runner,
    )


def _relative_to_repository(path: Path, repository: Path) -> str:
    try:
        return path.relative_to(repository).as_posix()
    except ValueError as error:  # pragma: no cover - paths are constructed above
        raise PreparationError(f"path escaped repository: {path}") from error


def render_queue(paths: AttemptPaths, attempt_id: str) -> str:
    template_path = paths.experiment_root / "queue_tools/queue_template.toml"
    if not template_path.is_file() or template_path.is_symlink():
        raise PreparationError(f"missing queue template: {template_path}")
    queue_id = f"RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001.{attempt_id}"
    replacements = {
        'queue_id = "REPLACE-WITH-UNIQUE-ATTEMPT-ID"':
            f'queue_id = {json.dumps(queue_id)}',
        'repository_root = "/absolute/path/to/sp_gd_admm-worktree"':
            f'repository_root = {json.dumps(str(paths.repo_root))}',
        'project_root = "/absolute/path/to/JadeJcade-project"':
            f'project_root = {json.dumps(str(paths.project_root))}',
        'freeze = "experiments/rq2_gd_parity_assignment_refresh_001/freeze/REPLACE"':
            f'freeze = {json.dumps(_relative_to_repository(paths.freeze, paths.repo_root))}',
        'preflight = "experiments/rq2_gd_parity_assignment_refresh_001/preflight/REPLACE/preflight_validation.md"':
            f'preflight = {json.dumps(_relative_to_repository(paths.preflight, paths.repo_root))}',
        'anchor_result = "experiments/rq2_gd_parity_assignment_refresh_001/results/REPLACE_anchor"':
            f'anchor_result = {json.dumps(_relative_to_repository(paths.anchor_result, paths.repo_root))}',
        'transfer_result = "experiments/rq2_gd_parity_assignment_refresh_001/results/REPLACE_transfer"':
            f'transfer_result = {json.dumps(_relative_to_repository(paths.transfer_result, paths.repo_root))}',
        'attribution_result = "experiments/rq2_gd_parity_assignment_refresh_001/results/REPLACE_attribution"':
            f'attribution_result = {json.dumps(_relative_to_repository(paths.attribution_result, paths.repo_root))}',
    }
    rendered = template_path.read_text(encoding="utf-8")
    for old, new in replacements.items():
        if rendered.count(old) != 1:
            raise PreparationError(f"queue template token changed or is ambiguous: {old}")
        rendered = rendered.replace(old, new)
    if "REPLACE" in rendered or "/absolute/path/to/" in rendered:
        raise PreparationError("queue template still contains an unfilled placeholder")
    parsed = tomllib.loads(rendered)
    if parsed.get("schema_version") != QUEUE_SCHEMA:
        raise PreparationError("rendered queue has the wrong schema")
    if parsed.get("experiment_id") != EXPERIMENT_ID:
        raise PreparationError("rendered queue has the wrong experiment ID")
    if parsed.get("execution") != REGISTERED_EXECUTION:
        raise PreparationError("rendered queue changed registered execution controls")
    expected_paths = {
        "repository_root": str(paths.repo_root),
        "project_root": str(paths.project_root),
        "config": _relative_to_repository(paths.config, paths.repo_root),
        "runner": _relative_to_repository(paths.runner, paths.repo_root),
        "preflight": _relative_to_repository(paths.preflight, paths.repo_root),
        "freeze": _relative_to_repository(paths.freeze, paths.repo_root),
        "anchor_result": _relative_to_repository(paths.anchor_result, paths.repo_root),
        "transfer_result": _relative_to_repository(paths.transfer_result, paths.repo_root),
        "attribution_result": _relative_to_repository(paths.attribution_result, paths.repo_root),
        "budget_transfer": "budget_transfer.toml",
        "budget_attribution": "budget_attribution.toml",
    }
    if parsed.get("paths") != expected_paths:
        raise PreparationError("rendered queue paths are not the exact attempt paths")
    immutable = set(parsed.get("inventory", {}).get("immutable_files", []))
    if immutable != EXPECTED_IMMUTABLE:
        raise PreparationError("rendered queue immutable inventory changed")
    return rendered


def _attempt_output_paths(paths: AttemptPaths) -> tuple[Path, ...]:
    return (
        paths.freeze,
        paths.anchor_result,
        paths.transfer_result,
        paths.attribution_result,
        paths.queue_root,
    )


def create_attempt_preflight(repo_root: Path, attempt_id: str) -> AttemptPaths:
    """Exclusively create one fresh attempt-local preflight record."""

    paths = authored_paths(repo_root, attempt_id)
    occupied = [
        path
        for path in (paths.preflight.parent, *_attempt_output_paths(paths))
        if path.exists() or path.is_symlink()
    ]
    if occupied:
        raise PreparationError(
            "refusing to overwrite or resume attempt paths: "
            + ", ".join(str(path) for path in occupied)
        )
    template = paths.experiment_root / "dispatcher" / PREFLIGHT_TEMPLATE_NAME
    if not template.is_file() or template.is_symlink():
        raise PreparationError(f"missing or indirect preflight template: {template}")
    if sha256_file(template) != PREFLIGHT_TEMPLATE_SHA256:
        raise PreparationError("preflight template differs from its pinned SHA-256")
    preflight_root = paths.preflight.parent.parent
    if preflight_root.is_symlink() or (
        preflight_root.exists() and not preflight_root.is_dir()
    ):
        raise PreparationError(
            f"attempt preflight root is indirect or not a directory: {preflight_root}"
        )
    preflight_root.mkdir(parents=True, exist_ok=True)
    created_directory = False
    created_file = False
    try:
        paths.preflight.parent.mkdir()
        created_directory = True
        with template.open("rb") as source, paths.preflight.open("xb") as target:
            created_file = True
            for block in iter(lambda: source.read(1024 * 1024), b""):
                target.write(block)
            target.flush()
            os.fsync(target.fileno())
        directory = os.open(paths.preflight.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except Exception as error:
        if created_file:
            paths.preflight.unlink(missing_ok=True)
        if created_directory:
            try:
                paths.preflight.parent.rmdir()
            except OSError:
                pass
        if isinstance(error, FileExistsError):
            raise PreparationError(
                f"refusing to overwrite or resume attempt preflight: {paths.preflight}"
            ) from error
        raise
    return paths


def require_passed_attempt_preflight(path: Path) -> None:
    if (
        not path.is_file()
        or path.is_symlink()
        or path.parent.is_symlink()
        or path.parent.parent.is_symlink()
    ):
        raise PreparationError(f"missing or indirect attempt preflight: {path}")
    statuses = [
        line.split(":", 1)[1].strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.startswith("validation_status:")
    ]
    if statuses != ["pass"]:
        raise PreparationError(
            f"attempt preflight is not a unique passed record: {path}"
        )


def initialize_attempt(repo_root: Path, attempt_id: str) -> AttemptPaths:
    paths = authored_paths(repo_root, attempt_id)
    require_passed_attempt_preflight(paths.preflight)
    occupied = [
        path
        for path in _attempt_output_paths(paths)
        if path.exists() or path.is_symlink()
    ]
    if occupied:
        raise PreparationError(
            "refusing to overwrite or resume attempt paths: "
            + ", ".join(str(path) for path in occupied)
        )
    rendered = render_queue(paths, attempt_id)
    paths.queue_root.parent.mkdir(parents=True, exist_ok=True)
    created_directory = False
    created_file = False
    try:
        paths.queue_root.mkdir()
        created_directory = True
        with (paths.queue_root / "queue.toml").open(
            "x", encoding="utf-8", newline=""
        ) as handle:
            created_file = True
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
    except Exception as error:
        # Remove only objects created by this invocation.  A concurrent
        # invocation's queue record is durable evidence and must be retained.
        queue_toml = paths.queue_root / "queue.toml"
        if created_file:
            queue_toml.unlink(missing_ok=True)
        if created_directory:
            try:
                paths.queue_root.rmdir()
            except OSError:
                pass
        if isinstance(error, FileExistsError):
            raise PreparationError(
                f"refusing to overwrite or resume attempt queue: {queue_toml}"
            ) from error
        raise
    return paths


def _resolve_queue_path(queue_root: Path, queue: dict[str, Any], key: str) -> Path:
    value = str(queue.get("paths", {}).get(key, ""))
    if not value:
        raise PreparationError(f"queue path is missing: {key}")
    candidate = Path(value)
    if candidate.is_absolute():
        return candidate.resolve()
    if ".." in candidate.parts or "." in candidate.parts:
        raise PreparationError(f"unsafe queue-relative path: {value}")
    if key.startswith("budget_"):
        return queue_root / candidate
    repository = Path(str(queue["paths"]["repository_root"]))
    if not repository.is_absolute():
        raise PreparationError("queue repository_root is not absolute")
    return (repository / candidate).resolve()


def _exclusive_copy(source: Path, target: Path) -> None:
    if not source.is_file() or source.is_symlink():
        raise PreparationError(f"missing or indirect frozen source: {source}")
    mode = stat.S_IMODE(source.stat().st_mode)
    try:
        with source.open("rb") as source_handle, target.open("xb") as target_handle:
            for block in iter(lambda: source_handle.read(1024 * 1024), b""):
                target_handle.write(block)
            target_handle.flush()
            os.fsync(target_handle.fileno())
        target.chmod(mode)
    except FileExistsError as error:
        raise PreparationError(f"refusing to overwrite queue file: {target}") from error


def finalize_attempt(
    queue_root: Path,
    *,
    python_executable: str = sys.executable,
    command_runner: CommandRunner = subprocess.run,
) -> dict[str, object]:
    queue_root = queue_root.resolve()
    queue_path = queue_root / "queue.toml"
    if not queue_path.is_file() or queue_path.is_symlink():
        raise PreparationError(f"missing attempt queue.toml: {queue_path}")
    queue = load_toml(queue_path)
    repository = Path(str(queue.get("paths", {}).get("repository_root", ""))).resolve()
    expected_queue_parent = repository / EXPERIMENT_RELATIVE / "queue"
    if queue_root.parent != expected_queue_parent:
        raise PreparationError(
            f"queue root is outside the registered attempt parent: {queue_root}"
        )
    present = {
        path.relative_to(queue_root).as_posix()
        for path in queue_root.rglob("*")
        if path.is_file() or path.is_symlink()
    }
    if present != {"queue.toml"}:
        raise PreparationError(
            "pre-package queue inventory is not pristine: " + repr(sorted(present))
        )
    freeze = _resolve_queue_path(queue_root, queue, "freeze")
    anchor = _resolve_queue_path(queue_root, queue, "anchor_result")
    transfer = _resolve_queue_path(queue_root, queue, "transfer_result")
    attribution = _resolve_queue_path(queue_root, queue, "attribution_result")
    if transfer.exists() or attribution.exists():
        raise PreparationError("non-anchor scientific output already exists")
    frozen_tools = freeze / "source/queue_tools"
    status = frozen_tools / "status_report.py"
    derive = frozen_tools / "derive_budget.py"
    locker = frozen_tools / "lock_queue_package.py"
    for required in (status, derive, locker):
        if not required.is_file() or required.is_symlink():
            raise PreparationError(f"missing frozen governance tool: {required}")

    run_checked(
        [python_executable, status, "verify-anchor-launch", "--queue-root", queue_root],
        command_runner=command_runner,
    )
    run_checked(
        [
            python_executable,
            status,
            "verify-result",
            "--result",
            anchor,
            "--stage",
            "anchor",
            "--require-expansion",
        ],
        command_runner=command_runner,
    )

    for target_name, source_name in IMMUTABLE_SOURCE_MAP.items():
        _exclusive_copy(frozen_tools / source_name, queue_root / target_name)
    for stage in ("transfer", "attribution"):
        output = queue_root / f"budget_{stage}.toml"
        run_checked(
            [
                python_executable,
                derive,
                "--anchor",
                anchor,
                "--output",
                output,
                "--target-stage",
                stage,
            ],
            command_runner=command_runner,
        )
        if not output.is_file() or output.is_symlink():
            raise PreparationError(f"budget tool did not create a regular file: {output}")

    present_before_lock = {
        path.relative_to(queue_root).as_posix()
        for path in queue_root.rglob("*")
        if path.is_file() or path.is_symlink()
    }
    if present_before_lock != EXPECTED_IMMUTABLE:
        raise PreparationError(
            "prepared immutable inventory is not exact: "
            f"missing={sorted(EXPECTED_IMMUTABLE-present_before_lock)}, "
            f"extra={sorted(present_before_lock-EXPECTED_IMMUTABLE)}"
        )
    run_checked(
        [python_executable, locker, "--queue-root", queue_root],
        command_runner=command_runner,
    )
    verified = run_checked(
        [python_executable, status, "verify-queue-launch", "--queue-root", queue_root],
        command_runner=command_runner,
    )
    return {
        "queue_root": str(queue_root),
        "freeze": str(freeze),
        "anchor_result": str(anchor),
        "transfer_result": str(transfer),
        "attribution_result": str(attribution),
        "verified": True,
        "verifier_output": verified.stdout.strip(),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    initialize = commands.add_parser("initialize")
    initialize.add_argument("--repo-root", required=True, type=Path)
    initialize.add_argument("--attempt-id", required=True)
    finalize = commands.add_parser("finalize")
    finalize.add_argument("--queue-root", required=True, type=Path)
    finalize.add_argument("--python-executable", default=sys.executable)
    return parser


def main(arguments: list[str] | None = None) -> int:
    args = build_parser().parse_args(arguments)
    if args.command == "initialize":
        payload: dict[str, object] = initialize_attempt(
            args.repo_root, args.attempt_id
        ).as_dict()
    else:
        payload = finalize_attempt(
            args.queue_root, python_executable=args.python_executable
        )
    print(json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PreparationError, OSError, KeyError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
