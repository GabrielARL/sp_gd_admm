#!/usr/bin/env python3

"""Build the fail-closed preflight record for the assignment factorial.

The production gate is a controller-written prerequisite TOML.  The builder
binds that decision back to the completed v3 result before running any test.
Only then does it run the Julia, budget, and queue-governance suites and
atomically finalize the existing preflight record.
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
from typing import Any, Mapping, Sequence

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # Python 3.10 on the registered host
    import tomli as tomllib  # type: ignore[no-redef]


EXPERIMENT_ID = "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001"
PREREQUISITE_EXPERIMENT_ID = "RQ2-GD-OFFSET-SPLIT-001"
PREREQUISITE_SCHEMA = (
    "rq2-gd-parity-assignment-refresh-001/prerequisite-selection-v1"
)
STRICT_PREREQUISITE_SCHEMA = "rq2-safe-dispatch/prerequisite-v1"
SELECTION_CONTRAST = "objective_use_given_bounds0"
TREATMENT_ARM = "objective1__bounds0"
REFERENCE_ARM = "objective0__bounds0"
ENDPOINTS = ("transmitted_word_equal", "parity_valid")
EXPECTED_BUDGET_TESTS = 4
EXPECTED_QUEUE_TESTS = 13

FIELD_ORDER = (
    "validation_status",
    "validated_utc",
    "test_exit_code",
    "test_assertions_passed",
    "test_assertions_total",
    "budget_test_exit_code",
    "budget_tests_passed",
    "budget_tests_total",
    "queue_test_exit_code",
    "queue_tests_passed",
    "queue_tests_total",
    "prerequisite_evidence_sha256",
    "config_sha256",
    "card_sha256",
    "runner_sha256",
    "test_sha256",
    "budget_tool_sha256",
    "budget_test_sha256",
    "queue_status_sha256",
    "queue_lock_tool_sha256",
    "anchor_wrapper_sha256",
    "queue_wrapper_sha256",
    "queue_template_sha256",
    "queue_readme_template_sha256",
    "queue_test_sha256",
    "split_runner_sha256",
    "legacy_runner_sha256",
    "registered_endpoint_frames_executed_during_preflight",
)

HASH_PATHS = {
    "config_sha256": "config.toml",
    "card_sha256": "experiment_card.md",
    "runner_sha256": "rq2_gd_parity_assignment_refresh_001.jl",
    "test_sha256": "test_rq2_gd_parity_assignment_refresh_001.jl",
    "budget_tool_sha256": "queue_tools/derive_budget.py",
    "budget_test_sha256": "queue_tools/test_derive_budget.py",
    "queue_status_sha256": "queue_tools/status_report.py",
    "queue_lock_tool_sha256": "queue_tools/lock_queue_package.py",
    "anchor_wrapper_sha256": "queue_tools/run_anchor_once.sh",
    "queue_wrapper_sha256": "queue_tools/run_queue.sh",
    "queue_template_sha256": "queue_tools/queue_template.toml",
    "queue_readme_template_sha256":
        "queue_tools/QUEUE_PACKAGE_README.template.md",
    "queue_test_sha256": "queue_tools/test_queue_tools.py",
    "split_runner_sha256":
        "vendor/rq2_gd_offset_split_001/rq2_gd_offset_split_001.jl",
    "legacy_runner_sha256":
        "vendor/rq2_gd_state_use_001/rq2_gd_state_use_001.jl",
}

ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
FIELD_LINE = re.compile(r"^([a-z][a-z0-9_]*)[ ]*:[ ]*(\S+)[ ]*$")
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")


class GateError(RuntimeError):
    """A fail-closed gate did not pass."""


@dataclass(frozen=True)
class CommandResult:
    command: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str

    @property
    def combined_output(self) -> str:
        return self.stdout + ("\n" if self.stdout and self.stderr else "") + self.stderr


@dataclass(frozen=True)
class SuiteResult:
    command_result: CommandResult
    passed: int
    total: int


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_toml(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise GateError(f"required regular TOML file is missing: {path}")
    try:
        with path.open("rb") as stream:
            return tomllib.load(stream)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise GateError(f"cannot parse TOML {path}: {error}") from error


def require_bool(value: Any, label: str) -> None:
    if value is not True:
        raise GateError(f"{label} must be true")


def require_sha256(value: Any, label: str) -> str:
    text = str(value)
    if HEX_SHA256.fullmatch(text) is None:
        raise GateError(f"{label} is not a lowercase SHA-256 digest")
    return text


def parse_checksum_manifest(path: Path) -> dict[str, str]:
    records: dict[str, str] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line:
            continue
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\x00]+)", line)
        if match is None:
            raise GateError(f"malformed checksum row {number} in {path}")
        digest, relative = match.groups()
        if relative in records:
            raise GateError(f"duplicate checksum path in {path}: {relative}")
        candidate = Path(relative)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise GateError(f"unsafe checksum path in {path}: {relative}")
        records[relative] = digest
    return records


def verify_result_checksum_manifest(result: Path) -> None:
    manifest_path = result / "MANIFEST.sha256"
    records = parse_checksum_manifest(manifest_path)
    required = {
        "COMPLETED.toml", "aggregate.csv", "manifest.toml", "science.json"
    }
    if not required.issubset(records):
        missing = ", ".join(sorted(required - set(records)))
        raise GateError(f"result checksum manifest omits terminal evidence: {missing}")
    for relative, expected in records.items():
        target = result / relative
        if not target.is_file() or target.is_symlink():
            raise GateError(f"checksum target is missing or a symlink: {target}")
        if sha256_file(target) != expected:
            raise GateError(f"checksum mismatch: {target}")


def aggregate_selection_rows(path: Path) -> dict[str, dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream)
        required = {
            "endpoint", "contrast_id", "treatment_arm", "reference_arm",
            "treatment_only_success", "reference_only_success",
        }
        if reader.fieldnames is None or not required.issubset(reader.fieldnames):
            raise GateError("aggregate.csv lacks the registered selection columns")
        selected: dict[str, dict[str, str]] = {}
        for row in reader:
            if (row["endpoint"] in ENDPOINTS and
                    row["contrast_id"] == SELECTION_CONTRAST):
                endpoint = row["endpoint"]
                if endpoint in selected:
                    raise GateError(f"duplicate aggregate selection row: {endpoint}")
                selected[endpoint] = row
    if set(selected) != set(ENDPOINTS):
        raise GateError("aggregate.csv lacks one or both registered endpoint rows")
    return selected


def verify_prerequisite_record(path: Path) -> dict[str, Any]:
    record = read_toml(path)
    schema = record.get("schema_version")
    if schema not in {PREREQUISITE_SCHEMA, STRICT_PREREQUISITE_SCHEMA}:
        raise GateError("unsupported prerequisite decision schema")
    if record.get("experiment_id") != PREREQUISITE_EXPERIMENT_ID:
        raise GateError("prerequisite decision names the wrong experiment")
    if record.get("attempt") != "v3":
        raise GateError("prerequisite decision is not for attempt v3")
    if record.get("state") != "selected":
        raise GateError("the v3 parity-calculation branch was not selected")
    require_bool(record.get("passed"), "prerequisite passed")
    if schema == STRICT_PREREQUISITE_SCHEMA:
        require_bool(
            record.get("deterministic_replay_passed"),
            "prerequisite deterministic_replay_passed",
        )
        require_bool(record.get("selection_rule_passed"), "selection_rule_passed")

    result_value = record.get("result")
    if not isinstance(result_value, str) or not result_value:
        raise GateError("prerequisite record lacks an absolute result path")
    result = Path(result_value)
    if not result.is_absolute() or not result.is_dir() or result.is_symlink():
        raise GateError("prerequisite result must be an existing regular directory")
    evidence_paths = {
        "completion_sha256": result / "COMPLETED.toml",
        "manifest_sha256": result / "manifest.toml",
        "science_sha256": result / "science.json",
        "aggregate_sha256": result / "aggregate.csv",
        "checksum_manifest_sha256": result / "MANIFEST.sha256",
    }
    for field, evidence_path in evidence_paths.items():
        expected = require_sha256(record.get(field), field)
        if not evidence_path.is_file() or evidence_path.is_symlink():
            raise GateError(f"missing terminal evidence: {evidence_path}")
        if sha256_file(evidence_path) != expected:
            raise GateError(f"prerequisite evidence hash mismatch: {field}")

    completion = read_toml(evidence_paths["completion_sha256"])
    manifest = read_toml(evidence_paths["manifest_sha256"])
    if completion.get("experiment_id") != PREREQUISITE_EXPERIMENT_ID:
        raise GateError("completion record names the wrong experiment")
    if manifest.get("experiment_id") != PREREQUISITE_EXPERIMENT_ID:
        raise GateError("result manifest names the wrong experiment")
    if completion.get("stage") != "heldout" or manifest.get("stage") != "heldout":
        raise GateError("prerequisite terminal evidence is not the held-out stage")
    if completion.get("status") != "complete_valid":
        raise GateError("prerequisite did not complete validly")
    require_bool(completion.get("correctness_passed"), "correctness_passed")
    require_bool(
        completion.get("deterministic_replay_passed"),
        "completion deterministic_replay_passed",
    )
    if completion.get("science_sha256") != record["science_sha256"]:
        raise GateError("completion does not bind the recorded science hash")
    if completion.get("manifest_sha256") != record["manifest_sha256"]:
        raise GateError("completion does not bind the recorded manifest hash")
    verify_result_checksum_manifest(result)

    aggregate_rows = aggregate_selection_rows(evidence_paths["aggregate_sha256"])
    for endpoint in ENDPOINTS:
        if schema == PREREQUISITE_SCHEMA:
            treatment_arm = record.get(
                f"{endpoint}_treatment_arm", record.get("treatment_arm"))
            reference_arm = record.get(
                f"{endpoint}_reference_arm", record.get("reference_arm"))
            recorded_treatment = record.get(f"{endpoint}_treatment_only")
            recorded_reference = record.get(f"{endpoint}_reference_only")
        else:
            endpoint_records = record.get("endpoints")
            if not isinstance(endpoint_records, dict):
                raise GateError("prerequisite record lacks endpoint decisions")
            endpoint_record = endpoint_records.get(endpoint)
            if not isinstance(endpoint_record, dict):
                raise GateError(f"missing prerequisite endpoint record: {endpoint}")
            treatment_arm = endpoint_record.get("treatment_arm")
            reference_arm = endpoint_record.get("reference_arm")
            recorded_treatment = endpoint_record.get("treatment_only_success")
            recorded_reference = endpoint_record.get("reference_only_success")
        if treatment_arm != TREATMENT_ARM:
            raise GateError(f"wrong treatment arm for {endpoint}")
        if reference_arm != REFERENCE_ARM:
            raise GateError(f"wrong reference arm for {endpoint}")
        row = aggregate_rows[endpoint]
        if row["treatment_arm"] != TREATMENT_ARM:
            raise GateError(f"aggregate treatment arm mismatch for {endpoint}")
        if row["reference_arm"] != REFERENCE_ARM:
            raise GateError(f"aggregate reference arm mismatch for {endpoint}")
        try:
            if (isinstance(recorded_treatment, bool) or
                    isinstance(recorded_reference, bool)):
                raise ValueError
            recorded_treatment = int(recorded_treatment)
            recorded_reference = int(recorded_reference)
            actual_treatment = int(row["treatment_only_success"])
            actual_reference = int(row["reference_only_success"])
        except (KeyError, TypeError, ValueError) as error:
            raise GateError(f"invalid selection counts for {endpoint}") from error
        if (recorded_treatment, recorded_reference) != (
                actual_treatment, actual_reference):
            raise GateError(f"selection counts do not match aggregate.csv for {endpoint}")
        if actual_treatment <= actual_reference:
            raise GateError(f"selection rule failed for {endpoint}")
    return record


def verify_prerequisite_command(command: Sequence[str], cwd: Path) -> dict[str, Any]:
    result = run_command(command, cwd)
    emit_command_result("prerequisite", result)
    if result.returncode != 0:
        raise GateError(f"prerequisite command exited {result.returncode}")
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if not lines:
        raise GateError("prerequisite command emitted no JSON decision")
    try:
        decision = json.loads(lines[-1])
    except json.JSONDecodeError as error:
        raise GateError("prerequisite command's last stdout line is not JSON") from error
    if not isinstance(decision, dict):
        raise GateError("prerequisite command decision is not an object")
    if decision.get("state") != "selected" or decision.get("passed") is not True:
        raise GateError("prerequisite command did not select the branch")
    return decision


def prerequisite_evidence_sha256(record: Mapping[str, Any]) -> str:
    """Hash only stable v3 evidence and registered paired counts."""

    stable: dict[str, Any] = {
        key: record.get(key)
        for key in (
            "experiment_id", "attempt", "result", "completion_sha256",
            "manifest_sha256", "science_sha256", "aggregate_sha256",
            "checksum_manifest_sha256",
        )
    }
    endpoints = record.get("endpoints")
    if isinstance(endpoints, dict):
        stable["endpoints"] = {
            endpoint: {
                key: endpoints.get(endpoint, {}).get(key)
                for key in (
                    "treatment_arm", "reference_arm", "treatment_only_success",
                    "reference_only_success", "passed",
                )
            }
            for endpoint in ENDPOINTS
        }
    else:
        stable["treatment_arm"] = record.get("treatment_arm")
        stable["reference_arm"] = record.get("reference_arm")
        for endpoint in ENDPOINTS:
            stable[f"{endpoint}_treatment_only"] = record.get(
                f"{endpoint}_treatment_only"
            )
            stable[f"{endpoint}_reference_only"] = record.get(
                f"{endpoint}_reference_only"
            )
    encoded = json.dumps(
        stable, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def run_command(command: Sequence[str], cwd: Path) -> CommandResult:
    if not command:
        raise GateError("empty command")
    environment = os.environ.copy()
    environment.update({
        "JULIA_NUM_THREADS": "1",
        "OMP_NUM_THREADS": "1",
        "OPENBLAS_NUM_THREADS": "1",
        "MKL_NUM_THREADS": "1",
        "BLAS_NUM_THREADS": "1",
    })
    try:
        completed = subprocess.run(
            list(command), cwd=cwd, env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        return CommandResult(
            tuple(command), completed.returncode,
            completed.stdout, completed.stderr,
        )
    except OSError as error:
        return CommandResult(tuple(command), 127, "", f"{type(error).__name__}: {error}\n")


def emit_command_result(label: str, result: CommandResult) -> None:
    print(f"[{label}] command: {shlex.join(result.command)}", file=sys.stderr)
    if result.stdout:
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n")
    if result.stderr:
        print(result.stderr, end="" if result.stderr.endswith("\n") else "\n",
              file=sys.stderr)
    print(f"[{label}] exit_code={result.returncode}", file=sys.stderr)


def parse_julia_test_counts(output: str) -> tuple[int, int]:
    lines = ANSI_ESCAPE.sub("", output).splitlines()
    candidates: list[tuple[int, int]] = []
    for index, line in enumerate(lines):
        if "Test Summary:" not in line or "|" not in line:
            continue
        columns = line.split("|", 1)[1].split()
        count_columns = [column for column in columns if column != "Time"]
        if "Pass" not in count_columns or "Total" not in count_columns:
            continue
        for row in lines[index + 1:]:
            if not row.strip():
                continue
            if "Test Summary:" in row:
                break
            if "|" not in row:
                continue
            values = re.findall(r"(?<![.\w])\d+(?![.\w])", row.split("|", 1)[1])
            if len(values) < len(count_columns):
                continue
            mapped = dict(zip(count_columns, map(int, values)))
            candidates.append((mapped["Pass"], mapped["Total"]))
            break
    if not candidates:
        return 0, 0
    return candidates[-1]


def parse_unittest_counts(output: str) -> tuple[int, int]:
    cleaned = ANSI_ESCAPE.sub("", output)
    matches = list(re.finditer(r"Ran\s+(\d+)\s+tests?\b", cleaned))
    if not matches:
        return 0, 0
    total = int(matches[-1].group(1))
    tail = cleaned[matches[-1].end():]
    failures = errors = skipped = unexpected = 0
    failed = re.search(r"FAILED\s*\(([^)]*)\)", tail)
    if failed is not None:
        for name, value in re.findall(r"(failures|errors|skipped|unexpected successes)=(\d+)",
                                      failed.group(1)):
            if name == "failures":
                failures = int(value)
            elif name == "errors":
                errors = int(value)
            elif name == "skipped":
                skipped = int(value)
            else:
                unexpected = int(value)
    else:
        skipped_match = re.search(r"OK\s*\(([^)]*)\)", tail)
        if skipped_match is not None:
            match = re.search(r"skipped=(\d+)", skipped_match.group(1))
            skipped = int(match.group(1)) if match else 0
    passed = max(0, total - failures - errors - skipped - unexpected)
    return passed, total


def run_suite(command: Sequence[str], cwd: Path, kind: str) -> SuiteResult:
    result = run_command(command, cwd)
    emit_command_result(kind, result)
    counts = (parse_julia_test_counts(result.combined_output)
              if kind == "julia" else
              parse_unittest_counts(result.combined_output))
    return SuiteResult(result, *counts)


def experiment_root(repo_root: Path) -> Path:
    return repo_root / "experiments" / "rq2_gd_parity_assignment_refresh_001"


def source_hashes(root: Path) -> dict[str, str]:
    hashes: dict[str, str] = {}
    for field, relative in HASH_PATHS.items():
        path = root / relative
        if not path.is_file() or path.is_symlink():
            raise GateError(f"preflight hash source is missing or a symlink: {path}")
        hashes[field] = sha256_file(path)
    return hashes


def default_julia_command(root: Path) -> list[str]:
    split_config = read_toml(root / "vendor/rq2_gd_offset_split_001/config.toml")
    try:
        project = Path(str(split_config["sources"]["jade_project_repo"]))
    except (KeyError, TypeError) as error:
        raise GateError("vendored split config lacks sources.jade_project_repo") from error
    if not (project / "Project.toml").is_file():
        raise GateError(f"Julia project is missing: {project / 'Project.toml'}")
    return [
        "julia", "--startup-file=no", "--history-file=no",
        f"--project={project}",
        str(root / "test_rq2_gd_parity_assignment_refresh_001.jl"),
    ]


def parse_command(value: str | None, default: Sequence[str]) -> list[str]:
    return list(default) if value is None else shlex.split(value)


def current_preflight_status(path: Path) -> tuple[str, str, os.stat_result]:
    if not path.is_file() or path.is_symlink():
        raise GateError(f"preflight record is missing or a symlink: {path}")
    text = path.read_text(encoding="utf-8")
    statuses = [match.group(2) for line in text.splitlines()
                if (match := FIELD_LINE.fullmatch(line)) is not None and
                match.group(1) == "validation_status"]
    if len(statuses) != 1:
        raise GateError("preflight record must contain one validation_status field")
    if statuses[0] not in {"not_run", "pending", "pass", "fail"}:
        raise GateError(f"unsupported preflight status {statuses[0]!r}")
    return statuses[0], text, path.stat()


def metadata_fields(text: str) -> dict[str, str]:
    lines = text.splitlines()
    start = next(
        (index for index, line in enumerate(lines) if line.startswith("validation_status:")),
        None,
    )
    if start is None:
        raise GateError("preflight metadata block is missing")
    end = next(
        (index for index, line in enumerate(lines[start:], start) if not line.strip()),
        None,
    )
    if end is None:
        raise GateError("preflight metadata block has no narrative separator")
    parsed: dict[str, str] = {}
    order: list[str] = []
    for line in lines[start:end]:
        match = FIELD_LINE.fullmatch(line)
        if match is None:
            raise GateError("preflight metadata block contains an invalid row")
        key, value = match.groups()
        if key in parsed:
            raise GateError(f"duplicate preflight metadata field: {key}")
        order.append(key)
        parsed[key] = value
    if tuple(order) != FIELD_ORDER:
        raise GateError("preflight metadata field order or inventory changed")
    return parsed


def verify_reusable_pass(
    text: str,
    *,
    current_hashes: Mapping[str, str],
    prerequisite_binding: str,
) -> None:
    fields = metadata_fields(text)
    expected = {
        "validation_status": "pass",
        "test_exit_code": "0",
        "budget_test_exit_code": "0",
        "budget_tests_passed": str(EXPECTED_BUDGET_TESTS),
        "budget_tests_total": str(EXPECTED_BUDGET_TESTS),
        "queue_test_exit_code": "0",
        "queue_tests_passed": str(EXPECTED_QUEUE_TESTS),
        "queue_tests_total": str(EXPECTED_QUEUE_TESTS),
        "prerequisite_evidence_sha256": prerequisite_binding,
        "registered_endpoint_frames_executed_during_preflight": "0",
        **current_hashes,
    }
    mismatches = {
        key: (expected_value, fields.get(key, "missing"))
        for key, expected_value in expected.items()
        if fields.get(key) != expected_value
    }
    try:
        assertions_passed = int(fields["test_assertions_passed"])
        assertions_total = int(fields["test_assertions_total"])
    except (KeyError, ValueError) as error:
        raise GateError("passed preflight has invalid Julia assertion counts") from error
    if assertions_passed <= 0 or assertions_passed != assertions_total:
        mismatches["julia_assertions"] = (
            "nonzero and complete", f"{assertions_passed}/{assertions_total}"
        )
    if mismatches:
        raise GateError(
            "passed preflight cannot be reused because its evidence changed: "
            + repr(mismatches)
        )


def render_preflight(original: str, fields: Mapping[str, str]) -> str:
    lines = original.splitlines(keepends=True)
    if not lines or not lines[0].startswith("# Preflight record"):
        raise GateError("unexpected preflight title")
    start = next((index for index, line in enumerate(lines[1:], 1)
                  if line.startswith("validation_status:")), None)
    if start is None:
        raise GateError("preflight metadata block is missing")
    end = next((index for index, line in enumerate(lines[start:], start)
                if not line.strip()), None)
    if end is None:
        raise GateError("preflight record has no narrative separator")
    existing: list[str] = []
    for line in lines[start:end]:
        match = FIELD_LINE.fullmatch(line.rstrip("\r\n"))
        if match is None:
            raise GateError("preflight metadata block contains an invalid row")
        existing.append(match.group(1))
    if tuple(existing) != FIELD_ORDER:
        raise GateError("preflight metadata field order or inventory changed")
    metadata = "".join(f"{key}: {fields[key]}\n" for key in FIELD_ORDER)
    return "".join(lines[:start]) + metadata + "".join(lines[end:])


def atomic_finalize(path: Path, original: str, stat_before: os.stat_result,
                    fields: Mapping[str, str]) -> None:
    if path.read_text(encoding="utf-8") != original:
        raise GateError("preflight record changed while validation was running")
    current_stat = path.stat()
    if (current_stat.st_dev, current_stat.st_ino) != (stat_before.st_dev, stat_before.st_ino):
        raise GateError("preflight record was replaced while validation was running")
    rendered = render_preflight(original, fields)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", dir=path.parent,
                prefix=f".{path.name}.", suffix=".tmp", delete=False) as stream:
            temporary_name = stream.name
            stream.write(rendered)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary_name, stat_before.st_mode & 0o777)
        os.replace(temporary_name, path)
        temporary_name = None
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)


def build_record(
    repo_root: Path,
    preflight_path: Path,
    prerequisite_record: Path | None,
    prerequisite_command: Sequence[str] | None,
    julia_command: Sequence[str],
    budget_command: Sequence[str],
    queue_command: Sequence[str],
) -> bool:
    root = experiment_root(repo_root)
    status, original, stat_before = current_preflight_status(preflight_path)

    # No configured test command may execute before this gate passes.
    if prerequisite_record is not None:
        prerequisite = verify_prerequisite_record(prerequisite_record)
    elif prerequisite_command is not None:
        prerequisite = verify_prerequisite_command(prerequisite_command, repo_root)
    else:
        raise GateError("a prerequisite record is required")

    prerequisite_binding = prerequisite_evidence_sha256(prerequisite)
    before_hashes = source_hashes(root)
    if status == "fail":
        raise GateError("refusing to reuse or overwrite a failed preflight")
    if status == "pass":
        verify_reusable_pass(
            original,
            current_hashes=before_hashes,
            prerequisite_binding=prerequisite_binding,
        )
        if preflight_path.read_text(encoding="utf-8") != original:
            raise GateError("passed preflight changed during reuse validation")
        current_stat = preflight_path.stat()
        if (current_stat.st_dev, current_stat.st_ino) != (
            stat_before.st_dev, stat_before.st_ino
        ):
            raise GateError("passed preflight was replaced during reuse validation")
        print("[preflight] reused exact passed record; no test command rerun")
        return True

    julia = run_suite(julia_command, repo_root, "julia")
    budget = run_suite(budget_command, repo_root, "budget")
    queue = run_suite(queue_command, repo_root, "queue")
    after_hashes = source_hashes(root)
    sources_stable = before_hashes == after_hashes
    passed = (
        sources_stable and
        julia.command_result.returncode == 0 and
        julia.passed > 0 and julia.passed == julia.total and
        budget.command_result.returncode == 0 and
        (budget.passed, budget.total) ==
            (EXPECTED_BUDGET_TESTS, EXPECTED_BUDGET_TESTS) and
        queue.command_result.returncode == 0 and
        (queue.passed, queue.total) ==
            (EXPECTED_QUEUE_TESTS, EXPECTED_QUEUE_TESTS)
    )
    fields = {
        "validation_status": "pass" if passed else "fail",
        "validated_utc": datetime.now(timezone.utc).isoformat(
            timespec="seconds").replace("+00:00", "Z"),
        "test_exit_code": str(julia.command_result.returncode),
        "test_assertions_passed": str(julia.passed),
        "test_assertions_total": str(julia.total),
        "budget_test_exit_code": str(budget.command_result.returncode),
        "budget_tests_passed": str(budget.passed),
        "budget_tests_total": str(budget.total),
        "queue_test_exit_code": str(queue.command_result.returncode),
        "queue_tests_passed": str(queue.passed),
        "queue_tests_total": str(queue.total),
        "prerequisite_evidence_sha256": prerequisite_binding,
        **after_hashes,
        "registered_endpoint_frames_executed_during_preflight": "0",
    }
    atomic_finalize(preflight_path, original, stat_before, fields)
    if not sources_stable:
        print("preflight source hashes changed while tests were running", file=sys.stderr)
    return passed


def parser() -> argparse.ArgumentParser:
    default_repo = Path(__file__).resolve().parents[3]
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--repo-root", type=Path, default=default_repo)
    result.add_argument("--preflight", type=Path)
    prerequisite = result.add_mutually_exclusive_group(required=True)
    prerequisite.add_argument("--prerequisite-record", type=Path)
    prerequisite.add_argument(
        "--prerequisite-command",
        help="test-only command; its final stdout line must be selected JSON",
    )
    result.add_argument("--julia-command", help="override command, parsed by shlex")
    result.add_argument("--budget-command", help="override command, parsed by shlex")
    result.add_argument("--queue-command", help="override command, parsed by shlex")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    repo_root = arguments.repo_root.resolve()
    root = experiment_root(repo_root)
    if arguments.preflight is None:
        preflight = root / "preflight_validation.md"
    elif arguments.preflight.is_absolute():
        preflight = arguments.preflight
    else:
        preflight = Path.cwd() / arguments.preflight
    try:
        julia_default = (default_julia_command(root)
                         if arguments.julia_command is None else [])
        julia_command = parse_command(arguments.julia_command, julia_default)
        budget_command = parse_command(arguments.budget_command, [
            sys.executable, str(root / "queue_tools/test_derive_budget.py")])
        queue_command = parse_command(arguments.queue_command, [
            sys.executable, str(root / "queue_tools/test_queue_tools.py")])
        prerequisite_command = (
            shlex.split(arguments.prerequisite_command)
            if arguments.prerequisite_command is not None else None)
        passed = build_record(
            repo_root, preflight, arguments.prerequisite_record,
            prerequisite_command, julia_command, budget_command, queue_command,
        )
        return 0 if passed else 4
    except GateError as error:
        print(f"preflight gate refused: {error}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
