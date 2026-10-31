#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib


HERE = Path(__file__).resolve().parent
QUEUE_TOOLS = HERE.parent / "queue_tools"
sys.path.insert(0, str(HERE))

import prepare_attempt as prepare  # noqa: E402
import run_selected_pipeline as pipeline  # noqa: E402


def queue_plan_toml() -> str:
    values = prepare.REGISTERED_EXECUTION
    return f'''experiment_id = "{prepare.EXPERIMENT_ID}"

[queue_plan]
scientific_unit_pattern = "{values["scientific_unit_pattern"]}"
anchor_unit_name = "{values["anchor_unit_name"]}"
queue_unit_name = "{values["queue_unit_name"]}"
anchor_wall_budget_seconds = {values["anchor_wall_budget_seconds"]}
anchor_term_after_seconds = {values["anchor_term_after_seconds"]}
termination_grace_seconds = {values["termination_grace_seconds"]}
maximum_nonanchor_wall_budget_seconds = {values["maximum_nonanchor_wall_budget_seconds"]}
julia_threads = {values["julia_threads"]}
omp_threads = {values["omp_threads"]}
blas_threads = {values["blas_threads"]}
nice = {values["nice"]}
ionice_class = "{values["ionice_class"]}"
'''


def make_repo(root: Path) -> Path:
    repo = root / "repo"
    experiment = repo / prepare.EXPERIMENT_RELATIVE
    vendor = experiment / "vendor/rq2_gd_offset_split_001"
    tools = experiment / "queue_tools"
    dispatcher = experiment / "dispatcher"
    project = root / "project"
    vendor.mkdir(parents=True)
    tools.mkdir()
    dispatcher.mkdir()
    project.mkdir()
    (experiment / "config.toml").write_text(queue_plan_toml(), encoding="utf-8")
    (experiment / "rq2_gd_parity_assignment_refresh_001.jl").write_text(
        "# test runner\n", encoding="utf-8"
    )
    (vendor / "config.toml").write_text(
        f'[sources]\njade_project_repo = "{project}"\n', encoding="utf-8"
    )
    shutil.copy2(QUEUE_TOOLS / "queue_template.toml", tools / "queue_template.toml")
    (dispatcher / "build_preflight_record.py").write_text(
        "# fake preflight builder\n", encoding="utf-8"
    )
    return repo


def systemctl_output(
    *, active: str, result: str = "success", exit_code: str = "0"
) -> str:
    return (
        "LoadState=loaded\n"
        f"ActiveState={active}\n"
        f"SubState={'running' if active == 'active' else 'dead'}\n"
        f"Result={result}\n"
        f"ExecMainStatus={exit_code}\n"
    )


class SequenceRunner:
    def __init__(self, outputs: list[str]) -> None:
        self.outputs = iter(outputs)
        self.commands: list[list[str]] = []

    def __call__(self, argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        command = [str(value) for value in argv]
        self.commands.append(command)
        return subprocess.CompletedProcess(command, 0, next(self.outputs), "")


class FullFakeCommands:
    def __init__(self, repo: Path, attempt_id: str) -> None:
        self.repo = repo.resolve()
        self.attempt_id = attempt_id
        self.commands: list[list[str]] = []

    @property
    def paths(self) -> prepare.AttemptPaths:
        return prepare.authored_paths(self.repo, self.attempt_id)

    def _make_freeze(self, output: Path) -> None:
        tools = output / "source/queue_tools"
        tools.mkdir(parents=True)
        for target_name, source_name in prepare.IMMUTABLE_SOURCE_MAP.items():
            source = tools / source_name
            source.write_text(f"frozen:{target_name}\n", encoding="utf-8")
            if source_name.endswith(".sh"):
                source.chmod(source.stat().st_mode | stat.S_IXUSR)

    def __call__(self, argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        command = [str(value) for value in argv]
        self.commands.append(command)
        if command[0] == "fake-julia":
            self._make_freeze(Path(command[command.index("--output") + 1]))
        elif command[0] == "fake-systemd-run":
            unit_argument = next(value for value in command if value.startswith("--unit="))
            unit = unit_argument.split("=", 1)[1]
            if unit == prepare.REGISTERED_EXECUTION["anchor_unit_name"]:
                self.paths.anchor_result.mkdir(parents=True)
            elif unit == prepare.REGISTERED_EXECUTION["queue_unit_name"]:
                self.paths.transfer_result.mkdir(parents=True)
                self.paths.attribution_result.mkdir(parents=True)
                (self.paths.queue_root / "QUEUE_COMPLETED.toml").write_text(
                    f'''schema_version = "test"
experiment_id = "{prepare.EXPERIMENT_ID}"
state = "complete"
exit_code = 0
recorded_utc = "2026-10-31T00:00:00Z"
''',
                    encoding="utf-8",
                )
        elif command[0] == "fake-systemctl":
            return subprocess.CompletedProcess(
                command, 0, systemctl_output(active="inactive"), ""
            )
        elif len(command) > 1 and Path(command[1]).name == "derive_budget.py":
            output = Path(command[command.index("--output") + 1])
            stage = command[command.index("--target-stage") + 1]
            output.write_text(f'target_stage = "{stage}"\n', encoding="utf-8")
        elif len(command) > 1 and Path(command[1]).name == "lock_queue_package.py":
            queue = Path(command[command.index("--queue-root") + 1])
            (queue / "QUEUE_MANIFEST.sha256").write_text(
                "0" * 64 + "  queue.toml\n", encoding="utf-8"
            )
            (queue / "QUEUE_PACKAGE_LOCK.toml").write_text(
                'state = "locked"\n', encoding="utf-8"
            )
        return subprocess.CompletedProcess(command, 0, "{}\n", "")


class SelectedPipelineTests(unittest.TestCase):
    def test_bridge_handoff_binds_evidence_and_refuses_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            queue = root / "queue"
            queue.mkdir()
            (queue / "QUEUE_COMPLETED.toml").write_text(
                'state = "complete"\n', encoding="utf-8"
            )
            (queue / "QUEUE_MANIFEST.sha256").write_text(
                "0" * 64 + "  queue.toml\n", encoding="utf-8"
            )
            results: dict[str, Path] = {}
            for stage in ("anchor", "transfer", "attribution"):
                result = root / stage
                result.mkdir()
                for name in ("manifest.toml", "science.json", "aggregate.csv"):
                    (result / name).write_text(f"{stage}:{name}\n", encoding="utf-8")
                (result / "COMPLETED.toml").write_text(
                    f'''experiment_id = "{prepare.EXPERIMENT_ID}"
stage = "{stage}"
status = "complete_valid"
correctness_passed = true
deterministic_replay_passed = true
''',
                    encoding="utf-8",
                )
                (result / "MANIFEST.sha256").write_text(
                    "1" * 64 + "  science.json\n", encoding="utf-8"
                )
                results[stage] = result
            decision = root / "selection_decision.toml"
            decision.write_text('state = "selected"\n', encoding="utf-8")
            paths = prepare.AttemptPaths(
                repo_root=root,
                experiment_root=root,
                freeze=root / "freeze",
                anchor_result=results["anchor"],
                transfer_result=results["transfer"],
                attribution_result=results["attribution"],
                queue_root=queue,
                project_root=root / "project",
                config=root / "config.toml",
                runner=root / "runner.jl",
            )
            handoff = root / "controller" / "BRIDGE_REGISTRATION_REQUIRED.toml"
            pipeline.record_bridge_handoff(
                handoff,
                attempt_id="attempt_v1",
                prerequisite_record=decision,
                paths=paths,
                anchor_unit=str(prepare.REGISTERED_EXECUTION["anchor_unit_name"]),
                queue_unit=str(prepare.REGISTERED_EXECUTION["queue_unit_name"]),
            )
            with handoff.open("rb") as handle:
                record = tomllib.load(handle)
            self.assertEqual(record["state"], "bridge_registration_required")
            self.assertTrue(record["factorial_pipeline_complete_valid"])
            self.assertFalse(record["automatic_bridge_launch_allowed"])
            self.assertEqual(record["attempt_id"], "attempt_v1")
            self.assertEqual(
                record["transfer_science_sha256"],
                pipeline.sha256_file(results["transfer"] / "science.json"),
            )
            original = handoff.read_bytes()
            with self.assertRaisesRegex(pipeline.PipelineError, "already exists"):
                pipeline.record_bridge_handoff(
                    handoff,
                    attempt_id="attempt_v1",
                    prerequisite_record=decision,
                    paths=paths,
                    anchor_unit="unused",
                    queue_unit="unused",
                )
            self.assertEqual(handoff.read_bytes(), original)

    def test_parse_systemctl_requires_exact_property_set(self) -> None:
        parsed = pipeline.parse_systemctl_show(systemctl_output(active="active"))
        self.assertEqual(parsed["ActiveState"], "active")
        with self.assertRaisesRegex(pipeline.PipelineError, "property set changed"):
            pipeline.parse_systemctl_show("LoadState=loaded\nActiveState=active\n")

    def test_wait_for_unit_observes_active_then_success_without_signaling(self) -> None:
        runner = SequenceRunner(
            [systemctl_output(active="active"), systemctl_output(active="inactive")]
        )
        clocks = iter([0.0, 1.0])
        result = pipeline.wait_for_unit(
            "registered.service",
            systemctl="fake-systemctl",
            poll_seconds=0,
            timeout_seconds=10,
            command_runner=runner,
            sleeper=lambda _: None,
            clock=lambda: next(clocks),
        )
        self.assertEqual(result["Result"], "success")
        self.assertTrue(all(command[2] == "show" for command in runner.commands))
        forbidden = {"stop", "kill", "restart", "reset-failed"}
        self.assertFalse(
            any(value in forbidden for command in runner.commands for value in command)
        )

    def test_wait_for_unit_rejects_failed_terminal_state(self) -> None:
        runner = SequenceRunner(
            [systemctl_output(active="failed", result="exit-code", exit_code="2")]
        )
        with self.assertRaisesRegex(pipeline.PipelineError, "unit failed"):
            pipeline.wait_for_unit(
                "registered.service",
                systemctl="fake-systemctl",
                poll_seconds=0,
                timeout_seconds=10,
                command_runner=runner,
            )

    def test_wait_accepts_collected_unit_only_after_observing_it_running(self) -> None:
        collected = systemctl_output(active="inactive").replace(
            "LoadState=loaded", "LoadState=not-found"
        )
        runner = SequenceRunner([systemctl_output(active="active"), collected])
        clocks = iter([0.0, 1.0])
        result = pipeline.wait_for_unit(
            "registered.service",
            systemctl="fake-systemctl",
            poll_seconds=0,
            timeout_seconds=10,
            command_runner=runner,
            sleeper=lambda _: None,
            clock=lambda: next(clocks),
        )
        self.assertEqual(result["LoadState"], "not-found")
        unobserved = SequenceRunner([collected])
        with self.assertRaisesRegex(pipeline.PipelineError, "not loaded"):
            pipeline.wait_for_unit(
                "registered.service",
                systemctl="fake-systemctl",
                poll_seconds=0,
                timeout_seconds=10,
                command_runner=unobserved,
            )

    def test_launch_unit_uses_exact_name_environment_and_no_restart(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            wrapper = root / "run.sh"
            wrapper.write_text("#!/bin/sh\n", encoding="utf-8")
            calls: list[list[str]] = []

            def runner(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
                calls.append([str(value) for value in argv])
                return subprocess.CompletedProcess(argv, 0, "", "")

            unit = str(prepare.REGISTERED_EXECUTION["anchor_unit_name"])
            pipeline.launch_unit(
                unit,
                wrapper,
                root / "queue",
                systemd_run="fake-systemd-run",
                command_runner=runner,
            )
            self.assertIn(f"--unit={unit}", calls[0])
            self.assertIn("--no-block", calls[0])
            self.assertIn(f"--setenv=RQ2_QUEUE_ROOT={root / 'queue'}", calls[0])
            self.assertIn("--property=Restart=no", calls[0])
            with self.assertRaisesRegex(pipeline.PipelineError, "unregistered"):
                pipeline.launch_unit(
                    "other.service",
                    wrapper,
                    root / "queue",
                    systemd_run="fake-systemd-run",
                    command_runner=runner,
                )

    def test_full_pipeline_orders_preflight_freeze_anchor_package_and_queue(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = make_repo(root)
            decision = root / "selection_decision.toml"
            decision.write_text('state = "selected"\npassed = true\n', encoding="utf-8")
            fake = FullFakeCommands(repo, "attempt_v1")
            result = pipeline.selected_pipeline(
                repo,
                "attempt_v1",
                decision,
                executables=pipeline.Executables(
                    python="fake-python",
                    julia="fake-julia",
                    systemd_run="fake-systemd-run",
                    systemctl="fake-systemctl",
                ),
                poll_seconds=0,
                command_runner=fake,
                sleeper=lambda _: None,
            )
            self.assertEqual(result["queue_state"], "complete")
            commands = fake.commands
            preflight_index = next(
                index
                for index, command in enumerate(commands)
                if len(command) > 1 and Path(command[1]).name == "build_preflight_record.py"
            )
            freeze_index = next(
                index for index, command in enumerate(commands) if command[0] == "fake-julia"
            )
            unit_indices = [
                index
                for index, command in enumerate(commands)
                if command[0] == "fake-systemd-run"
            ]
            lock_index = next(
                index
                for index, command in enumerate(commands)
                if len(command) > 1 and Path(command[1]).name == "lock_queue_package.py"
            )
            self.assertLess(preflight_index, freeze_index)
            self.assertLess(freeze_index, unit_indices[0])
            self.assertLess(unit_indices[0], lock_index)
            self.assertLess(lock_index, unit_indices[1])
            forbidden = {"stop", "kill", "restart", "reset-failed"}
            self.assertFalse(any(value in forbidden for command in commands for value in command))
            self.assertEqual(
                [
                    next(value for value in commands[index] if value.startswith("--unit="))
                    for index in unit_indices
                ],
                [
                    f'--unit={prepare.REGISTERED_EXECUTION["anchor_unit_name"]}',
                    f'--unit={prepare.REGISTERED_EXECUTION["queue_unit_name"]}',
                ],
            )

    def test_preflight_failure_creates_no_attempt_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = make_repo(root)
            decision = root / "selection_decision.toml"
            decision.write_text('state = "selected"\n', encoding="utf-8")

            def fail_preflight(
                argv: list[str], **_: object
            ) -> subprocess.CompletedProcess[str]:
                return subprocess.CompletedProcess(argv, 2, "", "gate failed")

            with self.assertRaisesRegex(pipeline.PipelineError, "gate failed"):
                pipeline.selected_pipeline(
                    repo,
                    "attempt_v1",
                    decision,
                    command_runner=fail_preflight,
                )
            paths = prepare.authored_paths(repo, "attempt_v1")
            self.assertFalse(paths.queue_root.exists())
            self.assertFalse(paths.freeze.exists())


if __name__ == "__main__":
    unittest.main()
