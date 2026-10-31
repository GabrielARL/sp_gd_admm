#!/usr/bin/env python3
"""Tests for the fail-closed v3 conditional controller."""

from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore[no-redef]


CONTROLLER = Path(__file__).with_name("conditional_controller.py")
sys.path.insert(0, str(CONTROLLER.parent))
import build_preflight_record  # noqa: E402


REFERENCE = "objective0__bounds0"
TREATMENT = "objective1__bounds0"
PHASES = ("preflight", "freeze", "anchor", "package", "queue", "decision")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def toml_array(values: list[str] | tuple[str, ...]) -> str:
    return json.dumps(list(values))


def read_toml(path: Path) -> dict:
    with path.open("rb") as handle:
        return tomllib.load(handle)


class Fixture:
    def __init__(
        self,
        root: Path,
        *,
        states: tuple[str, ...] = ("inactive",),
        helper_exit: int = 0,
        selected: bool = True,
        pipeline: bool = False,
        failing_phase: str = "",
    ):
        self.root = root
        self.state_dir = root / "dispatcher-state"
        self.v3_result = root / "v3-result"
        self.v3_result.mkdir()
        self.queue_terminal = root / "v3-queue-completed.toml"
        self.queue_terminal.write_text("state = \"complete\"\n", encoding="utf-8")
        self.result_terminal = self.v3_result / "COMPLETED.toml"
        self.result_manifest = self.v3_result / "manifest.toml"
        self.result_manifest.write_text(
            "experiment_id = \"RQ2-GD-OFFSET-SPLIT-001\"\nstage = \"heldout\"\n",
            encoding="utf-8",
        )
        self.result_science = self.v3_result / "science.json"
        self.result_science.write_text('{"correctness_passed":true}\n', encoding="utf-8")
        self.result_aggregate = self.v3_result / "aggregate.csv"
        self.result_aggregate.write_text(
            "endpoint,contrast_id,treatment_arm,reference_arm,"
            "treatment_only_success,reference_only_success\n"
            f"transmitted_word_equal,objective_use_given_bounds0,{TREATMENT},"
            f"{REFERENCE},1,0\n"
            f"parity_valid,objective_use_given_bounds0,{TREATMENT},{REFERENCE},1,0\n",
            encoding="utf-8",
        )
        self.result_terminal.write_text(
            "experiment_id = \"RQ2-GD-OFFSET-SPLIT-001\"\n"
            "stage = \"heldout\"\n"
            "status = \"complete_valid\"\n"
            "correctness_passed = true\n"
            "deterministic_replay_passed = true\n"
            f"science_sha256 = \"{sha256(self.result_science)}\"\n"
            f"manifest_sha256 = \"{sha256(self.result_manifest)}\"\n",
            encoding="utf-8",
        )
        self.checksum_manifest = self.v3_result / "MANIFEST.sha256"
        self.checksum_manifest.write_text(
            "\n".join(
                f"{sha256(path)}  {path.name}"
                for path in (
                    self.result_terminal,
                    self.result_aggregate,
                    self.result_manifest,
                    self.result_science,
                )
            )
            + "\n",
            encoding="utf-8",
        )
        self.failed_terminal = self.v3_result / "FAILED.toml"
        self.protected_output = root / "successor-attempt"
        self.phase_log = root / "phase-invocations.tsv"
        self.systemctl_log = root / "systemctl-argv.jsonl"
        self.systemctl_count = root / "systemctl-count.txt"
        self.helper_log = root / "helper-argv.json"
        self.frames_csv = self.v3_result / "frames.csv"
        self._write_frames(selected)
        self.systemctl = root / "fake-systemctl.py"
        self._write_systemctl(states)
        self.helper = root / "fake-status-helper.py"
        self._write_helper(helper_exit)
        self.phase_script = root / "fake-phase.py"
        self._write_phase_script(failing_phase)
        self.config = root / "controller.toml"
        self._write_config(pipeline)

    def _write_frames(self, selected: bool) -> None:
        # Selected: treatment-only wins reference-only 1:0 for both endpoints.
        # Unselected: parity_valid reverses that comparison 0:1.
        rows = [
            ("1", REFERENCE, "false", "false" if selected else "true"),
            ("1", TREATMENT, "true", "true" if selected else "false"),
            ("2", REFERENCE, "true", "true"),
            ("2", TREATMENT, "true", "true"),
            ("3", REFERENCE, "false", "false"),
            ("3", TREATMENT, "false", "false"),
            ("1", "objective0__bounds1", "true", "true"),
        ]
        with self.frames_csv.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle, lineterminator="\n")
            writer.writerow(
                ("frame", "arm", "transmitted_word_equal", "parity_valid")
            )
            writer.writerows(rows)

    def _write_systemctl(self, states: tuple[str, ...]) -> None:
        self.systemctl.write_text(
            textwrap.dedent(
                f"""\
                #!{sys.executable}
                import json
                from pathlib import Path
                import sys

                count_path = Path({str(self.systemctl_count)!r})
                log_path = Path({str(self.systemctl_log)!r})
                states = {states!r}
                count = int(count_path.read_text()) if count_path.exists() else 0
                count_path.write_text(str(count + 1))
                with log_path.open("a", encoding="utf-8") as handle:
                    handle.write(json.dumps(sys.argv[1:]) + "\\n")
                state = states[min(count, len(states) - 1)]
                if state == "active":
                    print("LoadState=loaded")
                    print("ActiveState=active")
                    print("SubState=running")
                    print("MainPID=4321")
                elif state == "failed":
                    print("LoadState=loaded")
                    print("ActiveState=failed")
                    print("SubState=failed")
                    print("MainPID=0")
                else:
                    print("LoadState=loaded")
                    print("ActiveState=inactive")
                    print("SubState=dead")
                    print("MainPID=0")
                """
            ),
            encoding="utf-8",
        )
        self.systemctl.chmod(0o755)

    def _write_helper(self, exit_code: int) -> None:
        self.helper.write_text(
            textwrap.dedent(
                f"""\
                import json
                from pathlib import Path
                import sys

                Path({str(self.helper_log)!r}).write_text(json.dumps(sys.argv[1:]))
                print("fake v3 result gate")
                raise SystemExit({exit_code})
                """
            ),
            encoding="utf-8",
        )

    def _write_phase_script(self, failing_phase: str) -> None:
        self.phase_script.write_text(
            textwrap.dedent(
                f"""\
                from pathlib import Path
                import sys

                phase, log_path, protected = sys.argv[1:]
                with Path(log_path).open("a", encoding="utf-8") as handle:
                    handle.write(phase + "\\n")
                if phase in ("preflight", "pipeline"):
                    Path(protected).mkdir(parents=True, exist_ok=False)
                raise SystemExit(7 if phase == {failing_phase!r} else 0)
                """
            ),
            encoding="utf-8",
        )

    def _write_config(self, pipeline: bool) -> None:
        common_command = [
            sys.executable,
            str(self.phase_script),
            "PHASE",
            str(self.phase_log),
            str(self.protected_output),
        ]
        if pipeline:
            command_lines = (
                "pipeline = "
                + toml_array(
                    [
                        common_command[0],
                        common_command[1],
                        "pipeline",
                        common_command[3],
                        common_command[4],
                    ]
                )
            )
        else:
            command_lines = "\n".join(
                f"{phase} = "
                + toml_array(
                    [
                        common_command[0],
                        common_command[1],
                        phase,
                        common_command[3],
                        common_command[4],
                    ]
                )
                for phase in PHASES
            )
        self.config.write_text(
            textwrap.dedent(
                f"""\
                dispatcher_id = "TEST-DISPATCHER"

                [controller]
                state_dir = {json.dumps(str(self.state_dir))}
                poll_interval_seconds = 0.01
                max_wait_seconds = 2.0
                command_timeout_seconds = 2.0
                command_cwd = {json.dumps(str(self.root))}

                [v3]
                unit = "fake-v3.service"
                systemctl = {json.dumps(str(self.systemctl))}
                result = {json.dumps(str(self.v3_result))}
                frames_csv = {json.dumps(str(self.frames_csv))}
                status_helper = {json.dumps(str(self.helper))}
                status_python = {json.dumps(sys.executable)}
                status_helper_sha256 = "{sha256(self.helper)}"
                required_terminal_files = {toml_array([str(self.queue_terminal), str(self.result_terminal)])}
                failure_terminal_files = {toml_array([str(self.failed_terminal)])}

                [selection]
                reference_arm = "{REFERENCE}"
                treatment_arm = "{TREATMENT}"
                endpoints = ["transmitted_word_equal", "parity_valid"]
                expected_cases = 3

                [safety]
                refuse_existing_paths = {toml_array([str(self.protected_output)])}
                trusted_successor_files = [
                  {{ path = {json.dumps(str(self.phase_script))}, sha256 = "{sha256(self.phase_script)}" }},
                ]

                [commands]
                {command_lines}
                """
            ),
            encoding="utf-8",
        )

    def run(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(CONTROLLER), "--config", str(self.config)],
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )


class ConditionalControllerTests(unittest.TestCase):
    def test_selected_rule_runs_six_phases_and_records_terminal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            completed = fixture.run()
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue((fixture.state_dir / "SELECTED.toml").is_file())
            self.assertFalse((fixture.state_dir / "UNSELECTED.toml").exists())
            self.assertFalse((fixture.state_dir / "FAILED.toml").exists())
            decision = read_toml(fixture.state_dir / "selection_decision.toml")
            self.assertTrue(decision["selected"])
            self.assertEqual(decision["transmitted_word_equal_treatment_only"], 1)
            self.assertEqual(decision["transmitted_word_equal_reference_only"], 0)
            self.assertEqual(decision["parity_valid_treatment_only"], 1)
            self.assertEqual(decision["parity_valid_reference_only"], 0)
            self.assertEqual(
                decision["schema_version"], "rq2-safe-dispatch/prerequisite-v1"
            )
            self.assertEqual(decision["experiment_id"], "RQ2-GD-OFFSET-SPLIT-001")
            self.assertEqual(decision["attempt"], "v3")
            self.assertEqual(decision["controller_config_sha256"], sha256(fixture.config))
            self.assertEqual(decision["state"], "selected")
            self.assertTrue(decision["passed"])
            self.assertTrue(decision["deterministic_replay_passed"])
            self.assertTrue(decision["selection_rule_passed"])
            self.assertEqual(decision["result"], str(fixture.v3_result))
            self.assertEqual(decision["completion_sha256"], sha256(fixture.result_terminal))
            self.assertEqual(decision["manifest_sha256"], sha256(fixture.result_manifest))
            self.assertEqual(decision["science_sha256"], sha256(fixture.result_science))
            self.assertEqual(decision["aggregate_sha256"], sha256(fixture.result_aggregate))
            self.assertEqual(
                decision["checksum_manifest_sha256"],
                sha256(fixture.checksum_manifest),
            )
            for endpoint in ("transmitted_word_equal", "parity_valid"):
                self.assertEqual(
                    decision[f"{endpoint}_treatment_arm"], TREATMENT
                )
                self.assertEqual(
                    decision[f"{endpoint}_reference_arm"], REFERENCE
                )
                endpoint_record = decision["endpoints"][endpoint]
                self.assertEqual(endpoint_record["treatment_arm"], TREATMENT)
                self.assertEqual(endpoint_record["reference_arm"], REFERENCE)
                self.assertEqual(endpoint_record["treatment_only_success"], 1)
                self.assertEqual(endpoint_record["reference_only_success"], 0)
                self.assertTrue(endpoint_record["passed"])
            verified = build_preflight_record.verify_prerequisite_record(
                fixture.state_dir / "selection_decision.toml"
            )
            self.assertEqual(verified["state"], "selected")
            self.assertEqual(
                fixture.phase_log.read_text(encoding="utf-8").splitlines(),
                list(PHASES),
            )
            terminal = read_toml(fixture.state_dir / "SELECTED.toml")
            self.assertEqual(
                terminal["controller_config_sha256"], sha256(fixture.config)
            )
            helper_argv = json.loads(fixture.helper_log.read_text(encoding="utf-8"))
            self.assertEqual(
                helper_argv,
                [
                    "assert-result",
                    "--result",
                    str(fixture.v3_result),
                    "--stage",
                    "heldout",
                ],
            )
            systemctl_argv = json.loads(
                fixture.systemctl_log.read_text(encoding="utf-8").splitlines()[0]
            )
            self.assertIn("show", systemctl_argv)
            for forbidden in ("stop", "kill", "restart", "start", "reset-failed"):
                self.assertNotIn(forbidden, systemctl_argv)

    def test_active_service_is_only_polled_then_inactive_service_continues(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary), states=("active", "inactive"))
            completed = fixture.run()
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(fixture.systemctl_count.read_text(encoding="utf-8"), "2")
            history = (fixture.state_dir / "status_history.tsv").read_text(
                encoding="utf-8"
            )
            self.assertIn("\twaiting\twait_v3\t", history)
            self.assertIn("\tvalidating\tv3_inactive\t", history)

    def test_unselected_rule_stops_cleanly_without_successor_commands(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary), selected=False)
            completed = fixture.run()
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue((fixture.state_dir / "UNSELECTED.toml").is_file())
            self.assertFalse(fixture.phase_log.exists())
            self.assertFalse(fixture.protected_output.exists())
            decision = read_toml(fixture.state_dir / "selection_decision.toml")
            self.assertFalse(decision["selected"])
            self.assertFalse(decision["parity_valid_passed"])
            self.assertEqual(decision["state"], "unselected")
            self.assertFalse(decision["passed"])
            self.assertFalse(decision["selection_rule_passed"])
            self.assertEqual(
                decision["endpoints"]["parity_valid"]["treatment_only_success"],
                0,
            )
            self.assertEqual(
                decision["endpoints"]["parity_valid"]["reference_only_success"],
                1,
            )

    def test_missing_hashed_result_evidence_fails_before_selection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            fixture.result_aggregate.unlink()
            completed = fixture.run()
            self.assertEqual(completed.returncode, 2)
            self.assertTrue((fixture.state_dir / "FAILED.toml").is_file())
            self.assertTrue(fixture.helper_log.is_file())
            self.assertFalse((fixture.state_dir / "selection_decision.toml").exists())
            self.assertFalse(fixture.phase_log.exists())

    def test_missing_terminal_evidence_fails_before_result_helper(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            fixture.queue_terminal.unlink()
            completed = fixture.run()
            self.assertEqual(completed.returncode, 2)
            self.assertTrue((fixture.state_dir / "FAILED.toml").is_file())
            self.assertFalse(fixture.helper_log.exists())
            self.assertFalse(fixture.phase_log.exists())

    def test_hash_pinned_result_helper_failure_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary), helper_exit=9)
            completed = fixture.run()
            self.assertEqual(completed.returncode, 2)
            self.assertTrue((fixture.state_dir / "FAILED.toml").is_file())
            self.assertFalse((fixture.state_dir / "selection_decision.toml").exists())
            self.assertFalse(fixture.phase_log.exists())

    def test_existing_output_is_never_overwritten_or_launched(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            fixture.protected_output.mkdir()
            sentinel = fixture.protected_output / "sentinel"
            sentinel.write_text("keep", encoding="utf-8")
            completed = fixture.run()
            self.assertEqual(completed.returncode, 2)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")
            self.assertFalse(fixture.helper_log.exists())
            self.assertFalse(fixture.phase_log.exists())

    def test_changed_successor_is_refused_after_selection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            with fixture.phase_script.open("a", encoding="utf-8") as handle:
                handle.write("\n# changed after controller configuration\n")
            completed = fixture.run()
            self.assertEqual(completed.returncode, 2)
            self.assertIn("trusted successor hash mismatch", completed.stderr)
            self.assertTrue((fixture.state_dir / "FAILED.toml").is_file())
            self.assertTrue((fixture.state_dir / "selection_decision.toml").is_file())
            self.assertFalse(fixture.phase_log.exists())
            self.assertFalse(fixture.protected_output.exists())

    def test_completed_attempt_is_not_auto_resumed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            first = fixture.run()
            self.assertEqual(first.returncode, 0, first.stderr)
            terminal = fixture.state_dir / "SELECTED.toml"
            original_terminal = terminal.read_bytes()
            original_phases = fixture.phase_log.read_bytes()
            second = fixture.run()
            self.assertEqual(second.returncode, 2)
            self.assertIn("refusing automatic resume", second.stderr)
            self.assertEqual(terminal.read_bytes(), original_terminal)
            self.assertEqual(fixture.phase_log.read_bytes(), original_phases)

    def test_successor_command_failure_records_failure_and_stops(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary), failing_phase="anchor")
            completed = fixture.run()
            self.assertEqual(completed.returncode, 2)
            self.assertTrue((fixture.state_dir / "FAILED.toml").is_file())
            self.assertFalse((fixture.state_dir / "SELECTED.toml").exists())
            self.assertEqual(
                fixture.phase_log.read_text(encoding="utf-8").splitlines(),
                ["preflight", "freeze", "anchor"],
            )

    def test_pipeline_command_mode_is_supported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary), pipeline=True)
            completed = fixture.run()
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(
                fixture.phase_log.read_text(encoding="utf-8").splitlines(),
                ["pipeline"],
            )
            terminal = read_toml(fixture.state_dir / "SELECTED.toml")
            self.assertEqual(terminal["successor_phase_count"], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
