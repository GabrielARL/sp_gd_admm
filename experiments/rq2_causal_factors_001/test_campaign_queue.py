#!/usr/bin/env python3
"""Tests for the campaign freeze, queue lock, gates, and serial ordering."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "queue_tools"))

import campaign_queue as campaign  # noqa: E402
from prepare_queue import prepare  # noqa: E402

FREEZE_SPEC = importlib.util.spec_from_file_location(
    "rq2_build_freeze", ROOT / "freeze" / "build_freeze.py"
)
assert FREEZE_SPEC is not None and FREEZE_SPEC.loader is not None
freeze_module = importlib.util.module_from_spec(FREEZE_SPEC)
FREEZE_SPEC.loader.exec_module(freeze_module)


MOCK_RUNNER = r'''#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import sys

raw = sys.argv[1:]
if raw[0] == "stage":
    raw.pop(0)
    stage_index = raw.index("--stage")
    stage = raw[stage_index + 1]
    del raw[stage_index:stage_index + 2]
else:
    stage = raw.pop(0)
parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--block", required=True)
parser.add_argument("--config")
parser.add_argument("--freeze")
parser.add_argument("--bad-replay", action="store_true")
parser.add_argument("--bad-sentinel", action="store_true")
parser.add_argument("--bad-cross-input", action="store_true")
args = parser.parse_args(raw)
runner_stage = stage
campaign_stage = {
    "calibration": "calibration",
    "anchor": "fresh_anchor",
    "transfer": "fresh_transfer",
    "attribution": "attribution",
}[runner_stage]
args.stage = runner_stage
args.output.mkdir(parents=True)

stages = {
    "calibration": (20001, 20024, 24, 11, 19, 24, "exact"),
    "fresh_anchor": (50001, 50024, 24, 10, 20, 24, "self_consistency"),
    "fresh_transfer": (50025, 50224, 200, 50, 150, 200, "self_consistency"),
    "attribution": (30001, 30200, 200, 107, 167, 200, "exact"),
}
first, last, count, gd, bridge, bp, gate_mode = stages[campaign_stage]
common = {
    "frame_first": first,
    "frame_last": last,
    "frame_count": count,
    "frame_ids_sha256": "d" * 64,
    "channel_llrs_sha256": ("f" if args.bad_cross_input else "e") * 64,
}
if args.block == "A":
    sentinels = {
        **common,
        "native_gd_successes": gd,
        "v4_asbuilt_frozen_successes": bridge,
        "native_bp_successes": bp,
        "native_gd_hard_words_sha256": "a" * 64,
        "v4_asbuilt_frozen_hard_words_sha256": "b" * 64,
        "native_bp_hard_words_sha256": "c" * 64,
    }
else:
    gate_mode = "cross_block_bp"
    sentinels = {
        **common,
        "native_bp_successes": bp,
        "native_bp_hard_words_sha256": "c" * 64,
        "full_direct_successes": bp,
        "full_direct_hard_words_sha256": "c" * 64,
        "native_bp_full_direct_equal": True,
    }
canonical = hashlib.sha256(
    json.dumps(sentinels, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
primary_sentinel = "e" * 64 if args.bad_sentinel else canonical
endpoint_rows = [
    'schema_version = "rq2-causal-factors-001/endpoint-gate-v1"',
    'experiment_id = "RQ2-CAUSAL-FACTORS-001"',
    f'block = "{args.block}"',
    f'stage = "{args.stage}"',
    f'gate_mode = "{gate_mode}"',
    'sentinel_self_consistency_passed = true',
    f'primary_sentinel_sha256 = "{primary_sentinel}"',
    f'replay_sentinel_sha256 = "{canonical}"',
]
for key, value in sentinels.items():
    if isinstance(value, bool):
        rendered = "true" if value else "false"
    elif isinstance(value, str):
        rendered = f'"{value}"'
    else:
        rendered = str(value)
    endpoint_rows.append(f"{key} = {rendered}")
endpoint = "\n".join(endpoint_rows) + "\n"
(args.output / "endpoint_gate.toml").write_text(endpoint, encoding="utf-8")

science = json.dumps({"block": args.block, "stage": args.stage}, sort_keys=True) + "\n"
(args.output / "science.json").write_text(science, encoding="utf-8")
if campaign_stage in ("calibration", "fresh_anchor"):
    timing = "\n".join([
        'schema_version = "rq2-causal-factors-001/stage-timing-v1"',
        'experiment_id = "RQ2-CAUSAL-FACTORS-001"',
        f'block = "{args.block}"',
        f'stage = "{args.stage}"',
        'frame_count = 24',
        'pass_count = 2',
        'scientific_frame_loop_seconds = 120.0',
        'post_loop_seconds = 10.0',
    ]) + "\n"
    (args.output / "timing.toml").write_text(timing, encoding="utf-8")
science_hash = hashlib.sha256(science.encode()).hexdigest()
endpoint_hash = hashlib.sha256(endpoint.encode()).hexdigest()
replay_hash = "d" * 64 if args.bad_replay else science_hash
completion = "\n".join([
    'schema_version = "rq2-causal-factors-001/result-completion-v1"',
    'experiment_id = "RQ2-CAUSAL-FACTORS-001"',
    f'block = "{args.block}"',
    f'stage = "{args.stage}"',
    'status = "complete_valid"',
    'correctness_passed = true',
    'deterministic_replay_passed = true',
    f'science_sha256 = "{science_hash}"',
    f'endpoint_gate_sha256 = "{endpoint_hash}"',
    f'primary_science_sha256 = "{science_hash}"',
    f'replay_science_sha256 = "{replay_hash}"',
]) + "\n"
(args.output / "COMPLETED.toml").write_text(completion, encoding="utf-8")

rows = []
names = ["COMPLETED.toml", "endpoint_gate.toml", "science.json"]
if campaign_stage in ("calibration", "fresh_anchor"):
    names.append("timing.toml")
for name in names:
    digest = hashlib.sha256((args.output / name).read_bytes()).hexdigest()
    rows.append(f"{digest}  {name}\n")
(args.output / "MANIFEST.sha256").write_text("".join(rows), encoding="utf-8")
'''


STAGES = ("calibration", "fresh_anchor", "fresh_transfer", "attribution")
STAGE_VALUES = {
    "calibration": (20001, 20024, 24, 11, 19, 24, "exact"),
    "fresh_anchor": (50001, 50024, 24, 10, 20, 24, "self_consistency"),
    "fresh_transfer": (50025, 50224, 200, 50, 150, 200, "self_consistency"),
    "attribution": (30001, 30200, 200, 107, 167, 200, "exact"),
}


def gate(block: str, stage: str) -> dict[str, object]:
    first, last, count, gd, bridge, bp, mode = STAGE_VALUES[stage]
    if block == "B":
        return {
            "mode": "cross_block_bp",
            "frame_first": first,
            "frame_last": last,
            "frame_count": count,
        }
    result: dict[str, object] = {
        "mode": mode,
        "frame_first": first,
        "frame_last": last,
        "frame_count": count,
    }
    if mode == "exact":
        result.update(
            {
                "frame_ids_sha256": "d" * 64,
                "channel_llrs_sha256": "e" * 64,
                "native_gd_successes": gd,
                "v4_asbuilt_frozen_successes": bridge,
                "native_bp_successes": bp,
                "native_gd_hard_words_sha256": "a" * 64,
                "v4_asbuilt_frozen_hard_words_sha256": "b" * 64,
                "native_bp_hard_words_sha256": "c" * 64,
            }
        )
    return result


def toml_gate(table: str, values: dict[str, object]) -> str:
    rows = [f"[{table}]"]
    for key, value in values.items():
        if isinstance(value, str):
            rows.append(f'{key} = "{value}"')
        else:
            rows.append(f"{key} = {value}")
    return "\n".join(rows)


class CampaignQueueTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = Path(tempfile.mkdtemp(prefix="rq2-causal-queue-test."))
        self.source = self.temporary / "mock_runner.py"
        self.source.write_text(MOCK_RUNNER, encoding="utf-8")
        self.mock_config = self.temporary / "mock_config.toml"
        self.mock_config.write_text('schema_version = "test-v1"\n', encoding="utf-8")
        self.preflight = self.temporary / "preflight_validation.toml"
        self.preflight.write_text(
            "\n".join(
                [
                    'schema_version = "rq2-causal-factors-001/preflight-v1"',
                    'experiment_id = "RQ2-CAUSAL-FACTORS-001"',
                    'validation_status = "pass"',
                    "block_a_tests_passed = true",
                    "block_b_tests_passed = true",
                    "command_contract_reviewed = true",
                    "endpoint_gate_contract_reviewed = true",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        self.spec = self.temporary / "freeze_spec.toml"
        self.spec.write_text(
            "\n".join(
                [
                    'schema_version = "rq2-causal-factors-001/freeze-spec-v1"',
                    'experiment_id = "RQ2-CAUSAL-FACTORS-001"',
                    'attempt_id = "test-v1"',
                    "",
                    "[[sources]]",
                    'label = "preflight_validation"',
                    f'path = "{self.preflight}"',
                    'archive_as = "source/preflight_validation.toml"',
                    "",
                    "[[sources]]",
                    'label = "block_a_runner"',
                    f'path = "{self.source}"',
                    'archive_as = "source/block_a/runner.py"',
                    "",
                    "[[sources]]",
                    'label = "block_a_config"',
                    f'path = "{self.mock_config}"',
                    'archive_as = "source/block_a/config.toml"',
                    "",
                    "[[sources]]",
                    'label = "block_b_runner"',
                    f'path = "{self.source}"',
                    'archive_as = "source/block_b/runner.py"',
                    "",
                    "[[sources]]",
                    'label = "block_b_config"',
                    f'path = "{self.mock_config}"',
                    'archive_as = "source/block_b/config.toml"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        self.freeze = self.temporary / "freeze"
        freeze_module.build_freeze(self.spec, self.freeze)
        self.output_root = self.temporary / "results"

    def tearDown(self) -> None:
        shutil.rmtree(self.temporary, ignore_errors=True)

    def write_config(
        self,
        *,
        bad_fresh_anchor_sentinel: bool = False,
        bad_replay: bool = False,
        bad_attribution_expectation: bool = False,
        bad_block_b_cross_input: bool = False,
    ) -> Path:
        config = self.temporary / "queue-input.toml"
        rows = [
            'schema_version = "rq2-causal-factors-001/queue-v1"',
            'experiment_id = "RQ2-CAUSAL-FACTORS-001"',
            'queue_id = "RQ2-CAUSAL-FACTORS-001.test-v1"',
            "",
            "[execution]",
            'block_order = ["A", "B"]',
            'unit_name = "sp-gd-rq2-causal-factors-test.service"',
            'scientific_unit_pattern = "sp-gd-*.service"',
            'global_lock_name = "sp-gd-scientific.lock"',
            "automatic_restart_allowed = false",
            "resume_allowed = false",
            "overwrite_allowed = false",
            "julia_threads = 1",
            "omp_threads = 1",
            "blas_threads = 1",
            "nice = 19",
            'ionice_class = "idle"',
            "",
            "[paths]",
            f'freeze_root = "{self.freeze}"',
            f'workdir = "{self.temporary}"',
            f'output_root = "{self.output_root}"',
            "",
            "[preflight]",
            'archived_relative_path = "source/preflight_validation.toml"',
            f'record_sha256 = "{campaign.sha256_file(self.freeze / "source" / "preflight_validation.toml")}"',
            'validation_status = "pass"',
        ]
        for block in ("A", "B"):
            rows.extend(["", f"[blocks.{block}]"])
            for stage in STAGES:
                rows.append(f'{stage}_output = "{block.lower()}_{stage}"')
            rows.append("calibration_timeout_seconds = 300")
            rows.append("termination_grace_seconds = 120")
            rows.append("budget_safety_factor = 1.5")
            for stage in STAGES:
                extra = ""
                if block == "A" and stage == "fresh_anchor" and bad_fresh_anchor_sentinel:
                    extra = ', "--bad-sentinel"'
                if block == "B" and stage == "attribution" and bad_replay:
                    extra = ', "--bad-replay"'
                if block == "B" and stage == "calibration" and bad_block_b_cross_input:
                    extra = ', "--bad-cross-input"'
                if block == "A":
                    command = (
                        f'["{sys.executable}", "{{freeze}}/source/block_a/runner.py", '
                        '"{runner_stage}", "--config", "{freeze}/source/block_a/config.toml", '
                        '"--output", "{output}", "--freeze", "{freeze}", "--block", "A"]'
                    )
                else:
                    command = (
                        f'["{sys.executable}", "{{freeze}}/source/block_b/runner.py", '
                        '"stage", "--stage", "{runner_stage}", "--config", '
                        '"{freeze}/source/block_b/config.toml", "--output", "{output}", '
                        '"--block", "B"]'
                    )
                rows.append(f"{stage}_command = {command[:-1]}{extra}]")
            for stage in STAGES:
                values = gate(block, stage)
                if block == "A" and stage == "attribution" and bad_attribution_expectation:
                    values["native_gd_successes"] = 108
                rows.extend(["", toml_gate(f"blocks.{block}.{stage}_gate", values)])
        rows.extend(
            [
                "",
                "[inventory]",
                "immutable_files = [",
                '  "README.md", "campaign_queue.py", "launch_detached.sh",',
                '  "lock_queue_package.py", "queue.toml", "run_queue.sh",',
                "]",
                "",
                "[telemetry]",
                "files = [",
                '  "queue.lock", "queue.log", "progress.toml", "phase_log.tsv",',
                '  "status_history.tsv", "QUEUE_COMPLETED.toml", "QUEUE_FAILED.toml",',
                "]",
                "",
            ]
        )
        config.write_text("\n".join(rows), encoding="utf-8")
        return config

    def prepare(self, **kwargs: object) -> Path:
        queue = self.temporary / "queue"
        prepare(self.write_config(**kwargs), queue)
        return queue

    def test_complete_campaign_is_serial_and_cannot_restart(self) -> None:
        queue = self.prepare()
        config = campaign.queue_config(queue)
        self.assertIn("{runner_stage}", config["blocks"]["A"]["calibration_command"])
        self.assertIn("--freeze", config["blocks"]["A"]["calibration_command"])
        self.assertEqual(
            config["blocks"]["B"]["calibration_command"][2:5],
            ["stage", "--stage", "{runner_stage}"],
        )
        self.assertNotIn("--freeze", config["blocks"]["B"]["calibration_command"])
        rendered_a = campaign._render_command(
            config["blocks"]["A"]["fresh_anchor_command"],
            queue,
            config,
            "A",
            "fresh_anchor",
        )
        self.assertEqual(rendered_a[2], "anchor")
        self.assertIn("--freeze", rendered_a)
        rendered_b = campaign._render_command(
            config["blocks"]["B"]["fresh_transfer_command"],
            queue,
            config,
            "B",
            "fresh_transfer",
        )
        self.assertEqual(rendered_b[2:5], ["stage", "--stage", "transfer"])
        self.assertNotIn("--freeze", rendered_b)
        result = campaign.run_campaign(queue, check_units=False)
        self.assertEqual(result["jobs_completed"], 8)
        self.assertTrue((queue / "QUEUE_COMPLETED.toml").is_file())
        self.assertFalse((queue / "QUEUE_FAILED.toml").exists())
        for block in ("A", "B"):
            anchor_budget = campaign.load_toml(
                queue / "budgets" / f"{block}_fresh_anchor.toml"
            )
            self.assertEqual(anchor_budget["wall_budget_seconds"], 315)
            self.assertEqual(anchor_budget["term_after_seconds"], 195)
            for stage in ("fresh_transfer", "attribution"):
                budget = campaign.load_toml(queue / "budgets" / f"{block}_{stage}.toml")
                self.assertEqual(budget["wall_budget_seconds"], 1635)
                self.assertEqual(budget["term_after_seconds"], 1515)
        for block in ("a", "b"):
            for stage in STAGES:
                self.assertTrue(
                    (self.output_root / f"{block}_{stage}" / "COMPLETED.toml").is_file()
                )
        phase_rows = (queue / "phase_log.tsv").read_text(encoding="utf-8").splitlines()
        starts = [
            "\t".join(row.split("\t")[1:5])
            for row in phase_rows
            if "\tscientific_command\tstart\t" in row
        ]
        self.assertEqual(
            starts,
            [
                f"{block}\t{stage}\tscientific_command\tstart"
                for block in ("A", "B")
                for stage in STAGES
            ],
        )
        with self.assertRaisesRegex(campaign.GateError, "forbids restart"):
            campaign.assert_fresh(queue)

    def test_fresh_anchor_self_consistency_failure_blocks_transfer(self) -> None:
        queue = self.prepare(bad_fresh_anchor_sentinel=True)
        with self.assertRaisesRegex(campaign.GateError, "primary_sentinel_sha256"):
            campaign.run_campaign(queue, check_units=False)
        self.assertTrue((self.output_root / "a_calibration").is_dir())
        self.assertTrue((self.output_root / "a_fresh_anchor").is_dir())
        for name in (
            "a_fresh_transfer",
            "a_attribution",
            "b_calibration",
            "b_fresh_anchor",
            "b_fresh_transfer",
            "b_attribution",
        ):
            self.assertFalse((self.output_root / name).exists())
        self.assertTrue((queue / "QUEUE_FAILED.toml").is_file())

    def test_replay_hash_mismatch_fails_closed(self) -> None:
        queue = self.prepare(bad_replay=True)
        with self.assertRaisesRegex(campaign.GateError, "deterministic_replay_hash"):
            campaign.run_campaign(queue, check_units=False)
        self.assertTrue((self.output_root / "b_attribution").is_dir())
        self.assertTrue((queue / "QUEUE_FAILED.toml").is_file())
        self.assertFalse((queue / "QUEUE_COMPLETED.toml").exists())

    def test_informed_attribution_requires_exact_retained_endpoint(self) -> None:
        queue = self.prepare(bad_attribution_expectation=True)
        with self.assertRaisesRegex(campaign.GateError, "native_gd_successes"):
            campaign.run_campaign(queue, check_units=False)
        self.assertTrue((self.output_root / "a_attribution").is_dir())
        self.assertFalse((self.output_root / "b_calibration").exists())
        self.assertTrue((queue / "QUEUE_FAILED.toml").is_file())

    def test_block_b_cross_checks_block_a_input_and_bp_identity(self) -> None:
        queue = self.prepare(bad_block_b_cross_input=True)
        with self.assertRaisesRegex(campaign.GateError, "block_a_cross_check.channel_llrs_sha256"):
            campaign.run_campaign(queue, check_units=False)
        self.assertTrue((self.output_root / "b_calibration").is_dir())
        self.assertFalse((self.output_root / "b_fresh_anchor").exists())
        endpoint = campaign.load_toml(
            self.output_root / "b_calibration" / "endpoint_gate.toml"
        )
        self.assertNotIn("native_gd_successes", endpoint)
        self.assertNotIn("v4_asbuilt_frozen_successes", endpoint)

    def test_freeze_tamper_invalidates_locked_queue(self) -> None:
        queue = self.prepare()
        frozen_runner = self.freeze / "source" / "block_a" / "runner.py"
        frozen_runner.chmod(0o644)
        frozen_runner.write_text(MOCK_RUNNER + "\n# tampered\n", encoding="utf-8")
        with self.assertRaisesRegex(campaign.GateError, "freeze checksum mismatch"):
            campaign.verify_queue_package(queue)

    def test_active_other_scientific_unit_is_rejected(self) -> None:
        queue = self.prepare()
        config = campaign.queue_config(queue)
        original = campaign.active_scientific_units
        campaign.active_scientific_units = lambda pattern: ["sp-gd-other.service"]
        try:
            with self.assertRaisesRegex(campaign.GateError, "other scientific units"):
                campaign.assert_no_competing_units(config, allow_own=True)
        finally:
            campaign.active_scientific_units = original


if __name__ == "__main__":
    unittest.main()

