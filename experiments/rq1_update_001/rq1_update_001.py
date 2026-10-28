#!/usr/bin/env python3
"""Deterministic 2 x 2 control for RQ1-UPDATE-001.

This executable compares a direct BP-style map with a true gradient step on
the declared objective function for that map.  It is not the repository's
native projected-GD decoder.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable, Sequence


HERE = Path(__file__).resolve().parent
CONFIG_PATH = HERE / "config.json"
SOURCE_PATHS = (
    HERE / "rq1_update_001.py",
    HERE / "config.json",
    HERE / "experiment_card.md",
    HERE / "test_rq1_update_001.py",
)

STATE_MAPS = ("full", "qbar_tied")
OPERATORS = ("direct", "true_residual_gradient")
EDGE_ORDER = (
    (0, 0, "b0-c0"),
    (1, 0, "b1-c0"),
    (1, 1, "b1-c1"),
    (2, 1, "b2-c1"),
)


Vector = list[float]
Matrix = list[list[float]]


def load_config(path: Path = CONFIG_PATH) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def vector_add(left: Sequence[float], right: Sequence[float]) -> Vector:
    return [a + b for a, b in zip(left, right)]


def vector_sub(left: Sequence[float], right: Sequence[float]) -> Vector:
    return [a - b for a, b in zip(left, right)]


def vector_scale(scale: float, values: Sequence[float]) -> Vector:
    return [scale * value for value in values]


def dot(left: Sequence[float], right: Sequence[float]) -> float:
    return sum(a * b for a, b in zip(left, right))


def norm2(values: Sequence[float]) -> float:
    return math.sqrt(dot(values, values))


def max_abs(values: Iterable[float]) -> float:
    materialized = [abs(value) for value in values]
    return max(materialized, default=0.0)


def identity(size: int) -> Matrix:
    return [
        [1.0 if row == column else 0.0 for column in range(size)]
        for row in range(size)
    ]


def matrix_sub(left: Matrix, right: Matrix) -> Matrix:
    return [
        [left[row][column] - right[row][column] for column in range(len(left[0]))]
        for row in range(len(left))
    ]


def transpose(matrix: Matrix) -> Matrix:
    return [list(column) for column in zip(*matrix)]


def matvec(matrix: Matrix, vector: Sequence[float]) -> Vector:
    return [dot(row, vector) for row in matrix]


def matmul(left: Matrix, right: Matrix) -> Matrix:
    right_t = transpose(right)
    return [[dot(row, column) for column in right_t] for row in left]


def matrix_max_abs_difference(left: Matrix, right: Matrix) -> float:
    return max_abs(
        left[row][column] - right[row][column]
        for row in range(len(left))
        for column in range(len(left[0]))
    )


def solve_linear(matrix: Matrix, vector: Sequence[float]) -> Vector:
    """Solve a small dense system with partial-pivoted elimination."""

    size = len(vector)
    augmented = [list(matrix[row]) + [float(vector[row])] for row in range(size)]
    for column in range(size):
        pivot = max(range(column, size), key=lambda row: abs(augmented[row][column]))
        if abs(augmented[pivot][column]) < 1e-15:
            raise ValueError("singular fixed-point system")
        augmented[column], augmented[pivot] = augmented[pivot], augmented[column]
        pivot_value = augmented[column][column]
        augmented[column] = [value / pivot_value for value in augmented[column]]
        for row in range(size):
            if row == column:
                continue
            factor = augmented[row][column]
            augmented[row] = [
                augmented[row][index] - factor * augmented[column][index]
                for index in range(size + 1)
            ]
    return [augmented[row][-1] for row in range(size)]


def symmetric_eigenvalues_jacobi(
    matrix: Matrix, *, tolerance: float = 1e-15, max_sweeps: int = 100
) -> Vector:
    """Compute eigenvalues independently of the closed-form spectral claim."""

    work = [row[:] for row in matrix]
    size = len(work)
    for _ in range(max_sweeps):
        p, q = max(
            ((row, column) for row in range(size) for column in range(row + 1, size)),
            key=lambda pair: abs(work[pair[0]][pair[1]]),
        )
        off_diagonal = work[p][q]
        if abs(off_diagonal) <= tolerance:
            break
        app = work[p][p]
        aqq = work[q][q]
        tau = (aqq - app) / (2.0 * off_diagonal)
        sign = 1.0 if tau >= 0.0 else -1.0
        tangent = sign / (abs(tau) + math.sqrt(1.0 + tau * tau))
        cosine = 1.0 / math.sqrt(1.0 + tangent * tangent)
        sine = tangent * cosine
        for index in range(size):
            if index in (p, q):
                continue
            aip = work[index][p]
            aiq = work[index][q]
            work[index][p] = cosine * aip - sine * aiq
            work[p][index] = work[index][p]
            work[index][q] = sine * aip + cosine * aiq
            work[q][index] = work[index][q]
        work[p][p] = (
            cosine * cosine * app
            - 2.0 * sine * cosine * off_diagonal
            + sine * sine * aqq
        )
        work[q][q] = (
            sine * sine * app
            + 2.0 * sine * cosine * off_diagonal
            + cosine * cosine * aqq
        )
        work[p][q] = 0.0
        work[q][p] = 0.0
    else:
        raise RuntimeError("Jacobi eigensolver did not converge")
    return sorted(work[index][index] for index in range(size))


def llrs_from_config(config: dict[str, Any]) -> Vector:
    return [float(value) for value in config["channel_llrs"]["values"]]


def map_evaluation(state_map: str, state: Sequence[float], llrs: Sequence[float]) -> dict[str, Any]:
    """Evaluate one flooding variable/check calculation on the frozen state."""

    if state_map not in STATE_MAPS:
        raise ValueError(f"unknown state map: {state_map}")
    if len(state) != len(EDGE_ORDER):
        raise ValueError("state must have one value per edge")

    full_variable_to_check: Vector = []
    for edge_index, (bit, check, _) in enumerate(EDGE_ORDER):
        other_incoming = sum(
            state[other_index]
            for other_index, (other_bit, other_check, _) in enumerate(EDGE_ORDER)
            if other_bit == bit and other_check != check
        )
        full_variable_to_check.append(llrs[bit] + other_incoming)

    qbar: Vector = []
    for bit in range(len(llrs)):
        outgoing = [
            full_variable_to_check[index]
            for index, (edge_bit, _, _) in enumerate(EDGE_ORDER)
            if edge_bit == bit
        ]
        qbar.append(sum(outgoing) / len(outgoing))

    if state_map == "full":
        variable_to_check_used = full_variable_to_check[:]
    else:
        variable_to_check_used = [qbar[bit] for bit, _, _ in EDGE_ORDER]

    output: Vector = []
    for edge_index, (_, check, _) in enumerate(EDGE_ORDER):
        other_edges = [
            other_index
            for other_index, (_, other_check, _) in enumerate(EDGE_ORDER)
            if other_check == check and other_index != edge_index
        ]
        if len(other_edges) != 1:
            raise ValueError("this frozen bench requires degree-two checks")
        output.append(variable_to_check_used[other_edges[0]])

    return {
        "state_map": state_map,
        "input_state": list(state),
        "variable_to_check_full": full_variable_to_check,
        "qbar_by_bit": qbar,
        "variable_to_check_used": variable_to_check_used,
        "output_state": output,
    }


def affine_map(state_map: str, llrs: Sequence[float]) -> tuple[Matrix, Vector]:
    """Return the analytic Jacobian and affine offset for the frozen graph."""

    l0, l1, l2 = llrs
    if state_map == "full":
        jacobian = [
            [0.0, 0.0, 1.0, 0.0],
            [0.0, 0.0, 0.0, 0.0],
            [0.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
        ]
    elif state_map == "qbar_tied":
        jacobian = [
            [0.0, 0.5, 0.5, 0.0],
            [0.0, 0.0, 0.0, 0.0],
            [0.0, 0.0, 0.0, 0.0],
            [0.0, 0.5, 0.5, 0.0],
        ]
    else:
        raise ValueError(f"unknown state map: {state_map}")
    offset = [l1, l0, l2, l1]
    return jacobian, offset


def objective(state_map: str, state: Sequence[float], llrs: Sequence[float]) -> float:
    mapped = map_evaluation(state_map, state, llrs)["output_state"]
    residual = vector_sub(state, mapped)
    return 0.5 * dot(residual, residual)


def residual_gradient(state_map: str, state: Sequence[float], llrs: Sequence[float]) -> Vector:
    jacobian, _ = affine_map(state_map, llrs)
    residual = vector_sub(state, map_evaluation(state_map, state, llrs)["output_state"])
    residual_jacobian = matrix_sub(identity(len(state)), jacobian)
    return matvec(transpose(residual_jacobian), residual)


def finite_difference_jacobian(
    state_map: str, state: Sequence[float], llrs: Sequence[float], step: float
) -> Matrix:
    columns: list[Vector] = []
    for coordinate in range(len(state)):
        plus = list(state)
        minus = list(state)
        plus[coordinate] += step
        minus[coordinate] -= step
        output_plus = map_evaluation(state_map, plus, llrs)["output_state"]
        output_minus = map_evaluation(state_map, minus, llrs)["output_state"]
        columns.append(
            [(right - left) / (2.0 * step) for right, left in zip(output_plus, output_minus)]
        )
    return transpose(columns)


def finite_difference_gradient(
    state_map: str, state: Sequence[float], llrs: Sequence[float], step: float
) -> Vector:
    result: Vector = []
    for coordinate in range(len(state)):
        plus = list(state)
        minus = list(state)
        plus[coordinate] += step
        minus[coordinate] -= step
        result.append(
            (objective(state_map, plus, llrs) - objective(state_map, minus, llrs))
            / (2.0 * step)
        )
    return result


def a_posteriori_llrs(state: Sequence[float], llrs: Sequence[float]) -> Vector:
    return [
        llrs[bit]
        + sum(
            state[index]
            for index, (edge_bit, _, _) in enumerate(EDGE_ORDER)
            if edge_bit == bit
        )
        for bit in range(len(llrs))
    ]


def hard_decision(a_posteriori: Sequence[float], *, positive_llr_bit: int = 1) -> list[int]:
    if positive_llr_bit not in (0, 1):
        raise ValueError("positive_llr_bit must be 0 or 1")
    negative_llr_bit = 1 - positive_llr_bit
    return [positive_llr_bit if value >= 0.0 else negative_llr_bit for value in a_posteriori]


def syndrome(bits: Sequence[int], parity_check_matrix: Sequence[Sequence[int]]) -> list[int]:
    return [sum(entry * bit for entry, bit in zip(row, bits)) % 2 for row in parity_check_matrix]


def decision_diagnostics(
    state: Sequence[float],
    llrs: Sequence[float],
    parity_check_matrix: Sequence[Sequence[int]],
    *,
    positive_llr_bit: int = 1,
) -> dict[str, Any]:
    posterior = a_posteriori_llrs(state, llrs)
    estimate = hard_decision(posterior, positive_llr_bit=positive_llr_bit)
    check_syndrome = syndrome(estimate, parity_check_matrix)
    return {
        "a_posteriori_llrs": posterior,
        "hard_decision_estimate": estimate,
        "syndrome": check_syndrome,
        "valid_codeword": all(value == 0 for value in check_syndrome),
    }


def operation_categories(state_map: str, operator: str) -> dict[str, Any]:
    state_counts = {
        "variable_node_additions": 2,
        "recipient_average_additions": 0 if state_map == "full" else 1,
        "recipient_average_scalings": 0 if state_map == "full" else 1,
        "degree_two_check_transfers": 4,
        "nonlinear_check_functions": 0,
    }
    if operator == "direct":
        operator_counts = {
            "residual_subtractions": 0,
            "jacobian_transpose_nonzero_products": 0,
            "jacobian_transpose_accumulations": 0,
            "step_size_multiplications": 0,
            "state_update_subtractions": 0,
            "state_assignments": 4,
        }
    else:
        nonzero_jacobian_entries = 2 if state_map == "full" else 4
        operator_counts = {
            "residual_subtractions": 4,
            "jacobian_transpose_nonzero_products": nonzero_jacobian_entries,
            "jacobian_transpose_accumulations": nonzero_jacobian_entries,
            "step_size_multiplications": 4,
            "state_update_subtractions": 4,
            "state_assignments": 0,
        }
    return {
        "algorithm_core": {**state_counts, **operator_counts},
        "excluded_diagnostics": [
            "finite-difference evaluations",
            "fixed-point solve",
            "objective-after evaluation",
            "hard decision and syndrome",
            "hashing and serialization",
        ],
        "weighted_scalar_total_reported": False,
    }


def storage_counts(state_map: str, operator: str) -> dict[str, Any]:
    return {
        "persistent_dynamic_values_between_updates": 4,
        "persistent_state_description": "check-to-variable state u",
        "fixed_channel_llrs_not_counted_as_dynamic_state": 3,
        "temporary_variable_to_check_values": 4,
        "temporary_qbar_values": 0 if state_map == "full" else 3,
        "temporary_residual_values": 0 if operator == "direct" else 4,
        "temporary_gradient_values": 0 if operator == "direct" else 4,
    }


def evaluate_cell(
    state_map: str,
    operator: str,
    before: Sequence[float],
    llrs: Sequence[float],
    parity_check_matrix: Sequence[Sequence[int]],
    alpha: float,
) -> dict[str, Any]:
    jacobian, offset = affine_map(state_map, llrs)
    map_before = map_evaluation(state_map, before, llrs)
    residual_before = vector_sub(before, map_before["output_state"])
    gradient_before = residual_gradient(state_map, before, llrs)
    objective_before = 0.5 * dot(residual_before, residual_before)

    if operator == "direct":
        after = map_before["output_state"][:]
    elif operator == "true_residual_gradient":
        after = vector_sub(before, vector_scale(alpha, gradient_before))
    else:
        raise ValueError(f"unknown operator: {operator}")

    map_after = map_evaluation(state_map, after, llrs)
    residual_after = vector_sub(after, map_after["output_state"])
    gradient_after = residual_gradient(state_map, after, llrs)
    objective_after = 0.5 * dot(residual_after, residual_after)

    return {
        "cell_id": f"{state_map}__{operator}",
        "state_map": state_map,
        "operator": operator,
        "update_budget": 1,
        "early_stopping": False,
        "before_state": list(before),
        "map_evaluation_before": map_before,
        "jacobian": jacobian,
        "affine_offset": offset,
        "residual_before": residual_before,
        "residual_norm_before": norm2(residual_before),
        "gradient_before": gradient_before,
        "objective_before": objective_before,
        "alpha": None if operator == "direct" else alpha,
        "update_displacement": vector_sub(after, before),
        "after_state": after,
        "map_evaluation_after": map_after,
        "residual_after": residual_after,
        "residual_norm_after": norm2(residual_after),
        "gradient_after": gradient_after,
        "objective_after": objective_after,
        "decision_before": decision_diagnostics(before, llrs, parity_check_matrix),
        "decision_after": decision_diagnostics(after, llrs, parity_check_matrix),
        "operation_categories": operation_categories(state_map, operator),
        "storage_counts": storage_counts(state_map, operator),
    }


def sign_transform_cell_diagnostics(
    cell: dict[str, Any],
    llrs: Sequence[float],
    parity_check_matrix: Sequence[Sequence[int]],
    alpha: float,
    tolerance: float,
) -> dict[str, Any]:
    """Check the equivalent bit-0-positive representation for one cell."""

    state_map = cell["state_map"]
    operator = cell["operator"]
    transformed_llrs = vector_scale(-1.0, llrs)
    transformed_before = vector_scale(-1.0, cell["before_state"])
    transformed_map_before = map_evaluation(state_map, transformed_before, transformed_llrs)
    transformed_residual = vector_sub(
        transformed_before, transformed_map_before["output_state"]
    )
    transformed_gradient = residual_gradient(state_map, transformed_before, transformed_llrs)
    if operator == "direct":
        transformed_after = transformed_map_before["output_state"][:]
    else:
        transformed_after = vector_sub(
            transformed_before, vector_scale(alpha, transformed_gradient)
        )
    transformed_posterior = a_posteriori_llrs(transformed_after, transformed_llrs)
    transformed_decision = decision_diagnostics(
        transformed_after,
        transformed_llrs,
        parity_check_matrix,
        positive_llr_bit=0,
    )

    original_map = cell["map_evaluation_before"]
    original_posterior = cell["decision_after"]["a_posteriori_llrs"]
    soft_negation_errors = {
        "channel_llr": max_abs(vector_add(transformed_llrs, llrs)),
        "before_state_u": max_abs(vector_add(transformed_before, cell["before_state"])),
        "variable_to_check_q_full": max_abs(
            vector_add(
                transformed_map_before["variable_to_check_full"],
                original_map["variable_to_check_full"],
            )
        ),
        "qbar": max_abs(
            vector_add(transformed_map_before["qbar_by_bit"], original_map["qbar_by_bit"])
        ),
        "variable_to_check_q_used": max_abs(
            vector_add(
                transformed_map_before["variable_to_check_used"],
                original_map["variable_to_check_used"],
            )
        ),
        "map_output_u": max_abs(
            vector_add(transformed_map_before["output_state"], original_map["output_state"])
        ),
        "residual": max_abs(vector_add(transformed_residual, cell["residual_before"])),
        "gradient": max_abs(vector_add(transformed_gradient, cell["gradient_before"])),
        "after_state_u": max_abs(vector_add(transformed_after, cell["after_state"])),
        "a_posteriori_x": max_abs(vector_add(transformed_posterior, original_posterior)),
    }
    maximum_soft_error = max(soft_negation_errors.values())
    transformed_objective = 0.5 * dot(transformed_residual, transformed_residual)
    objective_invariance_error = abs(transformed_objective - cell["objective_before"])
    hard_preserved = (
        transformed_decision["hard_decision_estimate"]
        == cell["decision_after"]["hard_decision_estimate"]
    )
    syndrome_preserved = transformed_decision["syndrome"] == cell["decision_after"]["syndrome"]
    passed = (
        maximum_soft_error <= tolerance
        and objective_invariance_error <= tolerance
        and hard_preserved
        and syndrome_preserved
    )
    return {
        "cell_id": cell["cell_id"],
        "source_convention": "L=ln(P(1|y)/P(0|y)); positive favors bit 1",
        "transformed_convention": "ell=ln(P(0|y)/P(1|y)); positive favors bit 0",
        "transform": "ell=-L, q0=-q1, u0=-u1, x0=-x1",
        "soft_negation_errors": soft_negation_errors,
        "maximum_soft_negation_error": maximum_soft_error,
        "objective_invariance_error": objective_invariance_error,
        "transformed_hard_decision_estimate": transformed_decision[
            "hard_decision_estimate"
        ],
        "transformed_syndrome": transformed_decision["syndrome"],
        "hard_decision_preserved": hard_preserved,
        "syndrome_preserved": syndrome_preserved,
        "tolerance": tolerance,
        "passed": passed,
    }


def first_difference(
    left: Sequence[float], right: Sequence[float], labels: Sequence[str], tolerance: float
) -> dict[str, Any]:
    for index, (left_value, right_value) in enumerate(zip(left, right)):
        difference = right_value - left_value
        if abs(difference) > tolerance:
            return {
                "found": True,
                "coordinate": index,
                "label": labels[index],
                "left": left_value,
                "right": right_value,
                "right_minus_left": difference,
            }
    return {"found": False, "coordinate": None, "label": None}


def factorial_contrasts(cells: dict[str, dict[str, Any]]) -> dict[str, Any]:
    full_direct = cells["full__direct"]["after_state"]
    tied_direct = cells["qbar_tied__direct"]["after_state"]
    full_gradient = cells["full__true_residual_gradient"]["after_state"]
    tied_gradient = cells["qbar_tied__true_residual_gradient"]["after_state"]

    state_effect = vector_scale(
        0.5,
        vector_add(
            vector_sub(tied_direct, full_direct),
            vector_sub(tied_gradient, full_gradient),
        ),
    )
    update_effect = vector_scale(
        0.5,
        vector_add(
            vector_sub(full_gradient, full_direct),
            vector_sub(tied_gradient, tied_direct),
        ),
    )
    interaction = vector_sub(
        vector_sub(tied_gradient, tied_direct),
        vector_sub(full_gradient, full_direct),
    )
    return {
        "orientation": {
            "state": "qbar_tied minus full, averaged over update operators",
            "update": "true_residual_gradient minus direct, averaged over state maps",
            "interaction": "(tied gradient - tied direct) - (full gradient - full direct)",
        },
        "state_effect_vector": state_effect,
        "state_effect_l2_norm": norm2(state_effect),
        "update_effect_vector": update_effect,
        "update_effect_l2_norm": norm2(update_effect),
        "interaction_vector": interaction,
        "interaction_l2_norm": norm2(interaction),
    }


def build_scientific_payload(config: dict[str, Any]) -> dict[str, Any]:
    llrs = llrs_from_config(config)
    parity_check_matrix = config["graph"]["parity_check_matrix"]
    zero_state = [0.0] * len(EDGE_ORDER)
    start = map_evaluation("full", zero_state, llrs)["output_state"]
    alpha = float(config["gradient_step"]["alpha"])

    state_map_properties: dict[str, dict[str, Any]] = {}
    for state_map in STATE_MAPS:
        jacobian, offset = affine_map(state_map, llrs)
        residual_jacobian = matrix_sub(identity(len(EDGE_ORDER)), jacobian)
        hessian = matmul(transpose(residual_jacobian), residual_jacobian)
        spectrum = symmetric_eigenvalues_jacobi(hessian)
        fixed_point = solve_linear(residual_jacobian, offset)
        state_map_properties[state_map] = {
            "jacobian": jacobian,
            "affine_offset": offset,
            "residual_jacobian": residual_jacobian,
            "residual_hessian": hessian,
            "residual_hessian_eigenvalues": spectrum,
            "maximum_eigenvalue": max(spectrum),
            "fixed_point": fixed_point,
            "fixed_point_residual": vector_sub(
                fixed_point, map_evaluation(state_map, fixed_point, llrs)["output_state"]
            ),
            "objective_at_fixed_point": objective(state_map, fixed_point, llrs),
        }

    cells: dict[str, dict[str, Any]] = {}
    for state_map in STATE_MAPS:
        for operator in OPERATORS:
            cell = evaluate_cell(
                state_map,
                operator,
                start,
                llrs,
                parity_check_matrix,
                alpha,
            )
            cells[cell["cell_id"]] = cell

    sign_tolerance = float(config["numeric_tolerances"]["sign_transform_max_abs"])
    sign_transform_cells = {
        cell_id: sign_transform_cell_diagnostics(
            cell,
            llrs,
            parity_check_matrix,
            alpha,
            sign_tolerance,
        )
        for cell_id, cell in cells.items()
    }
    sign_transform_invariance = {
        "source_llr_definition": config["channel_llrs"]["definition"],
        "source_positive_llr_bit": config["channel_llrs"]["positive_llr_bit"],
        "transformed_positive_llr_bit": config["sign_transform_control"][
            "positive_llr_bit"
        ],
        "transform": config["sign_transform_control"]["transform"],
        "tolerance": sign_tolerance,
        "all_cells_passed": all(
            diagnostics["passed"] for diagnostics in sign_transform_cells.values()
        ),
        "cells": sign_transform_cells,
    }

    labels = [edge[2] for edge in EDGE_ORDER]
    tolerance = float(config["numeric_tolerances"]["affine_map_max_abs"])
    comparisons = [
        ("state_within_direct", "full__direct", "qbar_tied__direct"),
        (
            "state_within_gradient",
            "full__true_residual_gradient",
            "qbar_tied__true_residual_gradient",
        ),
        ("update_within_full", "full__direct", "full__true_residual_gradient"),
        (
            "update_within_tied",
            "qbar_tied__direct",
            "qbar_tied__true_residual_gradient",
        ),
    ]
    first_divergences: dict[str, Any] = {}
    for comparison, left_id, right_id in comparisons:
        left_cell = cells[left_id]
        right_cell = cells[right_id]
        first_divergences[comparison] = {
            "left_cell": left_id,
            "right_cell": right_id,
            "pre_update_states_equal": left_cell["before_state"] == right_cell["before_state"],
            "first_divergent_update": 1,
            "state": first_difference(
                left_cell["after_state"], right_cell["after_state"], labels, tolerance
            ),
            "a_posteriori_llr": first_difference(
                left_cell["decision_after"]["a_posteriori_llrs"],
                right_cell["decision_after"]["a_posteriori_llrs"],
                ["b0", "b1", "b2"],
                tolerance,
            ),
        }

    contrasts = factorial_contrasts(cells)
    effect_tolerance = float(config["numeric_tolerances"]["affine_map_max_abs"])
    classification = {
        "state_effect_detected": contrasts["state_effect_l2_norm"] > effect_tolerance,
        "update_effect_detected": contrasts["update_effect_l2_norm"] > effect_tolerance,
        "interaction_detected": contrasts["interaction_l2_norm"] > effect_tolerance,
        "scope": "one-update trajectory effects on the declared three-bit anchor",
        "native_projected_gd_result": False,
        "decoding_performance_result": False,
    }

    return {
        "experiment_id": config["experiment_id"],
        "research_question": config["research_question"],
        "classification": config["classification"],
        "scope_note": (
            "BP-residual gradient control only; not native projected GD and not "
            "a decoding-performance experiment"
        ),
        "parity_check_matrix": parity_check_matrix,
        "edge_order": [
            {"coordinate": index, "bit": bit, "check": check, "label": label}
            for index, (bit, check, label) in enumerate(EDGE_ORDER)
        ],
        "channel_llrs": llrs,
        "llr_convention": config["channel_llrs"]["convention"],
        "llr_definition": config["channel_llrs"]["definition"],
        "start_state_definition": config["initialization"]["expression"],
        "start_state": start,
        "start_decision": decision_diagnostics(start, llrs, parity_check_matrix),
        "alpha": alpha,
        "alpha_expression": config["gradient_step"]["alpha_expression"],
        "update_budget": config["budget"],
        "state_map_properties": state_map_properties,
        "cells": cells,
        "sign_transform_invariance": sign_transform_invariance,
        "factorial_contrasts": contrasts,
        "first_divergences": first_divergences,
        "effect_classification": classification,
    }


def validation_check(
    check_id: str,
    description: str,
    observed: Any,
    threshold: Any,
    passed: bool,
) -> dict[str, Any]:
    return {
        "check_id": check_id,
        "description": description,
        "observed": observed,
        "threshold_or_expected": threshold,
        "passed": bool(passed),
    }


def validate_payload(config: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    llrs = payload["channel_llrs"]
    start = payload["start_state"]
    finite_step = float(config["finite_difference"]["central_step"])
    affine_tolerance = float(config["numeric_tolerances"]["affine_map_max_abs"])
    fixed_tolerance = float(config["numeric_tolerances"]["fixed_point_residual_max_abs"])
    spectral_tolerance = float(config["numeric_tolerances"]["spectral_max_abs"])
    jacobian_tolerance = float(config["finite_difference"]["jacobian_max_abs_tolerance"])
    gradient_tolerance = float(config["finite_difference"]["gradient_max_abs_tolerance"])
    expected_llrs = [-math.log(9.0), math.log(1.5), math.log(2.0)]
    expected_alpha = (3.0 - math.sqrt(5.0)) / 2.0
    expected_maximum_eigenvalue = (3.0 + math.sqrt(5.0)) / 2.0
    checks: list[dict[str, Any]] = []

    llr_error = max_abs(vector_sub(llrs, expected_llrs))
    checks.append(
        validation_check(
            "VAL-001",
            "configured LLRs and positive-bit convention reproduce the frozen definition",
            {
                "llr_max_abs_error": llr_error,
                "positive_llr_bit": config["channel_llrs"]["positive_llr_bit"],
            },
            {"llr_max_abs": affine_tolerance, "positive_llr_bit": 1},
            llr_error <= affine_tolerance
            and config["channel_llrs"]["positive_llr_bit"] == 1,
        )
    )

    recomputed_start = map_evaluation("full", [0.0] * len(EDGE_ORDER), llrs)["output_state"]
    start_error = max_abs(vector_sub(start, recomputed_start))
    checks.append(
        validation_check(
            "VAL-002",
            "u1 equals F_full(0)",
            start_error,
            affine_tolerance,
            start_error <= affine_tolerance,
        )
    )

    config_edges = [
        (entry["bit"], entry["check"], entry["label"])
        for entry in config["graph"]["edge_order"]
    ]
    checks.append(
        validation_check(
            "VAL-003",
            "configured edge order equals the frozen executable edge order",
            config_edges,
            list(EDGE_ORDER),
            tuple(config_edges) == EDGE_ORDER,
        )
    )

    for map_index, state_map in enumerate(STATE_MAPS, start=1):
        validation_base = 4 + 4 * (map_index - 1)
        properties = payload["state_map_properties"][state_map]
        jacobian = properties["jacobian"]
        offset = properties["affine_offset"]
        executable = map_evaluation(state_map, start, llrs)["output_state"]
        affine_output = vector_add(matvec(jacobian, start), offset)
        affine_error = max_abs(vector_sub(executable, affine_output))
        checks.append(
            validation_check(
                f"VAL-{validation_base:03d}",
                f"{state_map} executable map agrees with J*u+c",
                affine_error,
                affine_tolerance,
                affine_error <= affine_tolerance,
            )
        )

        numerical_jacobian = finite_difference_jacobian(state_map, start, llrs, finite_step)
        jacobian_error = matrix_max_abs_difference(jacobian, numerical_jacobian)
        checks.append(
            validation_check(
                f"VAL-{validation_base + 1:03d}",
                f"{state_map} analytic Jacobian agrees with central finite differences",
                jacobian_error,
                jacobian_tolerance,
                jacobian_error <= jacobian_tolerance,
            )
        )

        analytic_gradient = residual_gradient(state_map, start, llrs)
        numerical_gradient = finite_difference_gradient(state_map, start, llrs, finite_step)
        gradient_error = max_abs(vector_sub(analytic_gradient, numerical_gradient))
        checks.append(
            validation_check(
                f"VAL-{validation_base + 2:03d}",
                f"{state_map} analytic residual gradient agrees with central finite differences",
                gradient_error,
                gradient_tolerance,
                gradient_error <= gradient_tolerance,
            )
        )

        fixed_point_error = max_abs(properties["fixed_point_residual"])
        objective_at_fixed_point = properties["objective_at_fixed_point"]
        fixed_observed = max(fixed_point_error, math.sqrt(2.0 * objective_at_fixed_point))
        checks.append(
            validation_check(
                f"VAL-{validation_base + 3:03d}",
                f"{state_map} objective-function zero is a map fixed point",
                fixed_observed,
                fixed_tolerance,
                fixed_observed <= fixed_tolerance,
            )
        )

    spectral_errors = {
        state_map: abs(
            payload["state_map_properties"][state_map]["maximum_eigenvalue"]
            - expected_maximum_eigenvalue
        )
        for state_map in STATE_MAPS
    }
    shared_spectral_error = max(
        *spectral_errors.values(),
        abs(
            payload["state_map_properties"]["full"]["maximum_eigenvalue"]
            - payload["state_map_properties"]["qbar_tied"]["maximum_eigenvalue"]
        ),
    )
    checks.append(
        validation_check(
            "VAL-012",
            "both (I-J)^T(I-J) matrices have the frozen shared maximum eigenvalue",
            {"errors": spectral_errors, "shared_max_error": shared_spectral_error},
            spectral_tolerance,
            shared_spectral_error <= spectral_tolerance,
        )
    )

    alpha_error = max(
        abs(payload["alpha"] - expected_alpha),
        max(
            abs(payload["alpha"] * payload["state_map_properties"][state_map]["maximum_eigenvalue"] - 1.0)
            for state_map in STATE_MAPS
        ),
    )
    checks.append(
        validation_check(
            "VAL-013",
            "alpha is the reciprocal of each (I-J)^T(I-J) maximum eigenvalue",
            alpha_error,
            spectral_tolerance,
            alpha_error <= spectral_tolerance,
        )
    )

    decisions_recomputed = True
    for cell in payload["cells"].values():
        recomputed = decision_diagnostics(
            cell["after_state"], llrs, payload["parity_check_matrix"]
        )
        decisions_recomputed = decisions_recomputed and recomputed == cell["decision_after"]
    checks.append(
        validation_check(
            "VAL-014",
            "post-update hard decisions and syndromes recompute from retained states",
            decisions_recomputed,
            True,
            decisions_recomputed,
        )
    )

    sign_transform = payload["sign_transform_invariance"]
    sign_transform_maximum = max(
        max(cell["maximum_soft_negation_error"], cell["objective_invariance_error"])
        for cell in sign_transform["cells"].values()
    )
    sign_transform_tolerance = float(
        config["numeric_tolerances"]["sign_transform_max_abs"]
    )
    checks.append(
        validation_check(
            "VAL-015",
            "the complete LLR-convention sign transform preserves all four cells",
            {
                "maximum_numeric_error": sign_transform_maximum,
                "all_cells_passed": sign_transform["all_cells_passed"],
            },
            {
                "maximum_numeric_error": sign_transform_tolerance,
                "all_cells_passed": True,
            },
            sign_transform["all_cells_passed"]
            and sign_transform_maximum <= sign_transform_tolerance,
        )
    )

    second_payload = build_scientific_payload(config)
    first_digest = sha256_bytes(canonical_bytes(payload))
    second_digest = sha256_bytes(canonical_bytes(second_payload))
    checks.append(
        validation_check(
            "VAL-016",
            "pure scientific calculation replays deterministically",
            {"first": first_digest, "second": second_digest},
            "exact digest equality",
            first_digest == second_digest,
        )
    )

    direct_fixed_errors = {}
    for state_map in STATE_MAPS:
        direct_state = payload["cells"][f"{state_map}__direct"]["after_state"]
        fixed_point = payload["state_map_properties"][state_map]["fixed_point"]
        direct_fixed_errors[state_map] = max_abs(vector_sub(direct_state, fixed_point))
    direct_fixed_error = max(direct_fixed_errors.values())
    checks.append(
        validation_check(
            "VAL-017",
            "each direct cell reaches its map fixed point on the frozen anchor",
            direct_fixed_errors,
            fixed_tolerance,
            direct_fixed_error <= fixed_tolerance,
        )
    )

    all_passed = all(check["passed"] for check in checks)
    return {
        "all_passed": all_passed,
        "number_passed": sum(check["passed"] for check in checks),
        "number_total": len(checks),
        "checks": checks,
    }


def git_provenance(repository: Path) -> dict[str, Any]:
    def run_git(*arguments: str) -> str:
        completed = subprocess.run(
            ["git", *arguments],
            cwd=repository,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return completed.stdout.rstrip("\n")

    return {
        "head": run_git("rev-parse", "HEAD"),
        "branch": run_git("branch", "--show-current"),
        "status_porcelain_v1": run_git("status", "--porcelain=v1", "--untracked-files=all").splitlines(),
    }


def exact_command() -> str:
    arguments = getattr(sys, "orig_argv", [sys.executable, *sys.argv])
    return " ".join(shlex.quote(argument) for argument in arguments)


def source_hashes(repository: Path) -> dict[str, str]:
    return {
        str(path.relative_to(repository)): sha256_file(path)
        for path in SOURCE_PATHS
    }


def write_retained_result(
    output_directory: Path,
    config: dict[str, Any],
    payload: dict[str, Any],
    validation: dict[str, Any],
    repository: Path,
) -> dict[str, Any]:
    """Write a new retained directory; never replace an existing path."""

    if output_directory.exists():
        raise FileExistsError(f"refusing to overwrite retained output: {output_directory}")

    hashes = source_hashes(repository)
    source_bundle_hash = sha256_bytes(canonical_bytes(hashes))
    config_hash = sha256_bytes(canonical_bytes(config))
    scientific_payload_hash = sha256_bytes(canonical_bytes(payload))
    provenance = {
        "created_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "working_directory": str(Path.cwd()),
        "exact_command": exact_command(),
        "runtime": {
            "python": sys.version,
            "python_executable": sys.executable,
            "platform": platform.platform(),
            "process_id": os.getpid(),
        },
        "git": git_provenance(repository),
        "source_hashes": hashes,
        "source_bundle_sha256": source_bundle_hash,
        "configuration_sha256": config_hash,
    }
    result = {
        "experiment_id": config["experiment_id"],
        "run_status": "valid" if validation["all_passed"] else "invalid",
        "scientific_payload_sha256": scientific_payload_hash,
        "scientific_result": payload,
        "validation": validation,
        "provenance": provenance,
    }

    output_directory.mkdir(parents=True, exist_ok=False)
    result_path = output_directory / "result.json"
    validation_path = output_directory / "validation.json"
    result_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    validation_path.write_text(
        json.dumps(validation, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    manifest = {
        "experiment_id": config["experiment_id"],
        "write_policy": "new directory only; existing paths are never overwritten",
        "files": {
            "result.json": sha256_file(result_path),
            "validation.json": sha256_file(validation_path),
        },
        "scientific_payload_sha256": scientific_payload_hash,
        "configuration_sha256": config_hash,
        "source_bundle_sha256": source_bundle_hash,
    }
    manifest_path = output_directory / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return {
        "output_directory": str(output_directory),
        "result_path": str(result_path),
        "manifest_path": str(manifest_path),
        "result_sha256": manifest["files"]["result.json"],
        "scientific_payload_sha256": scientific_payload_hash,
        "run_status": result["run_status"],
    }


def repository_root() -> Path:
    completed = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=HERE,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return Path(completed.stdout.strip()).resolve()


def run(output_directory: Path) -> int:
    if output_directory.exists():
        raise FileExistsError(f"refusing to overwrite retained output: {output_directory}")
    config = load_config()
    payload = build_scientific_payload(config)
    validation = validate_payload(config, payload)
    summary = write_retained_result(
        output_directory.resolve(), config, payload, validation, repository_root()
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if validation["all_passed"] else 1


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        required=True,
        type=Path,
        help="new retained output directory; the command fails if it already exists",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_args(argv)
    try:
        return run(arguments.output_dir)
    except FileExistsError as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
