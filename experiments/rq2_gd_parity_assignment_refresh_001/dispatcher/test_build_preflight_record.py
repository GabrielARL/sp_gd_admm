#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import hashlib
import io
from pathlib import Path
import shlex
import sys
import tempfile
import textwrap
import unittest


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import build_preflight_record as builder  # noqa: E402


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def write_checksum_manifest(result: Path) -> Path:
    names = ("COMPLETED.toml", "aggregate.csv", "manifest.toml", "science.json")
    return write(
        result / "MANIFEST.sha256",
        "".join(f"{sha256(result / name)}  {name}\n" for name in names),
    )


def make_prerequisite(root: Path, *, selected: bool = True,
                      strict_schema: bool = False) -> Path:
    result = root / "v3_result"
    result.mkdir(parents=True)
    write(result / "science.json", '{"scientific_sha256":"fixture"}\n')
    write(
        result / "manifest.toml",
        'experiment_id = "RQ2-GD-OFFSET-SPLIT-001"\nstage = "heldout"\n',
    )
    aggregate = textwrap.dedent(
        """\
        endpoint,contrast_id,treatment_arm,reference_arm,treatment_only_success,reference_only_success
        transmitted_word_equal,objective_use_given_bounds0,objective1__bounds0,objective0__bounds0,8,1
        parity_valid,objective_use_given_bounds0,objective1__bounds0,objective0__bounds0,9,2
        """
    )
    write(result / "aggregate.csv", aggregate)
    write(
        result / "COMPLETED.toml",
        textwrap.dedent(
            f"""\
            experiment_id = "RQ2-GD-OFFSET-SPLIT-001"
            stage = "heldout"
            status = "complete_valid"
            correctness_passed = true
            deterministic_replay_passed = true
            science_sha256 = "{sha256(result / 'science.json')}"
            manifest_sha256 = "{sha256(result / 'manifest.toml')}"
            """
        ),
    )
    checksum = write_checksum_manifest(result)
    record = root / "prerequisite.toml"
    state = "selected" if selected else "not_selected"
    passed = "true" if selected else "false"
    if strict_schema:
        body = textwrap.dedent(
            f"""\
            schema_version = "rq2-safe-dispatch/prerequisite-v1"
            experiment_id = "RQ2-GD-OFFSET-SPLIT-001"
            attempt = "v3"
            state = "{state}"
            passed = {passed}
            result = "{result}"
            deterministic_replay_passed = true
            selection_rule_passed = true
            completion_sha256 = "{sha256(result / 'COMPLETED.toml')}"
            manifest_sha256 = "{sha256(result / 'manifest.toml')}"
            science_sha256 = "{sha256(result / 'science.json')}"
            aggregate_sha256 = "{sha256(result / 'aggregate.csv')}"
            checksum_manifest_sha256 = "{sha256(checksum)}"

            [endpoints.transmitted_word_equal]
            treatment_arm = "objective1__bounds0"
            reference_arm = "objective0__bounds0"
            treatment_only_success = 8
            reference_only_success = 1
            passed = true

            [endpoints.parity_valid]
            treatment_arm = "objective1__bounds0"
            reference_arm = "objective0__bounds0"
            treatment_only_success = 9
            reference_only_success = 2
            passed = true
            """
        )
    else:
        body = textwrap.dedent(
            f"""\
            schema_version = "rq2-gd-parity-assignment-refresh-001/prerequisite-selection-v1"
            experiment_id = "RQ2-GD-OFFSET-SPLIT-001"
            attempt = "v3"
            state = "{state}"
            passed = {passed}
            result = "{result}"
            completion_sha256 = "{sha256(result / 'COMPLETED.toml')}"
            manifest_sha256 = "{sha256(result / 'manifest.toml')}"
            science_sha256 = "{sha256(result / 'science.json')}"
            aggregate_sha256 = "{sha256(result / 'aggregate.csv')}"
            checksum_manifest_sha256 = "{sha256(checksum)}"
            treatment_arm = "objective1__bounds0"
            reference_arm = "objective0__bounds0"
            transmitted_word_equal_treatment_only = 8
            transmitted_word_equal_reference_only = 1
            parity_valid_treatment_only = 9
            parity_valid_reference_only = 2
            """
        )
    write(record, body)
    return record


def preflight_text(status_value: str = "not_run") -> str:
    values = {field: "pending" for field in builder.FIELD_ORDER}
    values["validation_status"] = status_value
    values["registered_endpoint_frames_executed_during_preflight"] = "0"
    metadata = "".join(f"{field}: {values[field]}\n" for field in builder.FIELD_ORDER)
    return (
        "# Preflight record for `RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001`\n\n"
        + metadata
        + "\n## Narrative kept byte for byte\n\nDo not replace this sentence.\n"
    )


def make_repository(root: Path) -> tuple[Path, Path]:
    experiment = root / "experiments/rq2_gd_parity_assignment_refresh_001"
    for relative in builder.HASH_PATHS.values():
        write(experiment / relative, f"fixture for {relative}\n")
    preflight = write(experiment / "preflight_validation.md", preflight_text())
    return experiment, preflight


def fake_command(root: Path, name: str, output: str, exit_code: int = 0,
                 sentinel: Path | None = None) -> list[str]:
    sentinel_line = (f"Path({str(sentinel)!r}).write_text('ran', encoding='utf-8')"
                     if sentinel is not None else "pass")
    script = write(
        root / f"{name}.py",
        textwrap.dedent(
            f"""\
            from pathlib import Path
            import sys
            {sentinel_line}
            sys.stdout.write({output!r})
            raise SystemExit({exit_code})
            """
        ),
    )
    return [sys.executable, str(script)]


def fields(path: Path) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = builder.FIELD_LINE.fullmatch(line)
        if match is not None:
            parsed[match.group(1)] = match.group(2)
    return parsed


class BuildPreflightRecordTests(unittest.TestCase):
    def test_count_parsers_use_real_summaries(self) -> None:
        julia = textwrap.dedent(
            """\
            Test Summary:                              | Pass  Total  Time
            RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001       |   87     87  1.2s
            """
        )
        self.assertEqual(builder.parse_julia_test_counts(julia), (87, 87))
        self.assertEqual(
            builder.parse_unittest_counts("Ran 13 tests in 1.0s\n\nOK\n"),
            (13, 13),
        )
        self.assertEqual(
            builder.parse_unittest_counts(
                "Ran 13 tests in 1.0s\nFAILED (failures=2, errors=1)\n"),
            (10, 13),
        )

    def test_strict_controller_record_binds_terminal_result(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prerequisite = make_prerequisite(root, strict_schema=True)
            verified = builder.verify_prerequisite_record(prerequisite)
            self.assertEqual(verified["state"], "selected")
            self.assertTrue(verified["selection_rule_passed"])

    def test_prerequisite_refusal_runs_no_test_command(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, preflight = make_repository(root)
            prerequisite = make_prerequisite(root, selected=False)
            sentinel = root / "suite-ran"
            command = fake_command(root, "must_not_run", "", sentinel=sentinel)
            original = preflight.read_bytes()
            with self.assertRaises(builder.GateError):
                builder.build_record(
                    root, preflight, prerequisite, None,
                    command, command, command,
                )
            self.assertFalse(sentinel.exists())
            self.assertEqual(preflight.read_bytes(), original)

    def test_success_records_exact_hashes_counts_and_preserves_narrative(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            experiment, preflight = make_repository(root)
            prerequisite = make_prerequisite(root)
            julia = fake_command(
                root, "julia",
                "Test Summary: | Pass  Total  Time\nfixture | 91 91 0.1s\n",
            )
            budget = fake_command(root, "budget", "Ran 4 tests in 0.1s\n\nOK\n")
            queue = fake_command(root, "queue", "Ran 13 tests in 0.1s\n\nOK\n")
            narrative = preflight.read_text(encoding="utf-8").split(
                "\n## Narrative", 1)[1]

            self.assertTrue(builder.build_record(
                root, preflight, prerequisite, None, julia, budget, queue))

            actual = fields(preflight)
            self.assertEqual(actual["validation_status"], "pass")
            self.assertEqual(actual["test_exit_code"], "0")
            self.assertEqual(actual["test_assertions_passed"], "91")
            self.assertEqual(actual["test_assertions_total"], "91")
            self.assertEqual(actual["budget_tests_passed"], "4")
            self.assertEqual(actual["queue_tests_passed"], "13")
            self.assertEqual(
                preflight.read_text(encoding="utf-8").split("\n## Narrative", 1)[1],
                narrative,
            )
            for field, relative in builder.HASH_PATHS.items():
                self.assertEqual(actual[field], sha256(experiment / relative))

    def test_failed_suite_records_real_exit_and_is_final(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, preflight = make_repository(root)
            prerequisite = make_prerequisite(root)
            julia = fake_command(
                root, "julia_fail",
                "Test Summary: | Pass  Fail  Total  Time\nfixture | 8 1 9 0.1s\n",
                exit_code=7,
            )
            budget = fake_command(root, "budget", "Ran 4 tests in 0.1s\nOK\n")
            queue = fake_command(root, "queue", "Ran 13 tests in 0.1s\nOK\n")
            self.assertFalse(builder.build_record(
                root, preflight, prerequisite, None, julia, budget, queue))
            actual = fields(preflight)
            self.assertEqual(actual["validation_status"], "fail")
            self.assertEqual(actual["test_exit_code"], "7")
            self.assertEqual(actual["test_assertions_passed"], "8")
            self.assertEqual(actual["test_assertions_total"], "9")
            with self.assertRaises(builder.GateError):
                builder.build_record(
                    root, preflight, prerequisite, None,
                    julia, budget, queue,
                )

    def test_exact_pass_is_reused_without_rerunning_suites(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, preflight = make_repository(root)
            prerequisite = make_prerequisite(root, strict_schema=True)
            julia = fake_command(
                root, "julia",
                "Test Summary: | Pass  Total  Time\nfixture | 91 91 0.1s\n",
            )
            budget = fake_command(root, "budget", "Ran 4 tests in 0.1s\nOK\n")
            queue = fake_command(root, "queue", "Ran 13 tests in 0.1s\nOK\n")
            self.assertTrue(builder.build_record(
                root, preflight, prerequisite, None, julia, budget, queue))
            original = preflight.read_bytes()
            sentinel = root / "suite-reran"
            must_not_run = fake_command(
                root, "must_not_rerun", "", exit_code=9, sentinel=sentinel)
            self.assertTrue(builder.build_record(
                root, preflight, prerequisite, None,
                must_not_run, must_not_run, must_not_run,
            ))
            self.assertFalse(sentinel.exists())
            self.assertEqual(preflight.read_bytes(), original)

    def test_pass_reuse_refuses_changed_source_without_rerunning_suites(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            experiment, preflight = make_repository(root)
            prerequisite = make_prerequisite(root, strict_schema=True)
            julia = fake_command(
                root, "julia",
                "Test Summary: | Pass  Total  Time\nfixture | 91 91 0.1s\n",
            )
            budget = fake_command(root, "budget", "Ran 4 tests in 0.1s\nOK\n")
            queue = fake_command(root, "queue", "Ran 13 tests in 0.1s\nOK\n")
            self.assertTrue(builder.build_record(
                root, preflight, prerequisite, None, julia, budget, queue))
            (experiment / "config.toml").write_text(
                "changed after pass\n", encoding="utf-8"
            )
            sentinel = root / "suite-reran"
            must_not_run = fake_command(
                root, "must_not_rerun", "", exit_code=9, sentinel=sentinel)
            with self.assertRaisesRegex(builder.GateError, "evidence changed"):
                builder.build_record(
                    root, preflight, prerequisite, None,
                    must_not_run, must_not_run, must_not_run,
                )
            self.assertFalse(sentinel.exists())

    def test_cli_command_gate_supports_fixture_commands(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, preflight = make_repository(root)
            prerequisite = fake_command(
                root, "prerequisite",
                '{"state":"selected","passed":true}\n',
            )
            julia = fake_command(
                root, "julia",
                "Test Summary: | Pass  Total  Time\nfixture | 3 3 0.1s\n",
            )
            budget = fake_command(root, "budget", "Ran 4 tests in 0.1s\nOK\n")
            queue = fake_command(root, "queue", "Ran 13 tests in 0.1s\nOK\n")
            arguments = [
                "--repo-root", str(root),
                "--preflight", str(preflight),
                "--prerequisite-command", shlex.join(prerequisite),
                "--julia-command", shlex.join(julia),
                "--budget-command", shlex.join(budget),
                "--queue-command", shlex.join(queue),
            ]
            with contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(builder.main(arguments), 0)
            self.assertEqual(fields(preflight)["validation_status"], "pass")

    def test_symlinked_evidence_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, preflight = make_repository(root)
            prerequisite = make_prerequisite(root)
            result = root / "v3_result"
            original = result / "science.json"
            target = root / "science-target.json"
            original.replace(target)
            original.symlink_to(target)
            command = fake_command(root, "must_not_run", "")
            with self.assertRaises(builder.GateError):
                builder.build_record(
                    root, preflight, prerequisite, None,
                    command, command, command,
                )


if __name__ == "__main__":
    unittest.main()
