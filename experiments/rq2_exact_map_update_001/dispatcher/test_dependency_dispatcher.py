#!/usr/bin/env python3
"""Fake-service tests for the exact-map one-shot dependency dispatcher."""

from __future__ import annotations

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


DISPATCHER = Path(__file__).with_name("dependency_dispatcher.py")


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_toml(path: Path) -> dict:
    with path.open("rb") as handle:
        return tomllib.load(handle)


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        self.state = root / "dispatcher-state"
        self.validation_log = root / "validation.log"
        self.systemctl_log = root / "systemctl.jsonl"
        self.systemctl_counts = root / "systemctl-counts.json"
        self.systemctl_mode = root / "systemctl-mode.txt"
        self.launch_count = root / "launch-count.txt"
        self.pred = root / "predecessor-queue"
        self.succ = root / "successor-queue"
        self.pred.mkdir()
        self.succ.mkdir()
        self.pred_results = root / "predecessor-results"
        self.succ_results = root / "successor-results"
        self.pred_results.mkdir()
        self.succ_results.mkdir()
        self.freeze = root / "predecessor-freeze"
        self.freeze.mkdir()
        self.systemctl = root / "fake-systemctl.py"
        self._write_systemctl()
        self.pred_controller = self.pred / "campaign_queue.py"
        self._write_predecessor()
        self.succ_controller = self.succ / "campaign_queue.py"
        self.launcher = self.succ / "launch_detached.sh"
        self._write_successor()
        self.config = root / "controller.toml"
        self._write_config()

    def _write_systemctl(self) -> None:
        self.systemctl.write_text(
            textwrap.dedent(
                f"""\
                #!{sys.executable}
                import json
                from pathlib import Path
                import sys

                log = Path({str(self.systemctl_log)!r})
                counts_path = Path({str(self.systemctl_counts)!r})
                with log.open("a", encoding="utf-8") as handle:
                    handle.write(json.dumps(sys.argv[1:]) + "\\n")
                counts = json.loads(counts_path.read_text()) if counts_path.exists() else {{}}
                unit = sys.argv[sys.argv.index("show") + 1]
                count = counts.get(unit, 0)
                counts[unit] = count + 1
                counts_path.write_text(json.dumps(counts))
                mode_path = Path({str(self.systemctl_mode)!r})
                mode = mode_path.read_text().strip() if mode_path.exists() else "normal"
                missing = unit == "predecessor.service" and (
                    mode == "initial-missing" or (mode == "collected" and count > 0)
                )
                print("LoadState=" + ("not-found" if missing else "loaded"))
                if missing:
                    print("ActiveState=inactive")
                    print("SubState=dead")
                    print("MainPID=0")
                elif unit == "predecessor.service" and count == 0:
                    print("ActiveState=active")
                    print("SubState=running")
                    print("MainPID=123")
                elif unit == "successor.service":
                    print("ActiveState=active")
                    print("SubState=running")
                    print("MainPID=456")
                else:
                    print("ActiveState=inactive")
                    print("SubState=dead")
                    print("MainPID=0")
                """
            ),
            encoding="utf-8",
        )
        self.systemctl.chmod(0o755)

    def _write_predecessor(self) -> None:
        jobs = [
            {"id": f"{index:02d}_job", "output": f"{index:02d}_job"}
            for index in range(1, 8)
        ]
        for job in jobs:
            (self.pred_results / job["output"]).mkdir()
        self.pred_controller.write_text(
            textwrap.dedent(
                f"""\
                from pathlib import Path

                LOG = Path({str(self.validation_log)!r})
                FREEZE = Path({str(self.freeze)!r})
                OUTPUT = Path({str(self.pred_results)!r})
                JOBS = {jobs!r}

                def note(value):
                    with LOG.open("a", encoding="utf-8") as handle:
                        handle.write(value + "\\n")

                def verify_queue_package(root):
                    note("pred:package")
                    return {{"paths": {{"freeze_root": str(FREEZE)}}, "jobs": JOBS}}

                def verify_freeze(path):
                    assert path == FREEZE
                    note("pred:freeze")

                def verify_preflight(config):
                    note("pred:preflight")

                def output_path(config, job):
                    return OUTPUT / job["output"]

                def verify_result(output, job):
                    if Path({str(self.root / 'bad-result')!r}).exists():
                        raise RuntimeError("deliberate bad result")
                    assert output.is_dir()
                    note("pred:result:" + job["id"])
                    return {{"status": "complete_valid"}}
                """
            ),
            encoding="utf-8",
        )
        (self.pred / "QUEUE_COMPLETED.toml").write_text(
            "schema_version = \"rq2-native-composition-001/queue-completion-v1\"\n"
            "experiment_id = \"RQ2-NATIVE-COMPOSITION-001\"\n"
            "queue_id = \"2026-11-01_v2\"\n"
            "status = \"complete_valid\"\n"
            "completed_jobs = 7\n"
            "total_jobs = 7\n",
            encoding="utf-8",
        )
        (self.pred / "progress.toml").write_text(
            "schema_version = \"rq2-native-composition-001/progress-v1\"\n"
            "experiment_id = \"RQ2-NATIVE-COMPOSITION-001\"\n"
            "queue_id = \"2026-11-01_v2\"\n"
            "status = \"complete_valid\"\n"
            "phase = \"queue_complete\"\n"
            "current_job = \"07_second_snr_confirmation\"\n"
            "completed_jobs = 7\n"
            "total_jobs = 7\n",
            encoding="utf-8",
        )

    def _write_successor(self) -> None:
        jobs = [
            {"id": "01_gate", "output": "01_gate"},
            {"id": "02_science", "output": "02_science"},
        ]
        self.succ_controller.write_text(
            textwrap.dedent(
                f"""\
                from pathlib import Path

                LOG = Path({str(self.validation_log)!r})
                OUTPUT = Path({str(self.succ_results)!r})
                JOBS = {jobs!r}

                def note(value):
                    with LOG.open("a", encoding="utf-8") as handle:
                        handle.write(value + "\\n")

                def verify_queue_package(root):
                    note("succ:package")
                    return {{"jobs": JOBS}}

                def assert_fresh(root):
                    note("succ:fresh")
                    assert not any((OUTPUT / job["output"]).exists() for job in JOBS)

                def prelaunch(root):
                    note("succ:prelaunch")
                    return {{"status": "ready"}}

                def output_path(config, job):
                    return OUTPUT / job["output"]
                """
            ),
            encoding="utf-8",
        )
        self.launcher.write_text(
            textwrap.dedent(
                f"""\
                #!{sys.executable}
                from pathlib import Path
                import sys

                root = Path(sys.argv[1])
                count_path = Path({str(self.launch_count)!r})
                count = int(count_path.read_text()) if count_path.exists() else 0
                count_path.write_text(str(count + 1))
                (root / "progress.toml").write_text(
                    'schema_version = "rq2-exact-map-update-001/progress-v1"\\n'
                    'experiment_id = "RQ2-EXACT-MAP-UPDATE-001"\\n'
                    'queue_id = "2026-11-01_v1"\\n'
                    'status = "running"\\n'
                    'completed_jobs = 0\\n'
                )
                """
            ),
            encoding="utf-8",
        )
        self.launcher.chmod(0o755)
        (self.succ / "queue.toml").write_text(
            'experiment_id = "RQ2-EXACT-MAP-UPDATE-001"\nqueue_id = "2026-11-01_v1"\n',
            encoding="utf-8",
        )
        members = (self.succ_controller, self.launcher, self.succ / "queue.toml")
        manifest = self.succ / "QUEUE_MANIFEST.sha256"
        manifest.write_text(
            "".join(f"{sha(path)}  {path.name}\n" for path in members),
            encoding="utf-8",
        )
        (self.succ / "QUEUE_PACKAGE_LOCK.toml").write_text(
            "schema_version = \"rq2-exact-map-update-001/queue-lock-v1\"\n"
            "experiment_id = \"RQ2-EXACT-MAP-UPDATE-001\"\n"
            "queue_id = \"2026-11-01_v1\"\n"
            "status = \"locked\"\n"
            f"queue_manifest_sha256 = \"{sha(manifest)}\"\n",
            encoding="utf-8",
        )

    def _write_config(self) -> None:
        manifest = self.succ / "QUEUE_MANIFEST.sha256"
        lock = self.succ / "QUEUE_PACKAGE_LOCK.toml"
        self.config.write_text(
            textwrap.dedent(
                f"""\
                schema_version = "rq2-exact-map-update-001/dependency-dispatcher-v1"
                dispatcher_id = "2026-11-01_v1-test"

                [controller]
                state_dir = {json.dumps(str(self.state))}
                systemctl = {json.dumps(str(self.systemctl))}
                poll_interval_seconds = 0.01
                max_wait_seconds = 2.0
                confirmation_timeout_seconds = 2.0
                confirmation_poll_seconds = 0.01
                command_timeout_seconds = 2.0

                [predecessor]
                unit_name = "predecessor.service"
                queue_root = {json.dumps(str(self.pred))}
                controller_relative_path = "campaign_queue.py"
                controller_sha256 = "{sha(self.pred_controller)}"
                failed_relative_path = "QUEUE_FAILED.toml"
                completed_relative_path = "QUEUE_COMPLETED.toml"
                progress_relative_path = "progress.toml"

                [successor]
                unit_name = "successor.service"
                queue_root = {json.dumps(str(self.succ))}
                controller_relative_path = "campaign_queue.py"
                controller_sha256 = "{sha(self.succ_controller)}"
                manifest_relative_path = "QUEUE_MANIFEST.sha256"
                manifest_sha256 = "{sha(manifest)}"
                lock_relative_path = "QUEUE_PACKAGE_LOCK.toml"
                lock_sha256 = "{sha(lock)}"
                launch_relative_path = "launch_detached.sh"
                launch_sha256 = "{sha(self.launcher)}"
                launch_arguments = [{json.dumps(str(self.succ))}]
                progress_relative_path = "progress.toml"
                completed_relative_path = "QUEUE_COMPLETED.toml"
                failed_relative_path = "QUEUE_FAILED.toml"
                experiment_id = "RQ2-EXACT-MAP-UPDATE-001"
                queue_id = "2026-11-01_v1"
                progress_schema = "rq2-exact-map-update-001/progress-v1"
                completion_schema = "rq2-exact-map-update-001/queue-completion-v1"
                failure_schema = "rq2-exact-map-update-001/queue-failure-v1"
                """
            ),
            encoding="utf-8",
        )

    def run(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(DISPATCHER), "--config", str(self.config)],
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )


class DispatcherTests(unittest.TestCase):
    def test_success_validates_every_gate_and_launches_once(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            result = fixture.run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((fixture.state / "DISPATCHED.toml").is_file())
            self.assertFalse((fixture.state / "FAILED.toml").exists())
            self.assertEqual(fixture.launch_count.read_text(), "1")
            validation = fixture.validation_log.read_text().splitlines()
            self.assertEqual(
                validation[:3], ["pred:package", "pred:freeze", "pred:preflight"]
            )
            self.assertEqual(
                validation[3:10], [f"pred:result:{index:02d}_job" for index in range(1, 8)]
            )
            self.assertEqual(
                validation[10:], ["succ:package", "succ:fresh", "succ:prelaunch"]
            )
            events = (fixture.state / "events.tsv").read_text().splitlines()
            self.assertEqual(events[0], "utc\tevent\toutcome\tdetail")
            self.assertTrue(any("\tdispatched\t" in row for row in events))
            for line in fixture.systemctl_log.read_text().splitlines():
                argv = json.loads(line)
                self.assertEqual(argv[:2], ["--user", "show"])
                self.assertFalse(any(word in argv for word in ("stop", "kill", "restart")))

            second = fixture.run()
            self.assertEqual(second.returncode, 2)
            self.assertEqual(fixture.launch_count.read_text(), "1")
            self.assertFalse((fixture.state / "FAILED.toml").exists())

    def test_predecessor_failed_marker_blocks_without_launch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            (fixture.pred / "QUEUE_FAILED.toml").write_text("status = \"failed_closed\"\n")
            result = fixture.run()
            self.assertEqual(result.returncode, 2)
            self.assertTrue((fixture.state / "FAILED.toml").is_file())
            self.assertFalse((fixture.state / "DISPATCHED.toml").exists())
            self.assertFalse(fixture.launch_count.exists())

    def test_collected_predecessor_is_accepted_only_after_observed_active(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            fixture.systemctl_mode.write_text("collected\n")
            result = fixture.run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((fixture.state / "DISPATCHED.toml").is_file())
            events = (fixture.state / "events.tsv").read_text()
            self.assertIn("predecessor_collected\tinactive_candidate", events)

    def test_initially_missing_predecessor_cannot_bypass_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            fixture.systemctl_mode.write_text("initial-missing\n")
            result = fixture.run()
            self.assertEqual(result.returncode, 2)
            self.assertIn("before this invocation observed it active", result.stderr)
            self.assertFalse(fixture.launch_count.exists())
            self.assertTrue((fixture.state / "FAILED.toml").is_file())

    def test_predecessor_result_failure_blocks_launch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            (fixture.root / "bad-result").write_text("bad\n")
            result = fixture.run()
            self.assertEqual(result.returncode, 2)
            self.assertIn("deliberate bad result", result.stderr)
            self.assertFalse(fixture.launch_count.exists())
            self.assertTrue((fixture.state / "FAILED.toml").is_file())

    def test_successor_hash_drift_blocks_launch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            with fixture.launcher.open("a", encoding="utf-8") as handle:
                handle.write("# drift\n")
            result = fixture.run()
            self.assertEqual(result.returncode, 2)
            self.assertIn("hash mismatch", result.stderr)
            self.assertFalse(fixture.launch_count.exists())

    def test_existing_successor_output_blocks_launch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            (fixture.succ_results / "01_gate").mkdir()
            result = fixture.run()
            self.assertEqual(result.returncode, 2)
            self.assertFalse(fixture.launch_count.exists())
            self.assertTrue((fixture.state / "FAILED.toml").is_file())


if __name__ == "__main__":
    unittest.main()
