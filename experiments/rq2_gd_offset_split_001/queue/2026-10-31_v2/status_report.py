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
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any, Iterable

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # Python 3.10 on the registered machine
    import tomli as tomllib  # type: ignore[no-redef]


QUEUE_ROOT = Path(__file__).resolve().parent
QUEUE_CONFIG = QUEUE_ROOT / "queue.toml"
QUEUE_SCHEMA = "rq2-gd-offset-split-001/queue-progress-v2"
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
        "schema_version": "rq2-gd-offset-split-001/queue-job-v2",
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
        "schema_version": "rq2-gd-offset-split-001/queue-terminal-v2",
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


def assert_amendment(args: argparse.Namespace) -> int:
    """Verify that v2 changes only the approved wall-clock service cap."""

    queue_root = Path(args.queue_root).resolve()
    config = queue_config(queue_root)
    amendment = config["amendment"]
    repository_root = Path(config["paths"]["repository_root"])

    def amendment_path(key: str) -> Path:
        candidate = Path(str(amendment[key]))
        return candidate if candidate.is_absolute() else repository_root / candidate

    old_config_path = amendment_path("predecessor_freeze") / "source" / "config.toml"
    new_config_path = repo_path(config, "config")
    old_config = load_toml(old_config_path)
    new_config = load_toml(new_config_path)

    old_for_comparison = json.loads(json.dumps(old_config))
    new_for_comparison = json.loads(json.dumps(new_config))
    amendment_record = new_for_comparison.pop("amendment", None)
    old_budget = old_for_comparison["work_budget"]["heldout_wall_budget_seconds"]
    new_budget = new_for_comparison["work_budget"]["heldout_wall_budget_seconds"]
    new_for_comparison["work_budget"]["heldout_wall_budget_seconds"] = old_budget

    predecessor_heldout = amendment_path("predecessor_heldout_result")
    predecessor_files = {
        path.relative_to(predecessor_heldout).as_posix()
        for path in predecessor_heldout.rglob("*")
        if path.is_file()
    }
    forbidden_science = {
        "frames.csv",
        "aggregate.csv",
        "science.json",
        "manifest.toml",
        "COMPLETED.toml",
        "MANIFEST.sha256",
    }
    predecessor_queue = amendment_path("predecessor_queue")
    checks = {
        "amendment_id": amendment.get("amendment_id") == "RQ2-AMEND-001",
        "launch_approval_id": amendment.get("launch_approval_id")
        == "RQ2-LAUNCH-001",
        "only_config_difference": new_for_comparison == old_for_comparison,
        "administrative_amendment_present": isinstance(amendment_record, dict),
        "old_budget": old_budget == 18000,
        "new_budget": new_budget == 36000,
        "queue_anchor_budget": config["wall_budget"]["anchor_seconds"] == 1800,
        "queue_heldout_budget": config["wall_budget"]["heldout_seconds"] == 36000,
        "queue_grace": config["wall_budget"][
            "termination_grace_seconds_inside_budget"
        ]
        == 120,
        "queue_term_after": config["wall_budget"]["heldout_term_after_seconds"]
        == 35880,
        "external_conflict_unit": config.get("external_scientific_conflict_unit")
        == "sp-gd-claude-controls-20261031.service",
        "external_conflict_poll": config.get("external_conflict_wait_poll_seconds")
        == 60,
        "wall_budget_after_external_wait": config.get(
            "scientific_wall_budget_begins_after_external_wait"
        )
        is True,
        "predecessor_config_hash": sha256_file(old_config_path)
        == amendment["predecessor_config_sha256"],
        "predecessor_card_hash": sha256_file(
            amendment_path("predecessor_freeze") / "source" / "experiment_card.md"
        )
        == amendment["predecessor_card_sha256"],
        "runner_byte_identity": sha256_file(repo_path(config, "runner"))
        == amendment["runner_sha256"],
        "test_byte_identity": sha256_file(repo_path(config, "test"))
        == amendment["test_sha256"],
        "predecessor_input_identity": sha256_file(
            amendment_path("predecessor_freeze") / "input_freeze.csv"
        )
        == amendment["predecessor_input_freeze_sha256"],
        "predecessor_anchor_science": sha256_file(
            amendment_path("predecessor_anchor_result") / "science.json"
        )
        == amendment["predecessor_anchor_science_sha256"],
        "predecessor_queue_failure": sha256_file(
            predecessor_queue / "QUEUE_FAILED.toml"
        )
        == amendment["predecessor_queue_failure_sha256"],
        "predecessor_j04_failure": sha256_file(
            predecessor_queue / "jobs" / "J04" / "FAILED.toml"
        )
        == amendment["predecessor_j04_failure_sha256"],
        "predecessor_queue_progress": sha256_file(
            predecessor_queue / "progress.toml"
        )
        == amendment["predecessor_queue_progress_sha256"],
        "predecessor_j04_log": sha256_file(predecessor_queue / "logs" / "J04.log")
        == amendment["predecessor_j04_log_sha256"],
        "predecessor_partial_not_reused": amendment.get(
            "reuse_predecessor_partial_progress"
        )
        is False,
        "predecessor_heldout_only_progress": predecessor_files == {"progress.toml"},
        "predecessor_heldout_has_no_science": not (
            predecessor_files & forbidden_science
        ),
    }
    failed = [key for key, value in checks.items() if not value]
    if failed:
        raise RuntimeError("amendment whitelist failed: " + ", ".join(failed))
    print(
        "prospective amendment passed: only held-out wall budget changed "
        "18000 -> 36000 seconds; v1 preserved; runner/test byte-identical"
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
    expected_files = {"queue.toml", "run_queue.sh", "status_report.py", "README.md"}
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
            == "rq2-gd-offset-split-001/queue-package-lock-v2",
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
        "schema_version": "rq2-gd-offset-split-001/queue-package-lock-v2",
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
    experiment = load_toml(repo_path(config, "config"))
    experiment_key = f"{args.stage}_wall_budget_seconds"
    queue_key = f"{args.stage}_seconds"
    experiment_budget = int(experiment["work_budget"][experiment_key])
    queue_budget = int(config["wall_budget"][queue_key])
    if experiment_budget != queue_budget:
        raise RuntimeError(
            f"{args.stage} wall budget mismatch: config={experiment_budget}, "
            f"queue={queue_budget}"
        )
    print(queue_budget)
    return 0


def write_final(args: argparse.Namespace) -> int:
    queue_root = Path(args.queue_root).resolve()
    config = queue_config(queue_root)
    anchor = result_gate(Path(args.anchor).resolve(), "anchor", True)
    heldout = result_gate(Path(args.heldout).resolve(), "heldout", False)
    amendment = config["amendment"]
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
        == amendment["predecessor_anchor_science_sha256"],
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
        "schema_version": "rq2-gd-offset-split-001/queue-summary-v2",
        "queue_id": config["queue_id"],
        "experiment_id": EXPERIMENT_ID,
        "amendment_id": amendment["amendment_id"],
        "launch_approval_id": amendment["launch_approval_id"],
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
        "predecessor_heldout_scientific_artifacts_used": False,
        "predecessor_partial_progress_used_as_checkpoint": False,
        "predecessor_anchor_science_sha256": amendment[
            "predecessor_anchor_science_sha256"
        ],
        "successor_anchor_science_equal_to_predecessor": sha256_file(
            Path(anchor["root"]) / "science.json"
        )
        == amendment["predecessor_anchor_science_sha256"],
        "heldout_wall_budget_seconds": int(config["wall_budget"]["heldout_seconds"]),
        "termination_grace_seconds_inside_wall_budget": int(
            config["wall_budget"]["termination_grace_seconds_inside_budget"]
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
    result_key = "anchor_result" if job in {"J02", "J03"} else (
        "heldout_result" if job in {"J04", "J05"} else ""
    )
    if result_key:
        result_progress = repo_path(config, result_key) / "progress.toml"
        if result_progress.is_file():
            record = load_toml(result_progress)
            print(
                f"Scientific stage {record['stage']}/{record['pass']}: "
                f"{record['frames_completed']}/{record['frames_total']} frames; "
                f"current frame {record['current_frame']}; status {record['status']}"
            )
            print(f"Scientific progress updated {record['updated_utc']}")
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
    for job_id in ("J01", "J02", "J03", "J04", "J05"):
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

    amendment = subparsers.add_parser("assert-amendment")
    amendment.add_argument("--queue-root", default=str(QUEUE_ROOT))
    amendment.set_defaults(function=assert_amendment)

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
    budget.add_argument("--stage", choices=("anchor", "heldout"), required=True)
    budget.set_defaults(function=get_budget)

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
