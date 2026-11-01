#!/usr/bin/env python3
"""Fail-closed controller for the four-job exact-map update campaign."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any, Iterable, Mapping

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore[no-redef]


EXPERIMENT_ID = "RQ2-EXACT-MAP-UPDATE-001"
QUEUE_SCHEMA = "rq2-exact-map-update-001/queue-v1"
FREEZE_SCHEMA = "rq2-exact-map-update-001/freeze-v1"
PREFLIGHT_SCHEMA = "rq2-exact-map-update-001/preflight-v1"
JOB_GATE_SCHEMA = "rq2-exact-map-update-001/job-gate-v1"
ENDPOINT_SCHEMA = "rq2-exact-map-update-001/endpoint-gate-v1"
COMPLETION_SCHEMA = "rq2-exact-map-update-001/job-completion-v1"
TIMING_SCHEMA = "rq2-exact-map-update-001/timing-v1"
BUDGET_SCHEMA = "rq2-exact-map-update-001/derived-budget-v1"
LOCK_SCHEMA = "rq2-exact-map-update-001/queue-lock-v1"
MANIFEST_NAME = "QUEUE_MANIFEST.sha256"
LOCK_NAME = "QUEUE_PACKAGE_LOCK.toml"

JOB_ORDER = (
    "01_validation_reproduction_gate",
    "02_fresh_dual_snr_anchor",
    "03_six_db_transfer",
    "04_second_snr_confirmation",
)
VALIDATION_JOBS = frozenset(JOB_ORDER[:1])
SCIENCE_JOBS = frozenset(JOB_ORDER[1:])
DERIVED_BUDGET_JOBS = frozenset(JOB_ORDER[2:])
FIXED_TIMEOUTS = {
    JOB_ORDER[0]: 7200,
    JOB_ORDER[1]: 7200,
}
EXPECTED_WORK = {
    JOB_ORDER[0]: (24, 4, 30, 2),
    JOB_ORDER[1]: (48, 4, 30, 2),
    JOB_ORDER[2]: (200, 4, 30, 2),
    JOB_ORDER[3]: (200, 4, 30, 2),
}
ARM_IDS = (
    "true_gradient__armijo",
    "map_minus_state__armijo",
    "true_gradient__unit",
    "map_minus_state__unit",
)
ARM_CONTRACT = {
    "true_gradient__armijo": ("true_gradient", "armijo"),
    "map_minus_state__armijo": ("map_minus_state", "armijo"),
    "true_gradient__unit": ("true_gradient", "unit"),
    "map_minus_state__unit": ("map_minus_state", "unit"),
}
EXPECTED_CASES = {
    JOB_ORDER[0]: frozenset(("six_db", frame) for frame in range(20001, 20025)),
    JOB_ORDER[1]: frozenset(
        [("six_db", frame) for frame in range(60425, 60449)]
        + [("second_snr", frame) for frame in range(60425, 60449)]
    ),
    JOB_ORDER[2]: frozenset(("six_db", frame) for frame in range(60449, 60649)),
    JOB_ORDER[3]: frozenset(("second_snr", frame) for frame in range(60649, 60849)),
}
SCIENCE_SCHEMA = "rq2-exact-map-update-001/science-v1"
FRAME_COLUMNS = (
    "job_id", "channel", "snr_db", "frame", "noise_seed", "llr_sha256",
    "arm_id", "direction_rule", "step_rule", "gradient_evaluated",
    "updates_attempted",
    "accepted_updates", "line_search_stalls", "non_descent_stalls",
    "absorbing_failure", "failure_update", "objective_evaluations",
    "first_valid_update", "first_exact_word_update", "terminal_outcome_eligible",
    "terminal_parity_valid", "terminal_exact_word", "terminal_coded_bit_errors",
    "terminal_syndrome_weight", "terminal_hard_word_sha256", "terminal_objective",
    "objective_increase_count", "directional_derivative_nonnegative_count",
    "unit_identity_exact_all", "unit_identity_max_abs_error",
    "unit_assignment_exact_all", "unit_assignment_max_abs_error",
    "native_valid", "native_exact_word", "native_iterations",
    "native_coded_bit_errors", "native_hard_word_sha256",
    "native_endpoint_gate_passed",
)
ITERATION_COLUMNS = (
    "job_id", "channel", "frame", "arm_id", "direction_rule", "step_rule",
    "update", "objective_before", "objective_after", "residual_norm_before",
    "residual_norm_after", "gradient_norm", "direction_norm",
    "directional_derivative", "gradient_evaluated", "step_size",
    "backtracks", "accepted",
    "non_descent", "absorbing_failure", "finite_trial", "objective_increased",
    "unit_identity_exact", "unit_identity_max_abs_error",
    "unit_assignment_exact", "unit_assignment_max_abs_error", "parity_valid",
    "exact_word", "coded_bit_errors", "syndrome_weight", "state_sha256",
    "hard_word_sha256",
)
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,160}$")
PLACEHOLDERS = {"freeze", "output", "job_id", "queue_root"}

IMMUTABLE_FILES = {
    "README.md",
    "campaign_queue.py",
    "launch_detached.sh",
    "lock_queue_package.py",
    "queue.toml",
    "run_queue.sh",
}
BASE_TELEMETRY = {
    "queue.lock",
    "queue.log",
    "progress.toml",
    "phase_log.tsv",
    "status_history.tsv",
    "QUEUE_COMPLETED.toml",
    "QUEUE_FAILED.toml",
}


class GateError(RuntimeError):
    """An integrity, preregistration, launch, or result gate failed."""


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def load_toml(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except (OSError, ValueError) as error:
        raise GateError(f"cannot read registered TOML file {path}: {error}") from error


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _hash(value: object, label: str, *, allow_empty: bool = False) -> str:
    rendered = str(value)
    if allow_empty and rendered == "":
        return rendered
    if not HASH_RE.fullmatch(rendered):
        raise GateError(f"{label} must be a lowercase SHA-256 digest")
    return rendered


def safe_relative(value: str) -> str:
    candidate = PurePosixPath(value)
    if (
        not value
        or candidate.is_absolute()
        or value != candidate.as_posix()
        or "." in candidate.parts
        or ".." in candidate.parts
    ):
        raise GateError(f"unsafe relative path: {value!r}")
    return value


def iter_files(root: Path) -> Iterable[str]:
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise GateError(f"symlinks are forbidden: {path}")
        if path.is_file():
            yield path.relative_to(root).as_posix()
        elif not path.is_dir():
            raise GateError(f"special filesystem entry is forbidden: {path}")


def parse_checksum_manifest(path: Path) -> dict[str, str]:
    if not path.is_file() or path.is_symlink():
        raise GateError(f"missing or indirect checksum manifest: {path}")
    listed: dict[str, str] = {}
    for number, row in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        expected, separator, relative = row.partition("  ")
        if not separator or not HASH_RE.fullmatch(expected):
            raise GateError(f"malformed checksum row {number} in {path}")
        relative = safe_relative(relative)
        if relative in listed:
            raise GateError(f"duplicate checksum path: {relative}")
        listed[relative] = expected
    if not listed:
        raise GateError(f"empty checksum manifest: {path}")
    return listed


def render_toml(fields: Mapping[str, object]) -> str:
    rows: list[str] = []
    for key, value in fields.items():
        if isinstance(value, bool):
            rendered = "true" if value else "false"
        elif isinstance(value, int):
            rendered = str(value)
        elif isinstance(value, float):
            rendered = repr(value)
        else:
            rendered = json.dumps(str(value), ensure_ascii=True)
        rows.append(f"{key} = {rendered}")
    return "\n".join(rows) + "\n"


def atomic_replace(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.tmp.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)


def exclusive_write(path: Path, text: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())


def append_fsync(path: Path, text: str) -> None:
    with path.open("a", encoding="utf-8", newline="") as handle:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())


def _positive_int(value: object, label: str, *, zero: bool = False) -> int:
    minimum = 0 if zero else 1
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        qualifier = "nonnegative" if zero else "positive"
        raise GateError(f"{label} must be a {qualifier} integer")
    return value


def _positive_float(value: object, label: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise GateError(f"{label} must be a finite positive number")
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise GateError(f"{label} must be a finite positive number")
    return result


def _validate_command(value: object, label: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise GateError(f"{label} must be a nonempty token array")
    command: list[str] = []
    found: set[str] = set()
    for index, token in enumerate(value):
        if not isinstance(token, str) or not token or "\x00" in token or "\n" in token:
            raise GateError(f"{label}[{index}] is not a safe command token")
        for placeholder in re.findall(r"\{([^{}]+)\}", token):
            if placeholder not in PLACEHOLDERS:
                raise GateError(f"{label} uses unknown placeholder {placeholder!r}")
            found.add(placeholder)
        command.append(token)
    if not {"freeze", "output", "job_id"}.issubset(found):
        raise GateError(f"{label} must reference freeze, output, and job_id")
    joined = "\0".join(command)
    if "--project={freeze}/source/jade_project" not in command:
        raise GateError(f"{label} must use the frozen Julia project")
    if "{freeze}/rq2_exact_map_update_001/exact_map_update.jl" not in joined:
        raise GateError(f"{label} must execute the frozen exact-map runner")
    if "{freeze}/rq2_exact_map_update_001/config.toml" not in joined:
        raise GateError(f"{label} must use the frozen exact-map config")
    return command


def queue_config(queue_root: Path) -> dict[str, Any]:
    path = queue_root / "queue.toml"
    if not path.is_file() or path.is_symlink():
        raise GateError(f"missing or indirect queue configuration: {path}")
    config = load_toml(path)
    expected_top = {
        "schema_version", "experiment_id", "queue_id", "execution", "paths",
        "preflight", "jobs", "inventory", "telemetry",
    }
    if set(config) != expected_top:
        raise GateError("queue configuration top-level fields differ from schema")
    if config["schema_version"] != QUEUE_SCHEMA or config["experiment_id"] != EXPERIMENT_ID:
        raise GateError("queue schema or experiment ID mismatch")
    if not isinstance(config["queue_id"], str) or not ID_RE.fullmatch(config["queue_id"]):
        raise GateError("unsafe queue_id")

    execution = config["execution"]
    execution_fields = {
        "unit_name", "scientific_unit_pattern", "global_lock_name",
        "automatic_restart_allowed", "resume_allowed", "overwrite_allowed",
        "julia_threads", "omp_threads", "blas_threads", "nice", "ionice_class",
    }
    if not isinstance(execution, dict) or set(execution) != execution_fields:
        raise GateError("execution fields differ from schema")
    if not re.fullmatch(r"sp-gd-[A-Za-z0-9_.@-]+\.service", str(execution["unit_name"])):
        raise GateError("unit_name must be an sp-gd systemd service")
    if any(execution[name] is not False for name in (
        "automatic_restart_allowed", "resume_allowed", "overwrite_allowed"
    )):
        raise GateError("restart, resume, and overwrite must remain disabled")
    for field in ("julia_threads", "omp_threads", "blas_threads"):
        if execution[field] != 1:
            raise GateError(f"{field} must equal one")
    if execution["nice"] != 19 or execution["ionice_class"] != "idle":
        raise GateError("registered low-priority execution settings changed")
    for field in ("scientific_unit_pattern", "global_lock_name"):
        if not isinstance(execution[field], str) or not execution[field]:
            raise GateError(f"execution.{field} must be nonempty")
    if execution["global_lock_name"] != "sp-gd-scientific.lock":
        raise GateError("global_lock_name differs from the launcher contract")

    paths = config["paths"]
    if not isinstance(paths, dict) or set(paths) != {"freeze_root", "workdir", "output_root"}:
        raise GateError("paths fields differ from schema")
    for field, value in paths.items():
        if not isinstance(value, str) or not Path(value).is_absolute():
            raise GateError(f"paths.{field} must be an absolute path")

    preflight = config["preflight"]
    if not isinstance(preflight, dict) or set(preflight) != {
        "archived_relative_path", "record_sha256", "validation_status"
    }:
        raise GateError("preflight fields differ from schema")
    safe_relative(str(preflight["archived_relative_path"]))
    _hash(preflight["record_sha256"], "preflight.record_sha256")
    if preflight["validation_status"] != "pass":
        raise GateError("preflight validation_status must be pass")

    raw_jobs = config["jobs"]
    if not isinstance(raw_jobs, list) or [job.get("id") for job in raw_jobs if isinstance(job, dict)] != list(JOB_ORDER):
        raise GateError("jobs must contain the registered strict four-job order")
    jobs: list[dict[str, Any]] = []
    job_fields = {
        "id", "kind", "output", "command", "termination_grace_seconds",
        "timeout_seconds", "budget_safety_factor", "expected_frame_count",
        "expected_arm_count", "expected_update_attempts_per_arm", "expected_pass_count",
    }
    outputs: set[str] = set()
    for index, raw in enumerate(raw_jobs):
        if not isinstance(raw, dict) or set(raw) != job_fields:
            raise GateError(f"jobs[{index}] fields differ from schema")
        job = dict(raw)
        job_id = JOB_ORDER[index]
        expected_kind = "validation" if job_id in VALIDATION_JOBS else "science"
        if job["kind"] != expected_kind:
            raise GateError(f"{job_id} must have kind={expected_kind}")
        output = safe_relative(str(job["output"]))
        if output in outputs:
            raise GateError(f"duplicate job output: {output}")
        outputs.add(output)
        job["command"] = _validate_command(job["command"], f"jobs[{index}].command")
        _positive_int(job["termination_grace_seconds"], f"{job_id}.termination_grace_seconds")
        _positive_float(job["budget_safety_factor"], f"{job_id}.budget_safety_factor")
        if job["termination_grace_seconds"] != 120:
            raise GateError(f"{job_id} termination grace differs from registration")
        if float(job["budget_safety_factor"]) != 1.5:
            raise GateError(f"{job_id} budget safety factor differs from registration")
        for field in (
            "expected_frame_count", "expected_arm_count",
            "expected_update_attempts_per_arm", "expected_pass_count",
        ):
            _positive_int(job[field], f"{job_id}.{field}", zero=True)
        registered_work = tuple(job[field] for field in (
            "expected_frame_count", "expected_arm_count",
            "expected_update_attempts_per_arm", "expected_pass_count",
        ))
        if registered_work != EXPECTED_WORK[job_id]:
            raise GateError(f"{job_id} work declaration differs from registration")
        for field in (
            "expected_frame_count", "expected_arm_count",
            "expected_update_attempts_per_arm", "expected_pass_count",
        ):
            _positive_int(job[field], f"{job_id}.{field}")
        timeout = job["timeout_seconds"]
        if job_id in DERIVED_BUDGET_JOBS:
            if timeout != 0:
                raise GateError(f"{job_id} timeout must be derived, not fixed")
        else:
            _positive_int(timeout, f"{job_id}.timeout_seconds")
            if timeout != FIXED_TIMEOUTS[job_id]:
                raise GateError(f"{job_id} fixed timeout differs from registration")
        jobs.append(job)
    config["jobs"] = jobs

    inventory = config["inventory"]
    telemetry = config["telemetry"]
    if not isinstance(inventory, dict) or set(inventory) != {"immutable_files"}:
        raise GateError("inventory fields differ from schema")
    if set(inventory["immutable_files"]) != IMMUTABLE_FILES:
        raise GateError("immutable queue inventory differs")
    if not isinstance(telemetry, dict) or set(telemetry) != {"files", "prefixes"}:
        raise GateError("telemetry fields differ from schema")
    if set(telemetry["files"]) != BASE_TELEMETRY or set(telemetry["prefixes"]) != {"budgets/"}:
        raise GateError("telemetry inventory differs")
    return config


def verify_freeze(freeze_root: Path) -> dict[str, Any]:
    if not freeze_root.is_dir() or freeze_root.is_symlink():
        raise GateError(f"freeze is missing or indirect: {freeze_root}")
    manifest_path = freeze_root / "MANIFEST.sha256"
    listed = parse_checksum_manifest(manifest_path)
    actual = set(iter_files(freeze_root))
    if actual != set(listed) | {"MANIFEST.sha256"}:
        raise GateError("freeze inventory differs from its checksum manifest")
    for relative, expected in listed.items():
        if sha256_file(freeze_root / relative) != expected:
            raise GateError(f"freeze checksum mismatch: {relative}")
    metadata = load_toml(freeze_root / "freeze_manifest.toml")
    if set(metadata) != {
        "schema_version", "experiment_id", "attempt_id", "created_utc",
        "source_spec_sha256", "predecessor_root", "predecessor_manifest_sha256",
        "predecessor_payload_file_count", "overlay_file_count", "file_count",
        "sources",
    }:
        raise GateError("freeze metadata fields differ from schema")
    if metadata.get("schema_version") != FREEZE_SCHEMA or metadata.get("experiment_id") != EXPERIMENT_ID:
        raise GateError("freeze metadata schema or experiment ID mismatch")
    _hash(metadata["source_spec_sha256"], "freeze source_spec_sha256")
    _hash(
        metadata["predecessor_manifest_sha256"],
        "freeze predecessor_manifest_sha256",
    )
    if not isinstance(metadata["predecessor_root"], str) or not Path(
        metadata["predecessor_root"]
    ).is_absolute():
        raise GateError("freeze predecessor_root must be absolute")
    predecessor_count = _positive_int(
        metadata["predecessor_payload_file_count"],
        "freeze predecessor_payload_file_count",
    )
    overlay_count = _positive_int(
        metadata["overlay_file_count"], "freeze overlay_file_count"
    )
    sources = metadata.get("sources")
    if not isinstance(sources, list) or not sources:
        raise GateError("freeze metadata has no sources")
    if metadata["file_count"] != len(sources):
        raise GateError("freeze metadata file_count differs from source records")
    if metadata["file_count"] != predecessor_count + overlay_count:
        raise GateError("freeze lineage counts do not sum to file_count")
    archived: set[str] = set()
    for source in sources:
        if not isinstance(source, dict) or set(source) != {
            "label", "original_path", "archived_relative_path", "sha256", "executable"
        }:
            raise GateError("freeze source record fields differ")
        relative = safe_relative(str(source["archived_relative_path"]))
        if relative in archived or relative not in listed:
            raise GateError(f"duplicate or unlisted frozen source: {relative}")
        archived.add(relative)
        if not isinstance(source["executable"], bool):
            raise GateError(f"freeze executable flag is not Boolean: {relative}")
        if listed[relative] != _hash(source["sha256"], f"freeze source {relative}"):
            raise GateError(f"freeze source digest differs: {relative}")
        mode = (freeze_root / relative).stat().st_mode
        if mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
            raise GateError(f"frozen source is writable: {relative}")
        if bool(mode & stat.S_IXUSR) is not source["executable"]:
            raise GateError(f"frozen source executable mode differs: {relative}")
    required = {
        "rq2_exact_map_update_001/preflight_validation.toml",
        "rq2_exact_map_update_001/exact_map_update.jl",
        "rq2_exact_map_update_001/test_exact_map_update.jl",
        "rq2_exact_map_update_001/config.toml",
        "rq2_exact_map_update_001/experiment_card.md",
        "source/native_composition.jl", "source/config.toml",
        "source/rung_registry.toml",
        "rq2_bp_target_state_update_001/rq2_bp_target_state_update_001.jl",
        "source/jade_project/Project.toml", "source/jade_project/Manifest.toml",
        "source/jade_project/src/JadeJcade.jl",
        "source/jade_project/tools/ldpc/make-ldpc",
        "source/jade_project/tools/ldpc/make-gen",
        "source/jade_project/tools/ldpc/print-pchk",
        "source/jade_project/tools/ldpc/src/randfile",
    }
    if not required.issubset(archived):
        raise GateError(f"freeze misses required sources: {sorted(required-archived)}")
    return metadata


def verify_preflight(config: Mapping[str, Any]) -> dict[str, Any]:
    freeze = Path(config["paths"]["freeze_root"])
    record_path = freeze / config["preflight"]["archived_relative_path"]
    if not record_path.is_file() or record_path.is_symlink():
        raise GateError("archived preflight record is missing or indirect")
    if sha256_file(record_path) != config["preflight"]["record_sha256"]:
        raise GateError("archived preflight digest differs from queue registration")
    record = load_toml(record_path)
    required = {
        "schema_version": PREFLIGHT_SCHEMA,
        "experiment_id": EXPERIMENT_ID,
        "validation_status": "pass",
        "candidate_runner_tests_passed": True,
        "candidate_queue_tests_passed": True,
        "candidate_runner_test_count": 80,
        "candidate_queue_test_count": 16,
        "candidate_full_frame_job_run": False,
        "queued_job1_mandatory_before_science": True,
        "official_runner_revalidation_passed": False,
        "official_runner_test_count": 0,
        "official_static_revalidation_passed": True,
        "official_full_frame_validation_run": False,
        "official_queue_revalidation_passed": True,
        "official_queue_test_count": 16,
        "candidate_official_source_equivalence_passed": True,
        "predecessor_freeze_verified": True,
        "four_arm_contract_reviewed": True,
        "unit_assignment_gate_reviewed": True,
        "deterministic_replay_required": True,
        "command_contract_reviewed": True,
    }
    if set(record) != set(required):
        raise GateError("preflight fields differ from schema")
    for field, expected in required.items():
        if record[field] != expected:
            raise GateError(f"preflight gate failed: {field}")
    return record


def verify_queue_package(queue_root: Path) -> dict[str, Any]:
    config = queue_config(queue_root)
    manifest = parse_checksum_manifest(queue_root / MANIFEST_NAME)
    if set(manifest) != IMMUTABLE_FILES:
        raise GateError("queue checksum manifest differs from immutable inventory")
    for relative, expected in manifest.items():
        path = queue_root / relative
        if not path.is_file() or path.is_symlink() or sha256_file(path) != expected:
            raise GateError(f"queue immutable checksum mismatch: {relative}")
    lock = load_toml(queue_root / LOCK_NAME)
    required_lock = {
        "schema_version", "experiment_id", "queue_id", "status", "created_utc",
        "immutable_count", "queue_manifest_sha256",
    }
    if set(lock) != required_lock:
        raise GateError("queue package lock fields differ")
    if (
        lock["schema_version"] != LOCK_SCHEMA
        or lock["experiment_id"] != EXPERIMENT_ID
        or lock["queue_id"] != config["queue_id"]
        or lock["status"] != "locked"
        or lock["immutable_count"] != len(IMMUTABLE_FILES)
        or lock["queue_manifest_sha256"] != sha256_file(queue_root / MANIFEST_NAME)
    ):
        raise GateError("queue package lock does not match the queue")
    allowed = IMMUTABLE_FILES | {MANIFEST_NAME, LOCK_NAME} | BASE_TELEMETRY
    for relative in iter_files(queue_root):
        if relative in allowed or relative.startswith("budgets/"):
            continue
        raise GateError(f"unregistered file in locked queue package: {relative}")
    return config


def lock_queue_package(queue_root: Path) -> dict[str, Any]:
    if (queue_root / MANIFEST_NAME).exists() or (queue_root / LOCK_NAME).exists():
        raise GateError("queue package is already locked or partially locked")
    config = queue_config(queue_root)
    actual = set(iter_files(queue_root))
    if actual != IMMUTABLE_FILES:
        raise GateError(f"unlocked queue inventory differs: {sorted(actual ^ IMMUTABLE_FILES)}")
    manifest_text = "".join(
        f"{sha256_file(queue_root / relative)}  {relative}\n"
        for relative in sorted(IMMUTABLE_FILES)
    )
    exclusive_write(queue_root / MANIFEST_NAME, manifest_text, 0o444)
    lock = {
        "schema_version": LOCK_SCHEMA,
        "experiment_id": EXPERIMENT_ID,
        "queue_id": config["queue_id"],
        "status": "locked",
        "created_utc": utc_now(),
        "immutable_count": len(IMMUTABLE_FILES),
        "queue_manifest_sha256": sha256_file(queue_root / MANIFEST_NAME),
    }
    exclusive_write(queue_root / LOCK_NAME, render_toml(lock), 0o444)
    verify_queue_package(queue_root)
    return lock


def output_path(config: Mapping[str, Any], job: Mapping[str, Any]) -> Path:
    return Path(config["paths"]["output_root"]) / str(job["output"])


def assert_fresh(queue_root: Path, *, allow_runtime_shell_files: bool = False) -> None:
    config = verify_queue_package(queue_root)
    for relative in BASE_TELEMETRY:
        if allow_runtime_shell_files and relative in {"queue.lock", "queue.log"}:
            continue
        if (queue_root / relative).exists():
            raise GateError(f"queue telemetry already exists: {relative}")
    if (queue_root / "budgets").exists():
        raise GateError("derived budget directory already exists")
    for job in config["jobs"]:
        if output_path(config, job).exists():
            raise GateError(f"job output already exists: {output_path(config, job)}")


def active_scientific_units(pattern: str) -> list[str]:
    process = subprocess.run(
        ["systemctl", "--user", "list-units", "--type=service", "--state=activating,running", "--no-legend", "--plain", pattern],
        check=False, capture_output=True, text=True,
    )
    if process.returncode != 0:
        raise GateError(f"cannot inspect active scientific units: {process.stderr.strip()}")
    return sorted({line.split()[0] for line in process.stdout.splitlines() if line.split()})


def assert_no_competing_units(config: Mapping[str, Any], *, allow_own: bool) -> None:
    units = active_scientific_units(str(config["execution"]["scientific_unit_pattern"]))
    own = str(config["execution"]["unit_name"])
    competing = [unit for unit in units if not (allow_own and unit == own)]
    if competing:
        raise GateError(f"competing scientific units are active: {', '.join(competing)}")


def _manifest_inventory(result: Path) -> dict[str, str]:
    listed = parse_checksum_manifest(result / "MANIFEST.sha256")
    actual = set(iter_files(result))
    if actual != set(listed) | {"MANIFEST.sha256"}:
        raise GateError(f"result inventory differs from manifest: {result}")
    for relative, expected in listed.items():
        if sha256_file(result / relative) != expected:
            raise GateError(f"result checksum mismatch: {relative}")
    return listed


def _load_csv_rows(path: Path, columns: tuple[str, ...]) -> list[dict[str, str]]:
    if not path.is_file() or path.is_symlink():
        raise GateError(f"missing or indirect CSV result: {path}")
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if tuple(reader.fieldnames or ()) != columns:
            raise GateError(f"CSV columns differ from schema: {path.name}")
        rows = list(reader)
    for index, row in enumerate(rows, 2):
        if None in row or set(row) != set(columns):
            raise GateError(f"malformed CSV row {index}: {path.name}")
    return rows


def _load_science(path: Path, job: Mapping[str, Any]) -> dict[str, Any]:
    try:
        science = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise GateError(f"cannot parse science.json for {job['id']}: {error}") from error
    if not isinstance(science, dict):
        raise GateError(f"science.json must contain an object for {job['id']}")
    required = {"schema_version", "experiment_id", "job_id", "validation_only"}
    if not required.issubset(science):
        raise GateError(f"science identity fields are missing for {job['id']}")
    if (
        science["schema_version"] != SCIENCE_SCHEMA
        or science["experiment_id"] != EXPERIMENT_ID
        or science["job_id"] != job["id"]
        or science["validation_only"] is not (job["kind"] == "validation")
    ):
        raise GateError(f"science identity differs from registration for {job['id']}")
    return science


def _row_identity(
    row: Mapping[str, Any], *, iteration: bool = False
) -> tuple[object, ...]:
    try:
        base: tuple[object, ...] = (
            str(row["channel"]), int(row["frame"]), str(row["arm_id"])
        )
        return base + ((int(row["update"]),) if iteration else ())
    except (KeyError, TypeError, ValueError) as error:
        kind = "iteration" if iteration else "frame"
        raise GateError(f"invalid {kind}-row identity") from error


def _bool(value: object, label: str) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str) and value.lower() in {"true", "false"}:
        return value.lower() == "true"
    raise GateError(f"{label} must be Boolean")


def _csv_int(value: object, label: str, *, zero: bool = True) -> int:
    try:
        result = int(str(value))
    except (TypeError, ValueError) as error:
        raise GateError(f"{label} must be an integer") from error
    lower = 0 if zero else 1
    if result < lower:
        qualifier = "nonnegative" if zero else "positive"
        raise GateError(f"{label} must be a {qualifier} integer")
    return result


def _finite(value: object, label: str, *, nonnegative: bool = False) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as error:
        raise GateError(f"{label} must be finite") from error
    if not math.isfinite(number) or (nonnegative and number < 0):
        raise GateError(f"{label} must be finite" + (" and nonnegative" if nonnegative else ""))
    return number


def _validate_frame_rows(
    rows: list[dict[str, str]], *, job: Mapping[str, Any]
) -> set[tuple[str, int]]:
    job_id = str(job["id"])
    expected_cases = EXPECTED_CASES[job_id]
    expected_arms = set(ARM_IDS)
    if len(rows) != len(expected_cases) * len(expected_arms):
        raise GateError(f"frame-row count differs from registration for {job_id}")
    by_case: dict[tuple[str, int], list[str]] = {}
    llr_hashes: dict[tuple[str, int], str] = {}
    native_hashes: dict[tuple[str, int], str] = {}
    for row in rows:
        if row["job_id"] != job_id:
            raise GateError(f"frame row job ID differs for {job_id}")
        channel, frame, arm_id = _row_identity(row)
        case = (str(channel), int(frame))
        if case not in expected_cases or arm_id not in expected_arms:
            raise GateError(f"frame row is outside registered cases or arms for {job_id}")
        if (row["direction_rule"], row["step_rule"]) != ARM_CONTRACT[str(arm_id)]:
            raise GateError(f"frame row factor labels differ for {job_id}: {arm_id}")
        expected_gradient = arm_id != "map_minus_state__unit"
        if _bool(row["gradient_evaluated"], f"{job_id} frames.csv gradient_evaluated") is not expected_gradient:
            raise GateError(f"frame gradient-evaluation label differs for {job_id}: {arm_id}")
        by_case.setdefault(case, []).append(str(arm_id))
        for field in ("llr_sha256", "terminal_hard_word_sha256", "native_hard_word_sha256"):
            _hash(row[field], f"{job_id} frames.csv {field}")
        for field in (
            "updates_attempted", "accepted_updates", "line_search_stalls",
            "non_descent_stalls", "objective_evaluations", "objective_increase_count",
            "directional_derivative_nonnegative_count", "native_iterations",
            "native_coded_bit_errors",
        ):
            _csv_int(row[field], f"{job_id} frames.csv {field}")
        for field in ("terminal_coded_bit_errors", "terminal_syndrome_weight"):
            _csv_int(row[field], f"{job_id} frames.csv {field}")
        for field in (
            "absorbing_failure", "terminal_outcome_eligible", "terminal_parity_valid",
            "terminal_exact_word", "unit_identity_exact_all",
            "unit_assignment_exact_all", "native_valid", "native_exact_word",
            "native_endpoint_gate_passed", "gradient_evaluated",
        ):
            _bool(row[field], f"{job_id} frames.csv {field}")
        _finite(row["terminal_objective"], f"{job_id} frames.csv terminal_objective")
        _finite(
            row["unit_identity_max_abs_error"],
            f"{job_id} frames.csv unit_identity_max_abs_error",
            nonnegative=True,
        )
        _finite(
            row["unit_assignment_max_abs_error"],
            f"{job_id} frames.csv unit_assignment_max_abs_error",
            nonnegative=True,
        )
        if not _bool(
            row["unit_assignment_exact_all"],
            f"{job_id} frames.csv unit_assignment_exact_all",
        ):
            raise GateError(f"unit assignment gate failed for {job_id}")
        if int(row["updates_attempted"]) > int(job["expected_update_attempts_per_arm"]):
            raise GateError(f"update budget exceeded for {job_id}")
        if case in llr_hashes and llr_hashes[case] != row["llr_sha256"]:
            raise GateError(f"LLR identity changes across arms for {job_id} case {case}")
        if case in native_hashes and native_hashes[case] != row["native_hard_word_sha256"]:
            raise GateError(f"native endpoint changes across arms for {job_id} case {case}")
        llr_hashes[case] = row["llr_sha256"]
        native_hashes[case] = row["native_hard_word_sha256"]
    if set(by_case) != set(expected_cases):
        raise GateError(f"case coverage differs from registration for {job_id}")
    for case, arm_ids in by_case.items():
        if len(arm_ids) != len(expected_arms) or set(arm_ids) != expected_arms:
            raise GateError(f"arm coverage differs for {job_id} case {case}")
        if len(arm_ids) != len(set(arm_ids)):
            raise GateError(f"duplicate arm row for {job_id} case {case}")
    return set(by_case)


def _validate_iteration_rows(
    rows: list[dict[str, str]], *, job: Mapping[str, Any],
    cases: set[tuple[str, int]],
) -> None:
    job_id = str(job["id"])
    identities: set[tuple[object, ...]] = set()
    by_case_arm: dict[tuple[str, int, str], list[int]] = {}
    for row in rows:
        if row["job_id"] != job_id:
            raise GateError(f"iteration row job ID differs for {job_id}")
        identity = _row_identity(row, iteration=True)
        case = (str(identity[0]), int(identity[1]))
        arm_id = str(identity[2])
        update = int(identity[3])
        if case not in cases or arm_id not in ARM_IDS:
            raise GateError(f"iteration row is outside registered cases or arms for {job_id}")
        if (row["direction_rule"], row["step_rule"]) != ARM_CONTRACT[arm_id]:
            raise GateError(f"iteration factor labels differ for {job_id}: {arm_id}")
        expected_gradient = arm_id != "map_minus_state__unit"
        actual_gradient = _bool(
            row["gradient_evaluated"],
            f"{job_id} iterations.csv gradient_evaluated",
        )
        absorbing = _bool(
            row["absorbing_failure"],
            f"{job_id} iterations.csv absorbing_failure",
        )
        if (not expected_gradient and actual_gradient) or (
            expected_gradient and not actual_gradient and not absorbing
        ):
            raise GateError(
                f"iteration gradient-evaluation label differs for {job_id}: {arm_id}"
            )
        if identity in identities:
            raise GateError(f"duplicate iteration row for {job_id}: {identity}")
        if update < 1 or update > int(job["expected_update_attempts_per_arm"]):
            raise GateError(f"iteration update is outside registered budget for {job_id}")
        identities.add(identity)
        by_case_arm.setdefault((case[0], case[1], arm_id), []).append(update)
        for field in ("state_sha256", "hard_word_sha256"):
            _hash(row[field], f"{job_id} iterations.csv {field}")
        for field in (
            "objective_before", "objective_after", "residual_norm_before",
            "residual_norm_after", "gradient_norm", "direction_norm",
            "directional_derivative", "step_size", "unit_identity_max_abs_error",
            "unit_assignment_max_abs_error",
        ):
            _finite(row[field], f"{job_id} iterations.csv {field}")
        for field in ("backtracks", "coded_bit_errors", "syndrome_weight"):
            _csv_int(row[field], f"{job_id} iterations.csv {field}")
        for field in (
            "accepted", "non_descent", "absorbing_failure", "finite_trial",
            "objective_increased", "unit_identity_exact", "unit_assignment_exact",
            "parity_valid", "exact_word", "gradient_evaluated",
        ):
            _bool(row[field], f"{job_id} iterations.csv {field}")
        if not _bool(
            row["unit_assignment_exact"],
            f"{job_id} iterations.csv unit_assignment_exact",
        ):
            raise GateError(f"unit assignment gate failed for {job_id}")
    for key, updates in by_case_arm.items():
        if updates != sorted(updates) or len(updates) != len(set(updates)):
            raise GateError(f"iteration order is invalid for {job_id}: {key}")


def _validate_science_tables(
    science: Mapping[str, Any],
    frame_rows: list[dict[str, str]],
    iteration_rows: list[dict[str, str]],
    job: Mapping[str, Any],
) -> None:
    job_id = str(job["id"])
    required = {
        "case_count", "arm_order", "update_attempts_per_arm", "frames_sha256",
        "iterations_sha256", "gates", "cases", "aggregates", "paired_contrasts",
    }
    if not required.issubset(science):
        raise GateError(f"science workload fields are missing for {job_id}")
    if (
        science["case_count"] != int(job["expected_frame_count"])
        or science["arm_order"] != list(ARM_IDS)
        or science["update_attempts_per_arm"] != int(job["expected_update_attempts_per_arm"])
    ):
        raise GateError(f"science workload differs from registration for {job_id}")
    _hash(science["frames_sha256"], f"{job_id} science frames_sha256")
    _hash(science["iterations_sha256"], f"{job_id} science iterations_sha256")
    cases = _validate_frame_rows(frame_rows, job=job)
    _validate_iteration_rows(iteration_rows, job=job, cases=cases)
    if not isinstance(science["gates"], dict):
        raise GateError(f"science gates must be an object for {job_id}")
    for field in ("cases", "aggregates", "paired_contrasts"):
        if not isinstance(science[field], (list, dict)):
            raise GateError(f"science {field} has invalid type for {job_id}")

def verify_timing(path: Path, job: Mapping[str, Any]) -> dict[str, Any]:
    timing = load_toml(path)
    required = {
        "schema_version", "experiment_id", "job_id", "frame_count", "arm_count",
        "update_attempts_per_arm", "pass_count", "primary_seconds",
        "replay_seconds", "write_seconds", "total_seconds", "seconds_per_case_arm",
    }
    if set(timing) != required:
        raise GateError(f"timing fields differ for {job['id']}")
    if (
        timing["schema_version"] != TIMING_SCHEMA
        or timing["experiment_id"] != EXPERIMENT_ID
        or timing["job_id"] != job["id"]
    ):
        raise GateError(f"timing identity mismatch for {job['id']}")
    expected = {
        "frame_count": job["expected_frame_count"],
        "arm_count": job["expected_arm_count"],
        "update_attempts_per_arm": job["expected_update_attempts_per_arm"],
        "pass_count": job["expected_pass_count"],
    }
    for field, value in expected.items():
        _positive_int(timing[field], f"timing.{field}")
        if timing[field] != value:
            raise GateError(f"timing {field} differs from registration for {job['id']}")
    for field in (
        "primary_seconds", "replay_seconds", "write_seconds", "total_seconds",
        "seconds_per_case_arm",
    ):
        value = timing[field]
        if (
            not isinstance(value, (int, float))
            or isinstance(value, bool)
            or not math.isfinite(float(value))
            or float(value) < 0
        ):
            raise GateError(f"timing.{field} must be finite and nonnegative")
    measured_total = (
        float(timing["primary_seconds"]) + float(timing["replay_seconds"])
        + float(timing["write_seconds"])
    )
    if not math.isclose(
        float(timing["total_seconds"]), measured_total, rel_tol=1e-6, abs_tol=1e-6
    ):
        raise GateError(f"timing total is inconsistent for {job['id']}")
    expected_rate = (
        float(timing["primary_seconds"]) + float(timing["replay_seconds"])
    ) / (
        int(timing["frame_count"]) * int(timing["arm_count"])
        * int(timing["pass_count"])
    )
    if not math.isclose(
        float(timing["seconds_per_case_arm"]), expected_rate,
        rel_tol=1e-6, abs_tol=1e-9,
    ):
        raise GateError(f"seconds_per_case_arm is inconsistent for {job['id']}")
    return timing

def verify_result(result: Path, job: Mapping[str, Any]) -> dict[str, Any]:
    if not result.is_dir() or result.is_symlink():
        raise GateError(f"missing or indirect result directory: {result}")
    listed = _manifest_inventory(result)
    required = {
        "COMPLETED.toml", "job_gate.toml", "science.json", "timing.toml",
        "frames.csv", "iterations.csv",
    }
    if job["kind"] == "science":
        required.add("endpoint_gate.toml")
    if set(listed) != required:
        raise GateError(
            f"result inventory differs from schema: {sorted(set(listed) ^ required)}"
        )
    if job["kind"] == "validation" and "endpoint_gate.toml" in listed:
        raise GateError("validation-only job must not emit an endpoint claim")

    science_path = result / "science.json"
    frames_path = result / "frames.csv"
    iterations_path = result / "iterations.csv"
    science = _load_science(science_path, job)
    frame_rows = _load_csv_rows(frames_path, FRAME_COLUMNS)
    iteration_rows = _load_csv_rows(iterations_path, ITERATION_COLUMNS)
    _validate_science_tables(science, frame_rows, iteration_rows, job)

    gate = load_toml(result / "job_gate.toml")
    required_gate = {
        "schema_version", "experiment_id", "job_id", "job_kind", "status",
        "validation_only", "correctness_passed", "deterministic_replay_passed",
        "config_sha256", "block_b_runner_sha256", "primary_science_sha256",
        "replay_science_sha256", "primary_frames_sha256", "replay_frames_sha256",
        "primary_iterations_sha256", "replay_iterations_sha256",
    }
    if set(gate) != required_gate:
        raise GateError(f"job gate fields differ for {job['id']}")
    if (
        gate["schema_version"] != JOB_GATE_SCHEMA
        or gate["experiment_id"] != EXPERIMENT_ID
        or gate["job_id"] != job["id"]
        or gate["job_kind"] != job["kind"]
        or gate["status"] != "pass"
        or gate["validation_only"] is not (job["kind"] == "validation")
        or gate["correctness_passed"] is not True
        or gate["deterministic_replay_passed"] is not True
    ):
        raise GateError(f"job gate failed for {job['id']}")
    for field in (
        "config_sha256", "block_b_runner_sha256", "primary_science_sha256",
        "replay_science_sha256", "primary_frames_sha256", "replay_frames_sha256",
        "primary_iterations_sha256", "replay_iterations_sha256",
    ):
        _hash(gate[field], f"job_gate.{field}")
    for primary, replay in (
        ("primary_science_sha256", "replay_science_sha256"),
        ("primary_frames_sha256", "replay_frames_sha256"),
        ("primary_iterations_sha256", "replay_iterations_sha256"),
    ):
        if gate[primary] != gate[replay]:
            raise GateError(f"deterministic replay digest differs for {job['id']}: {primary}")
    if science["frames_sha256"] != gate["primary_frames_sha256"]:
        raise GateError(f"science and gate frame-table digests differ for {job['id']}")
    if science["iterations_sha256"] != gate["primary_iterations_sha256"]:
        raise GateError(
            f"science and gate iteration-table digests differ for {job['id']}"
        )
    actual_hashes = {
        "primary_science_sha256": sha256_file(science_path),
    }
    for field, expected in actual_hashes.items():
        if gate[field] != expected:
            raise GateError(f"primary artifact digest differs for {job['id']}: {field}")

    completion = load_toml(result / "COMPLETED.toml")
    required_completion = {
        "schema_version", "experiment_id", "job_id", "status", "correctness_passed",
        "deterministic_replay_passed", "science_sha256", "frames_sha256",
        "iterations_sha256", "job_gate_sha256", "endpoint_gate_sha256",
    }
    if set(completion) != required_completion:
        raise GateError(f"completion fields differ for {job['id']}")
    if (
        completion["schema_version"] != COMPLETION_SCHEMA
        or completion["experiment_id"] != EXPERIMENT_ID
        or completion["job_id"] != job["id"]
        or completion["status"] != "complete_valid"
        or completion["correctness_passed"] is not True
        or completion["deterministic_replay_passed"] is not True
    ):
        raise GateError(f"completion gate failed for {job['id']}")
    artifact_digests = {
        "science_sha256": science_path,
        "frames_sha256": frames_path,
        "iterations_sha256": iterations_path,
        "job_gate_sha256": result / "job_gate.toml",
    }
    for field, artifact in artifact_digests.items():
        if _hash(completion[field], f"completion.{field}") != sha256_file(artifact):
            raise GateError(f"completion digest mismatch for {job['id']}: {field}")
    if completion["science_sha256"] != gate["primary_science_sha256"]:
        raise GateError(f"science and replay gate disagree for {job['id']}")

    if job["kind"] == "science":
        endpoint = load_toml(result / "endpoint_gate.toml")
        required_endpoint = {
            "schema_version", "experiment_id", "job_id", "status", "case_count",
            "case_ids_sha256", "channel_llrs_sha256", "native_bp_successes",
            "direct_oracle_80_successes", "native_bp_direct_oracle_equal",
            "map_unit_fixed30_successes", "map_unit_first30_oracle_equal",
            "unit_assignment_exact", "arm_success_counts",
            "absorbing_failure_counts", "native_hard_words_sha256",
            "direct_oracle_80_hard_words_sha256",
        }
        if set(endpoint) != required_endpoint:
            raise GateError(f"endpoint gate fields differ for {job['id']}")
        if (
            endpoint["schema_version"] != ENDPOINT_SCHEMA
            or endpoint["experiment_id"] != EXPERIMENT_ID
            or endpoint["job_id"] != job["id"]
            or endpoint["status"] != "pass"
            or endpoint["case_count"] != job["expected_frame_count"]
            or endpoint["native_bp_direct_oracle_equal"] is not True
            or endpoint["map_unit_first30_oracle_equal"] is not True
            or endpoint["unit_assignment_exact"] is not True
        ):
            raise GateError(f"native endpoint gate failed for {job['id']}")
        for field in (
            "case_ids_sha256", "channel_llrs_sha256",
            "native_hard_words_sha256", "direct_oracle_80_hard_words_sha256",
        ):
            _hash(endpoint[field], f"endpoint_gate.{field}")
        for field in (
            "native_bp_successes", "direct_oracle_80_successes",
            "map_unit_fixed30_successes",
        ):
            value = _positive_int(endpoint[field], f"endpoint_gate.{field}", zero=True)
            if value > int(job["expected_frame_count"]):
                raise GateError(f"endpoint count exceeds case count: {field}")
        for field in ("arm_success_counts", "absorbing_failure_counts"):
            counts = endpoint[field]
            if not isinstance(counts, dict) or set(counts) != set(ARM_IDS):
                raise GateError(f"endpoint {field} arm coverage differs")
            for arm_id, value in counts.items():
                count = _positive_int(value, f"endpoint {field}.{arm_id}", zero=True)
                if count > int(job["expected_frame_count"]):
                    raise GateError(f"endpoint count exceeds case count: {field}.{arm_id}")
        endpoint_path = result / "endpoint_gate.toml"
        if (
            _hash(completion["endpoint_gate_sha256"], "completion.endpoint_gate_sha256")
            != sha256_file(endpoint_path)
        ):
            raise GateError(f"endpoint gate digest mismatch for {job['id']}")
    elif completion["endpoint_gate_sha256"] != "":
        raise GateError("validation-only completion must have an empty endpoint digest")

    timing = verify_timing(result / "timing.toml", job)
    return {"completion": completion, "job_gate": gate, "timing": timing}

def derive_budget(
    anchor_timing: Mapping[str, Any], job: Mapping[str, Any]
) -> dict[str, Any]:
    if job["id"] not in DERIVED_BUDGET_JOBS:
        raise GateError("only Jobs 3 and 4 receive timing-derived budgets")
    anchor_passes = _positive_int(anchor_timing["pass_count"], "anchor pass_count")
    target_passes = _positive_int(job["expected_pass_count"], "target pass count")
    rate = _positive_float(
        anchor_timing["seconds_per_case_arm"], "anchor seconds_per_case_arm"
    )
    frame_count = _positive_int(job["expected_frame_count"], "target frame count")
    arm_count = _positive_int(job["expected_arm_count"], "target arm count")
    core = rate * frame_count * arm_count * target_passes
    anchor_frames = _positive_int(anchor_timing["frame_count"], "anchor frame count")
    write = float(anchor_timing["write_seconds"]) * frame_count / anchor_frames
    safety = _positive_float(job["budget_safety_factor"], "budget safety factor")
    timeout_seconds = max(60, math.ceil((core + write) * safety))
    return {
        "schema_version": BUDGET_SCHEMA,
        "experiment_id": EXPERIMENT_ID,
        "job_id": job["id"],
        "anchor_job_id": JOB_ORDER[1],
        "anchor_seconds_per_case_arm": rate,
        "anchor_pass_count": anchor_passes,
        "target_frame_count": frame_count,
        "target_arm_count": arm_count,
        "target_update_attempts_per_arm": job["expected_update_attempts_per_arm"],
        "target_pass_count": target_passes,
        "projected_scientific_seconds": core,
        "projected_write_seconds": write,
        "safety_factor": safety,
        "timeout_seconds": timeout_seconds,
    }


class Telemetry:
    def __init__(self, root: Path, queue_id: str) -> None:
        self.root = root
        self.queue_id = queue_id
        exclusive_write(root / "phase_log.tsv", "utc\tjob\tevent\tseconds\tdetail\n")
        exclusive_write(root / "status_history.tsv", "utc\tstatus\tjob\tdetail\n")

    def progress(self, status: str, job: str, completed: int, phase: str, detail: str = "") -> None:
        atomic_replace(self.root / "progress.toml", render_toml({
            "schema_version": "rq2-exact-map-update-001/progress-v1",
            "experiment_id": EXPERIMENT_ID,
            "queue_id": self.queue_id,
            "updated_utc": utc_now(),
            "status": status,
            "current_job": job,
            "phase": phase,
            "completed_jobs": completed,
            "total_jobs": len(JOB_ORDER),
            "detail": detail,
        }))
        append_fsync(self.root / "status_history.tsv", f"{utc_now()}\t{status}\t{job}\t{detail}\n")

    def phase(self, job: str, event: str, seconds: float, detail: str = "") -> None:
        append_fsync(self.root / "phase_log.tsv", f"{utc_now()}\t{job}\t{event}\t{seconds:.6f}\t{detail}\n")


def _render_command(command: Iterable[str], *, queue_root: Path, freeze: Path, output: Path, job_id: str) -> list[str]:
    values = {
        "queue_root": str(queue_root), "freeze": str(freeze),
        "output": str(output), "job_id": job_id,
    }
    rendered: list[str] = []
    for token in command:
        try:
            rendered.append(token.format(**values))
        except (KeyError, ValueError) as error:
            raise GateError(f"cannot render command token {token!r}") from error
    return rendered


def _run_process(command: list[str], *, cwd: Path, timeout_seconds: int, grace_seconds: int) -> None:
    process = subprocess.Popen(command, cwd=cwd, start_new_session=True)
    try:
        return_code = process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise GateError(f"job exceeded wall timeout of {timeout_seconds} seconds")
    if return_code != 0:
        raise GateError(f"job exited with status {return_code}")


def run_campaign(queue_root: Path, *, check_units: bool = True) -> dict[str, Any]:
    assert_fresh(queue_root, allow_runtime_shell_files=True)
    config = verify_queue_package(queue_root)
    freeze = Path(config["paths"]["freeze_root"])
    verify_freeze(freeze)
    verify_preflight(config)
    workdir = Path(config["paths"]["workdir"])
    if not workdir.is_dir():
        raise GateError(f"workdir does not exist: {workdir}")
    if check_units:
        assert_no_competing_units(config, allow_own=True)
    telemetry = Telemetry(queue_root, str(config["queue_id"]))
    anchor_timing: dict[str, Any] | None = None
    completed = 0
    telemetry.progress("running", "", completed, "queue_start")
    try:
        for job in config["jobs"]:
            job_id = str(job["id"])
            verify_queue_package(queue_root)
            verify_freeze(freeze)
            output = output_path(config, job)
            if output.exists():
                raise GateError(f"refusing to overwrite job output: {output}")
            if job_id in DERIVED_BUDGET_JOBS:
                if anchor_timing is None:
                    raise GateError("anchor timing is unavailable for derived budget")
                budget = derive_budget(anchor_timing, job)
                budget_path = queue_root / "budgets" / f"{job_id}.toml"
                exclusive_write(budget_path, render_toml(budget), 0o444)
                timeout_seconds = int(budget["timeout_seconds"])
                telemetry.phase(job_id, "budget_derived", 0.0, str(budget_path))
            else:
                timeout_seconds = int(job["timeout_seconds"])
            command = _render_command(
                job["command"], queue_root=queue_root, freeze=freeze,
                output=output, job_id=job_id,
            )
            command = ["nice", "-n", "19", "ionice", "-c", "3", *command]
            telemetry.progress("running", job_id, completed, "job_start", " ".join(command))
            telemetry.phase(job_id, "start", 0.0, f"timeout={timeout_seconds}")
            started = time.monotonic()
            _run_process(
                command, cwd=workdir, timeout_seconds=timeout_seconds,
                grace_seconds=int(job["termination_grace_seconds"]),
            )
            elapsed = time.monotonic() - started
            telemetry.phase(job_id, "process_end", elapsed)
            telemetry.progress("running", job_id, completed, "verify_result")
            verified = verify_result(output, job)
            if job_id == JOB_ORDER[1]:
                anchor_timing = verified["timing"]
            completed += 1
            telemetry.phase(job_id, "verified", elapsed)
            telemetry.progress("running", job_id, completed, "job_complete")
        completion = {
            "schema_version": "rq2-exact-map-update-001/queue-completion-v1",
            "experiment_id": EXPERIMENT_ID,
            "queue_id": config["queue_id"],
            "status": "complete_valid",
            "completed_utc": utc_now(),
            "completed_jobs": completed,
            "total_jobs": len(JOB_ORDER),
        }
        exclusive_write(queue_root / "QUEUE_COMPLETED.toml", render_toml(completion))
        telemetry.progress("complete_valid", JOB_ORDER[-1], completed, "queue_complete")
        return completion
    except Exception as error:
        failure = {
            "schema_version": "rq2-exact-map-update-001/queue-failure-v1",
            "experiment_id": EXPERIMENT_ID,
            "queue_id": config["queue_id"],
            "status": "failed_closed",
            "failed_utc": utc_now(),
            "completed_jobs": completed,
            "detail": str(error),
        }
        if not (queue_root / "QUEUE_FAILED.toml").exists():
            exclusive_write(queue_root / "QUEUE_FAILED.toml", render_toml(failure))
        telemetry.progress("failed_closed", "", completed, "queue_failed", str(error))
        raise


def prelaunch(queue_root: Path) -> dict[str, Any]:
    assert_fresh(queue_root)
    config = verify_queue_package(queue_root)
    verify_freeze(Path(config["paths"]["freeze_root"]))
    verify_preflight(config)
    assert_no_competing_units(config, allow_own=False)
    return {"status": "ready", "unit_name": config["execution"]["unit_name"]}


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)
    for action in ("verify", "assert-fresh", "prelaunch", "run", "unit-name"):
        item = subparsers.add_parser(action)
        item.add_argument("--queue-root", required=True, type=Path)
    args = parser.parse_args(arguments)
    root = args.queue_root.resolve()
    if args.action == "verify":
        result: object = verify_queue_package(root)
    elif args.action == "assert-fresh":
        assert_fresh(root)
        result = {"status": "fresh"}
    elif args.action == "prelaunch":
        result = prelaunch(root)
    elif args.action == "run":
        result = run_campaign(root)
    else:
        print(queue_config(root)["execution"]["unit_name"])
        return 0
    print(json.dumps(result, sort_keys=True, default=str))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (GateError, OSError, KeyError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)

