#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
QUEUE_TOOLS = HERE.parent / "queue_tools"
sys.path.insert(0, str(HERE))

import prepare_attempt as prepare  # noqa: E402

PREFLIGHT_TEMPLATE = HERE / prepare.PREFLIGHT_TEMPLATE_NAME


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
    shutil.copy2(PREFLIGHT_TEMPLATE, dispatcher / prepare.PREFLIGHT_TEMPLATE_NAME)
    return repo


def create_passed_preflight(repo: Path, attempt_id: str) -> prepare.AttemptPaths:
    paths = prepare.create_attempt_preflight(repo, attempt_id)
    text = paths.preflight.read_text(encoding="utf-8")
    paths.preflight.write_text(
        text.replace("validation_status: not_run", "validation_status: pass", 1),
        encoding="utf-8",
    )
    return paths


def make_frozen_tools(paths: prepare.AttemptPaths) -> Path:
    tools = paths.freeze / "source/queue_tools"
    tools.mkdir(parents=True)
    for target_name, source_name in prepare.IMMUTABLE_SOURCE_MAP.items():
        source = tools / source_name
        source.write_text(f"frozen:{target_name}\n", encoding="utf-8")
        if source_name.endswith(".sh"):
            source.chmod(source.stat().st_mode | stat.S_IXUSR)
    paths.anchor_result.mkdir(parents=True)
    return tools


class FakePackageCommands:
    def __init__(self) -> None:
        self.commands: list[list[str]] = []

    def __call__(self, argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        command = [str(value) for value in argv]
        self.commands.append(command)
        script = Path(command[1]).name if len(command) > 1 else ""
        if script == "derive_budget.py":
            output = Path(command[command.index("--output") + 1])
            stage = command[command.index("--target-stage") + 1]
            output.write_text(f'target_stage = "{stage}"\n', encoding="utf-8")
        elif script == "lock_queue_package.py":
            queue = Path(command[command.index("--queue-root") + 1])
            (queue / "QUEUE_MANIFEST.sha256").write_text(
                "0" * 64 + "  queue.toml\n", encoding="utf-8"
            )
            (queue / "QUEUE_PACKAGE_LOCK.toml").write_text(
                'state = "locked"\n', encoding="utf-8"
            )
        return subprocess.CompletedProcess(command, 0, "{}\n", "")


class PrepareAttemptTests(unittest.TestCase):
    def test_preflight_is_created_once_from_pinned_template(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = make_repo(Path(temporary))
            paths = prepare.create_attempt_preflight(repo, "attempt_v1")
            self.assertEqual(
                paths.preflight.read_bytes(), PREFLIGHT_TEMPLATE.read_bytes()
            )
            with self.assertRaisesRegex(prepare.PreparationError, "overwrite or resume"):
                prepare.create_attempt_preflight(repo, "attempt_v1")

    def test_initialize_requires_passed_attempt_preflight(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = make_repo(Path(temporary))
            prepare.create_attempt_preflight(repo, "attempt_v1")
            with self.assertRaisesRegex(prepare.PreparationError, "not a unique passed"):
                prepare.initialize_attempt(repo, "attempt_v1")

    def test_preflight_race_never_deletes_other_invocations_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = make_repo(Path(temporary))
            paths = prepare.authored_paths(repo, "attempt_v1")
            original_mkdir = Path.mkdir

            def racing_mkdir(path: Path, *args: object, **kwargs: object) -> None:
                original_mkdir(path, *args, **kwargs)
                if path == paths.preflight.parent:
                    paths.preflight.write_text(
                        "validation_status: fail\ncreated_by: other\n",
                        encoding="utf-8",
                    )

            with mock.patch.object(Path, "mkdir", racing_mkdir):
                with self.assertRaisesRegex(
                    prepare.PreparationError, "overwrite or resume"
                ):
                    prepare.create_attempt_preflight(repo, "attempt_v1")
            self.assertEqual(
                paths.preflight.read_text(encoding="utf-8"),
                "validation_status: fail\ncreated_by: other\n",
            )

    def test_initialize_fills_exact_unique_paths_and_refuses_resume(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = make_repo(Path(temporary))
            create_passed_preflight(repo, "2026-10-31_factorial_v1")
            paths = prepare.initialize_attempt(repo, "2026-10-31_factorial_v1")
            queue = prepare.load_toml(paths.queue_root / "queue.toml")
            self.assertEqual(
                set(path.name for path in paths.queue_root.iterdir()), {"queue.toml"}
            )
            self.assertEqual(queue["paths"]["repository_root"], str(repo.resolve()))
            self.assertEqual(queue["paths"]["project_root"], str(paths.project_root))
            self.assertEqual(
                (repo.resolve() / queue["paths"]["freeze"]), paths.freeze
            )
            self.assertEqual(
                (repo.resolve() / queue["paths"]["preflight"]), paths.preflight
            )
            self.assertEqual(
                paths.preflight,
                repo.resolve()
                / prepare.EXPERIMENT_RELATIVE
                / "preflight/2026-10-31_factorial_v1/preflight_validation.md",
            )
            self.assertEqual(
                (repo.resolve() / queue["paths"]["anchor_result"]),
                paths.anchor_result,
            )
            self.assertEqual(queue["execution"], prepare.REGISTERED_EXECUTION)
            self.assertFalse(paths.freeze.exists())
            self.assertFalse(paths.anchor_result.exists())
            with self.assertRaisesRegex(prepare.PreparationError, "overwrite or resume"):
                prepare.initialize_attempt(repo, "2026-10-31_factorial_v1")

    def test_initialize_rejects_unsafe_attempt_id_before_writing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = make_repo(Path(temporary))
            with self.assertRaisesRegex(prepare.PreparationError, "attempt ID"):
                prepare.initialize_attempt(repo, "../escape")
            self.assertFalse((repo / prepare.EXPERIMENT_RELATIVE / "queue").exists())

    def test_initialize_refuses_any_preexisting_scientific_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = make_repo(Path(temporary))
            create_passed_preflight(repo, "attempt_v1")
            paths = prepare.authored_paths(repo, "attempt_v1")
            paths.transfer_result.mkdir(parents=True)
            with self.assertRaisesRegex(prepare.PreparationError, "overwrite or resume"):
                prepare.initialize_attempt(repo, "attempt_v1")
            self.assertFalse(paths.queue_root.exists())

    def test_queue_race_never_deletes_other_invocations_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = make_repo(Path(temporary))
            paths = create_passed_preflight(repo, "attempt_v1")
            original_mkdir = Path.mkdir

            def racing_mkdir(path: Path, *args: object, **kwargs: object) -> None:
                original_mkdir(path, *args, **kwargs)
                if path == paths.queue_root:
                    (paths.queue_root / "queue.toml").write_text(
                        'queue_id = "created-by-other"\n', encoding="utf-8"
                    )

            with mock.patch.object(Path, "mkdir", racing_mkdir):
                with self.assertRaisesRegex(
                    prepare.PreparationError, "overwrite or resume"
                ):
                    prepare.initialize_attempt(repo, "attempt_v1")
            self.assertEqual(
                (paths.queue_root / "queue.toml").read_text(encoding="utf-8"),
                'queue_id = "created-by-other"\n',
            )

    def test_finalize_copies_only_registered_inventory_derives_then_locks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = make_repo(Path(temporary))
            create_passed_preflight(repo, "attempt_v1")
            paths = prepare.initialize_attempt(repo, "attempt_v1")
            frozen = make_frozen_tools(paths)
            commands = FakePackageCommands()
            result = prepare.finalize_attempt(
                paths.queue_root,
                python_executable="fake-python",
                command_runner=commands,
            )
            self.assertTrue(result["verified"])
            before_sidecars = {
                path.name
                for path in paths.queue_root.iterdir()
                if path.name not in {"QUEUE_MANIFEST.sha256", "QUEUE_PACKAGE_LOCK.toml"}
            }
            self.assertEqual(before_sidecars, prepare.EXPECTED_IMMUTABLE)
            for target_name, source_name in prepare.IMMUTABLE_SOURCE_MAP.items():
                self.assertEqual(
                    (paths.queue_root / target_name).read_bytes(),
                    (frozen / source_name).read_bytes(),
                )
            scripts = [Path(command[1]).name for command in commands.commands]
            self.assertEqual(scripts.count("derive_budget.py"), 2)
            self.assertLess(
                scripts.index("derive_budget.py"), scripts.index("lock_queue_package.py")
            )
            self.assertEqual(scripts[-1], "status_report.py")

    def test_finalize_refuses_dirty_queue_before_running_any_command(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = make_repo(Path(temporary))
            create_passed_preflight(repo, "attempt_v1")
            paths = prepare.initialize_attempt(repo, "attempt_v1")
            make_frozen_tools(paths)
            (paths.queue_root / "unregistered.txt").write_text("x", encoding="utf-8")
            commands = FakePackageCommands()
            with self.assertRaisesRegex(prepare.PreparationError, "not pristine"):
                prepare.finalize_attempt(paths.queue_root, command_runner=commands)
            self.assertEqual(commands.commands, [])

    def test_finalize_refuses_existing_nonanchor_result(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = make_repo(Path(temporary))
            create_passed_preflight(repo, "attempt_v1")
            paths = prepare.initialize_attempt(repo, "attempt_v1")
            make_frozen_tools(paths)
            paths.transfer_result.mkdir(parents=True)
            commands = FakePackageCommands()
            with self.assertRaisesRegex(prepare.PreparationError, "already exists"):
                prepare.finalize_attempt(paths.queue_root, command_runner=commands)
            self.assertEqual(commands.commands, [])


if __name__ == "__main__":
    unittest.main()
