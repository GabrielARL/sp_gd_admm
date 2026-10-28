#!/usr/bin/env python3
"""Independent unit checks for the RQ1-UPDATE-001 anchor."""

from __future__ import annotations

import json
import math
import tempfile
import unittest
from pathlib import Path

import rq1_update_001 as experiment


class RQ1Update001Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.config = experiment.load_config()
        cls.llrs = experiment.llrs_from_config(cls.config)
        cls.payload = experiment.build_scientific_payload(cls.config)

    def assertVectorAlmostEqual(self, actual, expected, places=12):  # noqa: N802
        self.assertEqual(len(actual), len(expected))
        for actual_value, expected_value in zip(actual, expected):
            self.assertAlmostEqual(actual_value, expected_value, places=places)

    def test_frozen_protocol(self) -> None:
        self.assertEqual(
            self.config["graph"]["parity_check_matrix"],
            [[1, 1, 0], [0, 1, 1]],
        )
        self.assertEqual(
            [entry["label"] for entry in self.config["graph"]["edge_order"]],
            ["b0-c0", "b1-c0", "b1-c1", "b2-c1"],
        )
        self.assertEqual(self.config["budget"], {"updates": 1, "early_stopping": False})
        self.assertEqual(self.config["channel_llrs"]["positive_llr_bit"], 1)

    def test_start_is_first_full_bp_state(self) -> None:
        expected = [math.log(1.5), -math.log(9.0), math.log(2.0), math.log(1.5)]
        self.assertVectorAlmostEqual(self.payload["start_state"], expected)

    def test_direct_outputs_have_closed_forms(self) -> None:
        full_expected = [
            math.log(3.0),
            -math.log(9.0),
            math.log(2.0),
            math.log(1.0 / 6.0),
        ]
        tied_expected = [
            -0.5 * math.log(2.0),
            -math.log(9.0),
            math.log(2.0),
            -0.5 * math.log(2.0),
        ]
        self.assertVectorAlmostEqual(
            self.payload["cells"]["full__direct"]["after_state"], full_expected
        )
        self.assertVectorAlmostEqual(
            self.payload["cells"]["qbar_tied__direct"]["after_state"], tied_expected
        )

    def test_analytic_jacobians_are_independently_differentiated(self) -> None:
        step = self.config["finite_difference"]["central_step"]
        for state_map in experiment.STATE_MAPS:
            analytic, _ = experiment.affine_map(state_map, self.llrs)
            numerical = experiment.finite_difference_jacobian(
                state_map, self.payload["start_state"], self.llrs, step
            )
            self.assertLess(experiment.matrix_max_abs_difference(analytic, numerical), 1e-8)

    def test_residual_gradients_are_independently_differentiated(self) -> None:
        step = self.config["finite_difference"]["central_step"]
        for state_map in experiment.STATE_MAPS:
            analytic = experiment.residual_gradient(
                state_map, self.payload["start_state"], self.llrs
            )
            numerical = experiment.finite_difference_gradient(
                state_map, self.payload["start_state"], self.llrs, step
            )
            self.assertLess(experiment.max_abs(experiment.vector_sub(analytic, numerical)), 1e-8)

    def test_shared_spectral_bound_and_step_size(self) -> None:
        expected_maximum = (3.0 + math.sqrt(5.0)) / 2.0
        expected_alpha = 1.0 / expected_maximum
        self.assertAlmostEqual(self.payload["alpha"], expected_alpha, places=14)
        for state_map in experiment.STATE_MAPS:
            observed = self.payload["state_map_properties"][state_map]["maximum_eigenvalue"]
            self.assertAlmostEqual(observed, expected_maximum, places=12)

    def test_objective_zero_sets_are_fixed_points(self) -> None:
        for state_map in experiment.STATE_MAPS:
            properties = self.payload["state_map_properties"][state_map]
            self.assertLess(experiment.max_abs(properties["fixed_point_residual"]), 1e-12)
            self.assertLess(properties["objective_at_fixed_point"], 1e-24)

    def test_hard_decisions_and_syndromes(self) -> None:
        expected = {
            "full__direct": ([0, 0, 0], [0, 0], True),
            "qbar_tied__direct": ([0, 0, 1], [0, 1], False),
        }
        for cell_id, (bits, check_syndrome, valid) in expected.items():
            decision = self.payload["cells"][cell_id]["decision_after"]
            self.assertEqual(decision["hard_decision_estimate"], bits)
            self.assertEqual(decision["syndrome"], check_syndrome)
            self.assertEqual(decision["valid_codeword"], valid)

    def test_complete_sign_transform_invariance(self) -> None:
        transformed = self.payload["sign_transform_invariance"]
        self.assertEqual(
            transformed["transform"],
            "ell=-L, q0=-q1, u0=-u1, x0=-x1",
        )
        self.assertTrue(transformed["all_cells_passed"])
        for cell in transformed["cells"].values():
            self.assertLessEqual(cell["maximum_soft_negation_error"], 1e-12)
            self.assertTrue(cell["hard_decision_preserved"])
            self.assertTrue(cell["syndrome_preserved"])

    def test_pure_payload_is_byte_deterministic(self) -> None:
        replay = experiment.build_scientific_payload(self.config)
        self.assertEqual(
            experiment.canonical_bytes(self.payload),
            experiment.canonical_bytes(replay),
        )

    def test_all_registered_validation_gates_pass(self) -> None:
        validation = experiment.validate_payload(self.config, self.payload)
        failures = [check for check in validation["checks"] if not check["passed"]]
        self.assertTrue(validation["all_passed"], json.dumps(failures, indent=2))

    def test_existing_retained_directory_is_never_overwritten(self) -> None:
        validation = experiment.validate_payload(self.config, self.payload)
        with tempfile.TemporaryDirectory() as temporary_root:
            existing = Path(temporary_root) / "already-retained"
            existing.mkdir()
            marker = existing / "marker.txt"
            marker.write_text("preserve\n", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                experiment.write_retained_result(
                    existing,
                    self.config,
                    self.payload,
                    validation,
                    experiment.repository_root(),
                )
            self.assertEqual(marker.read_text(encoding="utf-8"), "preserve\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
