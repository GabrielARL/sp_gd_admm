#!/usr/bin/env python3
"""Tests for the exact-map freeze, queue lock, budgets, and result gates."""

from __future__ import annotations

import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "queue_tools"))

import campaign_queue as campaign  # noqa: E402
from prepare_queue import prepare  # noqa: E402

FREEZE_SPEC = importlib.util.spec_from_file_location(
    "exact_map_build_freeze", ROOT / "freeze" / "build_freeze.py"
)
assert FREEZE_SPEC is not None and FREEZE_SPEC.loader is not None
freeze_module = importlib.util.module_from_spec(FREEZE_SPEC)
FREEZE_SPEC.loader.exec_module(freeze_module)

EQUIVALENCE_SPEC = importlib.util.spec_from_file_location(
    "exact_map_source_equivalence",
    ROOT / "freeze" / "verify_source_equivalence.py",
)
assert EQUIVALENCE_SPEC is not None and EQUIVALENCE_SPEC.loader is not None
equivalence_module = importlib.util.module_from_spec(EQUIVALENCE_SPEC)
EQUIVALENCE_SPEC.loader.exec_module(equivalence_module)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_manifest(root: Path, *, name: str = "MANIFEST.sha256") -> None:
    files = sorted(
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path.name != name
    )
    (root / name).write_text(
        "".join(f"{digest(root / relative)}  {relative}\n" for relative in files),
        encoding="utf-8",
    )


def write_csv(path: Path, columns: tuple[str, ...], rows: list[dict[str, object]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def render_endpoint(job_id: str, case_count: int) -> str:
    arm_counts = ", ".join(f"{arm} = {case_count}" for arm in campaign.ARM_IDS)
    failure_counts = ", ".join(f"{arm} = 0" for arm in campaign.ARM_IDS)
    return "\n".join([
        f'schema_version = "{campaign.ENDPOINT_SCHEMA}"',
        f'experiment_id = "{campaign.EXPERIMENT_ID}"',
        f'job_id = "{job_id}"',
        'status = "pass"',
        f"case_count = {case_count}",
        f'case_ids_sha256 = "{"c" * 64}"',
        f'channel_llrs_sha256 = "{"d" * 64}"',
        f"native_bp_successes = {case_count}",
        f"direct_oracle_80_successes = {case_count}",
        "native_bp_direct_oracle_equal = true",
        f"map_unit_fixed30_successes = {case_count}",
        "map_unit_first30_oracle_equal = true",
        "unit_assignment_exact = true",
        f'native_hard_words_sha256 = "{"e" * 64}"',
        f'direct_oracle_80_hard_words_sha256 = "{"e" * 64}"',
        f"arm_success_counts = {{ {arm_counts} }}",
        f"absorbing_failure_counts = {{ {failure_counts} }}",
        "",
    ])


class CampaignQueueTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def queue_text(self) -> str:
        text = (ROOT / "attempts" / "2026-11-01_v1" / "queue.toml").read_text(
            encoding="utf-8"
        )
        return text.replace(
            "/home/gabiel/Documents/GitHub/sp_gd_admm-rq2-bp-gd-causal-ladder-20261101/experiments/rq2_exact_map_update_001/freeze/2026-11-01_v1",
            str(self.base / "freeze"),
        ).replace(
            "/home/gabiel/Documents/GitHub/sp_gd_admm-rq2-bp-gd-causal-ladder-20261101/experiments/rq2_exact_map_update_001/results/2026-11-01_v1",
            str(self.base / "results"),
        ).replace(
            "/home/gabiel/Documents/GitHub/sp_gd_admm-rq2-bp-gd-causal-ladder-20261101",
            str(self.base),
        )

    def make_unlocked_queue(self) -> Path:
        queue = self.base / "queue"
        queue.mkdir()
        sources = {
            "README.md": "test queue\n",
            "campaign_queue.py": "# controller\n",
            "launch_detached.sh": "#!/bin/sh\n",
            "lock_queue_package.py": "# lock\n",
            "queue.toml": self.queue_text(),
            "run_queue.sh": "#!/bin/sh\n",
        }
        for name, content in sources.items():
            (queue / name).write_text(content, encoding="utf-8")
        return queue

    def make_predecessor(self) -> Path:
        root = self.base / "predecessor"
        required = set(freeze_module.REQUIRED_ARCHIVES)
        required -= {
            "rq2_exact_map_update_001/preflight_validation.toml",
            "rq2_exact_map_update_001/exact_map_update.jl",
            "rq2_exact_map_update_001/test_exact_map_update.jl",
            "rq2_exact_map_update_001/config.toml",
            "rq2_exact_map_update_001/experiment_card.md",
        }
        required.add("source/config.toml")
        required.add("source/rung_registry.toml")
        required.add("freeze_manifest.toml")
        for relative in sorted(required):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"predecessor:{relative}\n", encoding="utf-8")
            if relative.startswith("source/jade_project/tools/ldpc/") and "/src/" not in relative:
                path.chmod(0o755)
        write_manifest(root)
        return root

    def make_overlays(self) -> dict[str, Path]:
        overlay = self.base / "overlay"
        overlay.mkdir()
        preflight = "\n".join([
            f'schema_version = "{campaign.PREFLIGHT_SCHEMA}"',
            f'experiment_id = "{campaign.EXPERIMENT_ID}"',
            'validation_status = "pass"',
            "candidate_runner_tests_passed = true",
            "candidate_queue_tests_passed = true",
            "candidate_runner_test_count = 80",
            "candidate_queue_test_count = 16",
            "candidate_full_frame_job_run = false",
            "queued_job1_mandatory_before_science = true",
            "official_runner_revalidation_passed = false",
            "official_runner_test_count = 0",
            "official_static_revalidation_passed = true",
            "official_full_frame_validation_run = false",
            "official_queue_revalidation_passed = true",
            "official_queue_test_count = 16",
            "candidate_official_source_equivalence_passed = true",
            "predecessor_freeze_verified = true",
            "four_arm_contract_reviewed = true",
            "unit_assignment_gate_reviewed = true",
            "deterministic_replay_required = true",
            "command_contract_reviewed = true",
            "",
        ])
        contents = {
            "exact_map_update.jl": "# runner\n",
            "test_exact_map_update.jl": "# tests\n",
            "config.toml": 'schema_version = "rq2-exact-map-update-001/config-v1"\n',
            "experiment_card.md": "# card\n",
            "preflight_validation.toml": preflight,
        }
        result: dict[str, Path] = {}
        for name, content in contents.items():
            path = overlay / name
            path.write_text(content, encoding="utf-8")
            result[name] = path
        return result

    def make_freeze_spec(self, predecessor: Path, overlays: dict[str, Path]) -> Path:
        spec = self.base / "freeze_spec.toml"
        rows = [
            f'schema_version = "{freeze_module.SPEC_SCHEMA}"',
            f'experiment_id = "{freeze_module.EXPERIMENT_ID}"',
            'attempt_id = "test_v1"',
            "",
            "[predecessor]",
            f'root = {json.dumps(str(predecessor))}',
            f'manifest_sha256 = "{digest(predecessor / "MANIFEST.sha256")}"',
        ]
        archive_names = {
            "exact_map_update.jl": "exact_map_runner",
            "test_exact_map_update.jl": "exact_map_test",
            "config.toml": "exact_map_config",
            "experiment_card.md": "exact_map_card",
            "preflight_validation.toml": "exact_map_preflight",
        }
        for name, label in archive_names.items():
            rows.extend([
                "",
                "[[overlays]]",
                f'label = "{label}"',
                f'path = {json.dumps(str(overlays[name]))}',
                f'archive_as = "rq2_exact_map_update_001/{name}"',
            ])
        spec.write_text("\n".join(rows) + "\n", encoding="utf-8")
        return spec

    def job(self, index: int) -> dict[str, object]:
        queue = self.base / f"queue-config-{index}"
        queue.mkdir(exist_ok=True)
        (queue / "queue.toml").write_text(self.queue_text(), encoding="utf-8")
        return campaign.queue_config(queue)["jobs"][index]

    def make_result(
        self, job: dict[str, object], *, replay_mismatch: bool = False,
        bad_case: bool = False,
    ) -> Path:
        result = self.base / f"result-{job['id']}-{replay_mismatch}-{bad_case}"
        result.mkdir()
        job_id = str(job["id"])
        cases = sorted(campaign.EXPECTED_CASES[job_id])
        frame_rows: list[dict[str, object]] = []
        iteration_rows: list[dict[str, object]] = []
        for case_index, (channel, frame) in enumerate(cases):
            if bad_case and case_index == 0:
                frame += 100000
            llr_hash = hashlib.sha256(f"{channel}:{frame}:llr".encode()).hexdigest()
            native_hash = hashlib.sha256(f"{channel}:{frame}:native".encode()).hexdigest()
            for arm in campaign.ARM_IDS:
                hard_hash = hashlib.sha256(f"{channel}:{frame}:{arm}:hard".encode()).hexdigest()
                frame_rows.append({
                    "job_id": job_id, "channel": channel,
                    "snr_db": 6.0 if channel == "six_db" else 1.5,
                    "frame": frame, "noise_seed": 1000 + frame,
                    "llr_sha256": llr_hash, "arm_id": arm,
                    "direction_rule": arm.split("__")[0],
                    "step_rule": arm.split("__")[1],
                    "gradient_evaluated": arm != "map_minus_state__unit",
                    "updates_attempted": 1, "accepted_updates": 1,
                    "line_search_stalls": 0, "non_descent_stalls": 0,
                    "absorbing_failure": False, "failure_update": 0,
                    "objective_evaluations": 2, "first_valid_update": 1,
                    "first_exact_word_update": 1,
                    "terminal_outcome_eligible": True,
                    "terminal_parity_valid": True, "terminal_exact_word": True,
                    "terminal_coded_bit_errors": 0, "terminal_syndrome_weight": 0,
                    "terminal_hard_word_sha256": hard_hash,
                    "terminal_objective": 0.5, "objective_increase_count": 0,
                    "directional_derivative_nonnegative_count": 0,
                    "unit_identity_exact_all": True,
                    "unit_identity_max_abs_error": 0.0,
                    "unit_assignment_exact_all": True,
                    "unit_assignment_max_abs_error": 0.0,
                    "native_valid": True,
                    "native_exact_word": True, "native_iterations": 1,
                    "native_coded_bit_errors": 0,
                    "native_hard_word_sha256": native_hash,
                    "native_endpoint_gate_passed": True,
                })
                iteration_rows.append({
                    "job_id": job_id, "channel": channel, "frame": frame,
                    "arm_id": arm, "direction_rule": arm.split("__")[0],
                    "step_rule": arm.split("__")[1], "update": 1,
                    "objective_before": 1.0, "objective_after": 0.5,
                    "residual_norm_before": 1.0, "residual_norm_after": 0.5,
                    "gradient_norm": 1.0, "direction_norm": 1.0,
                    "directional_derivative": -1.0, "step_size": 1.0,
                    "gradient_evaluated": arm != "map_minus_state__unit",
                    "backtracks": 0, "accepted": True, "non_descent": False,
                    "absorbing_failure": False, "finite_trial": True,
                    "objective_increased": False, "unit_identity_exact": True,
                    "unit_identity_max_abs_error": 0.0,
                    "unit_assignment_exact": True,
                    "unit_assignment_max_abs_error": 0.0,
                    "parity_valid": True,
                    "exact_word": True, "coded_bit_errors": 0,
                    "syndrome_weight": 0,
                    "state_sha256": hashlib.sha256(
                        f"{channel}:{frame}:{arm}:state".encode()
                    ).hexdigest(),
                    "hard_word_sha256": hard_hash,
                })
        frames = result / "frames.csv"
        iterations = result / "iterations.csv"
        write_csv(frames, campaign.FRAME_COLUMNS, frame_rows)
        write_csv(iterations, campaign.ITERATION_COLUMNS, iteration_rows)
        science = {
            "schema_version": campaign.SCIENCE_SCHEMA,
            "experiment_id": campaign.EXPERIMENT_ID,
            "job_id": job_id,
            "validation_only": job["kind"] == "validation",
            "case_count": job["expected_frame_count"],
            "arm_order": list(campaign.ARM_IDS),
            "update_attempts_per_arm": job["expected_update_attempts_per_arm"],
            "frames_sha256": digest(frames),
            "iterations_sha256": digest(iterations),
            "gates": {"passed": True},
            "cases": [],
            "aggregates": {},
            "paired_contrasts": {},
        }
        science_path = result / "science.json"
        science_path.write_text(
            json.dumps(science, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        primary = {
            "science": digest(science_path),
            "frames": digest(frames),
            "iterations": digest(iterations),
        }
        replay = dict(primary)
        if replay_mismatch:
            replay["iterations"] = "f" * 64
        gate_text = campaign.render_toml({
            "schema_version": campaign.JOB_GATE_SCHEMA,
            "experiment_id": campaign.EXPERIMENT_ID,
            "job_id": job_id,
            "job_kind": job["kind"],
            "status": "pass",
            "validation_only": job["kind"] == "validation",
            "correctness_passed": True,
            "deterministic_replay_passed": True,
            "config_sha256": "a" * 64,
            "block_b_runner_sha256": "b" * 64,
            "primary_science_sha256": primary["science"],
            "replay_science_sha256": replay["science"],
            "primary_frames_sha256": primary["frames"],
            "replay_frames_sha256": replay["frames"],
            "primary_iterations_sha256": primary["iterations"],
            "replay_iterations_sha256": replay["iterations"],
        })
        gate_path = result / "job_gate.toml"
        gate_path.write_text(gate_text, encoding="utf-8")

        endpoint_hash = ""
        if job["kind"] == "science":
            endpoint = result / "endpoint_gate.toml"
            endpoint.write_text(
                render_endpoint(job_id, int(job["expected_frame_count"])),
                encoding="utf-8",
            )
            endpoint_hash = digest(endpoint)
        timing = {
            "schema_version": campaign.TIMING_SCHEMA,
            "experiment_id": campaign.EXPERIMENT_ID,
            "job_id": job_id,
            "frame_count": job["expected_frame_count"],
            "arm_count": job["expected_arm_count"],
            "update_attempts_per_arm": job["expected_update_attempts_per_arm"],
            "pass_count": job["expected_pass_count"],
            "primary_seconds": 10.0,
            "replay_seconds": 10.0,
            "write_seconds": 1.0,
            "total_seconds": 21.0,
            "seconds_per_case_arm": 20.0 / (
                int(job["expected_frame_count"]) * int(job["expected_arm_count"])
                * int(job["expected_pass_count"])
            ),
        }
        (result / "timing.toml").write_text(
            campaign.render_toml(timing), encoding="utf-8"
        )
        completion = {
            "schema_version": campaign.COMPLETION_SCHEMA,
            "experiment_id": campaign.EXPERIMENT_ID,
            "job_id": job_id,
            "status": "complete_valid",
            "correctness_passed": True,
            "deterministic_replay_passed": True,
            "science_sha256": digest(science_path),
            "frames_sha256": digest(frames),
            "iterations_sha256": digest(iterations),
            "job_gate_sha256": digest(gate_path),
            "endpoint_gate_sha256": endpoint_hash,
        }
        (result / "COMPLETED.toml").write_text(
            campaign.render_toml(completion), encoding="utf-8"
        )
        write_manifest(result)
        return result

    def test_queue_contract_accepts_registered_four_jobs(self) -> None:
        queue = self.base / "config"
        queue.mkdir()
        (queue / "queue.toml").write_text(self.queue_text(), encoding="utf-8")
        config = campaign.queue_config(queue)
        self.assertEqual([job["id"] for job in config["jobs"]], list(campaign.JOB_ORDER))
        self.assertEqual(config["jobs"][0]["expected_frame_count"], 24)
        self.assertEqual(config["jobs"][1]["expected_frame_count"], 48)
        self.assertEqual(config["jobs"][2]["timeout_seconds"], 0)

    def test_queue_contract_rejects_wrong_order(self) -> None:
        queue = self.base / "wrong-order"
        queue.mkdir()
        text = self.queue_text().replace(
            'id = "01_validation_reproduction_gate"',
            'id = "99_wrong"',
            1,
        )
        (queue / "queue.toml").write_text(text, encoding="utf-8")
        with self.assertRaises(campaign.GateError):
            campaign.queue_config(queue)

    def test_queue_contract_rejects_workload_or_command_drift(self) -> None:
        for old, new in (
            ("expected_arm_count = 4", "expected_arm_count = 3"),
            (
                "{freeze}/rq2_exact_map_update_001/exact_map_update.jl",
                "{freeze}/source/native_composition.jl",
            ),
        ):
            queue = self.base / hashlib.sha256(old.encode()).hexdigest()[:8]
            queue.mkdir()
            (queue / "queue.toml").write_text(
                self.queue_text().replace(old, new, 1), encoding="utf-8"
            )
            with self.assertRaises(campaign.GateError):
                campaign.queue_config(queue)

    def test_queue_package_lock_and_tamper_gate(self) -> None:
        queue = self.make_unlocked_queue()
        campaign.lock_queue_package(queue)
        campaign.verify_queue_package(queue)
        (queue / "campaign_queue.py").chmod(0o644)
        (queue / "campaign_queue.py").write_text("# tampered\n", encoding="utf-8")
        with self.assertRaises(campaign.GateError):
            campaign.verify_queue_package(queue)

    def test_prepare_queue_creates_one_time_locked_package(self) -> None:
        config = self.base / "queue.toml"
        config.write_text(self.queue_text(), encoding="utf-8")
        output = self.base / "prepared"
        prepared = prepare(config, output)
        self.assertEqual(prepared["queue_root"], str(output))
        campaign.verify_queue_package(output)
        with self.assertRaises(campaign.GateError):
            prepare(config, output)

    def test_freeze_copies_verified_predecessor_without_old_metadata(self) -> None:
        predecessor = self.make_predecessor()
        overlays = self.make_overlays()
        spec = self.make_freeze_spec(predecessor, overlays)
        output = self.base / "freeze"
        built = freeze_module.build_freeze(spec, output)
        self.assertEqual(built["overlay_file_count"], 5)
        self.assertNotEqual(
            digest(output / "MANIFEST.sha256"),
            digest(predecessor / "MANIFEST.sha256"),
        )
        self.assertEqual(
            (output / "source/native_composition.jl").read_text(encoding="utf-8"),
            (predecessor / "source/native_composition.jl").read_text(encoding="utf-8"),
        )
        metadata = campaign.verify_freeze(output)
        self.assertEqual(metadata["predecessor_manifest_sha256"], digest(predecessor / "MANIFEST.sha256"))
        self.assertTrue((output / "rq2_exact_map_update_001/exact_map_update.jl").is_file())

    def test_freeze_rejects_bad_predecessor_digest_and_overwrite(self) -> None:
        predecessor = self.make_predecessor()
        overlays = self.make_overlays()
        spec = self.make_freeze_spec(predecessor, overlays)
        text = spec.read_text(encoding="utf-8").replace(
            digest(predecessor / "MANIFEST.sha256"), "0" * 64
        )
        spec.write_text(text, encoding="utf-8")
        with self.assertRaises(freeze_module.FreezeError):
            freeze_module.build_freeze(spec, self.base / "freeze")
        spec = self.make_freeze_spec(predecessor, overlays)
        output = self.base / "existing"
        output.mkdir()
        with self.assertRaises(freeze_module.FreezeError):
            freeze_module.build_freeze(spec, output)

    def test_candidate_official_equivalence_excludes_only_preflight_metadata(self) -> None:
        predecessor = self.make_predecessor()
        overlays = self.make_overlays()
        spec = self.make_freeze_spec(predecessor, overlays)
        candidate = self.base / "candidate"
        freeze_module.build_freeze(spec, candidate)
        overlays["preflight_validation.toml"].write_text(
            overlays["preflight_validation.toml"].read_text(encoding="utf-8")
            + "# final launch record\n",
            encoding="utf-8",
        )
        official = self.base / "official"
        freeze_module.build_freeze(spec, official)
        result = equivalence_module.verify(candidate, official)
        self.assertEqual(result["status"], "equal")
        self.assertGreater(result["scientific_payload_file_count"], 0)
        with self.assertRaises(equivalence_module.EquivalenceError):
            equivalence_module.verify(candidate, candidate)

    def test_preflight_is_hash_bound_and_exact(self) -> None:
        predecessor = self.make_predecessor()
        overlays = self.make_overlays()
        spec = self.make_freeze_spec(predecessor, overlays)
        output = self.base / "freeze"
        freeze_module.build_freeze(spec, output)
        record = output / "rq2_exact_map_update_001/preflight_validation.toml"
        config = {
            "paths": {"freeze_root": str(output)},
            "preflight": {
                "archived_relative_path": "rq2_exact_map_update_001/preflight_validation.toml",
                "record_sha256": digest(record),
            },
        }
        campaign.verify_preflight(config)
        config["preflight"]["record_sha256"] = "0" * 64
        with self.assertRaises(campaign.GateError):
            campaign.verify_preflight(config)

    def test_validation_and_science_results_verify(self) -> None:
        campaign.verify_result(self.make_result(self.job(0)), self.job(0))
        campaign.verify_result(self.make_result(self.job(1)), self.job(1))

    def test_result_rejects_replay_mismatch(self) -> None:
        job = self.job(1)
        with self.assertRaises(campaign.GateError):
            campaign.verify_result(
                self.make_result(job, replay_mismatch=True), job
            )

    def test_result_rejects_case_range_drift(self) -> None:
        job = self.job(2)
        with self.assertRaises(campaign.GateError):
            campaign.verify_result(self.make_result(job, bad_case=True), job)

    def test_result_manifest_rejects_unregistered_file(self) -> None:
        job = self.job(0)
        result = self.make_result(job)
        (result / "extra.txt").write_text("extra\n", encoding="utf-8")
        with self.assertRaises(campaign.GateError):
            campaign.verify_result(result, job)

    def test_anchor_derived_budget_uses_registered_safety(self) -> None:
        anchor = {
            "pass_count": 2,
            "seconds_per_case_arm": 200.0 / (48 * 4 * 2),
            "frame_count": 48,
            "write_seconds": 10.0,
        }
        budget = campaign.derive_budget(anchor, self.job(2))
        self.assertEqual(budget["anchor_job_id"], campaign.JOB_ORDER[1])
        self.assertEqual(budget["target_arm_count"], 4)
        self.assertEqual(budget["target_update_attempts_per_arm"], 30)
        self.assertEqual(budget["safety_factor"], 1.5)
        self.assertEqual(budget["timeout_seconds"], 1313)

    def test_assert_fresh_rejects_existing_output(self) -> None:
        queue = self.make_unlocked_queue()
        campaign.lock_queue_package(queue)
        config = campaign.queue_config(queue)
        output = campaign.output_path(config, config["jobs"][0])
        output.mkdir(parents=True)
        with self.assertRaises(campaign.GateError):
            campaign.assert_fresh(queue)

    def test_controller_runs_strict_order_and_derives_jobs_three_four_budgets(self) -> None:
        queue = self.make_unlocked_queue()
        campaign.lock_queue_package(queue)
        seen: list[str] = []

        def verified(_output: Path, job: dict[str, object]) -> dict[str, object]:
            seen.append(str(job["id"]))
            return {
                "timing": {
                    "pass_count": 2,
                    "seconds_per_case_arm": 200.0 / (48 * 4 * 2),
                    "frame_count": 48,
                    "write_seconds": 10.0,
                }
            }

        with (
            mock.patch.object(campaign, "verify_freeze", return_value={}),
            mock.patch.object(campaign, "verify_preflight", return_value={}),
            mock.patch.object(campaign, "_run_process", return_value=None),
            mock.patch.object(campaign, "verify_result", side_effect=verified),
        ):
            completion = campaign.run_campaign(queue, check_units=False)
        self.assertEqual(seen, list(campaign.JOB_ORDER))
        self.assertEqual(completion["status"], "complete_valid")
        self.assertTrue((queue / "budgets" / f"{campaign.JOB_ORDER[2]}.toml").is_file())
        self.assertTrue((queue / "budgets" / f"{campaign.JOB_ORDER[3]}.toml").is_file())


if __name__ == "__main__":
    unittest.main()
