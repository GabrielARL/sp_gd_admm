#!/usr/bin/env python3
"""Split the retained native scalar-GD updates into the terms the Core story shows.

The eligible endpoint trace (RQ1-ENDPOINT-001, endpoint_v3) records, for every
accepted coral_exact_gradient update, the full gradient, the preconditioned
direction and the projected proposal. It does not record how the parity part of
that gradient splits by check. This script recomputes the split from the
retained x values with the declared native objective, in the same
floating-point order as rq1_endpoint_001.jl, and requires every recomposed
vector to equal the retained one bit for bit.

The output is explanatory bookkeeping for rq1_mechanism_animation.html. It runs
no decoder, adds no experiment and carries no performance evidence.

Usage:
    python3 build_core_story_trace.py          # write the retained output
    python3 build_core_story_trace.py --check  # recompute and compare bytes
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ENDPOINT_TRACE = "experiments/rq1_endpoint_001/results/2026-10-28_endpoint_v3/trace.json"
ENDPOINT_SHA256 = "c47e200c5be707b66e9fc454ee221671c4eb36771aedac6e143719b6a679e2f9"
NATIVE_RUNG = 6
NATIVE_CARD = "RQ1-ENDPOINT-PG-001"
TERM_RUNGS = {"parity": 0, "parity_channel": 1, "parity_channel_binary": 2}
RESULT_DIR = HERE / "results" / "2026-10-28_core_story_v1"
OUTPUT = RESULT_DIR / "core_story_trace.json"
MANIFEST = RESULT_DIR / "MANIFEST.sha256"
BIT_NAMES = ["b1", "b2", "b3"]
CHECK_NAMES = ["A", "B"]
FD_STEP = 1.0e-6
FD_TOLERANCE = 2.0e-8  # the endpoint card's finite-difference tolerance


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def load_endpoint(root: Path) -> dict[str, Any]:
    path = root / ENDPOINT_TRACE
    observed = sha256_file(path)
    if observed != ENDPOINT_SHA256:
        raise AssertionError(f"endpoint trace hash {observed} != {ENDPOINT_SHA256}")
    return json.loads(path.read_text(encoding="utf-8"))


def degrees(checks: list[list[int]], n: int) -> list[int]:
    result = [0] * n
    for check in checks:
        for bit in check:
            result[bit - 1] += 1
    return result


def objective_parts(x: list[float], ell: list[float], checks: list[list[int]],
                    fp: dict[str, Any]) -> dict[str, Any]:
    """Native objective and gradient, accumulated in rq1_endpoint_001.jl order."""
    n = len(x)
    pw = float(fp["parity_weight"])
    bw = float(fp["binary_weight"])
    cw = float(fp["channel_weight"])
    gradient = [0.0] * n
    raw_parity = 0.0
    per_check = []
    for check in checks:
        product = 1.0
        first = True
        for bit in check:
            product = x[bit - 1] if first else product * x[bit - 1]
            first = False
        residual = 1.0 - product
        raw_parity += residual * residual
        coefficient = -2.0 * pw * residual / n
        terms = []
        for slot, bit in enumerate(check):
            leave_one = 1.0
            for other_slot, other_bit in enumerate(check):
                if other_slot != slot:
                    leave_one *= x[other_bit - 1]
            term = coefficient * leave_one
            gradient[bit - 1] += term
            terms.append(term)
        per_check.append({"product": product, "residual": residual,
                          "coefficient": coefficient, "terms": terms})
    parity_gradient = list(gradient)
    dot = 0.0
    for e, v in zip(ell, x):
        dot += e * v
    channel = -cw * dot / (2 * n)
    channel_partial = [-(cw * e / (2 * n)) for e in ell]
    gradient = [g - (cw * e / (2 * n)) for g, e in zip(gradient, ell)]
    parity_channel_gradient = list(gradient)
    binary_raw = 0.0
    binary_partial = []
    for i, v in enumerate(x):
        binary_raw += (1.0 - v * v) * (1.0 - v * v)
        term = 4.0 * bw * v * (v * v - 1.0) / n
        binary_partial.append(term)
        gradient[i] += term
    parity = pw * raw_parity / n
    binary = bw * binary_raw / n
    return {
        "per_check": per_check,
        "parity_gradient": parity_gradient,
        "parity_channel_gradient": parity_channel_gradient,
        "channel_partial": channel_partial,
        "binary_partial": binary_partial,
        "gradient": gradient,
        "terms": {"channel": channel, "parity": parity, "binary": binary,
                  "raw_parity": raw_parity, "raw_binary": binary_raw},
        "loss": channel + parity + binary,
    }


def loss_only(x: list[float], ell: list[float], checks: list[list[int]],
              fp: dict[str, Any], keep: str) -> float:
    """One term family of J, for central finite differences."""
    n = len(x)
    if keep == "channel":
        return -float(fp["channel_weight"]) * sum(e * v for e, v in zip(ell, x)) / (2 * n)
    if keep == "binary":
        return float(fp["binary_weight"]) * sum((1.0 - v * v) ** 2 for v in x) / n
    index = int(keep.split(":")[1])
    product = 1.0
    for bit in checks[index]:
        product *= x[bit - 1]
    return float(fp["parity_weight"]) * (1.0 - product) ** 2 / n


def finite_difference(x: list[float], ell: list[float], checks: list[list[int]],
                      fp: dict[str, Any], keep: str, bit: int) -> float:
    plus = list(x)
    minus = list(x)
    plus[bit] += FD_STEP
    minus[bit] -= FD_STEP
    return (loss_only(plus, ell, checks, fp, keep) -
            loss_only(minus, ell, checks, fp, keep)) / (2.0 * FD_STEP)


def hard_decision(x: list[float]) -> list[int]:
    return [1 if v < 0.0 else 0 for v in x]


def syndrome(checks: list[list[int]], bits: list[int]) -> list[int]:
    out = []
    for check in checks:
        parity = 0
        for bit in check:
            parity ^= bits[bit - 1]
        out.append(parity)
    return out


def derive(root: Path = ROOT) -> dict[str, Any]:
    trace = load_endpoint(root)
    rung = trace["rung_results"][NATIVE_RUNG]
    if rung["card_id"] != NATIVE_CARD:
        raise AssertionError(f"rung {NATIVE_RUNG} is {rung['card_id']}, expected {NATIVE_CARD}")
    fp = trace["fingerprints"][NATIVE_RUNG]["payload"]
    checks = trace["graph"]["checks"]
    ell = trace["channel_evidence"]["ell_bit0_positive"]
    L = trace["channel_evidence"]["L_bit1_positive"]
    n = len(ell)
    deg = degrees(checks, n)
    lower, upper = float(fp["box_lower"]), float(fp["box_upper"])
    steps = rung["result"]["trace"]
    checks_passed: dict[str, bool] = {}
    fd_worst = 0.0
    updates = []
    previous = None
    for index, step in enumerate(steps):
        x = step["x_before"]
        parts = objective_parts(x, ell, checks, fp)
        curvature = [((2.0 * float(fp["parity_weight"])) * deg[i] +
                      8.0 * float(fp["binary_weight"])) / n for i in range(n)]
        if fp["preconditioner"] != "native_curvature_bound":
            raise AssertionError("unexpected preconditioner")
        direction = [(-g) / c for g, c in zip(parts["gradient"], curvature)]
        eta = float(fp["step_size"]) * 0.5 ** int(step["backtrack_index"])
        raw = [v + eta * d for v, d in zip(x, direction)]
        projected = [lower if v < lower else (upper if v > upper else v) for v in raw]
        active = [i + 1 for i in range(n) if raw[i] != projected[i]]
        tag = f"update_{step['update']:02d}"
        checks_passed[f"{tag}_gradient_bitwise"] = parts["gradient"] == step["gradient"]
        checks_passed[f"{tag}_direction_bitwise"] = direction == step["direction"]
        checks_passed[f"{tag}_step_size"] = eta == step["accepted_step"]
        checks_passed[f"{tag}_raw_proposal_bitwise"] = raw == step["raw_proposal"]
        checks_passed[f"{tag}_projected_proposal_bitwise"] = projected == step["projected_proposal"]
        checks_passed[f"{tag}_active_projection"] = active == step["active_projection_coordinates"]
        checks_passed[f"{tag}_loss_before"] = abs(parts["loss"] - step["loss_before"]) <= 1e-14
        checks_passed[f"{tag}_strict_decrease"] = step["loss_after"] < step["loss_before"]
        if previous is not None:
            checks_passed[f"{tag}_chained_state"] = x == previous
        previous = step["projected_proposal"]
        for bit in range(n):
            pieces = [("channel", parts["channel_partial"][bit]),
                      ("binary", parts["binary_partial"][bit])]
            for c_index, check in enumerate(checks):
                if bit + 1 in check:
                    slot = check.index(bit + 1)
                    pieces.append((f"parity:{c_index}", parts["per_check"][c_index]["terms"][slot]))
            for keep, analytic in pieces:
                fd_worst = max(fd_worst, abs(finite_difference(x, ell, checks, fp, keep, bit) - analytic))
        g = {}
        readings = {}
        products = {}
        residuals = {}
        for c_index, check in enumerate(checks):
            name = CHECK_NAMES[c_index]
            g[name] = {BIT_NAMES[bit - 1]: parts["per_check"][c_index]["terms"][slot]
                       for slot, bit in enumerate(check)}
            readings[name] = {BIT_NAMES[bit - 1]: x[bit - 1] for bit in check}
            products[name] = parts["per_check"][c_index]["product"]
            residuals[name] = parts["per_check"][c_index]["residual"]
        hard_before = hard_decision(x)
        hard_after = hard_decision(step["projected_proposal"])
        updates.append({
            "update": step["update"],
            "trace_pointer": f"/rung_results/{NATIVE_RUNG}/result/trace/{index}",
            "x_before": x,
            "readings": readings,
            "product": products,
            "residual": residuals,
            "g": g,
            "parity_partial": parts["parity_gradient"],
            "channel_partial": parts["channel_partial"],
            "binary_partial": parts["binary_partial"],
            "gradient": parts["gradient"],
            "curvature": curvature,
            "direction": direction,
            "accepted_step": eta,
            "backtrack_index": step["backtrack_index"],
            "raw_proposal": raw,
            "projected_proposal": projected,
            "active_projection_coordinates": active,
            "loss_before": step["loss_before"],
            "loss_after": step["loss_after"],
            "hard_decision_before": hard_before,
            "syndrome_before": syndrome(checks, hard_before),
            "hard_decision_after": hard_after,
            "syndrome_after": syndrome(checks, hard_after),
        })
    checks_passed["finite_differences"] = fd_worst <= FD_TOLERANCE
    first_x = steps[0]["x_before"]
    zero = dict(fp, channel_weight=0.0, binary_weight=0.0)
    no_binary = dict(fp, binary_weight=0.0)
    for name, rung_index in TERM_RUNGS.items():
        variant = {"parity": zero, "parity_channel": no_binary, "parity_channel_binary": fp}[name]
        recomposed = objective_parts(first_x, ell, checks, variant)["gradient"]
        retained = trace["rung_results"][rung_index]["result"]["initial_gradient"]
        checks_passed[f"rung_{rung_index}_{name}_initial_gradient_bitwise"] = recomposed == retained
    checks_passed["ell_is_negative_L"] = ell == [-v for v in L]
    checks_passed["hard_decision_matches_L_rule"] = hard_decision(first_x) == [1 if v >= 0.0 else 0 for v in L]
    checks_passed["source_validation_passed"] = trace["validation_passed"] is True and trace["status"] == "valid"
    all_passed = all(checks_passed.values())
    return {
        "schema_version": "comm-core-story-001/v1",
        "derivation_id": "COMM-CORE-STORY-001",
        "role": "explanatory decomposition for rq1_mechanism_animation.html (Core story)",
        "claim_boundary": ("Recomputes per-term partial derivatives of retained native scalar "
                           "updates. It runs no decoder, adds no experiment and carries no "
                           "performance evidence."),
        "source": {"path": ENDPOINT_TRACE, "sha256": ENDPOINT_SHA256,
                   "rung_index": NATIVE_RUNG, "card_id": NATIVE_CARD},
        "objective": {
            "coordinates": "one scalar per bit; x_i = +1 favours bit 0 (bit-0-positive)",
            "channel_evidence": "ell = -L, with L_i = ln(P(b_i=1|y_i)/P(b_i=0|y_i))",
            "formula": ("J(x) = -(w_ch/(2n)) sum_i ell_i x_i + (w_par/n) sum_c (1 - prod_{j in c} x_j)^2 "
                        "+ (w_bin/n) sum_i (1 - x_i^2)^2"),
            "check_term": ("g_{c,i} = -(2 w_par/n) r_c prod_{j in c, j != i} x_j, "
                           "with r_c = 1 - prod_{j in c} x_j"),
            "channel_term": "-(w_ch/(2n)) ell_i",
            "binary_term": "(4 w_bin/n) x_i (x_i^2 - 1)",
            "preconditioner": "D_i = (2 w_par deg_i + 8 w_bin)/n",
            "update": ("x <- clip(x - eta grad J / D, -1, 1), eta = step_size * 0.5^backtrack, "
                       "accepted at the first strict decrease of J"),
            "hard_decision_rule": "b_hat_i = 1 if x_i < 0 else 0",
            "n": n,
            "weights": {"channel": fp["channel_weight"], "parity": fp["parity_weight"],
                        "binary": fp["binary_weight"]},
            "step_size": fp["step_size"],
            "degrees": deg,
        },
        "names": {"bits": BIT_NAMES, "checks": CHECK_NAMES,
                  "trace_bit_labels": ["b0", "b1", "b2"], "trace_check_labels": ["c0", "c1"]},
        "graph": {"checks_one_based": checks},
        "ell": ell,
        "updates": updates,
        "validation": {"all_passed": all_passed, "checks": checks_passed,
                       "finite_difference_max_abs_error": fd_worst,
                       "finite_difference_tolerance": FD_TOLERANCE},
        "status": "valid" if all_passed else "invalid",
    }


def serialize(record: dict[str, Any]) -> bytes:
    return (json.dumps(record, indent=2, sort_keys=True) + "\n").encode("ascii")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true",
                        help="recompute and compare with the retained output instead of writing")
    args = parser.parse_args()
    record = derive()
    payload = serialize(record)
    if record["status"] != "valid":
        failed = [k for k, v in record["validation"]["checks"].items() if not v]
        print(f"FAIL: derivation checks failed: {failed}", file=sys.stderr)
        return 1
    digest = hashlib.sha256(payload).hexdigest()
    if args.check:
        if OUTPUT.read_bytes() != payload:
            print("FAIL: retained core_story_trace.json differs from a fresh derivation", file=sys.stderr)
            return 1
        if MANIFEST.read_text(encoding="ascii") != f"{digest}  {OUTPUT.name}\n":
            print("FAIL: MANIFEST.sha256 does not match", file=sys.stderr)
            return 1
        print(f"PASS: fresh derivation equals the retained output ({digest})")
        return 0
    RESULT_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(payload)
    MANIFEST.write_text(f"{digest}  {OUTPUT.name}\n", encoding="ascii")
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({digest}); {len(record['updates'])} updates, "
          f"{len(record['validation']['checks'])} checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
