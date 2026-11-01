#!/usr/bin/env python3
"""Read-only queue-package, result, unit-guard, and status checks.

This helper never starts Julia, writes queue state, or replays a scientific
calculation.  Queue wrappers use it as a fail-closed reader at launch
boundaries; humans can use ``status`` while a registered unit is running.
"""

from __future__ import annotations

import argparse
import csv
import fnmatch
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import subprocess
import sys
from typing import Any, Iterable

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # Python 3.10 on the registered machine
    import tomli as tomllib  # type: ignore[no-redef]


EXPERIMENT_ID = "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001"
QUEUE_SCHEMA = "rq2-gd-parity-assignment-refresh-001/queue-v1"
LOCK_SCHEMA = "rq2-gd-parity-assignment-refresh-001/queue-package-lock-v1"
BUDGET_SCHEMA = "rq2-gd-parity-assignment-refresh-001/budget-v1"
MANIFEST_NAME = "QUEUE_MANIFEST.sha256"
LOCK_NAME = "QUEUE_PACKAGE_LOCK.toml"

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
EXPECTED_JOB_IDS = ["J01", "J02"]
EXPECTED_QUEUE_TOP_LEVEL = {
    "schema_version",
    "queue_id",
    "experiment_id",
    "stages",
    "execution_mode",
    "automatic_restart_allowed",
    "interrupted_attempt_must_be_retained",
    "manual_relaunch_requires_new_attempt_directory",
    "execution",
    "paths",
    "inventory",
    "telemetry",
}
EXPECTED_PATH_KEYS = {
    "repository_root",
    "project_root",
    "config",
    "runner",
    "preflight",
    "freeze",
    "anchor_result",
    "transfer_result",
    "attribution_result",
    "budget_transfer",
    "budget_attribution",
}
PREFLIGHT_SOURCE_LABEL = "preflight_validation.md"
PREFLIGHT_FILENAME = "preflight_validation.md"
GOVERNANCE_SOURCE_LABELS = {
    "README.md": "queue_tools/QUEUE_PACKAGE_README.template.md",
    "derive_budget.py": "queue_tools/derive_budget.py",
    "lock_queue_package.py": "queue_tools/lock_queue_package.py",
    "run_anchor_once.sh": "queue_tools/run_anchor_once.sh",
    "run_queue.sh": "queue_tools/run_queue.sh",
    "status_report.py": "queue_tools/status_report.py",
}
POST_LOOP_PHASES = (
    "statistics",
    "frame_table_hash",
    "iteration_table_hash",
    "gate_hash",
    "pass_completed",
)

# These are the only mutable paths a locked package can declare.  Job marker
# and log paths are expanded from the exact job IDs in queue.toml.
BASE_TELEMETRY = {
    "queue.lock",
    "queue.log",
    "progress.toml",
    "status_history.tsv",
    "QUEUE_COMPLETED.toml",
    "QUEUE_FAILED.toml",
}
JOB_MARKERS = ("STARTED.toml", "COMPLETED.toml", "FAILED.toml")
REGISTERED_EXECUTION = {
    "scientific_unit_pattern": "sp-gd-*.service",
    "anchor_unit_name": "sp-gd-rq2-parity-assignment-refresh-v4-anchor-20261101.service",
    "queue_unit_name": "sp-gd-rq2-parity-assignment-refresh-v4-20261101.service",
    "anchor_wall_budget_seconds": 7200,
    "anchor_term_after_seconds": 7080,
    "termination_grace_seconds": 120,
    "maximum_nonanchor_wall_budget_seconds": 36000,
    "julia_threads": 1,
    "omp_threads": 1,
    "blas_threads": 1,
    "nice": 19,
    "ionice_class": "idle",
}


class GateError(RuntimeError):
    """A launch or integrity gate failed."""


def load_toml(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        return tomllib.load(handle)


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
        or ".." in candidate.parts
        or "." in candidate.parts
        or str(candidate) != value
    ):
        raise GateError(f"unsafe or non-canonical relative path: {value!r}")
    return value


def queue_config(queue_root: Path) -> dict[str, Any]:
    path = queue_root / "queue.toml"
    if not path.is_file():
        raise GateError(f"missing queue configuration: {path}")
    config = load_toml(path)
    if set(config) != EXPECTED_QUEUE_TOP_LEVEL:
        raise GateError(
            "queue top-level schema differs from the registered fields: "
            f"missing={sorted(EXPECTED_QUEUE_TOP_LEVEL-set(config))}, "
            f"extra={sorted(set(config)-EXPECTED_QUEUE_TOP_LEVEL)}"
        )
    if config.get("schema_version") != QUEUE_SCHEMA:
        raise GateError(f"unexpected queue schema: {config.get('schema_version')!r}")
    if config.get("experiment_id") != EXPERIMENT_ID:
        raise GateError(f"unexpected experiment ID: {config.get('experiment_id')!r}")
    if config.get("stages") != ["transfer", "attribution"]:
        raise GateError(
            "queue stages must be exactly ['transfer', 'attribution'] in serial order"
        )
    if config.get("execution") != REGISTERED_EXECUTION:
        raise GateError(
            "queue execution controls differ from the registered one-unit launch plan"
        )
    governance = {
        "execution_mode": "serial, one scientific unit, fail closed",
        "automatic_restart_allowed": False,
        "interrupted_attempt_must_be_retained": True,
        "manual_relaunch_requires_new_attempt_directory": True,
    }
    failures = {
        key: {"expected": expected, "found": config.get(key)}
        for key, expected in governance.items()
        if config.get(key) != expected
    }
    if failures:
        raise GateError(f"queue governance fields changed: {failures}")
    queue_id = config.get("queue_id")
    if (
        not isinstance(queue_id, str)
        or not queue_id
        or len(queue_id) > 128
        or any(character not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-" for character in queue_id)
    ):
        raise GateError(f"unsafe queue_id: {queue_id!r}")
    paths = config.get("paths")
    if not isinstance(paths, dict) or set(paths) != EXPECTED_PATH_KEYS:
        found = set(paths) if isinstance(paths, dict) else set()
        raise GateError(
            "queue path schema differs from the registered fields: "
            f"missing={sorted(EXPECTED_PATH_KEYS-found)}, "
            f"extra={sorted(found-EXPECTED_PATH_KEYS)}"
        )
    if any(not isinstance(value, str) or not value for value in paths.values()):
        raise GateError("every registered queue path must be a nonempty string")
    if set(config.get("inventory", {})) != {"immutable_files"}:
        raise GateError("inventory must contain only immutable_files")
    if set(config.get("telemetry", {})) != {"files", "job_ids"}:
        raise GateError("telemetry must contain only files and job_ids")
    return config


def immutable_inventory(config: dict[str, Any]) -> tuple[str, ...]:
    values = config.get("inventory", {}).get("immutable_files", [])
    if not isinstance(values, list) or not values:
        raise GateError("inventory.immutable_files must be a nonempty array")
    normalized = tuple(safe_relative(str(value)) for value in values)
    if len(normalized) != len(set(normalized)):
        raise GateError("inventory.immutable_files contains duplicates")
    found = set(normalized)
    if found != EXPECTED_IMMUTABLE:
        raise GateError(
            "immutable inventory must equal the registered file set: "
            f"missing={sorted(EXPECTED_IMMUTABLE-found)}, "
            f"extra={sorted(found-EXPECTED_IMMUTABLE)}"
        )
    for stage in ("transfer", "attribution"):
        expected = f"budget_{stage}.toml"
        budget = budget_relative(config, stage)
        if budget != expected:
            raise GateError(
                f"paths.budget_{stage} must equal the registered name {expected!r}"
            )
    return normalized


def telemetry_inventory(config: dict[str, Any]) -> set[str]:
    telemetry = config.get("telemetry", {})
    declared = telemetry.get("files", [])
    if not isinstance(declared, list):
        raise GateError("telemetry.files must be an array")
    declared_set = {safe_relative(str(value)) for value in declared}
    if declared_set != BASE_TELEMETRY:
        raise GateError(
            "telemetry.files must equal the registered mutable path set; "
            f"missing={sorted(BASE_TELEMETRY-declared_set)}, "
            f"extra={sorted(declared_set-BASE_TELEMETRY)}"
        )
    job_ids_raw = telemetry.get("job_ids", [])
    if not isinstance(job_ids_raw, list):
        raise GateError("telemetry.job_ids must be an array")
    job_ids = [str(value) for value in job_ids_raw]
    if job_ids != EXPECTED_JOB_IDS:
        raise GateError(
            f"telemetry.job_ids must equal the registered order {EXPECTED_JOB_IDS!r}"
        )
    for job_id in job_ids:
        if not job_id or any(character not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for character in job_id):
            raise GateError(f"unsafe telemetry job ID: {job_id!r}")
    allowed = set(declared_set)
    for job_id in job_ids:
        allowed.add(f"logs/{job_id}.log")
        for marker in JOB_MARKERS:
            allowed.add(f"jobs/{job_id}/{marker}")
    return allowed


def parse_checksum_manifest(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise GateError(f"missing checksum manifest: {path}")
    listed: dict[str, str] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line:
            raise GateError(f"blank checksum row at line {number}")
        expected, separator, relative = line.partition("  ")
        if not separator or len(expected) != 64:
            raise GateError(f"malformed checksum row at line {number}: {line!r}")
        try:
            int(expected, 16)
        except ValueError as error:
            raise GateError(f"non-hex checksum at line {number}") from error
        relative = safe_relative(relative)
        if relative in listed:
            raise GateError(f"duplicate checksum path: {relative}")
        listed[relative] = expected
    if not listed:
        raise GateError("checksum manifest is empty")
    return listed


def iter_files(root: Path) -> Iterable[str]:
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise GateError(f"symlinks are forbidden in queue packages: {path}")
        if path.is_file():
            yield path.relative_to(root).as_posix()
        elif not path.is_dir():
            raise GateError(f"special files are forbidden in queue packages: {path}")


def verify_queue_package(queue_root: Path) -> dict[str, Any]:
    queue_root = queue_root.resolve()
    manifest_path = queue_root / MANIFEST_NAME
    listed = parse_checksum_manifest(manifest_path)

    # Verify queue.toml before trusting its declared inventory or telemetry.
    expected_queue_hash = listed.get("queue.toml")
    if expected_queue_hash is None:
        raise GateError("queue.toml is not bound by the queue manifest")
    if sha256_file(queue_root / "queue.toml") != expected_queue_hash:
        raise GateError("queue.toml checksum mismatch")
    config = queue_config(queue_root)
    immutable = set(immutable_inventory(config))
    if set(listed) != immutable:
        raise GateError(
            "queue manifest differs from immutable inventory: "
            f"extra={sorted(set(listed)-immutable)}, "
            f"missing={sorted(immutable-set(listed))}"
        )
    for relative, expected in listed.items():
        target = queue_root / relative
        if not target.is_file() or target.is_symlink():
            raise GateError(f"missing or non-regular immutable file: {relative}")
        actual = sha256_file(target)
        if actual != expected:
            raise GateError(
                f"checksum mismatch for {relative}: expected {expected}, found {actual}"
            )

    lock_path = queue_root / LOCK_NAME
    if not lock_path.is_file() or lock_path.is_symlink():
        raise GateError(f"missing queue package lock: {lock_path}")
    lock = load_toml(lock_path)
    expected_lock = {
        "schema_version": LOCK_SCHEMA,
        "experiment_id": EXPERIMENT_ID,
        "queue_id": config.get("queue_id"),
        "queue_manifest_sha256": sha256_file(manifest_path),
        "locked_file_count": len(listed),
    }
    failures = {
        key: {"expected": value, "found": lock.get(key)}
        for key, value in expected_lock.items()
        if lock.get(key) != value
    }
    if failures:
        raise GateError(f"queue lock mismatch: {failures}")

    allowed = immutable | telemetry_inventory(config) | {MANIFEST_NAME, LOCK_NAME}
    actual = set(iter_files(queue_root))
    unlisted = actual - allowed
    if unlisted:
        raise GateError(
            "queue contains unlisted files; executable/config helpers cannot be "
            f"introduced after lock: {sorted(unlisted)}"
        )
    return {
        "queue_root": str(queue_root),
        "queue_id": config["queue_id"],
        "manifest_sha256": sha256_file(manifest_path),
        "locked_file_count": len(listed),
        "telemetry_files_present": sorted(actual & telemetry_inventory(config)),
    }


def budget_relative(config: dict[str, Any], stage: str) -> str:
    if stage not in {"transfer", "attribution"}:
        raise GateError(f"unsupported budget stage: {stage}")
    value = config.get("paths", {}).get(f"budget_{stage}")
    if value is None:
        raise GateError(f"paths.budget_{stage} is missing")
    return safe_relative(str(value))


def verify_budget(queue_root: Path, stage: str) -> dict[str, Any]:
    config = queue_config(queue_root)
    path = queue_root / budget_relative(config, stage)
    if not path.is_file():
        raise GateError(f"missing {stage} budget record: {path}")
    budget = load_toml(path)
    required = {
        "schema_version": BUDGET_SCHEMA,
        "experiment_id": EXPERIMENT_ID,
        "target_stage": stage,
        "anchor_cases": 24,
        "target_cases": 200,
        "pass_count": 2,
        "safety_factor": 1.5,
        "absolute_safety_cap_seconds": 36000,
        "termination_grace_seconds": 120,
    }
    failures = {
        key: {"expected": value, "found": budget.get(key)}
        for key, value in required.items()
        if budget.get(key) != value
    }
    wall = budget.get("wall_budget_seconds")
    term = budget.get("term_after_seconds")
    if not isinstance(wall, int) or not 120 < wall <= 36000:
        failures["wall_budget_seconds"] = {
            "expected": "integer in [121,36000]",
            "found": wall,
        }
    if not isinstance(term, int) or not isinstance(wall, int) or term + 120 != wall:
        failures["term_after_seconds"] = {
            "expected": "wall_budget_seconds - 120",
            "found": term,
        }
    if failures:
        raise GateError(f"invalid {stage} budget record: {failures}")
    return {
        "path": str(path.resolve()),
        "wall_budget_seconds": wall,
        "term_after_seconds": term,
        "termination_grace_seconds": 120,
    }


def verify_tree_checksum_manifest(root: Path) -> dict[str, str]:
    root = root.resolve()
    listed = parse_checksum_manifest(root / "MANIFEST.sha256")
    actual = set(iter_files(root)) - {"MANIFEST.sha256"}
    if actual != set(listed):
        raise GateError(
            "freeze inventory differs from MANIFEST.sha256: "
            f"extra={sorted(actual-set(listed))}, missing={sorted(set(listed)-actual)}"
        )
    for relative, expected in listed.items():
        target = root / relative
        if target.is_symlink() or sha256_file(target) != expected:
            raise GateError(f"freeze checksum mismatch: {relative}")
    return listed


def source_record(manifest: dict[str, Any], label: str) -> dict[str, Any]:
    matches = [
        record
        for record in manifest.get("sources", [])
        if str(record.get("label", "")) == label
    ]
    if len(matches) != 1:
        raise GateError(f"freeze must contain exactly one source record for {label}")
    return matches[0]


def archived_source(freeze: Path, manifest: dict[str, Any], label: str) -> Path:
    record = source_record(manifest, label)
    relative = safe_relative(str(record.get("archived_relative_path", "")))
    expected = str(record.get("sha256", ""))
    target = (freeze / relative).resolve()
    if not target.is_file() or target.is_symlink() or sha256_file(target) != expected:
        raise GateError(f"archived source does not match freeze record: {label}")
    return target


def preflight_status(path: Path) -> str:
    """Read the final validation status from an immutable preflight record."""

    if not path.is_file() or path.is_symlink():
        raise GateError(f"missing or indirect preflight record: {path}")
    statuses: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.partition(":")
        if separator and key.strip() == "validation_status":
            statuses.append(value.strip().strip("`"))
    if len(statuses) != 1:
        raise GateError(
            "preflight record must contain exactly one validation_status field"
        )
    return statuses[0]


def verify_attempt_preflight(
    queue_root: Path,
    queue: dict[str, Any],
    freeze: Path,
    freeze_manifest: dict[str, Any],
) -> dict[str, str]:
    """Bind this attempt to one passed preflight and its frozen copy."""

    repository = Path(str(queue.get("paths", {}).get("repository_root", "")))
    if not repository.is_absolute():
        raise GateError("paths.repository_root must be absolute")
    raw_value = str(queue.get("paths", {}).get("preflight", ""))
    raw_path = Path(raw_value)
    if raw_path.is_absolute():
        configured_raw = raw_path
    else:
        safe_relative(raw_value)
        configured_raw = repository / raw_path
    if not configured_raw.is_file() or configured_raw.is_symlink():
        raise GateError(
            f"attempt preflight is missing or indirect: {configured_raw}"
        )
    configured = configured_raw.resolve()

    preflight_root = (
        repository.resolve()
        / "experiments"
        / "rq2_gd_parity_assignment_refresh_001"
        / "preflight"
    )
    try:
        attempt_relative = configured.relative_to(preflight_root)
    except ValueError as error:
        raise GateError(
            f"attempt preflight must be below the registered preflight root: {preflight_root}"
        ) from error
    if (
        len(attempt_relative.parts) != 2
        or attempt_relative.name != PREFLIGHT_FILENAME
    ):
        raise GateError(
            "attempt preflight must have path preflight/<attempt-id>/"
            f"{PREFLIGHT_FILENAME}"
        )
    attempt_id = attempt_relative.parts[0]
    expected_queue_id = f"{EXPERIMENT_ID}.{attempt_id}"
    if queue.get("queue_id") != expected_queue_id:
        raise GateError(
            "queue ID and attempt preflight directory identify different attempts"
        )

    record = source_record(freeze_manifest, PREFLIGHT_SOURCE_LABEL)
    original_raw = Path(str(record.get("original_path", "")))
    if not original_raw.is_absolute() or original_raw != configured:
        raise GateError(
            "frozen preflight source record is not the exact configured attempt preflight"
        )
    expected_hash = str(record.get("sha256", ""))
    if sha256_file(configured) != expected_hash:
        raise GateError("attempt preflight differs from its frozen source record")

    archived = archived_source(freeze, freeze_manifest, PREFLIGHT_SOURCE_LABEL)
    if preflight_status(configured) != "pass" or preflight_status(archived) != "pass":
        raise GateError("attempt preflight validation_status is not pass")
    gate = freeze_manifest.get("preflight_gate")
    if not isinstance(gate, dict) or gate.get("passed") is not True:
        raise GateError("freeze manifest does not contain a passed preflight gate")
    recorded = gate.get("recorded")
    if not isinstance(recorded, dict) or recorded.get("validation_status") != "pass":
        raise GateError(
            "freeze manifest preflight gate does not record validation_status=pass"
        )
    return {
        "attempt_id": attempt_id,
        "preflight": str(configured),
        "preflight_sha256": expected_hash,
        "archived_preflight": str(archived),
    }


def verify_anchor_launch(queue_root: Path) -> dict[str, Any]:
    """Bind the pre-anchor launch plan to the exact frozen sources."""

    queue_root = queue_root.resolve()
    queue = queue_config(queue_root)
    freeze = resolve_config_path(queue_root, "freeze")
    current_status = Path(__file__).resolve()
    wrapper_freeze = current_status.parents[2]
    if freeze != wrapper_freeze:
        raise GateError(
            "queue freeze path differs from the freeze containing this trusted helper"
        )
    if not freeze.is_dir() or freeze.is_symlink():
        raise GateError(f"freeze is missing or not a real directory: {freeze}")
    verify_tree_checksum_manifest(freeze)
    freeze_manifest_path = freeze / "freeze_manifest.toml"
    freeze_manifest = load_toml(freeze_manifest_path)
    if freeze_manifest.get("experiment_id") != EXPERIMENT_ID:
        raise GateError("freeze manifest has the wrong experiment ID")

    preflight = verify_attempt_preflight(
        queue_root, queue, freeze, freeze_manifest
    )

    archived_config = archived_source(freeze, freeze_manifest, "config.toml")
    archived_runner = archived_source(
        freeze, freeze_manifest, "rq2_gd_parity_assignment_refresh_001.jl"
    )
    archived_status = archived_source(
        freeze, freeze_manifest, "queue_tools/status_report.py"
    )
    archived_anchor = archived_source(
        freeze, freeze_manifest, "queue_tools/run_anchor_once.sh"
    )
    archived_split_config = archived_source(
        freeze, freeze_manifest, "vendor/split_config.toml"
    )

    configured_config = resolve_config_path(queue_root, "config")
    configured_runner = resolve_config_path(queue_root, "runner")
    config_record = source_record(freeze_manifest, "config.toml")
    runner_record = source_record(
        freeze_manifest, "rq2_gd_parity_assignment_refresh_001.jl"
    )
    original_config_raw = Path(str(config_record.get("original_path", "")))
    original_runner_raw = Path(str(runner_record.get("original_path", "")))
    if not original_config_raw.is_absolute() or not original_runner_raw.is_absolute():
        raise GateError("frozen config/runner records lack absolute original paths")
    original_config = original_config_raw.resolve()
    original_runner = original_runner_raw.resolve()
    if (
        configured_config != original_config
        or not configured_config.is_file()
        or configured_config.is_symlink()
        or sha256_file(configured_config) != str(config_record["sha256"])
    ):
        raise GateError(
            "queue config must be the exact hash-bound original source: "
            f"{original_config}"
        )
    if (
        configured_runner != original_runner
        or not configured_runner.is_file()
        or configured_runner.is_symlink()
        or sha256_file(configured_runner) != str(runner_record["sha256"])
    ):
        raise GateError(
            "queue runner must be the exact hash-bound original source: "
            f"{original_runner}"
        )
    current_anchor = current_status.parent / "run_anchor_once.sh"
    if current_status != archived_status or sha256_file(current_status) != str(
        source_record(freeze_manifest, "queue_tools/status_report.py")["sha256"]
    ):
        raise GateError("verify-anchor-launch is not running from the frozen status helper")
    if current_anchor.resolve() != archived_anchor or sha256_file(current_anchor) != str(
        source_record(freeze_manifest, "queue_tools/run_anchor_once.sh")["sha256"]
    ):
        raise GateError("anchor wrapper is not the frozen archived wrapper")

    experiment_config = load_toml(archived_config)
    if freeze_manifest.get("configuration_sha256") != sha256_file(archived_config):
        raise GateError("freeze manifest configuration hash does not match frozen config")
    plan = experiment_config.get("queue_plan")
    if plan != REGISTERED_EXECUTION:
        raise GateError(
            "frozen config queue_plan differs from the registered launch controls: "
            f"{plan!r}"
        )
    execution = queue.get("execution")
    if execution != plan:
        raise GateError(
            "attempt queue execution controls differ from frozen config queue_plan"
        )

    pattern = str(execution["scientific_unit_pattern"])
    anchor_unit = str(execution["anchor_unit_name"])
    queue_unit = str(execution["queue_unit_name"])
    if (
        anchor_unit == queue_unit
        or not fnmatch.fnmatch(anchor_unit, pattern)
        or not fnmatch.fnmatch(queue_unit, pattern)
        or not anchor_unit.endswith(".service")
        or not queue_unit.endswith(".service")
    ):
        raise GateError("registered scientific unit names are invalid or not distinct")

    split_config = load_toml(archived_split_config)
    registered_project = str(
        split_config.get("sources", {}).get("jade_project_repo", "")
    )
    configured_project = str(queue.get("paths", {}).get("project_root", ""))
    if not registered_project or configured_project != registered_project:
        raise GateError(
            "queue project_root differs from the exact frozen split configuration"
        )
    project = Path(configured_project)
    if not project.is_absolute() or not project.is_dir() or project.is_symlink():
        raise GateError(f"registered project root is unavailable or indirect: {project}")

    if len(original_config.parents) < 3:
        raise GateError("frozen config record lacks a usable original repository path")
    registered_repository = original_config.parents[2]
    configured_repository = Path(
        str(queue.get("paths", {}).get("repository_root", ""))
    )
    if configured_repository != registered_repository:
        raise GateError(
            "queue repository_root differs from the frozen config source repository"
        )
    results_root = (
        registered_repository
        / "experiments"
        / "rq2_gd_parity_assignment_refresh_001"
        / "results"
    )
    result_paths: dict[str, str] = {}
    for stage in ("anchor", "transfer", "attribution"):
        result = resolve_config_path(queue_root, f"{stage}_result")
        if result.parent != results_root or stage not in result.name.lower():
            raise GateError(
                f"{stage} output must be one attempt-specific child of {results_root}"
            )
        result_paths[stage] = str(result)
    if len(set(result_paths.values())) != 3:
        raise GateError("anchor, transfer, and attribution outputs must be distinct")
    budget_relative(queue, "transfer")
    budget_relative(queue, "attribution")

    return {
        "queue_root": str(queue_root),
        "freeze": str(freeze),
        "freeze_manifest_sha256": sha256_file(freeze_manifest_path),
        "config": str(configured_config),
        "config_sha256": sha256_file(configured_config),
        "runner": str(configured_runner),
        "runner_sha256": sha256_file(configured_runner),
        "preflight": preflight,
        "project_root": configured_project,
        "repository_root": str(registered_repository),
        "result_paths": result_paths,
        "execution": execution,
    }


def result_inventory(result: Path) -> dict[str, str]:
    listed = parse_checksum_manifest(result / "MANIFEST.sha256")
    excluded = {"MANIFEST.sha256", "progress.toml", "phase_log.tsv"}
    actual = {
        path.relative_to(result).as_posix()
        for path in result.rglob("*")
        if path.is_file() and path.relative_to(result).as_posix() not in excluded
    }
    if actual != set(listed):
        raise GateError(
            "result inventory mismatch: "
            f"extra={sorted(actual-set(listed))}, missing={sorted(set(listed)-actual)}"
        )
    for relative, expected in listed.items():
        target = result / relative
        if target.is_symlink() or sha256_file(target) != expected:
            raise GateError(f"result checksum mismatch: {relative}")
    phase_sidecar = result / "PHASE_LOG.sha256"
    phase_log = result / "phase_log.tsv"
    if "PHASE_LOG.sha256" not in listed:
        raise GateError("result manifest does not bind PHASE_LOG.sha256")
    rows = phase_sidecar.read_text(encoding="utf-8").splitlines()
    if len(rows) != 1:
        raise GateError("malformed PHASE_LOG.sha256")
    expected, separator, relative = rows[0].partition("  ")
    if (
        not separator
        or relative != "phase_log.tsv"
        or not phase_log.is_file()
        or sha256_file(phase_log) != expected
    ):
        raise GateError("phase_log.tsv does not match PHASE_LOG.sha256")
    return listed


def verify_result(result: Path, stage: str, require_expansion: bool = False) -> dict[str, Any]:
    result = result.resolve()
    if not result.is_dir():
        raise GateError(f"missing result directory: {result}")
    result_inventory(result)
    completion_path = result / "COMPLETED.toml"
    manifest_path = result / "manifest.toml"
    science_path = result / "science.json"
    for path in (completion_path, manifest_path, science_path):
        if not path.is_file():
            raise GateError(f"missing result artifact: {path}")
    completion = load_toml(completion_path)
    manifest = load_toml(manifest_path)
    checks = {
        "experiment": completion.get("experiment_id") == EXPERIMENT_ID,
        "stage": completion.get("stage") == stage and manifest.get("stage") == stage,
        "status": completion.get("status") == "complete_valid",
        "correctness": completion.get("correctness_passed") is True,
        "replay": completion.get("deterministic_replay_passed") is True,
        "science_hash": completion.get("science_sha256") == sha256_file(science_path),
        "manifest_hash": completion.get("manifest_sha256") == sha256_file(manifest_path),
    }
    if require_expansion:
        checks["expansion"] = completion.get("anchor_expansion_authorized") is True
    failures = [name for name, passed in checks.items() if not passed]
    if failures:
        raise GateError(f"invalid {stage} result; failed checks: {failures}")
    return {
        "result": str(result),
        "stage": stage,
        "status": completion["status"],
        "science_sha256": sha256_file(science_path),
        "manifest_sha256": sha256_file(manifest_path),
    }


def resolve_config_path(queue_root: Path, key: str) -> Path:
    config = queue_config(queue_root)
    paths = config.get("paths", {})
    if key not in paths:
        raise GateError(f"queue path key is missing: {key}")
    candidate = Path(str(paths[key]))
    if candidate.is_absolute():
        return candidate.resolve()
    queue_relative = {"budget_transfer", "budget_attribution"}
    if key in queue_relative:
        return (queue_root / candidate).resolve()
    repository = Path(str(paths.get("repository_root", "")))
    if not repository.is_absolute():
        raise GateError("paths.repository_root must be absolute")
    return (repository / candidate).resolve()


def anchor_artifact_hashes(anchor: Path) -> dict[str, str]:
    """Return the exact anchor identities used by both budget records."""

    paths = {
        "anchor_science_sha256": anchor / "science.json",
        "anchor_completion_sha256": anchor / "COMPLETED.toml",
        "anchor_manifest_sha256": anchor / "manifest.toml",
        "anchor_checksum_manifest_sha256": anchor / "MANIFEST.sha256",
        "phase_log_sha256": anchor / "phase_log.tsv",
    }
    missing = [str(path) for path in paths.values() if not path.is_file()]
    if missing:
        raise GateError(f"anchor artifacts required by budgets are missing: {missing}")
    return {key: sha256_file(path) for key, path in paths.items()}


def anchor_phase_measurements(anchor: Path) -> tuple[float, float]:
    """Read the registered anchor phase durations used by derive_budget.py."""

    durations: dict[tuple[str, str], float] = {}
    events: dict[tuple[str, str, str], int] = {}
    with (anchor / "phase_log.tsv").open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if reader.fieldnames != ["utc", "pass", "phase", "seconds"]:
            raise GateError(f"unexpected anchor phase-log columns: {reader.fieldnames}")
        for row in reader:
            phase_event = row["phase"]
            if ":" not in phase_event:
                raise GateError(f"malformed anchor phase event: {phase_event!r}")
            phase, event = phase_event.rsplit(":", 1)
            event_key = (row["pass"], phase, event)
            events[event_key] = events.get(event_key, 0) + 1
            if event == "error":
                raise GateError(f"anchor phase log contains an error: {event_key}")
            if event == "end":
                key = (row["pass"], phase)
                if key in durations:
                    raise GateError(f"duplicate anchor phase end: {key}")
                durations[key] = float(row["seconds"])

    frame_keys = [("primary", "frame_loop"), ("replay", "frame_loop")]
    post_keys = [
        (pass_name, phase)
        for pass_name in ("primary", "replay")
        for phase in POST_LOOP_PHASES
    ]
    post_keys.extend(
        (
            ("primary", "primary_checkpoint"),
            ("artifact", "write_result"),
            ("artifact", "checksum_manifest"),
        )
    )
    required = frame_keys + post_keys
    missing = [key for key in required if key not in durations]
    if missing:
        raise GateError(f"anchor phase log lacks registered end rows: {missing}")
    malformed = [
        key
        for pass_name, phase in required
        for key in ((pass_name, phase, "start"), (pass_name, phase, "end"))
        if events.get(key, 0) != 1
    ]
    if malformed:
        raise GateError(
            "anchor phases do not have exactly one start and end: "
            f"{malformed}"
        )
    return (
        sum(durations[key] for key in frame_keys),
        sum(durations[key] for key in post_keys),
    )


def verify_budget_anchor_binding(
    queue_root: Path, stage: str, anchor: Path
) -> dict[str, Any]:
    """Verify one locked budget against the current complete-valid anchor."""

    basic = verify_budget(queue_root, stage)
    budget_path = Path(basic["path"])
    budget = load_toml(budget_path)
    expected_hashes = anchor_artifact_hashes(anchor)
    failures: dict[str, dict[str, Any]] = {}
    if budget.get("anchor_result") != str(anchor):
        failures["anchor_result"] = {
            "expected": str(anchor),
            "found": budget.get("anchor_result"),
        }
    for key, expected in expected_hashes.items():
        if budget.get(key) != expected:
            failures[key] = {"expected": expected, "found": budget.get(key)}

    numeric_fields = (
        "anchor_frame_loop_seconds",
        "anchor_seconds_per_case_per_pass",
        "projected_frame_seconds",
        "anchor_post_loop_seconds",
        "post_loop_scale",
        "projected_post_loop_seconds",
        "projected_seconds_before_safety",
    )
    try:
        numeric = {key: float(budget[key]) for key in numeric_fields}
        anchor_cases = int(budget["anchor_cases"])
        target_cases = int(budget["target_cases"])
        pass_count = int(budget["pass_count"])
        safety = float(budget["safety_factor"])
        measured_frame_seconds, measured_post_seconds = anchor_phase_measurements(
            anchor
        )
        expected = {
            "anchor_frame_loop_seconds": measured_frame_seconds,
            "anchor_post_loop_seconds": measured_post_seconds,
            "anchor_seconds_per_case_per_pass":
                measured_frame_seconds
                / (anchor_cases * pass_count),
            "projected_frame_seconds":
                measured_frame_seconds
                / anchor_cases * target_cases,
            "post_loop_scale": target_cases / anchor_cases,
            "projected_post_loop_seconds":
                measured_post_seconds
                * target_cases / anchor_cases,
        }
        expected["projected_seconds_before_safety"] = (
            expected["projected_frame_seconds"]
            + expected["projected_post_loop_seconds"]
        )
        for key, value in expected.items():
            if not math.isclose(numeric[key], value, rel_tol=0.0, abs_tol=1.0e-6):
                failures[key] = {"expected": value, "found": numeric[key]}
        expected_wall = math.ceil(
            safety * expected["projected_seconds_before_safety"]
        )
        if budget.get("wall_budget_seconds") != expected_wall:
            failures["wall_budget_seconds_formula"] = {
                "expected": expected_wall,
                "found": budget.get("wall_budget_seconds"),
            }
    except (KeyError, TypeError, ValueError, ZeroDivisionError) as error:
        failures["budget_formula"] = {
            "expected": "all registered finite timing fields",
            "found": str(error),
        }
    if failures:
        raise GateError(f"{stage} budget is not bound to the anchor: {failures}")
    return {**basic, **expected_hashes}


def verify_queue_launch(queue_root: Path) -> dict[str, Any]:
    """Bind the locked non-anchor launch to the frozen trusted sources."""

    queue_root = queue_root.resolve()
    package = verify_queue_package(queue_root)
    common = verify_anchor_launch(queue_root)
    freeze = Path(common["freeze"])
    freeze_manifest_path = freeze / "freeze_manifest.toml"
    freeze_checksum_path = freeze / "MANIFEST.sha256"
    freeze_manifest = load_toml(freeze_manifest_path)

    current_status = Path(__file__).resolve()
    current_queue_wrapper = current_status.parent / "run_queue.sh"
    archived_queue_wrapper = archived_source(
        freeze, freeze_manifest, "queue_tools/run_queue.sh"
    )
    queue_wrapper_record = source_record(
        freeze_manifest, "queue_tools/run_queue.sh"
    )
    if (
        current_queue_wrapper.resolve() != archived_queue_wrapper
        or sha256_file(current_queue_wrapper) != str(queue_wrapper_record["sha256"])
    ):
        raise GateError("non-anchor launch is not running from the frozen wrapper")

    governance_hashes: dict[str, str] = {}
    for relative, label in GOVERNANCE_SOURCE_LABELS.items():
        archived = archived_source(freeze, freeze_manifest, label)
        record = source_record(freeze_manifest, label)
        expected = str(record["sha256"])
        target = queue_root / relative
        if (
            not target.is_file()
            or target.is_symlink()
            or sha256_file(target) != expected
            or sha256_file(archived) != expected
        ):
            raise GateError(
                f"locked queue governance copy differs from frozen source: {relative}"
            )
        governance_hashes[relative] = expected

    anchor = resolve_config_path(queue_root, "anchor_result")
    anchor_record = verify_result(
        anchor, "anchor", require_expansion=True
    )
    anchor_manifest = load_toml(anchor / "manifest.toml")
    expected_freeze = {
        "freeze": str(freeze),
        "freeze_manifest_sha256": sha256_file(freeze_manifest_path),
        "freeze_checksum_manifest_sha256": sha256_file(freeze_checksum_path),
    }
    freeze_failures = {
        key: {"expected": value, "found": anchor_manifest.get(key)}
        for key, value in expected_freeze.items()
        if anchor_manifest.get(key) != value
    }
    if freeze_failures:
        raise GateError(
            "anchor result is not bound to the current frozen source tree: "
            f"{freeze_failures}"
        )

    budgets = {
        stage: verify_budget_anchor_binding(queue_root, stage, anchor)
        for stage in ("transfer", "attribution")
    }
    return {
        **common,
        "package": package,
        "anchor": anchor_record,
        "governance_sha256": governance_hashes,
        "budgets": budgets,
    }


def active_scientific_units(pattern: str) -> list[str]:
    completed = subprocess.run(
        [
            "systemctl",
            "--user",
            "list-units",
            pattern,
            "--type=service",
            "--state=active,activating,reloading,deactivating",
            "--no-legend",
            "--no-pager",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise GateError(
            "cannot determine active scientific services; refusing launch: "
            + completed.stderr.strip()
        )
    units: list[str] = []
    for line in completed.stdout.splitlines():
        fields = line.split()
        if fields and fnmatch.fnmatch(fields[0], pattern):
            units.append(fields[0])
    return sorted(set(units))


def unit_guard(queue_root: Path, mode: str) -> dict[str, Any]:
    config = queue_config(queue_root)
    execution = config.get("execution", {})
    pattern = str(execution.get("scientific_unit_pattern", ""))
    if not pattern or ".service" not in pattern:
        raise GateError("execution.scientific_unit_pattern must be a service glob")
    anchor_unit = str(execution.get("anchor_unit_name", ""))
    queue_unit = str(execution.get("queue_unit_name", ""))
    if (
        anchor_unit == queue_unit
        or not fnmatch.fnmatch(anchor_unit, pattern)
        or not fnmatch.fnmatch(queue_unit, pattern)
        or not anchor_unit.endswith(".service")
        or not queue_unit.endswith(".service")
    ):
        raise GateError("execution unit names must be distinct services matching the pattern")
    own_unit = anchor_unit if mode == "anchor" else queue_unit
    active = active_scientific_units(pattern)
    conflicts = [unit for unit in active if unit != own_unit]
    if conflicts:
        raise GateError(
            "another scientific service is active; this wrapper never signals it: "
            + ", ".join(conflicts)
        )
    return {"mode": mode, "own_unit": own_unit, "active_units": active}


def read_optional_toml(path: Path) -> dict[str, Any] | None:
    try:
        return load_toml(path) if path.is_file() else None
    except Exception as error:  # status reports malformed telemetry explicitly
        return {"read_error": str(error)}


def status_payload(queue_root: Path) -> dict[str, Any]:
    config = queue_config(queue_root)
    try:
        package: dict[str, Any] = {"passed": True, **verify_queue_package(queue_root)}
    except Exception as error:
        package = {"passed": False, "error": str(error)}
    execution = config.get("execution", {})
    try:
        units: dict[str, Any] = {
            "passed": True,
            "active": active_scientific_units(
                str(execution.get("scientific_unit_pattern", "sp-gd-*.service"))
            ),
        }
    except Exception as error:
        units = {"passed": False, "error": str(error)}
    results: dict[str, Any] = {}
    for stage in ("anchor", "transfer", "attribution"):
        path = resolve_config_path(queue_root, f"{stage}_result")
        results[stage] = {
            "path": str(path),
            "exists": path.exists(),
            "progress": read_optional_toml(path / "progress.toml"),
            "completion": read_optional_toml(path / "COMPLETED.toml"),
        }
    return {
        "queue_id": config.get("queue_id"),
        "package": package,
        "active_scientific_units": units,
        "queue_progress": read_optional_toml(queue_root / "progress.toml"),
        "results": results,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    verify_package = commands.add_parser("verify-package")
    verify_package.add_argument("--queue-root", required=True, type=Path)

    verify_budget_parser = commands.add_parser("verify-budget")
    verify_budget_parser.add_argument("--queue-root", required=True, type=Path)
    verify_budget_parser.add_argument(
        "--stage", required=True, choices=("transfer", "attribution")
    )
    verify_budget_parser.add_argument(
        "--format", choices=("json", "shell"), default="json"
    )

    verify_result_parser = commands.add_parser("verify-result")
    verify_result_parser.add_argument("--result", required=True, type=Path)
    verify_result_parser.add_argument(
        "--stage", required=True, choices=("anchor", "transfer", "attribution")
    )
    verify_result_parser.add_argument("--require-expansion", action="store_true")

    verify_anchor_parser = commands.add_parser("verify-anchor-launch")
    verify_anchor_parser.add_argument("--queue-root", required=True, type=Path)

    verify_queue_parser = commands.add_parser("verify-queue-launch")
    verify_queue_parser.add_argument("--queue-root", required=True, type=Path)

    resolve_parser = commands.add_parser("resolve-path")
    resolve_parser.add_argument("--queue-root", required=True, type=Path)
    resolve_parser.add_argument("--key", required=True)

    unit_parser = commands.add_parser("assert-unit-guard")
    unit_parser.add_argument("--queue-root", required=True, type=Path)
    unit_parser.add_argument("--mode", required=True, choices=("anchor", "queue"))

    status_parser = commands.add_parser("status")
    status_parser.add_argument("--queue-root", required=True, type=Path)
    status_parser.add_argument("--json", action="store_true")
    return parser


def main(arguments: list[str] | None = None) -> int:
    args = build_parser().parse_args(arguments)
    if args.command == "verify-package":
        payload = verify_queue_package(args.queue_root)
    elif args.command == "verify-budget":
        payload = verify_budget(args.queue_root.resolve(), args.stage)
        if args.format == "shell":
            print(
                payload["term_after_seconds"],
                payload["termination_grace_seconds"],
                payload["wall_budget_seconds"],
            )
            return 0
    elif args.command == "verify-result":
        payload = verify_result(args.result, args.stage, args.require_expansion)
    elif args.command == "verify-anchor-launch":
        payload = verify_anchor_launch(args.queue_root)
    elif args.command == "verify-queue-launch":
        payload = verify_queue_launch(args.queue_root)
    elif args.command == "resolve-path":
        print(resolve_config_path(args.queue_root.resolve(), args.key))
        return 0
    elif args.command == "assert-unit-guard":
        payload = unit_guard(args.queue_root.resolve(), args.mode)
    elif args.command == "status":
        payload = status_payload(args.queue_root.resolve())
        if not args.json:
            print(f"queue: {payload['queue_id']}")
            package = payload["package"]
            print(
                "package: "
                + ("valid" if package["passed"] else f"INVALID: {package['error']}")
            )
            units = payload["active_scientific_units"]
            print(
                "active scientific units: "
                + (
                    ", ".join(units["active"]) or "none"
                    if units["passed"]
                    else f"UNKNOWN: {units['error']}"
                )
            )
            for stage, record in payload["results"].items():
                completion = record["completion"] or {}
                progress = record["progress"] or {}
                state = completion.get("status") or progress.get("state") or "absent"
                phase = progress.get("phase") or progress.get("current_phase") or "-"
                completed = progress.get("frames_completed", "-")
                total = progress.get("frames_total", "-")
                print(
                    f"{stage}: {state}; phase={phase}; frames={completed}/{total}; "
                    f"path={record['path']}"
                )
            return 0
    else:  # pragma: no cover - argparse makes this unreachable
        raise AssertionError(args.command)
    print(json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (GateError, OSError, KeyError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
