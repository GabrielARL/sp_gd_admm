#!/usr/bin/env python3
"""Independent checks for the frozen cycle confirmation."""

from __future__ import annotations

import json
import math
import tempfile
import unittest
from pathlib import Path

import rq1_update_cycle_001 as experiment


class RQ1UpdateCycle001Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.config = experiment.load_config()
        cls.edges = experiment.edges_from_config(cls.config)
        cls.llrs = experiment.llrs_from_config(cls.config)
        cls.payload = experiment.build_scientific_payload(cls.config)

    def assertVectorAlmostEqual(self, actual, expected, places=12):  # noqa: N802
        self.assertEqual(len(actual), len(expected))
        for actual_value, expected_value in zip(actual, expected):
            self.assertAlmostEqual(actual_value, expected_value, places=places)

    def test_frozen_protocol(self) -> None:
        self.assertEqual(
            self.config["graph"]["parity_check_matrix"],
            [[1, 1, 0, 0], [0, 1, 1, 0], [0, 0, 1, 1], [1, 0, 0, 1]],
        )
        self.assertEqual(
            [edge[2] for edge in self.edges],
            [
                "b0-c0",
                "b0-c3",
                "b1-c0",
                "b1-c1",
                "b2-c1",
                "b2-c2",
                "b3-c2",
                "b3-c3",
            ],
        )
        self.assertEqual(self.config["channel_llrs"]["positive_llr_bit"], 1)
        self.assertIsNone(
            self.config["preregistered_predictions"]["hard_decision_prediction"]
        )
        self.assertEqual(
            self.config["budget"], {"updates": 1, "early_stopping": False}
        )

    def test_start_state_has_closed_form(self) -> None:
        l0, l1, l2, l3 = self.llrs
        expected = [l1, l3, l0, l2, l1, l3, l2, l0]
        self.assertVectorAlmostEqual(self.payload["start_state"], expected)

    def test_executable_maps_match_independent_affine_construction(self) -> None:
        for state_map in experiment.STATE_MAPS:
            jacobian, offset = experiment.analytic_affine_map(
                state_map, self.llrs, self.edges
            )
            executable = experiment.map_evaluation(
                state_map, self.payload["start_state"], self.llrs, self.edges
            )["output_state"]
            affine = experiment.vector_add(
                experiment.matvec(jacobian, self.payload["start_state"]), offset
            )
            self.assertLess(
                experiment.max_abs(experiment.vector_sub(executable, affine)), 1e-12
            )

    def test_jacobians_and_gradients_match_finite_differences(self) -> None:
        step = self.config["finite_difference"]["central_step"]
        for state_map in experiment.STATE_MAPS:
            jacobian, _ = experiment.analytic_affine_map(
                state_map, self.llrs, self.edges
            )
            numerical_jacobian = experiment.finite_difference_jacobian(
                state_map,
                self.payload["start_state"],
                self.llrs,
                self.edges,
                step,
            )
            self.assertLess(
                experiment.matrix_max_abs_difference(jacobian, numerical_jacobian),
                1e-8,
            )
            analytic_gradient = experiment.residual_gradient(
                state_map, self.payload["start_state"], self.llrs, self.edges
            )
            numerical_gradient = experiment.finite_difference_gradient(
                state_map,
                self.payload["start_state"],
                self.llrs,
                self.edges,
                step,
            )
            self.assertLess(
                experiment.max_abs(
                    experiment.vector_sub(analytic_gradient, numerical_gradient)
                ),
                1e-8,
            )

    def test_singular_fixed_point_systems_are_validated(self) -> None:
        for state_map in experiment.STATE_MAPS:
            properties = self.payload["state_map_properties"][state_map]
            fixed = properties["fixed_point_system"]
            self.assertTrue(fixed["consistent"])
            self.assertEqual(len(fixed["nullspace_basis"]), fixed["nullity"])
            particular_error = experiment.max_abs(
                experiment.vector_sub(
                    experiment.matvec(
                        properties["residual_jacobian"],
                        fixed["particular_solution"],
                    ),
                    properties["affine_offset"],
                )
            )
            self.assertLess(particular_error, 1e-11)
            for basis in fixed["nullspace_basis"]:
                self.assertLess(
                    experiment.max_abs(
                        experiment.matvec(properties["residual_jacobian"], basis)
                    ),
                    1e-11,
                )

    def test_transferred_alpha_is_not_retuned(self) -> None:
        expected = (3.0 - math.sqrt(5.0)) / 2.0
        self.assertAlmostEqual(self.payload["alpha"], expected, places=14)
        self.assertEqual(
            self.payload["alpha_selection_rule"],
            "transferred unchanged from RQ1-UPDATE-001; no cycle-specific retuning",
        )

    def test_complete_sign_transform_invariance(self) -> None:
        diagnostics = self.payload["sign_transform_invariance"]
        self.assertTrue(diagnostics["all_cells_passed"])
        for cell in diagnostics["cells"].values():
            self.assertLessEqual(cell["maximum_soft_negation_error"], 1e-12)
            self.assertTrue(cell["hard_decision_preserved"])
            self.assertTrue(cell["syndrome_preserved"])

    def test_degree_two_check_outputs_match_enumeration(self) -> None:
        for cell in self.payload["cells"].values():
            self.assertLessEqual(
                cell["local_parity_enumeration"]["maximum_absolute_error"],
                1e-12,
            )

    def test_hard_decisions_and_syndromes_recompute_without_expected_bits(self) -> None:
        for cell in self.payload["cells"].values():
            recomputed = experiment.decision_diagnostics(
                cell["after_state"],
                self.llrs,
                self.edges,
                self.config["graph"]["parity_check_matrix"],
            )
            self.assertEqual(recomputed, cell["decision_after"])

    def test_preregistered_vector_predictions(self) -> None:
        results = self.payload["preregistered_prediction_results"]
        self.assertTrue(results["state_effect_vector_nonzero"])
        self.assertTrue(results["update_effect_vector_nonzero"])
        self.assertTrue(results["difference_in_differences_vector_nonzero"])
        self.assertFalse(results["hard_decision_was_preregistered"])

    def test_payload_is_byte_deterministic(self) -> None:
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
