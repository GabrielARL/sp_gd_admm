#!/usr/bin/env python3
"""Tests for the seven-job freeze, queue lock, ordering, budgets, and gates."""

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


ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "queue_tools"))

import campaign_queue as campaign  # noqa: E402
from prepare_queue import prepare  # noqa: E402

FREEZE_SPEC = importlib.util.spec_from_file_location(
    "native_composition_build_freeze", ROOT / "freeze" / "build_freeze.py"
)
assert FREEZE_SPEC is not None and FREEZE_SPEC.loader is not None
freeze_module = importlib.util.module_from_spec(FREEZE_SPEC)
FREEZE_SPEC.loader.exec_module(freeze_module)


MOCK_RUNNER = r'''#!/usr/bin/env python3
import argparse
import csv
import hashlib
import json
from pathlib import Path
import sys

raw = sys.argv[1:]
if raw[0].startswith("--project="):
    raw.pop(0)
assert raw.pop(0) == "job"
job_id = raw.pop(0)
parser = argparse.ArgumentParser()
parser.add_argument("--config", required=True, type=Path)
parser.add_argument("--rungs", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args(raw)
args.output.mkdir(parents=True)

validation = job_id.startswith(("01_", "02_", "03_"))
counts = {
    "04_fresh_dual_snr_anchor": (48, 11, 2, 11),
    "05_six_db_forward_transfer": (200, 11, 2, 11),
    "06_six_db_order_controls_and_attribution": (400, 11, 2, 13),
    "07_second_snr_confirmation": (200, 11, 2, 11),
}
frames, rungs, passes, variants = (0, 0, 0, 0) if validation else counts[job_id]
forward = [
    "native_projected_gd", "shadow_edge_state",
    "assigned_frozen_compound_box", "assigned_frozen_product_box",
    "assigned_frozen_product_unconstrained",
    "edge_product_residual_gradient_tied",
    "exact_sp_residual_gradient_tied", "exact_sp_residual_gradient_full",
    "exact_sp_direct_full_fixed30", "exact_sp_direct_full_stop30",
    "native_exact_sum_product",
]
controls = ["assigned_frozen_compound_unconstrained", "exact_sp_direct_tied_fixed30"]
frame_columns = [
    "channel", "snr_db", "frame", "noise_seed", "llr_sha256",
    "received_sha256", "rung_id", "backend", "parity_valid",
    "transmitted_word_equal", "coded_bit_errors", "syndrome_weight",
    "updates", "status", "first_valid_update", "first_exact_update",
    "state_sha256", "hard_word_sha256",
]
iteration_columns = [
    "channel", "frame", "rung_id", "update", "accepted",
    "objective_before", "objective_after", "state_sha256",
    "hard_word_sha256", "syndrome_weight", "parity_valid",
    "transmitted_word_equal",
]

def case_specs():
    if job_id == "03_native_endpoint_and_rung_gate":
        return [("six_db", frame) for frame in range(20001, 20025)]
    if job_id == "04_fresh_dual_snr_anchor":
        return ([("six_db", frame) for frame in range(60001, 60025)] +
                [("second_snr", frame) for frame in range(60001, 60025)])
    if job_id == "05_six_db_forward_transfer":
        return [("six_db", frame) for frame in range(60025, 60225)]
    if job_id == "06_six_db_order_controls_and_attribution":
        return ([("six_db", frame) for frame in range(60025, 60225)] +
                [("six_db", frame) for frame in range(30001, 30201)])
    if job_id == "07_second_snr_confirmation":
        return [("second_snr", frame) for frame in range(60225, 60425)]
    return []

cases = case_specs()
frame_rows = []
for channel, frame in cases:
    input_key = f"{channel}:{frame}".encode()
    llr_hash = hashlib.sha256(b"llr:" + input_key).hexdigest()
    received_hash = hashlib.sha256(b"received:" + input_key).hexdigest()
    rung_ids = forward + (controls if job_id == "06_six_db_order_controls_and_attribution" else [])
    for rung_id in rung_ids:
        state_hash = hashlib.sha256((rung_id + ":state:").encode() + input_key).hexdigest()
        hard_hash = hashlib.sha256((rung_id + ":hard:").encode() + input_key).hexdigest()
        frame_rows.append({
            "channel": channel, "snr_db": 6.0 if channel == "six_db" else 1.5,
            "frame": frame, "noise_seed": 20261012 + frame,
            "llr_sha256": llr_hash, "received_sha256": received_hash,
            "rung_id": rung_id, "backend": "mock", "parity_valid": True,
            "transmitted_word_equal": True, "coded_bit_errors": 0,
            "syndrome_weight": 0, "updates": 1, "status": "mock",
            "first_valid_update": 1, "first_exact_update": 1,
            "state_sha256": state_hash, "hard_word_sha256": hard_hash,
        })
iteration_rows = []
if cases:
    channel, frame = cases[0]
    rung_ids = forward + (controls if job_id == "06_six_db_order_controls_and_attribution" else [])
    native = {"native_projected_gd", "shadow_edge_state"}
    block_a = {
        "assigned_frozen_compound_box", "assigned_frozen_product_box",
        "assigned_frozen_product_unconstrained",
        "assigned_frozen_compound_unconstrained",
    }
    product = {"edge_product_residual_gradient_tied"}
    block_b = {
        "exact_sp_residual_gradient_tied", "exact_sp_residual_gradient_full",
        "exact_sp_direct_full_fixed30", "exact_sp_direct_full_stop30",
        "exact_sp_direct_tied_fixed30",
    }
    for rung_id in rung_ids:
        if rung_id == "native_exact_sum_product":
            continue
        state_hash = hashlib.sha256(
            f"{channel}:{frame}:{rung_id}:iteration-state".encode()
        ).hexdigest()
        hard_hash = hashlib.sha256(
            f"{channel}:{frame}:{rung_id}:iteration-hard".encode()
        ).hexdigest()
        if rung_id in native:
            hard_hash = None
            syndrome = parity = exact = None
        elif rung_id in block_a:
            hard_hash = None
            syndrome, parity, exact = 0, True, True
        elif rung_id in block_b:
            state_hash = None
            syndrome, parity, exact = 0, True, True
        elif rung_id in product:
            syndrome, parity, exact = 0, True, True
        else:
            raise AssertionError(f"mock iteration policy missing for {rung_id}")
        iteration_rows.append({
            "channel": channel, "frame": frame, "rung_id": rung_id,
            "update": 1, "accepted": True, "objective_before": 1.0,
            "objective_after": 0.5, "state_sha256": state_hash,
            "hard_word_sha256": hard_hash, "syndrome_weight": syndrome,
            "parity_valid": parity, "transmitted_word_equal": exact,
        })
with (args.output / "frames.csv").open("w", encoding="utf-8", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=frame_columns)
    writer.writeheader()
    writer.writerows(frame_rows)
with (args.output / "iterations.csv").open("w", encoding="utf-8", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=iteration_columns)
    writer.writeheader()
    writer.writerows(iteration_rows)

science_payload = {
    "schema_version": "rq2-native-composition-001/science-v1",
    "experiment_id": "RQ2-NATIVE-COMPOSITION-001",
    "job_id": job_id,
    "validation_only": validation,
}
if validation:
    if job_id == "03_native_endpoint_and_rung_gate":
        science_payload["validation"] = {
            "validation_case_count": 24,
            "gates": {"passed": True},
            "transition_ledger": {},
            "frame_rows_sha256": "a" * 64,
            "iteration_rows_sha256": "b" * 64,
            "frame_row_count": len(frame_rows),
            "iteration_row_count": len(iteration_rows),
        }
    else:
        science_payload["validation"] = {"passed": True}
else:
    science_payload.update({
        "case_count": frames,
        "forward_rung_count": rungs,
        "execution_variant_count": variants,
        "frame_rows": frame_rows,
        "iteration_rows": iteration_rows,
    })
science = json.dumps(science_payload, sort_keys=True, separators=(",", ":")) + "\n"
(args.output / "science.json").write_text(science, encoding="utf-8")
science_hash = hashlib.sha256(science.encode()).hexdigest()

gate_rows = [
    'schema_version = "rq2-native-composition-001/job-gate-v1"',
    'experiment_id = "RQ2-NATIVE-COMPOSITION-001"',
    f'job_id = "{job_id}"',
    f'job_kind = "{"validation" if validation else "science"}"',
    'status = "pass"',
    f'validation_only = {"true" if validation else "false"}',
    'correctness_passed = true',
    'deterministic_replay_passed = true',
    f'config_sha256 = "{hashlib.sha256(args.config.read_bytes()).hexdigest()}"',
    f'rungs_sha256 = "{hashlib.sha256(args.rungs.read_bytes()).hexdigest()}"',
    f'registry_sha256 = "{hashlib.sha256(args.rungs.read_bytes()).hexdigest()}"',
    f'primary_science_sha256 = "{science_hash}"',
    f'replay_science_sha256 = "{science_hash}"',
]
job_gate = "\n".join(gate_rows) + "\n"
(args.output / "job_gate.toml").write_text(job_gate, encoding="utf-8")

endpoint_hash = ""
if not validation:
    endpoint = "\n".join([
        'schema_version = "rq2-native-composition-001/endpoint-gate-v1"',
        'experiment_id = "RQ2-NATIVE-COMPOSITION-001"',
        f'job_id = "{job_id}"',
        'status = "pass"',
        'native_gd_endpoint_equal = true',
        'native_bp_endpoint_equal = true',
        'native_gap_accounted = true',
        'joint_handoff_registered_non_atomic = true',
        'joint_handoff_single_factor_claim_made = false',
    ]) + "\n"
    (args.output / "endpoint_gate.toml").write_text(endpoint, encoding="utf-8")
    endpoint_hash = hashlib.sha256(endpoint.encode()).hexdigest()

if validation:
    primary = replay = write = 0.1
    rate = 0.0
else:
    primary = replay = 120.0
    write = 10.0
    rate = (primary + replay) / (frames * variants)
timing_rows = [
    'schema_version = "rq2-native-composition-001/timing-v1"',
    'experiment_id = "RQ2-NATIVE-COMPOSITION-001"',
    f'job_id = "{job_id}"',
    f'frame_count = {frames}',
    f'rung_count = {rungs}',
    f'pass_count = {passes}',
    f'execution_variant_count = {variants}',
    f'primary_seconds = {primary}',
    f'replay_seconds = {replay}',
    f'write_seconds = {write}',
    f'total_seconds = {primary + replay + write}',
    f'seconds_per_frame_rung = {rate}',
    f'seconds_per_frame_variant = {rate}',
]
if validation:
    timing_rows.append(f'validation_case_count = {24 if job_id.startswith("03_") else 0}')
(args.output / "timing.toml").write_text("\n".join(timing_rows) + "\n", encoding="utf-8")

completion = "\n".join([
    'schema_version = "rq2-native-composition-001/job-completion-v1"',
    'experiment_id = "RQ2-NATIVE-COMPOSITION-001"',
    f'job_id = "{job_id}"',
    'status = "complete_valid"',
    'correctness_passed = true',
    'deterministic_replay_passed = true',
    f'science_sha256 = "{science_hash}"',
    f'job_gate_sha256 = "{hashlib.sha256(job_gate.encode()).hexdigest()}"',
    f'endpoint_gate_sha256 = "{endpoint_hash}"',
]) + "\n"
(args.output / "COMPLETED.toml").write_text(completion, encoding="utf-8")

files = sorted(path for path in args.output.iterdir() if path.is_file())
(args.output / "MANIFEST.sha256").write_text("".join(
    f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in files
), encoding="utf-8")
'''


class CampaignQueueTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = Path(tempfile.mkdtemp(prefix="native-composition-queue-test."))
        self.runner = self.temporary / "native_composition.jl"
        self.runner.write_text(MOCK_RUNNER, encoding="utf-8")
        self.config = self.temporary / "config.toml"
        self.config.write_text('experiment_id = "RQ2-NATIVE-COMPOSITION-001"\n', encoding="utf-8")
        self.rungs = self.temporary / "rung_registry.toml"
        self.rungs.write_text('rung_count = 11\n', encoding="utf-8")
        self.project = self.temporary / "Project.toml"
        self.project.write_text('name = "JadeJcade"\n', encoding="utf-8")
        self.manifest = self.temporary / "Manifest.toml"
        self.manifest.write_text('julia_version = "1.11.5"\n', encoding="utf-8")
        self.package_entry = self.temporary / "JadeJcade.jl"
        self.package_entry.write_text("module JadeJcade\nend\n", encoding="utf-8")
        self.ldpc_helpers: list[tuple[str, Path, str]] = []
        for label, name in (
            ("jade_ldpc_tool_make_ldpc_linux", "make-ldpc"),
            ("jade_ldpc_tool_make_gen_linux", "make-gen"),
            ("jade_ldpc_tool_print_pchk_linux", "print-pchk"),
        ):
            helper = self.temporary / name
            helper.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            helper.chmod(0o755)
            self.ldpc_helpers.append(
                (label, helper, f"source/jade_project/tools/ldpc/{name}")
            )
        self.ldpc_randfile = self.temporary / "randfile"
        self.ldpc_randfile.write_bytes(b"fixture-random-data\n")
        self.ldpc_randfile.chmod(0o644)
        self.preflight = self.temporary / "preflight.toml"
        self.preflight.write_text("\n".join([
            'schema_version = "rq2-native-composition-001/preflight-v1"',
            'experiment_id = "RQ2-NATIVE-COMPOSITION-001"',
            'validation_status = "pass"',
            'runner_tests_passed = true',
            'queue_tests_passed = true',
            'native_gd_endpoint_contract_reviewed = true',
            'native_bp_endpoint_contract_reviewed = true',
            'rung_registry_reviewed = true',
            'joint_handoff_registered_non_atomic = true',
            'single_factor_attribution_for_joint_handoff_forbidden = true',
            'command_contract_reviewed = true',
            '',
        ]), encoding="utf-8")
        self.spec = self.temporary / "freeze_spec.toml"
        sources = [
            ("preflight", self.preflight, "source/preflight_validation.toml"),
            ("runner", self.runner, "source/native_composition.jl"),
            ("config", self.config, "source/config.toml"),
            ("rungs", self.rungs, "source/rung_registry.toml"),
            ("project", self.project, "source/jade_project/Project.toml"),
            ("manifest", self.manifest, "source/jade_project/Manifest.toml"),
            ("package", self.package_entry, "source/jade_project/src/JadeJcade.jl"),
            *self.ldpc_helpers,
            (
                "jade_ldpc_tool_randfile_linux",
                self.ldpc_randfile,
                "source/jade_project/tools/ldpc/src/randfile",
            ),
        ]
        rows = [
            'schema_version = "rq2-native-composition-001/freeze-spec-v1"',
            'experiment_id = "RQ2-NATIVE-COMPOSITION-001"',
            'attempt_id = "test-v1"',
        ]
        for label, path, archive in sources:
            rows.extend([
                "", "[[sources]]", f'label = "{label}"',
                f'path = "{path}"', f'archive_as = "{archive}"',
            ])
        self.spec.write_text("\n".join(rows) + "\n", encoding="utf-8")
        self.freeze = self.temporary / "freeze"
        freeze_module.build_freeze(self.spec, self.freeze)
        self.results = self.temporary / "results"

    def tearDown(self) -> None:
        shutil.rmtree(self.temporary, ignore_errors=True)

    def write_queue_config(self, *, swap_first_two: bool = False) -> Path:
        path = self.temporary / f"queue-input-{len(list(self.temporary.glob('queue-input-*')))}.toml"
        order = list(campaign.JOB_ORDER)
        if swap_first_two:
            order[0], order[1] = order[1], order[0]
        counts = {
            "04_fresh_dual_snr_anchor": (48, 11, 2, 11),
            "05_six_db_forward_transfer": (200, 11, 2, 11),
            "06_six_db_order_controls_and_attribution": (400, 11, 2, 13),
            "07_second_snr_confirmation": (200, 11, 2, 11),
        }
        fixed_timeouts = {
            "01_switch_registry_gate": 1800,
            "02_common_harness_gate": 3600,
            "03_native_endpoint_and_rung_gate": 7200,
            "04_fresh_dual_snr_anchor": 7200,
        }
        rows = [
            'schema_version = "rq2-native-composition-001/queue-v1"',
            'experiment_id = "RQ2-NATIVE-COMPOSITION-001"',
            f'queue_id = "test-{path.stem}"',
            "", "[execution]",
            f'unit_name = "sp-gd-{path.stem}.service"',
            'scientific_unit_pattern = "sp-gd-*.service"',
            'global_lock_name = "sp-gd-scientific.lock"',
            'automatic_restart_allowed = false', 'resume_allowed = false',
            'overwrite_allowed = false', 'julia_threads = 1', 'omp_threads = 1',
            'blas_threads = 1', 'nice = 19', 'ionice_class = "idle"',
            "", "[paths]", f'freeze_root = "{self.freeze}"',
            f'workdir = "{self.temporary}"', f'output_root = "{self.results}"',
            "", "[preflight]", 'archived_relative_path = "source/preflight_validation.toml"',
            f'record_sha256 = "{campaign.sha256_file(self.freeze / "source/preflight_validation.toml")}"',
            'validation_status = "pass"',
        ]
        command = [
            "python3", "{freeze}/source/native_composition.jl",
            "--project={freeze}/source/jade_project", "job", "{job_id}",
            "--config", "{freeze}/source/config.toml", "--rungs",
            "{freeze}/source/rung_registry.toml", "--output", "{output}",
        ]
        for job_id in order:
            validation = job_id in campaign.VALIDATION_JOBS
            frames, rungs, passes, variants = (0, 0, 0, 0) if validation else counts[job_id]
            rows.extend([
                "", "[[jobs]]", f'id = "{job_id}"',
                f'kind = "{"validation" if validation else "science"}"',
                f'output = "{job_id}"', 'termination_grace_seconds = 120',
                f'timeout_seconds = {0 if job_id in campaign.DERIVED_BUDGET_JOBS else fixed_timeouts[job_id]}',
                'budget_safety_factor = 1.5', f'expected_frame_count = {frames}',
                f'expected_rung_count = {rungs}', f'expected_pass_count = {passes}',
                f'expected_execution_variant_count = {variants}',
                "command = [" + ", ".join(f'"{token}"' for token in command) + "]",
            ])
        rows.extend([
            "", "[inventory]",
            'immutable_files = ["README.md", "campaign_queue.py", "launch_detached.sh", "lock_queue_package.py", "queue.toml", "run_queue.sh"]',
            "", "[telemetry]",
            'files = ["queue.lock", "queue.log", "progress.toml", "phase_log.tsv", "status_history.tsv", "QUEUE_COMPLETED.toml", "QUEUE_FAILED.toml"]',
            'prefixes = ["budgets/"]', "",
        ])
        path.write_text("\n".join(rows), encoding="utf-8")
        return path

    def prepare_queue(self) -> Path:
        queue = self.temporary / f"queue-{len(list(self.temporary.glob('queue-*')))}"
        prepare(self.write_queue_config(), queue)
        return queue

    def relock_result(self, result: Path, *, science_changed: bool = False) -> None:
        if science_changed:
            science_hash = campaign.sha256_file(result / "science.json")
            gate = campaign.load_toml(result / "job_gate.toml")
            gate["primary_science_sha256"] = science_hash
            gate["replay_science_sha256"] = science_hash
            (result / "job_gate.toml").write_text(
                campaign.render_toml(gate), encoding="utf-8"
            )
            completion = campaign.load_toml(result / "COMPLETED.toml")
            completion["science_sha256"] = science_hash
            completion["job_gate_sha256"] = campaign.sha256_file(
                result / "job_gate.toml"
            )
            (result / "COMPLETED.toml").write_text(
                campaign.render_toml(completion), encoding="utf-8"
            )
        files = sorted(
            path for path in result.iterdir()
            if path.is_file() and path.name != "MANIFEST.sha256"
        )
        (result / "MANIFEST.sha256").write_text(
            "".join(
                f"{campaign.sha256_file(path)}  {path.name}\n" for path in files
            ),
            encoding="utf-8",
        )

    def rewrite_csv_cell(
        self, path: Path, *, rung_id: str, field: str, value: str
    ) -> None:
        with path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            columns = list(reader.fieldnames or ())
            rows = list(reader)
        matches = [row for row in rows if row["rung_id"] == rung_id]
        self.assertEqual(len(matches), 1)
        matches[0][field] = value
        with path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=columns)
            writer.writeheader()
            writer.writerows(rows)

    def test_freeze_verifies(self) -> None:
        metadata = campaign.verify_freeze(self.freeze)
        self.assertEqual(metadata["experiment_id"], campaign.EXPERIMENT_ID)
        for _, _, archive in self.ldpc_helpers:
            mode = (self.freeze / archive).stat().st_mode
            self.assertEqual(mode & 0o111, 0o111)
        randfile_mode = (
            self.freeze / "source/jade_project/tools/ldpc/src/randfile"
        ).stat().st_mode
        self.assertEqual(randfile_mode & 0o111, 0)

    def test_freeze_without_required_ldpc_runtime_archive_fails_closed(self) -> None:
        required = (
            "source/jade_project/tools/ldpc/make-ldpc",
            "source/jade_project/tools/ldpc/src/randfile",
        )
        for index, missing in enumerate(required):
            with self.subTest(missing=missing):
                altered = self.temporary / f"freeze-without-ldpc-runtime-{index}"
                shutil.copytree(self.freeze, altered)
                (altered / missing).unlink()

                metadata_path = altered / "freeze_manifest.toml"
                metadata = campaign.load_toml(metadata_path)
                sources = [
                    source for source in metadata["sources"]
                    if source["archived_relative_path"] != missing
                ]
                rows = [
                    f'schema_version = {json.dumps(metadata["schema_version"])}',
                    f'experiment_id = {json.dumps(metadata["experiment_id"])}',
                    f'attempt_id = {json.dumps(metadata["attempt_id"])}',
                    f'created_utc = {json.dumps(metadata["created_utc"])}',
                    f'source_spec_sha256 = {json.dumps(metadata["source_spec_sha256"])}',
                    f'file_count = {len(sources)}',
                ]
                for source in sources:
                    rows.extend([
                        "", "[[sources]]",
                        f'label = {json.dumps(source["label"])}',
                        f'original_path = {json.dumps(source["original_path"])}',
                        f'archived_relative_path = {json.dumps(source["archived_relative_path"])}',
                        f'sha256 = {json.dumps(source["sha256"])}',
                        f'executable = {str(source["executable"]).lower()}',
                    ])
                metadata_path.chmod(0o644)
                metadata_path.write_text(
                    "\n".join(rows) + "\n", encoding="utf-8"
                )
                metadata_path.chmod(0o444)

                manifest = altered / "MANIFEST.sha256"
                manifest.chmod(0o644)
                files = sorted(
                    path for path in altered.rglob("*")
                    if path.is_file() and path != manifest
                )
                manifest.write_text(
                    "".join(
                        f"{campaign.sha256_file(path)}  "
                        f"{path.relative_to(altered).as_posix()}\n"
                        for path in files
                    ),
                    encoding="utf-8",
                )
                manifest.chmod(0o444)
                with self.assertRaisesRegex(
                    campaign.GateError, "freeze misses required sources"
                ):
                    campaign.verify_freeze(altered)

    def test_freeze_tamper_fails(self) -> None:
        (self.freeze / "source/config.toml").chmod(0o644)
        (self.freeze / "source/config.toml").write_text("tampered\n", encoding="utf-8")
        with self.assertRaises(campaign.GateError):
            campaign.verify_freeze(self.freeze)

    def test_joint_handoff_single_factor_claim_fails_preflight(self) -> None:
        text = self.preflight.read_text(encoding="utf-8").replace(
            "single_factor_attribution_for_joint_handoff_forbidden = true",
            "single_factor_attribution_for_joint_handoff_forbidden = false",
        )
        self.preflight.write_text(text, encoding="utf-8")
        unsafe_freeze = self.temporary / "unsafe-freeze"
        freeze_module.build_freeze(self.spec, unsafe_freeze)
        record = unsafe_freeze / "source/preflight_validation.toml"
        config = {
            "paths": {"freeze_root": str(unsafe_freeze)},
            "preflight": {
                "archived_relative_path": "source/preflight_validation.toml",
                "record_sha256": campaign.sha256_file(record),
            },
        }
        with self.assertRaises(campaign.GateError):
            campaign.verify_preflight(config)

    def test_queue_order_is_strict(self) -> None:
        with self.assertRaises(campaign.GateError):
            prepare(self.write_queue_config(swap_first_two=True), self.temporary / "bad-queue")

    def test_locked_queue_verifies(self) -> None:
        queue = self.prepare_queue()
        config = campaign.verify_queue_package(queue)
        self.assertEqual([job["id"] for job in config["jobs"]], list(campaign.JOB_ORDER))

    def test_locked_queue_tamper_fails(self) -> None:
        queue = self.prepare_queue()
        (queue / "queue.toml").write_text("tampered\n", encoding="utf-8")
        with self.assertRaises(campaign.GateError):
            campaign.verify_queue_package(queue)

    def test_budget_is_derived_from_anchor_timing(self) -> None:
        job = campaign.queue_config(self.prepare_queue())["jobs"][4]
        budget = campaign.derive_budget({
            "frame_count": 48, "pass_count": 2, "write_seconds": 10.0,
            "seconds_per_frame_variant": 0.5,
        }, job)
        self.assertEqual(budget["timeout_seconds"], 1713)
        self.assertEqual(budget["target_execution_variant_count"], 11)

    def test_all_seven_jobs_run_strictly_and_emit_telemetry(self) -> None:
        queue = self.prepare_queue()
        result = campaign.run_campaign(queue, check_units=False)
        self.assertEqual(result["status"], "complete_valid")
        self.assertEqual(result["completed_jobs"], 7)
        progress = campaign.load_toml(queue / "progress.toml")
        self.assertEqual(progress["completed_jobs"], 7)
        self.assertEqual(progress["status"], "complete_valid")
        for job_id in campaign.DERIVED_BUDGET_JOBS:
            self.assertTrue((queue / "budgets" / f"{job_id}.toml").is_file())
        history = (queue / "status_history.tsv").read_text(encoding="utf-8")
        positions = [history.index(job_id) for job_id in campaign.JOB_ORDER]
        self.assertEqual(positions, sorted(positions))

    def test_completed_queue_cannot_resume(self) -> None:
        queue = self.prepare_queue()
        campaign.run_campaign(queue, check_units=False)
        with self.assertRaises(campaign.GateError):
            campaign.run_campaign(queue, check_units=False)

    def test_unregistered_queue_file_fails_closed(self) -> None:
        queue = self.prepare_queue()
        (queue / "surprise.txt").write_text("not registered\n", encoding="utf-8")
        with self.assertRaises(campaign.GateError):
            campaign.verify_queue_package(queue)

    def test_result_missing_frames_csv_fails_even_with_new_manifest(self) -> None:
        queue = self.prepare_queue()
        campaign.run_campaign(queue, check_units=False)
        config = campaign.queue_config(queue)
        job = config["jobs"][0]
        result = campaign.output_path(config, job)
        (result / "frames.csv").unlink()
        self.relock_result(result)
        with self.assertRaises(campaign.GateError):
            campaign.verify_result(result, job)

    def test_science_count_tamper_fails_with_consistent_hashes(self) -> None:
        queue = self.prepare_queue()
        campaign.run_campaign(queue, check_units=False)
        config = campaign.queue_config(queue)
        job = config["jobs"][3]
        result = campaign.output_path(config, job)
        science_path = result / "science.json"
        science = json.loads(science_path.read_text(encoding="utf-8"))
        science["case_count"] = 47
        science_path.write_text(
            json.dumps(science, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        self.relock_result(result, science_changed=True)
        with self.assertRaises(campaign.GateError):
            campaign.verify_result(result, job)

    def test_job6_missing_control_row_fails_with_new_manifest(self) -> None:
        queue = self.prepare_queue()
        campaign.run_campaign(queue, check_units=False)
        config = campaign.queue_config(queue)
        job = config["jobs"][5]
        result = campaign.output_path(config, job)
        frames_path = result / "frames.csv"
        lines = frames_path.read_text(encoding="utf-8").splitlines(keepends=True)
        self.assertIn("exact_sp_direct_tied_fixed30", lines[-1])
        frames_path.write_text("".join(lines[:-1]), encoding="utf-8")
        self.relock_result(result)
        with self.assertRaises(campaign.GateError):
            campaign.verify_result(result, job)

    def test_job3_reported_row_count_tamper_fails(self) -> None:
        queue = self.prepare_queue()
        campaign.run_campaign(queue, check_units=False)
        config = campaign.queue_config(queue)
        job = config["jobs"][2]
        result = campaign.output_path(config, job)
        science_path = result / "science.json"
        science = json.loads(science_path.read_text(encoding="utf-8"))
        science["validation"]["frame_row_count"] -= 1
        science_path.write_text(
            json.dumps(science, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        self.relock_result(result, science_changed=True)
        with self.assertRaises(campaign.GateError):
            campaign.verify_result(result, job)

    def test_iteration_required_hash_cannot_be_blank(self) -> None:
        queue = self.prepare_queue()
        campaign.run_campaign(queue, check_units=False)
        config = campaign.queue_config(queue)
        job = config["jobs"][3]
        result = campaign.output_path(config, job)
        self.rewrite_csv_cell(
            result / "iterations.csv",
            rung_id="edge_product_residual_gradient_tied",
            field="hard_word_sha256",
            value="",
        )
        self.relock_result(result)
        with self.assertRaises(campaign.GateError):
            campaign.verify_result(result, job)

    def test_iteration_nonempty_invalid_hash_is_rejected(self) -> None:
        queue = self.prepare_queue()
        campaign.run_campaign(queue, check_units=False)
        config = campaign.queue_config(queue)
        job = config["jobs"][3]
        result = campaign.output_path(config, job)
        self.rewrite_csv_cell(
            result / "iterations.csv",
            rung_id="native_projected_gd",
            field="hard_word_sha256",
            value="not_recorded",
        )
        self.relock_result(result)
        with self.assertRaises(campaign.GateError):
            campaign.verify_result(result, job)


if __name__ == "__main__":
    unittest.main()
