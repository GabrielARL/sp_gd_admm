#!/usr/bin/env python3
"""Deterministic RQ1-STATE-002 belief-propagation state ablation.

The primary treatment is a one-update pulse after the standard variable-node
update and before the check-node update.  Every branch starts from the same
saved check-to-variable state.  The persistent treatment is available as a
separate diagnostic and is never silently substituted for the pulse.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import itertools
import json
import math
import platform
import shlex
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from fractions import Fraction
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple


SCHEMA_VERSION = "rq1-state-002/v2"
DEFAULT_ITERATIONS = 3
DEFAULT_INTERVENTION_ITERATION = 2
ABS_TOL = 1.0e-12

VARIANTS = (
    "full",
    "qbar_collapse",
    "delta_shadow_ignored",
    "qbar_delta_reconstruct",
    "posterior_copy_diagnostic",
)
TREATMENTS = ("pulse", "persistent")
PRIMARY_CASE_IDS = (
    "symmetric_tree",
    "nonzero_sum_tree",
    "degree_one_six_bit",
)


@dataclass(frozen=True)
class Case:
    case_id: str
    description: str
    h: Tuple[Tuple[int, ...], ...]
    llr: Tuple[float, ...]

    def __post_init__(self) -> None:
        if not self.h or not self.llr:
            raise ValueError("H and the channel-LLR vector must be nonempty")
        n = len(self.llr)
        if any(len(row) != n for row in self.h):
            raise ValueError("every row of H must match the channel-LLR length")
        if any(value not in (0, 1) for row in self.h for value in row):
            raise ValueError("H must be binary")
        if any(sum(row) < 2 for row in self.h):
            raise ValueError("this harness requires every check degree to be at least two")
        if any(sum(row[i] for row in self.h) < 1 for i in range(n)):
            raise ValueError("this harness requires every bit to have positive degree")

    @property
    def n_bits(self) -> int:
        return len(self.llr)

    @property
    def n_checks(self) -> int:
        return len(self.h)

    @property
    def edges(self) -> Tuple[Tuple[int, int], ...]:
        """Return (bit, check) pairs in stable bit-major order."""
        return tuple(
            (bit, check)
            for bit in range(self.n_bits)
            for check in range(self.n_checks)
            if self.h[check][bit]
        )

    @property
    def edge_slots(self) -> Tuple[str, ...]:
        """Return neutral labels for the stable undirected edge slots."""
        return tuple(f"b{bit}-c{check}" for bit, check in self.edges)

    @property
    def q_edge_labels(self) -> Tuple[str, ...]:
        """Return variable-to-check labels in edge-slot order."""
        return tuple(f"b{bit}->c{check}" for bit, check in self.edges)

    @property
    def u_edge_labels(self) -> Tuple[str, ...]:
        """Return check-to-variable labels in edge-slot order."""
        return tuple(f"c{check}->b{bit}" for bit, check in self.edges)


def _make_cases() -> Dict[str, Case]:
    tree_h = ((1, 1, 0), (0, 1, 1))
    return {
        "symmetric_tree": Case(
            case_id="symmetric_tree",
            description=(
                "Three bits and two degree-two checks; incoming iteration-one "
                "messages at the shared bit cancel in the a-posteriori LLR."
            ),
            h=tree_h,
            llr=(-math.log(9.0), math.log(3.0 / 2.0), math.log(9.0)),
        ),
        "nonzero_sum_tree": Case(
            case_id="nonzero_sum_tree",
            description=(
                "Three-bit calibration in which qbar and the a-posteriori LLR "
                "at the shared bit are deliberately different."
            ),
            h=tree_h,
            llr=(-math.log(9.0), math.log(3.0 / 2.0), math.log(2.0)),
        ),
        "degree_one_six_bit": Case(
            case_id="degree_one_six_bit",
            description=(
                "Six-bit, two-check example from the retained TeX source; every "
                "bit has degree one, so every recipient-specific delta is zero."
            ),
            h=(
                (0, 1, 1, 0, 0, 1),
                (1, 0, 0, 1, 1, 0),
            ),
            llr=(-0.38, 0.48, 0.14, 4.78, 2.85, 1.10),
        ),
        "cyclic_four_bit": Case(
            case_id="cyclic_four_bit",
            description=(
                "Four-bit cycle with four degree-two checks; the fourth check "
                "is linearly dependent.  This is a separately configured "
                "two-iteration confirmation case."
            ),
            h=(
                (1, 1, 0, 0),
                (0, 1, 1, 0),
                (0, 0, 1, 1),
                (1, 0, 0, 1),
            ),
            llr=(-math.log(9.0), math.log(3.0 / 2.0), math.log(2.0), math.log(3.0)),
        ),
    }


CASES = _make_cases()


@dataclass(frozen=True)
class Decomposition:
    qbar_by_bit: Tuple[float, ...]
    delta_by_edge: Tuple[float, ...]
    qbar_exact_by_bit: Tuple[Fraction, ...]
    delta_exact_by_edge: Tuple[Fraction, ...]
    reconstructed_by_edge: Tuple[float, ...]


def _edge_indices_at_bit(case: Case, bit: int) -> Tuple[int, ...]:
    return tuple(k for k, (candidate, _) in enumerate(case.edges) if candidate == bit)


def _edge_indices_at_check(case: Case, check: int) -> Tuple[int, ...]:
    return tuple(k for k, (_, candidate) in enumerate(case.edges) if candidate == check)


def variable_update(case: Case, u_in: Sequence[float]) -> Tuple[float, ...]:
    if len(u_in) != len(case.edges):
        raise ValueError("U has the wrong edge dimension")
    result: List[float] = []
    for k, (bit, _) in enumerate(case.edges):
        incoming = (u_in[j] for j in _edge_indices_at_bit(case, bit) if j != k)
        result.append(case.llr[bit] + math.fsum(incoming))
    return tuple(result)


def posterior_llr(case: Case, u_values: Sequence[float]) -> Tuple[float, ...]:
    if len(u_values) != len(case.edges):
        raise ValueError("U has the wrong edge dimension")
    return tuple(
        case.llr[bit]
        + math.fsum(u_values[k] for k in _edge_indices_at_bit(case, bit))
        for bit in range(case.n_bits)
    )


def decompose_q(case: Case, q_standard: Sequence[float]) -> Decomposition:
    """Decompose each bit's outgoing Q values using exact binary64 bookkeeping.

    Fraction.from_float exposes each input's exact binary64 value.  Computing
    qbar and delta as fractions makes sum(delta)=0 and qbar+delta=Q exact.  Only
    the collapse branch rounds qbar back to binary64; the exact fractions are
    validation metadata, not an alternative numerical check-node kernel.
    """
    q_fractions = tuple(Fraction.from_float(float(value)) for value in q_standard)
    qbar_exact: List[Fraction] = []
    for bit in range(case.n_bits):
        indices = _edge_indices_at_bit(case, bit)
        qbar_exact.append(sum((q_fractions[k] for k in indices), Fraction()) / len(indices))

    delta_exact = tuple(
        q_fractions[k] - qbar_exact[bit]
        for k, (bit, _) in enumerate(case.edges)
    )
    reconstructed = tuple(
        float(qbar_exact[bit] + delta_exact[k])
        for k, (bit, _) in enumerate(case.edges)
    )
    return Decomposition(
        qbar_by_bit=tuple(float(value) for value in qbar_exact),
        delta_by_edge=tuple(float(value) for value in delta_exact),
        qbar_exact_by_bit=tuple(qbar_exact),
        delta_exact_by_edge=delta_exact,
        reconstructed_by_edge=reconstructed,
    )


def _check_message_tanh_atanh(
    case: Case, q_values: Sequence[float], recipient_edge: int
) -> float:
    _, check = case.edges[recipient_edge]
    indices = _edge_indices_at_check(case, check)
    others = tuple(k for k in indices if k != recipient_edge)
    degree = len(indices)
    product = math.prod(math.tanh(q_values[k] / 2.0) for k in others)
    argument = ((-1.0) ** (degree - 1)) * product
    if argument >= 1.0:
        argument = math.nextafter(1.0, 0.0)
    elif argument <= -1.0:
        argument = math.nextafter(-1.0, 0.0)
    return -2.0 * math.atanh(argument)


def check_update(case: Case, q_values: Sequence[float]) -> Tuple[float, ...]:
    if len(q_values) != len(case.edges):
        raise ValueError("Q has the wrong edge dimension")
    result: List[float] = []
    for k, (_, check) in enumerate(case.edges):
        indices = _edge_indices_at_check(case, check)
        if len(indices) == 2:
            # For an even-parity degree-two check, the message equals the other
            # incoming LLR exactly.  This algebraic identity avoids needless
            # tanh/atanh roundoff while retaining the same sum-product update.
            result.append(q_values[indices[0] if indices[1] == k else indices[1]])
        else:
            result.append(_check_message_tanh_atanh(case, q_values, k))
    return tuple(result)


def _logsumexp(values: Sequence[float]) -> float:
    maximum = max(values)
    return maximum + math.log(math.fsum(math.exp(value - maximum) for value in values))


def enumerate_check_message(
    case: Case, q_values: Sequence[float], recipient_edge: int
) -> float:
    """Independently enumerate local even-parity configurations."""
    recipient_bit, check = case.edges[recipient_edge]
    check_bits = tuple(bit for bit, present in enumerate(case.h[check]) if present)
    other_bits = tuple(bit for bit in check_bits if bit != recipient_bit)
    q_by_bit = {
        bit: q_values[next(k for k, edge in enumerate(case.edges) if edge == (bit, check))]
        for bit in other_bits
    }
    log_weights: Dict[int, List[float]] = {0: [], 1: []}
    for recipient_value in (0, 1):
        for assignment in itertools.product((0, 1), repeat=len(other_bits)):
            if (recipient_value + sum(assignment)) % 2 != 0:
                continue
            log_weights[recipient_value].append(
                math.fsum(q_by_bit[bit] for bit, value in zip(other_bits, assignment) if value)
            )
    return _logsumexp(log_weights[1]) - _logsumexp(log_weights[0])


def hard_decision(llr_values: Sequence[float]) -> Tuple[int, ...]:
    return tuple(1 if value >= 0.0 else 0 for value in llr_values)


def hard_decision_probability_check(llr_values: Sequence[float]) -> Tuple[int, ...]:
    probabilities = tuple(1.0 / (1.0 + math.exp(-value)) for value in llr_values)
    return tuple(1 if probability >= 0.5 else 0 for probability in probabilities)


def syndrome(case: Case, bits: Sequence[int]) -> Tuple[int, ...]:
    return tuple(
        sum(bit * present for bit, present in zip(bits, row)) % 2
        for row in case.h
    )


def syndrome_xor_check(case: Case, bits: Sequence[int]) -> Tuple[int, ...]:
    result: List[int] = []
    for row in case.h:
        parity = 0
        for bit, present in zip(bits, row):
            if present:
                parity ^= int(bit)
        result.append(parity)
    return tuple(result)


def _fraction_text(value: Fraction) -> str:
    return f"{value.numerator}/{value.denominator}"


def _add_float_vector(record: Dict[str, Any], name: str, values: Sequence[float]) -> None:
    record[name] = [float(value) for value in values]
    record[f"{name}_hex"] = [float(value).hex() for value in values]


def _state_hash(values: Sequence[float]) -> str:
    payload = json.dumps([float(value).hex() for value in values], separators=(",", ":"))
    return hashlib.sha256(payload.encode("ascii")).hexdigest()


def _select_q(
    case: Case,
    variant: str,
    q_standard: Tuple[float, ...],
    decomposition: Decomposition,
    a_posteriori_before: Tuple[float, ...],
    intervention_active: bool,
) -> Tuple[float, ...]:
    if not intervention_active or variant == "full":
        return q_standard
    if variant in ("qbar_collapse", "delta_shadow_ignored"):
        return tuple(decomposition.qbar_by_bit[bit] for bit, _ in case.edges)
    if variant == "qbar_delta_reconstruct":
        return decomposition.reconstructed_by_edge
    if variant == "posterior_copy_diagnostic":
        return tuple(a_posteriori_before[bit] for bit, _ in case.edges)
    raise ValueError(f"unknown variant: {variant}")


def _iteration(
    case: Case,
    u_in: Tuple[float, ...],
    iteration: int,
    variant: str,
    treatment: str,
    intervention_iteration: int,
) -> Tuple[Dict[str, Any], Tuple[float, ...]]:
    intervention_active = (
        iteration == intervention_iteration
        or (treatment == "persistent" and iteration >= intervention_iteration)
    )
    q_standard = variable_update(case, u_in)
    decomposition = decompose_q(case, q_standard)
    a_posteriori_before = posterior_llr(case, u_in)
    q_transmitted = _select_q(
        case,
        variant,
        q_standard,
        decomposition,
        a_posteriori_before,
        intervention_active,
    )
    u_out = check_update(case, q_transmitted)
    a_posteriori_after = posterior_llr(case, u_out)
    estimate = hard_decision(a_posteriori_after)
    check_syndrome = syndrome(case, estimate)

    record: Dict[str, Any] = {
        "iteration": iteration,
        "selected_variant": variant if intervention_active else "full",
        "treatment": treatment,
        "intervention_active": intervention_active,
        "edge_slots": list(case.edge_slots),
        "q_edge_labels": list(case.q_edge_labels),
        "u_edge_labels": list(case.u_edge_labels),
        "qbar_exact_by_bit": [
            _fraction_text(value) for value in decomposition.qbar_exact_by_bit
        ],
        "delta_exact_by_edge": [
            _fraction_text(value) for value in decomposition.delta_exact_by_edge
        ],
        "hard_decision_estimate": list(estimate),
        "syndrome": list(check_syndrome),
    }
    _add_float_vector(record, "u_in", u_in)
    _add_float_vector(record, "q_standard", q_standard)
    _add_float_vector(record, "qbar_by_bit", decomposition.qbar_by_bit)
    _add_float_vector(record, "delta_by_edge", decomposition.delta_by_edge)
    _add_float_vector(record, "q_reconstructed", decomposition.reconstructed_by_edge)
    _add_float_vector(record, "a_posteriori_before", a_posteriori_before)
    _add_float_vector(record, "q_transmitted", q_transmitted)
    _add_float_vector(record, "u_out", u_out)
    _add_float_vector(record, "a_posteriori_after", a_posteriori_after)
    return record, u_out


def _build_prefix(
    case: Case, treatment: str, intervention_iteration: int
) -> Tuple[List[Dict[str, Any]], Tuple[float, ...]]:
    u_values = tuple(0.0 for _ in case.edges)
    records: List[Dict[str, Any]] = []
    for iteration in range(1, intervention_iteration):
        record, u_values = _iteration(
            case,
            u_values,
            iteration,
            "full",
            treatment,
            intervention_iteration,
        )
        records.append(record)
    return records, u_values


def _branch(
    case: Case,
    variant: str,
    treatment: str,
    iterations: int,
    intervention_iteration: int,
    prefix: Sequence[Mapping[str, Any]],
    fork_u: Tuple[float, ...],
) -> Dict[str, Any]:
    records = copy.deepcopy(list(prefix))
    u_values = tuple(fork_u)
    for iteration in range(intervention_iteration, iterations + 1):
        record, u_values = _iteration(
            case,
            u_values,
            iteration,
            variant,
            treatment,
            intervention_iteration,
        )
        records.append(record)
    branch: Dict[str, Any] = {
        "variant": variant,
        "treatment": treatment,
        "fork_state_sha256": _state_hash(fork_u),
        "iterations": records,
    }
    _add_float_vector(branch, "fork_u", fork_u)
    return branch


def _make_branches(
    case: Case,
    treatment: str,
    iterations: int,
    intervention_iteration: int,
) -> Dict[str, Dict[str, Any]]:
    prefix, fork_u = _build_prefix(case, treatment, intervention_iteration)
    return {
        variant: _branch(
            case,
            variant,
            treatment,
            iterations,
            intervention_iteration,
            prefix,
            fork_u,
        )
        for variant in VARIANTS
    }


def structural_delta_witness() -> Dict[str, Any]:
    """Show that qbar alone does not determine the next check-node inputs."""
    case = CASES["symmetric_tree"]
    q_left = (0.75, 1.5, 0.5, -0.25)
    q_right = (0.75, 0.5, 1.5, -0.25)
    left_decomposition = decompose_q(case, q_left)
    right_decomposition = decompose_q(case, q_right)
    u_left = check_update(case, q_left)
    u_right = check_update(case, q_right)
    changed_u_edges = [
        case.u_edge_labels[k]
        for k, (left, right) in enumerate(zip(u_left, u_right))
        if left != right
    ]
    passed = (
        left_decomposition.qbar_exact_by_bit
        == right_decomposition.qbar_exact_by_bit
        and left_decomposition.delta_exact_by_edge
        != right_decomposition.delta_exact_by_edge
        and u_left != u_right
        and changed_u_edges == ["c0->b0", "c1->b2"]
    )
    return {
        "passed": passed,
        "case_id": case.case_id,
        "edge_slots": list(case.edge_slots),
        "q_edge_labels": list(case.q_edge_labels),
        "u_edge_labels": list(case.u_edge_labels),
        "q_left": list(q_left),
        "q_right": list(q_right),
        "qbar_left": list(left_decomposition.qbar_by_bit),
        "qbar_right": list(right_decomposition.qbar_by_bit),
        "delta_left": list(left_decomposition.delta_by_edge),
        "delta_right": list(right_decomposition.delta_by_edge),
        "u_left": list(u_left),
        "u_right": list(u_right),
        "changed_check_to_variable_edges": changed_u_edges,
    }


def _check_relabeling_control(
    case: Case,
    treatment: str,
    iterations: int,
    intervention_iteration: int,
    original_branches: Mapping[str, Mapping[str, Any]],
) -> Dict[str, Any]:
    """Reverse check-row labels and compare after applying the inverse map."""
    new_to_old_check = tuple(reversed(range(case.n_checks)))
    relabeled = Case(
        case_id=f"{case.case_id}__check_rows_reversed",
        description="validation-only consistent check-row relabeling",
        h=tuple(case.h[old] for old in new_to_old_check),
        llr=case.llr,
    )
    relabeled_branches = _make_branches(
        relabeled, treatment, iterations, intervention_iteration
    )
    original_edge_index = {edge: k for k, edge in enumerate(case.edges)}
    relabeled_edge_to_original = tuple(
        original_edge_index[(bit, new_to_old_check[new_check])]
        for bit, new_check in relabeled.edges
    )

    edge_fields = (
        "u_in",
        "q_standard",
        "delta_by_edge",
        "q_reconstructed",
        "q_transmitted",
        "u_out",
    )
    bit_fields = (
        "qbar_by_bit",
        "a_posteriori_before",
        "a_posteriori_after",
    )
    first_mismatch: Dict[str, Any] | None = None
    max_abs_error = 0.0

    for variant in VARIANTS:
        original_records = original_branches[variant]["iterations"]
        relabeled_records = relabeled_branches[variant]["iterations"]
        for original, changed in zip(original_records, relabeled_records):
            for field in edge_fields:
                for new_index, old_index in enumerate(relabeled_edge_to_original):
                    error = abs(float(changed[field][new_index]) - float(original[field][old_index]))
                    max_abs_error = max(max_abs_error, error)
                    if error > ABS_TOL and first_mismatch is None:
                        first_mismatch = {
                            "variant": variant,
                            "iteration": original["iteration"],
                            "field": field,
                            "new_edge_index": new_index,
                            "old_edge_index": old_index,
                            "error": error,
                        }
            for field in bit_fields:
                for bit, (left, right) in enumerate(zip(original[field], changed[field])):
                    error = abs(float(left) - float(right))
                    max_abs_error = max(max_abs_error, error)
                    if error > ABS_TOL and first_mismatch is None:
                        first_mismatch = {
                            "variant": variant,
                            "iteration": original["iteration"],
                            "field": field,
                            "bit": bit,
                            "error": error,
                        }
            expected_syndrome = [original["syndrome"][old] for old in new_to_old_check]
            discrete_match = (
                original["hard_decision_estimate"] == changed["hard_decision_estimate"]
                and expected_syndrome == changed["syndrome"]
                and original["qbar_exact_by_bit"] == changed["qbar_exact_by_bit"]
                and all(
                    original["delta_exact_by_edge"][old_index]
                    == changed["delta_exact_by_edge"][new_index]
                    for new_index, old_index in enumerate(relabeled_edge_to_original)
                )
            )
            if not discrete_match and first_mismatch is None:
                first_mismatch = {
                    "variant": variant,
                    "iteration": original["iteration"],
                    "field": "discrete_or_exact_value",
                }

    return {
        "passed": first_mismatch is None,
        "new_check_index_to_old_check_index": list(new_to_old_check),
        "new_edge_index_to_old_edge_index": list(relabeled_edge_to_original),
        "max_abs_error": max_abs_error,
        "first_mismatch": first_mismatch,
        "variants_checked": list(VARIANTS),
        "iterations_checked": iterations,
    }


def _numbers_close(left: float, right: float, tolerance: float = ABS_TOL) -> bool:
    return math.isclose(left, right, rel_tol=0.0, abs_tol=tolerance)


def _first_vector_difference(
    left: Sequence[float], right: Sequence[float], tolerance: float = ABS_TOL
) -> int | None:
    for index, (a, b) in enumerate(zip(left, right)):
        if not _numbers_close(float(a), float(b), tolerance):
            return index
    return None


def first_divergence(
    reference: Mapping[str, Any], candidate: Mapping[str, Any]
) -> Dict[str, Any] | None:
    stages = (
        "q_transmitted",
        "u_out",
        "a_posteriori_after",
        "hard_decision_estimate",
        "syndrome",
    )
    for left, right in zip(reference["iterations"], candidate["iterations"]):
        for stage in stages:
            if stage in ("hard_decision_estimate", "syndrome"):
                if left[stage] != right[stage]:
                    index = next(
                        i for i, pair in enumerate(zip(left[stage], right[stage]))
                        if pair[0] != pair[1]
                    )
                else:
                    continue
            else:
                index = _first_vector_difference(left[stage], right[stage])
                if index is None:
                    continue
            if stage == "q_transmitted":
                coordinate_kind = "variable_to_check_edge"
                coordinate_label = left["q_edge_labels"][index]
            elif stage == "u_out":
                coordinate_kind = "check_to_variable_edge"
                coordinate_label = left["u_edge_labels"][index]
            elif stage == "syndrome":
                coordinate_kind = "check"
                coordinate_label = f"c{index}"
            else:
                coordinate_kind = "bit"
                coordinate_label = f"b{index}"
            return {
                "iteration": left["iteration"],
                "stage": stage,
                "index": index,
                "coordinate_kind": coordinate_kind,
                "coordinate_label": coordinate_label,
                "reference": left[stage][index],
                "candidate": right[stage][index],
            }
    return None


def _trajectory_signature(branch: Mapping[str, Any]) -> List[Dict[str, Any]]:
    names = (
        "u_in",
        "q_standard",
        "qbar_by_bit",
        "delta_by_edge",
        "q_reconstructed",
        "a_posteriori_before",
        "q_transmitted",
        "u_out",
        "a_posteriori_after",
        "hard_decision_estimate",
        "syndrome",
    )
    return [{name: record[name] for name in names} for record in branch["iterations"]]


def _max_trajectory_error(left: Mapping[str, Any], right: Mapping[str, Any]) -> float:
    maximum = 0.0
    names = (
        "u_in",
        "q_standard",
        "qbar_by_bit",
        "delta_by_edge",
        "q_reconstructed",
        "a_posteriori_before",
        "q_transmitted",
        "u_out",
        "a_posteriori_after",
    )
    for left_record, right_record in zip(left["iterations"], right["iterations"]):
        for name in names:
            for a, b in zip(left_record[name], right_record[name]):
                maximum = max(maximum, abs(float(a) - float(b)))
    return maximum


def _check_entry(checks: Dict[str, Any], name: str, passed: bool, **details: Any) -> None:
    checks[name] = {"passed": bool(passed), **details}


def validate_trace(document: Mapping[str, Any]) -> Dict[str, Any]:
    case = CASES[str(document["case_id"])]
    branches = document["branches"]
    full = branches["full"]
    collapse = branches["qbar_collapse"]
    shadow = branches["delta_shadow_ignored"]
    reconstruct = branches["qbar_delta_reconstruct"]
    copy_branch = branches["posterior_copy_diagnostic"]
    checks: Dict[str, Any] = {}

    expected_slots = list(case.edge_slots)
    expected_q_labels = list(case.q_edge_labels)
    expected_u_labels = list(case.u_edge_labels)
    label_schema_valid = (
        document["edge_slots"] == expected_slots
        and document["q_edge_labels"] == expected_q_labels
        and document["u_edge_labels"] == expected_u_labels
        and all(
            record["edge_slots"] == expected_slots
            and record["q_edge_labels"] == expected_q_labels
            and record["u_edge_labels"] == expected_u_labels
            for branch in branches.values()
            for record in branch["iterations"]
        )
    )
    _check_entry(
        checks,
        "directed_edge_labels_match_neutral_slots",
        label_schema_valid,
        edge_slots=expected_slots,
        q_edge_labels=expected_q_labels,
        u_edge_labels=expected_u_labels,
    )

    witness = document["structural_delta_witness"]
    _check_entry(
        checks,
        "equal_qbar_different_delta_changes_next_check_inputs",
        bool(witness["passed"]),
        changed_check_to_variable_edges=witness["changed_check_to_variable_edges"],
    )

    relabeling = _check_relabeling_control(
        case,
        str(document["treatment"]),
        int(document["iterations"]),
        int(document["intervention_iteration"]),
        branches,
    )
    _check_entry(
        checks,
        "consistent_check_row_relabeling",
        bool(relabeling["passed"]),
        new_check_index_to_old_check_index=relabeling[
            "new_check_index_to_old_check_index"
        ],
        new_edge_index_to_old_edge_index=relabeling[
            "new_edge_index_to_old_edge_index"
        ],
        max_abs_error=relabeling["max_abs_error"],
        first_mismatch=relabeling["first_mismatch"],
    )

    fork_hashes = {branch["fork_state_sha256"] for branch in branches.values()}
    _check_entry(
        checks,
        "identical_saved_fork_state",
        len(fork_hashes) == 1,
        fork_state_sha256=next(iter(fork_hashes)) if len(fork_hashes) == 1 else sorted(fork_hashes),
    )

    prefix_count = int(document["intervention_iteration"]) - 1
    prefix_signatures = {
        json.dumps(_trajectory_signature(branch)[:prefix_count], sort_keys=True)
        for branch in branches.values()
    }
    _check_entry(
        checks,
        "pre_intervention_trajectories_identical",
        len(prefix_signatures) == 1,
        compared_iterations=prefix_count,
    )

    iteration_one = full["iterations"][0]
    iteration_one_delta_zero = all(
        Fraction(text) == 0 for text in iteration_one["delta_exact_by_edge"]
    )
    iteration_one_expanded_qbar_hex = [
        iteration_one["qbar_by_bit_hex"][bit] for bit, _ in case.edges
    ]
    _check_entry(
        checks,
        "iteration_one_qbar_collapse_negative_control",
        iteration_one_delta_zero
        and iteration_one["q_standard_hex"] == iteration_one_expanded_qbar_hex,
        every_delta_is_exactly_zero=iteration_one_delta_zero,
        qbar_expansion_is_bitwise_q_standard=(
            iteration_one["q_standard_hex"] == iteration_one_expanded_qbar_hex
        ),
    )

    shadow_equal = _trajectory_signature(collapse) == _trajectory_signature(shadow)
    _check_entry(
        checks,
        "retained_delta_but_ignored_equals_qbar_collapse",
        shadow_equal,
        comparison="binary64 trajectory equality",
    )

    reconstruction_error = _max_trajectory_error(full, reconstruct)
    reconstruction_bitwise = _trajectory_signature(full) == _trajectory_signature(reconstruct)
    _check_entry(
        checks,
        "qbar_plus_delta_reconstructs_full",
        reconstruction_bitwise,
        comparison="binary64 trajectory equality",
        max_abs_error=reconstruction_error,
    )

    delta_zero_sum = True
    exact_reconstruction = True
    max_check_enumeration_error = 0.0
    hard_independent = True
    syndrome_independent = True
    for branch in branches.values():
        for record in branch["iterations"]:
            for bit in range(case.n_bits):
                delta_sum = sum(
                    (
                        Fraction(text)
                        for text, (edge_bit, _) in zip(
                            record["delta_exact_by_edge"], case.edges
                        )
                        if edge_bit == bit
                    ),
                    Fraction(),
                )
                delta_zero_sum = delta_zero_sum and delta_sum == 0
            exact_reconstruction = exact_reconstruction and (
                record["q_standard_hex"] == record["q_reconstructed_hex"]
            )
            q_sent = tuple(float(value) for value in record["q_transmitted"])
            for k, value in enumerate(record["u_out"]):
                independently_enumerated = enumerate_check_message(case, q_sent, k)
                max_check_enumeration_error = max(
                    max_check_enumeration_error,
                    abs(float(value) - independently_enumerated),
                )
            llr_after = tuple(float(value) for value in record["a_posteriori_after"])
            estimate = tuple(int(value) for value in record["hard_decision_estimate"])
            hard_independent = hard_independent and (
                estimate == hard_decision_probability_check(llr_after)
            )
            syndrome_independent = syndrome_independent and (
                tuple(record["syndrome"]) == syndrome_xor_check(case, estimate)
            )

    _check_entry(
        checks,
        "delta_sums_are_exactly_zero",
        delta_zero_sum,
        arithmetic="exact rational representation of binary64 inputs",
    )
    _check_entry(
        checks,
        "every_q_reconstruction_is_bitwise_exact",
        exact_reconstruction,
    )
    _check_entry(
        checks,
        "check_messages_match_local_configuration_enumeration",
        max_check_enumeration_error <= ABS_TOL,
        max_abs_error=max_check_enumeration_error,
    )
    _check_entry(checks, "hard_decisions_match_probability_threshold", hard_independent)
    _check_entry(checks, "syndromes_match_independent_xor", syndrome_independent)

    if case.case_id == "degree_one_six_bit":
        every_delta_zero = all(
            all(float(value) == 0.0 for value in record["delta_by_edge"])
            for branch in branches.values()
            for record in branch["iterations"]
        )
        _check_entry(checks, "degree_one_delta_negative_control", every_delta_zero)
        _check_entry(
            checks,
            "degree_one_qbar_collapse_equals_full",
            _trajectory_signature(full) == _trajectory_signature(collapse),
        )
    else:
        divergence = first_divergence(full, collapse)
        expected = (
            divergence is not None
            and divergence["iteration"] == int(document["intervention_iteration"])
            and divergence["stage"] == "q_transmitted"
        )
        _check_entry(
            checks,
            "qbar_first_divergence_at_intervened_q",
            expected,
            observed=divergence,
        )

    if case.case_id == "symmetric_tree":
        t2_full = full["iterations"][1]
        t2_collapse = collapse["iterations"][1]
        t2_copy = copy_branch["iterations"][1]
        shared_to_c0 = case.q_edge_labels.index("b1->c0")
        shared_to_c1 = case.q_edge_labels.index("b1->c1")
        anchor_ok = all(
            (
                _numbers_close(t2_full["q_transmitted"][shared_to_c0], math.log(13.5)),
                _numbers_close(t2_full["q_transmitted"][shared_to_c1], math.log(1.0 / 6.0)),
                _numbers_close(t2_collapse["q_transmitted"][shared_to_c0], math.log(1.5)),
                _numbers_close(t2_collapse["q_transmitted"][shared_to_c1], math.log(1.5)),
                t2_full["hard_decision_estimate"] == [1, 1, 1],
                t2_full["syndrome"] == [0, 0],
                t2_collapse["hard_decision_estimate"] == [0, 1, 1],
                t2_collapse["syndrome"] == [1, 0],
                t2_copy["hard_decision_estimate"] == [0, 1, 1],
                t2_copy["syndrome"] == [1, 0],
            )
        )
        _check_entry(checks, "symmetric_anchor_values", anchor_ok)

    if case.case_id == "nonzero_sum_tree":
        t2_full = full["iterations"][1]
        t2_collapse = collapse["iterations"][1]
        shared_to_c0 = case.q_edge_labels.index("b1->c0")
        shared_to_c1 = case.q_edge_labels.index("b1->c1")
        anchor_ok = all(
            (
                _numbers_close(t2_full["q_transmitted"][shared_to_c0], math.log(3.0)),
                _numbers_close(t2_full["q_transmitted"][shared_to_c1], math.log(1.0 / 6.0)),
                _numbers_close(t2_collapse["q_transmitted"][shared_to_c0], -0.5 * math.log(2.0)),
                _numbers_close(t2_collapse["q_transmitted"][shared_to_c1], -0.5 * math.log(2.0)),
                _numbers_close(t2_full["a_posteriori_before"][1], -math.log(3.0)),
            )
        )
        _check_entry(checks, "nonzero_sum_calibration_values", anchor_ok)

    if case.case_id == "cyclic_four_bit":
        t2_full = full["iterations"][1]
        t2_collapse = collapse["iterations"][1]
        expected_full_q = (
            -math.log(3.0),
            math.log(1.0 / 6.0),
            math.log(3.0),
            math.log(1.0 / 6.0),
            math.log(6.0),
            math.log(3.0),
            -math.log(3.0),
            math.log(6.0),
        )
        expected_qbar = (
            -0.5 * math.log(18.0),
            -0.5 * math.log(2.0),
            0.5 * math.log(18.0),
            0.5 * math.log(2.0),
        )
        cycle_ok = (
            all(
                _numbers_close(observed, expected)
                for observed, expected in zip(t2_full["q_transmitted"], expected_full_q)
            )
            and all(
                _numbers_close(observed, expected_qbar[bit])
                for observed, (bit, _) in zip(t2_collapse["q_transmitted"], case.edges)
            )
            and t2_full["hard_decision_estimate"] == [1, 1, 0, 1]
            and t2_full["syndrome"] == [0, 1, 1, 0]
            and t2_collapse["hard_decision_estimate"] == [0, 1, 1, 1]
            and t2_collapse["syndrome"] == [1, 0, 0, 1]
        )
        _check_entry(checks, "cyclic_confirmation_values", cycle_ok)

    divergences = {
        name: first_divergence(full, branch)
        for name, branch in branches.items()
        if name != "full"
    }
    divergence_labels_valid = True
    for divergence in divergences.values():
        if divergence is None:
            continue
        record = next(
            item
            for item in full["iterations"]
            if item["iteration"] == divergence["iteration"]
        )
        stage = divergence["stage"]
        index = int(divergence["index"])
        if stage == "q_transmitted":
            expected_kind = "variable_to_check_edge"
            expected_label = record["q_edge_labels"][index]
        elif stage == "u_out":
            expected_kind = "check_to_variable_edge"
            expected_label = record["u_edge_labels"][index]
        elif stage == "syndrome":
            expected_kind = "check"
            expected_label = f"c{index}"
        else:
            expected_kind = "bit"
            expected_label = f"b{index}"
        divergence_labels_valid = divergence_labels_valid and (
            divergence["coordinate_kind"] == expected_kind
            and divergence["coordinate_label"] == expected_label
        )
    _check_entry(
        checks,
        "first_divergence_uses_stage_specific_coordinate_labels",
        divergence_labels_valid,
    )
    return {
        "all_passed": all(item["passed"] for item in checks.values()),
        "checks": checks,
        "first_divergence_from_full": divergences,
    }


def build_trace(
    case: Case,
    treatment: str,
    iterations: int = DEFAULT_ITERATIONS,
    intervention_iteration: int = DEFAULT_INTERVENTION_ITERATION,
) -> Dict[str, Any]:
    if treatment not in TREATMENTS:
        raise ValueError(f"treatment must be one of {TREATMENTS}")
    if intervention_iteration < 1 or intervention_iteration > iterations:
        raise ValueError("intervention iteration must fall inside the iteration budget")
    branches = _make_branches(case, treatment, iterations, intervention_iteration)
    document: Dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "research_question": "RQ1",
        "experiment_id": "RQ1-STATE-002",
        "case_id": case.case_id,
        "case_description": case.description,
        "treatment": treatment,
        "iterations": iterations,
        "intervention_iteration": intervention_iteration,
        "llr_sign_convention": "L_i = ln(P(b_i=1|y_i)/P(b_i=0|y_i))",
        "schedule": "flooding",
        "h": [list(row) for row in case.h],
        "channel_llr": list(case.llr),
        "channel_llr_hex": [value.hex() for value in case.llr],
        "edge_slots": list(case.edge_slots),
        "q_edge_labels": list(case.q_edge_labels),
        "u_edge_labels": list(case.u_edge_labels),
        "variants": list(VARIANTS),
        "structural_delta_witness": structural_delta_witness(),
        "branches": branches,
    }
    document["validation"] = validate_trace(document)
    return document


def _canonical_bytes(document: Any) -> bytes:
    return (
        json.dumps(
            document,
            sort_keys=True,
            indent=2,
            ensure_ascii=False,
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _write_json(path: Path, document: Any) -> None:
    path.write_bytes(_canonical_bytes(document))


def _source_hashes(base: Path) -> Dict[str, str]:
    names = (
        "rq1_state_002.py",
        "test_rq1_state_002.py",
        "experiment_card.md",
        "cyclic_confirmation_config.json",
    )
    return {name: _sha256_file(base / name) for name in names}


def _repository_root(start: Path) -> Path:
    for candidate in (start, *start.parents):
        if (candidate / ".git").exists():
            return candidate
    raise RuntimeError(f"no Git repository found above {start}")


def _git_text(repository: Path, arguments: Sequence[str]) -> str:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=repository,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout


def _process_argv() -> List[str]:
    proc_path = Path("/proc/self/cmdline")
    if proc_path.exists():
        fields = proc_path.read_bytes().rstrip(b"\0").split(b"\0")
        return [field.decode("utf-8", errors="surrogateescape") for field in fields]
    return list(sys.argv)


def load_run_configuration(path: Path) -> Dict[str, Any]:
    """Load and strictly validate a retained JSON run configuration."""
    path = path.resolve()
    document = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise ValueError("run configuration must be a JSON object")
    required = {
        "schema_version",
        "experiment_id",
        "case_ids",
        "treatments",
        "iterations",
        "intervention_iteration",
    }
    allowed = required | {"notes"}
    missing = sorted(required - set(document))
    unknown = sorted(set(document) - allowed)
    if missing or unknown:
        raise ValueError(
            f"invalid run configuration fields: missing={missing}, unknown={unknown}"
        )
    if document["schema_version"] != SCHEMA_VERSION:
        raise ValueError(
            "run configuration schema does not match the executable schema: "
            f"{document['schema_version']!r} != {SCHEMA_VERSION!r}"
        )
    experiment_id = str(document["experiment_id"])
    if not experiment_id:
        raise ValueError("experiment_id must be nonempty")
    case_ids = tuple(str(value) for value in document["case_ids"])
    treatments = tuple(str(value) for value in document["treatments"])
    if not case_ids or len(set(case_ids)) != len(case_ids):
        raise ValueError("case_ids must be nonempty and unique")
    if not treatments or len(set(treatments)) != len(treatments):
        raise ValueError("treatments must be nonempty and unique")
    unknown_cases = sorted(set(case_ids) - set(CASES))
    unknown_treatments = sorted(set(treatments) - set(TREATMENTS))
    if unknown_cases or unknown_treatments:
        raise ValueError(
            "unknown configured values: "
            f"cases={unknown_cases}, treatments={unknown_treatments}"
        )
    iterations = document["iterations"]
    intervention_iteration = document["intervention_iteration"]
    if isinstance(iterations, bool) or not isinstance(iterations, int) or iterations < 1:
        raise ValueError("iterations must be a positive integer")
    if (
        isinstance(intervention_iteration, bool)
        or not isinstance(intervention_iteration, int)
        or intervention_iteration < 1
        or intervention_iteration > iterations
    ):
        raise ValueError("intervention_iteration must fall inside the iteration budget")
    notes = document.get("notes")
    if notes is not None and not isinstance(notes, str):
        raise ValueError("notes must be a string when present")
    return {
        "schema_version": SCHEMA_VERSION,
        "experiment_id": experiment_id,
        "case_ids": case_ids,
        "treatments": treatments,
        "iterations": iterations,
        "intervention_iteration": intervention_iteration,
        "notes": notes,
    }


def make_run_config(
    case_ids: Sequence[str],
    treatments: Sequence[str],
    iterations: int,
    intervention_iteration: int,
    experiment_id: str = "RQ1-STATE-002",
    configuration_source: Path | None = None,
    notes: str | None = None,
) -> Dict[str, Any]:
    config: Dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "experiment_id": experiment_id,
        "case_ids": list(case_ids),
        "treatments": list(treatments),
        "variants": list(VARIANTS),
        "iterations": iterations,
        "intervention_iteration": intervention_iteration,
        "absolute_validation_tolerance": ABS_TOL,
    }
    if notes is not None:
        config["notes"] = notes
    if configuration_source is not None:
        source_dir = Path(__file__).resolve().parent
        resolved_source = configuration_source.resolve()
        if resolved_source.parent != source_dir:
            raise ValueError(
                "configuration files must be retained beside rq1_state_002.py"
            )
        config["configuration_source"] = {
            "file": resolved_source.name,
            "sha256": _sha256_file(resolved_source),
        }
    return config


def _configuration_source_validation(
    config: Mapping[str, Any], source_dir: Path
) -> Dict[str, Any]:
    metadata = config.get("configuration_source")
    if metadata is None:
        return {"required": False, "passed": True}
    source_path = source_dir / str(metadata["file"])
    loaded = load_run_configuration(source_path)
    effective = {
        "schema_version": config["schema_version"],
        "experiment_id": config["experiment_id"],
        "case_ids": tuple(config["case_ids"]),
        "treatments": tuple(config["treatments"]),
        "iterations": config["iterations"],
        "intervention_iteration": config["intervention_iteration"],
        "notes": config.get("notes"),
    }
    observed_hash = _sha256_file(source_path)
    expected = {
        key: loaded[key]
        for key in (
            "schema_version",
            "experiment_id",
            "case_ids",
            "treatments",
            "iterations",
            "intervention_iteration",
            "notes",
        )
    }
    fields_match = effective == expected
    hash_matches = observed_hash == metadata["sha256"]
    return {
        "required": True,
        "passed": fields_match and hash_matches,
        "file": source_path.name,
        "observed_sha256": observed_hash,
        "recorded_sha256": metadata["sha256"],
        "hash_matches": hash_matches,
        "effective_fields_match": fields_match,
    }


def run_to_directory(
    output: Path,
    case_ids: Sequence[str],
    treatments: Sequence[str],
    iterations: int,
    intervention_iteration: int,
    invocation_argv: Sequence[str] | None = None,
    experiment_id: str = "RQ1-STATE-002",
    configuration_source: Path | None = None,
    notes: str | None = None,
) -> Dict[str, Any]:
    output = output.resolve()
    if output.exists():
        raise FileExistsError(f"refusing to overwrite existing result directory: {output}")
    config = make_run_config(
        case_ids,
        treatments,
        iterations,
        intervention_iteration,
        experiment_id=experiment_id,
        configuration_source=configuration_source,
        notes=notes,
    )
    source_dir = Path(__file__).resolve().parent
    configuration_source_validation = _configuration_source_validation(
        config, source_dir
    )
    if not configuration_source_validation["passed"]:
        raise ValueError(
            "the retained configuration file does not match the effective run config"
        )
    if "configuration_source" in config:
        config["configuration_source"]["effective_fields_match"] = True

    output.mkdir(parents=True, exist_ok=False)
    _write_json(output / "run_config.json", config)

    trace_hashes: Dict[str, str] = {}
    validation_status: Dict[str, bool] = {}
    for case_id in case_ids:
        for treatment in treatments:
            trace = build_trace(
                CASES[case_id],
                treatment,
                iterations=iterations,
                intervention_iteration=intervention_iteration,
            )
            filename = f"{case_id}__{treatment}.json"
            payload = _canonical_bytes(trace)
            (output / filename).write_bytes(payload)
            trace_hashes[filename] = _sha256_bytes(payload)
            validation_status[filename] = bool(trace["validation"]["all_passed"])

    source_hashes = _source_hashes(source_dir)
    retained_file_hashes = {
        **{f"source/{name}": digest for name, digest in source_hashes.items()},
        "result/run_config.json": _sha256_file(output / "run_config.json"),
        **{f"result/{name}": digest for name, digest in trace_hashes.items()},
    }

    # Create both provenance files before taking the complete porcelain
    # snapshot.  Their later content changes do not change porcelain path
    # entries, so the retained snapshot describes the finished file set.
    (output / "manifest.json").write_text("", encoding="utf-8")
    (output / "MANIFEST.sha256").write_text("", encoding="utf-8")
    repository = _repository_root(source_dir)
    git_head = _git_text(repository, ("rev-parse", "HEAD")).strip()
    status_arguments = ("status", "--porcelain=v1", "--untracked-files=all")
    git_status = _git_text(repository, status_arguments)
    command_argv = list(invocation_argv or ("programmatic:run_to_directory",))
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "experiment_id": config["experiment_id"],
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "output_directory": str(output),
        "python": sys.version,
        "platform": platform.platform(),
        "source_hashes": source_hashes,
        "run_config_sha256": _sha256_file(output / "run_config.json"),
        "configuration_source_validation": configuration_source_validation,
        "trace_sha256": trace_hashes,
        "retained_scientific_and_config_file_sha256": retained_file_hashes,
        "trace_validation_passed": validation_status,
        "all_trace_validations_passed": all(validation_status.values()),
        "overwrite_policy": "result directory must not exist",
        "exact_command": shlex.join(command_argv),
        "exact_command_argv": command_argv,
        "git_head": git_head,
        "git_status_command": "git status --porcelain=v1 --untracked-files=all",
        "git_status_porcelain_v1": git_status,
        "git_status_porcelain_v1_sha256": _sha256_bytes(git_status.encode("utf-8")),
        "scientific_trace_hash_scope": (
            "canonical trace JSON only; runtime timestamp and manifest metadata excluded"
        ),
    }
    _write_json(output / "manifest.json", manifest)
    manifest_hash = _sha256_file(output / "manifest.json")
    (output / "MANIFEST.sha256").write_text(
        f"{manifest_hash}  manifest.json\n", encoding="utf-8"
    )
    return manifest


def replay_result_directory(output: Path) -> Dict[str, Any]:
    output = output.resolve()
    config = json.loads((output / "run_config.json").read_text(encoding="utf-8"))
    manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
    comparisons: Dict[str, Any] = {}
    recomputed_validation_status: Dict[str, bool] = {}
    recorded_validation_status = manifest.get("trace_validation_passed", {})

    config_hash_matches = (
        _sha256_file(output / "run_config.json") == manifest["run_config_sha256"]
    )
    for case_id in config["case_ids"]:
        for treatment in config["treatments"]:
            filename = f"{case_id}__{treatment}.json"
            recomputed = build_trace(
                CASES[case_id],
                treatment,
                iterations=int(config["iterations"]),
                intervention_iteration=int(config["intervention_iteration"]),
            )
            recomputed_hash = _sha256_bytes(_canonical_bytes(recomputed))
            retained_hash = _sha256_file(output / filename)
            hashes_match = (
                recomputed_hash == retained_hash == manifest["trace_sha256"][filename]
            )
            recomputed_validation_passed = bool(
                recomputed["validation"]["all_passed"]
            )
            recomputed_validation_status[filename] = recomputed_validation_passed
            recorded_validation_passed = recorded_validation_status.get(filename)
            validation_flag_matches = (
                isinstance(recorded_validation_passed, bool)
                and recorded_validation_passed == recomputed_validation_passed
            )
            comparisons[filename] = {
                "passed": (
                    hashes_match
                    and validation_flag_matches
                    and recomputed_validation_passed
                ),
                "hashes_match": hashes_match,
                "recomputed_validation_passed": recomputed_validation_passed,
                "recorded_validation_passed": recorded_validation_passed,
                "validation_flag_matches": validation_flag_matches,
                "recomputed_sha256": recomputed_hash,
                "retained_sha256": retained_hash,
                "manifest_sha256": manifest["trace_sha256"][filename],
            }

    source_dir = Path(__file__).resolve().parent
    configuration_source_validation = _configuration_source_validation(
        config, source_dir
    )
    configuration_source_manifest_matches = (
        manifest.get("configuration_source_validation")
        == configuration_source_validation
    )
    validation_keys_match = set(recorded_validation_status) == set(
        recomputed_validation_status
    )
    all_recomputed_trace_validations_passed = (
        bool(recomputed_validation_status)
        and all(recomputed_validation_status.values())
    )
    all_recorded_trace_validations_passed = (
        bool(recorded_validation_status)
        and all(value is True for value in recorded_validation_status.values())
    )
    manifest_validation_aggregate_matches_flags = (
        isinstance(manifest.get("all_trace_validations_passed"), bool)
        and manifest["all_trace_validations_passed"]
        == all_recorded_trace_validations_passed
    )
    current_source_hashes = _source_hashes(source_dir)
    source_hashes_match = current_source_hashes == manifest["source_hashes"]
    retained_hash_comparisons: Dict[str, Any] = {}
    for retained_name, expected_hash in manifest[
        "retained_scientific_and_config_file_sha256"
    ].items():
        category, relative_name = retained_name.split("/", 1)
        retained_path = (
            source_dir / relative_name if category == "source" else output / relative_name
        )
        observed_hash = _sha256_file(retained_path)
        retained_hash_comparisons[retained_name] = {
            "passed": observed_hash == expected_hash,
            "observed_sha256": observed_hash,
            "manifest_sha256": expected_hash,
        }

    repository = _repository_root(source_dir)
    current_git_head = _git_text(repository, ("rev-parse", "HEAD")).strip()
    status_arguments = ("status", "--porcelain=v1", "--untracked-files=all")
    current_git_status = _git_text(repository, status_arguments)
    recorded_status_hash_matches_text = (
        _sha256_bytes(manifest["git_status_porcelain_v1"].encode("utf-8"))
        == manifest["git_status_porcelain_v1_sha256"]
    )
    command_record_is_consistent = (
        manifest["exact_command"] == shlex.join(manifest["exact_command_argv"])
    )
    manifest_line = (output / "MANIFEST.sha256").read_text(encoding="utf-8").split()[0]
    manifest_hash_matches = manifest_line == _sha256_file(output / "manifest.json")
    passed = (
        config_hash_matches
        and configuration_source_validation["passed"]
        and configuration_source_manifest_matches
        and validation_keys_match
        and all_recomputed_trace_validations_passed
        and all_recorded_trace_validations_passed
        and manifest_validation_aggregate_matches_flags
        and manifest["all_trace_validations_passed"] is True
        and source_hashes_match
        and manifest_hash_matches
        and recorded_status_hash_matches_text
        and command_record_is_consistent
        and len(manifest["git_head"]) == 40
        and all(item["passed"] for item in retained_hash_comparisons.values())
        and all(item["passed"] for item in comparisons.values())
    )
    return {
        "passed": passed,
        "config_hash_matches": config_hash_matches,
        "configuration_source_validation": configuration_source_validation,
        "configuration_source_manifest_matches": configuration_source_manifest_matches,
        "trace_validation_keys_match": validation_keys_match,
        "all_recomputed_trace_validations_passed": (
            all_recomputed_trace_validations_passed
        ),
        "all_recorded_trace_validations_passed": (
            all_recorded_trace_validations_passed
        ),
        "manifest_validation_aggregate_matches_flags": (
            manifest_validation_aggregate_matches_flags
        ),
        "source_hashes_match": source_hashes_match,
        "current_source_hashes": current_source_hashes,
        "manifest_hash_matches": manifest_hash_matches,
        "recorded_git_status_hash_matches_text": recorded_status_hash_matches_text,
        "current_git_status_matches_recorded_snapshot": (
            current_git_status == manifest["git_status_porcelain_v1"]
        ),
        "current_git_head": current_git_head,
        "current_git_head_matches_recorded": current_git_head == manifest["git_head"],
        "exact_command_record_is_consistent": command_record_is_consistent,
        "retained_file_comparisons": retained_hash_comparisons,
        "trace_comparisons": comparisons,
    }


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="create a non-overwriting result directory")
    run_parser.add_argument("--output", type=Path, required=True)
    run_parser.add_argument(
        "--config",
        type=Path,
        help="strict retained JSON configuration; cannot be combined with scientific overrides",
    )
    run_parser.add_argument(
        "--cases", nargs="+", choices=tuple(CASES), default=None
    )
    run_parser.add_argument("--treatments", nargs="+", choices=TREATMENTS, default=None)
    run_parser.add_argument("--iterations", type=int, default=None)
    run_parser.add_argument(
        "--intervention-iteration", type=int, default=None
    )

    replay_parser = subparsers.add_parser(
        "replay", help="recompute traces and compare them with a retained result"
    )
    replay_parser.add_argument("--result-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command == "run" and args.config is not None:
        overrides = (
            args.cases,
            args.treatments,
            args.iterations,
            args.intervention_iteration,
        )
        if any(value is not None for value in overrides):
            parser.error(
                "--config cannot be combined with --cases, --treatments, "
                "--iterations, or --intervention-iteration"
            )
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    if args.command == "run":
        if args.config is not None:
            configured = load_run_configuration(args.config)
            case_ids = configured["case_ids"]
            treatments = configured["treatments"]
            iterations = configured["iterations"]
            intervention_iteration = configured["intervention_iteration"]
            experiment_id = configured["experiment_id"]
            configuration_source = args.config
            notes = configured["notes"]
        else:
            case_ids = args.cases if args.cases is not None else PRIMARY_CASE_IDS
            treatments = (
                args.treatments if args.treatments is not None else TREATMENTS
            )
            iterations = (
                args.iterations
                if args.iterations is not None
                else DEFAULT_ITERATIONS
            )
            intervention_iteration = (
                args.intervention_iteration
                if args.intervention_iteration is not None
                else DEFAULT_INTERVENTION_ITERATION
            )
            experiment_id = "RQ1-STATE-002"
            configuration_source = None
            notes = None
        manifest = run_to_directory(
            args.output,
            case_ids,
            treatments,
            iterations,
            intervention_iteration,
            invocation_argv=_process_argv(),
            experiment_id=experiment_id,
            configuration_source=configuration_source,
            notes=notes,
        )
        print(json.dumps(manifest, indent=2, sort_keys=True))
        return 0 if manifest["all_trace_validations_passed"] else 1
    replay = replay_result_directory(args.result_dir)
    print(json.dumps(replay, indent=2, sort_keys=True))
    return 0 if replay["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
