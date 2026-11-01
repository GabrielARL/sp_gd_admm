#!/usr/bin/env python3
"""One-shot, fail-closed dispatcher for RQ2-EXACT-MAP-UPDATE-001.

The dispatcher observes the native-composition service with read-only
``systemctl show`` calls.  It never signals, restarts, or resumes either
scientific queue.  Once the predecessor is inactive it validates all retained
predecessor evidence through that queue's hash-pinned controller, validates a
fresh hash-locked successor queue, records an immutable launch intent, invokes
the successor's locked launcher once, and observes evidence that the launch
was accepted.

An invocation is one attempt.  Durable state makes a later invocation refuse
to run; there is deliberately no retry path after ``LAUNCH_INTENT.toml``.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from types import ModuleType
from typing import Any, Mapping, Sequence

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # pragma: no cover - Python 3.10
    import tomli as tomllib  # type: ignore[no-redef]


SCHEMA = "rq2-exact-map-update-001/dependency-dispatcher-v1"
PREDECESSOR_COMPLETION_SCHEMA = "rq2-native-composition-001/queue-completion-v1"
PREDECESSOR_PROGRESS_SCHEMA = "rq2-native-composition-001/progress-v1"
PREDECESSOR_EXPERIMENT_ID = "RQ2-NATIVE-COMPOSITION-001"
PREDECESSOR_QUEUE_ID = "2026-11-01_v2"
PREDECESSOR_JOB_COUNT = 7
PREDECESSOR_FINAL_JOB = "07_second_snr_confirmation"
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")
TERMINALS = ("DISPATCHED.toml", "FAILED.toml")


class DispatchError(RuntimeError):
    """A fail-closed dispatch error."""


class AlreadyAttempted(DispatchError):
    """Durable state proves that this one-shot attempt already began."""


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_toml(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        return tomllib.load(handle)


def quote(value: object) -> str:
    return json.dumps(str(value), ensure_ascii=True)


def render_flat_toml(values: Mapping[str, object]) -> str:
    lines: list[str] = []
    for key, value in values.items():
        if not re.fullmatch(r"[A-Za-z0-9_-]+", key):
            raise DispatchError(f"invalid TOML key: {key!r}")
        if isinstance(value, bool):
            text = "true" if value else "false"
        elif isinstance(value, int):
            text = str(value)
        elif isinstance(value, float):
            text = repr(value)
        else:
            text = quote(value)
        lines.append(f"{key} = {text}")
    return "\n".join(lines) + "\n"


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_create(path: Path, text: str, mode: int = 0o444) -> None:
    """Create an immutable record without an overwrite window."""

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
        os.chmod(temporary, mode)
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise AlreadyAttempted(f"refusing to overwrite durable record: {path}") from error
        fsync_directory(path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def append_event(path: Path, event: str, outcome: str, detail: str = "") -> None:
    """Append and fsync one telemetry row; the file is never rewritten."""

    path.parent.mkdir(parents=True, exist_ok=True)
    from io import StringIO

    buffer = StringIO()
    writer = csv.writer(buffer, delimiter="\t", lineterminator="\n")
    if not path.exists() or path.stat().st_size == 0:
        writer.writerow(("utc", "event", "outcome", "detail"))
    writer.writerow((utc_now(), event, outcome, detail))
    encoded = buffer.getvalue().encode("utf-8")
    descriptor = os.open(path, os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o644)
    try:
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("short write while appending dispatcher telemetry")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def regular_file(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise DispatchError(f"{label} is missing, non-regular, or a symlink: {path}")


def resolve_path(config_path: Path, value: object, label: str) -> Path:
    if not isinstance(value, str) or not value:
        raise DispatchError(f"{label} must be a nonempty path string")
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = config_path.parent / candidate
    return candidate.resolve(strict=False)


def require_digest(value: object, label: str) -> str:
    if not isinstance(value, str) or not HEX_SHA256.fullmatch(value):
        raise DispatchError(f"{label} must be a lowercase SHA-256 digest")
    return value


def require_hash(path: Path, expected: str, label: str) -> None:
    regular_file(path, label)
    observed = sha256_file(path)
    if observed != expected:
        raise DispatchError(
            f"{label} hash mismatch: expected {expected}, observed {observed}"
        )


def load_module(path: Path, digest: str, label: str) -> ModuleType:
    require_hash(path, digest, label)
    name = f"_rq2_locked_{hashlib.sha256(str(path).encode()).hexdigest()[:16]}"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise DispatchError(f"cannot load {label}: {path}")
    module = importlib.util.module_from_spec(spec)
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


def require_fields(record: Mapping[str, Any], expected: Mapping[str, object], label: str) -> None:
    for key, wanted in expected.items():
        observed = record.get(key)
        if observed != wanted:
            raise DispatchError(
                f"{label}.{key} mismatch: expected {wanted!r}, observed {observed!r}"
            )


def parse_checksum_manifest(root: Path, path: Path) -> dict[str, str]:
    regular_file(path, "successor queue manifest")
    entries: dict[str, str] = {}
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw:
            continue
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", raw)
        if match is None:
            raise DispatchError(f"malformed queue manifest line {line_number}")
        digest, relative_text = match.groups()
        relative = Path(relative_text)
        if relative.is_absolute() or ".." in relative.parts or relative_text in entries:
            raise DispatchError(f"unsafe or duplicate manifest path: {relative_text!r}")
        target = root / relative
        regular_file(target, f"manifest member {relative_text}")
        observed = sha256_file(target)
        if observed != digest:
            raise DispatchError(
                f"manifest member hash mismatch for {relative_text}: {observed}"
            )
        entries[relative_text] = digest
    if not entries:
        raise DispatchError("successor queue manifest is empty")
    return entries


def invoke_locked(module: ModuleType, name: str, *arguments: object) -> Any:
    function = getattr(module, name, None)
    if not callable(function):
        raise DispatchError(f"locked controller does not expose {name}()")
    try:
        return function(*arguments)
    except Exception as error:
        raise DispatchError(f"locked controller {name} failed: {error}") from error


class Dispatcher:
    def __init__(self, config_path: Path):
        self.config_path = config_path.resolve()
        regular_file(self.config_path, "dispatcher configuration")
        raw = load_toml(self.config_path)
        require_fields(raw, {"schema_version": SCHEMA}, "configuration")
        self.dispatcher_id = str(raw.get("dispatcher_id", ""))
        if not self.dispatcher_id:
            raise DispatchError("dispatcher_id is required")

        controller = self._table(raw, "controller")
        predecessor = self._table(raw, "predecessor")
        successor = self._table(raw, "successor")

        self.state_dir = resolve_path(
            self.config_path, controller.get("state_dir"), "controller.state_dir"
        )
        self.systemctl = resolve_path(
            self.config_path, controller.get("systemctl"), "controller.systemctl"
        )
        self.poll_seconds = self._positive(controller, "poll_interval_seconds")
        self.max_wait_seconds = self._positive(controller, "max_wait_seconds")
        self.confirm_seconds = self._positive(
            controller, "confirmation_timeout_seconds"
        )
        self.confirm_poll_seconds = self._positive(
            controller, "confirmation_poll_seconds"
        )
        self.command_timeout_seconds = self._positive(
            controller, "command_timeout_seconds"
        )

        self.pred_unit = self._string(predecessor, "unit_name", "predecessor")
        self.pred_root = resolve_path(
            self.config_path, predecessor.get("queue_root"), "predecessor.queue_root"
        )
        self.pred_controller = self.pred_root / self._string(
            predecessor, "controller_relative_path", "predecessor"
        )
        self.pred_controller_sha = require_digest(
            predecessor.get("controller_sha256"), "predecessor.controller_sha256"
        )
        self.pred_failed = self.pred_root / self._string(
            predecessor, "failed_relative_path", "predecessor"
        )
        self.pred_completed = self.pred_root / self._string(
            predecessor, "completed_relative_path", "predecessor"
        )
        self.pred_progress = self.pred_root / self._string(
            predecessor, "progress_relative_path", "predecessor"
        )

        self.succ_unit = self._string(successor, "unit_name", "successor")
        self.succ_root = resolve_path(
            self.config_path, successor.get("queue_root"), "successor.queue_root"
        )
        self.succ_controller = self.succ_root / self._string(
            successor, "controller_relative_path", "successor"
        )
        self.succ_controller_sha = require_digest(
            successor.get("controller_sha256"), "successor.controller_sha256"
        )
        self.succ_manifest = self.succ_root / self._string(
            successor, "manifest_relative_path", "successor"
        )
        self.succ_manifest_sha = require_digest(
            successor.get("manifest_sha256"), "successor.manifest_sha256"
        )
        self.succ_lock = self.succ_root / self._string(
            successor, "lock_relative_path", "successor"
        )
        self.succ_lock_sha = require_digest(
            successor.get("lock_sha256"), "successor.lock_sha256"
        )
        self.succ_launch = self.succ_root / self._string(
            successor, "launch_relative_path", "successor"
        )
        self.succ_launch_sha = require_digest(
            successor.get("launch_sha256"), "successor.launch_sha256"
        )
        arguments = successor.get("launch_arguments", [str(self.succ_root)])
        if not isinstance(arguments, list) or not all(
            isinstance(value, str) and value for value in arguments
        ):
            raise DispatchError("successor.launch_arguments must be nonempty strings")
        self.succ_launch_arguments = list(arguments)
        self.succ_progress = self.succ_root / self._string(
            successor, "progress_relative_path", "successor"
        )
        self.succ_completed = self.succ_root / self._string(
            successor, "completed_relative_path", "successor"
        )
        self.succ_failed = self.succ_root / self._string(
            successor, "failed_relative_path", "successor"
        )
        self.succ_experiment = self._string(successor, "experiment_id", "successor")
        self.succ_queue_id = self._string(successor, "queue_id", "successor")
        self.succ_progress_schema = self._string(
            successor, "progress_schema", "successor"
        )
        self.succ_completion_schema = self._string(
            successor, "completion_schema", "successor"
        )
        self.succ_failure_schema = self._string(
            successor, "failure_schema", "successor"
        )

        self.events = self.state_dir / "events.tsv"
        self.lock_path = self.state_dir / ".dispatcher.lock"
        self.config_sha256 = sha256_file(self.config_path)
        self._lock_handle: Any = None

    @staticmethod
    def _table(raw: Mapping[str, Any], name: str) -> Mapping[str, Any]:
        value = raw.get(name)
        if not isinstance(value, dict):
            raise DispatchError(f"[{name}] table is required")
        return value

    @staticmethod
    def _string(table: Mapping[str, Any], key: str, prefix: str) -> str:
        value = table.get(key)
        if not isinstance(value, str) or not value:
            raise DispatchError(f"{prefix}.{key} must be a nonempty string")
        return value

    @staticmethod
    def _positive(table: Mapping[str, Any], key: str) -> float:
        value = table.get(key)
        if not isinstance(value, (int, float)) or isinstance(value, bool) or value <= 0:
            raise DispatchError(f"controller.{key} must be positive")
        return float(value)

    def acquire(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        prior_lock = self.lock_path.exists()
        self._lock_handle = self.lock_path.open("a+")
        fcntl.flock(self._lock_handle.fileno(), fcntl.LOCK_EX)
        existing = [name for name in TERMINALS if (self.state_dir / name).exists()]
        prior_evidence = (
            prior_lock
            or (self.events.exists() and self.events.stat().st_size > 0)
            or (self.state_dir / "LAUNCH_INTENT.toml").exists()
        )
        if existing or prior_evidence:
            raise AlreadyAttempted(
                "dispatcher attempt already has durable state: "
                + ", ".join(existing or ["lock, events, or launch intent"])
            )

    def event(self, event: str, outcome: str, detail: str = "") -> None:
        append_event(self.events, event, outcome, detail)

    def systemctl_show(self, unit: str) -> dict[str, str]:
        command = [
            str(self.systemctl), "--user", "show", unit, "--no-pager",
            "--property=LoadState,ActiveState,SubState,MainPID",
        ]
        completed = subprocess.run(
            command, text=True, capture_output=True,
            timeout=self.command_timeout_seconds, check=False,
        )
        if completed.returncode != 0:
            raise DispatchError(
                f"systemctl show failed for {unit}: {completed.stderr.strip()}"
            )
        fields: dict[str, str] = {}
        for line in completed.stdout.splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                fields[key] = value
        for key in ("LoadState", "ActiveState", "SubState", "MainPID"):
            if key not in fields:
                raise DispatchError(f"systemctl show omitted {key} for {unit}")
        return fields

    def await_predecessor(self) -> None:
        started = time.monotonic()
        previous = ""
        observed_active = False
        while True:
            if self.pred_failed.exists():
                regular_file(self.pred_failed, "predecessor failure marker")
                raise DispatchError(f"predecessor declared failure: {self.pred_failed}")
            state = self.systemctl_show(self.pred_unit)
            summary = "/".join((state["ActiveState"], state["SubState"], state["MainPID"]))
            if summary != previous:
                self.event("predecessor_observed", "waiting", summary)
                previous = summary
            if state["LoadState"] == "not-found":
                if not observed_active:
                    raise DispatchError(
                        "predecessor unit was not found before this invocation observed it active"
                    )
                if self.pred_failed.exists():
                    raise DispatchError(f"predecessor declared failure: {self.pred_failed}")
                self.event(
                    "predecessor_collected", "inactive_candidate",
                    "unit disappeared after being observed active; retained evidence is required",
                )
                return
            if state["ActiveState"] == "active":
                observed_active = True
            if state["ActiveState"] in ("inactive", "failed"):
                if state["MainPID"] not in ("0", ""):
                    raise DispatchError("inactive predecessor retained a nonzero MainPID")
                if self.pred_failed.exists():
                    raise DispatchError(f"predecessor declared failure: {self.pred_failed}")
                self.event("predecessor_inactive", "ok", summary)
                return
            if state["ActiveState"] not in (
                "active", "activating", "deactivating", "reloading"
            ):
                raise DispatchError(f"unexpected predecessor state: {summary}")
            if time.monotonic() - started >= self.max_wait_seconds:
                raise DispatchError("timed out waiting for predecessor to become inactive")
            time.sleep(self.poll_seconds)

    def validate_predecessor(self) -> None:
        self.event("predecessor_validation", "start")
        module = load_module(
            self.pred_controller, self.pred_controller_sha,
            "predecessor locked controller",
        )
        config = invoke_locked(module, "verify_queue_package", self.pred_root)
        if not isinstance(config, dict):
            raise DispatchError("predecessor verify_queue_package returned no configuration")
        paths = config.get("paths")
        if not isinstance(paths, dict) or not isinstance(paths.get("freeze_root"), str):
            raise DispatchError("predecessor configuration lacks paths.freeze_root")
        invoke_locked(module, "verify_freeze", Path(paths["freeze_root"]))
        invoke_locked(module, "verify_preflight", config)

        if self.pred_failed.exists():
            raise DispatchError(f"predecessor declared failure: {self.pred_failed}")
        regular_file(self.pred_completed, "predecessor completion marker")
        completion = load_toml(self.pred_completed)
        require_fields(
            completion,
            {
                "schema_version": PREDECESSOR_COMPLETION_SCHEMA,
                "experiment_id": PREDECESSOR_EXPERIMENT_ID,
                "queue_id": PREDECESSOR_QUEUE_ID,
                "status": "complete_valid",
                "completed_jobs": PREDECESSOR_JOB_COUNT,
                "total_jobs": PREDECESSOR_JOB_COUNT,
            },
            "predecessor completion",
        )
        regular_file(self.pred_progress, "predecessor progress")
        progress = load_toml(self.pred_progress)
        require_fields(
            progress,
            {
                "schema_version": PREDECESSOR_PROGRESS_SCHEMA,
                "experiment_id": PREDECESSOR_EXPERIMENT_ID,
                "queue_id": PREDECESSOR_QUEUE_ID,
                "status": "complete_valid",
                "phase": "queue_complete",
                "current_job": PREDECESSOR_FINAL_JOB,
                "completed_jobs": PREDECESSOR_JOB_COUNT,
                "total_jobs": PREDECESSOR_JOB_COUNT,
            },
            "predecessor progress",
        )
        jobs = config.get("jobs")
        if not isinstance(jobs, list) or len(jobs) != PREDECESSOR_JOB_COUNT:
            raise DispatchError("predecessor locked configuration does not contain 7 jobs")
        for job in jobs:
            if not isinstance(job, dict):
                raise DispatchError("predecessor job is not a table")
            output = invoke_locked(module, "output_path", config, job)
            invoke_locked(module, "verify_result", output, job)
        if self.pred_failed.exists():
            raise DispatchError(f"predecessor failure appeared during validation: {self.pred_failed}")
        self.event("predecessor_validation", "ok", "locked package, freeze, preflight, 7 results")

    def validate_successor(self) -> None:
        self.event("successor_validation", "start")
        require_hash(self.succ_manifest, self.succ_manifest_sha, "successor queue manifest")
        entries = parse_checksum_manifest(self.succ_root, self.succ_manifest)
        require_hash(self.succ_lock, self.succ_lock_sha, "successor queue lock")
        lock = load_toml(self.succ_lock)
        require_fields(
            lock,
            {
                "experiment_id": self.succ_experiment,
                "queue_id": self.succ_queue_id,
                "status": "locked",
                "queue_manifest_sha256": self.succ_manifest_sha,
            },
            "successor queue lock",
        )
        for member in (
            self.succ_controller.relative_to(self.succ_root).as_posix(),
            self.succ_launch.relative_to(self.succ_root).as_posix(),
            "queue.toml",
        ):
            if member not in entries:
                raise DispatchError(f"successor manifest does not pin {member}")
        require_hash(
            self.succ_controller, self.succ_controller_sha,
            "successor locked controller",
        )
        require_hash(self.succ_launch, self.succ_launch_sha, "successor locked launcher")
        module = load_module(
            self.succ_controller, self.succ_controller_sha,
            "successor locked controller",
        )
        config = invoke_locked(module, "verify_queue_package", self.succ_root)
        if not isinstance(config, dict):
            raise DispatchError("successor verify_queue_package returned no configuration")
        invoke_locked(module, "assert_fresh", self.succ_root)
        invoke_locked(module, "prelaunch", self.succ_root)

        jobs = config.get("jobs")
        if not isinstance(jobs, list) or not jobs:
            raise DispatchError("successor locked configuration has no jobs")
        for job in jobs:
            if not isinstance(job, dict):
                raise DispatchError("successor job is not a table")
            output = invoke_locked(module, "output_path", config, job)
            if Path(output).exists():
                raise DispatchError(f"successor output already exists: {output}")
        for runtime in (self.succ_progress, self.succ_completed, self.succ_failed):
            if runtime.exists():
                raise DispatchError(f"successor runtime output already exists: {runtime}")
        self.event("successor_validation", "ok", "hash-locked package and fresh outputs")

    def launch_successor_once(self) -> None:
        if self.pred_failed.exists():
            regular_file(self.pred_failed, "predecessor failure marker")
            raise DispatchError(
                f"predecessor declared failure before dispatch: {self.pred_failed}"
            )
        intent = {
            "schema_version": "rq2-exact-map-update-001/launch-intent-v1",
            "dispatcher_id": self.dispatcher_id,
            "created_utc": utc_now(),
            "configuration_sha256": self.config_sha256,
            "successor_unit": self.succ_unit,
            "successor_queue_root": str(self.succ_root),
            "launcher_sha256": self.succ_launch_sha,
        }
        atomic_create(self.state_dir / "LAUNCH_INTENT.toml", render_flat_toml(intent))
        self.event("successor_launch", "intent_recorded", self.succ_unit)
        command = [str(self.succ_launch), *self.succ_launch_arguments]
        completed = subprocess.run(
            command, cwd=self.succ_root, text=True, capture_output=True,
            timeout=self.command_timeout_seconds, check=False,
        )
        detail = " ".join(part for part in (completed.stdout.strip(), completed.stderr.strip()) if part)
        if completed.returncode != 0:
            raise DispatchError(
                f"successor launcher exited {completed.returncode}: {detail}"
            )
        self.event("successor_launch", "invoked_once", detail)

    def _validate_successor_marker(self, path: Path, schema: str, status: str) -> None:
        regular_file(path, "successor terminal marker")
        record = load_toml(path)
        require_fields(
            record,
            {
                "schema_version": schema,
                "experiment_id": self.succ_experiment,
                "queue_id": self.succ_queue_id,
                "status": status,
            },
            "successor terminal marker",
        )

    def confirm_successor(self) -> tuple[str, str]:
        started = time.monotonic()
        while True:
            if self.succ_completed.exists():
                self._validate_successor_marker(
                    self.succ_completed, self.succ_completion_schema, "complete_valid"
                )
                return "terminal", "QUEUE_COMPLETED.toml"
            if self.succ_failed.exists():
                self._validate_successor_marker(
                    self.succ_failed, self.succ_failure_schema, "failed_closed"
                )
                return "terminal", "QUEUE_FAILED.toml"
            if self.succ_progress.exists():
                regular_file(self.succ_progress, "successor progress")
                progress = load_toml(self.succ_progress)
                require_fields(
                    progress,
                    {
                        "schema_version": self.succ_progress_schema,
                        "experiment_id": self.succ_experiment,
                        "queue_id": self.succ_queue_id,
                    },
                    "successor progress",
                )
                return "progress", str(progress.get("status", "observed"))
            state = self.systemctl_show(self.succ_unit)
            if state["LoadState"] != "not-found":
                if state["ActiveState"] in ("active", "activating"):
                    return "service", "/".join(
                        (state["ActiveState"], state["SubState"], state["MainPID"])
                    )
            if time.monotonic() - started >= self.confirm_seconds:
                raise DispatchError("successor launch produced no service, progress, or terminal evidence")
            time.sleep(self.confirm_poll_seconds)

    def finish_dispatched(self, kind: str, detail: str) -> None:
        record = {
            "schema_version": "rq2-exact-map-update-001/dispatched-v1",
            "dispatcher_id": self.dispatcher_id,
            "status": "dispatched",
            "dispatched_utc": utc_now(),
            "configuration_sha256": self.config_sha256,
            "predecessor_unit": self.pred_unit,
            "successor_unit": self.succ_unit,
            "confirmation_kind": kind,
            "confirmation_detail": detail,
        }
        atomic_create(self.state_dir / "DISPATCHED.toml", render_flat_toml(record))
        self.event("dispatcher", "dispatched", f"{kind}:{detail}")

    def fail(self, error: BaseException) -> None:
        if any((self.state_dir / name).exists() for name in TERMINALS):
            return
        record = {
            "schema_version": "rq2-exact-map-update-001/dispatch-failure-v1",
            "dispatcher_id": self.dispatcher_id,
            "status": "failed_closed",
            "failed_utc": utc_now(),
            "configuration_sha256": self.config_sha256,
            "detail": str(error),
        }
        atomic_create(self.state_dir / "FAILED.toml", render_flat_toml(record))
        self.event("dispatcher", "failed_closed", str(error))

    def run(self) -> None:
        self.acquire()
        self.event("dispatcher", "start", self.dispatcher_id)
        self.await_predecessor()
        self.validate_predecessor()
        self.validate_successor()
        self.launch_successor_once()
        kind, detail = self.confirm_successor()
        self.finish_dispatched(kind, detail)


def main(arguments: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args(arguments)
    dispatcher: Dispatcher | None = None
    try:
        dispatcher = Dispatcher(args.config)
        dispatcher.run()
    except AlreadyAttempted as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    except (DispatchError, OSError, subprocess.SubprocessError, KeyError, ValueError) as error:
        if dispatcher is not None:
            try:
                dispatcher.fail(error)
            except (DispatchError, OSError, AlreadyAttempted) as terminal_error:
                print(f"ERROR writing failure marker: {terminal_error}", file=sys.stderr)
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(str(dispatcher.state_dir / "DISPATCHED.toml"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
