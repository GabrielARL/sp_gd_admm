#!/usr/bin/env python3
"""Durable queue status, gates, and final-summary helpers.

This helper never runs a scientific calculation.  In particular, the
``assert-result`` command verifies the embedded deterministic-replay record;
it does not invoke the experiment runner's replay mode and therefore preserves
the registered two-pass work budget.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Iterable

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # Python 3.10 on the registered machine
    import tomli as tomllib  # type: ignore[no-redef]


QUEUE_ROOT = Path(__file__).resolve().parent
QUEUE_CONFIG = QUEUE_ROOT / "queue.toml"
QUEUE_SCHEMA = "rq2-gd-offset-split-001/queue-progress-v3"
EXPERIMENT_ID = "RQ2-GD-OFFSET-SPLIT-001"


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def parse_utc_timestamp(value: str) -> dt.datetime:
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    parsed = dt.datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def load_toml(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        return tomllib.load(handle)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def toml_quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def toml_text(flat: dict[str, Any]) -> str:
    lines: list[str] = []
    for key in sorted(flat):
        value = flat[key]
        if isinstance(value, bool):
            rendered = "true" if value else "false"
        elif isinstance(value, int):
            rendered = str(value)
        elif isinstance(value, float):
            rendered = repr(value)
        else:
            rendered = toml_quote(str(value))
        lines.append(f"{key} = {rendered}")
    return "\n".join(lines) + "\n"


def atomic_write(path: Path, text: str) -> None:
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
        if temporary.exists():
            temporary.unlink()


def append_history(path: Path, row: list[Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    new_file = not path.exists()
    output: list[str] = []
    if new_file:
        output.append(
            "updated_utc,queue_state,job_id,job_state,jobs_completed,"
            "jobs_total,exit_code,detail\n"
        )
    from io import StringIO

    buffer = StringIO()
    csv.writer(buffer, lineterminator="\n").writerow(row)
    output.append(buffer.getvalue())
    encoded = "".join(output).encode("utf-8")
    descriptor = os.open(path, os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o644)
    try:
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("short write while appending queue status history")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def queue_config(queue_root: Path) -> dict[str, Any]:
    return load_toml(queue_root / "queue.toml")


def repo_path(config: dict[str, Any], key: str) -> Path:
    root = Path(config["paths"]["repository_root"])
    candidate = Path(config["paths"][key])
    return candidate if candidate.is_absolute() else root / candidate


def queue_file(config: dict[str, Any], queue_root: Path, key: str) -> Path:
    candidate = Path(config["paths"][key])
    return candidate if candidate.is_absolute() else queue_root / candidate


def update_queue(args: argparse.Namespace) -> int:
    queue_root = Path(args.queue_root).resolve()
    config = queue_config(queue_root)
    progress_path = queue_file(config, queue_root, "queue_progress")
    existing: dict[str, Any] = {}
    if progress_path.is_file():
        existing = load_toml(progress_path)
    now = utc_now()
    started = existing.get("started_utc", args.started_utc or now)
    payload: dict[str, Any] = {
        "schema_version": QUEUE_SCHEMA,
        "queue_id": config["queue_id"],
        "experiment_id": config["experiment_id"],
        "state": args.state,
        "current_job": args.job_id,
        "current_job_state": args.job_state,
        "jobs_completed": args.completed,
        "jobs_total": int(config["job_count"]),
        "process_id": os.getppid(),
        "started_utc": started,
        "updated_utc": now,
        "exit_code": args.exit_code,
        "detail": args.detail,
    }
    atomic_write(progress_path, toml_text(payload))
    append_history(
        queue_file(config, queue_root, "status_history"),
        [
            now,
            args.state,
            args.job_id,
            args.job_state,
            args.completed,
            int(config["job_count"]),
            args.exit_code,
            args.detail,
        ],
    )
    print(
        f"{now} queue={args.state} job={args.job_id or '-'} "
        f"job_state={args.job_state} completed={args.completed}/{config['job_count']} "
        f"detail={args.detail}"
    )
    return 0


def write_marker(args: argparse.Namespace) -> int:
    queue_root = Path(args.queue_root).resolve()
    state = args.state.lower()
    marker_name = {
        "started": "STARTED.toml",
        "complete": "COMPLETED.toml",
        "failed": "FAILED.toml",
    }[state]
    marker = queue_root / "jobs" / args.job_id / marker_name
    job_root = marker.parent
    existing = {
        name for name in ("STARTED.toml", "COMPLETED.toml", "FAILED.toml")
        if (job_root / name).exists()
    }
    if state == "started" and existing:
        raise RuntimeError(
            f"refusing to start {args.job_id}; markers already exist: {sorted(existing)}"
        )
    if state in {"complete", "failed"}:
        opposite = "FAILED.toml" if state == "complete" else "COMPLETED.toml"
        if (job_root / opposite).exists():
            raise RuntimeError(
                f"refusing conflicting terminal marker for {args.job_id}: {opposite}"
            )
    payload = {
        "schema_version": "rq2-gd-offset-split-001/queue-job-v3",
        "queue_id": queue_config(queue_root)["queue_id"],
        "job_id": args.job_id,
        "state": state,
        "recorded_utc": utc_now(),
        "exit_code": args.exit_code,
        "detail": args.detail,
    }
    if marker.exists():
        raise RuntimeError(f"refusing to overwrite job marker: {marker}")
    atomic_write(marker, toml_text(payload))
    return 0


def write_queue_terminal(args: argparse.Namespace) -> int:
    queue_root = Path(args.queue_root).resolve()
    marker = queue_root / (
        "QUEUE_COMPLETED.toml" if args.state == "complete" else "QUEUE_FAILED.toml"
    )
    opposite = queue_root / (
        "QUEUE_FAILED.toml" if args.state == "complete" else "QUEUE_COMPLETED.toml"
    )
    if opposite.exists():
        raise RuntimeError(f"refusing conflicting queue terminal marker: {opposite}")
    if marker.exists():
        raise RuntimeError(f"refusing to overwrite queue terminal marker: {marker}")
    payload = {
        "schema_version": "rq2-gd-offset-split-001/queue-terminal-v3",
        "queue_id": queue_config(queue_root)["queue_id"],
        "experiment_id": EXPERIMENT_ID,
        "state": args.state,
        "recorded_utc": utc_now(),
        "exit_code": args.exit_code,
        "detail": args.detail,
    }
    atomic_write(marker, toml_text(payload))
    return 0


def parse_preflight_fields(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    pattern = re.compile(r"^([a-z][a-z0-9_]*)\s*:\s*`?([^`\s]+)`?\s*$")
    for line in path.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if match:
            fields[match.group(1)] = match.group(2)
    return fields


def assert_preflight(args: argparse.Namespace) -> int:
    queue_root = Path(args.queue_root).resolve()
    config = queue_config(queue_root)
    paths = {
        "config_sha256": repo_path(config, "config"),
        "card_sha256": repo_path(config, "experiment_root") / "experiment_card.md",
        "runner_sha256": repo_path(config, "runner"),
        "test_sha256": repo_path(config, "test"),
        "legacy_runner_sha256": repo_path(config, "legacy_runner"),
    }
    preflight = repo_path(config, "preflight")
    fields = parse_preflight_fields(preflight)
    expected = {
        "validation_status": "pass",
        "test_exit_code": "0",
        "prior_result_locks_passed": "true",
        "prohibited_call_audit_passed": "true",
        "registered_endpoint_frames_executed_during_preflight": "0",
        **{key: sha256_file(path) for key, path in paths.items()},
    }
    failures = [
        f"{key}: expected {value}, found {fields.get(key, 'missing')}"
        for key, value in expected.items()
        if fields.get(key) != value
    ]
    try:
        passed = int(fields["test_assertions_passed"])
        total = int(fields["test_assertions_total"])
        if passed <= 0 or passed != total:
            failures.append(
                f"test assertions: expected positive equal counts, found {passed}/{total}"
            )
    except (KeyError, ValueError):
        failures.append("test assertion counts are missing or malformed")
    if failures:
        raise RuntimeError("locked preflight validation failed: " + "; ".join(failures))
    print(f"locked preflight validation passed: {passed}/{total} assertions")
    return 0


def assert_optimization(args: argparse.Namespace) -> int:
    """Verify the isolated same-science v3 source successor and v2 locks."""

    queue_root = Path(args.queue_root).resolve()
    config = queue_config(queue_root)
    registered = config["optimization"]
    experiment = load_toml(repo_path(config, "config"))
    optimization = experiment["optimization"]

    old_legacy = repo_path(config, "predecessor_legacy_runner")
    new_legacy = repo_path(config, "legacy_runner")
    rejected = repo_path(config, "rejected_anchor_attempt")
    runtime_rejected = repo_path(config, "runtime_rejected_anchor_attempt")
    old_hash_line = (
        "scientific_sha256(value) = "
        "bytes2hex(sha256(codeunits(canonical_json(value))))"
    )
    new_hash_lines = (
        "scientific_sha256(value) = bytes2hex(sha256(\n"
        "    Vector{UInt8}(codeunits(canonical_json(value)))))"
    )
    expected_new_legacy = old_legacy.read_text(encoding="utf-8").replace(
        old_hash_line, new_hash_lines
    )
    checks = {
        "optimization_id": optimization.get("optimization_id")
        == "RQ2-OPTIMIZE-001",
        "queue_optimization_id": registered.get("optimization_id")
        == "RQ2-OPTIMIZE-001",
        "heldout_unit": config.get("heldout_queue_unit")
        == "sp-gd-rq2-offset-split-v3-20261031.service",
        "queue_never_signals_v2": config.get("queue_never_signals_predecessor")
        is True,
        "anchor_wrapper_budget": config.get("anchor_wrapper_wall_budget_seconds")
        == optimization.get("anchor_wrapper_wall_budget_seconds")
        == experiment["work_budget"]["anchor_wall_budget_seconds"]
        == 3600,
        "anchor_wrapper_term": config.get("anchor_wrapper_term_after_seconds")
        == optimization.get("anchor_wrapper_term_after_seconds")
        == 3480,
        "anchor_wrapper_script": "timeout --signal=TERM --kill-after=120s 3480s"
        in (queue_root / "run_anchor_once.sh").read_text(encoding="utf-8"),
        "predecessor_config": sha256_file(repo_path(config, "predecessor_config"))
        == registered["predecessor_config_sha256"],
        "predecessor_card": sha256_file(repo_path(config, "predecessor_card"))
        == registered["predecessor_card_sha256"],
        "predecessor_preflight": sha256_file(
            repo_path(config, "predecessor_preflight")
        )
        == registered["predecessor_preflight_sha256"],
        "predecessor_split_runner": sha256_file(
            repo_path(config, "predecessor_split_runner")
        )
        == registered["predecessor_split_runner_sha256"],
        "predecessor_test": sha256_file(repo_path(config, "predecessor_test"))
        == registered["predecessor_test_sha256"],
        "predecessor_legacy_runner": sha256_file(old_legacy)
        == registered["predecessor_legacy_runner_sha256"],
        "optimized_config": sha256_file(repo_path(config, "config"))
        == registered["optimized_config_sha256"],
        "optimized_card": sha256_file(
            repo_path(config, "experiment_root") / "experiment_card.md"
        )
        == registered["optimized_card_sha256"],
        "optimized_preflight": sha256_file(repo_path(config, "preflight"))
        == registered["optimized_preflight_sha256"],
        "optimized_split_runner": sha256_file(repo_path(config, "runner"))
        == optimization["optimized_split_runner_sha256"]
        == registered["optimized_split_runner_sha256"],
        "optimized_test": sha256_file(repo_path(config, "test"))
        == optimization["optimized_test_sha256"]
        == registered["optimized_test_sha256"],
        "optimized_legacy_runner": sha256_file(new_legacy)
        == optimization["optimized_legacy_runner_sha256"]
        == registered["optimized_legacy_runner_sha256"],
        "frozen_input_identity": optimization["predecessor_input_freeze_sha256"]
        == registered["predecessor_input_freeze_sha256"]
        == "739da19436f5f3371333ad04585be4c9cd934506c9a66892776b146105b5a5bd",
        "anchor_file_hash_target": optimization[
            "required_anchor_science_file_sha256"
        ]
        == registered["required_anchor_science_sha256"]
        == "2062fce292d4b41cf93c6dd86afdb6855345b52ff1408d9c89c7318e25b20d46",
        "anchor_base_hash_target": optimization[
            "required_anchor_base_scientific_sha256"
        ]
        == registered["required_anchor_base_scientific_sha256"]
        == "dfe9082912a6108fabae39f7db0e1749c7f097bc310d0cd5b63109cf327148d0",
        "only_legacy_scientific_change": new_legacy.read_text(encoding="utf-8")
        == expected_new_legacy,
        "same_hash_bytes_declared": optimization.get("scientific_change", "").startswith(
            "none; hash the same canonical UTF-8 bytes"
        ),
        "v2_partial_not_reused": optimization.get("reuse_v2_partial_progress")
        is False,
        "rejected_partial_not_reused": registered.get(
            "rejected_precompletion_attempt_reused"
        )
        is False,
        "rejected_exact_files": rejected.is_dir()
        and {
            path.relative_to(rejected).as_posix()
            for path in rejected.rglob("*")
            if path.is_file()
        }
        == {"REJECTED.toml", "phase_log.tsv", "progress.toml"},
        "rejected_record": sha256_file(rejected / "REJECTED.toml")
        == registered["rejected_record_sha256"],
        "rejected_progress": sha256_file(rejected / "progress.toml")
        == registered["rejected_progress_sha256"],
        "rejected_phase_log": sha256_file(rejected / "phase_log.tsv")
        == registered["rejected_phase_log_sha256"],
        "rejected_has_no_science": not any(
            (rejected / name).exists()
            for name in (
                "science.json",
                "frames.csv",
                "iterations.csv",
                "primary_checkpoint",
                "COMPLETED.toml",
                "MANIFEST.sha256",
            )
        ),
        "runtime_rejected_partial_not_reused": registered.get(
            "runtime_rejected_precompletion_attempt_reused"
        )
        is False,
        "runtime_rejected_exact_files": runtime_rejected.is_dir()
        and {
            path.relative_to(runtime_rejected).as_posix()
            for path in runtime_rejected.rglob("*")
            if path.is_file()
        }
        == {"REJECTED.toml", "phase_log.tsv", "progress.toml"},
        "runtime_rejected_record": sha256_file(
            runtime_rejected / "REJECTED.toml"
        )
        == registered["runtime_rejected_record_sha256"],
        "runtime_rejected_progress": sha256_file(
            runtime_rejected / "progress.toml"
        )
        == registered["runtime_rejected_progress_sha256"],
        "runtime_rejected_phase_log": sha256_file(
            runtime_rejected / "phase_log.tsv"
        )
        == registered["runtime_rejected_phase_log_sha256"],
        "runtime_rejected_has_no_science": not any(
            (runtime_rejected / name).exists()
            for name in (
                "science.json",
                "frames.csv",
                "iterations.csv",
                "primary_checkpoint",
                "COMPLETED.toml",
                "MANIFEST.sha256",
            )
        ),
        "new_freeze_path": optimization.get("successor_freeze")
        == "freeze/2026-10-31_v3",
        "new_anchor_path": optimization.get("successor_anchor_result")
        == "results/2026-10-31_anchor_v3",
        "new_heldout_path": optimization.get("successor_heldout_result")
        == "results/2026-10-31_heldout_v3",
    }
    failed = [key for key, value in checks.items() if not value]
    if failed:
        raise RuntimeError("v3 optimization whitelist failed: " + ", ".join(failed))
    print(
        "v3 optimization whitelist passed: same canonical bytes and digest; "
        "isolated phase/checkpoint instrumentation; v1/v2 retained"
    )
    return 0


def manifest_entries(root: Path, manifest_name: str = "MANIFEST.sha256") -> dict[str, str]:
    path = root / manifest_name
    if not path.is_file():
        raise RuntimeError(f"missing checksum manifest: {path}")
    entries: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        try:
            expected, relative = line.split("  ", 1)
        except ValueError as error:
            raise RuntimeError(f"malformed checksum line: {line}") from error
        if relative in entries:
            raise RuntimeError(f"duplicate checksum entry: {relative}")
        entries[relative] = expected
    return entries


def verify_checksum_tree(
    root: Path, exclusions: Iterable[str], manifest_name: str = "MANIFEST.sha256"
) -> int:
    excluded = set(exclusions)
    entries = manifest_entries(root, manifest_name)
    failures: list[str] = []
    for relative, expected in entries.items():
        path = root / relative
        if not path.is_file():
            failures.append(f"missing:{relative}")
        elif sha256_file(path) != expected:
            failures.append(f"hash:{relative}")
    actual = {
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path.relative_to(root).as_posix() not in excluded
    }
    listed = set(entries)
    failures.extend(f"extra:{name}" for name in sorted(actual - listed))
    failures.extend(f"unresolved:{name}" for name in sorted(listed - actual))
    if failures:
        raise RuntimeError("checksum verification failed: " + ", ".join(failures))
    return len(entries)


def verify_queue_lock(queue_root: Path, require_record: bool = False) -> int:
    manifest_name = "QUEUE_MANIFEST.sha256"
    entries = manifest_entries(queue_root, manifest_name)
    expected_files = {
        "README.md",
        "budget_derivation.toml",
        "derive_budget.py",
        "queue.toml",
        "run_anchor_once.sh",
        "run_queue.sh",
        "status_report.py",
    }
    if set(entries) != expected_files:
        raise RuntimeError(
            "queue lock must contain exactly: " + ", ".join(sorted(expected_files))
        )
    failures = []
    for relative, expected in entries.items():
        path = queue_root / relative
        if not path.is_file():
            failures.append(f"missing:{relative}")
        elif sha256_file(path) != expected:
            failures.append(f"hash:{relative}")
    if failures:
        raise RuntimeError("queue-package lock failed: " + ", ".join(failures))
    config = queue_config(queue_root)
    record_path = queue_file(config, queue_root, "queue_package_record")
    if record_path.exists():
        record = load_toml(record_path)
        record_checks = {
            "schema": record.get("schema_version")
            == "rq2-gd-offset-split-001/queue-package-lock-v3",
            "queue": record.get("queue_id") == config["queue_id"],
            "manifest": record.get("queue_manifest_sha256")
            == sha256_file(queue_root / manifest_name),
            "file_count": record.get("locked_file_count") == len(entries),
        }
        failed_record = [key for key, value in record_checks.items() if not value]
        if failed_record:
            raise RuntimeError(
                "queue-package launch record failed: " + ", ".join(failed_record)
            )
    elif require_record:
        raise RuntimeError(f"queue-package launch record is missing: {record_path}")
    return len(entries)


def lock_queue_package(args: argparse.Namespace) -> int:
    queue_root = Path(args.queue_root).resolve()
    config = queue_config(queue_root)
    count = verify_queue_lock(queue_root)
    record_path = queue_file(config, queue_root, "queue_package_record")
    if record_path.exists():
        raise RuntimeError(f"refusing to overwrite queue-package record: {record_path}")
    payload = {
        "schema_version": "rq2-gd-offset-split-001/queue-package-lock-v3",
        "queue_id": config["queue_id"],
        "experiment_id": EXPERIMENT_ID,
        "locked_utc": utc_now(),
        "queue_manifest_sha256": sha256_file(
            queue_root / "QUEUE_MANIFEST.sha256"
        ),
        "locked_file_count": count,
    }
    atomic_write(record_path, toml_text(payload))
    print(f"locked queue package: {count} files; record={record_path}")
    return 0


def assert_queue_lock(args: argparse.Namespace) -> int:
    count = verify_queue_lock(
        Path(args.queue_root).resolve(), require_record=args.require_record
    )
    print(f"queue-package lock passed: {count} files")
    return 0


def assert_freeze(args: argparse.Namespace) -> int:
    root = Path(args.freeze).resolve()
    entries = verify_checksum_tree(root, {"MANIFEST.sha256"})
    manifest = load_toml(root / "freeze_manifest.toml")
    checks = {
        "experiment_id": manifest.get("experiment_id") == EXPERIMENT_ID,
        "input_row_count": manifest.get("input_row_count") == 224,
        "anchor_row_count": manifest.get("anchor_row_count") == 24,
        "heldout_row_count": manifest.get("heldout_row_count") == 200,
        "source_gate": manifest.get("source_gate", {}).get("passed") is True,
        "preflight_gate": manifest.get("preflight_gate", {}).get("passed") is True,
    }
    failed = [key for key, value in checks.items() if not value]
    if failed:
        raise RuntimeError("freeze gate failed: " + ", ".join(failed))
    with (root / "input_freeze.csv").open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) != 224:
        raise RuntimeError(f"freeze table has {len(rows)} rows, expected 224")
    if args.expected_input_sha256:
        actual_input_sha256 = sha256_file(root / "input_freeze.csv")
        if actual_input_sha256 != args.expected_input_sha256:
            raise RuntimeError(
                "freeze input identity changed: expected "
                f"{args.expected_input_sha256}, found {actual_input_sha256}"
            )
    print(f"freeze verification passed: 224 rows, {entries} checksum entries")
    return 0


def phase_log_gate(root: Path) -> dict[str, float]:
    path = root / "phase_log.tsv"
    if not path.is_file():
        raise RuntimeError(f"phase log is missing: {path}")
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if reader.fieldnames != ["utc", "pass", "phase", "seconds"]:
            raise RuntimeError(f"unexpected phase-log columns: {reader.fieldnames}")
        rows = list(reader)
    primary = [
        "pass_preamble",
        "frame_loop",
        "statistics",
        "frame_table_hash",
        "iteration_table_hash",
        "gate_hash",
        "pass_completed",
        "primary_checkpoint",
    ]
    replay = [
        "pass_preamble",
        "frame_loop",
        "statistics",
        "frame_table_hash",
        "iteration_table_hash",
        "gate_hash",
        "pass_completed",
    ]
    expected: list[tuple[str, str]] = []
    for pass_name, phases in (("primary", primary), ("replay", replay)):
        for phase in phases:
            expected.extend(
                [(pass_name, f"{phase}:start"), (pass_name, f"{phase}:end")]
            )
    expected.extend(
        [("artifact", "write_result:start"), ("artifact", "write_result:end")]
    )
    actual = [(row["pass"], row["phase"]) for row in rows]
    if actual != expected:
        raise RuntimeError(
            "phase-log sequence differs from the registered sequence: "
            f"expected {expected}, found {actual}"
        )
    durations: dict[str, float] = {}
    previous_timestamp: dt.datetime | None = None
    for row in rows:
        timestamp = parse_utc_timestamp(row["utc"])
        if previous_timestamp is not None and timestamp < previous_timestamp:
            raise RuntimeError(f"phase-log timestamps are not append ordered: {row}")
        previous_timestamp = timestamp
        seconds = float(row["seconds"])
        if not math.isfinite(seconds):
            raise RuntimeError(f"phase event has non-finite seconds: {row}")
        phase_event = row["phase"]
        if phase_event.endswith(":start"):
            if seconds != 0.0:
                raise RuntimeError(f"phase start has nonzero seconds: {row}")
        else:
            if seconds < 0.0:
                raise RuntimeError(f"phase end has negative seconds: {row}")
            phase = phase_event[: -len(":end")]
            durations[f"{row['pass']}__{phase}"] = seconds
    return durations


def checkpoint_gate(root: Path, manifest: dict[str, Any]) -> dict[str, Any]:
    checkpoint = root / "primary_checkpoint"
    expected_files = {"frames.csv", "iterations.csv", "science.json"}
    actual_files = {
        path.relative_to(checkpoint).as_posix()
        for path in checkpoint.rglob("*")
        if path.is_file()
    } if checkpoint.is_dir() else set()
    checkpoint_science = checkpoint / "science.json"
    checkpoint_science_bytes = (
        checkpoint_science.read_bytes() if checkpoint_science.is_file() else b""
    )
    canonical_checkpoint_bytes = (
        checkpoint_science_bytes[:-1]
        if checkpoint_science_bytes.endswith(b"\n")
        else checkpoint_science_bytes
    )
    entries = manifest_entries(root)
    required_entries = {
        "phase_log.tsv",
        "primary_checkpoint/frames.csv",
        "primary_checkpoint/iterations.csv",
        "primary_checkpoint/science.json",
    }
    checks = {
        "exact_checkpoint_files": actual_files == expected_files,
        "frames_equal_final": checkpoint.is_dir()
        and sha256_file(checkpoint / "frames.csv") == sha256_file(root / "frames.csv"),
        "iterations_equal_final": checkpoint.is_dir()
        and sha256_file(checkpoint / "iterations.csv")
        == sha256_file(root / "iterations.csv"),
        "checkpoint_base_hash": bool(canonical_checkpoint_bytes)
        and hashlib.sha256(canonical_checkpoint_bytes).hexdigest()
        == manifest.get("base_scientific_sha256"),
        "checkpoint_file_hash": checkpoint_science.is_file()
        and sha256_file(checkpoint_science)
        == manifest.get("primary_checkpoint_science_sha256"),
        "checkpoint_manifest_path": manifest.get("primary_checkpoint")
        == "primary_checkpoint",
        "phase_log_manifest_path": manifest.get("phase_log") == "phase_log.tsv",
        "progress_excluded": manifest.get(
            "progress_excluded_from_scientific_and_checksum_hashes"
        )
        is True,
        "phase_log_included": manifest.get(
            "phase_log_included_in_checksum_hashes"
        )
        is True,
        "checksum_entries": required_entries.issubset(entries),
    }
    failed = [key for key, value in checks.items() if not value]
    if failed:
        raise RuntimeError("primary checkpoint gate failed: " + ", ".join(failed))
    return checks


def result_gate(root: Path, stage: str, require_expansion: bool) -> dict[str, Any]:
    entries = verify_checksum_tree(root, {"MANIFEST.sha256", "progress.toml"})
    completion = load_toml(root / "COMPLETED.toml")
    manifest = load_toml(root / "manifest.toml")
    science_bytes = (root / "science.json").read_bytes()
    science = json.loads(science_bytes)
    canonical_science_bytes = (
        science_bytes[:-1] if science_bytes.endswith(b"\n") else science_bytes
    )
    stored_scientific_sha256 = hashlib.sha256(canonical_science_bytes).hexdigest()
    replay = science.get("deterministic_replay", {})
    archived_config_path = root / "source" / "config.toml"
    archived_config = load_toml(archived_config_path)
    work_budget = archived_config.get("work_budget", {})
    source_records = manifest.get("source", {}).get("sources", [])
    config_records = [
        record
        for record in source_records
        if record.get("archived_relative_path") == "source/config.toml"
    ]
    freeze = Path(str(manifest.get("freeze", "")))
    freeze_manifest_path = freeze / "freeze_manifest.toml"
    freeze_checksums_path = freeze / "MANIFEST.sha256"
    freeze_checksum_entries = verify_checksum_tree(freeze, {"MANIFEST.sha256"})
    freeze_manifest = load_toml(freeze_manifest_path)
    archived_config_sha256 = sha256_file(archived_config_path)
    phase_durations = phase_log_gate(root)
    checkpoint_checks = checkpoint_gate(root, manifest)
    checks = {
        "experiment": completion.get("experiment_id") == EXPERIMENT_ID,
        "manifest_experiment": manifest.get("experiment_id") == EXPERIMENT_ID,
        "science_experiment": science.get("experiment_id") == EXPERIMENT_ID,
        "stage": completion.get("stage") == stage
        and manifest.get("stage") == stage
        and science.get("stage") == stage,
        "complete_valid": completion.get("status") == "complete_valid",
        "correctness": completion.get("correctness_passed") is True,
        "science_correctness": science.get("correctness_passed") is True,
        "science_correctness_gates": bool(science.get("correctness_gates"))
        and all(value is True for value in science["correctness_gates"].values()),
        "completion_replay": completion.get("deterministic_replay_passed") is True,
        "science_replay": replay.get("passed") is True,
        "replay_hash_equality": bool(replay.get("first_sha256"))
        and replay.get("first_sha256") == replay.get("second_sha256"),
        "replay_hash_bound_to_manifest": replay.get("first_sha256")
        == manifest.get("base_scientific_sha256"),
        "science_file_hash": completion.get("science_sha256")
        == sha256_file(root / "science.json"),
        "manifest_file_hash": completion.get("manifest_sha256")
        == sha256_file(root / "manifest.toml"),
        "stored_scientific_hash": manifest.get("stored_scientific_sha256")
        == stored_scientific_sha256,
        "single_archived_config_record": len(config_records) == 1,
        "archived_config_record_hash": len(config_records) == 1
        and config_records[0].get("sha256") == archived_config_sha256,
        "archived_config_experiment": archived_config.get("experiment_id")
        == EXPERIMENT_ID,
        "archived_config_bound_to_freeze": freeze_manifest.get(
            "configuration_sha256"
        )
        == archived_config_sha256,
        "freeze_experiment": freeze_manifest.get("experiment_id") == EXPERIMENT_ID,
        "freeze_input_count": freeze_manifest.get("input_row_count") == 224,
        "freeze_source_gate": freeze_manifest.get("source_gate", {}).get("passed")
        is True,
        "freeze_preflight_gate": freeze_manifest.get("preflight_gate", {}).get(
            "passed"
        )
        is True,
        "freeze_manifest_hash": manifest.get("freeze_manifest_sha256")
        == sha256_file(freeze_manifest_path),
        "freeze_checksum_manifest_hash": manifest.get(
            "freeze_checksum_manifest_sha256"
        )
        == sha256_file(freeze_checksums_path),
        "registered_scientific_passes": work_budget.get("scientific_passes") == 2,
        "registered_scientific_pass_names": work_budget.get(
            "scientific_pass_names"
        )
        == ["primary", "replay"],
        "registered_timed_execution": work_budget.get(
            "timed_executions_per_arm_case"
        )
        == 1,
    }
    if require_expansion:
        checks["anchor_expansion"] = (
            completion.get("anchor_expansion_authorized") is True
            and science.get("anchor_expansion_authorized") is True
        )
    failed = [key for key, value in checks.items() if not value]
    if failed:
        raise RuntimeError(f"{stage} result gate failed: " + ", ".join(failed))
    return {
        "root": str(root),
        "stage": stage,
        "checksum_entries": entries,
        "completion": completion,
        "manifest": manifest,
        "science": science,
        "archived_config_sha256": archived_config_sha256,
        "freeze_checksum_entries": freeze_checksum_entries,
        "work_budget": work_budget,
        "phase_durations": phase_durations,
        "checkpoint_checks": checkpoint_checks,
    }


def assert_result(args: argparse.Namespace) -> int:
    result = result_gate(Path(args.result).resolve(), args.stage, args.require_expansion)
    completion = result["completion"]
    if args.expected_science_sha256:
        actual_science_sha256 = sha256_file(Path(args.result) / "science.json")
        if actual_science_sha256 != args.expected_science_sha256:
            raise RuntimeError(
                f"{args.stage} science differs from the registered predecessor: "
                f"expected {args.expected_science_sha256}, found "
                f"{actual_science_sha256}"
            )
    print(
        f"{args.stage} replay-record/correctness/checksum gate passed: "
        f"{result['checksum_entries']} checksum entries; "
        f"science={completion['science_sha256']}"
    )
    return 0


def get_budget(args: argparse.Namespace) -> int:
    config = queue_config(Path(args.queue_root).resolve())
    if args.stage != "heldout":
        raise RuntimeError("v3 continuation queue has only a held-out wall budget")
    record = load_toml(queue_file(config, Path(args.queue_root).resolve(), "budget_record"))
    record_budget = int(record["heldout_wall_budget_seconds"])
    queue_budget = int(config["wall_budget"]["heldout_seconds"])
    if record_budget != queue_budget:
        raise RuntimeError(
            f"held-out wall budget mismatch: derivation={record_budget}, "
            f"queue={queue_budget}"
        )
    print(queue_budget)
    return 0


def assert_budget(args: argparse.Namespace) -> int:
    queue_root = Path(args.queue_root).resolve()
    config = queue_config(queue_root)
    anchor = repo_path(config, "anchor_result")
    record_path = queue_file(config, queue_root, "budget_record")
    derive_script = queue_file(config, queue_root, "budget_derivation_script")
    with tempfile.TemporaryDirectory(prefix="rq2-v3-budget-") as directory:
        regenerated = Path(directory) / "budget_derivation.toml"
        completed = subprocess.run(
            [
                sys.executable,
                str(derive_script),
                "--anchor",
                str(anchor),
                "--output",
                str(regenerated),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        regenerated_record = load_toml(regenerated)
    record = load_toml(record_path)
    checks = {
        "deterministic_derivation": regenerated_record == record,
        "queue_budget": int(config["wall_budget"]["heldout_seconds"])
        == int(record["heldout_wall_budget_seconds"]),
        "queue_term": int(config["wall_budget"]["heldout_term_after_seconds"])
        == int(record["term_after_seconds"]),
        "queue_grace": int(
            config["wall_budget"]["termination_grace_seconds_inside_budget"]
        )
        == int(record["termination_grace_seconds"]),
        "anchor_cases": int(record["anchor_cases"]) == 24,
        "heldout_cases": int(record["heldout_cases"]) == 200,
        "pass_count": int(record["pass_count"]) == 2,
        "safety_factor": float(record["safety_factor"]) == 1.5,
        "absolute_cap": int(record["absolute_safety_cap_seconds"]) == 36000,
        "within_cap": int(record["heldout_wall_budget_seconds"]) <= 36000,
        "anchor_science": record["anchor_science_sha256"]
        == "2062fce292d4b41cf93c6dd86afdb6855345b52ff1408d9c89c7318e25b20d46",
        "phase_log_hash": record["phase_log_sha256"]
        == sha256_file(anchor / "phase_log.tsv"),
    }
    readme = (queue_root / "README.md").read_text(encoding="utf-8")
    primary_hash = float(record["phase_seconds"]["primary__iteration_table_hash"])
    replay_hash = float(record["phase_seconds"]["replay__iteration_table_hash"])
    readme_fields = {
        "anchor_hash": (
            f"anchor science SHA-256: `{record['anchor_science_sha256']}`"
        ),
        "phase_log_hash": f"phase-log SHA-256: `{record['phase_log_sha256']}`",
        "primary_frame": (
            "primary frame-loop: "
            f"`{float(record['primary_frame_loop_seconds']):.9f}` seconds"
        ),
        "replay_frame": (
            "replay frame-loop: "
            f"`{float(record['replay_frame_loop_seconds']):.9f}` seconds"
        ),
        "seconds_per_frame": (
            "anchor seconds per frame per pass: "
            f"`{float(record['anchor_seconds_per_frame']):.12f}`"
        ),
        "primary_hash": (
            f"primary iteration-table hash: `{primary_hash:.9f}` seconds"
        ),
        "replay_hash": (
            f"replay iteration-table hash: `{replay_hash:.9f}` seconds"
        ),
        "total_hash": (
            "total iteration-table hash: "
            f"`{primary_hash + replay_hash:.9f}` seconds"
        ),
        "anchor_post": (
            "anchor post-loop total: "
            f"`{float(record['anchor_post_loop_seconds']):.9f}` seconds"
        ),
        "projected_frame": (
            "projected 200-frame frame-loop: "
            f"`{float(record['projected_frame_seconds']):.9f}` seconds"
        ),
        "projected_post": (
            "projected 200-frame post-loop: "
            f"`{float(record['projected_post_loop_seconds']):.9f}` seconds"
        ),
        "projected_total": (
            "projected held-out wall time before safety: "
            f"`{float(record['projected_seconds_before_safety']):.9f}` seconds"
        ),
        "safety": f"safety factor: `{float(record['safety_factor']):.1f}`",
        "cap": (
            "absolute safety cap: "
            f"`{int(record['absolute_safety_cap_seconds'])}` seconds"
        ),
        "budget": (
            f"held-out wall budget: `{record['heldout_wall_budget_seconds']}` seconds"
        ),
        "term": f"TERM after: `{record['term_after_seconds']}` seconds",
    }
    for key, snippet in readme_fields.items():
        checks[f"readme_{key}"] = snippet in readme
    failed = [key for key, value in checks.items() if not value]
    if failed:
        raise RuntimeError("derived-budget gate failed: " + ", ".join(failed))
    print(completed.stdout.strip())
    print(
        "derived-budget gate passed: "
        f"TERM={record['term_after_seconds']}s, cap={record['heldout_wall_budget_seconds']}s"
    )
    return 0


def write_final(args: argparse.Namespace) -> int:
    queue_root = Path(args.queue_root).resolve()
    config = queue_config(queue_root)
    anchor = result_gate(Path(args.anchor).resolve(), "anchor", True)
    heldout = result_gate(Path(args.heldout).resolve(), "heldout", False)
    optimization = config["optimization"]
    budget_path = queue_file(config, queue_root, "budget_record")
    budget = load_toml(budget_path)
    anchor_completion_hash = sha256_file(Path(anchor["root"]) / "COMPLETED.toml")
    heldout_manifest = heldout["manifest"]
    bindings = {
        "heldout_anchor_path": Path(str(heldout_manifest.get("anchor_result", ""))).resolve()
        == Path(anchor["root"]).resolve(),
        "heldout_anchor_completion": heldout_manifest.get("anchor_completion_sha256")
        == anchor_completion_hash,
        "shared_freeze_path": Path(str(heldout_manifest.get("freeze", ""))).resolve()
        == Path(str(anchor["manifest"].get("freeze", ""))).resolve(),
        "shared_freeze_manifest": heldout_manifest.get("freeze_manifest_sha256")
        == anchor["manifest"].get("freeze_manifest_sha256"),
        "shared_freeze_checksums": heldout_manifest.get(
            "freeze_checksum_manifest_sha256"
        )
        == anchor["manifest"].get("freeze_checksum_manifest_sha256"),
        "shared_archived_config": heldout["archived_config_sha256"]
        == anchor["archived_config_sha256"],
        "shared_registered_work_budget": heldout["work_budget"]
        == anchor["work_budget"],
        "anchor_science_equal_to_predecessor": sha256_file(
            Path(anchor["root"]) / "science.json"
        )
        == optimization["required_anchor_science_sha256"],
    }
    failed_bindings = [key for key, value in bindings.items() if not value]
    if failed_bindings:
        raise RuntimeError(
            "held-out/anchor provenance binding failed: " + ", ".join(failed_bindings)
        )
    queue_lock_count = verify_queue_lock(queue_root, require_record=True)
    queue_package_record = queue_file(config, queue_root, "queue_package_record")
    work_budget = anchor["work_budget"]
    output = queue_file(config, queue_root, "final_summary")
    if output.exists():
        raise RuntimeError(f"refusing to overwrite final summary: {output}")
    payload = {
        "schema_version": "rq2-gd-offset-split-001/queue-summary-v3",
        "queue_id": config["queue_id"],
        "experiment_id": EXPERIMENT_ID,
        "optimization_id": optimization["optimization_id"],
        "created_utc": utc_now(),
        "status": "complete_valid",
        "queue_manifest_sha256": sha256_file(queue_root / "QUEUE_MANIFEST.sha256"),
        "queue_package_record_sha256": sha256_file(queue_package_record),
        "queue_locked_files": queue_lock_count,
        "anchor_result": anchor["root"],
        "anchor_correctness_passed": True,
        "anchor_embedded_replay_passed": True,
        "anchor_checksum_entries": anchor["checksum_entries"],
        "anchor_science_sha256": anchor["completion"]["science_sha256"],
        "heldout_result": heldout["root"],
        "heldout_correctness_passed": True,
        "heldout_embedded_replay_passed": True,
        "heldout_checksum_entries": heldout["checksum_entries"],
        "heldout_science_sha256": heldout["completion"]["science_sha256"],
        "freeze_checksum_entries": anchor["freeze_checksum_entries"],
        "v2_heldout_scientific_artifacts_used": False,
        "v2_partial_progress_used_as_checkpoint": False,
        "required_anchor_science_sha256": optimization[
            "required_anchor_science_sha256"
        ],
        "successor_anchor_science_equal_to_predecessor": sha256_file(
            Path(anchor["root"]) / "science.json"
        )
        == optimization["required_anchor_science_sha256"],
        "budget_derivation_sha256": sha256_file(budget_path),
        "anchor_phase_log_sha256": budget["phase_log_sha256"],
        "heldout_wall_budget_seconds": int(
            budget["heldout_wall_budget_seconds"]
        ),
        "heldout_term_after_seconds": int(budget["term_after_seconds"]),
        "termination_grace_seconds_inside_wall_budget": int(
            budget["termination_grace_seconds"]
        ),
        "outcome_direction_used_as_gate": False,
        "registered_scientific_passes_per_stage": int(
            work_budget["scientific_passes"]
        ),
        "registered_scientific_pass_names": ",".join(
            str(name) for name in work_budget["scientific_pass_names"]
        ),
        "registered_timed_executions_per_arm_case": int(
            work_budget["timed_executions_per_arm_case"]
        ),
        "queue_invoked_external_replay_commands": 0,
        "queue_invoked_no_extra_replay": True,
        "interpretation_status": "not_interpreted_by_queue",
    }
    atomic_write(output, toml_text(payload))
    print(f"wrote final queue summary: {output}")
    return 0


def show_status(args: argparse.Namespace) -> int:
    queue_root = Path(args.queue_root).resolve()
    config = queue_config(queue_root)
    progress_path = queue_file(config, queue_root, "queue_progress")
    if not progress_path.is_file():
        print(f"Queue {config['queue_id']}: not started")
        return 0
    progress = load_toml(progress_path)
    print(
        f"Queue {progress['state']}: {progress['jobs_completed']}/"
        f"{progress['jobs_total']} jobs complete; current "
        f"{progress.get('current_job') or '-'} ({progress['current_job_state']})"
    )
    print(
        f"Updated {progress['updated_utc']}; PID {progress['process_id']}; "
        f"detail: {progress['detail']}"
    )
    status_timestamps = [str(progress["updated_utc"])]
    job = progress.get("current_job", "")
    result_key = "heldout_result" if job in {"J02", "J03"} else ""
    if result_key:
        result_progress = repo_path(config, result_key) / "progress.toml"
        if result_progress.is_file():
            record = load_toml(result_progress)
            print(
                f"Scientific stage {record['stage']}/{record['pass']}: "
                f"{record['frames_completed']}/{record['frames_total']} frames; "
                f"current frame {record['current_frame']}; status {record['status']}"
            )
            print(
                f"Scientific phase {record.get('phase', '-')}; started "
                f"{record.get('phase_started_utc', '-')}; previous "
                f"{record.get('previous_phase', '-')} took "
                f"{record.get('previous_phase_elapsed_seconds', 0.0)} seconds"
            )
            print(f"Scientific progress updated {record['updated_utc']}")
            phase_log = result_progress.parent / "phase_log.tsv"
            if phase_log.is_file():
                lines = phase_log.read_text(encoding="utf-8").splitlines()
                if len(lines) > 1:
                    print(f"Latest phase event: {lines[-1]}")
            status_timestamps.append(str(record["updated_utc"]))
    if progress["state"] in {"running", "waiting"}:
        process_id = int(progress["process_id"])
        alive = True
        try:
            os.kill(process_id, 0)
        except (ProcessLookupError, PermissionError):
            alive = False
        command_matches = False
        command_path = Path(f"/proc/{process_id}/cmdline")
        if alive and command_path.is_file():
            command_matches = "run_queue.sh" in command_path.read_bytes().replace(b"\0", b" ").decode(
                "utf-8", errors="replace"
            )
        try:
            updated = max(parse_utc_timestamp(value) for value in status_timestamps)
            age_seconds = (dt.datetime.now(dt.timezone.utc) - updated).total_seconds()
        except (TypeError, ValueError):
            age_seconds = float("inf")
        if not alive or not command_matches:
            print("WARNING: recorded queue PID is not a live run_queue.sh process")
        if age_seconds > 20 * 60:
            print(f"WARNING: newest durable status is stale by {int(age_seconds)} seconds")
    for job_id in ("J01", "J02", "J03"):
        job_root = queue_root / "jobs" / job_id
        state = "pending"
        for marker, label in (
            ("FAILED.toml", "failed"),
            ("COMPLETED.toml", "complete"),
            ("STARTED.toml", "running"),
        ):
            if (job_root / marker).is_file():
                state = label
                break
        print(f"{job_id}: {state}")
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subparsers = root.add_subparsers(dest="command", required=True)

    show = subparsers.add_parser("show")
    show.add_argument("--queue-root", default=str(QUEUE_ROOT))
    show.set_defaults(function=show_status)

    update = subparsers.add_parser("update-queue")
    update.add_argument("--queue-root", default=str(QUEUE_ROOT))
    update.add_argument("--state", required=True)
    update.add_argument("--job-id", default="")
    update.add_argument("--job-state", required=True)
    update.add_argument("--completed", type=int, required=True)
    update.add_argument("--exit-code", type=int, default=-1)
    update.add_argument("--detail", required=True)
    update.add_argument("--started-utc", default="")
    update.set_defaults(function=update_queue)

    marker = subparsers.add_parser("write-marker")
    marker.add_argument("--queue-root", default=str(QUEUE_ROOT))
    marker.add_argument("--job-id", required=True)
    marker.add_argument("--state", choices=("started", "complete", "failed"), required=True)
    marker.add_argument("--exit-code", type=int, required=True)
    marker.add_argument("--detail", required=True)
    marker.set_defaults(function=write_marker)

    terminal = subparsers.add_parser("queue-terminal")
    terminal.add_argument("--queue-root", default=str(QUEUE_ROOT))
    terminal.add_argument("--state", choices=("complete", "failed"), required=True)
    terminal.add_argument("--exit-code", type=int, required=True)
    terminal.add_argument("--detail", required=True)
    terminal.set_defaults(function=write_queue_terminal)

    preflight = subparsers.add_parser("assert-preflight")
    preflight.add_argument("--queue-root", default=str(QUEUE_ROOT))
    preflight.set_defaults(function=assert_preflight)

    optimization = subparsers.add_parser("assert-optimization")
    optimization.add_argument("--queue-root", default=str(QUEUE_ROOT))
    optimization.set_defaults(function=assert_optimization)

    queue_lock = subparsers.add_parser("assert-queue-lock")
    queue_lock.add_argument("--queue-root", default=str(QUEUE_ROOT))
    queue_lock.add_argument("--require-record", action="store_true")
    queue_lock.set_defaults(function=assert_queue_lock)

    package_lock = subparsers.add_parser("lock-queue-package")
    package_lock.add_argument("--queue-root", default=str(QUEUE_ROOT))
    package_lock.set_defaults(function=lock_queue_package)

    freeze = subparsers.add_parser("assert-freeze")
    freeze.add_argument("--freeze", required=True)
    freeze.add_argument("--expected-input-sha256", default="")
    freeze.set_defaults(function=assert_freeze)

    result = subparsers.add_parser("assert-result")
    result.add_argument("--result", required=True)
    result.add_argument("--stage", choices=("anchor", "heldout"), required=True)
    result.add_argument("--require-expansion", action="store_true")
    result.add_argument("--expected-science-sha256", default="")
    result.set_defaults(function=assert_result)

    budget = subparsers.add_parser("get-budget")
    budget.add_argument("--queue-root", default=str(QUEUE_ROOT))
    budget.add_argument("--stage", choices=("heldout",), required=True)
    budget.set_defaults(function=get_budget)

    budget_gate = subparsers.add_parser("assert-budget")
    budget_gate.add_argument("--queue-root", default=str(QUEUE_ROOT))
    budget_gate.set_defaults(function=assert_budget)

    final = subparsers.add_parser("write-final")
    final.add_argument("--queue-root", default=str(QUEUE_ROOT))
    final.add_argument("--anchor", required=True)
    final.add_argument("--heldout", required=True)
    final.set_defaults(function=write_final)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return int(args.function(args))
    except Exception as error:  # concise durable failure for queue logs
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
