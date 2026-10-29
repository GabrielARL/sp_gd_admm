#!/usr/bin/env python3
"""Tests for the Core story's scalar-GD term split."""

from __future__ import annotations

import hashlib
import json
import unittest

import build_core_story_trace as core


class CoreStoryTraceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.record = core.derive()
        cls.trace = core.load_endpoint(core.ROOT)

    def test_every_derivation_check_passes(self) -> None:
        failed = [k for k, v in self.record["validation"]["checks"].items() if not v]
        self.assertEqual(failed, [])
        self.assertEqual(self.record["status"], "valid")

    def test_all_thirty_updates_recompose_bit_for_bit(self) -> None:
        steps = self.trace["rung_results"][core.NATIVE_RUNG]["result"]["trace"]
        self.assertEqual(len(self.record["updates"]), len(steps))
        self.assertEqual(len(steps), 30)
        for derived, retained in zip(self.record["updates"], steps):
            for key in ("gradient", "direction", "raw_proposal", "projected_proposal"):
                self.assertEqual(derived[key], retained[key], (derived["update"], key))

    def test_check_terms_add_to_the_parity_gradient(self) -> None:
        for u in self.record["updates"]:
            g = u["g"]
            self.assertEqual(u["parity_partial"][0], g["A"]["b1"])
            self.assertEqual(u["parity_partial"][1], g["A"]["b2"] + g["B"]["b2"])
            self.assertEqual(u["parity_partial"][2], g["B"]["b3"])

    def test_first_update_values(self) -> None:
        u = self.record["updates"][0]
        self.assertEqual(u["x_before"], [0.8, -0.19999999999999998, -0.3333333333333333])
        self.assertAlmostEqual(u["residual"]["A"], 1.16, places=15)
        self.assertAlmostEqual(u["residual"]["B"], 1.0 - 0.2 / 3.0, places=15)
        self.assertAlmostEqual(u["g"]["A"]["b2"], -(4.0 / 3.0) * 1.16 * 0.8, places=14)
        self.assertAlmostEqual(u["curvature"][1], 3.2, places=15)
        self.assertEqual(u["active_projection_coordinates"], [])
        self.assertEqual(u["backtrack_index"], 0)
        self.assertEqual(u["hard_decision_before"], [0, 1, 1])

    def test_readings_are_the_frozen_state(self) -> None:
        for u in self.record["updates"]:
            x = u["x_before"]
            self.assertEqual(u["readings"], {"A": {"b1": x[0], "b2": x[1]},
                                             "B": {"b2": x[1], "b3": x[2]}})
            self.assertIs(u["readings"]["A"]["b2"] == u["readings"]["B"]["b2"], True)

    def test_retained_output_is_a_fresh_derivation(self) -> None:
        payload = core.serialize(self.record)
        self.assertEqual(core.OUTPUT.read_bytes(), payload)
        digest = hashlib.sha256(payload).hexdigest()
        self.assertEqual(core.MANIFEST.read_text(encoding="ascii"), f"{digest}  core_story_trace.json\n")

    def test_derivation_is_deterministic(self) -> None:
        self.assertEqual(core.serialize(core.derive()), core.serialize(self.record))

    def test_source_hash_is_enforced(self) -> None:
        self.assertEqual(self.record["source"]["sha256"], core.ENDPOINT_SHA256)
        retained = json.loads(core.OUTPUT.read_text(encoding="ascii"))
        self.assertEqual(retained["source"]["path"], core.ENDPOINT_TRACE)


if __name__ == "__main__":
    unittest.main()
