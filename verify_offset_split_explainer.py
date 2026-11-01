#!/usr/bin/env python3
"""Verify the short Offset Split explanation and its retained evidence view."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import re
import signal
import shutil
import subprocess
import tempfile
from html.parser import HTMLParser
from pathlib import Path
from collections import Counter
from typing import Any


ROOT = Path(__file__).resolve().parent
HTML_PATH = ROOT / "offset_split_explainer.html"
CORE_SCENES = 9
EVIDENCE_BEATS = 23
EVIDENCE_DIR = ROOT / "offset_split_explainer_evidence"
MANIFEST_PATH = EVIDENCE_DIR / "MANIFEST.sha256"
PINNED_SOURCES = {
    "compound_case_set_A": (
        "offset_split_explainer_evidence/compound_case_set_A.csv",
        "93b8cfc089e93a426720bad3d0713b0d27cf17e3015c799694976b3b21be5ad9",
    ),
    "offset_split_case_set_B": (
        "offset_split_explainer_evidence/offset_split_case_set_B.csv",
        "da69dc596418e116c670d1297d5b81164de8c21f228ae8ee89f6ba2d5d6a5d12",
    ),
    "offset_reassignment_case_set_B": (
        "offset_split_explainer_evidence/offset_reassignment_case_set_B.csv",
        "86e538b047055ff1a5514ea375629bf9f06a37ed4914af248393468903411c22",
    ),
    "native_gap_case_set_B": (
        "offset_split_explainer_evidence/native_gap_case_set_B.csv",
        "d47cfff41641a3b752309db4029d15dcdab0dc46c15da5353b3ea7266ae9b4ea",
    ),
    "offset_split_interaction_case_set_B": (
        "offset_split_explainer_evidence/offset_split_interaction_case_set_B.csv",
        "5d65a2ac2ba28fbf8004368d735e5b1f74edd9837c274bbb00bc3d6d5c80b061",
    ),
    "offset_split_completion_case_set_B": (
        "offset_split_explainer_evidence/offset_split_COMPLETED.toml",
        "1ee4e0d3139eea32e715213822f9e3bb2e06e71eb6f13508d23c85da1da882cf",
    ),
    "assignment_refresh_transfer_case_set_C": (
        "offset_split_explainer_evidence/assignment_refresh_transfer_case_set_C.csv",
        "7908cd846ee7cd8f47970f39cea199f8fee21e69b2998ddf7108cd14812cf85c",
    ),
    "assignment_refresh_transfer_interaction_case_set_C": (
        "offset_split_explainer_evidence/assignment_refresh_transfer_interaction_case_set_C.csv",
        "7790e946890c689c730b1c3576129691052aa00472216ce853ba679fb294aa9b",
    ),
    "assignment_refresh_transfer_completion_case_set_C": (
        "offset_split_explainer_evidence/assignment_refresh_transfer_COMPLETED.toml",
        "63cc477d16fdff86d0a3ad5b30a60928cad2d220590ccf3b47e3d89ccc28f1ba",
    ),
    "assignment_refresh_attribution_case_set_B": (
        "offset_split_explainer_evidence/assignment_refresh_attribution_case_set_B.csv",
        "7aca27b170c6e3063a4fe7e693c76beff407df48aa4a2bea3f45c70924c40319",
    ),
    "assignment_refresh_attribution_interaction_case_set_B": (
        "offset_split_explainer_evidence/assignment_refresh_attribution_interaction_case_set_B.csv",
        "3f589c7990e7dc7dd09d748cd486f59938a5fb61c5ca8c592693a071e5eefb81",
    ),
    "assignment_refresh_attribution_completion_case_set_B": (
        "offset_split_explainer_evidence/assignment_refresh_attribution_COMPLETED.toml",
        "f2097bca258a56809ef8b7ebcacaceed99a6619e50abbb1147d5feccbd7fb36b",
    ),
    "assignment_refresh_attribution_frames_case_set_B": (
        "offset_split_explainer_evidence/assignment_refresh_attribution_frames_case_set_B.csv",
        "ece720c9aeffac26ecdc8f2d0c91133320d03b2da0fc1dd36585ba55e5844200",
    ),
    "native_gap_frames_case_set_B": (
        "offset_split_explainer_evidence/native_gap_frames_case_set_B.csv",
        "a724bbcf3637d92ba61d5d086a28d8c6bc3e804da00459c153782859fb5ab9e7",
    ),
}


class EvidenceParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.active = False
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "script" and dict(attrs).get("id") == "offsetSplitEvidence":
            self.active = True

    def handle_endtag(self, tag: str) -> None:
        if tag == "script" and self.active:
            self.active = False

    def handle_data(self, data: str) -> None:
        if self.active:
            self.parts.append(data)


def extract_evidence(html: str) -> dict[str, Any]:
    parser = EvidenceParser()
    parser.feed(html)
    if not parser.parts:
        raise AssertionError("missing offsetSplitEvidence JSON")
    return json.loads("".join(parser.parts))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def read_flat_toml(path: Path) -> dict[str, Any]:
    values: dict[str, Any] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, raw_value = line.partition("=")
        if not separator:
            raise AssertionError(f"unsupported TOML line in {path.name}: {raw_line!r}")
        value = raw_value.strip()
        if value in {"true", "false"}:
            parsed: Any = value == "true"
        elif len(value) >= 2 and value[0] == value[-1] == '"':
            parsed = value[1:-1]
        else:
            raise AssertionError(f"unsupported TOML value in {path.name}: {raw_value!r}")
        values[key.strip()] = parsed
    return values


def one(rows: list[dict[str, str]], **where: str) -> dict[str, str]:
    matches = [row for row in rows if all(row.get(key) == value for key, value in where.items())]
    if len(matches) != 1:
        raise AssertionError(f"expected one row for {where}, found {len(matches)}")
    return matches[0]


def integer(row: dict[str, str], key: str) -> int:
    value = float(row[key])
    if not math.isfinite(value) or not value.is_integer():
        raise AssertionError(f"{key} must be a finite integer, got {row[key]!r}")
    return int(value)


def verify_paired_decomposition(
    row: dict[str, str],
    *,
    treatment_only_key: str,
    reference_only_key: str,
    treatment_success_key: str,
    reference_success_key: str,
    risk_key: str,
    label: str,
) -> None:
    pairs = integer(row, "pairs")
    both = integer(row, "both_success")
    treatment_only = integer(row, treatment_only_key)
    reference_only = integer(row, reference_only_key)
    neither = integer(row, "both_failure")
    treatment_success = integer(row, treatment_success_key)
    reference_success = integer(row, reference_success_key)
    if pairs != both + treatment_only + reference_only + neither:
        raise AssertionError(f"{label}: paired quadrants do not sum to pairs")
    if treatment_success != both + treatment_only:
        raise AssertionError(f"{label}: treatment successes do not match paired quadrants")
    if reference_success != both + reference_only:
        raise AssertionError(f"{label}: reference successes do not match paired quadrants")
    close(
        float(row[risk_key]),
        (treatment_success - reference_success) / pairs,
        f"{label}: risk difference",
    )


def close(actual: float, expected: float, label: str, tolerance: float = 1e-12) -> None:
    if not math.isclose(float(actual), float(expected), rel_tol=0.0, abs_tol=tolerance):
        raise AssertionError(f"{label}: {actual!r} != {expected!r}")


def relative_luminance(hex_color: str) -> float:
    channels = [int(hex_color[index:index + 2], 16) / 255.0 for index in (1, 3, 5)]
    linear = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4 for value in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast_ratio(first: str, second: str) -> float:
    high, low = sorted((relative_luminance(first), relative_luminance(second)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def verify_sources(evidence: dict[str, Any]) -> dict[str, Any]:
    if set(evidence["sources"]) != set(PINNED_SOURCES):
        raise AssertionError("embedded source set changed")
    expected_manifest = "".join(
        f"{digest}  {Path(relative_path).name}\n"
        for relative_path, digest in PINNED_SOURCES.values()
    )
    if MANIFEST_PATH.read_text(encoding="utf-8") != expected_manifest:
        raise AssertionError("evidence manifest differs from the verifier's pinned source list")
    tables: dict[str, Any] = {}
    for source_id, (relative_path, pinned_digest) in PINNED_SOURCES.items():
        descriptor = evidence["sources"][source_id]
        if descriptor != {"path": relative_path, "sha256": pinned_digest}:
            raise AssertionError(f"embedded descriptor changed for {source_id}")
        path = (ROOT / relative_path).resolve()
        if ROOT not in path.parents:
            raise AssertionError(f"source escapes the repository: {path}")
        if not path.is_file():
            raise AssertionError(f"missing retained source for {source_id}: {path}")
        observed = sha256(path)
        if observed != pinned_digest:
            raise AssertionError(f"{source_id} source digest changed: {observed}")
        if path.suffix == ".csv":
            tables[source_id] = read_rows(path)
        elif path.suffix == ".toml":
            tables[source_id] = read_flat_toml(path)
        else:
            raise AssertionError(f"unsupported retained source type: {path}")
    return tables


def verify_toy(evidence: dict[str, Any]) -> None:
    toy = evidence["toy"]
    x = float(toy["x_i"])
    offsets = {key: float(value) for key, value in toy["offsets"].items()}
    readings = {key: float(value) for key, value in toy["readings"].items()}
    close(sum(offsets.values()), 0.0, "toy offsets sum")
    for check in ("A", "B", "C"):
        close(x + offsets[check], readings[check], f"toy reading {check}")
    lower = max(-1.0 - value for value in offsets.values())
    upper = min(1.0 - value for value in offsets.values())
    close(lower, toy["offset_projection_interval"][0], "toy lower projection bound")
    close(upper, toy["offset_projection_interval"][1], "toy upper projection bound")
    projected = min(max(float(toy["trial_x"]), lower), upper)
    close(projected, toy["projected_trial_x"], "toy projected trial")
    if "Illustrative" not in toy["note"]:
        raise AssertionError("toy values are not visibly scoped as illustrative")


def verify_tables(evidence: dict[str, Any], tables: dict[str, Any]) -> None:
    compound_rows = tables["compound_case_set_A"]
    for row in compound_rows:
        verify_paired_decomposition(
            row,
            treatment_only_key="active_only_success",
            reference_only_key="control_only_success",
            treatment_success_key="active_successes",
            reference_success_key="control_successes",
            risk_key="risk_difference_active_minus_control",
            label=f"compound/{row['endpoint']}",
        )
    compound = one(compound_rows, endpoint="transmitted_word_equal")
    compound_parity = one(compound_rows, endpoint="parity_valid")
    compound_count_keys = (
        "pairs", "both_success", "active_only_success", "control_only_success",
        "both_failure", "active_successes", "control_successes",
    )
    if any(integer(compound, key) != integer(compound_parity, key) for key in compound_count_keys):
        raise AssertionError("compound parity-valid and transmitted-word totals differ")
    embedded = evidence["compound_case_set_A"]
    expected_compound = {
        "locked_cases": integer(compound, "pairs"),
        "control_recovered": integer(compound, "control_successes"),
        "compound_recovered": integer(compound, "active_successes"),
        "compound_only": integer(compound, "active_only_success"),
        "control_only": integer(compound, "control_only_success"),
    }
    if embedded != expected_compound:
        raise AssertionError(f"compound result mismatch: {embedded} != {expected_compound}")

    split_rows = tables["offset_split_case_set_B"]
    for row in split_rows:
        verify_paired_decomposition(
            row,
            treatment_only_key="treatment_only_success",
            reference_only_key="reference_only_success",
            treatment_success_key="treatment_successes",
            reference_success_key="reference_successes",
            risk_key="risk_difference_treatment_minus_reference",
            label=f"split/{row['endpoint']}/{row['contrast_id']}",
        )
    arm_map = {
        "objective_use_given_bounds0": ("objective1__bounds0", "objective0__bounds0"),
        "offset_bounds_given_objective0": ("objective0__bounds1", "objective0__bounds0"),
        "objective_use_given_bounds1": ("objective1__bounds1", "objective0__bounds1"),
        "offset_bounds_given_objective1": ("objective1__bounds1", "objective1__bounds0"),
    }

    def split_endpoint(endpoint: str) -> dict[str, dict[str, str]]:
        selected: dict[str, dict[str, str]] = {}
        arm_successes: dict[str, set[int]] = {}
        for contrast_id, (treatment_arm, reference_arm) in arm_map.items():
            row = one(split_rows, endpoint=endpoint, contrast_id=contrast_id)
            if (row["treatment_arm"], row["reference_arm"]) != (treatment_arm, reference_arm):
                raise AssertionError(f"arm mapping changed for {endpoint}/{contrast_id}")
            if integer(row, "pairs") != 200:
                raise AssertionError(f"pair count changed for {endpoint}/{contrast_id}")
            arm_successes.setdefault(treatment_arm, set()).add(integer(row, "treatment_successes"))
            arm_successes.setdefault(reference_arm, set()).add(integer(row, "reference_successes"))
            selected[contrast_id] = row
        inconsistent = {arm: values for arm, values in arm_successes.items() if len(values) != 1}
        if inconsistent:
            raise AssertionError(f"shared split arms have inconsistent totals for {endpoint}: {inconsistent}")
        return selected

    split_transmitted = split_endpoint("transmitted_word_equal")
    split_parity = split_endpoint("parity_valid")
    for contrast_id in arm_map:
        transmitted = {k: v for k, v in split_transmitted[contrast_id].items() if k != "endpoint"}
        parity = {k: v for k, v in split_parity[contrast_id].items() if k != "endpoint"}
        if transmitted != parity:
            raise AssertionError(f"split parity-valid row differs from transmitted-word row: {contrast_id}")

    o_at_p0 = split_transmitted["objective_use_given_bounds0"]
    p_at_o0 = split_transmitted["offset_bounds_given_objective0"]
    o_at_p1 = split_transmitted["objective_use_given_bounds1"]
    p_at_o1 = split_transmitted["offset_bounds_given_objective1"]
    expected_split = {
        "locked_cases": integer(o_at_p0, "pairs"),
        "parity_ignores_offsets__ordinary_interval": integer(o_at_p0, "reference_successes"),
        "parity_ignores_offsets__offset_interval": integer(p_at_o0, "treatment_successes"),
        "parity_uses_offsets__ordinary_interval": integer(o_at_p0, "treatment_successes"),
        "parity_uses_offsets__offset_interval": integer(o_at_p1, "treatment_successes"),
        "parity_effect_given_ordinary_interval": integer(o_at_p0, "treatment_successes") - integer(o_at_p0, "reference_successes"),
        "parity_effect_given_offset_interval": integer(o_at_p1, "treatment_successes") - integer(o_at_p1, "reference_successes"),
        "interval_effect_when_parity_ignores_offsets": integer(p_at_o0, "treatment_successes") - integer(p_at_o0, "reference_successes"),
        "interval_effect_when_parity_uses_offsets": integer(p_at_o1, "treatment_successes") - integer(p_at_o1, "reference_successes"),
    }
    if evidence["offset_split_case_set_B"] != expected_split:
        raise AssertionError("offset-split table does not reproduce the retained aggregate")

    for row in (o_at_p0, o_at_p1):
        if integer(row, "treatment_only_success") <= 0 or integer(row, "reference_only_success") != 0:
            raise AssertionError("parity-use contrast no longer has gains with zero losses")
        if not (float(row["interval_lower"]) > 0 and float(row["interval_upper"]) > 0):
            raise AssertionError("parity-use interval no longer excludes zero")
        if not float(row["holm_adjusted_pvalue"]) < 1e-15:
            raise AssertionError("parity-use Holm-adjusted p-value no longer supports the displayed bound")
    if (integer(o_at_p0, "treatment_only_success"), integer(o_at_p1, "treatment_only_success")) != (56, 57):
        raise AssertionError("displayed parity-use paired gains are no longer 56 and 57")
    for row in (p_at_o0, p_at_o1):
        if not float(row["interval_lower"]) <= 0 <= float(row["interval_upper"]):
            raise AssertionError("projection-interval contrast no longer includes zero")
        close(float(row["holm_adjusted_pvalue"]), 1.0, "projection-interval Holm-adjusted p-value")
    if (
        integer(p_at_o0, "treatment_only_success"),
        integer(p_at_o0, "reference_only_success"),
        integer(p_at_o1, "treatment_only_success"),
        integer(p_at_o1, "reference_only_success"),
    ) != (0, 1, 0, 0):
        raise AssertionError("displayed projection-interval paired changes are no longer -1 and 0")

    interaction_rows = tables["offset_split_interaction_case_set_B"]
    transmitted_interaction = one(interaction_rows, endpoint="transmitted_word_equal")
    parity_interaction = one(interaction_rows, endpoint="parity_valid")
    if {k: v for k, v in transmitted_interaction.items() if k != "endpoint"} != {
        k: v for k, v in parity_interaction.items() if k != "endpoint"
    }:
        raise AssertionError("parity-valid and transmitted-word interaction rows differ")
    if integer(transmitted_interaction, "frames") != 200:
        raise AssertionError("interaction frame count changed")
    close(float(transmitted_interaction["risk_difference_interaction"]), 0.005, "interaction")
    close(float(transmitted_interaction["interval_lower"]), 0.0, "interaction lower interval")
    close(float(transmitted_interaction["interval_upper"]), 0.015, "interaction upper interval")
    if integer(transmitted_interaction, "bootstrap_resamples") != 100_000:
        raise AssertionError("interaction bootstrap count changed")

    completion = tables["offset_split_completion_case_set_B"]
    expected_completion = {
        "experiment_id": "RQ2-GD-OFFSET-SPLIT-001",
        "stage": "heldout",
        "status": "complete_valid",
        "correctness_passed": True,
        "deterministic_replay_passed": True,
        "science_sha256": "a42793a4e94485e3f91873c1bb1cdce943879447a982555275ccf13483445125",
    }
    for key, expected_value in expected_completion.items():
        if completion.get(key) != expected_value:
            raise AssertionError(f"completion gate changed for {key}: {completion.get(key)!r}")

    null_rows = tables["offset_reassignment_case_set_B"]
    for row in null_rows:
        verify_paired_decomposition(
            row,
            treatment_only_key="treatment_only_success",
            reference_only_key="reference_only_success",
            treatment_success_key="treatment_successes",
            reference_success_key="reference_successes",
            risk_key="risk_difference",
            label=f"null/{row['endpoint']}/{row['contrast']}",
        )
    null_arm_map = {
        "reference_vs_control": ("reference", "control"),
        "permuted_vs_control": ("permuted", "control"),
        "frozen_vs_control": ("frozen", "control"),
        "reference_vs_permuted": ("reference", "permuted"),
        "reference_vs_frozen": ("reference", "frozen"),
    }

    def null_endpoint(endpoint: str) -> dict[str, dict[str, str]]:
        selected: dict[str, dict[str, str]] = {}
        arm_successes: dict[str, set[int]] = {}
        for contrast, (treatment, reference_arm) in null_arm_map.items():
            row = one(null_rows, endpoint=endpoint, contrast=contrast)
            if (row["treatment"], row["reference"]) != (treatment, reference_arm):
                raise AssertionError(f"null-control arm mapping changed for {endpoint}/{contrast}")
            if integer(row, "pairs") != 200:
                raise AssertionError(f"null-control pair count changed for {endpoint}/{contrast}")
            arm_successes.setdefault(treatment, set()).add(integer(row, "treatment_successes"))
            arm_successes.setdefault(reference_arm, set()).add(integer(row, "reference_successes"))
            selected[contrast] = row
        inconsistent = {arm: values for arm, values in arm_successes.items() if len(values) != 1}
        if inconsistent:
            raise AssertionError(f"shared null-control arms have inconsistent totals for {endpoint}: {inconsistent}")
        return selected

    null_transmitted = null_endpoint("transmitted_word_equal")
    null_parity = null_endpoint("parity_valid")
    for contrast in null_arm_map:
        transmitted = {k: v for k, v in null_transmitted[contrast].items() if k != "endpoint"}
        parity = {k: v for k, v in null_parity[contrast].items() if k != "endpoint"}
        if transmitted != parity:
            raise AssertionError(f"null-control parity-valid row differs from transmitted-word row: {contrast}")
    reference = null_transmitted["reference_vs_control"]
    permuted = null_transmitted["permuted_vs_control"]
    frozen = null_transmitted["frozen_vs_control"]
    expected_null = {
        "unused": integer(reference, "reference_successes"),
        "each_check_reads_its_own": integer(reference, "treatment_successes"),
        "reassigned_between_checks": integer(permuted, "treatment_successes"),
        "own_offsets_kept_from_first_adoption": integer(frozen, "treatment_successes"),
    }
    if evidence["offset_reassignment_case_set_B"] != expected_null:
        raise AssertionError("offset reassignment table does not reproduce the retained aggregate")

    native_rows = tables["native_gap_case_set_B"]
    for row in native_rows:
        verify_paired_decomposition(
            row,
            treatment_only_key="bp_only_success",
            reference_only_key="gd_only_success",
            treatment_success_key="bp_successes",
            reference_success_key="gd_successes",
            risk_key="risk_difference_bp_minus_gd",
            label=f"native/{row['endpoint']}",
        )
    native = one(native_rows, endpoint="transmitted_word_equal")
    native_parity = one(native_rows, endpoint="parity_valid")
    if {k: v for k, v in native.items() if k != "endpoint"} != {
        k: v for k, v in native_parity.items() if k != "endpoint"
    }:
        raise AssertionError("native parity-valid and transmitted-word rows differ")
    bp = integer(native, "bp_successes")
    gd = integer(native, "gd_successes")
    constructed = expected_split["parity_uses_offsets__ordinary_interval"]
    expected_native = {
        "belief_propagation": bp,
        "projected_gradient_descent": gd,
        "constructed_variant": constructed,
        "cases_recovered_by_constructed_variant": constructed - gd,
        "cases_still_unexplained": bp - constructed,
    }
    if evidence["native_gap_case_set_B"] != expected_native:
        raise AssertionError("native-gap decomposition is inconsistent")


FOLLOWUP_ARMS = {
    "assignment_given_refreshed": ("asbuilt__refreshed", "permuted__refreshed"),
    "assignment_given_frozen": ("asbuilt__frozen", "permuted__frozen"),
    "refresh_given_asbuilt": ("asbuilt__refreshed", "asbuilt__frozen"),
    "refresh_given_permuted": ("permuted__refreshed", "permuted__frozen"),
}
FOLLOWUP_SCIENCE = {
    "transfer": "2556c01f170d0e3f42bdcca831df47278270ec13628e84a1541a7976668c5595",
    "attribution": "e39e1894f0bdfec60960c8f5da6e85173559275e4586d9014f2678829bc0003a",
}


def displayed(shown: float, actual: str | float, label: str) -> None:
    """The page prints 3 decimals, or 4 when 0 < |value| < 0.001."""
    value = float(actual)
    tolerance = 0.00005 if 0 < abs(float(shown)) < 0.001 else 0.0005
    if not math.isfinite(value) or abs(float(shown) - value) > tolerance + 1e-12:
        raise AssertionError(f"{label}: displayed {shown} does not round {actual}")


def followup_stage(rows: list[dict[str, str]], label: str) -> tuple[dict[str, dict[str, str]], dict[str, int]]:
    for row in rows:
        verify_paired_decomposition(
            row,
            treatment_only_key="treatment_only_success",
            reference_only_key="reference_only_success",
            treatment_success_key="treatment_successes",
            reference_success_key="reference_successes",
            risk_key="risk_difference",
            label=f"{label}/{row['endpoint']}/{row['contrast']}",
        )
    selected: dict[tuple[str, str], dict[str, str]] = {}
    totals: dict[tuple[str, str], set[int]] = {}
    for endpoint in ("transmitted_word_equal", "parity_valid"):
        for contrast, (treatment, reference) in FOLLOWUP_ARMS.items():
            row = one(rows, endpoint=endpoint, contrast=contrast)
            if (row["treatment"], row["reference"]) != (treatment, reference):
                raise AssertionError(f"{label}: arm mapping changed for {endpoint}/{contrast}")
            if integer(row, "pairs") != 200:
                raise AssertionError(f"{label}: pair count changed for {endpoint}/{contrast}")
            totals.setdefault((endpoint, treatment), set()).add(integer(row, "treatment_successes"))
            totals.setdefault((endpoint, reference), set()).add(integer(row, "reference_successes"))
            selected[(endpoint, contrast)] = row
    inconsistent = {key: values for key, values in totals.items() if len(values) != 1}
    if inconsistent:
        raise AssertionError(f"{label}: shared arms have inconsistent totals: {inconsistent}")
    for contrast in FOLLOWUP_ARMS:
        transmitted = {k: v for k, v in selected[("transmitted_word_equal", contrast)].items() if k != "endpoint"}
        parity = {k: v for k, v in selected[("parity_valid", contrast)].items() if k != "endpoint"}
        if transmitted != parity:
            # Equal parity-valid and transmitted-word counts in every arm also rule out wrong valid words.
            raise AssertionError(f"{label}: parity-valid row differs from transmitted-word row for {contrast}")
    rows_tw = {contrast: selected[("transmitted_word_equal", contrast)] for contrast in FOLLOWUP_ARMS}
    arm_total = {arm: next(iter(values)) for (endpoint, arm), values in totals.items() if endpoint == "transmitted_word_equal"}
    return rows_tw, arm_total


def followup_counts(rows_tw: dict[str, dict[str, str]], arm_total: dict[str, int], label: str) -> dict[str, int]:
    a_r, a_k = rows_tw["assignment_given_refreshed"], rows_tw["assignment_given_frozen"]
    r_o, r_p = rows_tw["refresh_given_asbuilt"], rows_tw["refresh_given_permuted"]
    if integer(a_r, "reference_only_success") != 0 or integer(a_k, "reference_only_success") != 0:
        raise AssertionError(f"{label}: the own checks no longer lose no case to the permuted ones")
    return {
        "own_refreshed": arm_total["asbuilt__refreshed"],
        "own_kept": arm_total["asbuilt__frozen"],
        "permuted_refreshed": arm_total["permuted__refreshed"],
        "permuted_kept": arm_total["permuted__frozen"],
        "assignment_won_refreshed": integer(a_r, "treatment_only_success"),
        "assignment_won_kept": integer(a_k, "treatment_only_success"),
        "assignment_lost": 0,
        "refreshed_won_with_own": integer(r_o, "treatment_only_success"),
        "kept_won_with_own": integer(r_o, "reference_only_success"),
        "refreshed_won_with_permuted": integer(r_p, "treatment_only_success"),
        "kept_won_with_permuted": integer(r_p, "reference_only_success"),
    }


def followup_completion(completion: dict[str, Any], stage: str, embedded_sha: str) -> None:
    expected = {
        "experiment_id": "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001",
        "stage": stage,
        "status": "complete_valid",
        "correctness_passed": True,
        "deterministic_replay_passed": True,
        "science_sha256": FOLLOWUP_SCIENCE[stage],
    }
    for key, value in expected.items():
        if completion.get(key) != value:
            raise AssertionError(f"follow-up {stage} completion gate changed for {key}: {completion.get(key)!r}")
    if embedded_sha != FOLLOWUP_SCIENCE[stage]:
        raise AssertionError(f"embedded follow-up {stage} science hash changed")


def verify_followup(evidence: dict[str, Any], tables: dict[str, Any]) -> None:
    # Fresh transfer: the registered confirmatory family.
    rows_c, totals_c = followup_stage(tables["assignment_refresh_transfer_case_set_C"], "transfer")
    shown_c = evidence["assignment_refresh_case_set_C"]
    counts_c = followup_counts(rows_c, totals_c, "transfer")
    for key, value in counts_c.items():
        if shown_c.get(key) != value:
            raise AssertionError(f"transfer {key}: embedded {shown_c.get(key)!r} != retained {value!r}")
    if shown_c["fresh_cases"] != 200:
        raise AssertionError("transfer case count changed")
    for key, contrast in (("refreshed", "assignment_given_refreshed"), ("kept", "assignment_given_frozen")):
        row = rows_c[contrast]
        displayed(shown_c[f"assignment_rd_{key}"], row["risk_difference"], f"transfer assignment {key}")
        displayed(shown_c[f"assignment_interval_{key}"][0], row["interval_lower"], f"transfer assignment {key} lower")
        displayed(shown_c[f"assignment_interval_{key}"][1], row["interval_upper"], f"transfer assignment {key} upper")
        if not float(row["interval_lower"]) > 0:
            raise AssertionError(f"transfer assignment {key} interval no longer excludes zero")
        if not float(row["holm_p"]) < 0.05:
            raise AssertionError(f"transfer assignment {key} is no longer significant after Holm correction")
    for key, contrast in (("own", "refresh_given_asbuilt"), ("permuted", "refresh_given_permuted")):
        row = rows_c[contrast]
        displayed(shown_c[f"refresh_rd_with_{key}"], row["risk_difference"], f"transfer refresh with {key}")
        displayed(shown_c[f"refresh_interval_with_{key}"][0], row["interval_lower"], f"transfer refresh with {key} lower")
        displayed(shown_c[f"refresh_interval_with_{key}"][1], row["interval_upper"], f"transfer refresh with {key} upper")
        displayed(shown_c[f"refresh_holm_with_{key}"], row["holm_p"], f"transfer refresh with {key} Holm p")
        if (row["refresh_equivalence_evaluated"], row["refresh_equivalent_within_margin"]) != ("true", "false"):
            raise AssertionError(f"transfer refresh equivalence status changed for {key}")
        close(float(row["refresh_equivalence_margin"]), 0.05, f"transfer refresh margin {key}")
    if shown_c["refresh_equivalence_established"] is not False:
        raise AssertionError("embedded refresh-equivalence claim changed")
    interaction_rows = tables["assignment_refresh_transfer_interaction_case_set_C"]
    transmitted = one(interaction_rows, endpoint="transmitted_word_equal")
    if integer(transmitted, "frames") != 200 or integer(transmitted, "bootstrap_resamples") != 100_000:
        raise AssertionError("transfer interaction frame or resample count changed")
    displayed(shown_c["interaction"], transmitted["risk_difference_interaction"], "transfer interaction")
    displayed(shown_c["interaction_interval"][0], transmitted["bootstrap_lower"], "transfer interaction lower")
    displayed(shown_c["interaction_interval"][1], transmitted["bootstrap_upper"], "transfer interaction upper")
    if not float(transmitted["bootstrap_upper"]) < 0:
        raise AssertionError("transfer interaction interval no longer excludes zero")
    followup_completion(tables["assignment_refresh_transfer_completion_case_set_C"], "transfer", shown_c["science_sha256"])

    # Locked attribution on case set B: descriptive transitions only.
    rows_b, totals_b = followup_stage(tables["assignment_refresh_attribution_case_set_B"], "attribution")
    shown_b = evidence["assignment_refresh_case_set_B"]
    counts_b = followup_counts(rows_b, totals_b, "attribution")
    for key, value in counts_b.items():
        if shown_b.get(key) != value:
            raise AssertionError(f"attribution {key}: embedded {shown_b.get(key)!r} != retained {value!r}")
    if shown_b["locked_cases"] != 200:
        raise AssertionError("attribution case count changed")
    interaction_b = one(tables["assignment_refresh_attribution_interaction_case_set_B"], endpoint="transmitted_word_equal")
    displayed(shown_b["interaction"], interaction_b["risk_difference_interaction"], "attribution interaction")
    followup_completion(tables["assignment_refresh_attribution_completion_case_set_B"], "attribution", shown_b["science_sha256"])
    if shown_b["own_refreshed"] != evidence["offset_split_case_set_B"]["parity_uses_offsets__ordinary_interval"]:
        raise AssertionError("own-check refreshed arm no longer has the split parity-term arm's count")

    # Native-GD transition accounting, recomputed case by case.
    frames = tables["assignment_refresh_attribution_frames_case_set_B"]
    native_rows = tables["native_gap_frames_case_set_B"]
    by_arm: dict[str, dict[int, dict[str, str]]] = {}
    for row in frames:
        by_arm.setdefault(row["arm"], {})[int(row["frame"])] = row
    if set(by_arm) != {"asbuilt__frozen", "asbuilt__refreshed", "permuted__frozen", "permuted__refreshed"}:
        raise AssertionError("attribution frame table arms changed")
    bp = {int(r["frame"]): r for r in native_rows if r["method"] == "bp_exact_sum_product"}
    gd = {int(r["frame"]): r for r in native_rows if r["method"] == "gd_native_projected"}
    ids = sorted(gd)
    if ids != list(range(30001, 30201)) or sorted(bp) != ids:
        raise AssertionError("native-gap frame set is not 30001:30200")
    for arm, rows in by_arm.items():
        if sorted(rows) != ids:
            raise AssertionError(f"attribution frames for {arm} are not 30001:30200")
        for frame in ids:
            if not (rows[frame]["received_sha256"] == gd[frame]["received_sha256"] == bp[frame]["received_sha256"]):
                raise AssertionError(f"received samples differ for frame {frame}")
            if rows[frame]["wrong_valid_word"] != "false":
                raise AssertionError(f"{arm} produced a wrong valid word on frame {frame}")
    success = lambda row: row["transmitted_word_equal"] == "true"
    native_ok = {f for f in ids if success(gd[f])}
    bp_ok = {f for f in ids if success(bp[f])}
    if native_ok - bp_ok:
        raise AssertionError("native GD succeeds where BP fails")
    gap = bp_ok - native_ok
    arm_ok = {arm: {f for f in ids if success(rows[f])} for arm, rows in by_arm.items()}
    for arm, total in totals_b.items():
        if len(arm_ok[arm]) != total:
            raise AssertionError(f"attribution frame table and aggregate disagree for {arm}")
    names = {"asbuilt__frozen": "own_kept", "asbuilt__refreshed": "own_refreshed", "permuted__refreshed": "permuted_refreshed", "permuted__frozen": "permuted_kept"}
    expected: dict[str, Any] = {"belief_propagation": len(bp_ok), "projected_gradient_descent": len(native_ok), "bp_only": len(gap)}
    for arm, key in names.items():
        expected[f"{key}_recovered"] = len(arm_ok[arm] & gap)
        expected[f"{key}_lost"] = len(native_ok - arm_ok[arm])
    kept = by_arm["asbuilt__frozen"]
    unresolved = sorted(gap - arm_ok["asbuilt__frozen"])
    expected["unresolved"] = len(unresolved)
    budgets = set()
    for frame in unresolved:
        if kept[frame]["accepted_steps"] != kept[frame]["requested_steps"]:
            raise AssertionError(f"unresolved frame {frame} stopped before its update budget")
        budgets.add(int(kept[frame]["accepted_steps"]))
    if len(budgets) != 1:
        raise AssertionError("unresolved frames used different update budgets")
    expected["update_budget"] = budgets.pop()
    errors = Counter(int(kept[frame]["coded_bit_errors"]) for frame in unresolved)
    expected["unresolved_bit_errors"] = {str(k): v for k, v in sorted(errors.items())}
    expected["unresolved_bit_errors_min"] = min(errors)
    expected["unresolved_bit_errors_max"] = max(errors)
    native_errors = [int(gd[frame]["coded_bit_errors"]) for frame in unresolved]
    expected["unresolved_native_gd_bit_errors"] = [min(native_errors), max(native_errors)]
    expected["bp_iterations"] = {str(k): v for k, v in sorted(Counter(int(bp[f]["iterations"]) for f in ids).items())}
    others = arm_ok["asbuilt__refreshed"] | arm_ok["permuted__refreshed"] | arm_ok["permuted__frozen"]
    expected["kept_own_contains_all_other_successes"] = others <= arm_ok["asbuilt__frozen"]
    if evidence["native_accounting_case_set_B"] != expected:
        raise AssertionError(f"native-GD accounting mismatch: {evidence['native_accounting_case_set_B']} != {expected}")
    if expected["kept_own_contains_all_other_successes"] is not True or expected["own_kept_lost"] != 0:
        raise AssertionError("the page's nesting or no-loss claim no longer holds")
    if expected["projected_gradient_descent"] != evidence["native_gap_case_set_B"]["projected_gradient_descent"]:
        raise AssertionError("native-gap frame table and aggregate disagree")


def verify_html(html: str) -> None:
    if len(re.findall(r"^INTUITION_BEATS\.push\(\{", html, flags=re.MULTILINE)) != CORE_SCENES:
        raise AssertionError("unexpected number of intuitive scenes")
    if len(re.findall(r"^BEATS\.push\(\{", html, flags=re.MULTILINE)) != EVIDENCE_BEATS:
        raise AssertionError("unexpected number of retained evidence beats")
    required = (
        "Intuitive explanation",
        "Full evidence",
        "Start scene over",
        "CASE SET A · A DIFFERENT 200 LOCKED CASES",
        "CASE SET B · 200 LOCKED 6 dB CASES",
        "They are not BP messages",
        "The recovery increase follows the parity calculation",
        "Changing only the interval used to project x_i adds no observed recovery",
        "the cause of native BP’s advantage is not yet established",
        "SEPARATE COMPOUND-ARM CONTROL",
        "accepted GD update",
        "Verification scope.",
        "Enlarge chart for readable labels",
        "data-core-step",
        "#core=",
        "^#b",
        "With only the parity calculation reading them, the check assignment decides",
        "PARITY CALCULATION ONLY · PROJECTION ONTO [−1, 1] IN EVERY ARM",
        "REPEATED ON 200 FRESH CASES · THE REGISTERED CONFIRMATORY TEST",
        "What the follow-up found",
        "The 33 cases no constructed variant recovers",
        "this deck makes no current-status claim",
    )
    for phrase in required:
        if phrase not in html:
            raise AssertionError(f"required explanation or interaction is missing: {phrase!r}")
    banned_patterns = {
        "ambiguous input comparison": r"matched[ -]inputs?|input[ -]matched|common inputs|same inputs|identical[ -]inputs?",
        "GD-message conflation": r"gradient messages?",
        "GD messages": r"\bGD messages?\b|gradient[ -]descent messages?",
        "GD sends messages": r"\bGD\s+(?:passes|sends|stores|retains|computes)\s+(?:a\s+|the\s+)?messages?\b",
        "GD message-passing conflation": r"(?:GD|gradient[ -]descent|projected gradient descent).{0,50}message[ -]passing",
        "offset-message conflation": r"offsets act like extrinsic messages",
        "offsets called messages": r"offsets?\s+(?:are|become|act as|serve as)\s+(?:BP\s+|extrinsic\s+)?messages?\b",
        "banned GD indexing wording": r"bit-indexed",
        "stale live status": r"running now|attempt v4 running|experiment running now",
        "unsupported native causal attribution": r"causally explains part of the (?:native )?(?:BP.?GD )?gap|causal part of the performance gap",
        "overstated null effect": r"projection interval contributes nothing|interval (?:alone )?adds nothing",
        "unsupported case identity": r"coincide to the case",
    }
    for label, pattern in banned_patterns.items():
        if re.search(pattern, html, flags=re.IGNORECASE):
            raise AssertionError(f"{label} remains in reader-visible source: {pattern}")
    if "body[data-motion=\"paused\"]" not in html:
        raise AssertionError("Full evidence does not default to a paused/static state")
    if "position:sticky" not in html:
        raise AssertionError("navigation is not kept visible")
    if '.core-click:focus-visible>rect' not in html:
        raise AssertionError("SVG reveal controls do not expose keyboard focus")
    if 'role="img"' in html:
        raise AssertionError("interactive SVG content is hidden behind an image role")
    if 'role="tablist"' in html or "setAttribute('role','tab')" in html:
        raise AssertionError("scene navigation declares incomplete tab semantics")
    if ".stage svg{width:760px" in html:
        raise AssertionError("mobile layout still hides half the scene in a horizontal scroller")
    if 'body[data-mode="core"][data-mobile-zoom="readable"] .stage svg{width:960px' not in html:
        raise AssertionError("mobile layout lacks a readable-size chart option")
    if "button,summary,details,a,input,select,textarea,[role=\"button\"]" not in html:
        raise AssertionError("global keyboard navigation still intercepts interactive controls")
    if "Evidence and provenance" not in html or "<details class=\"src\"" not in html:
        raise AssertionError("provenance is not collapsed behind a disclosure control")
    light_palette = re.search(
        r":root\{.*?--paper:(#[0-9a-fA-F]{6}).*?--panel:(#[0-9a-fA-F]{6}).*?--act:(#[0-9a-fA-F]{6});\s*--oonly:(#[0-9a-fA-F]{6});\s*--ponly:(#[0-9a-fA-F]{6});.*?--ok:(#[0-9a-fA-F]{6});\s*--warn:(#[0-9a-fA-F]{6})",
        html,
        flags=re.DOTALL,
    )
    if not light_palette:
        raise AssertionError("could not inspect the light-mode result palette")
    paper, panel, active, parity_only, projection_only, success, warning = light_palette.groups()
    for label, background in (
        ("active", active),
        ("parity-only", parity_only),
        ("projection-only", projection_only),
        ("success", success),
        ("warning", warning),
    ):
        for surface_label, surface in (("paper", paper), ("panel", panel)):
            ratio = contrast_ratio(surface, background)
            if ratio < 4.5:
                raise AssertionError(
                    f"small light-mode text fails AA contrast on {label}/{surface_label}: {ratio:.2f}:1"
                )


class PlainTextParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
        self.hidden_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in {"script", "style"}:
            self.hidden_depth += 1

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style"} and self.hidden_depth:
            self.hidden_depth -= 1

    def handle_data(self, data: str) -> None:
        if not self.hidden_depth and data.strip():
            self.parts.append(data.strip())


def element_text(dom: str, tag: str, element_id: str) -> str:
    match = re.search(
        rf'<{tag}\b[^>]*\bid="{re.escape(element_id)}"[^>]*>(.*?)</{tag}>',
        dom,
        flags=re.DOTALL | re.IGNORECASE,
    )
    if not match:
        raise AssertionError(f"rendered DOM is missing {tag}#{element_id}")
    parser = PlainTextParser()
    parser.feed(match.group(1))
    return " ".join(parser.parts)


def dump_dom(browser: str, url: str, window_size: str, budget: int = 2500) -> str:
    timeout_seconds = 90
    with tempfile.TemporaryDirectory(prefix="offset-split-chrome-", ignore_cleanup_errors=True) as profile:
        command = [
            browser,
            "--headless=new",
            "--no-sandbox",
            "--disable-gpu",
            "--disable-dev-shm-usage",
            "--allow-file-access-from-files",
            f"--user-data-dir={profile}",
            f"--window-size={window_size}",
            f"--virtual-time-budget={budget}",
            "--dump-dom",
            url,
        ]
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=timeout_seconds)
        except subprocess.TimeoutExpired as error:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
            raise AssertionError(
                f"headless browser timed out after {timeout_seconds}s for {url}; stderr tail:\n{stderr[-1200:]}"
            ) from error
    if process.returncode != 0:
        raise AssertionError(f"headless browser exited {process.returncode}:\n{stderr[-1200:]}")
    return stdout


def browser_smoke() -> str:
    browser = next(
        (path for name in ("google-chrome", "chromium", "chromium-browser") if (path := shutil.which(name))),
        None,
    )
    if browser is None:
        return "skipped (no Chrome/Chromium executable)"
    base = HTML_PATH.resolve().as_uri()
    desktop = dump_dom(browser, base + "?smoke=1#core=1", "1440,900")
    required_attrs = (
        'data-offset-split-ready="true"',
        'data-offset-split-smoke="passed"',
        f'data-offset-split-smoke-core="{CORE_SCENES}"',
        f'data-offset-split-smoke-evidence="{EVIDENCE_BEATS}"',
        'data-layout-core-bounds="passed"',
        'data-layout-evidence-bounds="passed"',
        'data-layout-overflow="none"',
        'data-layout-stage-fit="true"',
    )
    for attribute in required_attrs:
        if attribute not in desktop:
            raise AssertionError(f"desktop smoke is missing {attribute}")
    if f"Scene 1 of {CORE_SCENES} · reveal 1 of 3" not in desktop:
        raise AssertionError("smoke did not return to the first intuitive scene")

    result = dump_dom(browser, base + "#core=6.4", "1440,900", 1200)
    if f"Scene 6 of {CORE_SCENES} · reveal 5 of 5" not in result:
        raise AssertionError("core deep link did not open the final result reveal")
    result_visible = element_text(result, "div", "stage") + " " + element_text(result, "aside", "aside")
    for value in ("107", "106", "163", "+56", "+57", "−1"):
        if value not in result_visible:
            raise AssertionError(f"visible core result is missing {value}")
    if "OBSERVED GAIN: PARITY CALCULATION USES THE STORED OFFSETS" not in result_visible:
        raise AssertionError("visible result does not state the isolated operation")
    core_cells = {
        "core-result-neither": ("Neither switch", "107"),
        "core-result-interval": ("Interval only", "106"),
        "core-result-parity": ("Parity only", "163"),
        "core-result-both": ("Both switches", "163"),
    }
    for element_id, expected_values in core_cells.items():
        cell_text = element_text(result, "g", element_id)
        if not all(value in cell_text for value in expected_values):
            raise AssertionError(f"visible core result cell is wrong: {element_id} -> {cell_text!r}")

    switches = dump_dom(browser, base + "#core=5.2", "1440,900", 1200)
    switches_visible = element_text(switches, "div", "stage")
    if not re.search(
        r"does it use the stored offsets\?.*OFF.*does the interval come from the offsets\?.*ON",
        switches_visible,
    ):
        raise AssertionError("interval-only demonstration does not visibly return Switch 1 to OFF")

    reassignment = dump_dom(browser, base + "#core=7.3", "1440,900", 1200)
    reassignment_visible = element_text(reassignment, "div", "stage") + " " + element_text(reassignment, "aside", "aside")
    for phrase in ("SEPARATE COMPOUND-ARM CONTROL", "isolates assignment", "no recovery difference"):
        if phrase not in reassignment_visible:
            raise AssertionError(f"reassignment scene is missing its scope: {phrase}")

    follow = dump_dom(browser, base + "#core=8.4", "1440,900", 1200)
    if f"Scene 8 of {CORE_SCENES} · reveal 5 of 5" not in follow:
        raise AssertionError("core deep link did not open the follow-up scene's last reveal")
    follow_visible = element_text(follow, "div", "stage") + " " + element_text(follow, "aside", "aside")
    follow_cells = {
        "core-follow-permuted-refreshed": ("permuted · refreshed", "81"),
        "core-follow-permuted-kept": ("permuted · kept", "63"),
        "core-follow-own-refreshed": ("own · refreshed", "163"),
        "core-follow-own-kept": ("own · kept", "167"),
    }
    for element_id, expected_values in follow_cells.items():
        cell_text = element_text(follow, "g", element_id)
        if not all(value in cell_text for value in expected_values):
            raise AssertionError(f"visible follow-up cell is wrong: {element_id} -> {cell_text!r}")
    for value in ("+82", "+104", "+4", "−18", "165", "174", "70", "61", "REPEATED ON 200 FRESH CASES", "loses none"):
        if value not in follow_visible:
            raise AssertionError(f"visible follow-up scene is missing {value}")

    boundary = dump_dom(browser, base + "#core=9.4", "1440,900", 1200)
    boundary_visible = element_text(boundary, "div", "stage") + " " + element_text(boundary, "aside", "aside")
    for phrase in (
        "among the four constructed GD variants",
        "Whether that operation explains native BP’s advantage remains an open experiment",
        "the cause of native BP’s advantage is not yet established",
        "107 → 163 → 167",
        "33",
    ):
        if phrase not in boundary_visible:
            raise AssertionError(f"boundary scene is missing its registered scope: {phrase}")

    legacy = dump_dom(browser, base + f"#b{EVIDENCE_BEATS}", "1440,900", 1200)
    if f"Evidence {EVIDENCE_BEATS} of {EVIDENCE_BEATS}" not in legacy:
        raise AssertionError("legacy #bN route did not open Full evidence")
    if 'id="evidenceMode" aria-pressed="true"' not in legacy:
        raise AssertionError("Full evidence mode is not selected on a legacy route")
    if 'data-motion="paused"' not in legacy:
        raise AssertionError("Full evidence auto-started instead of opening static")

    evidence_result = dump_dom(browser, base + "#b16", "1440,900", 1200)
    evidence_cells = {
        "evidence-result-control": ("native control", "107"),
        "evidence-result-interval": ("interval only", "106"),
        "evidence-result-parity": ("parity term only", "163"),
        "evidence-result-both": ("both", "163"),
    }
    for element_id, expected_values in evidence_cells.items():
        cell_text = element_text(evidence_result, "g", element_id)
        if not all(value in cell_text for value in expected_values):
            raise AssertionError(f"visible evidence result cell is wrong: {element_id} -> {cell_text!r}")
    follow_evidence = dump_dom(browser, base + "#b21", "1440,900", 1200)
    for element_id, value in {
        "evidence-follow-c-pr": "70", "evidence-follow-c-pk": "61", "evidence-follow-c-or": "165", "evidence-follow-c-ok": "174",
        "evidence-follow-b-pr": "81", "evidence-follow-b-pk": "63", "evidence-follow-b-or": "163", "evidence-follow-b-ok": "167",
    }.items():
        if value not in element_text(follow_evidence, "g", element_id):
            raise AssertionError(f"visible follow-up evidence cell is wrong: {element_id}")
    if '<p class="mode-note" id="modeNote"><strong>Verification scope.</strong>' not in evidence_result:
        raise AssertionError("Full evidence does not disclose the automated verification boundary")

    mobile = dump_dom(browser, base + "?smoke=1#core=1", "500,800")
    if 'data-layout-overflow="none"' not in mobile:
        raise AssertionError("mobile page overflows horizontally")
    if 'data-layout-stage-fit="true"' not in mobile:
        raise AssertionError("mobile stage does not fit the viewport")
    if 'data-mobile-zoom-check="passed"' not in mobile:
        raise AssertionError("mobile readable-size chart zoom failed")
    if 'data-mobile-active-pill="visible"' not in mobile:
        raise AssertionError("mobile scene strip did not reveal the active scene pill")
    return f"passed ({Path(browser).name}; visible claims, controls, deep links, legacy route, mobile)"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-browser", action="store_true", help="skip the headless-browser checks")
    args = parser.parse_args()

    html = HTML_PATH.read_text(encoding="utf-8")
    evidence = extract_evidence(html)
    if evidence.get("schema_version") != 1:
        raise AssertionError("unexpected embedded evidence schema")
    verify_toy(evidence)
    tables = verify_sources(evidence)
    verify_tables(evidence, tables)
    verify_followup(evidence, tables)
    verify_html(html)
    browser = "skipped by request" if args.skip_browser else browser_smoke()
    print(f"PASS: {CORE_SCENES} intuitive scenes, {EVIDENCE_BEATS} evidence beats, retained tables and terminology gates")
    print(f"Browser: {browser}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
