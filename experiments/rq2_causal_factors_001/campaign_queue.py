#!/usr/bin/env python3
"""Fail-closed controller and verifier for the RQ2 two-block campaign."""

from __future__ import annotations

import argparse
import math
import contextlib
import datetime as dt
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any, Iterable, Mapping

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # pragma: no cover - Python 3.10 deployment
    import tomli as tomllib  # type: ignore[no-redef]


EXPERIMENT_ID = "RQ2-CAUSAL-FACTORS-001"
QUEUE_SCHEMA = "rq2-causal-factors-001/queue-v1"
LOCK_SCHEMA = "rq2-causal-factors-001/queue-package-lock-v1"
FREEZE_SCHEMA = "rq2-causal-factors-001/freeze-v1"
COMPLETION_SCHEMA = "rq2-causal-factors-001/result-completion-v1"
ENDPOINT_SCHEMA = "rq2-causal-factors-001/endpoint-gate-v1"
PREFLIGHT_SCHEMA = "rq2-causal-factors-001/preflight-v1"
TIMING_SCHEMA = "rq2-causal-factors-001/stage-timing-v1"
BUDGET_SCHEMA = "rq2-causal-factors-001/derived-budget-v1"
MANIFEST_NAME = "QUEUE_MANIFEST.sha256"
LOCK_NAME = "QUEUE_PACKAGE_LOCK.toml"
BLOCK_ORDER = ("A", "B")
STAGE_ORDER = ("calibration", "fresh_anchor", "fresh_transfer", "attribution")
RUNNER_STAGE = {
    "calibration": "calibration",
    "fresh_anchor": "anchor",
    "fresh_transfer": "transfer",
    "attribution": "attribution",
}
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
PLACEHOLDERS = {
    "queue_root",
    "freeze",
    "output",
    "block",
    "stage",
    "runner_stage",
}

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
A_ENDPOINT_FIELDS = {
    "frame_first",
    "frame_last",
    "frame_count",
    "frame_ids_sha256",
    "channel_llrs_sha256",
    "native_gd_successes",
    "v4_asbuilt_frozen_successes",
    "native_bp_successes",
    "native_gd_hard_words_sha256",
    "v4_asbuilt_frozen_hard_words_sha256",
    "native_bp_hard_words_sha256",
}
B_ENDPOINT_FIELDS = {
    "frame_first",
    "frame_last",
    "frame_count",
    "frame_ids_sha256",
    "channel_llrs_sha256",
    "native_bp_successes",
    "native_bp_hard_words_sha256",
    "full_direct_successes",
    "full_direct_hard_words_sha256",
    "native_bp_full_direct_equal",
}
FRAME_FIELDS = {"frame_first", "frame_last", "frame_count"}


class GateError(RuntimeError):
    """A registered integrity, launch, or result gate failed."""


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


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


def _validate_hash(value: object, label: str) -> str:
    rendered = str(value)
    if not HASH_RE.fullmatch(rendered):
        raise GateError(f"{label} must be a concrete lowercase SHA-256 digest")
    return rendered


def runner_stage(stage: str) -> str:
    try:
        return RUNNER_STAGE[stage]
    except KeyError as error:
        raise GateError(f"unknown campaign stage: {stage!r}") from error


def validate_endpoint_expectation(
    value: object, label: str, block_id: str
) -> dict[str, Any]:
    allowed_modes = {"exact", "self_consistency"} if block_id == "A" else {"cross_block_bp"}
    if not isinstance(value, dict) or value.get("mode") not in allowed_modes:
        raise GateError(f"{label}.mode must be one of {sorted(allowed_modes)}")
    expected_fields = FRAME_FIELDS | {"mode"}
    if block_id == "A" and value["mode"] == "exact":
        expected_fields = A_ENDPOINT_FIELDS | {"mode"}
    if set(value) != expected_fields:
        found = set(value) if isinstance(value, dict) else set()
        raise GateError(
            f"{label} endpoint fields differ: "
            f"missing={sorted(expected_fields-found)}, "
            f"extra={sorted(found-expected_fields)}"
        )
    result = dict(value)
    for field in FRAME_FIELDS:
        item = result[field]
        if not isinstance(item, int) or isinstance(item, bool) or item < 0:
            raise GateError(f"{label}.{field} must be a nonnegative integer")
    if result["frame_last"] - result["frame_first"] + 1 != result["frame_count"]:
        raise GateError(f"{label} frame range does not equal frame_count")
    if block_id == "A" and result["mode"] == "exact":
        for field in (
            "native_gd_successes",
            "v4_asbuilt_frozen_successes",
            "native_bp_successes",
        ):
            item = result[field]
            if not isinstance(item, int) or isinstance(item, bool) or item < 0:
                raise GateError(f"{label}.{field} must be a nonnegative integer")
            if item > result["frame_count"]:
                raise GateError(f"{label}.{field} exceeds frame_count")
        for field in A_ENDPOINT_FIELDS - FRAME_FIELDS - {
            "native_gd_successes",
            "v4_asbuilt_frozen_successes",
            "native_bp_successes",
        }:
            _validate_hash(result[field], f"{label}.{field}")
    return result


def _validate_command(value: object, label: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise GateError(f"{label} must be a nonempty token array")
    command: list[str] = []
    for index, token in enumerate(value):
        if not isinstance(token, str) or not token or "\x00" in token or "\n" in token:
            raise GateError(f"{label}[{index}] is not a safe command token")
        names = set(re.findall(r"\{([A-Za-z_][A-Za-z0-9_]*)\}", token))
        unknown = names - PLACEHOLDERS
        if unknown:
            raise GateError(f"{label}[{index}] uses unknown placeholders: {unknown}")
        command.append(token)
    return command


def queue_config(queue_root: Path) -> dict[str, Any]:
    path = queue_root / "queue.toml"
    if not path.is_file() or path.is_symlink():
        raise GateError(f"missing or indirect queue configuration: {path}")
    config = load_toml(path)
    expected_top = {
        "schema_version",
        "experiment_id",
        "queue_id",
        "execution",
        "paths",
        "preflight",
        "blocks",
        "inventory",
        "telemetry",
    }
    if set(config) != expected_top:
        raise GateError("queue.toml top-level fields differ from the registered schema")
    if config["schema_version"] != QUEUE_SCHEMA or config["experiment_id"] != EXPERIMENT_ID:
        raise GateError("queue schema or experiment ID mismatch")
    queue_id = config["queue_id"]
    if not isinstance(queue_id, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", queue_id):
        raise GateError(f"unsafe queue_id: {queue_id!r}")

    expected_execution = {
        "block_order",
        "unit_name",
        "scientific_unit_pattern",
        "global_lock_name",
        "automatic_restart_allowed",
        "resume_allowed",
        "overwrite_allowed",
        "julia_threads",
        "omp_threads",
        "blas_threads",
        "nice",
        "ionice_class",
    }
    execution = config["execution"]
    if not isinstance(execution, dict) or set(execution) != expected_execution:
        raise GateError("execution fields differ from the registered schema")
    required_execution = {
        "block_order": ["A", "B"],
        "automatic_restart_allowed": False,
        "resume_allowed": False,
        "overwrite_allowed": False,
        "julia_threads": 1,
        "omp_threads": 1,
        "blas_threads": 1,
        "nice": 19,
        "ionice_class": "idle",
    }
    changed = {
        key: {"expected": expected, "found": execution.get(key)}
        for key, expected in required_execution.items()
        if execution.get(key) != expected
    }
    if changed:
        raise GateError(f"execution safety controls changed: {changed}")
    if not re.fullmatch(r"sp-gd-[A-Za-z0-9_.@-]+\.service", str(execution["unit_name"])):
        raise GateError("unit_name must be an explicit sp-gd-*.service name")
    if execution["scientific_unit_pattern"] != "sp-gd-*.service":
        raise GateError("scientific_unit_pattern must remain sp-gd-*.service")
    if execution["global_lock_name"] != "sp-gd-scientific.lock":
        raise GateError("global_lock_name must remain sp-gd-scientific.lock")

    paths = config["paths"]
    if not isinstance(paths, dict) or set(paths) != {"freeze_root", "workdir", "output_root"}:
        raise GateError("paths must contain exactly freeze_root, workdir, and output_root")
    for key, value in paths.items():
        candidate = Path(str(value))
        if not candidate.is_absolute():
            raise GateError(f"paths.{key} must be absolute")

    preflight = config["preflight"]
    if not isinstance(preflight, dict) or set(preflight) != {
        "archived_relative_path",
        "record_sha256",
        "validation_status",
    }:
        raise GateError("preflight fields differ from the registered schema")
    safe_relative(str(preflight["archived_relative_path"]))
    _validate_hash(preflight["record_sha256"], "preflight.record_sha256")
    if preflight["validation_status"] != "pass":
        raise GateError("preflight.validation_status must be pass")

    blocks = config["blocks"]
    if not isinstance(blocks, dict) or tuple(blocks) != BLOCK_ORDER:
        raise GateError("blocks must be declared in exact A, B order")
    block_fields = {
        f"{stage}_{suffix}"
        for stage in STAGE_ORDER
        for suffix in ("output", "command", "gate")
    } | {
        "calibration_timeout_seconds",
        "termination_grace_seconds",
        "budget_safety_factor",
    }
    outputs: set[str] = set()
    for block_id in BLOCK_ORDER:
        block = blocks[block_id]
        if not isinstance(block, dict) or set(block) != block_fields:
            raise GateError(f"Block {block_id} fields differ from the registered schema")
        for stage in STAGE_ORDER:
            output = safe_relative(str(block[f"{stage}_output"]))
            if "/" in output:
                raise GateError(f"Block {block_id} {stage} output must be one directory name")
            if output in outputs:
                raise GateError(f"duplicate result directory name: {output}")
            outputs.add(output)
            _validate_command(block[f"{stage}_command"], f"blocks.{block_id}.{stage}_command")
            validate_endpoint_expectation(
                block[f"{stage}_gate"], f"blocks.{block_id}.{stage}_gate", block_id
            )
        timeout_value = block["calibration_timeout_seconds"]
        if not isinstance(timeout_value, int) or not 180 <= timeout_value <= 86400:
            raise GateError(
                f"Block {block_id} calibration fixed timeout must be 180..86400 seconds"
            )
        if block["termination_grace_seconds"] != 120:
            raise GateError(f"Block {block_id} termination grace must remain 120 seconds")
        if block["budget_safety_factor"] != 1.5:
            raise GateError(f"Block {block_id} budget safety factor must remain 1.5")

    inventory = config["inventory"]
    if not isinstance(inventory, dict) or set(inventory) != {"immutable_files"}:
        raise GateError("inventory must contain only immutable_files")
    immutable = inventory["immutable_files"]
    if not isinstance(immutable, list) or set(map(str, immutable)) != IMMUTABLE_FILES:
        raise GateError("immutable inventory differs from the registered file set")
    telemetry = config["telemetry"]
    if not isinstance(telemetry, dict) or set(telemetry) != {"files"}:
        raise GateError("telemetry must contain only files")
    if not isinstance(telemetry["files"], list) or set(map(str, telemetry["files"])) != BASE_TELEMETRY:
        raise GateError("telemetry inventory differs from the registered mutable set")
    return config


def verify_freeze(freeze_root: Path) -> dict[str, Any]:
    freeze_root = freeze_root.resolve()
    if not freeze_root.is_dir() or freeze_root.is_symlink():
        raise GateError(f"freeze is missing or indirect: {freeze_root}")
    listed = parse_checksum_manifest(freeze_root / "MANIFEST.sha256")
    actual = set(iter_files(freeze_root)) - {"MANIFEST.sha256"}
    if actual != set(listed):
        raise GateError(
            f"freeze inventory mismatch: extra={sorted(actual-set(listed))}, "
            f"missing={sorted(set(listed)-actual)}"
        )
    for relative, expected in listed.items():
        target = freeze_root / relative
        if sha256_file(target) != expected:
            raise GateError(f"freeze checksum mismatch: {relative}")
    manifest_path = freeze_root / "freeze_manifest.toml"
    manifest = load_toml(manifest_path)
    if manifest.get("schema_version") != FREEZE_SCHEMA or manifest.get("experiment_id") != EXPERIMENT_ID:
        raise GateError("freeze manifest schema or experiment ID mismatch")
    if manifest.get("file_count") != len(listed) - 1:
        raise GateError("freeze manifest file_count mismatch")
    return {
        "freeze_root": str(freeze_root),
        "manifest_sha256": sha256_file(freeze_root / "MANIFEST.sha256"),
        "file_count": len(listed),
    }


def verify_preflight(config: Mapping[str, Any]) -> dict[str, Any]:
    freeze = Path(config["paths"]["freeze_root"]).resolve()
    registration = config["preflight"]
    relative = safe_relative(str(registration["archived_relative_path"]))
    path = (freeze / relative).resolve()
    try:
        path.relative_to(freeze)
    except ValueError as error:
        raise GateError("preflight record escapes the frozen source root") from error
    if not path.is_file() or path.is_symlink():
        raise GateError(f"frozen preflight record is missing or indirect: {path}")
    actual_hash = sha256_file(path)
    if actual_hash != registration["record_sha256"]:
        raise GateError("frozen preflight record hash differs from queue registration")
    record = load_toml(path)
    required = {
        "schema_version": PREFLIGHT_SCHEMA,
        "experiment_id": EXPERIMENT_ID,
        "validation_status": "pass",
        "block_a_tests_passed": True,
        "block_b_tests_passed": True,
        "command_contract_reviewed": True,
        "endpoint_gate_contract_reviewed": True,
    }
    if set(record) != set(required):
        raise GateError("frozen preflight record fields differ from the registered schema")
    failures = {
        key: {"expected": expected, "found": record.get(key)}
        for key, expected in required.items()
        if record.get(key) != expected
    }
    if failures:
        raise GateError(f"frozen preflight did not pass: {failures}")
    return {"path": str(path), "sha256": actual_hash, "validation_status": "pass"}


def _telemetry_allowed() -> set[str]:
    allowed = set(BASE_TELEMETRY)
    for block in BLOCK_ORDER:
        for stage in ("fresh_anchor", "fresh_transfer", "attribution"):
            allowed.add(f"budgets/{block}_{stage}.toml")
        for stage in STAGE_ORDER:
            job = f"{block}_{stage}"
            allowed.add(f"logs/{job}.log")
            for marker in ("STARTED.toml", "COMPLETED.toml", "FAILED.toml"):
                allowed.add(f"jobs/{job}/{marker}")
    return allowed


def verify_queue_package(queue_root: Path) -> dict[str, Any]:
    queue_root = queue_root.resolve()
    listed = parse_checksum_manifest(queue_root / MANIFEST_NAME)
    if set(listed) != IMMUTABLE_FILES:
        raise GateError("queue manifest differs from the immutable file set")
    for relative, expected in listed.items():
        target = queue_root / relative
        if not target.is_file() or target.is_symlink() or sha256_file(target) != expected:
            raise GateError(f"queue checksum mismatch: {relative}")
    config = queue_config(queue_root)
    lock_path = queue_root / LOCK_NAME
    if not lock_path.is_file() or lock_path.is_symlink():
        raise GateError(f"missing queue package lock: {lock_path}")
    lock = load_toml(lock_path)
    expected_lock = {
        "schema_version": LOCK_SCHEMA,
        "experiment_id": EXPERIMENT_ID,
        "queue_id": config["queue_id"],
        "queue_manifest_sha256": sha256_file(queue_root / MANIFEST_NAME),
        "locked_file_count": len(listed),
    }
    for key, expected in expected_lock.items():
        if lock.get(key) != expected:
            raise GateError(f"queue package lock mismatch for {key}")
    actual = set(iter_files(queue_root))
    allowed = IMMUTABLE_FILES | {MANIFEST_NAME, LOCK_NAME} | _telemetry_allowed()
    if actual - allowed:
        raise GateError(f"queue contains unregistered files: {sorted(actual-allowed)}")
    freeze = Path(config["paths"]["freeze_root"])
    freeze_status = verify_freeze(freeze)
    preflight_status = verify_preflight(config)
    return {
        "queue_root": str(queue_root),
        "queue_id": config["queue_id"],
        "manifest_sha256": sha256_file(queue_root / MANIFEST_NAME),
        "freeze": freeze_status,
        "preflight": preflight_status,
    }


def lock_queue_package(queue_root: Path) -> dict[str, Any]:
    queue_root = queue_root.resolve()
    if (queue_root / MANIFEST_NAME).exists() or (queue_root / LOCK_NAME).exists():
        raise GateError("queue package is already or partially locked")
    config = queue_config(queue_root)
    present = set(iter_files(queue_root))
    if present != IMMUTABLE_FILES:
        raise GateError(
            f"pre-lock inventory is not exact: extra={sorted(present-IMMUTABLE_FILES)}, "
            f"missing={sorted(IMMUTABLE_FILES-present)}"
        )
    verify_freeze(Path(config["paths"]["freeze_root"]))
    for script_name in ("run_queue.sh", "launch_detached.sh"):
        if not (queue_root / script_name).stat().st_mode & stat.S_IXUSR:
            raise GateError(f"{script_name} is not executable")
    text = "".join(
        f"{sha256_file(queue_root / relative)}  {relative}\n"
        for relative in sorted(IMMUTABLE_FILES)
    )
    exclusive_write(queue_root / MANIFEST_NAME, text)
    try:
        exclusive_write(
            queue_root / LOCK_NAME,
            render_toml(
                {
                    "schema_version": LOCK_SCHEMA,
                    "experiment_id": EXPERIMENT_ID,
                    "queue_id": config["queue_id"],
                    "queue_manifest_sha256": sha256_file(queue_root / MANIFEST_NAME),
                    "locked_file_count": len(IMMUTABLE_FILES),
                    "locked_utc": utc_now(),
                }
            ),
        )
        return verify_queue_package(queue_root)
    except Exception:
        (queue_root / LOCK_NAME).unlink(missing_ok=True)
        (queue_root / MANIFEST_NAME).unlink(missing_ok=True)
        raise


def output_path(config: Mapping[str, Any], block: str, stage: str) -> Path:
    name = config["blocks"][block][f"{stage}_output"]
    return (Path(config["paths"]["output_root"]) / name).resolve()


def assert_fresh(queue_root: Path) -> None:
    verify_queue_package(queue_root)
    config = queue_config(queue_root)
    telemetry = set(iter_files(queue_root)) - IMMUTABLE_FILES - {MANIFEST_NAME, LOCK_NAME}
    if telemetry:
        raise GateError(f"prior queue telemetry forbids restart: {sorted(telemetry)}")
    existing = [
        str(output_path(config, block, stage))
        for block in BLOCK_ORDER
        for stage in STAGE_ORDER
        if output_path(config, block, stage).exists()
    ]
    if existing:
        raise GateError(f"refusing to resume or overwrite result paths: {existing}")


def active_scientific_units(pattern: str) -> list[str]:
    completed = subprocess.run(
        [
            "systemctl",
            "--user",
            "list-units",
            "--type=service",
            "--state=active,activating,reloading",
            "--no-legend",
            "--plain",
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        raise GateError(
            "cannot verify user scientific units: " + completed.stderr.strip()
        )
    units = []
    for row in completed.stdout.splitlines():
        fields = row.split()
        if fields and fnmatch.fnmatch(fields[0], pattern):
            units.append(fields[0])
    return sorted(set(units))


def assert_no_competing_units(config: Mapping[str, Any], allow_own: bool) -> None:
    execution = config["execution"]
    active = active_scientific_units(execution["scientific_unit_pattern"])
    allowed = {execution["unit_name"]} if allow_own else set()
    competitors = [unit for unit in active if unit not in allowed]
    if competitors:
        raise GateError(f"other scientific units are active: {competitors}")


def _manifest_inventory(result: Path) -> dict[str, str]:
    listed = parse_checksum_manifest(result / "MANIFEST.sha256")
    excluded = {"MANIFEST.sha256", "progress.toml", "phase_log.tsv"}
    actual = set(iter_files(result)) - excluded
    if actual != set(listed):
        raise GateError(
            f"result inventory mismatch: extra={sorted(actual-set(listed))}, "
            f"missing={sorted(set(listed)-actual)}"
        )
    for relative, expected in listed.items():
        if sha256_file(result / relative) != expected:
            raise GateError(f"result checksum mismatch: {relative}")
    return listed


def verify_result(
    result: Path,
    block: str,
    stage: str,
    expected_endpoint: Mapping[str, Any],
    reference_endpoint: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    result = result.resolve()
    if not result.is_dir() or result.is_symlink():
        raise GateError(f"missing or indirect result directory: {result}")
    _manifest_inventory(result)
    completion_path = result / "COMPLETED.toml"
    science_path = result / "science.json"
    endpoint_path = result / "endpoint_gate.toml"
    for required in (completion_path, science_path, endpoint_path):
        if not required.is_file() or required.is_symlink():
            raise GateError(f"missing or indirect result artifact: {required}")
    completion = load_toml(completion_path)
    required_completion = {
        "schema_version": COMPLETION_SCHEMA,
        "experiment_id": EXPERIMENT_ID,
        "block": block,
        "stage": runner_stage(stage),
        "status": "complete_valid",
        "correctness_passed": True,
        "deterministic_replay_passed": True,
        "science_sha256": sha256_file(science_path),
        "endpoint_gate_sha256": sha256_file(endpoint_path),
    }
    failures = {
        key: {"expected": expected, "found": completion.get(key)}
        for key, expected in required_completion.items()
        if completion.get(key) != expected
    }
    primary = completion.get("primary_science_sha256")
    replay = completion.get("replay_science_sha256")
    if not HASH_RE.fullmatch(str(primary)) or primary != replay:
        failures["deterministic_replay_hash"] = {
            "expected": "equal concrete primary and replay SHA-256 digests",
            "found": [primary, replay],
        }
    if failures:
        raise GateError(f"invalid {block} {stage} completion: {failures}")

    endpoint = load_toml(endpoint_path)
    required_endpoint = {
        "schema_version": ENDPOINT_SCHEMA,
        "experiment_id": EXPERIMENT_ID,
        "block": block,
        "stage": runner_stage(stage),
        "gate_mode": expected_endpoint["mode"],
        "sentinel_self_consistency_passed": True,
    }
    endpoint_failures = {
        key: {"expected": expected, "found": endpoint.get(key)}
        for key, expected in required_endpoint.items()
        if endpoint.get(key) != expected
    }
    endpoint_fields = A_ENDPOINT_FIELDS if block == "A" else B_ENDPOINT_FIELDS
    digest_fields = {key: endpoint.get(key) for key in sorted(endpoint_fields)}
    canonical_digest = hashlib.sha256(
        json.dumps(
            digest_fields,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
        ).encode("utf-8")
    ).hexdigest()
    digest_contract = {
        "primary_sentinel_sha256": canonical_digest,
        "replay_sentinel_sha256": canonical_digest,
    }
    for key, expected in digest_contract.items():
        if endpoint.get(key) != expected:
            endpoint_failures[key] = {"expected": expected, "found": endpoint.get(key)}
    result_endpoint_fields = set(required_endpoint) | endpoint_fields | set(digest_contract)
    if set(endpoint) != result_endpoint_fields:
        endpoint_failures["field_set"] = {
            "expected": sorted(result_endpoint_fields),
            "found": sorted(endpoint),
        }
    for key, expected in expected_endpoint.items():
        if key == "mode":
            continue
        if endpoint.get(key) != expected:
            endpoint_failures[key] = {"expected": expected, "found": endpoint.get(key)}
    frame_values = {key: endpoint.get(key) for key in FRAME_FIELDS}
    if any(
        not isinstance(value, int) or isinstance(value, bool) or value < 0
        for value in frame_values.values()
    ):
        endpoint_failures["frame_fields"] = {
            "expected": "nonnegative integer frame_first, frame_last, and frame_count",
            "found": frame_values,
        }
        frame_count = -1
    else:
        frame_count = int(frame_values["frame_count"])
        if frame_values["frame_last"] - frame_values["frame_first"] + 1 != frame_count:
            endpoint_failures["frame_range"] = {
                "expected": "frame_last - frame_first + 1 == frame_count",
                "found": frame_values,
            }
    count_fields = (
        ("native_gd_successes", "v4_asbuilt_frozen_successes", "native_bp_successes")
        if block == "A"
        else ("native_bp_successes", "full_direct_successes")
    )
    for key in count_fields:
        value = endpoint.get(key)
        if (
            not isinstance(value, int)
            or isinstance(value, bool)
            or not 0 <= value <= frame_count
        ):
            endpoint_failures[key] = {
                "expected": "integer in [0, frame_count]",
                "found": value,
            }
    hash_fields = endpoint_fields - FRAME_FIELDS - set(count_fields)
    hash_fields.discard("native_bp_full_direct_equal")
    for key in hash_fields:
        if not HASH_RE.fullmatch(str(endpoint.get(key))):
            endpoint_failures[key] = {
                "expected": "lowercase SHA-256",
                "found": endpoint.get(key),
            }
    if block == "B":
        if endpoint.get("native_bp_full_direct_equal") is not True:
            endpoint_failures["native_bp_full_direct_equal"] = {
                "expected": True,
                "found": endpoint.get("native_bp_full_direct_equal"),
            }
        if endpoint.get("full_direct_successes") != endpoint.get("native_bp_successes"):
            endpoint_failures["full_direct_successes"] = {
                "expected": endpoint.get("native_bp_successes"),
                "found": endpoint.get("full_direct_successes"),
            }
        if endpoint.get("full_direct_hard_words_sha256") != endpoint.get(
            "native_bp_hard_words_sha256"
        ):
            endpoint_failures["full_direct_hard_words_sha256"] = {
                "expected": endpoint.get("native_bp_hard_words_sha256"),
                "found": endpoint.get("full_direct_hard_words_sha256"),
            }
        if reference_endpoint is None:
            endpoint_failures["block_a_reference"] = {
                "expected": "valid Block A endpoint for the same stage",
                "found": None,
            }
        else:
            cross_fields = (
                "frame_first",
                "frame_last",
                "frame_count",
                "frame_ids_sha256",
                "channel_llrs_sha256",
                "native_bp_successes",
                "native_bp_hard_words_sha256",
            )
            for key in cross_fields:
                if endpoint.get(key) != reference_endpoint.get(key):
                    endpoint_failures[f"block_a_cross_check.{key}"] = {
                        "expected": reference_endpoint.get(key),
                        "found": endpoint.get(key),
                    }
    if endpoint_failures:
        raise GateError(f"{block} {stage} endpoint gate mismatch: {endpoint_failures}")
    return {
        "result": str(result),
        "block": block,
        "stage": stage,
        "science_sha256": sha256_file(science_path),
        "endpoint_gate_sha256": sha256_file(endpoint_path),
        "primary_replay_sha256": primary,
    }


def _render_command(
    template: list[str], queue_root: Path, config: Mapping[str, Any], block: str, stage: str
) -> list[str]:
    freeze = Path(config["paths"]["freeze_root"]).resolve()
    output = output_path(config, block, stage)
    values = {
        "queue_root": str(queue_root.resolve()),
        "freeze": str(freeze),
        "output": str(output),
        "block": block,
        "stage": stage,
        "runner_stage": runner_stage(stage),
    }
    command = [token.format_map(values) for token in template]
    if any("{" in token or "}" in token for token in command):
        raise GateError(f"unresolved brace in {block} {stage} command")
    frozen_file_referenced = False
    for token in command[1:]:
        candidate = Path(token)
        if candidate.is_absolute():
            try:
                candidate.resolve().relative_to(freeze)
            except ValueError:
                continue
            if candidate.is_file() and not candidate.is_symlink():
                frozen_file_referenced = True
    if not frozen_file_referenced:
        raise GateError(
            f"{block} {stage} command must reference at least one regular frozen file"
        )
    return command


class Telemetry:
    def __init__(self, queue_root: Path) -> None:
        self.root = queue_root
        self.completed = 0
        self.total = len(BLOCK_ORDER) * len(STAGE_ORDER)
        self.phase_path = self.root / "phase_log.tsv"
        self.history_path = self.root / "status_history.tsv"
        exclusive_write(
            self.phase_path,
            "utc\tblock\tstage\tphase\tevent\tseconds\n",
        )
        exclusive_write(
            self.history_path,
            "utc\tstate\tblock\tstage\tjobs_completed\tdetail\n",
        )

    def progress(self, state: str, block: str, stage: str, detail: str) -> None:
        fields = {
            "schema_version": "rq2-causal-factors-001/queue-progress-v1",
            "experiment_id": EXPERIMENT_ID,
            "state": state,
            "current_block": block,
            "current_stage": stage,
            "jobs_completed": self.completed,
            "jobs_total": self.total,
            "updated_utc": utc_now(),
            "detail": detail,
        }
        atomic_replace(self.root / "progress.toml", render_toml(fields))
        append_fsync(
            self.history_path,
            f"{fields['updated_utc']}\t{state}\t{block}\t{stage}\t"
            f"{self.completed}\t{detail}\n",
        )

    @contextlib.contextmanager
    def phase(self, block: str, stage: str, phase: str):
        start = time.monotonic()
        append_fsync(
            self.phase_path,
            f"{utc_now()}\t{block}\t{stage}\t{phase}\tstart\t0.000000\n",
        )
        try:
            yield
        except BaseException:
            elapsed = time.monotonic() - start
            append_fsync(
                self.phase_path,
                f"{utc_now()}\t{block}\t{stage}\t{phase}\terror\t{elapsed:.6f}\n",
            )
            raise
        else:
            elapsed = time.monotonic() - start
            append_fsync(
                self.phase_path,
                f"{utc_now()}\t{block}\t{stage}\t{phase}\tend\t{elapsed:.6f}\n",
            )


def _job_marker(queue_root: Path, block: str, stage: str, state: str, detail: str) -> None:
    job = f"{block}_{stage}"
    name = {"started": "STARTED.toml", "complete": "COMPLETED.toml", "failed": "FAILED.toml"}[state]
    exclusive_write(
        queue_root / "jobs" / job / name,
        render_toml(
            {
                "schema_version": "rq2-causal-factors-001/queue-job-v1",
                "experiment_id": EXPERIMENT_ID,
                "block": block,
                "stage": stage,
                "state": state,
                "recorded_utc": utc_now(),
                "detail": detail,
            }
        ),
    )


def _run_job(
    queue_root: Path,
    config: Mapping[str, Any],
    telemetry: Telemetry,
    block: str,
    stage: str,
    timeout_seconds: int,
) -> None:
    block_config = config["blocks"][block]
    result = output_path(config, block, stage)
    if result.exists():
        raise GateError(f"refusing to overwrite result: {result}")
    command = _render_command(
        block_config[f"{stage}_command"], queue_root, config, block, stage
    )
    log_path = queue_root / "logs" / f"{block}_{stage}.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    _job_marker(queue_root, block, stage, "started", "scientific command starting")
    telemetry.progress("running", block, stage, "scientific command running")
    environment = os.environ.copy()
    for variable in (
        "JULIA_NUM_THREADS",
        "OMP_NUM_THREADS",
        "OPENBLAS_NUM_THREADS",
        "MKL_NUM_THREADS",
        "BLIS_NUM_THREADS",
        "VECLIB_MAXIMUM_THREADS",
    ):
        environment[variable] = "1"
    grace = block_config["termination_grace_seconds"]
    if not isinstance(timeout_seconds, int) or timeout_seconds <= grace:
        raise GateError(f"invalid {block} {stage} wall budget: {timeout_seconds}")
    term_after = timeout_seconds - grace
    prefixed = [
        "timeout",
        "--signal=TERM",
        f"--kill-after={grace}s",
        f"{term_after}s",
        "nice",
        "-n",
        "19",
        "ionice",
        "-c",
        "3",
        *command,
    ]
    try:
        with telemetry.phase(block, stage, "scientific_command"):
            with log_path.open("x", encoding="utf-8", newline="") as log:
                completed = subprocess.run(
                    prefixed,
                    cwd=config["paths"]["workdir"],
                    env=environment,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    timeout=timeout_seconds + 10,
                    check=False,
                    text=True,
                )
                log.flush()
                os.fsync(log.fileno())
            if completed.returncode != 0:
                raise GateError(
                    f"{block} {stage} command exited {completed.returncode}; see {log_path}"
                )
        with telemetry.phase(block, stage, "result_and_endpoint_gate"):
            reference_endpoint = None
            if block == "B":
                block_a_result = output_path(config, "A", stage)
                verify_result(
                    block_a_result,
                    "A",
                    stage,
                    config["blocks"]["A"][f"{stage}_gate"],
                )
                reference_endpoint = load_toml(
                    block_a_result / "endpoint_gate.toml"
                )
            verify_result(
                result,
                block,
                stage,
                block_config[f"{stage}_gate"],
                reference_endpoint,
            )
        _job_marker(queue_root, block, stage, "complete", "complete-valid registered gate")
        telemetry.completed += 1
        telemetry.progress("running", block, stage, "complete-valid registered gate")
    except BaseException as error:
        _job_marker(queue_root, block, stage, "failed", str(error))
        raise


def derive_stage_budget(
    queue_root: Path,
    config: Mapping[str, Any],
    block: str,
    source_stage: str,
    target_stage: str,
) -> dict[str, Any]:
    allowed = {
        ("calibration", "fresh_anchor"),
        ("fresh_anchor", "fresh_transfer"),
        ("fresh_anchor", "attribution"),
    }
    if (source_stage, target_stage) not in allowed:
        raise GateError(
            f"cannot derive a budget from {source_stage} to {target_stage}"
        )
    source_result = output_path(config, block, source_stage)
    timing_path = source_result / "timing.toml"
    if not timing_path.is_file() or timing_path.is_symlink():
        raise GateError(f"{source_stage} lacks checksum-bound timing: {timing_path}")
    timing = load_toml(timing_path)
    expected_timing_fields = {
        "schema_version",
        "experiment_id",
        "block",
        "stage",
        "frame_count",
        "pass_count",
        "scientific_frame_loop_seconds",
        "post_loop_seconds",
    }
    if set(timing) != expected_timing_fields:
        raise GateError(f"{source_stage} timing fields differ from the registered schema")
    required = {
        "schema_version": TIMING_SCHEMA,
        "experiment_id": EXPERIMENT_ID,
        "block": block,
        "stage": runner_stage(source_stage),
        "frame_count": config["blocks"][block][f"{source_stage}_gate"]["frame_count"],
    }
    failures = {
        key: {"expected": expected, "found": timing.get(key)}
        for key, expected in required.items()
        if timing.get(key) != expected
    }
    pass_count = timing.get("pass_count")
    frame_seconds = timing.get("scientific_frame_loop_seconds")
    post_seconds = timing.get("post_loop_seconds")
    if not isinstance(pass_count, int) or isinstance(pass_count, bool) or pass_count < 2:
        failures["pass_count"] = {"expected": "integer >= 2", "found": pass_count}
    for key, value in (
        ("scientific_frame_loop_seconds", frame_seconds),
        ("post_loop_seconds", post_seconds),
    ):
        if (
            not isinstance(value, (int, float))
            or isinstance(value, bool)
            or not math.isfinite(value)
            or value <= 0
        ):
            failures[key] = {"expected": "finite positive seconds", "found": value}
    if failures:
        raise GateError(f"invalid {source_stage} timing: {failures}")
    frame_count = int(timing["frame_count"])
    seconds_per_frame_per_pass = float(frame_seconds) / (frame_count * int(pass_count))
    target_frames = config["blocks"][block][f"{target_stage}_gate"]["frame_count"]
    projected_frame_seconds = seconds_per_frame_per_pass * target_frames * int(pass_count)
    projected_science_seconds = projected_frame_seconds + float(post_seconds)
    safety_factor = float(config["blocks"][block]["budget_safety_factor"])
    term_after = math.ceil(projected_science_seconds * safety_factor)
    grace = int(config["blocks"][block]["termination_grace_seconds"])
    if term_after <= 0:
        raise GateError(
            "measured derived scientific timeout is not positive; "
            "retain this anchor and register a new measurement attempt"
        )
    wall_budget = term_after + grace
    budget_path = queue_root / "budgets" / f"{block}_{target_stage}.toml"
    fields: dict[str, object] = {
        "schema_version": BUDGET_SCHEMA,
        "experiment_id": EXPERIMENT_ID,
        "block": block,
        "source_stage": source_stage,
        "target_stage": target_stage,
        "formula": "term_after_seconds = ceil((seconds_per_frame_per_pass * target_frames * pass_count + post_loop_seconds) * safety_factor); wall_budget_seconds = term_after_seconds + termination_grace_seconds",
        "anchor_timing_sha256": sha256_file(timing_path),
        "anchor_frame_count": frame_count,
        "pass_count": int(pass_count),
        "scientific_frame_loop_seconds": float(frame_seconds),
        "seconds_per_frame_per_pass": seconds_per_frame_per_pass,
        "target_frames": target_frames,
        "projected_frame_seconds": projected_frame_seconds,
        "post_loop_seconds": float(post_seconds),
        "projected_science_seconds": projected_science_seconds,
        "safety_factor": safety_factor,
        "wall_budget_seconds": wall_budget,
        "termination_grace_seconds": grace,
        "term_after_seconds": term_after,
        "recorded_utc": utc_now(),
    }
    exclusive_write(budget_path, render_toml(fields))
    return dict(fields)


def run_campaign(queue_root: Path, *, check_units: bool = True) -> dict[str, Any]:
    queue_root = queue_root.resolve()
    verify_queue_package(queue_root)
    config = queue_config(queue_root)
    # run_queue.sh creates only these two append-only/lock files before entry.
    present = set(iter_files(queue_root)) - IMMUTABLE_FILES - {MANIFEST_NAME, LOCK_NAME}
    if present - {"queue.lock", "queue.log"}:
        raise GateError(f"prior queue state forbids restart: {sorted(present)}")
    for block in BLOCK_ORDER:
        for stage in STAGE_ORDER:
            if output_path(config, block, stage).exists():
                raise GateError("scientific output exists before campaign start")
    if check_units:
        assert_no_competing_units(config, allow_own=True)
    Path(config["paths"]["output_root"]).mkdir(parents=True, exist_ok=True)
    telemetry = Telemetry(queue_root)
    telemetry.progress("running", "", "", "campaign initialized")
    try:
        with telemetry.phase("", "", "campaign"):
            for block in BLOCK_ORDER:
                block_config = config["blocks"][block]
                _run_job(
                    queue_root,
                    config,
                    telemetry,
                    block,
                    "calibration",
                    block_config["calibration_timeout_seconds"],
                )
                telemetry.progress("running", block, "budget", "deriving measured fresh-anchor budget")
                with telemetry.phase(block, "budget", "derive_fresh_anchor_budget"):
                    anchor_budget = derive_stage_budget(
                        queue_root, config, block, "calibration", "fresh_anchor"
                    )
                _run_job(
                    queue_root,
                    config,
                    telemetry,
                    block,
                    "fresh_anchor",
                    int(anchor_budget["wall_budget_seconds"]),
                )
                telemetry.progress("running", block, "budget", "deriving measured 200-frame budgets")
                with telemetry.phase(block, "budget", "derive_measured_budgets"):
                    transfer_budget = derive_stage_budget(
                        queue_root, config, block, "fresh_anchor", "fresh_transfer"
                    )
                    attribution_budget = derive_stage_budget(
                        queue_root, config, block, "fresh_anchor", "attribution"
                    )
                # The prospective 200-frame transfer is reachable only after
                # the fresh anchor's correctness, replay, and sentinel
                # self-consistency gates pass. Its outcomes are not expected.
                _run_job(
                    queue_root,
                    config,
                    telemetry,
                    block,
                    "fresh_transfer",
                    int(transfer_budget["wall_budget_seconds"]),
                )
                # Attribution is deliberately last because its informed cases
                # and endpoint counts are already informed by prior work.
                _run_job(
                    queue_root,
                    config,
                    telemetry,
                    block,
                    "attribution",
                    int(attribution_budget["wall_budget_seconds"]),
                )
        telemetry.progress("complete", "", "", "Block A then Block B complete-valid")
        exclusive_write(
            queue_root / "QUEUE_COMPLETED.toml",
            render_toml(
                {
                    "schema_version": "rq2-causal-factors-001/queue-terminal-v1",
                    "experiment_id": EXPERIMENT_ID,
                    "state": "complete",
                    "jobs_completed": telemetry.completed,
                    "recorded_utc": utc_now(),
                }
            ),
        )
    except BaseException as error:
        telemetry.progress("failed", "", "", str(error))
        exclusive_write(
            queue_root / "QUEUE_FAILED.toml",
            render_toml(
                {
                    "schema_version": "rq2-causal-factors-001/queue-terminal-v1",
                    "experiment_id": EXPERIMENT_ID,
                    "state": "failed",
                    "jobs_completed": telemetry.completed,
                    "recorded_utc": utc_now(),
                    "detail": str(error),
                }
            ),
        )
        raise
    return {
        "queue_root": str(queue_root),
        "state": "complete",
        "jobs_completed": telemetry.completed,
    }


def prelaunch(queue_root: Path) -> dict[str, Any]:
    assert_fresh(queue_root)
    config = queue_config(queue_root)
    assert_no_competing_units(config, allow_own=False)
    return {
        "queue_root": str(queue_root.resolve()),
        "unit_name": config["execution"]["unit_name"],
        "state": "ready",
    }


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("verify", "assert-fresh", "prelaunch", "run", "unit-name"):
        subparser = subparsers.add_parser(name)
        subparser.add_argument("--queue-root", required=True, type=Path)
    args = parser.parse_args(arguments)
    if args.command == "verify":
        result = verify_queue_package(args.queue_root)
    elif args.command == "assert-fresh":
        assert_fresh(args.queue_root)
        result = {"state": "fresh"}
    elif args.command == "prelaunch":
        result = prelaunch(args.queue_root)
    elif args.command == "run":
        result = run_campaign(args.queue_root)
    else:
        config = queue_config(args.queue_root.resolve())
        print(config["execution"]["unit_name"])
        return 0
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (GateError, OSError, KeyError, ValueError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
