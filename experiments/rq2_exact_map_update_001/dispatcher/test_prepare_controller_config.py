#!/usr/bin/env python3
"""Tests for atomic pinning of the attempt-specific controller config."""

from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore[no-redef]


PREPARER = Path(__file__).with_name("prepare_controller_config.py")


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ConfigPreparerTests(unittest.TestCase):
    def fixture(self, root: Path) -> tuple[Path, Path, Path, Path, Path]:
        predecessor = (
            root / "experiments/rq2_native_composition_001/queue/2026-11-01_v2"
        )
        successor = root / "experiments/rq2_exact_map_update_001/queue/2026-11-01_v1"
        predecessor.mkdir(parents=True)
        successor.mkdir(parents=True)
        pred_controller = predecessor / "campaign_queue.py"
        pred_controller.write_text("# predecessor\n", encoding="utf-8")
        files = {
            "campaign_queue.py": "# successor\n",
            "launch_detached.sh": "#!/bin/sh\nexit 0\n",
            "queue.toml": 'queue_id = "2026-11-01_v1"\n',
        }
        for name, text in files.items():
            (successor / name).write_text(text, encoding="utf-8")
        manifest = successor / "QUEUE_MANIFEST.sha256"
        manifest.write_text(
            "".join(f"{sha(successor / name)}  {name}\n" for name in files),
            encoding="utf-8",
        )
        lock = successor / "QUEUE_PACKAGE_LOCK.toml"
        lock.write_text(
            'experiment_id = "RQ2-EXACT-MAP-UPDATE-001"\n'
            'queue_id = "2026-11-01_v1"\n'
            'status = "locked"\n'
            f'queue_manifest_sha256 = "{sha(manifest)}"\n',
            encoding="utf-8",
        )
        output = root / "controller.toml"
        return predecessor, successor, pred_controller, manifest, output

    def test_pins_exact_paths_and_hashes_without_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            predecessor, successor, pred_controller, manifest, output = self.fixture(root)
            result = subprocess.run(
                [
                    sys.executable, str(PREPARER), "--repo-root", str(root),
                    "--output", str(output),
                ],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            with output.open("rb") as handle:
                config = tomllib.load(handle)
            self.assertEqual(config["predecessor"]["queue_root"], str(predecessor))
            self.assertEqual(
                config["predecessor"]["controller_sha256"], sha(pred_controller)
            )
            self.assertEqual(config["successor"]["queue_root"], str(successor))
            self.assertEqual(config["successor"]["manifest_sha256"], sha(manifest))

            repeated = subprocess.run(
                [
                    sys.executable, str(PREPARER), "--repo-root", str(root),
                    "--output", str(output),
                ],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(repeated.returncode, 2)
            self.assertIn("refusing to overwrite", repeated.stderr)

    def test_manifest_drift_fails_before_config_creation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, successor, _, _, output = self.fixture(root)
            with (successor / "campaign_queue.py").open("a", encoding="utf-8") as handle:
                handle.write("# drift\n")
            result = subprocess.run(
                [
                    sys.executable, str(PREPARER), "--repo-root", str(root),
                    "--output", str(output),
                ],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("manifest hash mismatch", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
