#!/usr/bin/env python3
"""Deterministic second-graph confirmation for RQ1-UPDATE-CYCLE-001."""

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
    HERE / "rq1_update_cycle_001.py",
    HERE / "config.json",
    HERE / "experiment_card.md",
    HERE / "test_rq1_update_cycle_001.py",
)
STATE_MAPS = ("full", "qbar_tied")
OPERATORS = ("direct", "true_residual_gradient")

Vector = list[float]
Matrix = list[list[float]]
Edge = tuple[int, int, str]


def load_config(path: Path = CONFIG_PATH) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def edges_from_config(config: dict[str, Any]) -> tuple[Edge, ...]:
    return tuple(
        (int(entry["bit"]), int(entry["check"]), str(entry["label"]))
        for entry in config["graph"]["edge_order"]
    )


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


def transpose(matrix: Matrix) -> Matrix:
    return [list(column) for column in zip(*matrix)]


def matvec(matrix: Matrix, vector: Sequence[float]) -> Vector:
    return [dot(row, vector) for row in matrix]


def matmul(left: Matrix, right: Matrix) -> Matrix:
    right_t = transpose(right)
    return [[dot(row, column) for column in right_t] for row in left]


def matrix_sub(left: Matrix, right: Matrix) -> Matrix:
    return [
        [left[row][column] - right[row][column] for column in range(len(left[0]))]
        for row in range(len(left))
    ]


def matrix_max_abs_difference(left: Matrix, right: Matrix) -> float:
    return max_abs(
        left[row][column] - right[row][column]
        for row in range(len(left))
        for column in range(len(left[0]))
    )


def symmetric_eigenvalues_jacobi(
    matrix: Matrix, *, tolerance: float = 1e-14, max_iterations: int = 10000
) -> Vector:
    work = [row[:] for row in matrix]
    size = len(work)
    if size == 1:
        return [work[0][0]]
    for _ in range(max_iterations):
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


def rref_fixed_point_system(matrix: Matrix, vector: Sequence[float], tolerance: float) -> dict[str, Any]:
    """Reduce A*u=c and retain consistency, one solution, and nullspace basis."""

    row_count = len(matrix)
    column_count = len(matrix[0])
    augmented = [list(matrix[row]) + [float(vector[row])] for row in range(row_count)]
    pivot_columns: list[int] = []
    pivot_row = 0
    for column in range(column_count):
        candidate = max(
            range(pivot_row, row_count),
            key=lambda row: abs(augmented[row][column]),
            default=pivot_row,
        )
        if abs(augmented[candidate][column]) <= tolerance:
            continue
        augmented[pivot_row], augmented[candidate] = augmented[candidate], augmented[pivot_row]
        scale = augmented[pivot_row][column]
        augmented[pivot_row] = [value / scale for value in augmented[pivot_row]]
        for row in range(row_count):
            if row == pivot_row:
                continue
            factor = augmented[row][column]
            if abs(factor) <= tolerance:
                continue
            augmented[row] = [
                augmented[row][index] - factor * augmented[pivot_row][index]
                for index in range(column_count + 1)
            ]
        pivot_columns.append(column)
        pivot_row += 1
        if pivot_row == row_count:
            break

    for row in range(row_count):
        augmented[row] = [0.0 if abs(value) <= tolerance else value for value in augmented[row]]

    inconsistent_rows = [
        row
        for row in range(row_count)
        if max_abs(augmented[row][:column_count]) <= tolerance
        and abs(augmented[row][column_count]) > tolerance
    ]
    consistent = not inconsistent_rows
    rank_matrix = len(pivot_columns)
    rank_augmented = rank_matrix + (0 if consistent else 1)
    free_columns = [column for column in range(column_count) if column not in pivot_columns]

    particular: Vector | None = None
    nullspace: list[Vector] = []
    if consistent:
        particular = [0.0] * column_count
        for row, column in enumerate(pivot_columns):
            particular[column] = augmented[row][column_count]
        for free_column in free_columns:
            basis = [0.0] * column_count
            basis[free_column] = 1.0
            for row, column in enumerate(pivot_columns):
                basis[column] = -augmented[row][free_column]
            nullspace.append(basis)

    return {
        "consistent": consistent,
        "rank_matrix": rank_matrix,
        "rank_augmented": rank_augmented,
        "nullity": column_count - rank_matrix,
        "pivot_columns": pivot_columns,
        "free_columns": free_columns,
        "rref_augmented": augmented,
        "inconsistent_rows": inconsistent_rows,
        "particular_solution": particular,
        "nullspace_basis": nullspace,
    }


def llrs_from_config(config: dict[str, Any]) -> Vector:
    return [float(value) for value in config["channel_llrs"]["values"]]


def map_evaluation(
    state_map: str,
    state: Sequence[float],
    llrs: Sequence[float],
    edges: Sequence[Edge],
) -> dict[str, Any]:
    if state_map not in STATE_MAPS:
        raise ValueError(f"unknown state map: {state_map}")
    if len(state) != len(edges):
        raise ValueError("state must have one value per edge")

    full_variable_to_check: Vector = []
    for bit, check, _ in edges:
        other_incoming = math.fsum(
            state[index]
            for index, (other_bit, other_check, _) in enumerate(edges)
            if other_bit == bit and other_check != check
        )
        full_variable_to_check.append(llrs[bit] + other_incoming)

    qbar: Vector = []
    for bit in range(len(llrs)):
        outgoing = [
            full_variable_to_check[index]
            for index, (edge_bit, _, _) in enumerate(edges)
            if edge_bit == bit
        ]
        qbar.append(math.fsum(outgoing) / len(outgoing))

    used = (
        full_variable_to_check[:]
        if state_map == "full"
        else [qbar[bit] for bit, _, _ in edges]
    )
    output: Vector = []
    source_edges: list[int] = []
    for edge_index, (_, check, _) in enumerate(edges):
        others = [
            other_index
            for other_index, (_, other_check, _) in enumerate(edges)
            if other_check == check and other_index != edge_index
        ]
        if len(others) != 1:
            raise ValueError("this confirmation requires degree-two checks")
        source_edges.append(others[0])
        output.append(used[others[0]])

    return {
        "state_map": state_map,
        "input_state": list(state),
        "variable_to_check_full": full_variable_to_check,
        "qbar_by_bit": qbar,
        "variable_to_check_used": used,
        "check_source_edge_by_output_coordinate": source_edges,
        "output_state": output,
    }


def analytic_affine_map(
    state_map: str, llrs: Sequence[float], edges: Sequence[Edge]
) -> tuple[Matrix, Vector]:
    """Construct J and c directly from graph incidence and the declared rule."""

    size = len(edges)
    jacobian = [[0.0] * size for _ in range(size)]
    offset = [0.0] * size
    for output_index, (_, check, _) in enumerate(edges):
        source_candidates = [
            index
            for index, (_, other_check, _) in enumerate(edges)
            if other_check == check and index != output_index
        ]
        if len(source_candidates) != 1:
            raise ValueError("this confirmation requires degree-two checks")
        source_edge = source_candidates[0]
        source_bit, source_recipient_check, _ = edges[source_edge]
        offset[output_index] = llrs[source_bit]
        source_bit_edges = [
            index for index, (bit, _, _) in enumerate(edges) if bit == source_bit
        ]
        if state_map == "full":
            for incoming_edge in source_bit_edges:
                if edges[incoming_edge][1] != source_recipient_check:
                    jacobian[output_index][incoming_edge] += 1.0
        elif state_map == "qbar_tied":
            degree = len(source_bit_edges)
            for outgoing_edge in source_bit_edges:
                outgoing_check = edges[outgoing_edge][1]
                for incoming_edge in source_bit_edges:
                    if edges[incoming_edge][1] != outgoing_check:
                        jacobian[output_index][incoming_edge] += 1.0 / degree
        else:
            raise ValueError(f"unknown state map: {state_map}")
    return jacobian, offset


def objective(
    state_map: str,
    state: Sequence[float],
    llrs: Sequence[float],
    edges: Sequence[Edge],
) -> float:
    mapped = map_evaluation(state_map, state, llrs, edges)["output_state"]
    residual = vector_sub(state, mapped)
    return 0.5 * dot(residual, residual)


def residual_gradient(
    state_map: str,
    state: Sequence[float],
    llrs: Sequence[float],
    edges: Sequence[Edge],
) -> Vector:
    jacobian, _ = analytic_affine_map(state_map, llrs, edges)
    residual = vector_sub(
        state, map_evaluation(state_map, state, llrs, edges)["output_state"]
    )
    residual_jacobian = matrix_sub(identity(len(state)), jacobian)
    return matvec(transpose(residual_jacobian), residual)


def finite_difference_jacobian(
    state_map: str,
    state: Sequence[float],
    llrs: Sequence[float],
    edges: Sequence[Edge],
    step: float,
) -> Matrix:
    columns: list[Vector] = []
    for coordinate in range(len(state)):
        plus = list(state)
        minus = list(state)
        plus[coordinate] += step
        minus[coordinate] -= step
        output_plus = map_evaluation(state_map, plus, llrs, edges)["output_state"]
        output_minus = map_evaluation(state_map, minus, llrs, edges)["output_state"]
        columns.append(
            [(a - b) / (2.0 * step) for a, b in zip(output_plus, output_minus)]
        )
    return transpose(columns)


def finite_difference_gradient(
    state_map: str,
    state: Sequence[float],
    llrs: Sequence[float],
    edges: Sequence[Edge],
    step: float,
) -> Vector:
    result: Vector = []
    for coordinate in range(len(state)):
        plus = list(state)
        minus = list(state)
        plus[coordinate] += step
        minus[coordinate] -= step
        result.append(
            (
                objective(state_map, plus, llrs, edges)
                - objective(state_map, minus, llrs, edges)
            )
            / (2.0 * step)
        )
    return result


def a_posteriori_llrs(
    state: Sequence[float], llrs: Sequence[float], edges: Sequence[Edge]
) -> Vector:
    return [
        llrs[bit]
        + math.fsum(
            state[index]
            for index, (edge_bit, _, _) in enumerate(edges)
            if edge_bit == bit
        )
        for bit in range(len(llrs))
    ]


def hard_decision(values: Sequence[float], *, positive_llr_bit: int = 1) -> list[int]:
    if positive_llr_bit not in (0, 1):
        raise ValueError("positive_llr_bit must be 0 or 1")
    return [
        positive_llr_bit if value >= 0.0 else 1 - positive_llr_bit
        for value in values
    ]


def syndrome(bits: Sequence[int], parity_check_matrix: Sequence[Sequence[int]]) -> list[int]:
    return [sum(entry * bit for entry, bit in zip(row, bits)) % 2 for row in parity_check_matrix]


def decision_diagnostics(
    state: Sequence[float],
    llrs: Sequence[float],
    edges: Sequence[Edge],
    parity_check_matrix: Sequence[Sequence[int]],
    *,
    positive_llr_bit: int = 1,
) -> dict[str, Any]:
    posterior = a_posteriori_llrs(state, llrs, edges)
    estimate = hard_decision(posterior, positive_llr_bit=positive_llr_bit)
    check_syndrome = syndrome(estimate, parity_check_matrix)
    return {
        "a_posteriori_llrs": posterior,
        "hard_decision_estimate": estimate,
        "syndrome": check_syndrome,
        "valid_codeword": all(value == 0 for value in check_syndrome),
        "transmitted_word_recovery": None,
    }


def logsumexp(values: Sequence[float]) -> float:
    if not values:
        return -math.inf
    maximum = max(values)
    return maximum + math.log(math.fsum(math.exp(value - maximum) for value in values))


def parity_enumeration_diagnostics(
    evaluation: dict[str, Any], edges: Sequence[Edge]
) -> dict[str, Any]:
    records: list[dict[str, Any]] = []
    for output_index, (recipient_bit, check, label) in enumerate(edges):
        source_index = evaluation["check_source_edge_by_output_coordinate"][output_index]
        source_bit = edges[source_index][0]
        source_q = evaluation["variable_to_check_used"][source_index]
        log_weights = {0: [], 1: []}
        for recipient_value in (0, 1):
            for source_value in (0, 1):
                if (recipient_value + source_value) % 2 == 0:
                    log_weights[recipient_value].append(source_value * source_q)
        enumerated = logsumexp(log_weights[1]) - logsumexp(log_weights[0])
        executable = evaluation["output_state"][output_index]
        records.append(
            {
                "output_coordinate": output_index,
                "output_label": label,
                "check": check,
                "recipient_bit": recipient_bit,
                "source_bit": source_bit,
                "source_q": source_q,
                "enumerated_check_to_variable_llr": enumerated,
                "executable_check_to_variable_llr": executable,
                "absolute_error": abs(enumerated - executable),
            }
        )
    return {
        "records": records,
        "maximum_absolute_error": max(record["absolute_error"] for record in records),
    }


def operation_categories(state_map: str, operator: str, edge_count: int, bit_count: int) -> dict[str, Any]:
    state_counts = {
        "variable_node_additions": edge_count,
        "recipient_average_additions": 0 if state_map == "full" else bit_count,
        "recipient_average_scalings": 0 if state_map == "full" else bit_count,
        "degree_two_check_transfers": edge_count,
        "nonlinear_check_functions": 0,
    }
    if operator == "direct":
        update_counts = {
            "residual_subtractions": 0,
            "jacobian_transpose_nonzero_products": 0,
            "jacobian_transpose_accumulations": 0,
            "step_size_multiplications": 0,
            "state_update_subtractions": 0,
            "state_assignments": edge_count,
        }
    else:
        nonzero_jacobian = edge_count if state_map == "full" else 2 * edge_count
        update_counts = {
            "residual_subtractions": edge_count,
            "jacobian_transpose_nonzero_products": nonzero_jacobian,
            "jacobian_transpose_accumulations": nonzero_jacobian,
            "step_size_multiplications": edge_count,
            "state_update_subtractions": edge_count,
            "state_assignments": 0,
        }
    excluded_diagnostics = [
        "finite-difference evaluations",
        "rank and nullspace calculations",
        "local parity enumeration",
        "objective-after evaluation",
        "hard decision and syndrome",
        "hashing and serialization",
    ]
    if state_map == "full":
        excluded_diagnostics.append(
            "qbar values calculated only for aligned diagnostics in the full cell"
        )
    return {
        "algorithm_core": {**state_counts, **update_counts},
        "excluded_diagnostics": excluded_diagnostics,
        "weighted_scalar_total_reported": False,
    }


def storage_counts(state_map: str, operator: str, edge_count: int, bit_count: int) -> dict[str, Any]:
    return {
        "persistent_dynamic_values_between_updates": edge_count,
        "persistent_state_description": "check-to-variable state u",
        "fixed_channel_llrs_not_counted_as_dynamic_state": bit_count,
        "temporary_variable_to_check_values": edge_count,
        "temporary_qbar_values": 0 if state_map == "full" else bit_count,
        "temporary_residual_values": 0 if operator == "direct" else edge_count,
        "temporary_gradient_values": 0 if operator == "direct" else edge_count,
    }


def evaluate_cell(
    state_map: str,
    operator: str,
    before: Sequence[float],
    llrs: Sequence[float],
    edges: Sequence[Edge],
    parity_check_matrix: Sequence[Sequence[int]],
    alpha: float,
) -> dict[str, Any]:
    jacobian, offset = analytic_affine_map(state_map, llrs, edges)
    evaluation_before = map_evaluation(state_map, before, llrs, edges)
    residual_before = vector_sub(before, evaluation_before["output_state"])
    gradient_before = residual_gradient(state_map, before, llrs, edges)
    if operator == "direct":
        after = evaluation_before["output_state"][:]
    elif operator == "true_residual_gradient":
        after = vector_sub(before, vector_scale(alpha, gradient_before))
    else:
        raise ValueError(f"unknown operator: {operator}")
    evaluation_after = map_evaluation(state_map, after, llrs, edges)
    residual_after = vector_sub(after, evaluation_after["output_state"])
    gradient_after = residual_gradient(state_map, after, llrs, edges)
    return {
        "cell_id": f"{state_map}__{operator}",
        "state_map": state_map,
        "operator": operator,
        "update_budget": 1,
        "early_stopping": False,
        "before_state": list(before),
        "map_evaluation_before": evaluation_before,
        "jacobian": jacobian,
        "affine_offset": offset,
        "residual_before": residual_before,
        "residual_norm_before": norm2(residual_before),
        "gradient_before": gradient_before,
        "objective_before": 0.5 * dot(residual_before, residual_before),
        "alpha": None if operator == "direct" else alpha,
        "update_displacement": vector_sub(after, before),
        "after_state": after,
        "map_evaluation_after": evaluation_after,
        "residual_after": residual_after,
        "residual_norm_after": norm2(residual_after),
        "gradient_after": gradient_after,
        "objective_after": 0.5 * dot(residual_after, residual_after),
        "decision_before": decision_diagnostics(
            before, llrs, edges, parity_check_matrix
        ),
        "decision_after": decision_diagnostics(
            after, llrs, edges, parity_check_matrix
        ),
        "local_parity_enumeration": parity_enumeration_diagnostics(
            evaluation_before, edges
        ),
        "operation_categories": operation_categories(
            state_map, operator, len(edges), len(llrs)
        ),
        "storage_counts": storage_counts(
            state_map, operator, len(edges), len(llrs)
        ),
    }


def sign_transform_cell_diagnostics(
    cell: dict[str, Any],
    llrs: Sequence[float],
    edges: Sequence[Edge],
    parity_check_matrix: Sequence[Sequence[int]],
    alpha: float,
    tolerance: float,
) -> dict[str, Any]:
    state_map = cell["state_map"]
    operator = cell["operator"]
    transformed_llrs = vector_scale(-1.0, llrs)
    transformed_before = vector_scale(-1.0, cell["before_state"])
    transformed_evaluation = map_evaluation(
        state_map, transformed_before, transformed_llrs, edges
    )
    transformed_residual = vector_sub(
        transformed_before, transformed_evaluation["output_state"]
    )
    transformed_gradient = residual_gradient(
        state_map, transformed_before, transformed_llrs, edges
    )
    if operator == "direct":
        transformed_after = transformed_evaluation["output_state"][:]
    else:
        transformed_after = vector_sub(
            transformed_before, vector_scale(alpha, transformed_gradient)
        )
    transformed_posterior = a_posteriori_llrs(
        transformed_after, transformed_llrs, edges
    )
    transformed_decision = decision_diagnostics(
        transformed_after,
        transformed_llrs,
        edges,
        parity_check_matrix,
        positive_llr_bit=0,
    )
    original_evaluation = cell["map_evaluation_before"]
    errors = {
        "channel_llr": max_abs(vector_add(transformed_llrs, llrs)),
        "before_state_u": max_abs(vector_add(transformed_before, cell["before_state"])),
        "variable_to_check_q_full": max_abs(
            vector_add(
                transformed_evaluation["variable_to_check_full"],
                original_evaluation["variable_to_check_full"],
            )
        ),
        "qbar": max_abs(
            vector_add(
                transformed_evaluation["qbar_by_bit"],
                original_evaluation["qbar_by_bit"],
            )
        ),
        "variable_to_check_q_used": max_abs(
            vector_add(
                transformed_evaluation["variable_to_check_used"],
                original_evaluation["variable_to_check_used"],
            )
        ),
        "map_output_u": max_abs(
            vector_add(
                transformed_evaluation["output_state"],
                original_evaluation["output_state"],
            )
        ),
        "residual": max_abs(vector_add(transformed_residual, cell["residual_before"])),
        "gradient": max_abs(vector_add(transformed_gradient, cell["gradient_before"])),
        "after_state_u": max_abs(vector_add(transformed_after, cell["after_state"])),
        "a_posteriori_x": max_abs(
            vector_add(
                transformed_posterior,
                cell["decision_after"]["a_posteriori_llrs"],
            )
        ),
    }
    maximum_error = max(errors.values())
    objective_error = abs(
        0.5 * dot(transformed_residual, transformed_residual)
        - cell["objective_before"]
    )
    hard_preserved = (
        transformed_decision["hard_decision_estimate"]
        == cell["decision_after"]["hard_decision_estimate"]
    )
    syndrome_preserved = (
        transformed_decision["syndrome"] == cell["decision_after"]["syndrome"]
    )
    return {
        "cell_id": cell["cell_id"],
        "transform": "ell=-L, q0=-q1, u0=-u1, x0=-x1",
        "soft_negation_errors": errors,
        "maximum_soft_negation_error": maximum_error,
        "objective_invariance_error": objective_error,
        "hard_decision_preserved": hard_preserved,
        "syndrome_preserved": syndrome_preserved,
        "transformed_hard_decision_estimate": transformed_decision[
            "hard_decision_estimate"
        ],
        "transformed_syndrome": transformed_decision["syndrome"],
        "tolerance": tolerance,
        "passed": maximum_error <= tolerance
        and objective_error <= tolerance
        and hard_preserved
        and syndrome_preserved,
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
    state = vector_scale(
        0.5,
        vector_add(
            vector_sub(tied_direct, full_direct),
            vector_sub(tied_gradient, full_gradient),
        ),
    )
    update = vector_scale(
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
        "state_effect_vector": state,
        "state_effect_l2_norm": norm2(state),
        "update_effect_vector": update,
        "update_effect_l2_norm": norm2(update),
        "interaction_vector": interaction,
        "interaction_l2_norm": norm2(interaction),
    }


def build_scientific_payload(config: dict[str, Any]) -> dict[str, Any]:
    llrs = llrs_from_config(config)
    edges = edges_from_config(config)
    parity_check_matrix = config["graph"]["parity_check_matrix"]
    zero_state = [0.0] * len(edges)
    start = map_evaluation("full", zero_state, llrs, edges)["output_state"]
    alpha = float(config["gradient_step"]["alpha"])
    rank_tolerance = float(config["numeric_tolerances"]["rank_pivot"])

    properties: dict[str, dict[str, Any]] = {}
    for state_map in STATE_MAPS:
        jacobian, offset = analytic_affine_map(state_map, llrs, edges)
        residual_jacobian = matrix_sub(identity(len(edges)), jacobian)
        hessian = matmul(transpose(residual_jacobian), residual_jacobian)
        spectrum = symmetric_eigenvalues_jacobi(hessian)
        fixed_system = rref_fixed_point_system(
            residual_jacobian, offset, rank_tolerance
        )
        properties[state_map] = {
            "jacobian": jacobian,
            "affine_offset": offset,
            "residual_jacobian": residual_jacobian,
            "objective_hessian": hessian,
            "objective_hessian_eigenvalues": spectrum,
            "maximum_eigenvalue": max(spectrum),
            "transferred_alpha": alpha,
            "gradient_descent_stability_upper_bound": 2.0 / max(spectrum),
            "transferred_alpha_in_open_stability_interval": 0.0
            < alpha
            < 2.0 / max(spectrum),
            "fixed_point_system": fixed_system,
        }

    cells: dict[str, dict[str, Any]] = {}
    for state_map in STATE_MAPS:
        for operator in OPERATORS:
            cell = evaluate_cell(
                state_map,
                operator,
                start,
                llrs,
                edges,
                parity_check_matrix,
                alpha,
            )
            cells[cell["cell_id"]] = cell

    sign_tolerance = float(config["numeric_tolerances"]["sign_transform_max_abs"])
    sign_cells = {
        cell_id: sign_transform_cell_diagnostics(
            cell,
            llrs,
            edges,
            parity_check_matrix,
            alpha,
            sign_tolerance,
        )
        for cell_id, cell in cells.items()
    }
    sign_transform = {
        "transform": config["sign_transform_control"]["transform"],
        "source_positive_llr_bit": config["channel_llrs"]["positive_llr_bit"],
        "transformed_positive_llr_bit": config["sign_transform_control"][
            "positive_llr_bit"
        ],
        "all_cells_passed": all(cell["passed"] for cell in sign_cells.values()),
        "cells": sign_cells,
    }

    contrasts = factorial_contrasts(cells)
    nonzero_tolerance = float(config["numeric_tolerances"]["effect_nonzero"])
    prediction_results = {
        "state_effect_vector_nonzero": contrasts["state_effect_l2_norm"]
        > nonzero_tolerance,
        "update_effect_vector_nonzero": contrasts["update_effect_l2_norm"]
        > nonzero_tolerance,
        "difference_in_differences_vector_nonzero": contrasts[
            "interaction_l2_norm"
        ]
        > nonzero_tolerance,
        "hard_decision_was_preregistered": False,
    }

    labels = [edge[2] for edge in edges]
    comparison_tolerance = float(config["numeric_tolerances"]["affine_map_max_abs"])
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
        left = cells[left_id]
        right = cells[right_id]
        first_divergences[comparison] = {
            "left_cell": left_id,
            "right_cell": right_id,
            "pre_update_states_equal": left["before_state"] == right["before_state"],
            "first_divergent_update": 1,
            "state": first_difference(
                left["after_state"], right["after_state"], labels, comparison_tolerance
            ),
            "a_posteriori_llr": first_difference(
                left["decision_after"]["a_posteriori_llrs"],
                right["decision_after"]["a_posteriori_llrs"],
                [f"b{bit}" for bit in range(len(llrs))],
                comparison_tolerance,
            ),
        }

    return {
        "experiment_id": config["experiment_id"],
        "research_question": config["research_question"],
        "classification": config["classification"],
        "scope_note": (
            "second-graph BP-residual gradient confirmation only; not native "
            "projected GD and not a decoding-performance experiment"
        ),
        "parity_check_matrix": parity_check_matrix,
        "edge_order": [
            {"coordinate": index, "bit": bit, "check": check, "label": label}
            for index, (bit, check, label) in enumerate(edges)
        ],
        "channel_llrs": llrs,
        "llr_definition": config["channel_llrs"]["definition"],
        "llr_convention": config["channel_llrs"]["convention"],
        "start_state_definition": config["initialization"]["expression"],
        "start_state": start,
        "start_decision": decision_diagnostics(
            start, llrs, edges, parity_check_matrix
        ),
        "alpha": alpha,
        "alpha_expression": config["gradient_step"]["alpha_expression"],
        "alpha_selection_rule": config["gradient_step"]["selection_rule"],
        "update_budget": config["budget"],
        "preregistered_predictions": config["preregistered_predictions"],
        "state_map_properties": properties,
        "cells": cells,
        "sign_transform_invariance": sign_transform,
        "factorial_contrasts": contrasts,
        "preregistered_prediction_results": prediction_results,
        "first_divergences": first_divergences,
        "interpretation_limits": config["scope"],
    }


def validation_check(
    check_id: str,
    description: str,
    observed: Any,
    threshold_or_expected: Any,
    passed: bool,
) -> dict[str, Any]:
    return {
        "check_id": check_id,
        "description": description,
        "observed": observed,
        "threshold_or_expected": threshold_or_expected,
        "passed": bool(passed),
    }


def validate_payload(config: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    llrs = payload["channel_llrs"]
    edges = edges_from_config(config)
    start = payload["start_state"]
    affine_tolerance = float(config["numeric_tolerances"]["affine_map_max_abs"])
    fixed_tolerance = float(config["numeric_tolerances"]["fixed_point_max_abs"])
    parity_tolerance = float(config["numeric_tolerances"]["parity_enumeration_max_abs"])
    sign_tolerance = float(config["numeric_tolerances"]["sign_transform_max_abs"])
    jacobian_tolerance = float(config["finite_difference"]["jacobian_max_abs_tolerance"])
    gradient_tolerance = float(config["finite_difference"]["gradient_max_abs_tolerance"])
    finite_step = float(config["finite_difference"]["central_step"])
    nonzero_tolerance = float(config["numeric_tolerances"]["effect_nonzero"])
    expected_llrs = [
        -math.log(9.0),
        math.log(1.5),
        math.log(2.0),
        math.log(3.0),
    ]
    expected_h = [[1, 1, 0, 0], [0, 1, 1, 0], [0, 0, 1, 1], [1, 0, 0, 1]]
    expected_edges: tuple[Edge, ...] = (
        (0, 0, "b0-c0"),
        (0, 3, "b0-c3"),
        (1, 0, "b1-c0"),
        (1, 1, "b1-c1"),
        (2, 1, "b2-c1"),
        (2, 2, "b2-c2"),
        (3, 2, "b3-c2"),
        (3, 3, "b3-c3"),
    )
    expected_alpha = (3.0 - math.sqrt(5.0)) / 2.0
    checks: list[dict[str, Any]] = []

    protocol_errors = {
        "llr_max_abs": max_abs(vector_sub(llrs, expected_llrs)),
        "alpha_abs": abs(payload["alpha"] - expected_alpha),
        "matrix_equal": payload["parity_check_matrix"] == expected_h,
        "edge_order_equal": tuple(edges) == expected_edges,
        "positive_llr_bit": config["channel_llrs"]["positive_llr_bit"],
        "budget": payload["update_budget"],
        "hard_prediction": config["preregistered_predictions"][
            "hard_decision_prediction"
        ],
    }
    protocol_passed = (
        protocol_errors["llr_max_abs"] <= affine_tolerance
        and protocol_errors["alpha_abs"] <= affine_tolerance
        and protocol_errors["matrix_equal"]
        and protocol_errors["edge_order_equal"]
        and protocol_errors["positive_llr_bit"] == 1
        and protocol_errors["budget"] == {"updates": 1, "early_stopping": False}
        and protocol_errors["hard_prediction"] is None
    )
    checks.append(
        validation_check(
            "VAL-001",
            "frozen matrix, edges, LLRs, convention, alpha, budget, and no hard prediction",
            protocol_errors,
            "exact protocol identity; numeric errors <= 1e-12",
            protocol_passed,
        )
    )

    recomputed_start = map_evaluation(
        "full", [0.0] * len(edges), llrs, edges
    )["output_state"]
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

    check_id = 3
    for state_map in STATE_MAPS:
        properties = payload["state_map_properties"][state_map]
        jacobian = properties["jacobian"]
        offset = properties["affine_offset"]
        executable = map_evaluation(state_map, start, llrs, edges)["output_state"]
        affine_output = vector_add(matvec(jacobian, start), offset)
        affine_error = max_abs(vector_sub(executable, affine_output))
        checks.append(
            validation_check(
                f"VAL-{check_id:03d}",
                f"{state_map} executable map agrees with J*u+c",
                affine_error,
                affine_tolerance,
                affine_error <= affine_tolerance,
            )
        )
        check_id += 1

        numerical_jacobian = finite_difference_jacobian(
            state_map, start, llrs, edges, finite_step
        )
        jacobian_error = matrix_max_abs_difference(jacobian, numerical_jacobian)
        checks.append(
            validation_check(
                f"VAL-{check_id:03d}",
                f"{state_map} analytic Jacobian agrees with central finite differences",
                jacobian_error,
                jacobian_tolerance,
                jacobian_error <= jacobian_tolerance,
            )
        )
        check_id += 1

        analytic_gradient = residual_gradient(state_map, start, llrs, edges)
        numerical_gradient = finite_difference_gradient(
            state_map, start, llrs, edges, finite_step
        )
        gradient_error = max_abs(vector_sub(analytic_gradient, numerical_gradient))
        checks.append(
            validation_check(
                f"VAL-{check_id:03d}",
                f"{state_map} analytic gradient agrees with central finite differences",
                gradient_error,
                gradient_tolerance,
                gradient_error <= gradient_tolerance,
            )
        )
        check_id += 1

        fixed_system = properties["fixed_point_system"]
        particular = fixed_system["particular_solution"]
        if particular is None:
            particular_error = math.inf
        else:
            particular_error = max_abs(
                vector_sub(
                    matvec(properties["residual_jacobian"], particular), offset
                )
            )
        nullspace_errors = [
            max_abs(matvec(properties["residual_jacobian"], basis))
            for basis in fixed_system["nullspace_basis"]
        ]
        maximum_nullspace_error = max(nullspace_errors, default=0.0)
        spectral_rank = sum(
            eigenvalue > config["numeric_tolerances"]["rank_pivot"]
            for eigenvalue in properties["objective_hessian_eigenvalues"]
        )
        fixed_passed = (
            fixed_system["consistent"]
            and particular_error <= fixed_tolerance
            and maximum_nullspace_error <= fixed_tolerance
            and len(fixed_system["nullspace_basis"]) == fixed_system["nullity"]
            and spectral_rank == fixed_system["rank_matrix"]
        )
        checks.append(
            validation_check(
                f"VAL-{check_id:03d}",
                f"{state_map} fixed-point system rank, consistency, solution, and nullspace validate",
                {
                    "consistent": fixed_system["consistent"],
                    "rank_matrix": fixed_system["rank_matrix"],
                    "rank_augmented": fixed_system["rank_augmented"],
                    "nullity": fixed_system["nullity"],
                    "spectral_rank": spectral_rank,
                    "particular_solution_max_abs_error": particular_error,
                    "nullspace_max_abs_error": maximum_nullspace_error,
                },
                {
                    "consistent": True,
                    "numeric_max_abs": fixed_tolerance,
                    "basis_count_equals_nullity": True,
                    "spectral_rank_equals_rref_rank": True,
                },
                fixed_passed,
            )
        )
        check_id += 1

    stable = {
        state_map: {
            "lambda_max": payload["state_map_properties"][state_map][
                "maximum_eigenvalue"
            ],
            "upper_bound": payload["state_map_properties"][state_map][
                "gradient_descent_stability_upper_bound"
            ],
            "alpha": payload["alpha"],
            "inside": payload["state_map_properties"][state_map][
                "transferred_alpha_in_open_stability_interval"
            ],
        }
        for state_map in STATE_MAPS
    }
    checks.append(
        validation_check(
            f"VAL-{check_id:03d}",
            "transferred alpha is retained and its cycle-specific stability interval is recorded",
            stable,
            "alpha=(3-sqrt(5))/2 and 0<alpha<2/lambda_max for both maps",
            abs(payload["alpha"] - expected_alpha) <= affine_tolerance
            and all(entry["inside"] for entry in stable.values()),
        )
    )
    check_id += 1

    sign_transform = payload["sign_transform_invariance"]
    sign_maximum = max(
        max(cell["maximum_soft_negation_error"], cell["objective_invariance_error"])
        for cell in sign_transform["cells"].values()
    )
    checks.append(
        validation_check(
            f"VAL-{check_id:03d}",
            "complete LLR-convention sign transform preserves all cells",
            {
                "maximum_numeric_error": sign_maximum,
                "all_cells_passed": sign_transform["all_cells_passed"],
            },
            {"maximum_numeric_error": sign_tolerance, "all_cells_passed": True},
            sign_transform["all_cells_passed"] and sign_maximum <= sign_tolerance,
        )
    )
    check_id += 1

    parity_errors = {
        cell_id: cell["local_parity_enumeration"]["maximum_absolute_error"]
        for cell_id, cell in payload["cells"].items()
    }
    checks.append(
        validation_check(
            f"VAL-{check_id:03d}",
            "degree-two check outputs agree with local valid-assignment enumeration",
            parity_errors,
            parity_tolerance,
            max(parity_errors.values()) <= parity_tolerance,
        )
    )
    check_id += 1

    decisions_passed = True
    for cell in payload["cells"].values():
        recomputed = decision_diagnostics(
            cell["after_state"],
            llrs,
            edges,
            payload["parity_check_matrix"],
        )
        probabilities = [
            1.0 / (1.0 + math.exp(-value))
            for value in cell["decision_after"]["a_posteriori_llrs"]
        ]
        probability_decision = [1 if probability >= 0.5 else 0 for probability in probabilities]
        decisions_passed = (
            decisions_passed
            and recomputed == cell["decision_after"]
            and probability_decision == cell["decision_after"]["hard_decision_estimate"]
        )
    checks.append(
        validation_check(
            f"VAL-{check_id:03d}",
            "hard-decision estimates and syndromes independently recompute",
            decisions_passed,
            True,
            decisions_passed,
        )
    )
    check_id += 1

    contrasts = payload["factorial_contrasts"]
    prediction_results = payload["preregistered_prediction_results"]
    predictions_passed = (
        prediction_results["state_effect_vector_nonzero"]
        and prediction_results["update_effect_vector_nonzero"]
        and prediction_results["difference_in_differences_vector_nonzero"]
        and not prediction_results["hard_decision_was_preregistered"]
    )
    checks.append(
        validation_check(
            f"VAL-{check_id:03d}",
            "three preregistered vector predictions pass without a hard-decision prediction",
            {
                "state_norm": contrasts["state_effect_l2_norm"],
                "update_norm": contrasts["update_effect_l2_norm"],
                "interaction_norm": contrasts["interaction_l2_norm"],
                "hard_decision_was_preregistered": False,
            },
            {
                "each_norm_greater_than": nonzero_tolerance,
                "hard_decision_was_preregistered": False,
            },
            predictions_passed,
        )
    )
    check_id += 1

    second_payload = build_scientific_payload(config)
    first_digest = sha256_bytes(canonical_bytes(payload))
    second_digest = sha256_bytes(canonical_bytes(second_payload))
    checks.append(
        validation_check(
            f"VAL-{check_id:03d}",
            "pure scientific calculation replays deterministically",
            {"first": first_digest, "second": second_digest},
            "exact digest equality",
            first_digest == second_digest,
        )
    )

    all_passed = all(check["passed"] for check in checks)
    return {
        "all_passed": all_passed,
        "number_passed": sum(check["passed"] for check in checks),
        "number_total": len(checks),
        "checks": checks,
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
        "status_porcelain_v1": run_git(
            "status", "--porcelain=v1", "--untracked-files=all"
        ).splitlines(),
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
    if output_directory.exists():
        raise FileExistsError(f"refusing to overwrite retained output: {output_directory}")
    hashes = source_hashes(repository)
    source_bundle_hash = sha256_bytes(canonical_bytes(hashes))
    configuration_hash = sha256_bytes(canonical_bytes(config))
    scientific_hash = sha256_bytes(canonical_bytes(payload))
    result = {
        "experiment_id": config["experiment_id"],
        "run_status": "valid" if validation["all_passed"] else "invalid",
        "evidence_eligible": bool(validation["all_passed"]),
        "scientific_payload_sha256": scientific_hash,
        "scientific_result": payload,
        "validation": validation,
        "provenance": {
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
            "configuration_sha256": configuration_hash,
        },
    }
    output_directory.mkdir(parents=True, exist_ok=False)
    result_path = output_directory / "result.json"
    validation_path = output_directory / "validation.json"
    result_path.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    validation_path.write_text(
        json.dumps(validation, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    manifest = {
        "experiment_id": config["experiment_id"],
        "run_status": result["run_status"],
        "evidence_eligible": result["evidence_eligible"],
        "write_policy": "new directory only; existing paths are never overwritten",
        "files": {
            "result.json": sha256_file(result_path),
            "validation.json": sha256_file(validation_path),
        },
        "scientific_payload_sha256": scientific_hash,
        "configuration_sha256": configuration_hash,
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
        "run_status": result["run_status"],
        "evidence_eligible": result["evidence_eligible"],
        "result_sha256": manifest["files"]["result.json"],
        "scientific_payload_sha256": scientific_hash,
    }


def run(output_directory: Path) -> int:
    if output_directory.exists():
        raise FileExistsError(f"refusing to overwrite retained output: {output_directory}")
    config = load_config()
    payload = build_scientific_payload(config)
    validation = validate_payload(config, payload)
    summary = write_retained_result(
        output_directory.resolve(),
        config,
        payload,
        validation,
        repository_root(),
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if validation["all_passed"] else 1


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        required=True,
        type=Path,
        help="new retained output directory; command fails if it exists",
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
