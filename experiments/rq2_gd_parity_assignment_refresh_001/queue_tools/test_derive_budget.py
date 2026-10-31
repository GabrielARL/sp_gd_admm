#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "derive_budget.py"
PASSES = {
    "primary": (
        "frame_loop",
        "statistics",
        "frame_table_hash",
        "iteration_table_hash",
        "gate_hash",
        "pass_completed",
        "primary_checkpoint",
    ),
    "replay": (
        "frame_loop",
        "statistics",
        "frame_table_hash",
        "iteration_table_hash",
        "gate_hash",
        "pass_completed",
    ),
    "artifact": ("write_result", "checksum_manifest"),
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_anchor(root: Path, *, frame_seconds=(100.0, 50.0), mutate_log=None) -> Path:
    root.mkdir()
    rows = ["utc\tpass\tphase\tseconds"]
    for pass_name, phases in PASSES.items():
        for phase in phases:
            seconds = 1.0
            if (pass_name, phase) == ("primary", "frame_loop"):
                seconds = frame_seconds[0]
            if (pass_name, phase) == ("replay", "frame_loop"):
                seconds = frame_seconds[1]
            rows.append(f"2026-11-01T00:00:00Z\t{pass_name}\t{phase}:start\t0.0")
            rows.append(f"2026-11-01T00:00:01Z\t{pass_name}\t{phase}:end\t{seconds}")
    if mutate_log is not None:
        mutate_log(rows)
    phase_log = root / "phase_log.tsv"
    phase_log.write_text("\n".join(rows) + "\n", encoding="utf-8")

    science = root / "science.json"
    science.write_text(
        json.dumps(
            {
                "experiment_id": "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001",
                "stage": "anchor",
                "frame_count": 24,
                "correctness_passed": True,
                "anchor_expansion_authorized": True,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )
    manifest = root / "manifest.toml"
    manifest.write_text('experiment_id = "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001"\n', encoding="utf-8")
    completion = root / "COMPLETED.toml"
    completion.write_text(
        "\n".join(
            (
                'experiment_id = "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001"',
                'stage = "anchor"',
                'status = "complete_valid"',
                "correctness_passed = true",
                "deterministic_replay_passed = true",
                "anchor_expansion_authorized = true",
                f'science_sha256 = "{sha256(science)}"',
                f'manifest_sha256 = "{sha256(manifest)}"',
            )
        )
        + "\n",
        encoding="utf-8",
    )
    phase_sidecar = root / "PHASE_LOG.sha256"
    phase_sidecar.write_text(f"{sha256(phase_log)}  phase_log.tsv\n", encoding="utf-8")
    files = (completion, manifest, phase_sidecar, science)
    (root / "MANIFEST.sha256").write_text(
        "".join(f"{sha256(path)}  {path.name}\n" for path in sorted(files)),
        encoding="utf-8",
    )
    return root


def run_tool(anchor: Path, output: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "python3",
            str(SCRIPT),
            "--anchor",
            str(anchor),
            "--output",
            str(output),
            "--target-stage",
            "transfer",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


class DeriveBudgetTests(unittest.TestCase):
    def test_registered_formula(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            anchor = write_anchor(root / "anchor")
            output = root / "budget.toml"
            completed = run_tool(anchor, output)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            text = output.read_text(encoding="utf-8")
            self.assertIn("projected_frame_seconds = 1250.000000000", text)
            self.assertIn("projected_post_loop_seconds = 108.333333333", text)
            self.assertIn("wall_budget_seconds = 2038", text)
            self.assertIn("term_after_seconds = 1918", text)

    def test_missing_duplicate_and_error_phase_rows_fail(self) -> None:
        mutations = (
            lambda rows: rows.pop(1),
            lambda rows: rows.append(rows[1]),
            lambda rows: rows.append(
                "2026-11-01T00:00:02Z\tprimary\tframe_loop:error\t0.0"
            ),
        )
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                anchor = write_anchor(root / "anchor", mutate_log=mutation)
                completed = run_tool(anchor, root / "budget.toml")
                self.assertNotEqual(completed.returncode, 0)

    def test_phase_sidecar_mismatch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            anchor = write_anchor(root / "anchor")
            (anchor / "phase_log.tsv").write_text("tampered\n", encoding="utf-8")
            completed = run_tool(anchor, root / "budget.toml")
            self.assertNotEqual(completed.returncode, 0)

    def test_cap_and_overwrite_refusals(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            anchor = write_anchor(root / "anchor", frame_seconds=(3000.0, 3000.0))
            completed = run_tool(anchor, root / "budget.toml")
            self.assertNotEqual(completed.returncode, 0)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            anchor = write_anchor(root / "anchor")
            output = root / "budget.toml"
            output.write_text("existing\n", encoding="utf-8")
            completed = run_tool(anchor, output)
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(output.read_text(encoding="utf-8"), "existing\n")


if __name__ == "__main__":
    unittest.main()
