#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import io
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import lock_queue_package as locker  # noqa: E402
import status_report as status  # noqa: E402


IMMUTABLE = (
    "README.md",
    "budget_attribution.toml",
    "budget_transfer.toml",
    "derive_budget.py",
    "lock_queue_package.py",
    "queue.toml",
    "run_anchor_once.sh",
    "run_queue.sh",
    "status_report.py",
)
TEST_ATTEMPT_ID = "test_v1"
TEST_QUEUE_ID = f"{status.EXPERIMENT_ID}.{TEST_ATTEMPT_ID}"


def budget_text(stage: str, anchor: Path | None = None) -> str:
    rows = [
            'schema_version = "rq2-gd-parity-assignment-refresh-001/budget-v1"',
            'experiment_id = "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001"',
            f'target_stage = "{stage}"',
            "anchor_cases = 24",
            "target_cases = 200",
            "pass_count = 2",
            "safety_factor = 1.5",
            "absolute_safety_cap_seconds = 36000",
            "termination_grace_seconds = 120",
    ]
    if anchor is None:
        rows.extend(("wall_budget_seconds = 600", "term_after_seconds = 480"))
    else:
        frame_seconds, post_seconds = status.anchor_phase_measurements(anchor)
        projected_frame = frame_seconds / 24 * 200
        projected_post = post_seconds / 24 * 200
        projected = projected_frame + projected_post
        wall = math.ceil(1.5 * projected)
        rows.extend(
            (
                f'anchor_result = "{anchor}"',
                f'anchor_science_sha256 = "{status.sha256_file(anchor / "science.json")}"',
                f'anchor_completion_sha256 = "{status.sha256_file(anchor / "COMPLETED.toml")}"',
                f'anchor_manifest_sha256 = "{status.sha256_file(anchor / "manifest.toml")}"',
                f'anchor_checksum_manifest_sha256 = "{status.sha256_file(anchor / "MANIFEST.sha256")}"',
                f'phase_log_sha256 = "{status.sha256_file(anchor / "phase_log.tsv")}"',
                f"anchor_frame_loop_seconds = {frame_seconds:.9f}",
                f"anchor_seconds_per_case_per_pass = {frame_seconds / 48:.12f}",
                f"projected_frame_seconds = {projected_frame:.9f}",
                f"anchor_post_loop_seconds = {post_seconds:.9f}",
                f"post_loop_scale = {200 / 24:.12f}",
                f"projected_post_loop_seconds = {projected_post:.9f}",
                f"projected_seconds_before_safety = {projected:.9f}",
                f"wall_budget_seconds = {wall}",
                f"term_after_seconds = {wall - 120}",
            )
        )
    return "\n".join((*rows, ""))


def queue_text(root: Path) -> str:
    immutable = ",\n  ".join(f'"{value}"' for value in IMMUTABLE)
    telemetry = ",\n  ".join(f'"{value}"' for value in sorted(status.BASE_TELEMETRY))
    return f'''schema_version = "rq2-gd-parity-assignment-refresh-001/queue-v1"
queue_id = "{TEST_QUEUE_ID}"
experiment_id = "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001"
stages = ["transfer", "attribution"]
execution_mode = "serial, one scientific unit, fail closed"
automatic_restart_allowed = false
interrupted_attempt_must_be_retained = true
manual_relaunch_requires_new_attempt_directory = true

[execution]
scientific_unit_pattern = "sp-gd-*.service"
anchor_unit_name = "sp-gd-rq2-parity-assignment-refresh-v4-anchor-20261101.service"
queue_unit_name = "sp-gd-rq2-parity-assignment-refresh-v4-20261101.service"
anchor_wall_budget_seconds = 7200
anchor_term_after_seconds = 7080
termination_grace_seconds = 120
maximum_nonanchor_wall_budget_seconds = 36000
julia_threads = 1
omp_threads = 1
blas_threads = 1
nice = 19
ionice_class = "idle"

[paths]
repository_root = "{root}"
project_root = "{root}/project"
config = "experiments/rq2_gd_parity_assignment_refresh_001/config.toml"
runner = "experiments/rq2_gd_parity_assignment_refresh_001/rq2_gd_parity_assignment_refresh_001.jl"
preflight = "experiments/rq2_gd_parity_assignment_refresh_001/preflight/{TEST_ATTEMPT_ID}/preflight_validation.md"
freeze = "freeze"
anchor_result = "experiments/rq2_gd_parity_assignment_refresh_001/results/test_anchor"
transfer_result = "experiments/rq2_gd_parity_assignment_refresh_001/results/test_transfer"
attribution_result = "experiments/rq2_gd_parity_assignment_refresh_001/results/test_attribution"
budget_transfer = "budget_transfer.toml"
budget_attribution = "budget_attribution.toml"

[inventory]
immutable_files = [
  {immutable},
]

[telemetry]
files = [
  {telemetry},
]
job_ids = ["J01", "J02"]
'''


def make_queue(root: Path) -> Path:
    queue = root / "queue"
    queue.mkdir()
    (root / "project").mkdir()
    shutil.copy2(HERE / "QUEUE_PACKAGE_README.template.md", queue / "README.md")
    (queue / "budget_transfer.toml").write_text(
        budget_text("transfer"), encoding="utf-8"
    )
    (queue / "budget_attribution.toml").write_text(
        budget_text("attribution"), encoding="utf-8"
    )
    for name in (
        "derive_budget.py",
        "lock_queue_package.py",
        "run_anchor_once.sh",
        "run_queue.sh",
        "status_report.py",
    ):
        shutil.copy2(HERE / name, queue / name)
    for name in ("run_anchor_once.sh", "run_queue.sh"):
        (queue / name).chmod(0o755)
    (queue / "queue.toml").write_text(queue_text(root), encoding="utf-8")
    return queue


def write_tree_checksum_manifest(root: Path) -> None:
    files = sorted(
        path
        for path in root.rglob("*")
        if path.is_file() and path.name != "MANIFEST.sha256"
    )
    (root / "MANIFEST.sha256").write_text(
        "".join(
            f"{status.sha256_file(path)}  {path.relative_to(root).as_posix()}\n"
            for path in files
        ),
        encoding="utf-8",
    )


def write_freeze_manifest(freeze: Path, records: list[tuple[str, Path]]) -> None:
    config_record = next(path for label, path in records if label == "config.toml")
    rows = [
        'experiment_id = "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001"',
        f'configuration_sha256 = "{status.sha256_file(config_record)}"',
        "",
        "[preflight_gate]",
        "passed = true",
        "",
        "[preflight_gate.recorded]",
        'validation_status = "pass"',
    ]
    for label, path in records:
        if label in {
            "config.toml",
            "rq2_gd_parity_assignment_refresh_001.jl",
        }:
            original = (
                freeze.parent
                / "experiments"
                / "rq2_gd_parity_assignment_refresh_001"
                / (
                    "config.toml"
                    if label == "config.toml"
                    else "rq2_gd_parity_assignment_refresh_001.jl"
                )
            )
        elif label == status.PREFLIGHT_SOURCE_LABEL:
            original = (
                freeze.parent
                / "experiments"
                / "rq2_gd_parity_assignment_refresh_001"
                / "preflight"
                / TEST_ATTEMPT_ID
                / status.PREFLIGHT_FILENAME
            )
        else:
            original = path
        rows.extend(
            (
                "",
                "[[sources]]",
                f'label = "{label}"',
                f'archived_relative_path = "{path.relative_to(freeze).as_posix()}"',
                f'original_path = "{original}"',
                f'sha256 = "{status.sha256_file(path)}"',
            )
        )
    (freeze / "freeze_manifest.toml").write_text(
        "\n".join(rows) + "\n", encoding="utf-8"
    )
    write_tree_checksum_manifest(freeze)


def make_anchor_freeze(root: Path, queue: Path) -> tuple[Path, Path, Path]:
    freeze = root / "freeze"
    source = freeze / "source"
    tools = source / "queue_tools"
    vendor = source / "vendor"
    tools.mkdir(parents=True)
    vendor.mkdir(parents=True)
    config = source / "config.toml"
    config.write_text(
        '''experiment_id = "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001"

[queue_plan]
scientific_unit_pattern = "sp-gd-*.service"
anchor_unit_name = "sp-gd-rq2-parity-assignment-refresh-v4-anchor-20261101.service"
queue_unit_name = "sp-gd-rq2-parity-assignment-refresh-v4-20261101.service"
anchor_wall_budget_seconds = 7200
anchor_term_after_seconds = 7080
termination_grace_seconds = 120
maximum_nonanchor_wall_budget_seconds = 36000
julia_threads = 1
omp_threads = 1
blas_threads = 1
nice = 19
ionice_class = "idle"
''',
        encoding="utf-8",
    )
    runner = source / "rq2_gd_parity_assignment_refresh_001.jl"
    runner.write_text("# frozen test runner\n", encoding="utf-8")
    live_experiment = (
        root / "experiments" / "rq2_gd_parity_assignment_refresh_001"
    )
    live_experiment.mkdir(parents=True)
    shutil.copy2(config, live_experiment / "config.toml")
    live_runner = live_experiment / "rq2_gd_parity_assignment_refresh_001.jl"
    shutil.copy2(runner, live_runner)
    preflight = source / status.PREFLIGHT_FILENAME
    preflight.write_text("validation_status: pass\n", encoding="utf-8")
    live_preflight = (
        live_experiment
        / "preflight"
        / TEST_ATTEMPT_ID
        / status.PREFLIGHT_FILENAME
    )
    live_preflight.parent.mkdir(parents=True)
    shutil.copy2(preflight, live_preflight)
    frozen_governance: dict[str, Path] = {}
    for package_name, label in status.GOVERNANCE_SOURCE_LABELS.items():
        source_name = (
            "QUEUE_PACKAGE_README.template.md"
            if package_name == "README.md"
            else package_name
        )
        target = source / label
        shutil.copy2(HERE / source_name, target)
        frozen_governance[label] = target
    frozen_status = frozen_governance["queue_tools/status_report.py"]
    split = vendor / "split_config.toml"
    split.write_text(
        f'[sources]\njade_project_repo = "{root / "project"}"\n',
        encoding="utf-8",
    )
    records = [
        ("config.toml", config),
        (status.PREFLIGHT_SOURCE_LABEL, preflight),
        ("rq2_gd_parity_assignment_refresh_001.jl", runner),
        *sorted(frozen_governance.items()),
        ("vendor/split_config.toml", split),
    ]
    write_freeze_manifest(freeze, records)

    return freeze, frozen_status, live_runner


def make_anchor_result(root: Path, freeze: Path) -> Path:
    anchor = (
        root
        / "experiments"
        / "rq2_gd_parity_assignment_refresh_001"
        / "results"
        / "test_anchor"
    )
    anchor.mkdir(parents=True)
    required_phases = [
        ("primary", "frame_loop", 12.0),
        ("replay", "frame_loop", 12.0),
    ]
    required_phases.extend(
        (pass_name, phase, 1.0)
        for pass_name in ("primary", "replay")
        for phase in status.POST_LOOP_PHASES
    )
    required_phases.extend(
        (
            ("primary", "primary_checkpoint", 1.0),
            ("artifact", "write_result", 1.0),
            ("artifact", "checksum_manifest", 1.0),
        )
    )
    phase_rows = ["utc\tpass\tphase\tseconds"]
    for pass_name, phase, seconds in required_phases:
        phase_rows.append(f"2026-10-31T00:00:00Z\t{pass_name}\t{phase}:start\t0")
        phase_rows.append(
            f"2026-10-31T00:00:01Z\t{pass_name}\t{phase}:end\t{seconds}"
        )
    phase_log = anchor / "phase_log.tsv"
    phase_log.write_text("\n".join(phase_rows) + "\n", encoding="utf-8")
    (anchor / "PHASE_LOG.sha256").write_text(
        f"{status.sha256_file(phase_log)}  phase_log.tsv\n", encoding="utf-8"
    )
    science = anchor / "science.json"
    science.write_text(
        json.dumps(
            {
                "experiment_id": status.EXPERIMENT_ID,
                "stage": "anchor",
                "frame_count": 24,
                "correctness_passed": True,
                "anchor_expansion_authorized": True,
            },
            sort_keys=True,
        ),
        encoding="utf-8",
    )
    manifest = anchor / "manifest.toml"
    manifest.write_text(
        "\n".join(
            (
                f'experiment_id = "{status.EXPERIMENT_ID}"',
                'stage = "anchor"',
                f'freeze = "{freeze}"',
                f'freeze_manifest_sha256 = "{status.sha256_file(freeze / "freeze_manifest.toml")}"',
                f'freeze_checksum_manifest_sha256 = "{status.sha256_file(freeze / "MANIFEST.sha256")}"',
                "",
            )
        ),
        encoding="utf-8",
    )
    completion = anchor / "COMPLETED.toml"
    completion.write_text(
        "\n".join(
            (
                f'experiment_id = "{status.EXPERIMENT_ID}"',
                'stage = "anchor"',
                'status = "complete_valid"',
                "correctness_passed = true",
                "deterministic_replay_passed = true",
                "anchor_expansion_authorized = true",
                f'science_sha256 = "{status.sha256_file(science)}"',
                f'manifest_sha256 = "{status.sha256_file(manifest)}"',
                "",
            )
        ),
        encoding="utf-8",
    )
    files = sorted(
        path
        for path in anchor.iterdir()
        if path.is_file() and path.name not in {"MANIFEST.sha256", "phase_log.tsv"}
    )
    (anchor / "MANIFEST.sha256").write_text(
        "".join(f"{status.sha256_file(path)}  {path.name}\n" for path in files),
        encoding="utf-8",
    )
    return anchor


def prepare_locked_launch(
    root: Path,
) -> tuple[Path, Path, Path, Path, Path]:
    queue = make_queue(root)
    freeze, frozen_status, runner = make_anchor_freeze(root, queue)
    anchor = make_anchor_result(root, freeze)
    for stage in ("transfer", "attribution"):
        (queue / f"budget_{stage}.toml").write_text(
            budget_text(stage, anchor), encoding="utf-8"
        )
    locker.lock_package(queue)
    return queue, freeze, frozen_status, runner, anchor


def frozen_queue_gate(frozen_status: Path, queue: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "python3",
            str(frozen_status),
            "verify-queue-launch",
            "--queue-root",
            str(queue),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )


class QueuePackageTests(unittest.TestCase):
    def test_template_and_runner_authorization_share_closed_inventory(self) -> None:
        template = status.load_toml(HERE / "queue_template.toml")
        self.assertEqual(template["stages"], ["transfer", "attribution"])
        self.assertEqual(template["execution"], status.REGISTERED_EXECUTION)
        self.assertEqual(
            set(status.immutable_inventory(template)), status.EXPECTED_IMMUTABLE
        )
        self.assertEqual(template["telemetry"]["job_ids"], status.EXPECTED_JOB_IDS)
        expected_mutable = set(status.BASE_TELEMETRY)
        for job_id in ("J01", "J02"):
            expected_mutable.add(f"logs/{job_id}.log")
            expected_mutable.update(
                f"jobs/{job_id}/{marker}" for marker in status.JOB_MARKERS
            )
        self.assertEqual(status.telemetry_inventory(template), expected_mutable)
        experiment = status.load_toml(HERE.parent / "config.toml")
        self.assertEqual(experiment["queue_plan"], status.REGISTERED_EXECUTION)
        authorization = experiment["execution_authorization"]
        self.assertEqual(
            set(authorization["queue_unlisted_immutable_sidecars"]),
            {status.MANIFEST_NAME, status.LOCK_NAME},
        )
        self.assertEqual(
            set(authorization["queue_allowed_mutable_relative_paths"]),
            expected_mutable,
        )

    def test_lock_and_exact_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            queue = make_queue(root)
            locked = locker.lock_package(queue)
            self.assertEqual(locked["locked_file_count"], len(IMMUTABLE))
            verified = status.verify_queue_package(queue)
            self.assertEqual(verified["queue_id"], TEST_QUEUE_ID)

            # Every registered telemetry path is allowed after lock.
            for relative in status.BASE_TELEMETRY:
                (queue / relative).write_text("telemetry\n", encoding="utf-8")
            for job_id in ("J01", "J02"):
                (queue / "logs").mkdir(exist_ok=True)
                (queue / "jobs" / job_id).mkdir(parents=True, exist_ok=True)
                (queue / "logs" / f"{job_id}.log").write_text(
                    "log\n", encoding="utf-8"
                )
                for marker in status.JOB_MARKERS:
                    (queue / "jobs" / job_id / marker).write_text(
                        "marker\n", encoding="utf-8"
                    )
            status.verify_queue_package(queue)

        # A modified queue.toml cannot bless an added executable as immutable.
        with tempfile.TemporaryDirectory() as temporary:
            queue = make_queue(Path(temporary))
            (queue / "extra_runner.sh").write_text("#!/bin/sh\n", encoding="utf-8")
            queue_toml = queue / "queue.toml"
            queue_toml.write_text(
                queue_toml.read_text(encoding="utf-8").replace(
                    '  "status_report.py",\n]',
                    '  "status_report.py",\n  "extra_runner.sh",\n]',
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(status.GateError, "registered file set"):
                locker.lock_package(queue)

        # The wrapper writes J01 then J02, so alternate marker IDs fail early.
        with tempfile.TemporaryDirectory() as temporary:
            queue = make_queue(Path(temporary))
            queue_toml = queue / "queue.toml"
            queue_toml.write_text(
                queue_toml.read_text(encoding="utf-8").replace(
                    'job_ids = ["J01", "J02"]',
                    'job_ids = ["J99", "J02"]',
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(status.GateError, "registered order"):
                locker.lock_package(queue)

    def test_unlisted_helper_and_tamper_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            queue = make_queue(Path(temporary))
            locker.lock_package(queue)
            hidden = queue / "emergency_config.toml"
            hidden.write_text("enabled = true\n", encoding="utf-8")
            with self.assertRaisesRegex(status.GateError, "unlisted files"):
                status.verify_queue_package(queue)
            hidden.unlink()
            (queue / "run_queue.sh").write_text("tampered\n", encoding="utf-8")
            with self.assertRaisesRegex(status.GateError, "checksum mismatch"):
                status.verify_queue_package(queue)

    def test_preexisting_telemetry_and_bad_budget_refuse_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            queue = make_queue(Path(temporary))
            (queue / "queue.log").write_text("old attempt\n", encoding="utf-8")
            with self.assertRaisesRegex(status.GateError, "telemetry already exists"):
                locker.lock_package(queue)
        with tempfile.TemporaryDirectory() as temporary:
            queue = make_queue(Path(temporary))
            path = queue / "budget_transfer.toml"
            path.write_text(
                budget_text("transfer").replace(
                    "wall_budget_seconds = 600", "wall_budget_seconds = 36001"
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(status.GateError, "invalid transfer budget"):
                locker.lock_package(queue)

    def test_stage_order_is_exact_and_locked(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            queue = make_queue(Path(temporary))
            config = queue / "queue.toml"
            config.write_text(
                config.read_text(encoding="utf-8").replace(
                    'stages = ["transfer", "attribution"]',
                    'stages = ["attribution", "transfer"]',
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(status.GateError, "stages must be exactly"):
                locker.lock_package(queue)

    def test_changed_execution_controls_cannot_be_locked(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            queue = make_queue(Path(temporary))
            config = queue / "queue.toml"
            config.write_text(
                config.read_text(encoding="utf-8").replace(
                    'scientific_unit_pattern = "sp-gd-*.service"',
                    'scientific_unit_pattern = "not-the-registered-prefix*.service"',
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(status.GateError, "execution controls"):
                locker.lock_package(queue)

        with tempfile.TemporaryDirectory() as temporary:
            queue = make_queue(Path(temporary))
            config = queue / "queue.toml"
            config.write_text(
                config.read_text(encoding="utf-8").replace(
                    "automatic_restart_allowed = false",
                    "automatic_restart_allowed = true",
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(status.GateError, "governance fields"):
                locker.lock_package(queue)

        with tempfile.TemporaryDirectory() as temporary:
            queue = make_queue(Path(temporary))
            config = queue / "queue.toml"
            config.write_text(
                config.read_text(encoding="utf-8").replace(
                    '[paths]\nrepository_root =',
                    '[paths]\nunregistered_runner = "elsewhere.jl"\nrepository_root =',
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(status.GateError, "path schema"):
                locker.lock_package(queue)

    def test_symlink_is_never_telemetry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            queue = make_queue(Path(temporary))
            locker.lock_package(queue)
            (queue / "queue.log").symlink_to(queue / "README.md")
            with self.assertRaisesRegex(status.GateError, "symlinks are forbidden"):
                status.verify_queue_package(queue)


class GuardAndWrapperTests(unittest.TestCase):
    def test_unit_guard_allows_only_own_service(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            queue = make_queue(root)
            own = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=(
                    "sp-gd-rq2-parity-assignment-refresh-v4-20261101.service "
                    "loaded active running test\n"
                ),
                stderr="",
            )
            with mock.patch.object(status.subprocess, "run", return_value=own):
                record = status.unit_guard(queue, "queue")
                self.assertEqual(
                    record["active_units"],
                    ["sp-gd-rq2-parity-assignment-refresh-v4-20261101.service"],
                )
            conflict = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=(
                    "sp-gd-rq2-parity-assignment-refresh-v4-20261101.service "
                    "loaded active running test\n"
                    "sp-gd-rq2-offset-split-v3-20261031.service loaded active running v3\n"
                ),
                stderr="",
            )
            with mock.patch.object(status.subprocess, "run", return_value=conflict):
                with self.assertRaisesRegex(status.GateError, "another scientific"):
                    status.unit_guard(queue, "queue")
            with mock.patch.object(
                status.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(
                    args=[], returncode=0, stdout="", stderr=""
                ),
            ) as run:
                status.active_scientific_units("sp-gd-*.service")
                self.assertIn(
                    "--state=active,activating,reloading,deactivating",
                    run.call_args.args[0],
                )

    def test_unit_guard_rejects_duplicate_or_out_of_pattern_names(self) -> None:
        replacements = (
            (
                'queue_unit_name = "sp-gd-rq2-parity-assignment-refresh-v4-20261101.service"',
                'queue_unit_name = "sp-gd-rq2-parity-assignment-refresh-v4-anchor-20261101.service"',
            ),
            (
                'anchor_unit_name = "sp-gd-rq2-parity-assignment-refresh-v4-anchor-20261101.service"',
                'anchor_unit_name = "unregistered-anchor.service"',
            ),
        )
        for old, new in replacements:
            with self.subTest(new=new), tempfile.TemporaryDirectory() as temporary:
                queue = make_queue(Path(temporary))
                path = queue / "queue.toml"
                path.write_text(
                    path.read_text(encoding="utf-8").replace(old, new),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(status.GateError, "execution controls"):
                    status.unit_guard(queue, "anchor")

    def test_wrappers_parse_and_encode_registered_controls(self) -> None:
        for script in (HERE / "run_anchor_once.sh", HERE / "run_queue.sh"):
            completed = subprocess.run(
                ["bash", "-n", str(script)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
        anchor = (HERE / "run_anchor_once.sh").read_text(encoding="utf-8")
        self.assertIn('QUEUE_ROOT_SOURCE="${RQ2_QUEUE_ROOT:-$SCRIPT_ROOT}"', anchor)
        self.assertIn('STATUS="$SCRIPT_ROOT/status_report.py"', anchor)
        self.assertIn("verify-anchor-launch", anchor)
        self.assertIn("--kill-after=120s 7080s", anchor)
        self.assertIn("nice -n 19 ionice -c 3", anchor)
        self.assertIn("JULIA_NUM_THREADS=1", anchor)
        queue = (HERE / "run_queue.sh").read_text(encoding="utf-8")
        self.assertIn('QUEUE_ROOT_SOURCE="$RQ2_QUEUE_ROOT"', queue)
        self.assertIn('STATUS="$SCRIPT_ROOT/status_report.py"', queue)
        self.assertIn("verify-queue-launch", queue)
        self.assertLess(queue.index("verify_launch\n"), queue.index("REPO_ROOT="))
        self.assertLess(queue.index("run_job J01 transfer"), queue.index("run_job J02 attribution"))
        self.assertIn('--budget-record "$BUDGET_TRANSFER" --queue-manifest "$MANIFEST"', queue)
        self.assertIn('--budget-record "$BUDGET_ATTRIBUTION" --queue-manifest "$MANIFEST"', queue)
        self.assertNotIn("systemctl --user stop", queue)
        self.assertNotIn("systemctl --user kill", queue)
        readme = (HERE / "QUEUE_PACKAGE_README.template.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("RQ2_QUEUE_ROOT=/absolute/path/to/new/queue", readme)
        self.assertIn("freeze/source/queue_tools/run_anchor_once.sh", readme)
        self.assertIn("freeze/source/queue_tools/run_queue.sh", readme)
        self.assertIn("verify-queue-launch", readme)
        self.assertIn("copied checker", readme)

    def test_frozen_status_helper_reads_a_separate_queue_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            queue = make_queue(root)
            completed = subprocess.run(
                [
                    "python3",
                    str(HERE / "status_report.py"),
                    "resolve-path",
                    "--queue-root",
                    str(queue),
                    "--key",
                    "runner",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(
                Path(completed.stdout.strip()),
                root
                / "experiments"
                / "rq2_gd_parity_assignment_refresh_001"
                / "rq2_gd_parity_assignment_refresh_001.jl",
            )

    def test_anchor_launch_is_bound_to_freeze_and_registered_controls(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            queue = make_queue(root)
            _, frozen_status, runner = make_anchor_freeze(root, queue)

            def verify() -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    [
                        "python3",
                        str(frozen_status),
                        "verify-anchor-launch",
                        "--queue-root",
                        str(queue),
                    ],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                    env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
                )

            completed = verify()
            self.assertEqual(completed.returncode, 0, completed.stderr)

            live_preflight = (
                root
                / "experiments"
                / "rq2_gd_parity_assignment_refresh_001"
                / "preflight"
                / TEST_ATTEMPT_ID
                / status.PREFLIGHT_FILENAME
            )
            original_preflight = live_preflight.read_bytes()
            live_preflight.write_text("validation_status: fail\n", encoding="utf-8")
            completed = verify()
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("preflight", completed.stderr)
            live_preflight.write_bytes(original_preflight)

            queue_config = queue / "queue.toml"
            original_queue = queue_config.read_text(encoding="utf-8")
            prior_preflight = (
                live_preflight.parent.parent
                / "prior_attempt"
                / status.PREFLIGHT_FILENAME
            )
            prior_preflight.parent.mkdir()
            prior_preflight.write_bytes(original_preflight)
            queue_config.write_text(
                original_queue.replace(
                    f"preflight/{TEST_ATTEMPT_ID}/{status.PREFLIGHT_FILENAME}",
                    f"preflight/prior_attempt/{status.PREFLIGHT_FILENAME}",
                ),
                encoding="utf-8",
            )
            completed = verify()
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("different attempts", completed.stderr)
            queue_config.write_text(original_queue, encoding="utf-8")

            freeze = frozen_status.parents[2]
            archived_preflight = freeze / "source" / status.PREFLIGHT_FILENAME
            original_archived = archived_preflight.read_bytes()
            archived_preflight.write_bytes(original_archived + b"# tampered\n")
            write_tree_checksum_manifest(freeze)
            completed = verify()
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("archived source", completed.stderr)
            archived_preflight.write_bytes(original_archived)
            write_tree_checksum_manifest(freeze)

            freeze_manifest = freeze / "freeze_manifest.toml"
            original_manifest = freeze_manifest.read_text(encoding="utf-8")
            freeze_manifest.write_text(
                original_manifest.replace("passed = true", "passed = false", 1),
                encoding="utf-8",
            )
            write_tree_checksum_manifest(freeze)
            completed = verify()
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("passed preflight gate", completed.stderr)
            freeze_manifest.write_text(original_manifest, encoding="utf-8")
            write_tree_checksum_manifest(freeze)

            original_runner = runner.read_bytes()
            runner.write_bytes(original_runner + b"# tampered\n")
            completed = verify()
            self.assertNotEqual(completed.returncode, 0)
            runner.write_bytes(original_runner)

            config = (
                root
                / "experiments"
                / "rq2_gd_parity_assignment_refresh_001"
                / "config.toml"
            )
            original_config = config.read_bytes()
            config.write_bytes(original_config + b"# tampered\n")
            completed = verify()
            self.assertNotEqual(completed.returncode, 0)
            config.write_bytes(original_config)

            alternate_runner = root / "same_bytes_elsewhere.jl"
            alternate_runner.write_bytes(original_runner)
            queue_config.write_text(
                original_queue.replace(
                    'runner = "experiments/rq2_gd_parity_assignment_refresh_001/'
                    'rq2_gd_parity_assignment_refresh_001.jl"',
                    f'runner = "{alternate_runner}"',
                ),
                encoding="utf-8",
            )
            completed = verify()
            self.assertNotEqual(completed.returncode, 0)

            queue_config.write_text(
                original_queue.replace(
                    "anchor_wall_budget_seconds = 7200",
                    "anchor_wall_budget_seconds = 7199",
                ),
                encoding="utf-8",
            )
            completed = verify()
            self.assertNotEqual(completed.returncode, 0)

        # The post-anchor gate succeeds only through the frozen checker.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            queue, _, frozen_status, _, _ = prepare_locked_launch(root)
            completed = frozen_queue_gate(frozen_status, queue)
            self.assertEqual(completed.returncode, 0, completed.stderr)

        # Re-locking a same-byte runner at another path cannot redirect Julia.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            queue, _, frozen_status, runner, _ = prepare_locked_launch(root)
            (queue / status.MANIFEST_NAME).unlink()
            (queue / status.LOCK_NAME).unlink()
            alternate = root / "same_bytes_unregistered_runner.jl"
            alternate.write_bytes(runner.read_bytes())
            queue_toml = queue / "queue.toml"
            queue_toml.write_text(
                queue_toml.read_text(encoding="utf-8").replace(
                    'runner = "experiments/rq2_gd_parity_assignment_refresh_001/'
                    'rq2_gd_parity_assignment_refresh_001.jl"',
                    f'runner = "{alternate}"',
                ),
                encoding="utf-8",
            )
            locker.lock_package(queue)
            completed = frozen_queue_gate(frozen_status, queue)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("exact hash-bound original source", completed.stderr)

        # A self-locked output path cannot escape the registered results root.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            queue, _, frozen_status, _, _ = prepare_locked_launch(root)
            (queue / status.MANIFEST_NAME).unlink()
            (queue / status.LOCK_NAME).unlink()
            queue_toml = queue / "queue.toml"
            queue_toml.write_text(
                queue_toml.read_text(encoding="utf-8").replace(
                    'transfer_result = "experiments/'
                    'rq2_gd_parity_assignment_refresh_001/results/test_transfer"',
                    f'transfer_result = "{root / "outside_transfer"}"',
                ),
                encoding="utf-8",
            )
            locker.lock_package(queue)
            completed = frozen_queue_gate(frozen_status, queue)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("one attempt-specific child", completed.stderr)

        # A copied verifier, wrapper, lock tool, or budget tool cannot become
        # trusted merely by regenerating a self-consistent manifest and lock.
        for governance_name in (
            "status_report.py",
            "run_queue.sh",
            "lock_queue_package.py",
            "derive_budget.py",
        ):
            with self.subTest(governance_name=governance_name):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    queue, _, frozen_status, _, _ = prepare_locked_launch(root)
                    (queue / status.MANIFEST_NAME).unlink()
                    (queue / status.LOCK_NAME).unlink()
                    with (queue / governance_name).open(
                        "a", encoding="utf-8"
                    ) as handle:
                        handle.write("# self-locked tamper\n")
                    locker.lock_package(queue)
                    completed = frozen_queue_gate(frozen_status, queue)
                    self.assertNotEqual(completed.returncode, 0)
                    self.assertIn("differs from frozen source", completed.stderr)

        # Even a rewritten freeze manifest remains bound by the retained
        # anchor result, so a post-anchor frozen-tool substitution fails.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            queue, freeze, frozen_status, _, _ = prepare_locked_launch(root)
            (queue / status.MANIFEST_NAME).unlink()
            (queue / status.LOCK_NAME).unlink()
            archived_tool = freeze / "source" / "queue_tools" / "derive_budget.py"
            old_hash = status.sha256_file(archived_tool)
            with archived_tool.open("a", encoding="utf-8") as handle:
                handle.write("# substituted after anchor\n")
            new_hash = status.sha256_file(archived_tool)
            freeze_manifest = freeze / "freeze_manifest.toml"
            freeze_manifest.write_text(
                freeze_manifest.read_text(encoding="utf-8").replace(
                    f'sha256 = "{old_hash}"', f'sha256 = "{new_hash}"'
                ),
                encoding="utf-8",
            )
            shutil.copy2(archived_tool, queue / "derive_budget.py")
            write_tree_checksum_manifest(freeze)
            locker.lock_package(queue)
            completed = frozen_queue_gate(frozen_status, queue)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("not bound to the current frozen source tree", completed.stderr)

        # Both locked budgets must identify the exact measured anchor.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            queue, _, frozen_status, _, _ = prepare_locked_launch(root)
            (queue / status.MANIFEST_NAME).unlink()
            (queue / status.LOCK_NAME).unlink()
            budget = queue / "budget_transfer.toml"
            original_hash = next(
                line.split('"')[1]
                for line in budget.read_text(encoding="utf-8").splitlines()
                if line.startswith("anchor_science_sha256")
            )
            budget.write_text(
                budget.read_text(encoding="utf-8").replace(
                    original_hash, "0" * 64, 1
                ),
                encoding="utf-8",
            )
            locker.lock_package(queue)
            completed = frozen_queue_gate(frozen_status, queue)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("budget is not bound to the anchor", completed.stderr)

    def test_status_path_is_read_only_for_a_locked_package(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            queue = make_queue(root)
            locker.lock_package(queue)
            before = {
                path.relative_to(queue).as_posix(): status.sha256_file(path)
                for path in queue.rglob("*")
                if path.is_file()
            }
            completed = subprocess.CompletedProcess(
                args=[], returncode=0, stdout="", stderr=""
            )
            with mock.patch.object(status.subprocess, "run", return_value=completed):
                with contextlib.redirect_stdout(io.StringIO()):
                    exit_code = status.main(
                        ["status", "--queue-root", str(queue), "--json"]
                    )
            self.assertEqual(exit_code, 0)
            after = {
                path.relative_to(queue).as_posix(): status.sha256_file(path)
                for path in queue.rglob("*")
                if path.is_file()
            }
            self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
