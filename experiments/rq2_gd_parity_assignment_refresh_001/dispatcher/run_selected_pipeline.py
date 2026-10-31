#!/usr/bin/env python3
"""Run the selected factorial branch as a fail-closed, non-resumable pipeline.

The prerequisite controller calls this program only after it has written a
selected decision record.  This program then builds the one-time preflight
record, initializes a new attempt, freezes all inputs, launches the exact
registered anchor service, verifies it, locks the derived queue package, and
launches the exact registered transfer-plus-attribution service.

It never stops, kills, restarts, resets, or otherwise signals a service.  Any
failure retains the partial attempt and a new attempt ID is required.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable, Mapping, Sequence

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # pragma: no cover - registered host has tomllib
    import tomli as tomllib  # type: ignore[no-redef]


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import prepare_attempt as preparation  # noqa: E402


EXPERIMENT_ID = "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001"
HANDOFF_SCHEMA = "rq2-gd-parity-assignment-refresh-001/bridge-handoff-v1"
ACTIVE_STATES = {"active", "activating", "reloading", "deactivating"}
THREAD_ENVIRONMENT = {
    "JULIA_NUM_THREADS": "1",
    "OMP_NUM_THREADS": "1",
    "OPENBLAS_NUM_THREADS": "1",
    "MKL_NUM_THREADS": "1",
    "BLIS_NUM_THREADS": "1",
    "VECLIB_MAXIMUM_THREADS": "1",
}


class PipelineError(RuntimeError):
    """A selected-pipeline gate failed."""


@dataclass(frozen=True)
class Executables:
    python: str = sys.executable
    julia: str = "julia"
    systemd_run: str = "systemd-run"
    systemctl: str = "systemctl"


CommandRunner = Callable[..., subprocess.CompletedProcess[str]]
Sleeper = Callable[[float], None]
Clock = Callable[[], float]


def load_toml(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        return tomllib.load(handle)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def _toml_value(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=True)


def _atomic_create(path: Path, payload: Mapping[str, object]) -> None:
    """Create one immutable handoff record and refuse replacement."""

    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.tmp.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            for key in sorted(payload):
                handle.write(f"{key} = {_toml_value(payload[key])}\n")
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise PipelineError(f"refusing to overwrite bridge handoff: {path}") from error
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def _result_evidence(stage: str, result: Path) -> dict[str, object]:
    evidence_names = {
        "completion_sha256": "COMPLETED.toml",
        "manifest_sha256": "manifest.toml",
        "science_sha256": "science.json",
        "aggregate_sha256": "aggregate.csv",
        "checksum_manifest_sha256": "MANIFEST.sha256",
    }
    evidence: dict[str, object] = {"result": str(result)}
    for field, name in evidence_names.items():
        path = result / name
        if not path.is_file() or path.is_symlink():
            raise PipelineError(f"missing or indirect {stage} evidence: {path}")
        evidence[field] = sha256_file(path)
    completion = load_toml(result / "COMPLETED.toml")
    if completion.get("experiment_id") != EXPERIMENT_ID:
        raise PipelineError(f"{stage} completion names the wrong experiment")
    if completion.get("stage") != stage or completion.get("status") != "complete_valid":
        raise PipelineError(f"{stage} completion is not complete_valid")
    if completion.get("correctness_passed") is not True:
        raise PipelineError(f"{stage} completion did not pass correctness gates")
    if completion.get("deterministic_replay_passed") is not True:
        raise PipelineError(
            f"the two {stage} scientific passes do not have the same canonical hash"
        )
    return evidence


def record_bridge_handoff(
    handoff_record: Path,
    *,
    attempt_id: str,
    prerequisite_record: Path,
    paths: preparation.AttemptPaths,
    anchor_unit: str,
    queue_unit: str,
) -> None:
    """Bind completed factorial evidence and stop before any bridge launch."""

    if handoff_record.exists() or handoff_record.is_symlink():
        raise PipelineError(f"bridge handoff already exists: {handoff_record}")
    for protected in (
        paths.freeze,
        paths.anchor_result,
        paths.transfer_result,
        paths.attribution_result,
        paths.queue_root,
    ):
        if handoff_record == protected or protected in handoff_record.parents:
            raise PipelineError(
                f"bridge handoff must be outside scientific outputs: {handoff_record}"
            )
    if not prerequisite_record.is_file() or prerequisite_record.is_symlink():
        raise PipelineError(f"missing prerequisite decision: {prerequisite_record}")
    queue_completion = paths.queue_root / "QUEUE_COMPLETED.toml"
    queue_manifest = paths.queue_root / "QUEUE_MANIFEST.sha256"
    for path in (queue_completion, queue_manifest):
        if not path.is_file() or path.is_symlink():
            raise PipelineError(f"missing or indirect queue evidence: {path}")

    payload: dict[str, object] = {
        "schema_version": HANDOFF_SCHEMA,
        "experiment_id": EXPERIMENT_ID,
        "attempt_id": attempt_id,
        "state": "bridge_registration_required",
        "factorial_pipeline_complete_valid": True,
        "automatic_bridge_launch_allowed": False,
        "recorded_utc": utc_now(),
        "reason": (
            "factorial evidence is retained; the result-dependent bridge requires "
            "its own registered card, runner, tests, freeze, valid anchor, and manifest"
        ),
        "next_action": (
            "interpret the registered transfer contrasts and interaction, register "
            "one appropriate bridge, then launch it as a new attempt"
        ),
        "prerequisite_record": str(prerequisite_record),
        "prerequisite_record_sha256": sha256_file(prerequisite_record),
        "queue_root": str(paths.queue_root),
        "queue_completion_sha256": sha256_file(queue_completion),
        "queue_manifest_sha256": sha256_file(queue_manifest),
        "anchor_unit": anchor_unit,
        "queue_unit": queue_unit,
    }
    for stage, result in (
        ("anchor", paths.anchor_result),
        ("transfer", paths.transfer_result),
        ("attribution", paths.attribution_result),
    ):
        for field, value in _result_evidence(stage, result).items():
            payload[f"{stage}_{field}"] = value
    _atomic_create(handoff_record, payload)


def run_checked(
    command: Sequence[object],
    *,
    command_runner: CommandRunner = subprocess.run,
    env: Mapping[str, str] | None = None,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    argv = [str(value) for value in command]
    completed = command_runner(
        argv,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        env=dict(env) if env is not None else None,
        cwd=str(cwd) if cwd is not None else None,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise PipelineError(
            f"command failed ({completed.returncode}): {' '.join(argv)}"
            + (f"\n{detail}" if detail else "")
        )
    return completed


def parse_systemctl_show(output: str) -> dict[str, str]:
    properties: dict[str, str] = {}
    for raw_line in output.splitlines():
        if not raw_line.strip():
            continue
        key, separator, value = raw_line.partition("=")
        if not separator or not key or key in properties:
            raise PipelineError(f"malformed or duplicate systemctl property: {raw_line!r}")
        properties[key] = value
    required = {"LoadState", "ActiveState", "SubState", "Result", "ExecMainStatus"}
    if set(properties) != required:
        raise PipelineError(
            "systemctl property set changed: "
            f"missing={sorted(required-set(properties))}, "
            f"extra={sorted(set(properties)-required)}"
        )
    return properties


def unit_properties(
    unit_name: str,
    *,
    systemctl: str,
    command_runner: CommandRunner = subprocess.run,
) -> dict[str, str]:
    completed = run_checked(
        [
            systemctl,
            "--user",
            "show",
            unit_name,
            "--no-pager",
            "--property=LoadState",
            "--property=ActiveState",
            "--property=SubState",
            "--property=Result",
            "--property=ExecMainStatus",
        ],
        command_runner=command_runner,
    )
    return parse_systemctl_show(completed.stdout)


def wait_for_unit(
    unit_name: str,
    *,
    systemctl: str,
    poll_seconds: float,
    timeout_seconds: float,
    command_runner: CommandRunner = subprocess.run,
    sleeper: Sleeper = time.sleep,
    clock: Clock = time.monotonic,
) -> dict[str, str]:
    if poll_seconds < 0 or timeout_seconds <= 0:
        raise PipelineError("poll and timeout values must be positive")
    started = clock()
    observed_running = False
    while True:
        properties = unit_properties(
            unit_name, systemctl=systemctl, command_runner=command_runner
        )
        if properties["LoadState"] != "loaded":
            # Successful transient units may be garbage-collected immediately
            # after becoming inactive.  Accept that only after this process
            # observed the exact unit running; the caller must still verify the
            # checksum-bound scientific result before continuing.  A failed
            # service remains loaded in the failed state under systemd's
            # default CollectMode, and an unobserved/not-found unit is never
            # accepted.
            if properties["LoadState"] == "not-found" and observed_running:
                return properties
            raise PipelineError(
                f"registered unit is not loaded after launch: {unit_name}; "
                f"load={properties['LoadState']}"
            )
        active = properties["ActiveState"]
        observed_running = observed_running or active in ACTIVE_STATES
        if active not in ACTIVE_STATES:
            if (
                active == "inactive"
                and properties["Result"] == "success"
                and properties["ExecMainStatus"] == "0"
            ):
                return properties
            raise PipelineError(
                f"registered unit failed: {unit_name}; "
                f"active={active}, sub={properties['SubState']}, "
                f"result={properties['Result']}, "
                f"exit={properties['ExecMainStatus']}"
            )
        if clock() - started > timeout_seconds:
            raise PipelineError(
                f"monitoring deadline expired while {unit_name} remained {active}; "
                "the dispatcher did not signal it"
            )
        sleeper(poll_seconds)


def launch_unit(
    unit_name: str,
    wrapper: Path,
    queue_root: Path,
    *,
    systemd_run: str,
    command_runner: CommandRunner = subprocess.run,
) -> None:
    if unit_name not in {
        str(preparation.REGISTERED_EXECUTION["anchor_unit_name"]),
        str(preparation.REGISTERED_EXECUTION["queue_unit_name"]),
    }:
        raise PipelineError(f"refusing unregistered scientific unit: {unit_name}")
    if not wrapper.is_file() or wrapper.is_symlink():
        raise PipelineError(f"missing or indirect frozen wrapper: {wrapper}")
    run_checked(
        [
            systemd_run,
            "--user",
            f"--unit={unit_name}",
            "--no-block",
            "--property=Type=exec",
            "--property=Restart=no",
            f"--setenv=RQ2_QUEUE_ROOT={queue_root}",
            str(wrapper),
        ],
        command_runner=command_runner,
    )


def frozen_check(
    python: str,
    status: Path,
    arguments: Sequence[object],
    *,
    command_runner: CommandRunner,
) -> subprocess.CompletedProcess[str]:
    if not status.is_file() or status.is_symlink():
        raise PipelineError(f"missing or indirect frozen status helper: {status}")
    return run_checked(
        [python, status, *arguments], command_runner=command_runner
    )


def verify_queue_terminal(queue_root: Path) -> dict[str, Any]:
    terminal_path = queue_root / "QUEUE_COMPLETED.toml"
    failed_path = queue_root / "QUEUE_FAILED.toml"
    if failed_path.exists():
        raise PipelineError(f"queue retained a failure marker: {failed_path}")
    if not terminal_path.is_file() or terminal_path.is_symlink():
        raise PipelineError(f"queue lacks a regular completion marker: {terminal_path}")
    terminal = load_toml(terminal_path)
    required = {
        "experiment_id": EXPERIMENT_ID,
        "state": "complete",
        "exit_code": 0,
    }
    failures = {
        key: {"expected": value, "found": terminal.get(key)}
        for key, value in required.items()
        if terminal.get(key) != value
    }
    if failures:
        raise PipelineError(f"queue completion marker failed: {failures}")
    return terminal


def selected_pipeline(
    repo_root: Path,
    attempt_id: str,
    prerequisite_record: Path,
    *,
    handoff_record: Path | None = None,
    executables: Executables = Executables(),
    poll_seconds: float = 20.0,
    command_runner: CommandRunner = subprocess.run,
    sleeper: Sleeper = time.sleep,
    clock: Clock = time.monotonic,
) -> dict[str, object]:
    repo_root = repo_root.resolve()
    prerequisite_record = prerequisite_record.resolve()
    if handoff_record is not None:
        handoff_record = handoff_record.resolve(strict=False)
        if handoff_record.exists() or handoff_record.is_symlink():
            raise PipelineError(f"bridge handoff already exists: {handoff_record}")
    dispatcher = (
        repo_root
        / preparation.EXPERIMENT_RELATIVE
        / "dispatcher"
    )
    preflight_builder = dispatcher / "build_preflight_record.py"
    if not preflight_builder.is_file() or preflight_builder.is_symlink():
        raise PipelineError(f"missing preflight builder: {preflight_builder}")
    if not prerequisite_record.is_file() or prerequisite_record.is_symlink():
        raise PipelineError(
            f"missing or indirect selected decision record: {prerequisite_record}"
        )

    print("pipeline phase 1/6: build one-time preflight record", flush=True)
    run_checked(
        [
            executables.python,
            preflight_builder,
            "--repo-root",
            repo_root,
            "--prerequisite-record",
            prerequisite_record,
        ],
        command_runner=command_runner,
    )

    paths = preparation.initialize_attempt(repo_root, attempt_id)
    environment = {**os.environ, **THREAD_ENVIRONMENT}
    print("pipeline phase 2/6: freeze registered source and 424 inputs", flush=True)
    run_checked(
        [
            executables.julia,
            "--threads=1",
            "--startup-file=no",
            "--depwarn=error",
            f"--project={paths.project_root}",
            paths.runner,
            "freeze",
            "--config",
            paths.config,
            "--output",
            paths.freeze,
        ],
        command_runner=command_runner,
        env=environment,
        cwd=paths.repo_root,
    )

    frozen_tools = paths.freeze / "source/queue_tools"
    status = frozen_tools / "status_report.py"
    anchor_wrapper = frozen_tools / "run_anchor_once.sh"
    queue_wrapper = frozen_tools / "run_queue.sh"
    frozen_check(
        executables.python,
        status,
        ["verify-anchor-launch", "--queue-root", paths.queue_root],
        command_runner=command_runner,
    )
    frozen_check(
        executables.python,
        status,
        ["assert-unit-guard", "--queue-root", paths.queue_root, "--mode", "anchor"],
        command_runner=command_runner,
    )

    execution = load_toml(paths.queue_root / "queue.toml")["execution"]
    if execution != preparation.REGISTERED_EXECUTION:
        raise PipelineError("attempt execution controls changed after initialization")
    anchor_unit = str(execution["anchor_unit_name"])
    queue_unit = str(execution["queue_unit_name"])

    print(f"pipeline phase 3/6: launch and verify anchor unit {anchor_unit}", flush=True)
    launch_unit(
        anchor_unit,
        anchor_wrapper,
        paths.queue_root,
        systemd_run=executables.systemd_run,
        command_runner=command_runner,
    )
    wait_for_unit(
        anchor_unit,
        systemctl=executables.systemctl,
        poll_seconds=poll_seconds,
        timeout_seconds=float(execution["anchor_wall_budget_seconds"]) + 300.0,
        command_runner=command_runner,
        sleeper=sleeper,
        clock=clock,
    )
    frozen_check(
        executables.python,
        status,
        [
            "verify-result",
            "--result",
            paths.anchor_result,
            "--stage",
            "anchor",
            "--require-expansion",
        ],
        command_runner=command_runner,
    )

    print("pipeline phase 4/6: derive budgets and lock exact queue package", flush=True)
    package = preparation.finalize_attempt(
        paths.queue_root,
        python_executable=executables.python,
        command_runner=command_runner,
    )
    frozen_check(
        executables.python,
        status,
        ["verify-queue-launch", "--queue-root", paths.queue_root],
        command_runner=command_runner,
    )
    frozen_check(
        executables.python,
        status,
        ["assert-unit-guard", "--queue-root", paths.queue_root, "--mode", "queue"],
        command_runner=command_runner,
    )

    print(f"pipeline phase 5/6: launch serial scientific unit {queue_unit}", flush=True)
    launch_unit(
        queue_unit,
        queue_wrapper,
        paths.queue_root,
        systemd_run=executables.systemd_run,
        command_runner=command_runner,
    )
    wait_for_unit(
        queue_unit,
        systemctl=executables.systemctl,
        poll_seconds=poll_seconds,
        timeout_seconds=(
            2.0 * float(execution["maximum_nonanchor_wall_budget_seconds"]) + 600.0
        ),
        command_runner=command_runner,
        sleeper=sleeper,
        clock=clock,
    )

    print("pipeline phase 6/6: verify both scientific results and queue terminal", flush=True)
    frozen_check(
        executables.python,
        status,
        ["verify-queue-launch", "--queue-root", paths.queue_root],
        command_runner=command_runner,
    )
    for stage, result in (
        ("transfer", paths.transfer_result),
        ("attribution", paths.attribution_result),
    ):
        frozen_check(
            executables.python,
            status,
            ["verify-result", "--result", result, "--stage", stage],
            command_runner=command_runner,
        )
    terminal = verify_queue_terminal(paths.queue_root)
    if handoff_record is not None:
        record_bridge_handoff(
            handoff_record,
            attempt_id=attempt_id,
            prerequisite_record=prerequisite_record,
            paths=paths,
            anchor_unit=anchor_unit,
            queue_unit=queue_unit,
        )
    return {
        "attempt_id": attempt_id,
        "queue_root": str(paths.queue_root),
        "freeze": str(paths.freeze),
        "anchor_result": str(paths.anchor_result),
        "transfer_result": str(paths.transfer_result),
        "attribution_result": str(paths.attribution_result),
        "anchor_unit": anchor_unit,
        "queue_unit": queue_unit,
        "package_verified": package["verified"],
        "queue_state": terminal["state"],
        "bridge_handoff": str(handoff_record) if handoff_record is not None else "",
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--attempt-id", required=True)
    parser.add_argument(
        "--prerequisite-record",
        "--decision-record",
        dest="prerequisite_record",
        required=True,
        type=Path,
    )
    parser.add_argument("--python-executable", default=sys.executable)
    parser.add_argument("--julia-executable", default="julia")
    parser.add_argument("--systemd-run-executable", default="systemd-run")
    parser.add_argument("--systemctl-executable", default="systemctl")
    parser.add_argument("--poll-seconds", type=float, default=20.0)
    parser.add_argument("--handoff-record", required=True, type=Path)
    return parser


def main(arguments: list[str] | None = None) -> int:
    args = build_parser().parse_args(arguments)
    payload = selected_pipeline(
        args.repo_root,
        args.attempt_id,
        args.prerequisite_record,
        handoff_record=args.handoff_record,
        executables=Executables(
            python=args.python_executable,
            julia=args.julia_executable,
            systemd_run=args.systemd_run_executable,
            systemctl=args.systemctl_executable,
        ),
        poll_seconds=args.poll_seconds,
    )
    print(json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        PipelineError,
        preparation.PreparationError,
        OSError,
        KeyError,
        ValueError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
