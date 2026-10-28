#!/usr/bin/env python3
"""Unit tests for the deterministic RQ1-STATE-002 harness."""

from __future__ import annotations

import copy
import json
import math
import tempfile
import unittest
from unittest import mock
from pathlib import Path

import rq1_state_002 as model


class RQ1State002Tests(unittest.TestCase):
    def test_all_registered_traces_validate(self) -> None:
        for case in model.CASES.values():
            for treatment in model.TREATMENTS:
                with self.subTest(case=case.case_id, treatment=treatment):
                    trace = model.build_trace(case, treatment)
                    failed = {
                        name: detail
                        for name, detail in trace["validation"]["checks"].items()
                        if not detail["passed"]
                    }
                    self.assertTrue(trace["validation"]["all_passed"], failed)

    def test_symmetric_anchor_prediction(self) -> None:
        trace = model.build_trace(model.CASES["symmetric_tree"], "pulse")
        full = trace["branches"]["full"]["iterations"][1]
        collapse = trace["branches"]["qbar_collapse"]["iterations"][1]
        edges = trace["q_edge_labels"]
        to_c0 = edges.index("b1->c0")
        to_c1 = edges.index("b1->c1")
        self.assertAlmostEqual(full["q_transmitted"][to_c0], math.log(13.5), places=14)
        self.assertAlmostEqual(full["q_transmitted"][to_c1], math.log(1.0 / 6.0), places=14)
        self.assertEqual(full["hard_decision_estimate"], [1, 1, 1])
        self.assertEqual(full["syndrome"], [0, 0])
        self.assertEqual(collapse["hard_decision_estimate"], [0, 1, 1])
        self.assertEqual(collapse["syndrome"], [1, 0])

    def test_nonzero_sum_separates_qbar_from_posterior_copy(self) -> None:
        trace = model.build_trace(model.CASES["nonzero_sum_tree"], "pulse")
        collapse = trace["branches"]["qbar_collapse"]["iterations"][1]
        posterior_copy = trace["branches"]["posterior_copy_diagnostic"]["iterations"][1]
        shared_edge = trace["q_edge_labels"].index("b1->c0")
        self.assertAlmostEqual(
            collapse["q_transmitted"][shared_edge], -0.5 * math.log(2.0), places=14
        )
        self.assertAlmostEqual(
            posterior_copy["q_transmitted"][shared_edge], -math.log(3.0), places=14
        )
        self.assertNotAlmostEqual(
            collapse["q_transmitted"][shared_edge],
            posterior_copy["q_transmitted"][shared_edge],
            places=12,
        )

    def test_shadow_and_reconstruction_controls(self) -> None:
        for case in model.CASES.values():
            trace = model.build_trace(case, "pulse")
            branches = trace["branches"]
            self.assertEqual(
                model._trajectory_signature(branches["qbar_collapse"]),
                model._trajectory_signature(branches["delta_shadow_ignored"]),
            )
            self.assertEqual(
                model._trajectory_signature(branches["full"]),
                model._trajectory_signature(branches["qbar_delta_reconstruct"]),
            )

    def test_degree_one_negative_control(self) -> None:
        trace = model.build_trace(model.CASES["degree_one_six_bit"], "pulse")
        branches = trace["branches"]
        self.assertEqual(
            model._trajectory_signature(branches["full"]),
            model._trajectory_signature(branches["qbar_collapse"]),
        )
        for branch in branches.values():
            for iteration in branch["iterations"]:
                self.assertTrue(all(delta == 0.0 for delta in iteration["delta_by_edge"]))

    def test_separately_configured_cyclic_confirmation(self) -> None:
        trace = model.build_trace(
            model.CASES["cyclic_four_bit"],
            "pulse",
            iterations=2,
            intervention_iteration=2,
        )
        self.assertTrue(trace["validation"]["all_passed"])
        full = trace["branches"]["full"]["iterations"][1]
        collapse = trace["branches"]["qbar_collapse"]["iterations"][1]
        self.assertEqual(full["hard_decision_estimate"], [1, 1, 0, 1])
        self.assertEqual(full["syndrome"], [0, 1, 1, 0])
        self.assertEqual(collapse["hard_decision_estimate"], [0, 1, 1, 1])
        self.assertEqual(collapse["syndrome"], [1, 0, 0, 1])

    def test_first_divergence_is_the_pulsed_transmitted_q(self) -> None:
        trace = model.build_trace(model.CASES["symmetric_tree"], "pulse")
        divergence = trace["validation"]["first_divergence_from_full"]["qbar_collapse"]
        self.assertEqual(divergence["iteration"], 2)
        self.assertEqual(divergence["stage"], "q_transmitted")
        self.assertEqual(divergence["coordinate_kind"], "variable_to_check_edge")
        self.assertEqual(divergence["coordinate_label"], "b1->c0")

    def test_equal_qbar_different_delta_structural_witness(self) -> None:
        witness = model.structural_delta_witness()
        self.assertTrue(witness["passed"])
        self.assertEqual(witness["qbar_left"], witness["qbar_right"])
        self.assertNotEqual(witness["delta_left"], witness["delta_right"])
        self.assertEqual(
            witness["changed_check_to_variable_edges"], ["c0->b0", "c1->b2"]
        )

    def test_directional_labels_share_neutral_edge_slots(self) -> None:
        case = model.CASES["symmetric_tree"]
        trace = model.build_trace(case, "pulse")
        self.assertEqual(trace["edge_slots"], ["b0-c0", "b1-c0", "b1-c1", "b2-c1"])
        self.assertEqual(
            trace["q_edge_labels"], ["b0->c0", "b1->c0", "b1->c1", "b2->c1"]
        )
        self.assertEqual(
            trace["u_edge_labels"], ["c0->b0", "c0->b1", "c1->b1", "c1->b2"]
        )
        for branch in trace["branches"].values():
            for record in branch["iterations"]:
                self.assertEqual(record["edge_slots"], trace["edge_slots"])
                self.assertEqual(record["q_edge_labels"], trace["q_edge_labels"])
                self.assertEqual(record["u_edge_labels"], trace["u_edge_labels"])

        candidate = copy.deepcopy(trace["branches"]["full"])
        candidate["iterations"][0]["u_out"][0] += 0.25
        divergence = model.first_divergence(trace["branches"]["full"], candidate)
        self.assertEqual(divergence["stage"], "u_out")
        self.assertEqual(divergence["coordinate_kind"], "check_to_variable_edge")
        self.assertEqual(divergence["coordinate_label"], "c0->b0")

    def test_iteration_one_collapse_negative_control_is_explicit(self) -> None:
        for case in model.CASES.values():
            trace = model.build_trace(case, "pulse")
            check = trace["validation"]["checks"][
                "iteration_one_qbar_collapse_negative_control"
            ]
            with self.subTest(case=case.case_id):
                self.assertTrue(check["passed"], check)
                self.assertTrue(check["every_delta_is_exactly_zero"])
                self.assertTrue(check["qbar_expansion_is_bitwise_q_standard"])

    def test_consistent_check_row_relabeling(self) -> None:
        for case in model.CASES.values():
            trace = model.build_trace(case, "pulse")
            check = trace["validation"]["checks"]["consistent_check_row_relabeling"]
            with self.subTest(case=case.case_id):
                self.assertTrue(check["passed"], check)

    def test_check_update_matches_independent_enumeration(self) -> None:
        for case in model.CASES.values():
            q_values = tuple(case.llr[bit] for bit, _ in case.edges)
            formula = model.check_update(case, q_values)
            enumerated = tuple(
                model.enumerate_check_message(case, q_values, k)
                for k in range(len(case.edges))
            )
            with self.subTest(case=case.case_id):
                for left, right in zip(formula, enumerated):
                    self.assertAlmostEqual(left, right, places=12)

    def test_pulse_and_persistent_are_separate_treatments(self) -> None:
        case = model.CASES["nonzero_sum_tree"]
        pulse = model.build_trace(case, "pulse")
        persistent = model.build_trace(case, "persistent")
        self.assertEqual(pulse["treatment"], "pulse")
        self.assertEqual(persistent["treatment"], "persistent")
        pulse_t3 = pulse["branches"]["qbar_collapse"]["iterations"][2]
        persistent_t3 = persistent["branches"]["qbar_collapse"]["iterations"][2]
        self.assertFalse(pulse_t3["intervention_active"])
        self.assertTrue(persistent_t3["intervention_active"])
        self.assertNotEqual(pulse_t3["q_transmitted_hex"], persistent_t3["q_transmitted_hex"])

    def test_non_overwriting_run_and_deterministic_replay(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "result"
            manifest = model.run_to_directory(
                output,
                model.PRIMARY_CASE_IDS,
                model.TREATMENTS,
                model.DEFAULT_ITERATIONS,
                model.DEFAULT_INTERVENTION_ITERATION,
            )
            self.assertTrue(manifest["all_trace_validations_passed"])
            replay = model.replay_result_directory(output)
            self.assertTrue(replay["passed"], json.dumps(replay, indent=2))
            with self.assertRaises(FileExistsError):
                model.run_to_directory(
                    output,
                    tuple(model.CASES),
                    model.TREATMENTS,
                    model.DEFAULT_ITERATIONS,
                    model.DEFAULT_INTERVENTION_ITERATION,
                )

    def test_replay_rejects_tampered_validation_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "result"
            model.run_to_directory(
                output,
                ("symmetric_tree",),
                ("pulse",),
                model.DEFAULT_ITERATIONS,
                model.DEFAULT_INTERVENTION_ITERATION,
            )
            manifest_path = output / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            filename = "symmetric_tree__pulse.json"
            manifest["trace_validation_passed"][filename] = False
            manifest["all_trace_validations_passed"] = False
            model._write_json(manifest_path, manifest)
            (output / "MANIFEST.sha256").write_text(
                f"{model._sha256_file(manifest_path)}  manifest.json\n",
                encoding="utf-8",
            )

            replay = model.replay_result_directory(output)
            self.assertFalse(replay["passed"], json.dumps(replay, indent=2))
            self.assertFalse(replay["all_recorded_trace_validations_passed"])
            self.assertFalse(
                replay["trace_comparisons"][filename]["validation_flag_matches"]
            )

    def test_replay_rejects_reproducible_invalid_trace(self) -> None:
        original_build_trace = model.build_trace

        def invalid_build_trace(*args: object, **kwargs: object) -> dict:
            trace = original_build_trace(*args, **kwargs)
            trace["validation"]["checks"]["forced_invalid_test_control"] = {
                "passed": False
            }
            trace["validation"]["all_passed"] = False
            return trace

        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "result"
            with mock.patch.object(model, "build_trace", side_effect=invalid_build_trace):
                manifest = model.run_to_directory(
                    output,
                    ("symmetric_tree",),
                    ("pulse",),
                    model.DEFAULT_ITERATIONS,
                    model.DEFAULT_INTERVENTION_ITERATION,
                )
                self.assertFalse(manifest["all_trace_validations_passed"])
                replay = model.replay_result_directory(output)

            self.assertFalse(replay["passed"], json.dumps(replay, indent=2))
            self.assertFalse(replay["all_recomputed_trace_validations_passed"])
            comparison = replay["trace_comparisons"]["symmetric_tree__pulse.json"]
            self.assertTrue(comparison["hashes_match"])
            self.assertTrue(comparison["validation_flag_matches"])
            self.assertFalse(comparison["recomputed_validation_passed"])

    def test_cyclic_configuration_is_consumed_and_replayed(self) -> None:
        configuration_path = Path(__file__).with_name(
            "cyclic_confirmation_config.json"
        )
        configured = model.load_run_configuration(configuration_path)
        self.assertEqual(configured["case_ids"], ("cyclic_four_bit",))
        self.assertEqual(configured["treatments"], ("pulse",))
        self.assertEqual(configured["iterations"], 2)
        self.assertEqual(configured["intervention_iteration"], 2)

        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "result"
            manifest = model.run_to_directory(
                output,
                configured["case_ids"],
                configured["treatments"],
                configured["iterations"],
                configured["intervention_iteration"],
                experiment_id=configured["experiment_id"],
                configuration_source=configuration_path,
                notes=configured["notes"],
            )
            self.assertTrue(manifest["configuration_source_validation"]["passed"])
            run_config = json.loads(
                (output / "run_config.json").read_text(encoding="utf-8")
            )
            self.assertTrue(
                run_config["configuration_source"]["effective_fields_match"]
            )
            replay = model.replay_result_directory(output)
            self.assertTrue(replay["passed"], json.dumps(replay, indent=2))
            self.assertTrue(replay["configuration_source_manifest_matches"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
