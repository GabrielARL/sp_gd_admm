#!/usr/bin/env python3
"""Fail-closed dispatcher for the v3-dependent parity-assignment experiment.

The controller is deliberately small and read-only with respect to the v3
scientific unit.  It only calls ``systemctl --user show`` while waiting.  Once
the unit is inactive, the controller requires configured terminal evidence,
invokes the hash-pinned v3 ``status_report.py assert-result`` gate, evaluates
the registered two-endpoint selection rule, and only then runs the configured
successor commands.

An invocation is a single attempt.  Durable progress from any earlier
invocation makes a later invocation fail; this program never resumes work or
overwrites attempt outputs.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from typing import Any, Iterable, Mapping, Sequence

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # pragma: no cover - Python 3.10 compatibility
    import tomli as tomllib  # type: ignore[no-redef]


SCHEMA = "rq2-gd-parity-assignment-refresh-001/conditional-controller-v1"
DECISION_SCHEMA = "rq2-safe-dispatch/prerequisite-v1"
PREREQUISITE_EXPERIMENT_ID = "RQ2-GD-OFFSET-SPLIT-001"
PREREQUISITE_ATTEMPT = "v3"
TERMINAL_NAMES = ("SELECTED.toml", "UNSELECTED.toml", "FAILED.toml")
PROGRESS_NAME = "progress.toml"
HISTORY_NAME = "status_history.tsv"
DECISION_NAME = "selection_decision.toml"
LOCK_NAME = ".controller.lock"
REGISTERED_REFERENCE_ARM = "objective0__bounds0"
REGISTERED_TREATMENT_ARM = "objective1__bounds0"
REGISTERED_ENDPOINTS = ("transmitted_word_equal", "parity_valid")
PHASE_ORDER = ("preflight", "freeze", "anchor", "package", "queue", "decision")
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")


class ControllerError(RuntimeError):
    """A fail-closed controller error."""


class AlreadyStarted(ControllerError):
    """The durable state proves this invocation would be a resume."""


class CommandFailed(ControllerError):
    """A trusted gate or configured successor command failed."""


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


def toml_quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def flat_toml(payload: Mapping[str, Any]) -> str:
    lines: list[str] = []
    for key in sorted(payload):
        if not re.fullmatch(r"[A-Za-z0-9_-]+", key):
            raise ControllerError(f"invalid flat TOML key: {key!r}")
        value = payload[key]
        if isinstance(value, bool):
            rendered = "true" if value else "false"
        elif isinstance(value, int):
            rendered = str(value)
        elif isinstance(value, float):
            rendered = repr(value)
        elif value is None:
            rendered = toml_quote("")
        else:
            rendered = toml_quote(str(value))
        lines.append(f"{key} = {rendered}")
    return "\n".join(lines) + "\n"


def decision_toml(
    payload: Mapping[str, Any],
    endpoints: Mapping[str, Mapping[str, Any]],
) -> str:
    """Render the prerequisite record expected by the production preflight gate."""

    rendered = flat_toml(payload).rstrip("\n")
    sections: list[str] = [rendered]
    for endpoint in REGISTERED_ENDPOINTS:
        record = endpoints.get(endpoint)
        if record is None:
            raise ControllerError(f"decision lacks endpoint record: {endpoint}")
        sections.append(f"[endpoints.{endpoint}]\n" + flat_toml(record).rstrip("\n"))
    return "\n\n".join(sections) + "\n"


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_replace(path: Path, text: str) -> None:
    """Atomically replace a mutable record and fsync its containing directory."""

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
        fsync_directory(path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def atomic_create(path: Path, text: str) -> None:
    """Atomically create an immutable record, refusing an existing destination."""

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
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise ControllerError(f"refusing to overwrite durable record: {path}") from error
        fsync_directory(path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def append_history(path: Path, row: Sequence[Any]) -> None:
    """Append one fsynced TSV record under the controller's exclusive lock."""

    path.parent.mkdir(parents=True, exist_ok=True)
    from io import StringIO

    buffer = StringIO()
    writer = csv.writer(buffer, delimiter="\t", lineterminator="\n")
    encoded_parts: list[bytes] = []
    if not path.exists() or path.stat().st_size == 0:
        writer.writerow(("utc", "state", "phase", "exit_code", "detail"))
        encoded_parts.append(buffer.getvalue().encode("utf-8"))
        buffer.seek(0)
        buffer.truncate(0)
    writer.writerow(row)
    encoded_parts.append(buffer.getvalue().encode("utf-8"))
    encoded = b"".join(encoded_parts)
    descriptor = os.open(path, os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o644)
    try:
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("short write while appending status history")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def resolve_path(config_path: Path, value: Any, name: str) -> Path:
    if not isinstance(value, str) or not value:
        raise ControllerError(f"{name} must be a nonempty path string")
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = config_path.parent / candidate
    return candidate.resolve(strict=False)


def string_list(value: Any, name: str, *, allow_empty: bool = False) -> list[str]:
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item for item in value
    ):
        raise ControllerError(f"{name} must be an array of nonempty strings")
    if not value and not allow_empty:
        raise ControllerError(f"{name} must not be empty")
    return list(value)


def require_regular_file(path: Path, name: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise ControllerError(f"{name} is missing, non-regular, or a symlink: {path}")


def parse_bool(value: str, *, column: str, frame: str, arm: str) -> bool:
    if value == "true":
        return True
    if value == "false":
        return False
    raise ControllerError(
        f"invalid {column} value for frame {frame}, arm {arm}: {value!r}"
    )


class Controller:
    def __init__(self, config_path: Path):
        self.config_path = config_path.resolve()
        require_regular_file(self.config_path, "controller configuration")
        self.config_sha256 = sha256_file(self.config_path)
        self.raw = load_toml(self.config_path)
        self.dispatcher_id = str(self.raw.get("dispatcher_id", ""))
        if not self.dispatcher_id:
            raise ControllerError("dispatcher_id is required")

        controller = self._table("controller")
        v3 = self._table("v3")
        selection = self._table("selection")
        safety = self._table("safety")
        commands = self._table("commands")

        self.state_dir = resolve_path(
            self.config_path, controller.get("state_dir"), "controller.state_dir"
        )
        self.poll_seconds = float(controller.get("poll_interval_seconds", 60.0))
        self.max_wait_seconds = float(controller.get("max_wait_seconds", 0.0))
        self.command_timeout_seconds = float(
            controller.get("command_timeout_seconds", 0.0)
        )
        if self.poll_seconds <= 0:
            raise ControllerError("controller.poll_interval_seconds must be positive")
        if self.max_wait_seconds < 0 or self.command_timeout_seconds < 0:
            raise ControllerError("wait and command timeouts must be nonnegative")
        cwd_value = controller.get("command_cwd", str(self.config_path.parent))
        self.command_cwd = resolve_path(
            self.config_path, cwd_value, "controller.command_cwd"
        )
        if not self.command_cwd.is_dir():
            raise ControllerError(f"command_cwd is not a directory: {self.command_cwd}")

        self.unit = str(v3.get("unit", ""))
        self.systemctl = str(v3.get("systemctl", "/usr/bin/systemctl"))
        if not self.unit or not self.systemctl:
            raise ControllerError("v3.unit and v3.systemctl are required")
        self.v3_result = resolve_path(
            self.config_path, v3.get("result"), "v3.result"
        )
        self.frames_csv = resolve_path(
            self.config_path,
            v3.get("frames_csv", str(self.v3_result / "frames.csv")),
            "v3.frames_csv",
        )
        self.status_helper = resolve_path(
            self.config_path, v3.get("status_helper"), "v3.status_helper"
        )
        self.status_python = str(v3.get("status_python", sys.executable))
        self.status_helper_sha256 = str(v3.get("status_helper_sha256", ""))
        if not HEX_SHA256.fullmatch(self.status_helper_sha256):
            raise ControllerError("v3.status_helper_sha256 must be 64 lowercase hex digits")
        self.required_terminal_files = [
            resolve_path(self.config_path, value, "v3.required_terminal_files")
            for value in string_list(
                v3.get("required_terminal_files"), "v3.required_terminal_files"
            )
        ]
        self.failure_terminal_files = [
            resolve_path(self.config_path, value, "v3.failure_terminal_files")
            for value in string_list(
                v3.get("failure_terminal_files", []),
                "v3.failure_terminal_files",
                allow_empty=True,
            )
        ]

        self.reference_arm = str(selection.get("reference_arm", ""))
        self.treatment_arm = str(selection.get("treatment_arm", ""))
        if self.reference_arm != REGISTERED_REFERENCE_ARM:
            raise ControllerError(
                "selection.reference_arm must preserve the registered control "
                f"{REGISTERED_REFERENCE_ARM}"
            )
        if self.treatment_arm != REGISTERED_TREATMENT_ARM:
            raise ControllerError(
                "selection.treatment_arm must preserve the registered treatment "
                f"{REGISTERED_TREATMENT_ARM}"
            )
        endpoints = tuple(
            string_list(selection.get("endpoints"), "selection.endpoints")
        )
        if endpoints != REGISTERED_ENDPOINTS:
            raise ControllerError(
                "selection.endpoints must be exactly transmitted_word_equal, parity_valid"
            )
        self.expected_cases = int(selection.get("expected_cases", 0))
        if self.expected_cases <= 0:
            raise ControllerError("selection.expected_cases must be positive")

        self.protected_outputs = [
            resolve_path(self.config_path, value, "safety.refuse_existing_paths")
            for value in string_list(
                safety.get("refuse_existing_paths"), "safety.refuse_existing_paths"
            )
        ]
        if any(path == self.state_dir for path in self.protected_outputs):
            raise ControllerError("state_dir must not be a protected successor output")

        trusted_successors = safety.get("trusted_successor_files")
        if not isinstance(trusted_successors, list) or not trusted_successors:
            raise ControllerError(
                "safety.trusted_successor_files must be a nonempty array of tables"
            )
        self.trusted_successor_files: list[tuple[Path, str]] = []
        for index, entry in enumerate(trusted_successors, start=1):
            if not isinstance(entry, dict):
                raise ControllerError(
                    f"safety.trusted_successor_files[{index}] must be a table"
                )
            path = resolve_path(
                self.config_path,
                entry.get("path"),
                f"safety.trusted_successor_files[{index}].path",
            )
            digest = str(entry.get("sha256", ""))
            if not HEX_SHA256.fullmatch(digest):
                raise ControllerError(
                    f"safety.trusted_successor_files[{index}].sha256 must be "
                    "64 lowercase hex digits"
                )
            self.trusted_successor_files.append((path, digest))
        if len({path for path, _ in self.trusted_successor_files}) != len(
            self.trusted_successor_files
        ):
            raise ControllerError("trusted successor paths must be unique")

        pipeline = commands.get("pipeline")
        individual_present = [phase for phase in PHASE_ORDER if phase in commands]
        if pipeline is not None:
            if individual_present:
                raise ControllerError(
                    "commands.pipeline is mutually exclusive with individual phase commands"
                )
            self.phase_commands = [
                ("pipeline", string_list(pipeline, "commands.pipeline"))
            ]
        else:
            missing = [phase for phase in PHASE_ORDER if phase not in commands]
            if missing:
                raise ControllerError(
                    "missing configured successor commands: " + ", ".join(missing)
                )
            self.phase_commands = [
                (phase, string_list(commands[phase], f"commands.{phase}"))
                for phase in PHASE_ORDER
            ]

        environment = self.raw.get("environment", {})
        if not isinstance(environment, dict):
            raise ControllerError("environment must be a TOML table")
        self.environment = {str(key): str(value) for key, value in environment.items()}
        self.started_utc = ""
        self.current_phase = "startup"
        self.lock_handle: Any = None

    def _table(self, name: str) -> dict[str, Any]:
        value = self.raw.get(name)
        if not isinstance(value, dict):
            raise ControllerError(f"[{name}] table is required")
        return value

    @property
    def progress_path(self) -> Path:
        return self.state_dir / PROGRESS_NAME

    @property
    def history_path(self) -> Path:
        return self.state_dir / HISTORY_NAME

    @property
    def decision_path(self) -> Path:
        return self.state_dir / DECISION_NAME

    def acquire_new_attempt(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.lock_handle = (self.state_dir / LOCK_NAME).open("a+")
        try:
            fcntl.flock(self.lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise AlreadyStarted("another controller process holds the attempt lock") from error

        durable = [
            self.progress_path,
            self.history_path,
            self.decision_path,
            *(self.state_dir / name for name in TERMINAL_NAMES),
        ]
        existing = [str(path) for path in durable if path.exists()]
        if existing:
            raise AlreadyStarted(
                "refusing automatic resume; durable controller state already exists: "
                + ", ".join(existing)
            )
        existing_outputs = [str(path) for path in self.protected_outputs if path.exists()]
        if existing_outputs:
            raise AlreadyStarted(
                "refusing to overwrite existing successor outputs: "
                + ", ".join(existing_outputs)
            )
        self.started_utc = utc_now()

    def release_lock(self) -> None:
        if self.lock_handle is not None:
            try:
                fcntl.flock(self.lock_handle.fileno(), fcntl.LOCK_UN)
            finally:
                self.lock_handle.close()
                self.lock_handle = None

    def record(
        self, state: str, phase: str, detail: str, exit_code: int = -1
    ) -> None:
        self.current_phase = phase
        now = utc_now()
        payload = {
            "schema_version": SCHEMA,
            "dispatcher_id": self.dispatcher_id,
            "state": state,
            "phase": phase,
            "detail": detail,
            "exit_code": exit_code,
            "process_id": os.getpid(),
            "started_utc": self.started_utc,
            "updated_utc": now,
            "v3_unit": self.unit,
            "controller_config_sha256": self.config_sha256,
        }
        atomic_replace(self.progress_path, flat_toml(payload))
        append_history(
            self.history_path, (now, state, phase, exit_code, detail)
        )

    def terminal(self, name: str, payload: Mapping[str, Any]) -> None:
        if name not in TERMINAL_NAMES:
            raise ControllerError(f"unknown terminal record: {name}")
        conflicts = [
            str(self.state_dir / other)
            for other in TERMINAL_NAMES
            if other != name and (self.state_dir / other).exists()
        ]
        if conflicts:
            raise ControllerError(
                "refusing conflicting terminal decision: " + ", ".join(conflicts)
            )
        complete_payload = {
            "schema_version": SCHEMA,
            "dispatcher_id": self.dispatcher_id,
            "controller_config_sha256": self.config_sha256,
            "recorded_utc": utc_now(),
            **payload,
        }
        atomic_create(self.state_dir / name, flat_toml(complete_payload))

    def poll_service_until_inactive(self) -> dict[str, str]:
        start = time.monotonic()
        poll_count = 0
        while True:
            failed_markers = [
                str(path) for path in self.failure_terminal_files if path.exists()
            ]
            if failed_markers:
                raise ControllerError(
                    "v3 failure terminal evidence exists: " + ", ".join(failed_markers)
                )
            command = [
                self.systemctl,
                "--user",
                "show",
                self.unit,
                "--property=LoadState",
                "--property=ActiveState",
                "--property=SubState",
                "--property=MainPID",
                "--no-pager",
            ]
            completed = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )
            if completed.returncode != 0:
                raise ControllerError(
                    "read-only systemctl show failed: "
                    + completed.stderr.strip()[:1000]
                )
            status: dict[str, str] = {}
            for line in completed.stdout.splitlines():
                if "=" in line:
                    key, value = line.split("=", 1)
                    status[key] = value
            required = ("ActiveState", "SubState", "MainPID")
            missing = [key for key in required if key not in status]
            if missing:
                raise ControllerError(
                    "systemctl show omitted required fields: " + ", ".join(missing)
                )
            try:
                main_pid = int(status["MainPID"])
            except ValueError as error:
                raise ControllerError(
                    f"systemctl returned malformed MainPID: {status['MainPID']!r}"
                ) from error
            active_state = status["ActiveState"]
            poll_count += 1
            detail = (
                f"poll={poll_count} ActiveState={active_state} "
                f"SubState={status['SubState']} MainPID={main_pid}"
            )
            if active_state == "inactive":
                if main_pid != 0:
                    raise ControllerError(
                        f"v3 reports inactive with nonzero MainPID {main_pid}"
                    )
                self.record("validating", "v3_inactive", detail)
                return status
            if active_state == "failed":
                raise ControllerError(f"v3 scientific unit failed: {detail}")
            if active_state not in {
                "active",
                "activating",
                "deactivating",
                "reloading",
            }:
                raise ControllerError(f"unexpected v3 service state: {detail}")
            self.record("waiting", "wait_v3", detail)
            if self.max_wait_seconds and time.monotonic() - start >= self.max_wait_seconds:
                raise ControllerError(
                    f"v3 did not become inactive within {self.max_wait_seconds:g} seconds"
                )
            time.sleep(self.poll_seconds)

    def require_terminal_evidence(self) -> dict[str, str]:
        evidence: dict[str, str] = {}
        for index, path in enumerate(self.required_terminal_files, start=1):
            require_regular_file(path, f"v3 terminal evidence {index}")
            evidence[f"terminal_{index}_path"] = str(path)
            evidence[f"terminal_{index}_sha256"] = sha256_file(path)
        self.record(
            "validating",
            "terminal_evidence",
            f"verified {len(evidence) // 2} required terminal files",
        )
        return evidence

    def run_logged_command(
        self,
        phase: str,
        argv: Sequence[str],
        *,
        trusted_gate: bool = False,
    ) -> None:
        log_dir = self.state_dir / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        log_path = log_dir / f"{phase}.log"
        if log_path.exists():
            raise AlreadyStarted(f"refusing to overwrite command log: {log_path}")
        rendered = self.render_command(argv)
        self.record(
            "validating" if trusted_gate else "running",
            phase,
            "starting hash-pinned v3 result gate"
            if trusted_gate
            else f"starting configured {phase} command",
        )
        environment = os.environ.copy()
        environment.update(self.environment)
        timeout = self.command_timeout_seconds or None
        with log_path.open("x", encoding="utf-8", newline="") as handle:
            handle.write("argv=" + json.dumps(rendered, ensure_ascii=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
            try:
                completed = subprocess.run(
                    rendered,
                    cwd=self.command_cwd,
                    env=environment,
                    stdout=handle,
                    stderr=subprocess.STDOUT,
                    text=True,
                    check=False,
                    timeout=timeout,
                )
            except subprocess.TimeoutExpired as error:
                raise CommandFailed(
                    f"{phase} exceeded configured timeout {timeout:g}s; see {log_path}"
                ) from error
        if completed.returncode != 0:
            raise CommandFailed(
                f"{phase} exited {completed.returncode}; see {log_path}"
            )
        self.record(
            "validating" if trusted_gate else "running",
            phase,
            f"completed with exit code 0; log={log_path}",
            0,
        )

    def render_command(self, argv: Sequence[str]) -> list[str]:
        replacements = {
            "{config_dir}": str(self.config_path.parent),
            "{state_dir}": str(self.state_dir),
            "{decision_record}": str(self.decision_path),
            "{v3_result}": str(self.v3_result),
            "{frames_csv}": str(self.frames_csv),
        }
        rendered: list[str] = []
        for argument in argv:
            value = argument
            for token, replacement in replacements.items():
                value = value.replace(token, replacement)
            if not value:
                raise ControllerError("a configured command rendered an empty argument")
            rendered.append(value)
        return rendered

    def validate_v3_result(self) -> None:
        require_regular_file(self.status_helper, "trusted v3 status helper")
        actual_hash = sha256_file(self.status_helper)
        if actual_hash != self.status_helper_sha256:
            raise ControllerError(
                "trusted v3 status-helper hash mismatch: "
                f"expected {self.status_helper_sha256}, found {actual_hash}"
            )
        command = [
            self.status_python,
            str(self.status_helper),
            "assert-result",
            "--result",
            str(self.v3_result),
            "--stage",
            "heldout",
        ]
        self.run_logged_command("v3_result_validation", command, trusted_gate=True)

    def result_evidence(self) -> dict[str, str]:
        """Bind the selected/unselected decision to exact validated v3 files."""

        evidence_paths = {
            "completion_sha256": self.v3_result / "COMPLETED.toml",
            "manifest_sha256": self.v3_result / "manifest.toml",
            "science_sha256": self.v3_result / "science.json",
            "aggregate_sha256": self.v3_result / "aggregate.csv",
            "checksum_manifest_sha256": self.v3_result / "MANIFEST.sha256",
        }
        evidence: dict[str, str] = {}
        for field, path in evidence_paths.items():
            require_regular_file(path, f"validated v3 evidence {field}")
            evidence[field] = sha256_file(path)
        self.record(
            "validating",
            "result_evidence",
            "bound completion, manifest, science, aggregate, and checksum manifest",
            0,
        )
        return evidence

    def verify_successor_trust(self) -> None:
        """Rehash every delayed successor program immediately before execution."""

        for index, (path, expected) in enumerate(
            self.trusted_successor_files, start=1
        ):
            require_regular_file(path, f"trusted successor file {index}")
            actual = sha256_file(path)
            if actual != expected:
                raise ControllerError(
                    "trusted successor hash mismatch: "
                    f"path={path}, expected={expected}, found={actual}"
                )
        self.record(
            "validating",
            "successor_trust",
            f"verified {len(self.trusted_successor_files)} pinned successor files",
            0,
        )

    def evaluate_selection(
        self, result_evidence: Mapping[str, str]
    ) -> tuple[bool, dict[str, Any]]:
        require_regular_file(self.frames_csv, "validated v3 frame table")
        values: dict[str, dict[str, dict[str, bool]]] = {
            self.reference_arm: {},
            self.treatment_arm: {},
        }
        with self.frames_csv.open(newline="", encoding="utf-8") as handle:
            reader = csv.DictReader(handle)
            required = {"frame", "arm", *REGISTERED_ENDPOINTS}
            if reader.fieldnames is None or not required.issubset(reader.fieldnames):
                raise ControllerError(
                    "v3 frame table lacks registered selection columns: "
                    + ", ".join(sorted(required))
                )
            for row in reader:
                arm = row["arm"]
                if arm not in values:
                    continue
                frame = row["frame"]
                if not frame:
                    raise ControllerError("v3 frame table contains an empty frame identifier")
                if frame in values[arm]:
                    raise ControllerError(
                        f"duplicate v3 frame/arm row: frame={frame}, arm={arm}"
                    )
                values[arm][frame] = {
                    endpoint: parse_bool(
                        row[endpoint], column=endpoint, frame=frame, arm=arm
                    )
                    for endpoint in REGISTERED_ENDPOINTS
                }

        reference_frames = set(values[self.reference_arm])
        treatment_frames = set(values[self.treatment_arm])
        if reference_frames != treatment_frames:
            missing_reference = sorted(treatment_frames - reference_frames)
            missing_treatment = sorted(reference_frames - treatment_frames)
            raise ControllerError(
                "selected v3 arms do not cover identical frame IDs; "
                f"missing_reference={missing_reference[:5]}, "
                f"missing_treatment={missing_treatment[:5]}"
            )
        if len(reference_frames) != self.expected_cases:
            raise ControllerError(
                f"v3 selection has {len(reference_frames)} paired cases, "
                f"expected {self.expected_cases}"
            )

        detail: dict[str, Any] = {
            "schema_version": DECISION_SCHEMA,
            "dispatcher_id": self.dispatcher_id,
            "controller_config_sha256": self.config_sha256,
            "recorded_utc": utc_now(),
            "experiment_id": PREREQUISITE_EXPERIMENT_ID,
            "attempt": PREREQUISITE_ATTEMPT,
            "reference_arm": self.reference_arm,
            "treatment_arm": self.treatment_arm,
            "paired_cases": len(reference_frames),
            "comparison": "treatment_only strictly greater than reference_only for both endpoints",
            "result": str(self.v3_result),
            "frames_csv": str(self.frames_csv),
            "frames_csv_sha256": sha256_file(self.frames_csv),
            "v3_status_helper_sha256": self.status_helper_sha256,
            "deterministic_replay_passed": True,
            **result_evidence,
        }
        endpoint_records: dict[str, dict[str, Any]] = {}
        selected = True
        for endpoint in REGISTERED_ENDPOINTS:
            treatment_only = sum(
                values[self.treatment_arm][frame][endpoint]
                and not values[self.reference_arm][frame][endpoint]
                for frame in reference_frames
            )
            reference_only = sum(
                values[self.reference_arm][frame][endpoint]
                and not values[self.treatment_arm][frame][endpoint]
                for frame in reference_frames
            )
            endpoint_passed = treatment_only > reference_only
            selected = selected and endpoint_passed
            detail[f"{endpoint}_treatment_arm"] = self.treatment_arm
            detail[f"{endpoint}_reference_arm"] = self.reference_arm
            detail[f"{endpoint}_treatment_only"] = treatment_only
            detail[f"{endpoint}_reference_only"] = reference_only
            detail[f"{endpoint}_passed"] = endpoint_passed
            endpoint_records[endpoint] = {
                "treatment_arm": self.treatment_arm,
                "reference_arm": self.reference_arm,
                "treatment_only_success": treatment_only,
                "reference_only_success": reference_only,
                "passed": endpoint_passed,
            }
        detail["selected"] = selected
        detail["state"] = "selected" if selected else "unselected"
        detail["passed"] = selected
        detail["selection_rule_passed"] = selected
        detail["decision"] = detail["state"]
        detail["reason"] = (
            "registered parity-calculation branch-selection rule passed"
            if selected
            else "registered parity-calculation branch-selection rule did not pass"
        )
        atomic_create(self.decision_path, decision_toml(detail, endpoint_records))
        self.record(
            "selected" if selected else "unselected",
            "selection_rule",
            str(detail["reason"]),
            0,
        )
        return selected, detail

    def run(self) -> int:
        self.acquire_new_attempt()
        try:
            self.record("starting", "startup", "new non-resumable attempt acquired")
            service_status = self.poll_service_until_inactive()
            terminal_evidence = self.require_terminal_evidence()
            self.validate_v3_result()
            result_evidence = self.result_evidence()
            selected, decision = self.evaluate_selection(result_evidence)
            if not selected:
                self.terminal(
                    "UNSELECTED.toml",
                    {
                        "state": "complete_unselected",
                        "exit_code": 0,
                        "detail": decision["reason"],
                        "decision_sha256": sha256_file(self.decision_path),
                        "v3_active_state": service_status["ActiveState"],
                        **terminal_evidence,
                    },
                )
                self.record(
                    "complete_unselected",
                    "terminal",
                    "no successor command was run",
                    0,
                )
                return 0

            # This check is repeated immediately before successor work so a
            # concurrently created attempt output cannot be overwritten.
            self.verify_successor_trust()
            existing_outputs = [
                str(path) for path in self.protected_outputs if path.exists()
            ]
            if existing_outputs:
                raise AlreadyStarted(
                    "successor outputs appeared before launch; refusing overwrite: "
                    + ", ".join(existing_outputs)
                )
            for phase, command in self.phase_commands:
                self.run_logged_command(phase, command)
            self.terminal(
                "SELECTED.toml",
                {
                    "state": "complete_selected",
                    "exit_code": 0,
                    "detail": "registered branch selected; configured successor pipeline completed",
                    "decision_sha256": sha256_file(self.decision_path),
                    "v3_active_state": service_status["ActiveState"],
                    "successor_phase_count": len(self.phase_commands),
                    "trusted_successor_file_count": len(
                        self.trusted_successor_files
                    ),
                    **terminal_evidence,
                },
            )
            self.record(
                "complete_selected",
                "terminal",
                "configured successor pipeline completed",
                0,
            )
            return 0
        except Exception as error:
            if not any((self.state_dir / name).exists() for name in TERMINAL_NAMES):
                try:
                    self.terminal(
                        "FAILED.toml",
                        {
                            "state": "failed",
                            "exit_code": 2,
                            "phase": self.current_phase,
                            "detail": str(error),
                            "decision_sha256": (
                                sha256_file(self.decision_path)
                                if self.decision_path.is_file()
                                else ""
                            ),
                        },
                    )
                    self.record("failed", self.current_phase, str(error), 2)
                except Exception as marker_error:
                    print(
                        f"ERROR: {error}; additionally failed to record terminal state: "
                        f"{marker_error}",
                        file=sys.stderr,
                    )
                    return 2
            print(f"ERROR: {error}", file=sys.stderr)
            return 2
        finally:
            self.release_lock()


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--config", required=True, type=Path)
    return result


def main(argv: Iterable[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        controller = Controller(args.config)
        return controller.run()
    except AlreadyStarted as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    except Exception as error:
        print(f"ERROR: invalid controller configuration or startup: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
